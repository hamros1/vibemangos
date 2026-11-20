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
import dmangos.world.testdata : raceHuman, raceOrc;
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

    /// A character of `classId` and `level` (a human, else of `race`) in Stormwind's Trade District, logged in,
    /// knowing `spells`.
    TestClient character(uint guid, string name, ubyte classId, uint level, const(uint)[] spells,
        ubyte race = raceHuman)
    {
        auto clock = &now;
        context.clock = () => *clock;
        auto client = loggedIn(context, db, guid, name, Position(-8835, 615, 93), AccountLevel.player, race, 0,
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

enum ubyte classShamanId = 7;

/// Fire Power rank 2 (12378): 4% more Fireball (133) damage, by its first rank's `spell_affect` mask (0x8C20017).
unittest
{
    import dmangos.world.spellmods : applySpellMod, SpellModOp;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint firePower = 12378, fireball = 133;
    auto mage = w.character(10, "Kaelthas", classMageId, 60, [firePower]);
    auto me = mage.session.inWorld;
    me.applyPassive(w.context.data.spells.spell(firePower));
    assert(me.player.auras.find(firePower) !is null);
    assert(applySpellMod(me.player.auras.list, SpellModOp.damage, *w.context.data.spells.spell(fireball), 1000) == 1040,
        "4% more");
}

/// `who` takes the weapon `entry` and wields it (Kidney Shot and Sunder Armor need one: `EquippedItemClass` 2).
private void wield(ref TestClient who, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    auto me = who.session.inWorld;
    me.storeLoot(entry, 1, 0, false);
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
            {
                who.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, s));
                break;
            }
    who.read();
    assert(me.player.inventory.equipped(15) !is null && me.player.inventory.equipped(15).entry == entry, "wielded");
}

/**
 * Reincarnation (21169): its hour is its category's (1161; RecoveryTime 0), less Improved Reincarnation rank 2's
 * twenty minutes (16209, whose mask is its first rank's `spell_affect` row).
 */
unittest
{
    import dmangos.world.player : DeathState;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields : PLAYER_SELF_RES_SPELL;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint passive = 20608, reincarnation = 21169, improved = 16209, ankh = 17030;
    auto thrall = w.character(3, "Thrall", classShamanId, 60, [passive, improved], raceOrc);
    auto me = thrall.session.inWorld;
    me.applyPassive(w.context.data.spells.spell(improved));
    assert(me.player.auras.find(improved) !is null, "the talent's aura");
    me.storeLoot(ankh, 1, 0, false);
    thrall.read();
    me.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(me.player.values.get!PLAYER_SELF_RES_SPELL == reincarnation, "offered");
    thrall.write(Opcode.CMSG_SELF_RES, null);
    assert(me.player.deathState == DeathState.alive, "back");
    assert(!me.spellIsReady(reincarnation), "its category's cooldown started");
    w.now += 39 * 60.seconds;
    assert(!me.spellIsReady(reincarnation), "forty minutes with the talent");
    w.now += 2 * 60.seconds;
    assert(me.spellIsReady(reincarnation), "not the hour: the talent's rank 2 counts");
}

/**
 * Items of one cooldown category of their own share it though their spells have none: Restoring Balm (1970) is not
 * ready right after a Crystal Basilisk Spine (1703); both `spellcategory_1` 1153, two minutes.
 */
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.defines : inventorySlotBag0;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint spine = 1703, balm = 1970;
    auto user = w.character(4, "Brann", classWarriorId, 60, []);
    auto me = user.session.inWorld;
    me.storeLoot(spine, 1, 0, false);
    me.storeLoot(balm, 1, 0, false);
    user.read();
    ubyte slotOf(uint entry)
    {
        foreach (ubyte s; 23 .. 39)
            if (const item = me.player.inventory[inventorySlotBag0, s])
                if (item.entry == entry)
                    return s;
        assert(false, "not in the backpack");
    }
    // The cast result of using `entry` at oneself.
    ubyte use(uint entry)
    {
        ByteWriter w;
        w.put(ubyte(inventorySlotBag0));
        w.put(slotOf(entry));
        w.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(w);
        user.write(Opcode.CMSG_USE_ITEM, w.data);
        foreach (p; user.read())
            if (p.opcode == Opcode.SMSG_CAST_RESULT)
            {
                auto r = ByteReader(p.body_);
                r.read!uint;
                return r.read!ubyte == 0 ? 0 : r.read!ubyte;
            }
        assert(false, "no cast result");
    }
    assert(use(spine) == 0, "the spine used");
    w.now += 2.seconds;
    assert(use(balm) == SpellCastResult.notReady, "the balm shares its category's two minutes");
    w.now += 119.seconds;
    assert(use(balm) == 0);
}

/// Bloodrage (2687) costs a fifth of the base health (`PowerType` -2, `ManaCostPercentage` 20), taken as health.
unittest
{
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint bloodrage = 2687;
    auto warrior = w.character(5, "Varian", classWarriorId, 60, [bloodrage]);
    auto me = warrior.session.inWorld;
    const health = me.player.values.get!UNIT_FIELD_HEALTH, cost = me.player.stats.baseHealth * 20 / 100;
    assert(w.cast_(warrior, bloodrage) == SpellCastResult.ok);
    assert(me.player.values.get!UNIT_FIELD_HEALTH == health - cost, "a fifth of the base health");
}

/// An interrupt stops a channel too, and locks its school out: Arcane Missiles (5143) channelled at a kobold.
unittest
{
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint missiles = 5143;
    auto mage = w.character(6, "Aegwynn", classMageId, 60, [missiles]);
    auto me = mage.session.inWorld;
    const kobold = w.enemy(mage);
    me.player.movement.position.orientation = 0; // facing it (east)
    assert(w.castAt(mage, missiles, kobold) == SpellCastResult.ok);
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == missiles, "channelling");
    me.castInterruptedBy(kobold, 4000); // a Kick, a Pummel
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == 0, "the channel interrupted");
    w.now += 2.seconds;
    assert(w.castAt(mage, missiles, kobold) == SpellCastResult.notReady, "arcane locked out");
}

/**
 * Kidney Shot rank 1 (408) lasts nothing at no combo point and a second a point (`SpellDuration` 187: 0 to 5000):
 * two points, two seconds.
 */
unittest
{
    import dmangos.world.creature : Creature;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint kidneyShot = 408;
    auto rogue = w.character(7, "Garona", classRogueId, 60, [kidneyShot]);
    auto me = rogue.session.inWorld;
    wield(rogue, 2092); // a Worn Dagger
    me.player.movement.position.orientation = 0; // facing east, where each kobold stands
    foreach (attempt; 0 .. 20) // a kobold may dodge it: another (no diminishing) until one is stunned
    {
        const kobold = w.enemy(rogue);
        me.addComboPoints(kobold, 2);
        w.now += 21.seconds; // its cooldown, the global one
        const result = w.castAt(rogue, kidneyShot, kobold);
        import std.format : format;
        assert(result == SpellCastResult.ok, format!"Kidney Shot refused: %s"(result));
        auto creature = w.context.map(0).creatureAt(kobold);
        if (auto stun = creature.auras.find(kidneyShot))
        {
            assert(stun.maxDuration == 2000, "two points, two seconds");
            return;
        }
    }
    assert(false, "never stunned");
}

/// Two warriors' Sunder Armor (11597) on one kobold: one stack of the two, not a stack each.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint sunder = 11597;
    auto first = w.character(8, "Lothar", classWarriorId, 60, [sunder]);
    auto second = w.character(9, "Danath", classWarriorId, 60, [sunder]);
    wield(first, 25); // a Worn Shortsword each
    wield(second, 25);
    const kobold = w.enemy(first);
    foreach (who; [first, second])
        who.session.inWorld.player.movement.position.orientation = 0; // facing it (east)
    auto creature = w.context.map(0).creatureAt(kobold);
    uint sunders()
    {
        uint n;
        foreach (aura; creature.auras.list)
            n += aura.spell.id == sunder;
        return n;
    }
    // Each sunders until one lands (a kobold may dodge).
    foreach (who; [first, second])
    {
        const before = creature.auras.find(sunder) is null ? 0 : creature.auras.find(sunder).stacks;
        foreach (attempt; 0 .. 20)
        {
            w.now += 2.seconds;
            w.castAt(who, sunder, kobold);
            const now = creature.auras.find(sunder) is null ? 0 : creature.auras.find(sunder).stacks;
            if (now > before || sunders() > 1)
                break;
        }
    }
    assert(sunders() == 1, "one Sunder Armor");
    assert(creature.auras.find(sunder).stacks == 2, "of both warriors' stacks");
}
