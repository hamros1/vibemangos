/**
 * Spells tested on the real data: the client's DBC files and the world database the server runs on, not spells made
 * up for a test. A test with invented fields agrees with the code's own assumptions (Cold Snap passed while Ice
 * Block, whose cooldown is its category's, was never reset); one with the real rows does not.
 *
 * These run only where `DMANGOS_REAL_DATA` names the data, as `dataDir|mysqlLibrary|worldConnection` (the
 * connection as `world_database` has it): the full check (tools/harness/check.sh) sets it, with the harness's
 * database; elsewhere they do nothing. The data is loaded once for all of them.
 */
module dmangos.world.realspelltests;

version (unittest):

import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import dmangos.auth.accounts : AccountLevel;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.context : WorldContext;
import dmangos.world.database : MemoryWorldDatabase;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : CharacterData, Player;
import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.testclient;
import dmangos.world.testdata : raceHuman;
import dmangos.world.worlddata : WorldData;

private __gshared ClientData realClient;
private __gshared WorldData realWorldData;
private __gshared bool realLoaded, realTried;

/// The real data, loaded at the first call; false (nothing to test against) without `DMANGOS_REAL_DATA`.
bool haveRealData()
{
    import std.array : split;
    import std.process : environment;
    import dmangos.mysql : ConnectionInfo, MySqlConnection;

    if (realTried)
        return realLoaded;
    realTried = true;
    const named = environment.get("DMANGOS_REAL_DATA");
    if (named is null)
        return false;
    const parts = named.split("|");
    assert(parts.length == 3, "DMANGOS_REAL_DATA: dataDir|mysqlLibrary|worldConnection");
    realClient = ClientData.load(parts[0]);
    auto world = new MySqlConnection(ConnectionInfo.parse(parts[2]), parts[1]);
    scope (exit)
        world.close();
    realWorldData = WorldData.load(world, realClient);
    realLoaded = true;
    return true;
}

/// A world on the real data, characters in memory, its clock the test's.
struct RealWorld
{
    MemoryWorldDatabase db;
    WorldContext context;
    MonoTime now;

    static RealWorld make()
    {
        RealWorld w;
        w.db = newDatabase();
        WorldConfig config;
        config.logoutDelay = 0;
        w.context = new WorldContext(config, w.db, realWorldData, realClient);
        w.now = MonoTime.currTime;
        return w;
    }

    /// A character of `classId` and `level` in Stormwind's Trade District, logged in, knowing `spells`.
    TestClient character(uint guid, string name, ubyte classId, uint level, const(uint)[] spells)
    {
        auto clock = &now;
        context.clock = () => *clock;
        auto client = loggedIn(context, db, guid, name, Position(-8835, 615, 93), AccountLevel.player, raceHuman, 0,
            level, (ref CharacterData c) { c.classId = classId; });
        auto me = cast(Player) client.session.character;
        {
            import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1, UNIT_FIELD_POWER1;

            foreach (power; 0 .. 5) // full, as a rested character is (the record in memory saved none)
                me.values.set!UNIT_FIELD_POWER1(power, me.values.get!UNIT_FIELD_MAXPOWER1(power));
        }
        foreach (spell; spells)
            if (!me.knowsSpell(spell))
                me.spells ~= spell;
        client.read();
        return client;
    }

    /// A hostile creature of `entry` (6: a Kobold Vermin) two yards in front of `who`, its guid.
    ulong enemy(ref TestClient who, uint entry = 6)
    {
        import dmangos.world.creature : TempSpawnType;

        auto me = cast(Player) who.session.character;
        auto at = me.position;
        at.x += 2;
        auto creature = context.summonCreature(context.map(0), entry, at, TempSpawnType.manual, 0, 0);
        assert(creature !is null, "no such creature in the world database");
        who.read();
        return creature.guid;
    }

    /// Casts `spell` at `target`.
    SpellCastResult castAt(ref TestClient who, uint spell, ulong target)
    {
        const info = context.data.spells.spell(spell);
        assert(info !is null, "no such spell in the world database");
        return who.session.inWorld.castSpell(info, SpellTargets(TargetFlags.unit, target), false, 0);
    }

    /// Casts `spell` (from the real data) on oneself.
    SpellCastResult cast_(ref TestClient who, uint spell)
    {
        const info = context.data.spells.spell(spell);
        assert(info !is null, "no such spell in the world database");
        return who.session.inWorld.castSpell(info, SpellTargets(TargetFlags.self, 0), false, 0);
    }
}

enum ubyte classMageId = 8, classRogueId = 4, classWarriorId = 1;

/// Cold Snap (12472) makes Ice Block (11958) ready again: its cooldown is its category's (37), not its own.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint iceBlock = 11958, coldSnap = 12472;
    auto mage = w.character(1, "Jaina", classMageId, 60, [iceBlock, coldSnap]);
    auto me = mage.session.inWorld;
    {
        const r = w.cast_(mage, iceBlock);
        import std.format : format;
        assert(r == SpellCastResult.ok, format!"Ice Block refused: %s"(r));
    }
    assert(!me.spellIsReady(iceBlock), "Ice Block cooling down");
    // Out of the block (it stuns its mage: no Cold Snap inside it), past the global cooldown.
    if (auto aura = me.player.auras.find(iceBlock))
        me.removeAura(aura);
    w.now += 2.seconds;
    mage.read();
    assert(w.cast_(mage, coldSnap) == SpellCastResult.ok);
    assert(me.spellIsReady(iceBlock), "Cold Snap made Ice Block ready");
    assert(mage.read().canFind!(p => p.opcode == Opcode.SMSG_CLEAR_COOLDOWN), "the client told");
}

/// Presence of Mind (12043): its cooldown waits for its aura to end, then starts and the client is told.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint presenceOfMind = 12043, frostbolt = 116;
    auto mage = w.character(2, "Antonidas", classMageId, 60, [presenceOfMind, frostbolt]);
    auto me = mage.session.inWorld;
    assert(w.cast_(mage, presenceOfMind) == SpellCastResult.ok);
    assert(me.player.auras.find(presenceOfMind) !is null, "its aura on");
    assert(!me.spellIsReady(presenceOfMind), "held while its aura lasts");
    mage.read();
    w.now += 2.seconds;
    // Its charge spent by the next spell with a cast time: the aura goes, the cooldown starts.
    const kobold = w.enemy(mage);
    me.player.movement.position.orientation = 0; // facing it (east)
    assert(w.castAt(mage, frostbolt, kobold) == SpellCastResult.ok);
    assert(me.player.auras.find(presenceOfMind) is null, "spent by Frostbolt");
    assert(mage.read().canFind!(p => p.opcode == Opcode.SMSG_COOLDOWN_EVENT), "the client's cooldown starts");
    assert(!me.spellIsReady(presenceOfMind));
}

/// The first backpack slot holding item `entry`.
private ubyte backpackSlot(Player me, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;

    foreach (ubyte s; 23 .. 39)
        if (const item = me.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
                return s;
    assert(false, "not in the backpack");
}

/**
 * An item's own cooldown category: the Swiftness Potion (2459, spell 2379 of no category; the item's
 * spellcategory_1 4) waits on the Major Healing Potion (13446, category 4, two minutes).
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto w = RealWorld.make();
    enum uint majorHealing = 13446, swiftness = 2459, speed = 2379;
    auto hero = w.character(3, "Drinker", classWarriorId, 60, []);
    auto me = cast(Player) hero.session.character;
    hero.session.inWorld.storeLoot(majorHealing, 1, 0, false);
    hero.session.inWorld.storeLoot(swiftness, 1, 0, false);
    me.values.set!UNIT_FIELD_HEALTH(1u); // hurt: the potion has something to heal
    hero.read();
    void use(uint entry)
    {
        ByteWriter b;
        b.put(inventorySlotBag0);
        b.put(backpackSlot(me, entry));
        b.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(b);
        hero.write(Opcode.CMSG_USE_ITEM, b.data.dup);
        hero.read();
    }
    use(majorHealing);
    assert(me.inventory.count(majorHealing) == 0, "drunk");
    w.now += 2.seconds;
    use(swiftness);
    assert(me.inventory.count(swiftness) == 1 && me.auras.find(speed) is null, "the potions' category 4 waits");
    w.now += 120.seconds;
    use(swiftness);
    assert(me.inventory.count(swiftness) == 0 && me.auras.find(speed) !is null, "two minutes on");
}

/**
 * Pick Lock (1804) by a level 60 rogue: its lockpicking skill counts, not its level. A Heavy Junkbox (16885: Lock.dbc
 * 599, lockpicking 250) is beyond lockpicking 10, within 300.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.defines : inventorySlotBag0;

    auto w = RealWorld.make();
    enum uint pickLock = 1804, junkbox = 16885, lockpicking = 633;
    auto rogue = w.character(4, "Picker", classRogueId, 60, [pickLock]);
    auto me = cast(Player) rogue.session.character;
    rogue.session.inWorld.storeLoot(junkbox, 1, 0, false);
    rogue.session.inWorld.storeLoot(5060, 1, 0, false); // Thieves' Tools, its Totem1
    rogue.read();
    SpellTargets t;
    t.mask = TargetFlags.item;
    t.item = me.inventory[inventorySlotBag0, backpackSlot(me, junkbox)].fullGuid;
    const info = w.context.data.spells.spell(pickLock);
    me.setSkill(lockpicking, 10, 300);
    assert(rogue.session.inWorld.castSpell(info, t, false, 0) == SpellCastResult.lowCastLevel, "10 against 250");
    me.setSkill(lockpicking, 300, 300);
    {
        import std.format : format;

        const r = rogue.session.inWorld.castSpell(info, t, false, 0);
        assert(r == SpellCastResult.ok, format!"300 against 250: %s"(r));
    }
}

/**
 * Invisibility detection takes the strongest of a type: Detect Lesser Invisibility (132) and Detect Invisibility
 * (2970) together do not see through Greater Invisibility (10228); Detect Greater Invisibility (11743) does.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.auras : AuraSet, makeAura;
    import dmangos.world.spellcast : effectValue;
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.updatefields : TypeId;

    auto w = RealWorld.make();
    auto hiddenValues = UpdateValues(TypeId.unit), seeingValues = UpdateValues(TypeId.unit);
    AuraSet hidden, seeing;
    void put(ref AuraSet set, ref UpdateValues values, uint id)
    {
        const info = w.context.data.spells.spell(id);
        assert(info !is null);
        bool isNew;
        set.apply(makeAura(info, 1, 60, 60_000, true, [effectValue(*info, 0, 60, 0), 0, 0]), values, isNew);
    }
    put(hidden, hiddenValues, 10228);
    put(seeing, seeingValues, 132);
    put(seeing, seeingValues, 2970);
    assert(!seeing.seesThroughInvisibility(hidden), "100 and 200 are not 300");
    put(seeing, seeingValues, 11743);
    assert(seeing.seesThroughInvisibility(hidden));
}
