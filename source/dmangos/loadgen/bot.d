/**
 * One headless 1.12 client of the load generator: it authenticates with a session key the
 * generator put in the login database, creates or picks its character, enters the world, and then
 * plays the part of a player: running between points, stopping, saying something now and then and
 * pinging every 30 seconds (the fastest the server allows), as the real client does. Everything the
 * server sends is read, decrypted and counted, but not otherwise looked at.
 *
 * Bots never block: `Bot.receive` takes whatever arrived and `Bot.update` whatever is due, and
 * `output` collects what to send; `dmangos.loadgen.main` moves the bytes.
 */
module dmangos.loadgen.bot;

import core.time : Duration, MonoTime, msecs, seconds;
import std.math : atan2, cos, sin, sqrt;
import std.random : Random, uniform, uniform01;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.crypto.hash : sha1;
import dmangos.crypto.srp6 : sessionKeyLength;
import dmangos.serialization : serialize;
import dmangos.world.addons : ClientAddon, makeAddonBlock, standardAddonCrc;
import dmangos.world.crypt : CipherState;
import dmangos.world.movement : MovementFlags, MovementInfo, Position;
import dmangos.world.opcodes : AuthResponse, CharacterResponse, Opcode;
import dmangos.world.packets : ClientAuthSession, ClientCharCreate, ClientPlayerLogin;

/// How bots move once in the world.
enum Behaviour
{
    wander, /// run between random points within `radius` of where they entered
    travel, /// run `radius` yards out and back along a line, crossing cells and sight
    idle,   /// stand still
}

/// What every bot does; the generator's options.
struct BotPlan
{
    bool createOnly;          /// create the character and leave
    Behaviour behaviour = Behaviour.wander;
    float radius = 30;
    float speed = 6.5f;       /// yards a second: under running speed, so the speed check passes
    Duration chatEvery;       /// mean time between says; zero for none
    string[] commands;        /// said one after another (GM commands), `commandEvery` apart
    Duration commandEvery = 3.seconds; /// ditto
    bool trace;               /// print every packet received
}

/// What a bot measured.
struct BotStats
{
    ulong packetsIn, bytesIn, packetsOut, bytesOut;
    Duration loginTime;       /// from connecting to `SMSG_LOGIN_VERIFY_WORLD`
    Duration[] pings;         /// round trips of `CMSG_PING`
    string failure;           /// why it stopped, if it did
}

/// See the module documentation.
final class Bot
{
    enum State
    {
        challenge,
        authResponse,
        enumerated,
        created,
        loggingIn,
        inWorld,
        done,
    }

    immutable uint index;
    string account;
    string characterName;
    ubyte[sessionKeyLength] key;
    BotStats stats;

    private
    {
        BotPlan plan;
        Random rng;
        State state_ = State.challenge;
        CipherState sending, receiving;
        bool encrypted;
        ubyte[] inbox;
        ubyte[4] pendingHeader;   // a decrypted header whose body has not all arrived
        bool headerDecrypted;
        ByteWriter outbox;

        MonoTime connectedAt, lastUpdate;
        uint clockMs;             // the bot's own client clock
        Position at, anchor, target;
        uint map;
        bool moving;
        MonoTime nextMove, nextHeartbeat, nextChat, nextPing;
        uint pingSequence;
        MonoTime pingSentAt;
        bool travellingOut = true;
        size_t commandsSaid;
        MonoTime nextCommand;
    }

    ///
    this(uint index, string account, string characterName, const ubyte[sessionKeyLength] key, BotPlan plan, uint seed)
    {
        this.index = index;
        this.account = account;
        this.characterName = characterName;
        this.key = key;
        this.plan = plan;
        rng = Random(seed);
    }

    ///
    @property State state() const
    {
        return state_;
    }

    /// The connection is open (the clock for the login time starts).
    void connected(MonoTime now)
    {
        connectedAt = lastUpdate = now;
    }

    /// Bytes to send; the bot forgets them.
    const(ubyte)[] output()
    {
        auto bytes = outbox.data.dup;
        outbox.clear();
        stats.bytesOut += bytes.length;
        return bytes;
    }

    /// The bot gives up.
    void fail(string why)
    {
        if (state_ != State.done)
            stats.failure = why;
        state_ = State.done;
    }

    /// Bytes from the server.
    void receive(const(ubyte)[] data, MonoTime now)
    {
        stats.bytesIn += data.length;
        inbox ~= data;
        size_t used;
        while (state_ != State.done)
        {
            if (inbox.length - used < 4)
                break;
            if (!headerDecrypted)
            {
                pendingHeader = inbox[used .. used + 4];
                if (encrypted)
                    receiving.decrypt(pendingHeader[], key);
                headerDecrypted = true;
            }
            const size = (pendingHeader[0] << 8 | pendingHeader[1]) - 2;
            if (inbox.length - used < 4 + size)
                break;
            const opcode = cast(ushort)(pendingHeader[2] | pendingHeader[3] << 8);
            const body_ = inbox[used + 4 .. used + 4 + size];
            used += 4 + size;
            headerDecrypted = false;
            ++stats.packetsIn;
            handle(opcode, body_, now);
        }
        inbox = inbox[used .. $].dup;
    }

    /// Movement, chat and pings that are due.
    void update(MonoTime now)
    {
        const elapsed = now - lastUpdate;
        lastUpdate = now;
        clockMs += cast(uint) elapsed.total!"msecs";
        if (state_ != State.inWorld)
            return;

        if (moving)
        {
            const step = plan.speed * elapsed.total!"usecs" / 1e6f;
            const dx = target.x - at.x, dy = target.y - at.y;
            const left = sqrt(dx * dx + dy * dy);
            if (left <= step)
            {
                at.x = target.x;
                at.y = target.y;
                moving = false;
                sendMove(Opcode.MSG_MOVE_STOP, MovementFlags.none);
                nextMove = now + uniform(0, 3000, rng).msecs;
            }
            else
            {
                at.x += dx / left * step;
                at.y += dy / left * step;
                if (now >= nextHeartbeat)
                {
                    sendMove(Opcode.MSG_MOVE_HEARTBEAT, MovementFlags.forward);
                    nextHeartbeat = now + 500.msecs;
                }
            }
        }
        else if (plan.behaviour != Behaviour.idle && now >= nextMove)
        {
            chooseTarget();
            at.orientation = atan2(target.y - at.y, target.x - at.x);
            moving = true;
            sendMove(Opcode.MSG_MOVE_START_FORWARD, MovementFlags.forward);
            nextHeartbeat = now + 500.msecs;
        }

        if (commandsSaid < plan.commands.length && now >= nextCommand)
        {
            import std.stdio : writefln;

            const text = plan.commands[commandsSaid++];
            if (plan.trace)
                writefln!"%s > %s"(account, text);
            ByteWriter say;
            say.put(uint(0)); // CHAT_MSG_SAY
            say.put(uint(7)); // LANG_COMMON
            say.putCString(text);
            send(Opcode.CMSG_MESSAGECHAT, say.data);
            nextCommand = now + plan.commandEvery;
        }
        if (plan.chatEvery > Duration.zero && now >= nextChat)
        {
            ByteWriter say;
            say.put(uint(0)); // CHAT_MSG_SAY
            say.put(uint(7)); // LANG_COMMON
            say.putCString("load test");
            send(Opcode.CMSG_MESSAGECHAT, say.data);
            nextChat = now + randomInterval(plan.chatEvery);
        }
        if (now >= nextPing)
        {
            ByteWriter ping;
            ping.put(++pingSequence);
            ping.put(uint(0)); // latency
            send(Opcode.CMSG_PING, ping.data);
            pingSentAt = now;
            nextPing = now + 30.seconds;
        }
    }

private:
    void handle(ushort opcode, const(ubyte)[] body_, MonoTime now)
    {
        if (plan.trace && state_ == State.inWorld)
        {
            import std.conv : to;
            import std.stdio : writefln;

            const name = () { try return (cast(Opcode) opcode).to!string; catch (Exception) return opcode.to!string; }();
            writefln!"%s < %s (%s bytes) %(%02x %)"(account, name, body_.length, body_[0 .. body_.length < 24 ? $ : 24]);
        }
        switch (opcode)
        {
        case Opcode.SMSG_AUTH_CHALLENGE:
            if (state_ != State.challenge)
                return;
            authenticate(ByteReader(body_).read!uint);
            state_ = State.authResponse;
            break;
        case Opcode.SMSG_AUTH_RESPONSE:
            if (body_.length == 0 || body_[0] != AuthResponse.AUTH_OK)
                return fail(body_.length && body_[0] == AuthResponse.AUTH_WAIT_QUEUE ? "queued" : "authentication refused");
            send(Opcode.CMSG_CHAR_ENUM, null);
            state_ = State.enumerated;
            break;
        case Opcode.SMSG_CHAR_ENUM:
            if (body_.length == 0)
                return fail("bad character list");
            if (body_[0] == 0)
            {
                ByteWriter create;
                serialize(create, ClientCharCreate(characterName, 1, 1, 0, 0, 0, 1, 0, 0, 0)); // human warrior
                send(Opcode.CMSG_CHAR_CREATE, create.data);
                state_ = State.created;
            }
            else if (plan.createOnly)
                state_ = State.done;
            else
            {
                ByteWriter login;
                serialize(login, ClientPlayerLogin(ByteReader(body_[1 .. 9]).read!ulong));
                send(Opcode.CMSG_PLAYER_LOGIN, login.data);
                state_ = State.loggingIn;
            }
            break;
        case Opcode.SMSG_CHAR_CREATE:
            if (body_.length == 0 || body_[0] != CharacterResponse.CHAR_CREATE_SUCCESS)
                return fail("character not created");
            if (plan.createOnly)
                state_ = State.done;
            else
            {
                send(Opcode.CMSG_CHAR_ENUM, null);
                state_ = State.enumerated;
            }
            break;
        case Opcode.SMSG_CHARACTER_LOGIN_FAILED:
            fail("login failed");
            break;
        case Opcode.SMSG_LOGIN_VERIFY_WORLD:
            auto r = ByteReader(body_);
            map = r.read!uint;
            at = Position(r.read!float, r.read!float, r.read!float, r.read!float);
            anchor = at;
            stats.loginTime = now - connectedAt;
            state_ = State.inWorld;
            nextMove = now + uniform(0, 2000, rng).msecs;
            nextChat = now + (plan.chatEvery > Duration.zero ? randomInterval(plan.chatEvery) : Duration.zero);
            nextPing = now + uniform(0, 30_000, rng).msecs;
            break;
        case Opcode.SMSG_NEW_WORLD:
            // A teleport to another map: acknowledged as the client does once it has loaded it.
            auto r = ByteReader(body_);
            map = r.read!uint;
            at = Position(r.read!float, r.read!float, r.read!float, r.read!float);
            moving = false;
            send(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
            break;
        case Opcode.SMSG_PONG:
            if (pingSentAt != MonoTime.init)
                stats.pings ~= now - pingSentAt;
            break;
        case Opcode.MSG_MOVE_TELEPORT_ACK:
            // Put back by the speed check (or a GM): acknowledge as the client does, and go on from there.
            auto r = ByteReader(body_);
            const guid = r.readPackedGuid();
            const counter = r.read!uint;
            const info = MovementInfo.read(r);
            ByteWriter ack;
            ack.put(guid);
            ack.put(counter);
            ack.put(clockMs);
            send(Opcode.MSG_MOVE_TELEPORT_ACK, ack.data);
            at = info.position;
            moving = false;
            break;
        default:
            break;
        }
    }

    void authenticate(uint serverSeed)
    {
        import std.bitmanip : nativeToLittleEndian;

        ClientAuthSession request;
        request.build = 5875;
        request.account = account;
        request.clientSeed = uniform!uint(rng);
        const uint zero = 0;
        request.digest = sha1(account, nativeToLittleEndian(zero), nativeToLittleEndian(request.clientSeed),
            nativeToLittleEndian(serverSeed), key);
        request.addonData = makeAddonBlock([ClientAddon("Blizzard_RaidUI", 1, standardAddonCrc, 0)]);
        ByteWriter w;
        serialize(w, request);
        send(Opcode.CMSG_AUTH_SESSION, w.data);
        encrypted = true; // everything after the session packet is encrypted, both ways
    }

    void chooseTarget()
    {
        final switch (plan.behaviour)
        {
        case Behaviour.wander:
            const angle = uniform01(rng) * 2 * 3.14159265f;
            const range = uniform01(rng) * plan.radius;
            target = Position(anchor.x + range * cos(angle), anchor.y + range * sin(angle), anchor.z, 0);
            break;
        case Behaviour.travel:
            target = Position(anchor.x + (travellingOut ? plan.radius : 0), anchor.y, anchor.z, 0);
            travellingOut = !travellingOut;
            break;
        case Behaviour.idle:
            break;
        }
    }

    void sendMove(Opcode opcode, uint flags)
    {
        MovementInfo info;
        info.flags = flags;
        info.time = clockMs;
        info.position = at;
        ByteWriter w;
        info.write(w);
        send(opcode, w.data);
    }

    Duration randomInterval(Duration mean)
    {
        import std.math : log;

        // Exponential: says come as from independent players, not in lockstep.
        const u = uniform01(rng);
        return (cast(long)(-log(1 - u) * mean.total!"msecs")).msecs;
    }

    void send(uint opcode, const(ubyte)[] body_)
    {
        ubyte[6] header;
        const size = body_.length + 4;
        header[0] = cast(ubyte)(size >> 8);
        header[1] = cast(ubyte) size;
        header[2] = cast(ubyte) opcode;
        header[3] = cast(ubyte)(opcode >> 8);
        header[4] = header[5] = 0;
        if (encrypted)
            sending.encrypt(header[], key);
        outbox.putBytes(header[]);
        outbox.putBytes(body_);
        ++stats.packetsOut;
    }
}

/**
 * A character name of letters only, as the name rules want: up to five letters of the prefix
 * ("Loadb"), then the index in base 26 ("Loadbbaf").
 */
string characterName(string prefix, uint index)
{
    import std.ascii : isAlpha, toLower, toUpper;

    char[] name;
    foreach (c; prefix)
        if (isAlpha(c) && name.length < 5)
            name ~= name.length ? toLower(c) : toUpper(c);
    if (name.length == 0)
        name = "Lb".dup;
    char[] letters;
    do
    {
        letters = cast(char)('a' + index % 26) ~ letters;
        index /= 26;
    }
    while (index);
    return cast(string)(name ~ letters);
}

unittest
{
    assert(characterName("LOADBOT", 0) == "Loadba" && characterName("LOADBOT", 27) == "Loadbbb");
    assert(characterName("x1", 25) == "Xz" && characterName("12", 1) == "Lbb");
}
