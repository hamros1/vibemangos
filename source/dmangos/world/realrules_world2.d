/**
 * The rules of docs/FORMULAS.md for stats and regeneration, loot, the economy and the timers of death and PvP,
 * tested on the real data (the client's DBC files, the world database's level stats, spells and items), asserting
 * the sourced numbers. Run only where `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realrules_world2;

version (unittest):

import std.math : isClose;
import dmangos.world.defines : PlayerClass, Stat;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.updatefields;

private enum ubyte raceNightElf = 4, raceDwarf = 3;

/// Health from spirit, a two-second tick out of combat (docs/FORMULAS.md "Health and mana from spirit"): a
/// warrior's spirit × 0.8 + 6, a rogue's × 0.5 + 2; a third more sitting. (It was CMaNGOS's per-tick lines taken
/// a second: twice as much, 1.26 × spirit − 22.6 a second for a warrior.)
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    uint tick(ubyte classId, uint guid, bool sitting)
    {
        auto c = w.character(guid, "Regen", classId, 60, []);
        auto me = cast(Player) c.session.character;
        me.values.set!UNIT_FIELD_HEALTH(1u);
        if (sitting)
            me.values.setByte!UNIT_FIELD_BYTES_1(0, 1);
        me.regenerate(2000, 1, 1, 1, 1);
        return me.values.get!UNIT_FIELD_HEALTH - 1;
    }
    auto warrior = w.character(1, "Spirited", PlayerClass.warrior, 60, []);
    const spirit = float((cast(Player) warrior.session.character).values.get!UNIT_FIELD_STAT0(Stat.spirit));
    assert(spirit > 20, "the real level 60 stats");
    assert(tick(PlayerClass.warrior, 2, false) == cast(uint)(spirit * 0.8f + 6));
    assert(tick(PlayerClass.warrior, 3, true) == cast(uint)((spirit * 0.8f + 6) * 4 / 3), "sitting: a third more");
    auto rogue = w.character(4, "Sly", PlayerClass.rogue, 60, []);
    const rogueSpirit = float((cast(Player) rogue.session.character).values.get!UNIT_FIELD_STAT0(Stat.spirit));
    assert(tick(PlayerClass.rogue, 5, false) == cast(uint)(rogueSpirit * 0.5f + 2));
}

/// Flat health regeneration uses the tooltip's five-second rate across the normal two-second ticks.
unittest
{
    import dmangos.world.spellcast : SpellCastResult;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint weakTrollsBlood = 3219, majorTrollsBlood = 24361, demonArmor = 11735;
    enum uint gripOfCommand = 21172, auraOfBattle = 21174;
    void check(uint guid, uint spell, uint perFiveSeconds, bool inCombat)
    {
        auto c = w.character(guid, "Regen", PlayerClass.warlock, 60, [spell]);
        auto me = cast(Player) c.session.character;
        assert(w.cast_(c, spell) == SpellCastResult.ok);
        assert(me.auras.find(spell) !is null);
        me.values.set!UNIT_FIELD_HEALTH(1u);
        foreach (tick; 1u .. 6u)
        {
            me.regenerate(2000, 0, 1, 1, 1, inCombat);
            assert(me.values.get!UNIT_FIELD_HEALTH == 1 + perFiveSeconds * tick * 2 / 5);
        }
    }
    check(1, weakTrollsBlood, 2, true);
    check(2, majorTrollsBlood, 20, true);
    check(3, demonArmor, 15, false);
    check(4, gripOfCommand, 60, true);
    check(5, auraOfBattle, 40, true);
}

/// ClassicDB's template pool selects a single Akubar the Seer across its installed placements.
unittest
{
    import dmangos.world.worlddata : PoolMember;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto data = w.context.data;
    size_t positions, active;
    foreach (ref spawn; data.creatureSpawns)
        if (spawn.entry == 8298)
        {
            ++positions;
            assert(data.pools.inPool(PoolMember.Kind.creature, spawn.guid));
            active += data.pools.spawns(PoolMember.Kind.creature, spawn.guid);
        }
    assert(positions > 1 && active == 1);
}

/// The five-second rule after a channel paid at its start: as long as it channels (Tranquility, 10 seconds), five
/// seconds after one that is shorter; mana from spirit, a tick, spirit / 5 + 15 for a druid.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint tranquility = 9862, moonfire = 8921;
    auto c = w.character(1, "Malfurion", PlayerClass.druid, 60, [tranquility, moonfire], raceNightElf);
    auto me = cast(Player) c.session.character;
    const spirit = float(me.values.get!UNIT_FIELD_STAT0(Stat.spirit));
    assert(isClose(me.manaRegenPerSecond() * 2, spirit / 5 + 15), "mana a tick");
    assert(w.cast_(c, tranquility) == imported!"dmangos.world.spellcast".SpellCastResult.ok);
    assert(me.spiritPaused == 10_000, "the whole channel");
    me.regenerate(6000, 1, 1, 1, 1);
    assert(me.spiritPaused == 4000 && me.manaRegenPerSecond() == 0, "still channelling past five seconds");
}

/// Spell crit from intellect at level 60: 59.5 intellect a percent for a mage (Blizzard's figure; it was a
/// paladin's 53.77); the other classes' figures as Blizzard gave them.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    float perPercent(ubyte classId, uint guid, ubyte race)
    {
        auto c = w.character(guid, "Caster", classId, 60, [], race);
        auto me = c.session.inWorld;
        const frostbolt = w.context.data.spells.spell(116);
        const before = me.spellCritOf(frostbolt);
        me.player.values.set!UNIT_FIELD_STAT0(Stat.intellect, me.player.values.get!UNIT_FIELD_STAT0(Stat.intellect) + 595);
        return 595 / (me.spellCritOf(frostbolt) - before);
    }
    assert(isClose(perPercent(PlayerClass.mage, 1, 1), 59.5f, 1e-3), "a mage: 59.5");
    assert(isClose(perPercent(PlayerClass.priest, 2, 1), 59.2f, 1e-2), "a priest: 59.2");
    assert(isClose(perPercent(PlayerClass.warlock, 3, 1), 60.5f, 2e-3), "a warlock: 60.6");
    assert(isClose(perPercent(PlayerClass.druid, 4, raceNightElf), 60.0f, 5e-3), "a druid: 60.0");
    assert(isClose(perPercent(PlayerClass.shaman, 5, 2), 59.5f, 1e-3), "a shaman: 59.5");
}

/// Crit and dodge from agility at level 60, as Blizzard gave them: 20 agility a percent of each for most classes,
/// a rogue 29 and 14.5, a hunter 53 and 26.5.
unittest
{
    import dmangos.world.stats : ChanceInputs, meleeChances;

    void check(ubyte classId, float crit, float dodge)
    {
        auto at = (float agility) => meleeChances(ChanceInputs(classId, 60, agility, 0, 300, 300, 300));
        assert(isClose(at(crit * 10).crit - at(0).crit, 10, 1e-4) && isClose(at(dodge * 10).dodge - at(0).dodge, 10, 1e-4));
    }
    check(PlayerClass.warrior, 20, 20);
    check(PlayerClass.paladin, 20, 20);
    check(PlayerClass.mage, 20, 20);
    check(PlayerClass.rogue, 29, 14.5f);
    check(PlayerClass.hunter, 53, 26.5f);
}

/// Auction deposits by AuctionHouse.dbc (a city's 5%, Blackwater's 25%): the two hours' copper rounded down, then
/// times the spans. A Frayed Cloak (1376, sells for 4) is free to list for a day in a city (it cost 2: 4 × 12 × 5%).
unittest
{
    import dmangos.world.auctionhouse : auctionDeposit;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const city = w.context.client.auctionHouses.lookup(1), goblins = w.context.client.auctionHouses.lookup(7);
    assert(city.depositPercent == 5 && city.cutPercent == 5 && goblins.depositPercent == 25 && goblins.cutPercent == 15);
    const cloak = 1376 in w.context.data.items, linen = 2589 in w.context.data.items;
    assert(cloak.details.sellPrice == 4 && linen.details.sellPrice == 13);
    enum uint day = 24 * 60 * 60, eight = 8 * 60 * 60;
    assert(auctionDeposit(*city, day, cloak.details.sellPrice, 1) == 0);
    assert(auctionDeposit(*goblins, day, cloak.details.sellPrice, 1) == 12);
    assert(auctionDeposit(*city, eight, linen.details.sellPrice, 20) == 52);
}

/// Need before greed on the real items and characters: a mage is passed for the mail Stormwind Guard Leggings (6084),
/// with no roll window; the warrior, who can wear mail, rolls for it.
unittest
{
    import dmangos.world.loot : Loot, LootItem, LootRoll, LootRule, Looter;
    import dmangos.world.opcodes : Opcode;
    import std.algorithm.searching : canFind;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto warrior = w.character(1, "Tank", PlayerClass.warrior, 60, []);
    auto mage = w.character(2, "Robe", PlayerClass.mage, 60, []);
    auto tankSession = warrior.session.inWorld, robeSession = mage.session.inWorld;
    const tank = tankSession.player.guid, robe = robeSession.player.guid;
    auto loot = new Loot(9, (ulong guid) => guid == tank ? cast(Looter) tankSession
        : guid == robe ? cast(Looter) robeSession : null);
    loot.rule = LootRule.needBeforeGreed;
    loot.owners[tank] = true;
    loot.owners[robe] = true;
    auto item = new LootItem;
    item.itemId = 6084;
    item.quality = 2;
    item.allowed[tank] = true;
    item.allowed[robe] = true;
    loot.items ~= item;
    warrior.read();
    mage.read();
    assert(new LootRoll(loot, item).tryToStart(0));
    assert(warrior.read().canFind!(p => p.opcode == Opcode.SMSG_LOOT_START_ROLL), "the warrior chooses");
    const seen = mage.read();
    assert(!seen.canFind!(p => p.opcode == Opcode.SMSG_LOOT_START_ROLL), "the mage has no window");
    assert(seen.canFind!(p => p.opcode == Opcode.SMSG_LOOT_ROLL && p.body_[$ - 1] == 1), "but its automatic pass");
}
