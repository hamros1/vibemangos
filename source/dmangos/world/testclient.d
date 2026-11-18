/**
 * A scripted world client for the session tests: it frames and encrypts its
 * packets like a 1.12 client, holds its half of the header cipher, and reads
 * the server's replies. Also the fixtures every session test starts from.
 */
module dmangos.world.testclient;

version (unittest):

// What every session test speaks: importing this module is enough to write one.
public import std.algorithm.searching : canFind;
public import dmangos.auth.accounts : AccountLevel;
public import dmangos.world.context : WorldContext;
public import dmangos.world.movement : MovementFlags, MovementInfo, Position;
public import dmangos.bytes;
public import dmangos.crypto.srp6 : sessionKeyLength;
public import dmangos.serialization : deserialize, serialize;
public import dmangos.world.config : WorldConfig;
public import dmangos.world.database : CharacterRecord, MemoryWorldDatabase;
public import dmangos.world.names : CharNameResult;
public import dmangos.world.opcodes;
public import dmangos.world.packets;
public import dmangos.world.session : WorldSession, WorldState;
public import dmangos.world.testdata;

import std.bitmanip : bigEndianToNative, littleEndianToNative, nativeToBigEndian, nativeToLittleEndian;

import dmangos.crypto.hash : sha1;
import dmangos.log;
import dmangos.world.addons : ClientAddon, makeAddonBlock, standardAddonCrc;
import dmangos.world.crypt : CipherState;
import dmangos.world.database : WorldAccount;
import dmangos.world.worlddata : ItemTemplate, PlayerInfo, WorldData;
import dmangos.world.player : CharacterData;

struct ServerPacketRead
{
    ushort opcode;
    ubyte[] body_;
}

/**
 * What a client knows of objects' fields: the values the update packets it was sent gave them. The decoding is
 * written from the client's format, not from `dmangos.world.objects`, so a field the server forgets to send
 * shows up as a difference (`assertSeesItself`).
 */
struct ClientView
{
    uint[size_t][ulong] fields; /// guid -> field -> value

    /// Applies an `SMSG_UPDATE_OBJECT` or `SMSG_COMPRESSED_UPDATE_OBJECT`.
    void apply(ushort opcode, const(ubyte)[] body_)
    {
        import std.zlib : uncompress;

        if (opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
        {
            auto sized = ByteReader(body_);
            const size = sized.read!uint;
            body_ = cast(const(ubyte)[]) uncompress(body_[4 .. $], size);
            assert(body_.length == size);
        }
        auto r = ByteReader(body_);
        const count = r.read!uint;
        r.read!ubyte; // has a transport
        foreach (_; 0 .. count)
        {
            const kind = r.read!ubyte;
            if (kind == 4 || kind == 5) // out of range, near objects: a list of guids
            {
                foreach (__; 0 .. r.read!uint)
                {
                    const gone = packedGuid(r);
                    if (kind == 4)
                        fields.remove(gone);
                }
                continue;
            }
            const guid = packedGuid(r);
            if (kind == 2 || kind == 3)
            {
                r.read!ubyte; // the type id
                skipMovement(r);
                fields.remove(guid); // created anew: what was known is replaced
            }
            assert(kind <= 3, "an update block of an unknown kind");
            const blocks = r.read!ubyte;
            uint[] masks;
            foreach (__; 0 .. blocks)
                masks ~= r.read!uint;
            auto known = guid in fields;
            if (known is null)
            {
                fields[guid] = null;
                known = guid in fields;
            }
            foreach (i; 0 .. blocks * 32)
                if (masks[i / 32] & (1u << (i % 32)))
                    (*known)[i] = r.read!uint;
        }
        assert(r.remaining == 0, "bytes left over after the update blocks");
    }

    /// Field `slot` of `guid` as the client has it (0 if never sent).
    uint opIndex(ulong guid, size_t slot) const
    {
        if (auto known = guid in fields)
            return (*known).get(slot, 0);
        return 0;
    }

private:
    static ulong packedGuid(ref ByteReader r)
    {
        const mask = r.read!ubyte;
        ulong guid;
        foreach (i; 0 .. 8)
            if (mask & (1 << i))
                guid |= ulong(r.read!ubyte) << (8 * i);
        return guid;
    }

    // A create block's movement part, as the 1.12 client reads it.
    static void skipMovement(ref ByteReader r)
    {
        const flags = r.read!ubyte;
        if (flags & 0x20) // living
        {
            const moveFlags = r.read!uint;
            r.skip(4 + 16);         // time; x, y, z, o
            if (moveFlags & 0x0200_0000)
                r.skip(8 + 16);     // on a transport: its guid, the place on it
            if (moveFlags & 0x0020_0000)
                r.skip(4);          // swimming: pitch
            r.skip(4);              // fall time
            if (moveFlags & 0x0000_2000)
                r.skip(16);         // jumping
            if (moveFlags & 0x0400_0000)
                r.skip(4);          // spline elevation
            r.skip(6 * 4);          // speeds
            if (moveFlags & 0x0040_0000) // walking a spline
            {
                const splineFlags = r.read!uint;
                r.skip(splineFlags & 0x1_0000 ? 12 : splineFlags & 0x2_0000 ? 8 : splineFlags & 0x4_0000 ? 4 : 0);
                r.skip(4 + 4 + 4);  // passed, duration, id
                const nodes = r.read!uint;
                r.skip(12 * nodes + 12);
            }
        }
        else if (flags & 0x40) // has a position
            r.skip(16);
        if (flags & 0x08)
            r.skip(4);
        if (flags & 0x10)
            r.skip(4);
        if (flags & 0x04)
            packedGuid(r);
        if (flags & 0x02)
            r.skip(4);
    }
}

/// The client's side of the conversation.
struct TestClient
{
    WorldSession session;
    ubyte[sessionKeyLength] key;
    CipherState sending, receiving;
    bool encrypted;
    ubyte[] inbox;
    ClientView view; /// what the packets read so far told of objects' fields

    /// Every complete packet the server has sent since the last call.
    ServerPacketRead[] read()
    {
        inbox ~= session.takeOutput();
        ServerPacketRead[] packets;
        while (inbox.length >= 4)
        {
            ubyte[4] header = inbox[0 .. 4];
            if (encrypted)
                receiving.decrypt(header, key);
            const size = bigEndianToNative!ushort(header[0 .. 2]);
            packets ~= ServerPacketRead(littleEndianToNative!ushort(header[2 .. 4]), inbox[4 .. 2 + size].dup);
            inbox = inbox[2 + size .. $];
            const p = packets[$ - 1];
            if (p.opcode == Opcode.SMSG_UPDATE_OBJECT || p.opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
                view.apply(p.opcode, p.body_);
        }
        return packets;
    }

    /// Frames, encrypts (once authenticated) and delivers a client packet.
    void write(uint opcode, const(ubyte)[] body_, size_t chunk = size_t.max)
    {
        import std.range : chunks;

        ubyte[6] header;
        header[0 .. 2] = nativeToBigEndian(cast(ushort)(body_.length + 4));
        header[2 .. 6] = nativeToLittleEndian(opcode);
        if (encrypted)
            sending.encrypt(header, key);
        foreach (piece; (header ~ body_).chunks(chunk))
            session.receive(piece);
    }

    void write(T)(uint opcode, const T packet)
    {
        ByteWriter body_;
        serialize(body_, packet);
        write(opcode, body_.data);
    }
}

enum ubyte[sessionKeyLength] testKey = () {
    ubyte[sessionKeyLength] key;
    foreach (i, ref b; key)
        b = cast(ubyte)(i * 31 + 7);
    return key;
}();

MemoryWorldDatabase newDatabase()
{
    auto db = new MemoryWorldDatabase;
    WorldAccount player;
    player.id = 4;
    player.username = "PLAYER";
    player.sessionKey = testKey;
    player.hasSessionKey = true;
    player.os = "Win";
    player.platform = "x86";
    db.accounts["PLAYER"] = player;

    CharacterRecord thrall;
    thrall.guid = 1;
    thrall.name = "Thrall";
    thrall.race = 2;
    thrall.classId = 7;
    thrall.level = 60;
    thrall.zone = 1637;
    thrall.map = 1;
    thrall.equipmentCache = "0 0 0 0 0 0 0 0 17182 0";
    db.characterLists[4] = [thrall];
    return db;
}

WorldContext newContext(MemoryWorldDatabase db)
{
    auto data = new WorldData;
    data.playerInfo[WorldData.raceClassKey(2, 7)] = PlayerInfo.init; // orc shaman
    data.items[17182] = ItemTemplate.display(30606, 17);
    setLogLevel(LogLevel.error);
    return new WorldContext(WorldConfig.init, db, data, testClientData());
}

/// Reads the challenge and answers it; returns the server's reply packets.
ServerPacketRead[] authenticate(ref TestClient client, string account = "PLAYER",
    ubyte[sessionKeyLength] key = testKey, uint build = 5875)
{
    const challenge = client.read();
    assert(challenge.length == 1 && challenge[0].opcode == Opcode.SMSG_AUTH_CHALLENGE);
    auto reader = ByteReader(challenge[0].body_);
    const serverSeed = reader.read!uint;

    ClientAuthSession request;
    request.build = build;
    request.account = account;
    request.clientSeed = 0xC0FFEE;
    const ubyte[4] zero = 0;
    request.digest = sha1(account, zero, nativeToLittleEndian(request.clientSeed),
        nativeToLittleEndian(serverSeed), key);
    request.addonData = makeAddonBlock([ClientAddon("Blizzard_RaidUI", 1, standardAddonCrc, 0)]);
    client.write(Opcode.CMSG_AUTH_SESSION, request);

    client.encrypted = client.session.state == WorldState.characterScreen;
    return client.read();
}

ubyte authResult(ServerPacketRead[] packets)
{
    assert(packets[$ - 1].opcode == Opcode.SMSG_AUTH_RESPONSE);
    return packets[$ - 1].body_[0];
}

WorldContext newCreationContext(MemoryWorldDatabase db, void delegate(ref WorldConfig) adjust = null)
{
    auto client = testClientData();
    WorldConfig config;
    config.logoutDelay = 0; // everyone logs out at once, unless a test sets the 20-second wait up
    if (adjust)
        adjust(config);
    setLogLevel(LogLevel.error);
    return new WorldContext(config, db, testWorldData(client), client);
}

ubyte createCharacter(ref TestClient client, string name, ubyte race, ubyte classId, ubyte hairStyle = 1)
{
    client.write(Opcode.CMSG_CHAR_CREATE, ClientCharCreate(name, race, classId, 0, 0, 0, hairStyle, 0, 0, 0));
    const reply = client.read();
    assert(reply.length == 1 && reply[0].opcode == Opcode.SMSG_CHAR_CREATE);
    return reply[0].body_[0];
}

ubyte[] deleteCharacter(ref TestClient client, ulong guid)
{
    client.write(Opcode.CMSG_CHAR_DELETE, ClientCharDelete(guid));
    const reply = client.read();
    return reply.length ? reply[0].body_.dup : null;
}

/**
 * A character in the world: its account (named after it, upper case) is created in the login
 * database and `db`, the character in `db`; then the client authenticates and logs in. The login
 * packets are read.
 */
TestClient loggedIn(WorldContext context, MemoryWorldDatabase db, uint guid, string name, Position position,
    AccountLevel level = AccountLevel.player, ubyte race = raceHuman, uint map = 0, uint characterLevel = 1,
    void delegate(ref CharacterData) setup = null)
{
    import std.uni : toUpper;

    // The account is created in the login database too, so GM commands find it under the same id.
    WorldAccount account = db.accounts["PLAYER"];
    account.username = name.toUpper;
    account.level = level;
    const existing = context.accounts.findAccount(account.username);
    account.id = existing.isNull ? context.accounts.createAccount(account.username, "test", level).id : existing.get.id;
    db.accounts[account.username] = account;
    CharacterData c;
    c.guid = guid;
    c.account = account.id;
    c.name = name;
    c.race = race;
    c.classId = race == raceOrc ? classHunter : classWarrior; // the combinations testWorldData has
    c.level = characterLevel;
    c.cinematic = 1;
    c.map = map;
    c.position = position;
    if (setup !is null)
        setup(c);
    db.loadable[guid] = c;

    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client, account.username);
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(guid));
    client.read();
    assertSeesItself(client);
    return client;
}

/**
 * The client sees every field of its own player as the server holds it (as it must: its quest log, money and
 * the rest are read from them). Read the client's packets first.
 */
void assertSeesItself(ref TestClient client, string file = __FILE__, size_t line = __LINE__)
{
    import std.format : format;
    import dmangos.world.player : Player;
    import dmangos.world.updatefields : PLAYER_END, TypeId, typeMaskOf, updateFields;

    string nameOf(size_t slot)
    {
        foreach (field; updateFields)
            if ((field.owner & typeMaskOf(TypeId.player)) && slot >= field.offset && slot < field.offset + field.size)
                return slot == field.offset ? field.name : format!"%s+%s"(field.name, slot - field.offset);
        return format!"slot %s"(slot);
    }

    auto me = cast(Player) client.session.character;
    foreach (slot; 0 .. size_t(PLAYER_END))
    {
        const server = me.values[slot], seen = client.view[me.guid, slot];
        if (server != seen)
            throw new Exception(format!"the client sees %s as %s, the server has %s"(nameOf(slot), seen, server),
                file, line);
    }
}

/// A `CMSG_MESSAGECHAT` body; `target` is the whisper's receiver or the channel.
ubyte[] chatBody(ChatType type, string text, string target = null, Language language = Language.LANG_COMMON)
{
    ByteWriter w;
    w.put(uint(type));
    w.put(uint(language));
    if (type == ChatType.CHAT_MSG_WHISPER || type == ChatType.CHAT_MSG_CHANNEL)
        w.putCString(target);
    w.putCString(text);
    return w.data.dup;
}

/// The opcodes of some packets.
ushort[] opcodesOf(const(ServerPacketRead)[] packets)
{
    ushort[] codes;
    foreach (p; packets)
        codes ~= p.opcode;
    return codes;
}

/// The body of the first packet with `opcode`, or null.
const(ubyte)[] bodyOf(const(ServerPacketRead)[] packets, Opcode opcode)
{
    foreach (p; packets)
        if (p.opcode == opcode)
            return p.body_;
    return null;
}

/// Types a chat command (or anything said), as `/say text`.
void say(ref TestClient client, string text)
{
    client.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, text));
}

/// The texts of the system messages among some packets.
string[] systemMessages(const(ServerPacketRead)[] packets)
{
    string[] texts;
    foreach (p; packets)
        if (p.opcode == Opcode.SMSG_MESSAGECHAT && p.body_[0] == ChatType.CHAT_MSG_SYSTEM)
        {
            auto reader = ByteReader(p.body_[13 .. $]);
            const length = reader.read!uint;
            texts ~= cast(string) p.body_[17 .. 17 + length - 1].idup;
        }
    return texts;
}
