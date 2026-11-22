// Optional real-data checks for the 1.12.1 trainer audit. See docs/research/TRAINER-SPELL-AUDIT.md.
module dmangos.world.trainer_spell_probe;

version (unittest):

import core.time : msecs;
import std.stdio : stderr;
import dmangos.bytes : ByteWriter;
import dmangos.world.combat : MeleeHitOutcome;
import dmangos.world.creature : Creature;
import dmangos.world.diminishing : drCategory, DrCategory;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ClientGroupName, ClientGuid, ClientNpcGuid, ClientTrainerBuySpell, ServerTrainerList;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.updatefields;

unittest
{
    assert(haveRealData(), "set DMANGOS_REAL_DATA to the harness world database and extracted client data");
    size_t failures;
    void check(bool ok, string rule)
    {
        stderr.writefln("trainer-audit %s  %s", ok ? "PASS" : "FAIL", rule);
        if (!ok)
            ++failures;
    }

    foreach (id; [20905u, 20906u])
    {
        auto w = RealWorld.make();
        auto hunter = w.character(61001, "Bowman", 3, 60, [id], 3);
        check(w.cast_(hunter, id) == SpellCastResult.ok && hunter.session.inWorld.player.auras.find(id) !is null,
            id == 20905 ? "Hunter applies Trueshot Aura rank 2" : "Hunter applies Trueshot Aura rank 3");
    }

    foreach (warrior; [true, false])
    {
        auto w = RealWorld.make();
        auto who = w.character(61311, warrior ? "Fighter" : "Knight", warrior ? 1 : 2, warrior ? 6 : 8, []);
        auto npc = w.enemy(who, warrior ? 5479 : 5491); // summon the real trainer template beside the player
        const lesson = warrior ? 1229u : 1998u;
        const learned = warrior ? 877u : 1973u;
        auto player = who.session.inWorld.player;
        player.values.set!PLAYER_FIELD_COINAGE(1000u);
        assert(!player.knowsSpell(learned));
        import dmangos.world.npchandlers : packet;
        import std.algorithm.searching : canFind;
        who.write(Opcode.CMSG_TRAINER_LIST, ClientNpcGuid(npc));
        auto list = packet!ServerTrainerList(who.read());
        check(list.spells.length && !list.spells.canFind!(row => row.spell == lesson),
            warrior ? "Warrior list omits obsolete Elemental Fury" : "Paladin list omits obsolete Hip Shot");
        who.write(Opcode.CMSG_TRAINER_BUY_SPELL, ClientTrainerBuySpell(npc, lesson));
        check(!player.knowsSpell(learned) && player.values.get!PLAYER_FIELD_COINAGE == 1000,
            warrior ? "Warrior trainer refuses obsolete Elemental Fury" : "Paladin trainer refuses obsolete Hip Shot");
    }

    enum Tap { unclaimed, own, party, foreign, duringCast }
    foreach (tap; [Tap.unclaimed, Tap.own, Tap.party, Tap.foreign, Tap.duringCast])
    {
        auto w = RealWorld.make();
        auto mage = w.character(61234, "Caster", 8, 60, [118u]);
        auto other = w.character(61235, "Tagger", 1, 60, []);
        const target = w.enemy(mage);
        auto mob = cast(Creature) w.context.map(0).findObject(target);
        if (tap == Tap.party)
        {
            mage.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("tagger"));
            other.write(Opcode.CMSG_GROUP_ACCEPT, null);
            auto group = w.context.groups.of(mage.session.character.guid);
            assert(group !is null && group.isMember(other.session.character.guid));
            mob.setLootRecipient(other.session.character.guid, group.id);
        }
        else if (tap == Tap.own)
            mob.setLootRecipient(mage.session.character.guid, 0);
        else if (tap == Tap.foreign)
            mob.setLootRecipient(other.session.character.guid, 0);
        mage.session.inWorld.player.movement.position.orientation = 0;
        const result = w.castAt(mage, 118, target);
        if (tap == Tap.duringCast)
            mob.setLootRecipient(other.session.character.guid, 0);
        w.now += 2000.msecs;
        mage.session.update(2000.msecs);
        const landed = mob.auras.find(118) !is null;
        final switch (tap)
        {
        case Tap.unclaimed: check(landed, "Polymorph lands on an unclaimed target"); break;
        case Tap.own: check(landed, "Polymorph lands on the caster's tap"); break;
        case Tap.party: check(landed, "Polymorph lands on a party tap"); break;
        case Tap.foreign: check(result == SpellCastResult.cantCastOnTapped && !landed, "Polymorph refuses a foreign tap"); break;
        case Tap.duringCast: check(result == SpellCastResult.ok && !landed, "Polymorph rechecks the tap on completion"); break;
        }
    }

    {
        auto w = RealWorld.make();
        auto shaman = w.character(62001, "Healer", 7, 60, [10623u], 2);
        auto ally(uint guid, string name, uint maximum, uint health)
        {
            auto who = w.character(guid, name, 1, 60, [], 2);
            who.session.inWorld.player.values.set!UNIT_FIELD_MAXHEALTH(maximum);
            who.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(health);
            return who;
        }
        auto small = ally(62002, "Small", 1000, 300);
        auto large = ally(62003, "Large", 4000, 2400);
        auto third = ally(62004, "Third", 1000, 400);
        shaman.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(100u);
        assert(w.castAt(shaman, 10623, shaman.session.character.guid) == SpellCastResult.ok);
        w.now += 3000.msecs;
        shaman.session.update(3000.msecs);
        check(large.session.inWorld.player.values.get!UNIT_FIELD_HEALTH > 2400
                && small.session.inWorld.player.values.get!UNIT_FIELD_HEALTH > 300
                && third.session.inWorld.player.values.get!UNIT_FIELD_HEALTH == 400,
            "Chain Heal prioritizes the two largest absolute health deficits");
    }

    {
        auto w = RealWorld.make();
        const trap = drCategory(*w.context.data.spells.spell(3355));
        bool sameCategory = trap != DrCategory.none;
        foreach (id; [14308u, 14309, 19503, 19386, 24132, 24133])
            sameCategory = sameCategory && drCategory(*w.context.data.spells.spell(id)) == trap;
        check(sameCategory, "Freezing Trap shares diminishing returns with Scatter Shot and Wyvern Sting");

        auto rogue = w.character(62222, "Shadow", 4, 60, [1856u, 1784u]);
        rogue.session.inWorld.storeLoot(5140, 1, 0, false); // Flash Powder
        assert(w.cast_(rogue, 1856) == SpellCastResult.ok);
        auto auras = &rogue.session.inWorld.player.auras;
        assert(auras.find(11327) !is null && auras.find(1784) !is null);
        ByteWriter cancel;
        cancel.put(1784u);
        rogue.write(Opcode.CMSG_CANCEL_AURA, cancel.data);
        check(auras.find(1784) is null && auras.find(11327) is null, "Cancelling Stealth also ends Vanish");
    }

    {
        auto w = RealWorld.make();
        auto warrior = w.character(62005, "Fighter", 1, 60, [2457u, 11585u]);
        auto me = warrior.session.inWorld;
        const dodger = w.enemy(warrior), other = w.enemy(warrior);
        warrior.write(Opcode.CMSG_SET_SELECTION, ClientGuid(dodger));
        me.swingDodgedBy(dodger, MeleeHitOutcome.dodge);
        assert(me.comboPoints && me.comboTarget == dodger);
        warrior.write(Opcode.CMSG_SET_SELECTION, ClientGuid(dodger));
        check(me.comboPoints != 0 && me.comboTarget == dodger, "Re-selecting the dodger preserves Overpower");
        warrior.write(Opcode.CMSG_SET_SELECTION, ClientGuid(other));
        warrior.write(Opcode.CMSG_SET_SELECTION, ClientGuid(dodger));
        check(me.comboPoints == 0, "Switching targets consumes the Overpower opportunity");
    }

    assert(!failures, "trainer spell discrepancies above");
}
