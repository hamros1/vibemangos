/// A battlegroup's realms share one queue and simulate each battleground once.
/// Home sessions, services, character storage and ordinary maps still belong to their own realm.
module dmangos.world.battlegroup;

import dmangos.world.bgqueue : BattlegroundQueue;
import dmangos.world.context : WorldContext;
import dmangos.world.group : GroupDirectory, Groups, memberStatus;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes : Opcode;

enum uint battlegroupInstance = 0x8000_0000;

/// The high 16 bits still identify a player in the 1.12 protocol. Its low 32 bits identify its character row.
ulong realmPlayerGuid(uint realm, uint local) pure nothrow @nogc @safe
{
    return local ? (cast(ulong) realm << 32 | local) : 0;
}

final class Battlegroup : GroupDirectory
{
    private WorldContext[uint] realms;
    Groups raids;
    WorldContext host;
    BattlegroundQueue queue;

    void attach(WorldContext realm)
    {
        import std.exception : enforce;
        const id = realm.config.realmId;
        enforce(id > 0 && id <= ushort.max && id !in realms, "battlegroup requires distinct 16-bit realm IDs");
        enforce(host is null || host.config.battlegroup == realm.config.battlegroup,
            "different battlegroups cannot share a queue");
        realms[id] = realm;
        if (host is null)
        {
            host = realm;
            raids = new Groups(null, this, battlegroupInstance);
            queue = realm.newBattlegroundQueue();
            auto allocate = queue.newInstanceId;
            queue.newInstanceId = (out uint instance) {
                uint id;
                if (!allocate(id) || !id || id >= battlegroupInstance) return false;
                instance = id | battlegroupInstance;
                return true;
            };
            queue.deliver = &deliver;
            queue.currentNode = (ulong guid) {
                if (auto realm = homeOf(guid))
                    return realm.queuePlayerNode(guid);
                return ushort(0);
            };
        }
        else
            realm.battlegrounds = host.battlegrounds;
        realm.groups.battlegroundRaids = raids;
        realm.battlegroup = this;
    }

    WorldContext homeOf(ulong guid)
    {
        return realms.get(cast(uint)(guid >> 32), null);
    }

    private void deliver(ulong guid, ushort node, Opcode opcode, const(ubyte)[] body_)
    {
        if (auto realm = cast(uint)(guid >> 32) in realms)
            (*realm).deliverQueuePacket(guid, node, opcode, body_);
    }

    /// The directory for temporary team raids. A player is visible only while registered in its copy.
    OnlinePlayer local(ulong guid)
    {
        auto realm = homeOf(guid);
        auto who = realm is null ? null : realm.onlinePlayer(guid);
        if (who is null || !(who.instanceId & battlegroupInstance)) return null;
        auto copy = host.battlegrounds.find(who.instanceId);
        return copy !is null && guid in copy.members ? who : null;
    }

    bool deliverTo(ulong guid, Opcode opcode, const(ubyte)[] body_)
    {
        auto who = local(guid);
        if (who is null) return false;
        who.deliver(opcode, body_);
        return true;
    }

    ubyte statusOf(ulong guid)
    {
        return memberStatus(local(guid));
    }

    bool seeEachOther(ulong a, ulong b)
    {
        auto first = local(a), second = local(b);
        if (first is null || second is null || first.instanceId != second.instanceId) return false;
        auto map = host.existingMap(first.character.data.map, first.instanceId);
        return map !is null && map.seeEachOther(a, b);
    }

    /// Only resolve foreign players who actually belong to this copy.
    OnlinePlayer member(uint instance, ulong guid)
    {
        auto who = local(guid);
        return who !is null && who.instanceId == instance ? who : null;
    }
}

/// Two separate character databases contain the same local GUID and name. Both clients enter one map.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.bgqueue : BattlegroundType, BattlegroundQueueHost, BattlegroundJoin;
    import dmangos.world.battleground : winnerAlliance;
    import dmangos.world.clientdata : emotesFormat, emotesTextDataFormat, emotesTextFormat;
    import dmangos.world.group : GroupUpdate, MemberStatus;
    import dmangos.world.opcodes : ChatType, Language;
    import dmangos.world.packets : ClientTextEmote;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapEasternKingdoms, mapWarsongGulch, testClientData, testWorldData;

    auto pool = new Battlegroup;
    auto client = testClientData();
    auto wave = new uint[emotesTextFormat.length];
    wave[0] = 101;
    wave[2] = 3; // the one-shot wave animation
    wave[3] = 1;
    wave[4] = 2;
    wave[7] = 3;
    client.emotesText = typeof(client.emotesText).parse(buildDbc(emotesTextFormat, [wave]), "");
    auto animation = new uint[emotesFormat.length];
    animation[0] = 3;
    client.emotes = typeof(client.emotes).parse(buildDbc(emotesFormat, [animation]), "");
    enum targetedWave = "%s waves at %s.\0", atViewer = "%s waves at you.\0";
    const strings = cast(const(ubyte)[]) ("\0" ~ targetedWave ~ atViewer ~ "%s waves.\0");
    client.emotesTextData = typeof(client.emotesTextData).parse(buildDbc(emotesTextDataFormat, [
        [1u, 1, 0, 0, 0, 0, 0, 0, 0, 0],
        [2u, cast(uint) (1 + targetedWave.length), 0, 0, 0, 0, 0, 0, 0, 0],
        [3u, cast(uint) (1 + targetedWave.length + atViewer.length), 0, 0, 0, 0, 0, 0, 0, 0]], strings), "");
    auto firstDb = newDatabase(), nextDb = newDatabase();
    WorldContext make(uint id, MemoryWorldDatabase db)
    {
        auto data = testWorldData(client);
        data.battlegroundTemplates[BattlegroundType.warsongGulch].minPerTeam = 1;
        WorldConfig conf;
        conf.realmId = id;
        conf.battlegroup = "Emberstorm";
        auto world = new WorldContext(conf, db, data, client, null, pool);
        world.realmDisplayName = id == 1 ? "First" : "Silver Hand";
        return world;
    }
    auto a = make(1, firstDb), b = make(2, nextDb);
    auto left = loggedIn(a, firstDb, 7, "Echo", Position(-8949,-132,84), AccountLevel.player, 1, 0, 20);
    auto right = loggedIn(b, nextDb, 7, "Echo", Position(-8939,-142,85), AccountLevel.player, 2, 0, 20);
    left.read(); right.read();
    const l = left.session.inWorld.player.guid, r = right.session.inWorld.player.guid;
    assert(l != r && cast(uint)l == cast(uint)r);
    a.services.call!(BattlegroundQueueHost.join)(BattlegroundJoin(l,0,0,20,BattlegroundType.warsongGulch,0));
    assert(!pool.queue.copies.length);
    b.services.call!(BattlegroundQueueHost.join)(BattlegroundJoin(r,0,1,20,BattlegroundType.warsongGulch,0));
    assert(pool.queue.copies.length == 1);
    auto copyId = pool.queue.copies.keys[0];
    assert(copyId & battlegroupInstance);
    ByteWriter port;
    port.put(mapWarsongGulch); port.put(ubyte(1));
    foreach (user; [&left, &right])
    {
        assert(bodyOf(user.read(),Opcode.SMSG_BATTLEFIELD_STATUS).length);
        user.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
        assert(bodyOf(user.read(),Opcode.SMSG_NEW_WORLD).length);
        user.write(Opcode.MSG_MOVE_WORLDPORT_ACK,null);
        user.read();
    }
    auto match = a.battlegrounds.find(copyId);
    assert(match is b.battlegrounds.find(copyId) && match.members.length == 2);
    assert(left.session.inWorld.currentMap is right.session.inWorld.currentMap);
    assert(match.memberSession(l) is left.session.inWorld && match.memberSession(r) is right.session.inWorld);
    void checkName(ref TestClient user, ulong guid, string expectedName, string expectedRealm)
    {
        user.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(guid));
        auto name = ByteReader(bodyOf(user.read(), Opcode.SMSG_NAME_QUERY_RESPONSE));
        assert(name.read!ulong == guid && name.readCString() == expectedName && name.readCString() == expectedRealm);
    }
    checkName(left, r, "Echo", "Silver Hand");
    checkName(right, l, "Echo", "First");
    checkName(left, l, "Echo", "");
    checkName(right, r, "Echo", "");
    void whisper(ref TestClient user, string address, string text)
    {
        user.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, text, address));
    }
    whisper(left, "Echo-SilverHand", "For the Horde?");
    assert(bodyOf(left.read(), Opcode.SMSG_CHAT_PLAYER_NOT_FOUND).length);
    assert(bodyOf(right.read(), Opcode.SMSG_MESSAGECHAT).length == 0);
    auto teammate = loggedIn(b, nextDb, 8, "Scout", Position(-8939, -142, 85), AccountLevel.player, 1, 0, 20);
    const scout = teammate.session.inWorld.player.guid;
    assert(pool.member(copyId, scout) is null);
    whisper(left, "Scout-SilverHand", "Still in Stormwind?");
    assert(bodyOf(left.read(), Opcode.SMSG_CHAT_PLAYER_NOT_FOUND).length);
    assert(bodyOf(teammate.read(), Opcode.SMSG_MESSAGECHAT).length == 0);
    b.services.call!(BattlegroundQueueHost.join)(BattlegroundJoin(scout, 0, 0, 20, BattlegroundType.warsongGulch, 0));
    teammate.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
    teammate.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    auto raid = a.groups.of(l);
    assert(raid !is null && raid.isRaid && raid is b.groups.of(scout) && raid.members.length == 2);
    assert(raid.isMember(l) && raid.isMember(scout) && !raid.isMember(r));
    assert(firstDb.groups.length == 0 && nextDb.groups.length == 0);
    auto moved = left.session.inWorld.player.movement;
    moved.position.x += 500;
    left.session.inWorld.player.movement = moved;
    left.session.inWorld.movedOn(moved, Opcode.MSG_MOVE_HEARTBEAT);
    assert(!pool.seeEachOther(l, scout));
    teammate.read();
    teammate.write(Opcode.CMSG_REQUEST_PARTY_MEMBER_STATS, ClientGuid(l));
    auto stats = ByteReader(bodyOf(teammate.read(), Opcode.SMSG_PARTY_MEMBER_STATS_FULL));
    assert(stats.readPackedGuid() == l && (stats.read!uint & GroupUpdate.currentHealth));
    assert(stats.read!ubyte == MemberStatus.online && stats.read!ushort > 0);
    void checkChat(ref TestClient user, ChatType type, ulong other, string text)
    {
        auto reply = ByteReader(bodyOf(user.read(), Opcode.SMSG_MESSAGECHAT));
        assert(reply.read!ubyte == type);
        reply.read!uint;
        assert(reply.read!ulong == other);
        assert(reply.read!uint == text.length + 1 && reply.readCString() == text);
    }
    whisper(left, "scout-silverhand", "Defend here?");
    checkChat(teammate, ChatType.CHAT_MSG_WHISPER, l, "Defend here?");
    checkChat(left, ChatType.CHAT_MSG_WHISPER_INFORM, scout, "Defend here?");
    whisper(teammate, "Echo-First", "On my way");
    checkChat(left, ChatType.CHAT_MSG_WHISPER, scout, "On my way");
    checkChat(teammate, ChatType.CHAT_MSG_WHISPER_INFORM, l, "On my way");
    left.read();
    ByteWriter chat;
    chat.put(cast(uint) ChatType.CHAT_MSG_BATTLEGROUND);
    chat.put(cast(uint) Language.LANG_COMMON);
    chat.putCString("Defend the flag");
    teammate.write(Opcode.CMSG_MESSAGECHAT, chat.data);
    auto message = ByteReader(bodyOf(left.read(), Opcode.SMSG_MESSAGECHAT));
    assert(message.read!ubyte == ChatType.CHAT_MSG_BATTLEGROUND);
    message.read!uint;
    assert(message.read!ulong == scout, "the chat sender uses the same realm-qualified GUID as the name cache");
    checkName(left, scout, "Scout", "Silver Hand");

    void place(ref TestClient user, Position at)
    {
        auto who = user.session.inWorld;
        auto motion = who.player.movement;
        motion.position = at;
        who.player.movement = motion;
        who.movedOn(motion, Opcode.MSG_MOVE_HEARTBEAT);
    }
    const near = teammate.session.inWorld.player.position;
    place(left, near);
    place(right, Position(near.x + 500, near.y, near.z));
    foreach (user; [&left, &right, &teammate])
        user.read();
    teammate.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_EMOTE, "cheers at 100%."));
    checkChat(left, ChatType.CHAT_MSG_TEXT_EMOTE, scout, "Scout-SilverHand cheers at 100%.");
    checkChat(teammate, ChatType.CHAT_MSG_EMOTE, scout, "cheers at 100%.");
    assert(bodyOf(right.read(), Opcode.SMSG_MESSAGECHAT).length == 0);

    place(right, near);
    foreach (user; [&left, &right, &teammate])
        user.read();
    teammate.write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(101, 0, l));
    auto onlooker = right.read();
    assert(bodyOf(onlooker, Opcode.SMSG_EMOTE).length, "the animation still reaches the onlooker");
    auto wavePacket = ByteReader(bodyOf(onlooker, Opcode.SMSG_TEXT_EMOTE));
    assert(wavePacket.read!ulong == scout && wavePacket.read!uint == 101);
    wavePacket.read!uint;
    assert(wavePacket.read!uint == "Echo-First".length + 1 && wavePacket.readCString() == "Echo-First",
        "an onlooker with the target's local name still sees the right realm");
    checkChat(left, ChatType.CHAT_MSG_TEXT_EMOTE, scout, "Scout-SilverHand waves at you.");
    teammate.read();

    left.write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(101, 0, scout));
    checkChat(teammate, ChatType.CHAT_MSG_TEXT_EMOTE, l, "Echo-First waves at you.");
    checkChat(right, ChatType.CHAT_MSG_TEXT_EMOTE, l, "Echo-First waves at Scout.");
    left.read();
    teammate.write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(101, 0, 0));
    checkChat(left, ChatType.CHAT_MSG_TEXT_EMOTE, scout, "Scout-SilverHand waves.");
    right.read();

    teammate.read();
    a.data.serverStrings[605] = "$n captured the Horde flag!";
    match.message(605, ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE, scout);
    foreach (i, user; [&left, &right, &teammate])
    {
        auto announcement = ByteReader(bodyOf(user.read(), Opcode.SMSG_MESSAGECHAT));
        assert(announcement.read!ubyte == ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE);
        announcement.read!uint;
        assert(announcement.read!ulong == scout);
        announcement.read!uint;
        assert(announcement.readCString() == (i == 0 ? "Scout-SilverHand captured the Horde flag!"
            : "$n captured the Horde flag!"));
    }

    teammate.session.disconnected();
    assert(match.memberSession(scout) is null && scout in match.members);
    whisper(left, "Scout-SilverHand", "Are you back?");
    assert(bodyOf(left.read(), Opcode.SMSG_CHAT_PLAYER_NOT_FOUND).length);
    left.read();
    left.write(Opcode.MSG_PVP_LOG_DATA, null);
    auto board = ByteReader(bodyOf(left.read(), Opcode.MSG_PVP_LOG_DATA));
    assert(board.read!ubyte == 0 && board.read!uint == 3);
    bool foundScout;
    foreach (_; 0 .. 3)
    {
        foundScout |= board.read!ulong == scout;
        board.readBytes(5 * uint.sizeof);
        const columns = board.read!uint;
        board.readBytes(columns * uint.sizeof);
    }
    assert(foundScout);
    checkName(left, scout, "Scout", "Silver Hand");
    match.removed(scout);
    left.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(scout));
    assert(bodyOf(left.read(), Opcode.SMSG_NAME_QUERY_RESPONSE).length == 0);
    assert(pool.member(copyId, scout) is null && a.groups.of(l) is null && b.groups.of(scout) is null);
    match.start();
    match.rewardHonorToTeam(1,0);
    match.end(winnerAlliance);
    foreach (user; [&left,&right])
    {
        user.write(Opcode.CMSG_LEAVE_BATTLEFIELD,null);
        user.write(Opcode.MSG_MOVE_WORLDPORT_ACK,null);
        assert(user.session.inWorld.player.data.map == mapEasternKingdoms);
    }
    assert(left.session.inWorld.player.position.x == -8949 && right.session.inWorld.player.position.x == -8939);
}

/// Real battlemasters, opposite factions and the actual end-of-match reward spells.
unittest
{
    import dmangos.world.realspelltests : haveRealData, RealWorld;
    if (!haveRealData()) return;
    import dmangos.world.battleground : winnerAlliance;
    import dmangos.world.bgqueue : BattlegroundType;
    import dmangos.world.testclient;
    import dmangos.world.objects : HighGuid, makeGuid;

    auto fixture = RealWorld.make();
    auto pool = new Battlegroup;
    RealWorld realm(uint id)
    {
        RealWorld w;
        w.db = newDatabase();
        auto config = fixture.context.config;
        config.realmId = id;
        config.battlegroup = "Emberstorm";
        config.battlegroundScoreStatistics = true;
        w.context = new WorldContext(config, w.db, fixture.context.data, fixture.context.client, null, pool);
        w.now = fixture.now;
        w.context.realmDisplayName = id == 1 ? "First" : "Second";
        return w;
    }
    auto alliance = realm(1), horde = realm(2);
    auto elf = alliance.character(23,"Echo",1,60,[]);
    auto orc = horde.character(23,"Echo",1,60,[],2);
    const type = BattlegroundType.warsongGulch;
    pool.queue.templates[type].minPerTeam = 1;
    Position[2] origin;
    foreach (i, user; [&elf,&orc])
    {
        auto me = user.session.inWorld;
        const entry = i == 0 ? 14981u : 2804u;
        ulong guid;
        foreach (ref s; fixture.context.data.creatureSpawns)
            if (s.map == 0 && s.entry == entry)
            {
                guid = makeGuid(HighGuid.unit,s.entry,s.guid);
                origin[i] = Position(s.x + 1,s.y,s.z);
                break;
            }
        assert(guid);
        me.teleportTo(0,origin[i],null,0,true);
        user.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid,0,0));
        user.read();
        user.write(Opcode.CMSG_BATTLEMASTER_HELLO,ClientNpcGuid(guid));
        assert(bodyOf(user.read(),Opcode.SMSG_BATTLEFIELD_LIST).length);
        ByteWriter join;
        join.put(guid); join.put(489u); join.put(0u); join.put(ubyte(0));
        user.write(Opcode.CMSG_BATTLEMASTER_JOIN,join.data);
    }
    assert(pool.queue.copies.length == 1);
    const id = pool.queue.copies.keys[0];
    foreach (user; [&elf,&orc])
    {
        ByteWriter port;
        port.put(489u); port.put(ubyte(1));
        user.write(Opcode.CMSG_BATTLEFIELD_PORT,port.data);
        user.write(Opcode.MSG_MOVE_WORLDPORT_ACK,null);
    }
    auto match = alliance.context.battlegrounds.find(id);
    assert(match.members.length == 2);
    match.start();
    match.rewardHonorToTeam(2,0);
    match.end(winnerAlliance);
    assert(elf.session.inWorld.player.inventory.count(20558) == 3);
    assert(orc.session.inWorld.player.inventory.count(20558) == 1);
    assert(alliance.db.pvpStatsRows.length == 1 && horde.db.pvpStatsRows.length == 1);
    foreach (i, user; [&elf,&orc])
    {
        user.write(Opcode.CMSG_LEAVE_BATTLEFIELD,null);
        user.write(Opcode.MSG_MOVE_WORLDPORT_ACK,null);
        assert(user.session.inWorld.player.position == origin[i]);
        auto db = i == 0 ? alliance.db : horde.db;
        assert(db.pvpStatsPlayerRows[0].length == 1 && db.pvpStatsPlayerRows[0][0].guid == 23);
        if (i == 0) assert(db.pvpStatsPlayerRows[0][0].bonusHonor > horde.db.pvpStatsPlayerRows[0][0].bonusHonor);
        user.session.disconnected();
        uint marks;
        foreach (item; db.itemRows)
            if (item.entry == 20558 && db.itemOwners[item.guid] == 23)
                marks += item.count;
        assert(marks == (i == 0 ? 3 : 1));
    }
}
