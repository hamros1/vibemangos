/// Client commands that must read the current guild under the same lock as their writes.
module dmangos.world.guildmutation;

import dmangos.world.opcodes : Opcode;

package bool mutatesGuild(Opcode opcode)
{
    switch (opcode)
    {
    case Opcode.CMSG_GUILD_CREATE:
    case Opcode.CMSG_PETITION_BUY:
    case Opcode.CMSG_PETITION_SIGN:
    case Opcode.CMSG_TURN_IN_PETITION:
    case Opcode.CMSG_GUILD_INVITE:
    case Opcode.CMSG_GUILD_ACCEPT:
    case Opcode.CMSG_GUILD_LEAVE:
    case Opcode.CMSG_GUILD_REMOVE:
    case Opcode.CMSG_GUILD_DISBAND:
    case Opcode.CMSG_GUILD_PROMOTE:
    case Opcode.CMSG_GUILD_DEMOTE:
    case Opcode.CMSG_GUILD_LEADER:
    case Opcode.CMSG_GUILD_RANK:
    case Opcode.CMSG_GUILD_ADD_RANK:
    case Opcode.CMSG_GUILD_DEL_RANK:
    case Opcode.CMSG_GUILD_MOTD:
    case Opcode.CMSG_GUILD_INFO_TEXT:
    case Opcode.CMSG_GUILD_SET_PUBLIC_NOTE:
    case Opcode.CMSG_GUILD_SET_OFFICER_NOTE:
    case Opcode.MSG_SAVE_GUILD_EMBLEM:
        return true;
    default:
        return false;
    }
}

/// Workers can change different guild fields and recheck permissions with a stale local view.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.database : GuildRecord;
    import dmangos.world.guild : Guild;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : loggedIn, newCreationContext, newDatabase;

    auto db = newDatabase();
    GuildRecord record;
    record.id = 1;
    record.name = "Stormwind Guard";
    record.leader = 7;
    record.motd = "Original message";
    record.info = "Original description";
    db.saveGuild(record);
    db.saveGuildRanks(record.id, Guild.defaultRanks());
    db.saveGuildMember(record.id, 7, 0, "", "");
    db.saveGuildMember(record.id, 8, 1, "", "");
    auto first = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 1; });
    auto second = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 2; });
    first.nodeId = 1;
    second.nodeId = 2;
    first.regionOwnerAround = (uint, Position, float) => first.nodeId;
    second.regionOwnerAround = (uint, Position, float) => second.nodeId;
    const position = Position(-8949.95f, -132.49f, 83.53f);
    auto leader = loggedIn(first, db, 7, "Anduin", position);
    auto officer = loggedIn(second, db, 8, "Jaina", position);

    ubyte[] text(string value)
    {
        ByteWriter message;
        message.putCString(value);
        return message.data.dup;
    }

    ulong published;
    first.guildReloadElsewhere = (uint id) {
        assert(id == record.id);
        published = db.guildRevision();
    };
    leader.write(Opcode.CMSG_GUILD_MOTD, text("Meet at the bank"));
    assert(published == 2 && second.guilds.find(record.id).motd == record.motd);
    officer.write(Opcode.CMSG_GUILD_INFO_TEXT, text("Bring a shield"));
    const updated = db.loadGuild(record.id);
    assert(updated.get.motd == "Meet at the bank" && updated.get.info == "Bring a shield");
    assert(db.guildRevision() == 3);

    leader.write(Opcode.CMSG_GUILD_REMOVE, text("Jaina"));
    assert(published == 4 && second.guilds.of(8) !is null);
    officer.write(Opcode.CMSG_GUILD_MOTD, text("Old permissions"));
    assert(db.loadGuild(record.id).get.motd == "Meet at the bank" && db.guildRevision() == 4);
    assert(second.guilds.of(8) is null);

    import dmangos.mysql : DatabaseException;

    auto before = first.guilds.find(record.id);
    const oldMotd = before.motd;
    const oldRank = before.member(7).rank;
    bool notified;
    assert(!first.commitGuildChange({
        auto staged = first.guilds.find(record.id);
        staged.motd = "Uncommitted";
        staged.member(7).rank = 3;
        first.afterGuildWrite(() { notified = true; });
        throw new DatabaseException("save failed");
    }));
    assert(first.guilds.find(record.id) is before);
    assert(before.motd == oldMotd && before.member(7).rank == oldRank && !notified);
}
