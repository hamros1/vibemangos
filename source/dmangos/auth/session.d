/**
 * One client's login conversation.
 *
 * `AuthSession` does no I/O of its own. The network layer passes in whatever
 * bytes arrive (`receive`) and sends whatever the session produces
 * (`takeOutput`). Packets may arrive split or merged arbitrarily. The unit
 * tests drive the whole protocol this way, with no sockets.
 *
 * Packet handlers are methods tagged with `@Handles(opcode, state)`; the
 * dispatch `switch` is generated from them at compile time by
 * `dmangos.net.dispatch`. An unknown opcode, or one sent in the wrong state,
 * disconnects the client.
 *
 * The decisions follow CMaNGOS `realmd/AuthSocket.cpp`:
 * $(UL
 *   $(LI banned IP: "no access"; account locked to another IP: "suspended";)
 *   $(LI unreadable `s`/`v`: "no access"; permanent ban: "banned"; temporary ban: "suspended";)
 *   $(LI unknown account: a fake but stable challenge, so names cannot be enumerated;)
 *   $(LI wrong password: "unknown account", counted toward the `WrongPass` autoban.)
 * )
 *
 * ---
 *   awaitingChallenge ──logonChallenge──▶ awaitingLogonProof ──logonProof──▶ authenticated ⟲ realmList
 *          │                                                                      ▲
 *          └──reconnectChallenge──▶ awaitingReconnectProof ──reconnectProof──────┘
 * ---
 */
module dmangos.auth.session;

import core.time : MonoTime;
import std.algorithm.searching : canFind;
import std.typecons : Nullable;

import dmangos.bytes;
import dmangos.crypto.hash : constantTimeEqual;
import dmangos.crypto.random : secureRandom;
import dmangos.crypto.srp6;
import dmangos.log;
import dmangos.net.dispatch : DispatchResult, HandlesFor = Handles, PacketDispatch;
import dmangos.net.server : NetSession;
import dmangos.serialization : deserialize, wireSize;
import dmangos.auth.accounts;
import dmangos.auth.config : WrongPassBanTarget;
import dmangos.auth.context;
import dmangos.auth.database : autoBanAuthor;
import dmangos.auth.protocol;
import dmangos.auth.realms : buildRealmList;

/// The most unprocessed input a session buffers. The largest client packet is under 100 bytes.
private enum maxBufferedInput = 1024;

/// Where a session is in the protocol.
enum SessionState
{
    awaitingChallenge,
    awaitingLogonProof,
    awaitingReconnectProof,
    authenticated,
    closed,
}

/// Binds a handler method to an opcode and the session states in which that opcode is legal.
private alias Handles = HandlesFor!(Opcode, SessionState);

/// See the module documentation.
final class AuthSession : NetSession
{
    /// Where the session is in the protocol.
    alias State = SessionState;

    mixin PacketDispatch!Handles;

    private
    {
        AuthContext context;
        string remoteAddress;
        State state_ = State.awaitingChallenge;
        bool finishing; // disconnect once the pending output has been sent
        ubyte[] input;
        ubyte[] output;

        ushort build;
        string loginName;      // the name the client sent, case-folded; what it hashes into its proofs
        ClientDetails client;
        Account account;
        bool fakeAccount;      // the challenge was a decoy for an account that does not exist
        Srp6Server srp;
        ubyte[16] reconnectChallenge;
    }

    invariant
    {
        assert(state_ == State.awaitingChallenge || state_ == State.closed || loginName.length > 0,
            "past the challenge, a session always knows who is logging in");
        assert(state_ != State.authenticated || (!fakeAccount && account.sessionKey.length == sessionKeyLength),
            "an authenticated session always belongs to a real account with a session key");
        assert(input.length <= maxBufferedInput);
    }

    ///
    this(AuthContext context, string remoteAddress)
    in (context !is null)
    {
        this.context = context;
        this.remoteAddress = remoteAddress;
    }

    /// Current protocol state.
    @property State state() const
    {
        return state_;
    }

    /// The client's address, as given to the constructor.
    @property string address() const
    {
        return remoteAddress;
    }

    /// True when the connection should be closed once pending output is flushed.
    @property bool wantsClose() const
    {
        return finishing || state_ == State.closed;
    }

    /// Feeds bytes received from the client and processes every complete packet among them.
    void receive(scope const(ubyte)[] data)
    {
        if (wantsClose)
            return;
        if (input.length + data.length > maxBufferedInput)
        {
            warning!"%s: too much unprocessed input, disconnecting"(remoteAddress);
            disconnect();
            return;
        }

        input ~= data;
        while (input.length > 0 && !wantsClose)
        {
            auto reader = ByteReader(input);
            immutable opcode = reader.read!ubyte;
            try
                dispatch(cast(Opcode) opcode, reader);
            catch (IncompletePacketException)
                break; // wait for the rest; handlers change nothing until a packet is fully parsed
            catch (PacketException e)
            {
                warning!"%s: malformed packet 0x%02X: %s"(remoteAddress, opcode, e.msg);
                disconnect();
                break;
            }
            input = input[reader.position .. $];
        }
        if (input.length == 0 || wantsClose)
            input = null;
    }

    /// Takes the bytes that should be sent to the client.
    ubyte[] takeOutput()
    {
        auto pending = output;
        output = null;
        return pending;
    }

    /// Nothing to clean up: a login session holds no shared state.
    void disconnected()
    {
    }

private:
    void dispatch(Opcode opcode, ref ByteReader reader)
    {
        final switch (dispatchPacket(opcode, state_, reader))
        {
        case DispatchResult.handled:
            break;
        case DispatchResult.wrongState:
            warning!"%s: %s is not allowed in state %s"(remoteAddress, opcode, state_);
            disconnect();
            break;
        case DispatchResult.unhandled:
            warning!"%s: unsupported opcode 0x%02X in state %s"(remoteAddress, cast(ubyte) opcode, state_);
            disconnect();
            break;
        }
    }

    void send(T)(auto ref const T packet)
    {
        output ~= encode(packet);
    }

    void finish()
    {
        finishing = true;
    }

    void disconnect()
    {
        state_ = State.closed;
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    @Handles(Opcode.logonChallenge, State.awaitingChallenge)
    void handleLogonChallenge(ref ByteReader reader)
    {
        const challenge = readChallenge(reader);
        identify(challenge);

        if (!buildAllowed(challenge))
            return rejectChallenge(AuthResult.failVersionInvalid, "unsupported client build");
        if (addressBlocked())
            return rejectChallenge(AuthResult.failNoAccess, "address is banned");

        auto found = lookupAccount();
        if (found.isNull)
        {
            // Indistinguishable from a real account; the proof that follows can never succeed.
            const decoy = fakeCredentials(context.fakeAccountSecret, loginName);
            account = Account.init;
            account.username = loginName;
            account.salt = decoy.salt;
            account.verifier = decoy.verifier;
            fakeAccount = true;
            verbose!"%s: unknown account '%s', sending a decoy challenge"(remoteAddress, loginName);
            return sendChallenge();
        }

        account = found.get;
        if (account.locked && account.lockedIp != remoteAddress)
            return rejectChallenge(AuthResult.failSuspended, "account is locked to " ~ account.lockedIp);
        if (!account.credentialsValid)
            return rejectChallenge(AuthResult.failNoAccess, "stored s/v values are broken");
        if (account.ban == BanState.banned)
            return rejectChallenge(AuthResult.failBanned, "account is banned");
        if (account.ban == BanState.suspended)
            return rejectChallenge(AuthResult.failSuspended, "account is temporarily banned");

        sendChallenge();
    }

    @Handles(Opcode.logonProof, State.awaitingLogonProof)
    void handleLogonProof(const ClientLogonProof proof)
    {
        if (proof.securityFlags != 0)
            throw new PacketException("client sent PIN data although none was requested");
        if (proof.keyCount != 0)
            throw new PacketException("telemetry keys are not supported");

        const session = srp.verify(proof.clientPublicKey, proof.clientProof);
        if (session.isNull || fakeAccount)
        {
            info!"%s: wrong password for '%s'"(remoteAddress, loginName);
            context.throttle.recordFailure(remoteAddress, MonoTime.currTime);
            sendLogonProofFailure(AuthResult.failUnknownAccount);
            if (!fakeAccount)
                registerFailedLogin();
            finish();
            return;
        }

        context.database.recordLogin(account.id, session.get.sessionKey, remoteAddress, client);
        context.throttle.recordSuccess(remoteAddress);
        account.sessionKey = session.get.sessionKey.dup;

        send(ServerLogonProof(AuthResult.success, session.get.serverProof));
        state_ = State.authenticated;
        info!"%s: '%s' logged in (%s, build %s)"(remoteAddress, loginName, versionName(build), build);
    }

    @Handles(Opcode.reconnectChallenge, State.awaitingChallenge)
    void handleReconnectChallenge(ref ByteReader reader)
    {
        const challenge = readChallenge(reader);
        identify(challenge);

        // The client cannot show an error at this step, so every refusal just closes the
        // connection. The client then falls back to a full login, which reports the reason.
        if (!buildAllowed(challenge) || addressBlocked())
            return refuseReconnect("build not allowed or address banned");

        auto found = lookupAccount();
        if (found.isNull)
            return refuseReconnect("no such account");
        account = found.get;
        if (account.ban != BanState.none)
            return refuseReconnect("account is banned");
        if (account.locked && account.lockedIp != remoteAddress)
            return refuseReconnect("account is locked to another address");
        if (account.sessionKey.length != sessionKeyLength)
            return refuseReconnect("no session key stored");

        reconnectChallenge = secureRandom!16;
        send(ServerReconnectChallenge(AuthResult.success, reconnectChallenge, secureRandom!16));
        state_ = State.awaitingReconnectProof;
    }

    @Handles(Opcode.reconnectProof, State.awaitingReconnectProof)
    void handleReconnectProof(const ClientReconnectProof proof)
    {
        const ubyte[sessionKeyLength] sessionKey = account.sessionKey;
        const expected = computeReconnectProof(loginName, proof.proofData, reconnectChallenge, sessionKey);
        if (!constantTimeEqual(expected[], proof.clientProof[]))
        {
            context.throttle.recordFailure(remoteAddress, MonoTime.currTime);
            warning!"%s: bad reconnect proof for '%s'"(remoteAddress, loginName);
            disconnect();
            return;
        }

        context.throttle.recordSuccess(remoteAddress);
        send(ServerReconnectProof(AuthResult.success));
        state_ = State.authenticated;
        info!"%s: '%s' reconnected"(remoteAddress, loginName);
    }

    @Handles(Opcode.realmList, State.authenticated)
    void handleRealmList(const ClientRealmList request) // read only to check its size
    {
        const realms = context.realms.current(MonoTime.currTime);
        send(buildRealmList(realms, build, account.level, context.database.characterCounts(account.id)));
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Reads the size-prefixed body that logon and reconnect challenges share.
    ClientLogonChallenge readChallenge(ref ByteReader reader)
    {
        enum minimumSize = wireSize!ClientInfo + 1; // + the username length byte

        const header = deserialize!LogonChallengeHeader(reader);
        if (header.size < minimumSize || header.size > minimumSize + 4 * maxAccountNameLength)
            throw new PacketException("logon challenge has an implausible size");

        auto payload = ByteReader(reader.readBytes(header.size));
        ClientLogonChallenge challenge;
        try
            challenge = deserialize!ClientLogonChallenge(payload);
        catch (IncompletePacketException)
            throw new PacketException("logon challenge is shorter than its contents");
        if (!payload.empty)
            throw new PacketException("logon challenge is longer than its contents");
        return challenge;
    }

    /// The account the client named, if that name can exist at all.
    Nullable!Account lookupAccount()
    {
        return isValidAccountName(loginName) ? context.database.findAccount(loginName) : Nullable!Account.init;
    }

    /// Records who is connecting and with what client.
    void identify(const ref ClientLogonChallenge challenge)
    {
        build = challenge.info.build;
        loginName = canonicalAccountName(challenge.username);
        client = ClientDetails(challenge.info.locale, challenge.info.os, challenge.info.platform);
    }

    bool buildAllowed(const ref ClientLogonChallenge challenge)
    {
        return challenge.info.game == "WoW" && context.config.allowedBuilds.canFind(challenge.info.build);
    }

    /// Banned in `ip_banned`, or blocked by the in-memory throttle.
    bool addressBlocked()
    {
        return context.throttle.isBlocked(remoteAddress, MonoTime.currTime)
            || context.database.isIpBanned(remoteAddress);
    }

    void sendChallenge()
    {
        srp = Srp6Server(loginName, account.salt, account.verifier);

        ServerLogonChallenge response;
        response.serverPublicKey = srp.publicKey;
        response.salt = account.salt;
        response.versionChallenge = secureRandom!16;
        send(response);
        state_ = State.awaitingLogonProof;
        verbose!"%s: sent logon challenge for '%s' (%s, build %s)"(remoteAddress, loginName,
            versionName(build), build);
    }

    void rejectChallenge(AuthResult result, string reason)
    {
        info!"%s: logon challenge for '%s' rejected (%s): %s"(remoteAddress, loginName, result, reason);
        send(ServerLogonChallengeFailure(0, result));
        finish();
    }

    void refuseReconnect(string reason)
    {
        info!"%s: reconnect for '%s' refused: %s"(remoteAddress, loginName, reason);
        disconnect();
    }

    void sendLogonProofFailure(AuthResult result)
    {
        // 1.12.3 (6141) expects two trailing bytes; 1.12.1 and 1.12.2 do not (CMaNGOS AuthSocket.cpp).
        if (build > 6005)
            send(ServerLogonProofFailurePadded(result));
        else
            send(ServerLogonProofFailure(result));
    }

    /// CMaNGOS `RegisterFailedLogin`: count the failure, and ban once `WrongPass.MaxCount` is reached.
    void registerFailedLogin()
    {
        const limit = context.config.wrongPassMaxCount;
        if (limit == 0)
            return;

        const failures = context.database.recordFailedLogin(account.id);
        if (failures < limit)
            return;

        const duration = context.config.wrongPassBanTime;
        final switch (context.config.wrongPassBanType)
        {
        case WrongPassBanTarget.account:
            context.database.banAccount(account.id, duration, autoBanAuthor, "Failed login autoban");
            info!"account '%s' banned for %s seconds after %s failed logins"(loginName, duration, failures);
            break;
        case WrongPassBanTarget.ip:
            context.database.banIp(remoteAddress, duration, autoBanAuthor, "Failed login autoban");
            info!"%s banned for %s seconds after %s failed logins on '%s'"(remoteAddress, duration, failures,
                loginName);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests: a scripted client talks to a session through bytes alone.
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.auth.config : AuthConfig;
    import dmangos.auth.database : MemoryLoginDatabase;
    import dmangos.auth.realms : RealmRecord;
    import dmangos.serialization : serialize;

    private MemoryLoginDatabase newDatabase()
    {
        auto db = new MemoryLoginDatabase;
        db.createAccount("player", "secret");
        db.realms = [RealmRecord(1, "Test Realm", "127.0.0.1", 8085, 1, 0, 1, 0, 0, "5875 6005 6141")];
        return db;
    }

    private AuthContext newContext(MemoryLoginDatabase db, uint wrongPassMaxCount = 0)
    {
        AuthConfig config;
        config.maxFailedLogins = 2;
        config.wrongPassMaxCount = wrongPassMaxCount;
        setLogLevel(LogLevel.error); // keep test output quiet
        return new AuthContext(config, db);
    }

    private AuthSession newSession(MemoryLoginDatabase db, string address = "127.0.0.1")
    {
        return new AuthSession(newContext(db), address);
    }

    private ubyte[] challengePacket(string username, ushort build = 5875,
        Opcode opcode = Opcode.logonChallenge)
    {
        ClientLogonChallenge challenge;
        challenge.info = ClientInfo("WoW", 1, 12, 1, build, "x86", "Win", "enUS", 60, [127, 0, 0, 1]);
        challenge.username = username;

        ByteWriter body_;
        serialize(body_, challenge);

        ByteWriter packet;
        packet.put(cast(ubyte) opcode);
        packet.put(ubyte(3));
        packet.put(cast(ushort) body_.length);
        packet.putBytes(body_.data);
        return packet.release();
    }

    private ubyte[] proofPacket(in ubyte[keyLength] publicKey, in ubyte[proofLength] clientProof)
    {
        ClientLogonProof proof;
        proof.clientPublicKey = publicKey;
        proof.clientProof = clientProof;
        ByteWriter packet;
        packet.put(cast(ubyte) Opcode.logonProof);
        serialize(packet, proof);
        return packet.release();
    }

    private ServerLogonChallenge expectChallenge(AuthSession session)
    {
        auto reply = ByteReader(session.takeOutput());
        assert(reply.read!ubyte == Opcode.logonChallenge);
        const response = deserialize!ServerLogonChallenge(reply);
        assert(response.result == AuthResult.success);
        assert(reply.empty);
        return response;
    }

    private ubyte[] expectChallengeFailure(AuthSession session, string username)
    {
        session.receive(challengePacket(username));
        assert(session.wantsClose);
        return session.takeOutput();
    }

    /// Sends a logon proof for `password` and returns the server's reply.
    private ubyte[] tryPassword(AuthSession session, string username, string password,
        out ubyte[sessionKeyLength] sessionKey, out ubyte[proofLength] expectedServerProof)
    {
        session.receive(challengePacket(username));
        const challenge = expectChallenge(session);
        auto client = Srp6Client(username, password, secureRandom!privateKeyLength);
        const answer = client.respond(challenge.salt, challenge.serverPublicKey);
        sessionKey = answer.sessionKey;
        expectedServerProof = answer.expectedServerProof;
        session.receive(proofPacket(client.publicKey, answer.clientProof));
        return session.takeOutput();
    }

    private ubyte[] tryPassword(AuthSession session, string username, string password)
    {
        ubyte[sessionKeyLength] key;
        ubyte[proofLength] proof;
        return tryPassword(session, username, password, key, proof);
    }

    private enum ubyte[2] wrongPasswordReply = [Opcode.logonProof, AuthResult.failUnknownAccount];
}

/// A full login, followed by a realm list request.
unittest
{
    auto db = newDatabase();
    db.setCharacterCount(1, 1, 3);
    auto session = newSession(db);

    ubyte[sessionKeyLength] key;
    ubyte[proofLength] expectedProof;
    auto reply = ByteReader(tryPassword(session, "player", "secret", key, expectedProof));
    assert(reply.read!ubyte == Opcode.logonProof);
    const proof = deserialize!ServerLogonProof(reply);
    assert(proof.result == AuthResult.success && proof.serverProof == expectedProof);
    assert(session.state == AuthSession.State.authenticated);
    assert(db.findAccount("PLAYER").get.sessionKey == key[]);
    assert(db.logons == ["PLAYER@127.0.0.1 (enUS Win x86)"]);

    const ubyte[5] realmRequest = [Opcode.realmList, 0, 0, 0, 0];
    session.receive(realmRequest);
    auto realms = ByteReader(session.takeOutput());
    assert(realms.read!ubyte == Opcode.realmList);
    assert(realms.read!ushort == realms.remaining);
    const list = deserialize!ServerRealmList(realms);
    assert(list.realms.length == 1);
    assert(list.realms[0].name == "Test Realm" && list.realms[0].address == "127.0.0.1:8085");
    assert(list.realms[0].characters == 3);
    assert(list.realms[0].flags == RealmFlags.none);
    assert(!session.wantsClose);
}

/// Packets split into single bytes decode the same way.
unittest
{
    auto session = newSession(newDatabase());
    foreach (b; challengePacket("player"))
    {
        const ubyte[1] single = [b];
        session.receive(single);
    }
    expectChallenge(session);
}

/// An unknown account gets a decoy challenge, the same each time, and then fails like a wrong password.
unittest
{
    auto db = newDatabase();
    auto context = newContext(db);

    auto first = new AuthSession(context, "127.0.0.1");
    first.receive(challengePacket("nobody"));
    const salt = expectChallenge(first).salt;
    auto second = new AuthSession(context, "127.0.0.1");
    second.receive(challengePacket("NoBody"));
    assert(expectChallenge(second).salt == salt, "the decoy must not change between attempts");

    auto session = new AuthSession(context, "127.0.0.2");
    assert(tryPassword(session, "nobody", "anything") == wrongPasswordReply[]);
    assert(session.wantsClose);
}

/// A wrong password fails with "unknown account"; with WrongPass.MaxCount set it leads to an IP ban.
unittest
{
    auto db = newDatabase();
    auto context = newContext(db, 2);

    auto first = new AuthSession(context, "10.0.0.5");
    assert(tryPassword(first, "player", "wrong") == wrongPasswordReply[]);
    assert(db.findAccount("player").get.failedLogins == 1);
    assert(db.findAccount("player").get.sessionKey.length == 0);
    assert(!db.isIpBanned("10.0.0.5"));

    auto second = new AuthSession(context, "10.0.0.5");
    tryPassword(second, "player", "wrong");
    assert(db.isIpBanned("10.0.0.5"), "the second failure reaches the limit");

    const ubyte[3] noAccess = [Opcode.logonChallenge, 0, AuthResult.failNoAccess];
    assert(expectChallengeFailure(new AuthSession(context, "10.0.0.5"), "player") == noAccess[]);
    // A successful login resets the counter.
    tryPassword(new AuthSession(context, "10.0.0.6"), "player", "secret");
    assert(db.findAccount("player").get.failedLogins == 0);
}

/// Bans, IP locks, broken credentials and unsupported builds are turned away at the challenge.
unittest
{
    static ubyte[3] reply(AuthResult result)
    {
        return [Opcode.logonChallenge, 0, result];
    }

    auto db = newDatabase();
    const id = db.findAccount("player").get.id;

    auto oldClient = newSession(db);
    oldClient.receive(challengePacket("player", 4222));
    assert(oldClient.takeOutput() == reply(AuthResult.failVersionInvalid)[]);

    db.banAccount(id, 3600, "test", "test");
    assert(expectChallengeFailure(newSession(db), "player") == reply(AuthResult.failSuspended)[]);
    db.banAccount(id, 0, "test", "test");
    assert(expectChallengeFailure(newSession(db), "player") == reply(AuthResult.failBanned)[]);
    db.unbanAccount(id, "test");

    db.lockAccount("player", "10.9.9.9");
    assert(expectChallengeFailure(newSession(db), "player") == reply(AuthResult.failSuspended)[]);
    auto fromLockedAddress = newSession(db, "10.9.9.9");
    fromLockedAddress.receive(challengePacket("player"));
    expectChallenge(fromLockedAddress);

    db.breakCredentials("player");
    assert(expectChallengeFailure(newSession(db, "10.9.9.9"), "player") == reply(AuthResult.failNoAccess)[]);
}

/// Packets out of order, unknown opcodes and lying size fields disconnect the client.
unittest
{
    auto db = newDatabase();

    auto early = newSession(db);
    const ubyte[5] realmRequest = [Opcode.realmList, 0, 0, 0, 0];
    early.receive(realmRequest);
    assert(early.state == AuthSession.State.closed);

    auto patcher = newSession(db);
    const ubyte[1] xfer = [Opcode.xferAccept];
    patcher.receive(xfer);
    assert(patcher.state == AuthSession.State.closed);

    auto liar = newSession(db);
    auto packet = challengePacket("player");
    packet[2] = 0xFF; // size field now far larger than any real challenge
    liar.receive(packet);
    assert(liar.state == AuthSession.State.closed);
}

/// Repeated wrong passwords also trip the in-memory throttle.
unittest
{
    auto db = newDatabase();
    auto context = newContext(db);
    foreach (attempt; 0 .. 2)
        tryPassword(new AuthSession(context, "10.1.1.1"), "player", "guess");

    const ubyte[3] noAccess = [Opcode.logonChallenge, 0, AuthResult.failNoAccess];
    assert(expectChallengeFailure(new AuthSession(context, "10.1.1.1"), "player") == noAccess[]);
}

/// A client that lost its world connection can reconnect with the session key from its last login.
unittest
{
    auto db = newDatabase();
    ubyte[sessionKeyLength] key;
    ubyte[proofLength] unused;
    tryPassword(newSession(db), "player", "secret", key, unused);

    auto session = newSession(db);
    session.receive(challengePacket("player", 5875, Opcode.reconnectChallenge));
    auto reply = ByteReader(session.takeOutput());
    assert(reply.read!ubyte == Opcode.reconnectChallenge);
    const challenge = deserialize!ServerReconnectChallenge(reply);
    assert(challenge.result == AuthResult.success);

    ClientReconnectProof proof;
    proof.proofData = secureRandom!16;
    proof.clientProof = computeReconnectProof("PLAYER", proof.proofData, challenge.challenge, key);
    ByteWriter packet;
    packet.put(cast(ubyte) Opcode.reconnectProof);
    serialize(packet, proof);
    session.receive(packet.data);

    const ubyte[4] success = [Opcode.reconnectProof, AuthResult.success, 0, 0];
    assert(session.takeOutput() == success[]);
    assert(session.state == AuthSession.State.authenticated);

    // An unknown account or a banned one cannot reconnect.
    auto stranger = newSession(db);
    stranger.receive(challengePacket("nobody", 5875, Opcode.reconnectChallenge));
    assert(stranger.state == AuthSession.State.closed);
    db.banAccount(1, 0, "test", "test");
    auto banned = newSession(db);
    banned.receive(challengePacket("player", 5875, Opcode.reconnectChallenge));
    assert(banned.state == AuthSession.State.closed);
}
