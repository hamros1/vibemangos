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

/// The client's side of the conversation.
struct TestClient
{
    WorldSession session;
    ubyte[sessionKeyLength] key;
    CipherState sending, receiving;
    bool encrypted;
    ubyte[] inbox;

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
    return client;
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
