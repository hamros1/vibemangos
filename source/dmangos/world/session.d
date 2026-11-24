/**
 * One client's connection to the world server.
 *
 * Like the login session, `WorldSession` does no I/O. It takes the bytes
 * that arrive and produces the bytes to send, so the unit tests below play
 * a whole client conversation without sockets.
 *
 * The handshake:
 * $(OL
 *   $(LI the server sends `SMSG_AUTH_CHALLENGE` with a random seed;)
 *   $(LI the client answers `CMSG_AUTH_SESSION` with SHA1(account, 0, its seed, the server seed, K),
 *        where K is the session key the login server stored in `account.sessionkey`;)
 *   $(LI from then on, every header is encrypted with K (`dmangos.world.crypt`);)
 *   $(LI the server replies `SMSG_ADDON_INFO` and `SMSG_AUTH_RESPONSE` (AUTH_OK).)
 * )
 * The client is then on the character screen, where characters can be listed,
 * created (`dmangos.world.playercreate`) and deleted, each request checked
 * first.
 *
 * `CMSG_PLAYER_LOGIN` enters the world.
 *
 * The handlers are grouped by subject, one module per group, each a mixin
 * template that `WorldSession` mixes in:
 * $(UL
 *   $(LI `dmangos.world.charscreen`: the character list, creation, deletion and logging in;)
 *   $(LI `dmangos.world.inworld`: logging out, movement, queries, chat and settings.)
 * )
 * A mixed-in handler is a member of `WorldSession`, with the same access to its
 * state as the handlers here, and `PacketDispatch` finds it like any other.
 */
module dmangos.world.session;

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import std.bitmanip : bigEndianToNative, littleEndianToNative, nativeToLittleEndian;

import dmangos.auth.accounts : AccountLevel;
import dmangos.cluster.protocol : SimulationOwner;
import dmangos.bytes;
import dmangos.timer : IntervalTimer;
import dmangos.crypto.hash : constantTimeEqual, sha1;
import dmangos.crypto.random : secureRandom;
import dmangos.log;
import dmangos.net.dispatch : DispatchResult, HandlesFor = Handles, PacketDispatch;
import dmangos.net.server : BoundedOutput, NetSession, ReusesOutput;
import dmangos.world.addons : buildAddonInfo, parseAddons;
import dmangos.world.charscreen : CharacterScreenHandlers;
import dmangos.world.context : Kickable, WorldContext;
import dmangos.world.crypt : clientHeaderLength, HeaderCrypt;
import dmangos.world.database : WorldAccount;
import dmangos.world.objects : UpdateData, UpdatePacket;
import dmangos.world.map : deliverUpdate, Inhabitant, Map;
import dmangos.world.player : CharacterData, DeathState, Player, PlayerFlags, Viewer;
import dmangos.world.opcodes;
import dmangos.world.packets;
import dmangos.world.character : Character;

/// Where a session is in the protocol.
enum WorldState
{
    awaitingAuth,    /// challenge sent, waiting for CMSG_AUTH_SESSION
    characterScreen, /// authenticated; the client shows its character list
    inWorld,         /// playing a character
    elsewhere,       /// playing a character simulated on another node of the cluster
    closed,
}

private alias Handles = HandlesFor!(Opcode, WorldState);

/// Pings closer together than this count as over-speed.
private enum minimumPingInterval = 27.seconds;

/// The most unprocessed input buffered: two maximum-size packets.
private enum maxBufferedInput = 2 * (clientHeaderLength + maxClientPacketSize);

/// See the module documentation.
final class WorldSession : NetSession, ReusesOutput, BoundedOutput, Kickable
{
    /// See `BoundedOutput`: `max_pending_output_kb`.
    @property size_t outputLimit() const
    {
        return size_t(context.config.maxPendingOutputKb) * 1024;
    }

    // A player simulated on another node than its client's (docs/CLUSTER.md).
    package ushort ownerNode;              // home: the node simulating this session's player; 0: here
    package ushort homeNode;               // owner: the node holding this session's client; 0: here
    package bool releaseWhenBack;          // home: the client left while elsewhere; release once the owner saved
    package bool gatewayPaused;            // home: keep the socket alive while its owner is unreachable
    package SimulationOwner gatewayHome;   // owner: the gateway's incarnation
    package uint gatewayCharacter;         // owner: the simulated character, including while loading
    package ulong gatewayToken;            // owner: the coordinator's route for this simulation
    private CharacterData recovery;        // owner: durable state while recovering, until the client loads the map
    private MonoTime recoveryReadyBy;      // owner: waiting for the checkpoint and ownership grant
    private MonoTime recoveryReadAt;

    /// The character in the world (docs/DESIGN.md, step 3); null at the character screen.
    package Character playing;

    private bool admitted;                 // the account is this session's (see `Kickable.admit`)
    private bool characterListWaiting;     // list only after an earlier session has saved and released the account
    private bool loginWaiting;             // a player login waits for that
    private ClientPlayerLogin pendingLogin;

    mixin PacketDispatch!Handles;

    package
    {
        WorldContext context;
        string remoteAddress;
        WorldState state_ = WorldState.awaitingAuth;
        bool finishing;
        bool registered; // listed in the context's session table
        ubyte[] input;
        OutputBuffer output;
        ubyte[] spareOutput;     // the memory of a sent array, given back by the server, for the next output
        ubyte[][] lentOutput;    // the memory of the arrays handed to the server, to know a returned one's whole
        import std.stdio : File;
        File packetLog;          // `packet_log`: what this connection was sent
        HeaderCrypt crypt;
        uint serverSeed;

        // A decrypted header whose body has not fully arrived yet. Headers are
        // decrypted exactly once, because decryption advances the key stream.
        bool haveHeader;
        uint bodyLength;
        uint pendingOpcode;

        WorldAccount account;
        uint build;
        string carriedAddress;   // the client's address, for a player whose home is another node
        MonoTime lastPing;
        bool pinged;
        uint overspeedPings;
        uint latency;
        bool tutorialRowMissing; // the account's character_tutorial row is written with its first character

    }

    invariant
    {
        assert(state_ != WorldState.characterScreen && state_ != WorldState.inWorld && state_ != WorldState.elsewhere
            || (crypt.active && account.hasSessionKey) || homeNode != 0,
            "an authenticated session always encrypts with its account's session key (unless its client is elsewhere)");
        import std.format : format;

        assert((state_ == WorldState.inWorld) == (playing !is null),
            format!"a character exists exactly while in the world (state %s, character %s)"(state_, playing !is null));
        assert(input.length <= maxBufferedInput);
    }

    /// Starts a session and queues `SMSG_AUTH_CHALLENGE`.
    this(WorldContext context, string remoteAddress)
    in (context !is null)
    {
        this.context = context;
        this.remoteAddress = remoteAddress;
        serverSeed = littleEndianToNative!uint(secureRandom!4);
        send(ServerAuthChallenge(serverSeed));
    }

    /**
     * A session whose client is on node `home`: its player's simulation came here. It has
     * no socket: what it sends goes to `home`, what the client sends comes through `fromHome`.
     */
    this(WorldContext context, WorldAccount account, ushort home)
    in (context !is null && home != 0)
    {
        import std.conv : to;

        this.context = context;
        this.remoteAddress = "client on node " ~ home.to!string;
        this.account = account;
        homeNode = home;
        admitted = true;
        state_ = WorldState.characterScreen;
    }

    /// The node holding this session's client, if it is another; 0 if here.
    @property ushort home() const pure nothrow @nogc @safe
    {
        return homeNode;
    }

    /// The node simulating this session's player, if it is another; 0 if here.
    @property ushort owner() const pure nothrow @nogc @safe
    {
        return ownerNode;
    }

    /// Owner: a packet from the client, relayed by its home node.
    void fromHome(ushort opcode, const(ubyte)[] body_)
    {
        auto reader = ByteReader(body_);
        handle(cast(Opcode) opcode, reader);
    }

    /// Home: a packet for the client from the node simulating its player.
    void fromOwner(ushort opcode, const(ubyte)[] body_)
    {
        if (!wantsClose)
            frame(cast(Opcode) opcode, body_);
    }

    /**
     * Home: the player's simulation came back here, or moved on to node `next` (0: it left the world
     * there, `toCharacterScreen` saying whether by logging out).
     */
    void ownerLeft(bool toCharacterScreen)
    {
        ownerNode = 0;
        if (releaseWhenBack || state_ == WorldState.closed)
        {
            // The client is gone and the owner has saved the character: the account is free.
            if (registered)
                context.removeSession(account.id, this);
            registered = false;
            state_ = WorldState.closed;
            return;
        }
        state_ = toCharacterScreen ? WorldState.characterScreen : WorldState.closed;
        if (!toCharacterScreen)
            finish();
    }

    /// Home: the player's simulation moved on to node `next` (from one third node to another).
    void ownerMoved(ushort next)
    {
        if (state_ == WorldState.elsewhere)
            ownerNode = next;
    }

    /**
     * The player's simulation arrives here from another node (`Character.arrive`): its character is
     * made; false if it cannot be loaded.
     */
    bool arrive(const(ubyte)[] state)
    {
        auto arriving = new Character(this, context);
        return arriving.arrive(state); // it becomes `playing` as it enters the world
    }

    /// Prepares the replacement world. Gameplay resumes with the existing client's worldport acknowledgement.
    package bool beginGatewayRecovery(uint guid, uint clientBuild)
    {
        if (!guid || context.ownsCell is null)
            return false;
        build = clientBuild;
        gatewayCharacter = guid;
        const now = context.clock();
        recoveryReadyBy = now + 15.seconds;
        return pollGatewayRecovery(now);
    }

    private bool readGatewayCheckpoint(MonoTime now)
    {
        import dmangos.mysql : DatabaseException;

        if (now < recoveryReadAt)
            return true;
        try
        {
            auto loaded = context.database.loadCharacter(gatewayCharacter);
            if (loaded.isNull || loaded.get.account != account.id || !loaded.get.position.isFinite
                || context.data.createInfo(loaded.get.race, loaded.get.classId) is null)
                return false;
            recovery = loaded.get;
        }
        catch (DatabaseException error)
        {
            recoveryReadAt = now + 1.seconds;
            warning!"%s: could not read character %s's recovery checkpoint: %s"(remoteAddress, gatewayCharacter, error.msg);
        }
        return true;
    }

    /// The gateway can see the replacement's grant before its map is ready to simulate.
    package bool pollGatewayRecovery(MonoTime now)
    {
        if (recoveryReadyBy == MonoTime.init)
            return true;
        if (now >= recoveryReadyBy)
        {
            warning!"%s: timed out restoring character %s"(remoteAddress, gatewayCharacter);
            return false;
        }
        if (!recovery.guid && !readGatewayCheckpoint(now))
            return false;
        if (recovery.guid && ownsRecoveryPosition(recovery))
        {
            recoveryReadyBy = MonoTime.init;
            const at = recovery.position;
            send(ServerTransferPending(recovery.map));
            send(ServerNewWorld(recovery.map, at.x, at.y, at.z, at.orientation));
        }
        return true;
    }

    private bool ownsRecoveryPosition(const ref CharacterData saved)
    {
        import dmangos.world.grid : cellKeyAt;

        return context.canWrite() && context.ownsCell !is null
            && context.ownsCell(saved.map, cellKeyAt(saved.position.x, saved.position.y))
            && context.onlinePlayer(context.playerGuid(saved.guid)) is null
            && context.battlegrounds.mapReady(saved.map);
    }

    private void finishGatewayRecovery()
    {
        if (!ownsRecoveryPosition(recovery))
            return clientGone();
        auto saved = recovery;
        recovery = CharacterData.init;
        auto entering = new Character(this, context);
        entering.enterWorldAtLogin(saved, true);
    }

    /// Owner: the client is gone; the player leaves the world here, saved.
    void clientGone()
    {
        if (playing !is null)
            playing.leave("disconnected", false);
        else if (recovery.guid || recoveryReadyBy != MonoTime.init)
        {
            recovery = CharacterData.init;
            recoveryReadyBy = MonoTime.init;
            context.playerRelay.left(homeNode, account.id, false);
            context.playerRelay.remoteDone(account.id);
        }
        state_ = WorldState.closed;
    }

    /// Current protocol state.
    @property WorldState state() const
    {
        return state_;
    }

    /// The client's address (the one it connected from, when its simulation moved here from its home).
    @property string address() const
    {
        return carriedAddress.length ? carriedAddress : remoteAddress;
    }

    /// True when the connection should be closed once pending output is flushed.
    @property bool wantsClose() const
    {
        return finishing || state_ == WorldState.closed;
    }

    /// The round-trip time the client last reported, in milliseconds.
    @property uint latencyMs() const
    {
        return latency;
    }

    /// Feeds received bytes and handles every complete packet among them.
    /// A packet whose handling takes longer than this is logged: every other client waits meanwhile.
    private enum slowPacket = 200.msecs;

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
        while (!wantsClose)
        {
            if (!haveHeader)
            {
                if (input.length < clientHeaderLength)
                    break;
                ubyte[clientHeaderLength] header = input[0 .. clientHeaderLength];
                input = input[clientHeaderLength .. $];
                crypt.decryptHeader(header);

                const size = bigEndianToNative!ushort(header[0 .. 2]); // counts the 4-byte opcode
                pendingOpcode = littleEndianToNative!uint(header[2 .. 6]);
                if (size < 4 || size > maxClientPacketSize || pendingOpcode >= numMessageTypes)
                {
                    warning!"%s: malformed packet header (size %s, opcode 0x%X)"(remoteAddress, size, pendingOpcode);
                    disconnect();
                    break;
                }
                bodyLength = size - 4;
                haveHeader = true;
            }

            if (input.length < bodyLength)
                break;
            auto reader = ByteReader(input[0 .. bodyLength]);
            input = input[bodyLength .. $];
            haveHeader = false;
            const started = MonoTime.currTime;
            handle(cast(Opcode) pendingOpcode, reader);
            const took = MonoTime.currTime - started;
            if (took > slowPacket)
                warning!"%s: handling %s took %s ms"(remoteAddress, cast(Opcode) pendingOpcode, took.total!"msecs");
        }
        if (input.length == 0 || wantsClose)
            input = null;
    }

    /// Takes the bytes that should be sent to the client; the next go into a returned array, if any.
    ubyte[] takeOutput()
    {
        if (output.length == 0)
            return null;
        if (lentOutput.length >= 4)
            lentOutput.length = 0; // never given back (a connection that cannot send): forgotten
        lentOutput ~= output.memory;
        auto pending = output.take(spareOutput);
        spareOutput = null;
        return pending;
    }

    /// See `ReusesOutput`: an array the server has sent, kept for the next output (the largest of two).
    void returnOutput(ubyte[] buffer)
    {
        // The whole of the memory it was written in (it was handed over as the written part).
        foreach (i, memory; lentOutput)
            if (memory.ptr is buffer.ptr)
            {
                lentOutput[i] = lentOutput[$ - 1];
                lentOutput.length -= 1;
                lentOutput.assumeSafeAppend();
                if (output.length == 0 && memory.length > output.capacity)
                    output.take(memory);
                else if (memory.length > spareOutput.length)
                    spareOutput = memory;
                return;
            }
    }

    /// The character being played, if any (its `Player`).
    @property const(Player) character() const
    {
        return playing is null ? null : playing.character;
    }

    /// The character in the world; null at the character screen.
    @property Character inWorld()
    {
        return playing;
    }

    /// One tick of the world update: the character's (`Character.update`).
    void update(Duration elapsed)
    {
        if (playing !is null)
            playing.update(elapsed);
    }

    /**
     * Frames a packet for the client; with `packet_log` set, also writes it there (a file per
     * connection, once the account is known): the time in milliseconds, the opcode and the body in hex.
     * For finding which packet a client cannot take.
     */
    private void frame(Opcode opcode, scope const(ubyte)[] body_)
    {
        appendPacket(output, opcode, body_, crypt);
        if (context.config.packetLog.length && account.username.length)
            logPacket(opcode, body_);
    }

    private void logPacket(Opcode opcode, scope const(ubyte)[] body_)
    {
        import std.conv : to;
        import std.datetime.systime : Clock;
        import std.format : format;
        import std.path : buildPath;
        import std.stdio : File;

        try
        {
            if (!packetLog.isOpen)
                packetLog = File(buildPath(context.config.packetLog, format!"%s-%s.log"(account.username,
                    Clock.currTime.toUnixTime)), "w");
            const name = () { try return opcode.to!string; catch (Exception) return format!"0x%03X"(cast(uint) opcode); }();
            packetLog.writefln!"%s %s %(%02x%)"(Clock.currStdTime / 10_000, name, body_);
            packetLog.flush();
        }
        catch (Exception e)
        {
        }
    }

    /// Frames a packet another player's session (or the map) sends to this client.
    void deliver(Opcode opcode, const(ubyte)[] body_)
    {
        if (homeNode)
            return context.relayToHome(homeNode, account.id, cast(ushort) opcode, body_);
        if (!wantsClose)
            frame(opcode, body_);
    }

    /// Saves the character if one is being played, and removes the session from the context's table.
    void disconnected()
    {
        if (state_ == WorldState.elsewhere)
        {
            // The owner saves the player first; the account is released when it says so (`ownerLeft`).
            context.relayDisconnect(ownerNode, account.id);
            releaseWhenBack = true;
            state_ = WorldState.closed;
            return;
        }
        if (releaseWhenBack)
            return;
        if (playing !is null)
            playing.leave("disconnected", false);
        if (registered)
            context.removeSession(account.id, this);
        registered = false;
        state_ = WorldState.closed;
    }

    /// See `Kickable.admit`: character-screen requests waiting for the account can now run.
    void admit()
    {
        admitted = true;
        if (state_ != WorldState.characterScreen)
            return;
        if (characterListWaiting)
        {
            characterListWaiting = false;
            handleCharEnum();
        }
        if (loginWaiting)
        {
            loginWaiting = false;
            handlePlayerLogin(pendingLogin);
        }
    }

    /// Ends the session, e.g. because the account logged in again.
    void kick(string reason)
    {
        info!"%s: '%s' kicked: %s"(remoteAddress, account.username, reason);
        disconnect();
    }

package:
    void handle(Opcode opcode, ref ByteReader reader)
    {
        // Name lookups can be answered at the gateway even while the owner is changing.
        const gatewayNameQuery = state_ == WorldState.elsewhere && context.config.cluster.gateway
            && opcode == Opcode.CMSG_NAME_QUERY;
        if (state_ == WorldState.elsewhere && !gatewayPaused && !gatewayNameQuery)
            return context.relayToOwner(ownerNode, account.id, cast(ushort) opcode, reader.readBytes(reader.remaining));
        DispatchResult result;
        try
        {
            if ((gatewayPaused || recovery.guid || recoveryReadyBy != MonoTime.init) && !gatewayNameQuery)
            {
                if (recovery.guid && recoveryReadyBy == MonoTime.init
                    && opcode == Opcode.MSG_MOVE_WORLDPORT_ACK && reader.empty)
                    finishGatewayRecovery();
                else if (opcode == Opcode.CMSG_PING)
                    dispatchPacket(opcode, WorldState.characterScreen, reader);
                return;
            }
            result = dispatchPacket(opcode, state_, reader);
            // A packet of the player in the world: its character's.
            if (result == DispatchResult.unhandled && playing !is null)
                result = playing.handlePacket(opcode, state_, reader);
        }
        catch (PacketException e) // the body is complete, so "incomplete" means malformed too
        {
            warning!"%s: malformed packet 0x%03X: %s"(remoteAddress, cast(uint) opcode, e.msg);
            disconnect();
            return;
        }

        final switch (result)
        {
        case DispatchResult.handled:
            break;
        case DispatchResult.wrongState:
        case DispatchResult.unhandled:
            if (state_ == WorldState.awaitingAuth)
            {
                // Nothing but CMSG_AUTH_SESSION is accepted before authentication.
                warning!"%s: opcode 0x%03X before authentication, disconnecting"(remoteAddress, cast(uint) opcode);
                disconnect();
            }
            else
                trace!"%s: ignoring opcode 0x%03X in state %s"(remoteAddress, cast(uint) opcode, state_);
            break;
        }
    }

    void send(T)(auto ref const T packet)
    {
        import dmangos.serialization : serialize;

        ByteWriter payload;
        serialize(payload, packet);
        if (homeNode)
            return context.relayToHome(homeNode, account.id, cast(ushort) T.opcode, payload.data);
        frame(T.opcode, payload.data);
    }

    void finish()
    {
        finishing = true;
    }

    void disconnect()
    {
        if (state_ == WorldState.elsewhere && context.config.cluster.gateway)
        {
            context.relayDisconnect(ownerNode, account.id);
            releaseWhenBack = true;
        }
        if (playing !is null)
            playing.leave("disconnected", false);
        state_ = WorldState.closed;
    }

    /// Replies with an error and closes; every failed check of the handshake ends so.
    void refuse(AuthResponse response, string reason)
    {
        info!"%s: world login refused (%s): %s"(remoteAddress, response, reason);
        send(ServerAuthFailure(response));
        finish();
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_NAME_QUERY, WorldState.inWorld, WorldState.elsewhere)
    void handleNameQuery(const ClientNameQuery request)
    {
        import dmangos.world.objects : lowGuid;

        if (request.guid >> 48 != 0) // only player GUIDs use this query
            return;
        const origin = cast(uint)(request.guid >> 32);
        if (origin && origin != context.config.realmId)
        {
            if (state_ == WorldState.elsewhere && !gatewayPaused)
            {
                import dmangos.bytes : ByteWriter;
                ByteWriter query;
                query.put(request.guid);
                return context.relayToOwner(ownerNode, account.id, cast(ushort) Opcode.CMSG_NAME_QUERY, query.data);
            }
            if (inWorld !is null)
                if (auto copy = inWorld.currentBattleground())
                {
                    ServerNameQueryResponse response;
                    if (copy.foreignName(inWorld.player.guid, request.guid, response))
                        send(response);
                }
            return;
        }
        if (const other = context.onlinePlayer(request.guid))
        {
            const c = other.character;
            return send(ServerNameQueryResponse(request.guid, c.data.name, "", c.data.race, c.data.gender,
                c.data.classId));
        }
        if (const remote = context.remotePlayer(request.guid))
        {
            const c = remote.entry;
            return send(ServerNameQueryResponse(request.guid, c.name, "", c.race, c.gender, c.classId));
        }
        const found = context.database.nameInfo(lowGuid(request.guid));
        if (!found.isNull)
            send(ServerNameQueryResponse(request.guid, found.get.name, "", found.get.race, found.get.gender,
                found.get.classId));
    }

    @Handles(Opcode.CMSG_AUTH_SESSION, WorldState.awaitingAuth)
    void handleAuthSession(const ClientAuthSession request)
    {
        build = request.build;
        if (!context.config.allowedBuilds.canFind(request.build))
            return refuse(AuthResponse.AUTH_VERSION_MISMATCH, "unsupported client build");

        auto found = context.database.findAccount(request.account);
        if (found.isNull)
            return refuse(AuthResponse.AUTH_UNKNOWN_ACCOUNT, "no account named '" ~ request.account ~ "'");
        const candidate = found.get;
        if (candidate.locked && candidate.lockedIp != remoteAddress)
            return refuse(AuthResponse.AUTH_FAILED, "account is locked to " ~ candidate.lockedIp);
        if (!candidate.hasSessionKey)
            return refuse(AuthResponse.AUTH_FAILED, "no valid session key; log in through the login server first");
        if (context.database.isBanned(candidate.id, remoteAddress))
            return refuse(AuthResponse.AUTH_BANNED, "account or address is banned");

        const ubyte[4] zero = 0;
        const expected = sha1(request.account, zero, nativeToLittleEndian(request.clientSeed),
            nativeToLittleEndian(serverSeed), candidate.sessionKey);
        if (!constantTimeEqual(expected[], request.digest[]))
            return refuse(AuthResponse.AUTH_FAILED, "session proof does not match the stored session key");

        // A client of an operating system or platform not known is closed without a reply.
        if (candidate.os != "Win" && candidate.os != "OSX")
        {
            warning!"%s: unrecognized client OS '%s' for '%s'"(remoteAddress, candidate.os, candidate.username);
            return disconnect();
        }
        if (candidate.platform != "x86" && !(candidate.platform == "PPC" && candidate.os == "OSX"))
        {
            warning!"%s: unrecognized platform '%s' for '%s'"(remoteAddress, candidate.platform, candidate.username);
            return disconnect();
        }
        const addons = parseAddons(request.addonData); // a malformed list disconnects

        context.database.recordLogon(candidate.id, remoteAddress);
        account = candidate;
        tutorialRowMissing = !context.database.hasTutorialData(account.id);
        crypt.initialize(account.sessionKey);
        send(ServerAddonInfo(buildAddonInfo(addons)));
        send(ServerAuthSuccess());
        state_ = WorldState.characterScreen;
        context.addSession(account.id, this);
        registered = true;
        info!"%s: '%s' entered the character screen (build %s, %s addons)"(remoteAddress, account.username, build,
            addons.length);
    }

    @Handles(Opcode.CMSG_PING, WorldState.characterScreen, WorldState.inWorld)
    void handlePing(const ClientPing ping)
    {
        const now = context.clock();
        if (pinged)
        {
            if (now - lastPing < minimumPingInterval)
            {
                ++overspeedPings;
                const limit = context.config.maxOverspeedPings;
                if (limit && overspeedPings > limit && account.level == AccountLevel.player)
                {
                    warning!"%s: '%s' kicked for over-speed pings"(remoteAddress, account.username);
                    return disconnect();
                }
            }
            else
                overspeedPings = 0;
        }
        pinged = true;
        lastPing = now;
        latency = ping.latency;
        send(ServerPong(ping.sequence));
    }

    // -----------------------------------------------------------------------
    // The handler groups
    // -----------------------------------------------------------------------

    mixin CharacterScreenHandlers;
}

// ---------------------------------------------------------------------------
// Tests (the scripted client is in dmangos.world.testclient)
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testclient;
}

/// A successful handshake, then the character list, a ping and an attempt to enter the world with a character
/// that cannot be loaded.
unittest
{
    auto db = newDatabase();
    auto context = newContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);

    const replies = authenticate(client);
    assert(replies.length == 2);
    assert(replies[0].opcode == Opcode.SMSG_ADDON_INFO && replies[0].body_.length == 8);
    assert(replies[1].opcode == Opcode.SMSG_AUTH_RESPONSE);
    assert(replies[1].body_ == [AuthResponse.AUTH_OK, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    assert(client.session.state == WorldState.characterScreen);
    assert(db.logons == ["4@127.0.0.1"] && context.sessionCount == 1);

    client.write(Opcode.CMSG_CHAR_ENUM, null);
    auto list = client.read();
    assert(list.length == 1 && list[0].opcode == Opcode.SMSG_CHAR_ENUM);
    auto reader = ByteReader(list[0].body_);
    const characters = deserialize!ServerCharEnum(reader);
    assert(characters.characters.length == 1);
    assert(characters.characters[0].name == "Thrall" && characters.characters[0].level == 60);
    assert(characters.characters[0].equipment[4] == EquipmentDisplay(30606, 17));

    client.write(Opcode.CMSG_PING, ClientPing(42, 25));
    const pong = client.read();
    assert(pong.length == 1 && pong[0].opcode == Opcode.SMSG_PONG && pong[0].body_ == [42, 0, 0, 0]);
    assert(client.session.latencyMs == 25);

    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(1));
    const refused = client.read();
    assert(refused[0].opcode == Opcode.SMSG_CHARACTER_LOGIN_FAILED);
    assert(refused[0].body_ == [ubyte(CharacterLoginFailure.CHAR_LOGIN_NO_CHARACTER)]);

    // Opcodes without a handler, or not handled on the character screen, are ignored once authenticated.
    client.write(Opcode.CMSG_NAME_QUERY, [1, 0, 0, 0, 0, 0, 0, 0]);
    assert(!client.session.wantsClose);

    client.session.disconnected();
    assert(context.sessionCount == 0);
}

/// Packets split into single bytes, with each header decrypted exactly once.
unittest
{
    auto client = TestClient(new WorldSession(newContext(newDatabase()), "127.0.0.1"), testKey);
    authenticate(client);
    foreach (sequence; 0 .. 3)
    {
        ByteWriter ping;
        serialize(ping, ClientPing(sequence, 0));
        client.write(Opcode.CMSG_PING, ping.data, 1);
        const pong = client.read();
        assert(pong.length == 1 && pong[0].body_[0] == sequence);
    }
}

/// Every failed check is answered in the clear and closes the connection.
unittest
{
    auto db = newDatabase();
    auto context = newContext(db);

    static ubyte attempt(WorldContext context, string account, ubyte[sessionKeyLength] key, uint build = 5875)
    {
        auto client = TestClient(new WorldSession(context, "10.0.0.1"), key);
        const result = authResult(authenticate(client, account, key, build));
        assert(client.session.wantsClose && client.session.state != WorldState.characterScreen);
        return result;
    }

    ubyte[sessionKeyLength] wrongKey = testKey;
    wrongKey[0] ^= 1;
    assert(attempt(context, "PLAYER", wrongKey) == AuthResponse.AUTH_FAILED);
    assert(attempt(context, "NOBODY", testKey) == AuthResponse.AUTH_UNKNOWN_ACCOUNT);
    assert(attempt(context, "PLAYER", testKey, 4222) == AuthResponse.AUTH_VERSION_MISMATCH);

    db.bannedAccounts[4] = true;
    assert(attempt(context, "PLAYER", testKey) == AuthResponse.AUTH_BANNED);
    db.bannedAccounts.remove(4);

    db.accounts["PLAYER"].locked = true;
    db.accounts["PLAYER"].lockedIp = "10.9.9.9";
    assert(attempt(context, "PLAYER", testKey) == AuthResponse.AUTH_FAILED);
    db.accounts["PLAYER"].locked = false;

    db.accounts["PLAYER"].hasSessionKey = false;
    assert(attempt(context, "PLAYER", testKey) == AuthResponse.AUTH_FAILED);
    assert(context.sessionCount == 0 && db.logons.length == 0);
}

/// Anything but CMSG_AUTH_SESSION before authentication, or a malformed header, disconnects.
unittest
{
    auto context = newContext(newDatabase());

    auto early = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    early.read();
    early.write(Opcode.CMSG_CHAR_ENUM, null);
    assert(early.session.state == WorldState.closed);

    auto garbage = new WorldSession(context, "127.0.0.1");
    const ubyte[6] badHeader = [0xFF, 0xFF, 0, 0, 0, 0];
    garbage.receive(badHeader);
    assert(garbage.state == WorldState.closed);
}

/// Pings faster than every 27 seconds get a player kicked after `max_overspeed_pings`.
unittest
{
    auto context = newContext(newDatabase());
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    foreach (i; 0 .. 3) // the first ping sets the pace, the next two are tolerated
    {
        client.write(Opcode.CMSG_PING, ClientPing(i, 0));
        now += 5.seconds;
    }
    assert(!client.session.wantsClose);
    client.write(Opcode.CMSG_PING, ClientPing(3, 0));
    assert(client.session.wantsClose);

    // Pings at the normal pace are fine forever.
    auto steady = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(steady);
    foreach (i; 0 .. 10)
    {
        steady.write(Opcode.CMSG_PING, ClientPing(i, 0));
        now += 30.seconds;
    }
    assert(!steady.session.wantsClose);
}

/// Logging in again kicks the earlier session of the same account.
unittest
{
    auto context = newContext(newDatabase());
    auto first = TestClient(new WorldSession(context, "10.0.0.1"), testKey);
    authenticate(first);
    auto second = TestClient(new WorldSession(context, "10.0.0.2"), testKey);
    authenticate(second);

    assert(first.session.wantsClose && !second.session.wantsClose);
    first.session.disconnected();
    assert(context.sessionCount == 1, "closing the kicked session must not remove its replacement");
}


/// In a cluster the character list and login wait for the account grant; an eviction kicks.
unittest
{
    import dmangos.world.player : CharacterData;

    auto db = newDatabase();
    auto context = newContext(db);
    uint[] claimed, released;
    ulong lastSerial;
    context.claimSession = (uint account, ulong serial) { claimed ~= account; lastSerial = serial; };
    context.releaseSession = (uint account, ulong serial) { released ~= account; };

    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    CharacterData c;
    c.guid = 7;
    c.account = db.accounts["PLAYER"].id;
    c.name = "Waiter";
    c.race = 2;    // an orc shaman: what `newContext` can create
    c.classId = 7;
    c.level = 1;
    db.loadable[7] = c;
    authenticate(client);
    assert(claimed == [c.account], "the session claimed its account");

    client.write(Opcode.CMSG_CHAR_ENUM, null);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    assert(client.read().length == 0, "the list and login both wait for the grant");
    context.sessionGranted(c.account, lastSerial + 1);
    assert(client.read().length == 0, "a grant for another session counts for nothing");
    context.sessionGranted(c.account, lastSerial);
    const packets = opcodesOf(client.read());
    assert(packets[0] == Opcode.SMSG_CHAR_ENUM && packets.canFind(Opcode.SMSG_LOGIN_VERIFY_WORLD),
        "the client gets its list, then enters the world once granted");
    assert(client.session.character !is null);

    // Another node takes the account: this session is kicked, and on closing releases it.
    context.sessionEvicted(c.account, lastSerial);
    assert(client.session.wantsClose);
    client.session.disconnected();
    assert(released == [c.account]);
}

/// A player simulated on another node: handed over, relayed both ways, and back to the character screen.
unittest
{
    import core.time : seconds;
    import dmangos.world.context : PlayerRelay;
    import dmangos.world.player : CharacterData;
    import dmangos.world.objects : HighGuid, makeGuid;

    auto db = newDatabase();
    auto home = newContext(db);
    auto owner = newContext(db);
    home.config.cluster.gateway = true;

    // Two nodes joined in memory: what one relays, the other gets at once.
    static final class Pipe : PlayerRelay
    {
        WorldContext homeContext, ownerContext;
        WorldSession remote;
        string[] log;
        void toHome(ushort, uint account, ushort opcode, const(ubyte)[] body_)
        {
            (cast(WorldSession) homeContext.sessionOf(account)).fromOwner(opcode, body_);
        }
        void toOwner(ushort, uint, ushort opcode, const(ubyte)[] body_)
        {
            remote.fromHome(opcode, body_);
        }
        void disconnect(ushort, uint) { remote.clientGone(); }
        void migrate(ushort, uint, const(ubyte)[] state)
        {
            log ~= "migrate";
            remote = new WorldSession(ownerContext, Character.migrationAccount(state), 1);
            assert(remote.arrive(state));
        }
        void left(ushort, uint account, bool toCharacterScreen)
        {
            log ~= "left";
            (cast(WorldSession) homeContext.sessionOf(account)).ownerLeft(toCharacterScreen);
        }
        void remoteDone(uint) { log ~= "done"; }
        void moved(ushort, uint, ushort) { log ~= "moved"; }
    }
    auto pipe = new Pipe;
    pipe.homeContext = home;
    pipe.ownerContext = owner;
    home.playerRelay = owner.playerRelay = pipe;
    home.nodeId = 1;
    owner.nodeId = 2;
    // Everything belongs to node 2: a player simulated on node 1 moves there.
    home.regionOwnerAround = owner.regionOwnerAround = (uint, Position, float) => ushort(2);

    CharacterData c;
    c.guid = 7;
    c.account = db.accounts["PLAYER"].id;
    c.name = "Wanderer";
    c.race = 2; // an orc shaman: what `newContext` can create
    c.classId = 7;
    c.level = 1;
    db.loadable[7] = c;
    auto client = TestClient(new WorldSession(home, "127.0.0.1"), testKey);
    authenticate(client);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();

    // Its ground is node 2's: it moves there as it logs in.
    client.session.update(1.seconds);
    assert(pipe.log == ["migrate"] && client.session.state == WorldState.elsewhere && client.session.owner == 2);
    assert(pipe.remote.state == WorldState.inWorld && owner.onlinePlayer(makeGuid(HighGuid.player, 7)) !is null);
    assert(home.onlinePlayer(makeGuid(HighGuid.player, 7)) is null);

    // The client has its create packet and can ask for its own name while the gateway waits for a route.
    client.session.gatewayPaused = true;
    client.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(c.guid));
    const nameReply = client.read();
    assert(nameReply.length == 1 && nameReply[0].opcode == Opcode.SMSG_NAME_QUERY_RESPONSE,
        "a name query during the gateway handoff must still get a reply");
    auto nameReader = ByteReader(nameReply[0].body_);
    const name = deserialize!ServerNameQueryResponse(nameReader);
    assert(name.guid == c.guid && name.name == c.name && name.race == c.race && name.gender == c.gender
        && name.classId == c.classId);
    client.session.gatewayPaused = false;

    // The client sits down: node 2 handles it, and the answer comes back to the client, encrypted for it.
    client.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    const answer = client.read();
    assert(answer.length >= 1 && opcodesOf(answer).canFind(Opcode.SMSG_STANDSTATE_UPDATE));

    // It logs out there (the 20-second logout, on node 2's clock): node 1's session is back at the character screen.
    auto now = MonoTime.currTime;
    owner.clock = () => now;
    client.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    client.read();
    now += 30.seconds;
    pipe.remote.update(30.seconds);
    client.read();
    assert(pipe.log == ["migrate", "left", "done"]);
    assert(client.session.state == WorldState.characterScreen && client.session.owner == 0);
}

/**
 * A player away from home moving on to a third node: straight there, its home told, the
 * client's packets then going there; and back home from there.
 */
unittest
{
    import core.time : seconds;
    import std.format : format;
    import dmangos.world.context : PlayerRelay;
    import dmangos.world.player : CharacterData;
    import dmangos.world.objects : HighGuid, makeGuid;

    auto db = newDatabase();
    WorldContext[ushort] nodes;
    foreach (ushort id; 1 .. 4)
    {
        nodes[id] = newContext(db);
        nodes[id].nodeId = id;
    }

    // Three nodes joined in memory; each knows which one it is.
    static final class Mesh
    {
        WorldContext[ushort] nodes;
        WorldSession[uint][ushort] remotes; // node -> account -> owner-side session
        string[] log;
    }
    static final class Relay : PlayerRelay
    {
        Mesh mesh;
        ushort self;
        this(Mesh mesh, ushort self) { this.mesh = mesh; this.self = self; }
        void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
        {
            auto session = cast(WorldSession) mesh.nodes[home].sessionOf(account);
            if (session.state == WorldState.elsewhere && session.owner != self)
                session.ownerMoved(self);
            session.fromOwner(opcode, body_);
        }
        void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
        {
            mesh.log ~= format!"to %s"(owner);
            if (auto s = account in mesh.remotes.require(owner, null))
                s.fromHome(opcode, body_);
        }
        void disconnect(ushort owner, uint account) { mesh.remotes[owner][account].clientGone(); }
        void migrate(ushort target, uint account, const(ubyte)[] state)
        {
            mesh.log ~= format!"migrate %s->%s"(self, target);
            if (auto home = cast(WorldSession) mesh.nodes[target].sessionOf(account))
                if (home.state == WorldState.elsewhere)
                {
                    assert(home.arrive(state));
                    return;
                }
            const homeNode = Character.migrationHome(state);
            auto session = new WorldSession(mesh.nodes[target], Character.migrationAccount(state),
                homeNode ? homeNode : self);
            mesh.remotes.require(target, null)[account] = session;
            assert(session.arrive(state));
        }
        void left(ushort home, uint account, bool toCharacterScreen)
        {
            (cast(WorldSession) mesh.nodes[home].sessionOf(account)).ownerLeft(toCharacterScreen);
        }
        void remoteDone(uint account) { mesh.remotes[self].remove(account); }
        void moved(ushort home, uint account, ushort next)
        {
            mesh.log ~= format!"moved %s"(next);
            (cast(WorldSession) mesh.nodes[home].sessionOf(account)).ownerMoved(next);
        }
    }
    auto mesh = new Mesh;
    mesh.nodes = nodes;
    foreach (id, node; nodes)
        node.playerRelay = new Relay(mesh, id);
    // Node 2 owns the ground at first; then node 3; then node 1, the home.
    ushort groundOwner = 2;
    foreach (node; nodes)
        node.regionOwnerAround = (uint, Position, float) => groundOwner;
    auto now = MonoTime.currTime;
    foreach (node; nodes)
        node.clock = () => now;

    CharacterData c;
    c.guid = 7;
    c.account = db.accounts["PLAYER"].id;
    c.name = "Wanderer";
    c.race = 2; // an orc shaman: what `newContext` can create
    c.classId = 7;
    c.level = 1;
    db.loadable[7] = c;
    auto client = TestClient(new WorldSession(nodes[1], "127.0.0.1"), testKey);
    authenticate(client);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();
    const guid = makeGuid(HighGuid.player, 7);

    client.session.update(1.seconds);
    assert(mesh.log == ["migrate 1->2"] && client.session.owner == 2);

    // Node 3's ground now: node 2 hands the player straight to node 3, and the home follows it.
    groundOwner = 3;
    now += 11.seconds;
    mesh.remotes[2][c.account].update(1.seconds);
    assert(mesh.log == ["migrate 1->2", "migrate 2->3", "moved 3"], "no stop at home on the way");
    assert(client.session.owner == 3 && client.session.state == WorldState.elsewhere);
    assert(nodes[3].onlinePlayer(guid) !is null && nodes[2].onlinePlayer(guid) is null);
    auto third = mesh.remotes[3][c.account];
    assert(third.home == 1, "node 3 knows the client is on node 1, not node 2");

    // The client sits: node 3 handles it, and the answer comes to the client from there.
    client.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    assert(mesh.log[$ - 1] == "to 3");
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_STANDSTATE_UPDATE));

    // Home's ground: back home from node 3.
    groundOwner = 1;
    now += 11.seconds;
    third.update(1.seconds);
    assert(mesh.log[$ - 1] == "migrate 3->1" && client.session.state == WorldState.inWorld);
    assert(client.session.owner == 0 && nodes[1].onlinePlayer(guid) !is null);
}

/// Whispers across nodes: to a player another node simulates, checked and delivered by that node.
unittest
{
    import dmangos.cluster.protocol : PresenceEntry;
    import dmangos.world.context : PresenceFlags;
    import dmangos.world.player : CharacterData;
    import dmangos.world.whisper : WhisperFrom;

    auto db = newDatabase();
    auto context = newContext(db);
    ushort sentTo;
    ulong sentGuid;
    WhisperFrom sentFrom;
    context.whisperRemote = (ushort node, ulong guid, WhisperFrom from, string text) {
        sentTo = node;
        sentGuid = guid;
        sentFrom = from;
        assert(text == "hello");
    };
    context.presence(2, true, [PresenceEntry(0x77, "Faraway", 9, 2, 7, 10, 0, 12, PresenceFlags.afk, 0, "brb")], null);
    auto client = loggedIn(context, db, 7, "Whisperer", Position(0, 0, 0), AccountLevel.player, raceOrc, 0, 1,
        (ref CharacterData c) { c.classId = 7; }); // an orc shaman: what `newContext` can load
    assert(client.session.state == WorldState.inWorld);

    client.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "hello", "faraway"));
    assert(client.read().length == 0, "the receiver's node answers, not this one");
    assert(sentTo == 2 && sentGuid == 0x77 && sentFrom.guid == client.session.character.guid && sentFrom.race == 2);

    client.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "hello", "nobody"));
    assert(opcodesOf(client.read()) == [Opcode.SMSG_CHAT_PLAYER_NOT_FOUND]);

    // Node 2 is lost: its players with it.
    context.presenceLost(2);
    client.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "hello", "faraway"));
    assert(opcodesOf(client.read()) == [Opcode.SMSG_CHAT_PLAYER_NOT_FOUND]);
}

/// Whispers from another node: checked where the receiver is, the answers going back to the sender.
unittest
{
    import dmangos.world.player : CharacterData;
    import dmangos.world.whisper : deliverWhisper, WhisperFrom;

    auto db = newDatabase();
    auto context = newContext(db);
    auto gm = loggedIn(context, db, 8, "Keeper", Position(0, 0, 0), AccountLevel.player, raceOrc, 0, 1,
        (ref CharacterData c) { c.classId = 7; });
    (cast(Player) gm.session.character).gmTagOn = true;
    gm.read();

    Opcode[] back;
    auto from = WhisperFrom(0x99, 2, false, 0); // a player on another node
    void whisperTo(TestClient* target)
    {
        back = null;
        deliverWhisper(target.session.inWorld, from, "help", false,
            (ulong sender) => target.session.inWorld.allowsWhispersFrom(sender),
            (ubyte race) => cast(uint) context.client.teamForRace(race), (Opcode op, const(ubyte)[]) { back ~= op; });
    }
    whisperTo(&gm);
    assert(back == [Opcode.SMSG_MESSAGECHAT] && gm.read().length == 0, "the GM's automatic reply, back to the sender");
    gm.session.inWorld.gmTargets[0x99] = true;
    whisperTo(&gm);
    assert(gm.read().length == 1 && back == [Opcode.SMSG_MESSAGECHAT], "allowed: the GM hears it, the sender gets its copy");
}

/**
 * Combat with another node's creature: attacking its replica moves the player to the node that
 * simulates it, where the attack begins; while the fight lasts the player stays there, whoever owns
 * the ground.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import std.format : format;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.context : PlayerRelay, WorldContext;
    import dmangos.world.creature : Creature;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid, ClientPlayerLogin;
    import dmangos.world.player : CharacterData;
    import dmangos.world.replication : encodeState, Replica;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    WorldContext[ushort] nodes;
    foreach (ushort id; 1 .. 3)
    {
        nodes[id] = newCreationContext(db);
        nodes[id].nodeId = id;
    }
    static final class Mesh
    {
        WorldContext[ushort] nodes;
        WorldSession[uint][ushort] remotes;
        string[] log;
    }
    static final class Relay : PlayerRelay
    {
        Mesh mesh;
        ushort self;
        this(Mesh mesh, ushort self) { this.mesh = mesh; this.self = self; }
        void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
        {
            auto session = cast(WorldSession) mesh.nodes[home].sessionOf(account);
            session.fromOwner(opcode, body_);
        }
        void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
        {
            if (auto s = account in mesh.remotes.require(owner, null))
                s.fromHome(opcode, body_);
        }
        void disconnect(ushort owner, uint account) { mesh.remotes[owner][account].clientGone(); }
        void migrate(ushort target, uint account, const(ubyte)[] state)
        {
            mesh.log ~= format!"migrate %s->%s"(self, target);
            const homeNode = Character.migrationHome(state);
            auto session = new WorldSession(mesh.nodes[target], Character.migrationAccount(state),
                homeNode ? homeNode : self);
            mesh.remotes.require(target, null)[account] = session;
            assert(session.arrive(state));
        }
        void left(ushort home, uint account, bool toCharacterScreen) {}
        void remoteDone(uint account) { mesh.remotes[self].remove(account); }
        void moved(ushort home, uint account, ushort next) {}
    }
    auto mesh = new Mesh;
    mesh.nodes = nodes;
    foreach (id, node; nodes)
    {
        node.playerRelay = new Relay(mesh, id);
        node.regionOwnerAround = (uint, Position, float) => ushort(1); // node 1's ground throughout
    }
    auto now = MonoTime.currTime;
    foreach (node; nodes)
        node.clock = () => now;

    CharacterData c;
    c.guid = 7;
    c.account = db.accounts["PLAYER"].id;
    c.name = "Wanderer";
    c.race = 1; // a human warrior: what `newCreationContext` has
    c.classId = 1;
    c.level = 1;
    c.position = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    db.loadable[7] = c;
    auto client = TestClient(new WorldSession(nodes[1], "127.0.0.1"), testKey);
    authenticate(client);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();

    // The innkeeper, an enemy, simulated by node 2; node 1 holds a replica of it.
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const cell = cellKeyAt(-8951, -130);
    nodes[2].map(0).peerInterest(1, [cell], null);
    auto owned = cast(Creature) nodes[2].map(0).findObject(innkeeper);
    assert(owned !is null);
    const monsters = 8u;
    nodes[2].client.factionTemplates = typeof(nodes[2].client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[1u, 1, 0, 1 | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, 1 | 2, 0, 0, 0, 0, 0,
        0, 0, 0]]), "FactionTemplate.dbc");
    owned.factionTemplate = nodes[2].client.factionTemplates.lookup(14);
    nodes[1].map(0).removeObject(innkeeper);
    nodes[1].map(0).replicaCreated(owner: 2, cell: cell, guid: innkeeper, encodeState(owned, 0));
    assert(cast(Replica) nodes[1].map(0).findObject(innkeeper) !is null);

    // Attacking the replica: the player moves to node 2, and the attack begins there.
    client.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    assert(mesh.log == ["migrate 1->2"], "moved to the creature's node");
    auto there = mesh.remotes[2][c.account];
    there.update(50.msecs);
    assert(there.inWorld.attacking == innkeeper && owned.ai.inCombat, "fighting there");

    // The ground is node 1's, but the fight keeps the player on node 2.
    now += 11.seconds;
    there.update(1.seconds);
    assert(mesh.log == ["migrate 1->2"], "no move while fighting");
}

/**
 * Noticed by another node's creature: an enemy whose replica is near the player when it moves (within
 * its aggro radius) moves the player to the creature's node, where the creature attacks; and not
 * again for the same creature within 30 seconds.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import std.format : format;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.context : PlayerRelay, WorldContext;
    import dmangos.world.creature : Creature;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid, ClientPlayerLogin;
    import dmangos.world.player : CharacterData;
    import dmangos.world.replication : encodeState, Replica;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    WorldContext[ushort] nodes;
    foreach (ushort id; 1 .. 3)
    {
        nodes[id] = newCreationContext(db);
        nodes[id].nodeId = id;
    }
    static final class Mesh
    {
        WorldContext[ushort] nodes;
        WorldSession[uint][ushort] remotes;
        string[] log;
    }
    static final class Relay : PlayerRelay
    {
        Mesh mesh;
        ushort self;
        this(Mesh mesh, ushort self) { this.mesh = mesh; this.self = self; }
        void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
        {
            auto session = cast(WorldSession) mesh.nodes[home].sessionOf(account);
            session.fromOwner(opcode, body_);
        }
        void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
        {
            if (auto s = account in mesh.remotes.require(owner, null))
                s.fromHome(opcode, body_);
        }
        void disconnect(ushort owner, uint account) { mesh.remotes[owner][account].clientGone(); }
        void migrate(ushort target, uint account, const(ubyte)[] state)
        {
            mesh.log ~= format!"migrate %s->%s"(self, target);
            const homeNode = Character.migrationHome(state);
            auto session = new WorldSession(mesh.nodes[target], Character.migrationAccount(state),
                homeNode ? homeNode : self);
            mesh.remotes.require(target, null)[account] = session;
            assert(session.arrive(state));
        }
        void left(ushort home, uint account, bool toCharacterScreen) {}
        void remoteDone(uint account) { mesh.remotes[self].remove(account); }
        void moved(ushort home, uint account, ushort next) {}
    }
    auto mesh = new Mesh;
    mesh.nodes = nodes;
    foreach (id, node; nodes)
    {
        node.playerRelay = new Relay(mesh, id);
        node.regionOwnerAround = (uint, Position, float) => ushort(1); // node 1's ground throughout
    }
    auto now = MonoTime.currTime;
    foreach (node; nodes)
        node.clock = () => now;

    CharacterData c;
    c.guid = 7;
    c.account = db.accounts["PLAYER"].id;
    c.name = "Wanderer";
    c.race = 1; // a human warrior: what `newCreationContext` has
    c.classId = 1;
    c.level = 1;
    c.position = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    db.loadable[7] = c;
    auto client = TestClient(new WorldSession(nodes[1], "127.0.0.1"), testKey);
    authenticate(client);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();
    const monsters = 8u, humans = client.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    foreach (node; nodes)
        node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[humans, 1, 0, 1 | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, 1 | 2, 0, 0, 0,
            0, 0, 0, 0, 0]]), "FactionTemplate.dbc");

    // The innkeeper, an enemy, simulated by node 2; node 1 holds a replica of it.
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const cell = cellKeyAt(-8951, -130);
    nodes[2].map(0).peerInterest(1, [cell], null);
    auto owned = cast(Creature) nodes[2].map(0).findObject(innkeeper);
    assert(owned !is null);
    owned.factionTemplate = nodes[2].client.factionTemplates.lookup(14);
    owned.values.set!UNIT_FIELD_FACTIONTEMPLATE(14u);
    foreach (node; nodes)
        node.data.creatureTemplates.edit(creatureInnkeeper).detection = 20;
    nodes[1].map(0).removeObject(innkeeper);
    nodes[1].map(0).replicaCreated(owner: 2, cell: cell, guid: innkeeper, encodeState(owned, 0));
    assert(cast(Replica) nodes[1].map(0).findObject(innkeeper) !is null);
    const second = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn + 1);
    nodes[1].map(0).replicaCreated(owner: 2, cell: cell, guid: second, encodeState(owned, 0));

    // The player moves near it: node 1 judges the creature would notice it, and it moves to node 2.
    auto moving = client.session.inWorld;
    nodes[1].map(0).refreshVisibility(moving);
    const movement = moving.character.movement;
    moving.movedOn(movement, Opcode.MSG_MOVE_HEARTBEAT);
    assert(mesh.log == ["migrate 1->2"], "moved to the creature's node");
    auto there = mesh.remotes[2][c.account];
    there.update(50.msecs);
    assert(owned.ai.inCombat && owned.ai.currentVictim == 7, "noticed, and attacked, there");
}
