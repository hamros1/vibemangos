/// Alterac Valley assaults on real quest, NPC, item and spell records, through the client command paths.
module dmangos.world.realalterac;

version (unittest):
import core.time : msecs;
import std.format : format;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.alterac;
import dmangos.world.alteracassaults;
import dmangos.world.battleground : Battleground;
import dmangos.world.bgqueue : BattlegroundEntry, BattlegroundType;
import dmangos.world.creature : Creature;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ClientNpcGuid, ClientGossipSelectOption, ClientTeleportAck;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.testclient : TestClient, bodyOf;

private class Valley
{
    RealWorld w;
    Battleground copy;
    AlteracRules rules;
    TestClient player;
    ubyte side;

    this(ubyte team)
    {
        side = team;
        w = RealWorld.make();
        copy = w.context.battlegrounds.open(970 + side, BattlegroundType.alteracValley);
        rules = cast(AlteracRules) copy.rules;
        copy.testing = true;
        copy.start();
        player = w.character(17, "Raider", 1, 60, [], side ? 2 : 1);
        me.enterBattleground(BattlegroundEntry(true, copy.instance, side, BattlegroundType.alteracValley));
        player.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        me.godModeCheat = true;
    }

    auto me() { return player.session.inWorld; }
    auto map() { return me.currentMap; }

    void move(Position p)
    {
        me.teleportTo(30, p, null, copy.instance, true);
        player.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
        player.read();
    }

    Creature meet(uint entry)
    {
        foreach (ref row; w.context.data.creatureSpawns)
            if (row.entry == entry && row.map == 30)
            {
                move(Position(row.x + 1, row.y, row.z));
                foreach (c; map.creaturesNear(me.player.position, 8))
                    if (c.template_.entry == entry && c.alive)
                        return c;
            }
        const field = muster[side];
        move(field);
        foreach (c; map.creaturesNear(field, 25))
            if (c.template_.entry == entry && c.alive)
                return c;
        assert(false, format!"NPC %s missing"(entry));
    }

    void run(uint ms)
    {
        for (uint i; i < ms; i += 200)
        {
            w.now += 200.msecs;
            w.context.update(w.now);
            player.read();
        }
    }

    bool select(Creature npc, string label)
    {
        player.read();
        player.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(npc.guid));
        auto body_ = bodyOf(player.read(), Opcode.SMSG_GOSSIP_MESSAGE);
        if (!body_.length)
            return false;
        auto r = ByteReader(body_);
        assert(r.read!ulong == npc.guid);
        r.read!uint;
        const count = r.read!uint;
        foreach (_; 0 .. count)
        {
            const index = r.read!uint;
            r.read!ubyte;
            r.read!ubyte;
            if (r.readCString() == label)
            {
                player.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(npc.guid, index));
                return true;
            }
        }
        return false;
    }
    void testEnemy(Creature troop)
    {
        auto opponent = w.character(31, "Opponent", 1, 60, [], side == 0 ? 2 : 1);
        auto enemy = opponent.session.inWorld;
        enemy.enterBattleground(BattlegroundEntry(true, copy.instance, cast(ubyte)(1-side), BattlegroundType.alteracValley));
        opponent.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        enemy.godModeCheat = true;
        enemy.teleportTo(30, troop.position, null, copy.instance, true);
        opponent.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(enemy.player.guid, 0, 0));
        run(3000);
        assert(troop.ai.currentVictim == enemy.player.guid,
            format!"unit %s did not attack the enemy in its path, victim %s"(troop.template_.entry, troop.ai.currentVictim));
    }

    void quest(Creature npc, uint quest, bool reward)
    {
        ByteWriter b;
        b.put(npc.guid);
        b.put(quest);
        if (reward)
            b.put(0u);
        player.write(reward ? Opcode.CMSG_QUESTGIVER_CHOOSE_REWARD : Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, b.data);
    }
}

/// A mounted ram or wolf must actually be brought in. Completing the stables unlocks the commander's charge.
unittest
{
    if (!haveRealData()) return;
    import dmangos.script.api : QuestProgress;
    import dmangos.world.defines : inventorySlotBag0, inventorySlotItemStart, inventorySlotItemEnd;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.motion : MotionType;
    foreach (ubyte side; 0 .. 2)
    {
        auto v = new Valley(side);
        auto master = v.meet(stableMasters[side]);
        v.quest(master, stableQuest[side], false);
        assert(v.me.questStatusOf(stableQuest[side]) == QuestProgress.incomplete);
        assert(!v.select(master, "I have brought a mount for the stables."));
        const tool = side == 0 ? 17689u : 17626u;
        ubyte slot = inventorySlotItemStart;
        while (slot < inventorySlotItemEnd && (v.me.player.inventory[inventorySlotBag0, slot] is null
            || v.me.player.inventory[inventorySlotBag0, slot].proto.entry != tool)) ++slot;
        assert(slot < inventorySlotItemEnd);
        auto pos = master.position;
        pos.x += 2;
        auto mount = v.map.creatureAt(v.copy.summonAt(wildMounts[side], pos.x, pos.y, pos.z, pos.orientation));
        ByteWriter cmd;
        cmd.put(inventorySlotBag0); cmd.put(slot); cmd.put(ubyte(0));
        SpellTargets(TargetFlags.unit, mount.guid).write(cmd);
        v.player.write(Opcode.CMSG_USE_ITEM, cmd.data);
        const result = bodyOf(v.player.read(), Opcode.SMSG_CAST_RESULT).dup;
        v.run(4000);
        assert(mount.generator.type == MotionType.follow, format!"mount did not follow, side %s result %s aura %s motion %s in combat %s, player %s beast %s"(side, result, mount.auras.find(collarSpells[side]) !is null, mount.generator.type, mount.ai.inCombat, v.me.player.position, mount.position));
        assert(v.select(master, "I have brought a mount for the stables."));
        assert(v.me.questStatusOf(stableQuest[side]) == QuestProgress.complete);
        v.quest(master, stableQuest[side], true);
        assert(v.rules.mounts[side] == 1);
        auto chief = v.meet(cavalryChiefs[side]);
        foreach (_; 1 .. 25) v.rules.questRewarded(v.copy, v.me.player.guid, stableQuest[side]);
        foreach (_; 0 .. 24) v.rules.questRewarded(v.copy, v.me.player.guid, hideQuest[side]);
        v.me.modifyReputation(factions[side], 10000);
        assert(!v.select(chief, "Riders, assemble for the assault!"));
        v.rules.questRewarded(v.copy, v.me.player.guid, hideQuest[side]);
        assert(v.select(chief, "Riders, assemble for the assault!"));
        assert(!v.select(chief, "Riders, assemble for the assault!"));
        Creature first;
        size_t count;
        foreach (c; v.map.creaturesNear(chief.position, 30))
            if (c.template_.entry == riders[side]) { ++count; first = c; }
        assert(count == 5);
        v.move(first.position);
        assert(v.select(first, "Advance on the enemy base!"));
        assert(first.generator.type == MotionType.point);
        v.testEnemy(first);
    }
}

/// Mined supplies become an order carried by an Honored ally to the battlefield commander.
unittest
{
    if (!haveRealData()) return;
    foreach (ubyte side; 0 .. 2)
    {
        auto v = new Valley(side);
        auto quartermaster = v.meet(quartermasters[side]);
        foreach (_; 0 .. 7)
            v.rules.questRewarded(v.copy, v.me.player.guid, mineQuest[side][1-side]);
        const order = "Give me the ground assault orders.";
        assert(!v.select(quartermaster, order), "a neutral recruit was offered command");
        v.me.modifyReputation(factions[side], 10000);
        assert(v.select(quartermaster, order) && v.me.player.inventory.count(orderItems[side]) == 1);
        assert(!v.select(quartermaster, order));
        auto commander = v.meet(groundChiefs[side]);
        v.quest(commander, groundQuest[side], false);
        v.quest(commander, groundQuest[side], true);
        assert(!v.me.player.inventory.count(orderItems[side]) && v.rules.mineSupplies[side][1-side] == 0);
        uint count;
        Creature first;
        foreach (c; v.map.creaturesNear(commander.position, 24))
            if (c.template_.entry == (side == 0 ? 13524 : 13528)) { first = c; ++count; }
        assert(count == 10);
        v.move(first.position);
        assert(v.select(first, "Advance on the enemy base!"));
        v.testEnemy(first);
    }
}
