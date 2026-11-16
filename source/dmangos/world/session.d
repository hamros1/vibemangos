/**
 * One client's connection to the world server.
 *
 * Like the login session, `WorldSession` does no I/O. It takes the bytes
 * that arrive and produces the bytes to send, so the unit tests below play
 * a whole client conversation without sockets.
 *
 * The handshake follows CMaNGOS `Server/WorldSocket.cpp`:
 * $(OL
 *   $(LI the server sends `SMSG_AUTH_CHALLENGE` with a random seed;)
 *   $(LI the client answers `CMSG_AUTH_SESSION` with SHA1(account, 0, its seed, the server seed, K),
 *        where K is the session key the login server stored in `account.sessionkey`;)
 *   $(LI from then on, every header is encrypted with K (`dmangos.world.crypt`);)
 *   $(LI the server replies `SMSG_ADDON_INFO` and `SMSG_AUTH_RESPONSE` (AUTH_OK).)
 * )
 * The client is then on the character screen, where characters can be listed,
 * created (`dmangos.world.playercreate`) and deleted, with CMaNGOS's checks from
 * `Entities/CharacterHandler.cpp`.
 *
 * `CMSG_PLAYER_LOGIN` enters the world (`WorldSession::HandlePlayerLogin`).
 *
 * The handlers are grouped as CMaNGOS groups them in its `*Handler.cpp` files,
 * one module per group, each a mixin template that `WorldSession` mixes in:
 * $(UL
 *   $(LI `dmangos.world.charscreen`: the character list, creation, deletion and logging in;)
 *   $(LI `dmangos.world.inworld`: logging out, movement, queries, chat and settings.)
 * )
 * A mixed-in handler is a member of `WorldSession`, with the same access to its
 * state as the handlers here, and `PacketDispatch` finds it like any other.
 */
module dmangos.world.session;

import core.time : MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.bitmanip : nativeToLittleEndian;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes;
import dmangos.crypto.hash : constantTimeEqual, sha1;
import dmangos.crypto.random : secureRandom;
import dmangos.log;
import dmangos.net.dispatch : DispatchResult, HandlesFor = Handles, PacketDispatch;
import dmangos.net.server : NetSession;
import dmangos.world.addons : buildAddonInfo, parseAddons;
import dmangos.world.channelhandlers : ChannelHandlers;
import dmangos.world.charscreen : CharacterScreenHandlers;
import dmangos.world.commands : ChatCommands;
import dmangos.world.grouphandlers : GroupHandlers;
import dmangos.world.inworld : InWorldHandlers;
import dmangos.world.teleport : Teleport, TeleportHandlers;
import dmangos.world.context : Kickable, WorldContext;
import dmangos.world.crypt : clientHeaderLength, HeaderCrypt;
import dmangos.world.database : WorldAccount;
import dmangos.world.objects : UpdateData, UpdatePacket;
import dmangos.world.map : deliverUpdate, Inhabitant, Map;
import dmangos.world.movement : Position;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.player : Player, PlayerFlags, Viewer;
import dmangos.world.queries : chatMessage;
import dmangos.world.opcodes;
import dmangos.world.packets;

/// Where a session is in the protocol.
enum WorldState
{
    awaitingAuth,    /// challenge sent, waiting for CMSG_AUTH_SESSION
    characterScreen, /// authenticated; the client shows its character list
    inWorld,         /// playing a character
    closed,
}

private alias Handles = HandlesFor!(Opcode, WorldState);

/// Pings closer together than this count as over-speed (CMaNGOS: 27 seconds).
private enum minimumPingInterval = 27.seconds;

/// The most unprocessed input buffered: two maximum-size packets.
private enum maxBufferedInput = 2 * (clientHeaderLength + maxClientPacketSize);

/// See the module documentation.
final class WorldSession : NetSession, Kickable, OnlinePlayer
{
    mixin PacketDispatch!Handles;

    private
    {
        WorldContext context;
        string remoteAddress;
        WorldState state_ = WorldState.awaitingAuth;
        bool finishing;
        bool registered; // listed in the context's session table
        ubyte[] input;
        ubyte[] output;
        HeaderCrypt crypt;
        uint serverSeed;

        // A decrypted header whose body has not fully arrived yet. Headers are
        // decrypted exactly once, because decryption advances the key stream.
        bool haveHeader;
        uint bodyLength;
        uint pendingOpcode;

        WorldAccount account;
        uint build;
        MonoTime lastPing;
        bool pinged;
        uint overspeedPings;
        uint latency;
        bool tutorialRowMissing; // the account's character_tutorial row is written with its first character

        Player player;           // while in the world
        MonoTime enteredWorld;

        // Teleports (`Player::m_teleport_dest`, the teleport semaphores) and the order counter of
        // MSG_MOVE_TELEPORT_ACK.
        Teleport teleporting;
        uint moveOrderCounter;
        bool gameMaster;          // `.gm on`: requirements and checks do not apply
        uint recallMap;           // where `.recall` goes: the place before the last command teleport
        Position recallPosition;

        // The movement check: where the player was, and when.
        Position checkpoint;
        MonoTime checkpointTime;
        Position groupPositionAt; // where group members out of sight last heard the player was
    }

    invariant
    {
        assert(state_ != WorldState.characterScreen && state_ != WorldState.inWorld
            || (crypt.active && account.hasSessionKey),
            "an authenticated session always encrypts with its account's session key");
        assert((state_ == WorldState.inWorld) == (player !is null), "a player exists exactly while in the world");
        assert(input.length <= maxBufferedInput);
    }

    /// Starts a session and queues `SMSG_AUTH_CHALLENGE`.
    this(WorldContext context, string remoteAddress)
    in (context !is null)
    {
        this.context = context;
        this.remoteAddress = remoteAddress;
        const seed = secureRandom!4;
        serverSeed = seed[0] | seed[1] << 8 | seed[2] << 16 | seed[3] << 24;
        send(ServerAuthChallenge(serverSeed));
    }

    /// Current protocol state.
    @property WorldState state() const
    {
        return state_;
    }

    /// The client's address.
    @property string address() const
    {
        return remoteAddress;
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

                const size = header[0] << 8 | header[1]; // big-endian, counts the 4-byte opcode
                pendingOpcode = header[2] | header[3] << 8 | header[4] << 16 | header[5] << 24;
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
            handle(cast(Opcode) pendingOpcode, reader);
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

    /// The character being played, if any.
    @property const(Player) character() const
    {
        return player;
    }

    /// Frames a packet another player's session (or the map) sends to this client.
    void deliver(Opcode opcode, const(ubyte)[] body_)
    {
        if (!wantsClose)
            output ~= encodePacket(opcode, body_, crypt);
    }

    /// The create block a player who just came into sight gets: group mates see real health.
    UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
    {
        return player.createForOthers(serverTime, context.groups.sameGroup(player.guid, viewer.character.guid));
    }

    /// The account's level.
    @property AccountLevel security() const
    {
        return account.level;
    }

    /// Between `SMSG_NEW_WORLD` and the client's `MSG_MOVE_WORLDPORT_ACK`.
    @property bool transferring() const
    {
        return teleporting == Teleport.far;
    }

    /// The group changed: the leader flag, and the health the players around see and are seen with.
    void groupChanged()
    {
        if (player is null)
            return;
        updateLeaderFlag();
        if (transferring)
            return;
        foreach (watcher; map.watchers(this))
        {
            const mates = context.groups.sameGroup(player.guid, watcher.character.guid);
            const view = mates ? Viewer.groupMate : Viewer.stranger;
            deliverUpdate(watcher, player.groupView(view));
            deliverUpdate(this, watcher.character.groupView(view));
        }
    }

    /// Saves the character if one is being played, and removes the session from the context's table.
    void disconnected()
    {
        if (player !is null)
            leaveWorld("disconnected", false);
        if (registered)
            context.removeSession(account.id, this);
        registered = false;
        state_ = WorldState.closed;
    }

    /// Ends the session, e.g. because the account logged in again.
    void kick(string reason)
    {
        info!"%s: '%s' kicked: %s"(remoteAddress, account.username, reason);
        disconnect();
    }

private:
    void handle(Opcode opcode, ref ByteReader reader)
    {
        DispatchResult result;
        try
            result = dispatchPacket(opcode, state_, reader);
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
                // As CMaNGOS: nothing but CMSG_AUTH_SESSION is accepted before authentication.
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
        output ~= encodePacket(packet, crypt);
    }

    void finish()
    {
        finishing = true;
    }

    void disconnect()
    {
        if (player !is null)
            leaveWorld("disconnected", false);
        state_ = WorldState.closed;
    }

    void sendUpdate(const ref UpdateData update)
    {
        const packet = update.build();
        if (packet.compressed)
            send(ServerCompressedUpdateObject(cast(ubyte[]) packet.body_));
        else
            send(ServerUpdateObject(cast(ubyte[]) packet.body_));
    }

    /// `Player::UpdateGroupLeaderFlag`
    void updateLeaderFlag()
    {
        auto group = context.groups.of(player.guid);
        player.setFlag(PlayerFlags.groupLeader, group !is null && group.isLeader(player.guid));
        flushPlayerChanges();
    }

    /**
     * Sends the player's changed fields to itself, and to each player who sees it the fields it may
     * see: group mates and strangers see different health values.
     */
    void flushPlayerChanges()
    {
        UpdateData forSelf;
        if (player.addChanges(forSelf, Viewer.self))
            sendUpdate(forSelf);
        UpdatePacket[Viewer] built;
        foreach (watcher; transferring ? null : map.watchers(this))
        {
            const view = context.groups.sameGroup(player.guid, watcher.character.guid) ? Viewer.groupMate
                : Viewer.stranger;
            if (view !in built)
            {
                UpdateData update;
                built[view] = player.addChanges(update, view) ? update.build() : UpdatePacket.init;
            }
            const packet = built[view];
            if (packet.body_.length)
                watcher.deliver(packet.compressed ? Opcode.SMSG_COMPRESSED_UPDATE_OBJECT : Opcode.SMSG_UPDATE_OBJECT,
                    packet.body_);
        }
        player.clearChanges();
    }

    /// The map the player is on.
    @property Map map()
    in (player !is null)
    {
        return context.map(player.data.map);
    }

    /// Milliseconds on the server's clock, as movement packets carry them.
    uint serverTime()
    {
        return context.serverTime();
    }

    /// Seconds since the character entered the world.
    uint secondsInWorld()
    {
        return cast(uint)(context.clock() - enteredWorld).total!"seconds";
    }

    void sendSystemMessage(string text)
    {
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text)));
    }

    /// `WorldSession::SendNotification`: a message in the middle of the screen.
    void sendNotification(string text)
    {
        send(ServerNotification(text));
    }

    /// Replies with an error and closes, as CMaNGOS does for every failed check.
    void refuse(AuthResponse response, string reason)
    {
        info!"%s: world login refused (%s): %s"(remoteAddress, response, reason);
        send(ServerAuthFailure(response));
        finish();
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

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

        // CMaNGOS closes without a reply for operating systems and platforms it does not know.
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
        const addons = parseAddons(request.addonData); // a malformed list disconnects, as in CMaNGOS

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
    mixin InWorldHandlers;
    mixin TeleportHandlers;
    mixin GroupHandlers;
    mixin ChannelHandlers;
    mixin ChatCommands;
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

