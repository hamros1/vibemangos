/**
 * The spell scripts of items, quests and the world in the world (`dmangos.scripts.worldspells` and the zones'):
 * food's chewing at the heartbeat, an opening that calls the enemies near, a capture refused at the wrong
 * creature, a statue's stone skin, a hex that ends in its curses, the Wondervolt's shapes and hate halved.
 */
module dmangos.world.worldspelltests;

version (unittest):

import core.time : msecs;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes : ByteReader;
import dmangos.world.creature : Creature, CreatureSpawn;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.spellids;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.updatefields;

private enum Position here = Position(-8949.95f, -132.49f, 83.53f);

/// A spell of one effect for the tests, named for its script.
private const(SpellInfo)* scripted(imported!"dmangos.world.context".WorldContext context, uint id, SpellEffect effect,
    string script, AuraType aura = AuraType.none, ImplicitTarget target = ImplicitTarget.caster, int amplitude = 0, int misc = 0)
{
    auto spell = SpellInfo(id);
    spell.effect[0] = effect;
    spell.implicitTargetA[0] = target;
    spell.casting.applyAuraName[0] = aura;
    spell.casting.amplitude[0] = amplitude;
    spell.miscValue[0] = misc;
    context.data.spells.spells[id] = spell;
    if (script.length)
        context.data.spellScriptNames[id] = script;
    return id in context.data.spells.spells;
}

/// A creature of `entry` (the test world's innkeeper, renamed) beside the player.
private Creature creatureBeside(imported!"dmangos.world.context".WorldContext context, uint entry, uint guid,
    uint faction = 0)
{
    auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
    t.entry = entry;
    if (faction)
        t.faction = faction;
    context.data.creatureTemplates[entry] = t;
    CreatureSpawn spawn = {guid: guid, entry: entry, map: mapEasternKingdoms, x: here.x + 3, y: here.y, z: here.z};
    auto creature = context.makeCreature(&spawn);
    context.map(mapEasternKingdoms).addObject(creature);
    return creature;
}

/// The visual kits of the `SMSG_PLAY_SPELL_VISUAL`s among `packets`.
private uint[] visuals(ServerPacketRead[] packets)
{
    uint[] kits;
    foreach (p; packets)
        if (p.opcode == Opcode.SMSG_PLAY_SPELL_VISUAL)
        {
            auto r = ByteReader(p.body_);
            r.read!ulong;
            kits ~= r.read!uint;
        }
    return kits;
}

/// Food (`spell_food_animation`): the eater chews at its heartbeat, every five seconds, while it eats.
unittest
{
    import core.time : Duration, MonoTime;
    import dmangos.world.auras : makeAura;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto food = scripted(context, 433, SpellEffect.applyAura, "spell_food_animation", AuraType.modRegen);
    auto eater = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    eater.read();
    uint[] chews(uint seconds)
    {
        uint[] kits;
        foreach (_; 0 .. seconds)
        {
            now += 1000.msecs;
            context.update(now);
            kits ~= visuals(eater.read());
        }
        return kits;
    }

    assert(chews(10) == [], "not eating");
    auto session = eater.session.inWorld;
    session.addAura(makeAura(food, session.player.guid, 10, 60_000, true, [10, 0, 0]));
    assert(chews(5) == [406], "it chews at the heartbeat");
    assert(chews(10) == [406, 406], "every five seconds");
}

/**
 * An opening (`spell_gameobject_call_for_help_on_usage`): as it begins, the enemies within twelve yards of the
 * player come for it.
 */
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto opening = scripted(context, 6477, SpellEffect.dummy, "spell_gameobject_call_for_help_on_usage");
    auto miner = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    miner.read();
    enum uint players = 1, monsters = 8;
    const own = miner.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[own, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    auto guard = creatureBeside(context, 1501, 90101, 14);
    assert(!guard.ai.inCombat);
    auto session = miner.session.inWorld;
    session.castSpell(opening, SpellTargets(TargetFlags.self, 0), true, 0);
    assert(guard.ai.inCombat && guard.ai.threatOf(session.player.guid) >= 0, "the enemy near comes");
}

/// A Muisek vessel (`spell_capture_treant`): only at a treant; at another creature, an invalid target.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto vessel = scripted(context, 11885, SpellEffect.dummy, "spell_capture_treant", AuraType.none, ImplicitTarget.unit);
    auto druid = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 40);
    druid.read();
    auto session = druid.session.inWorld;
    auto wrong = creatureBeside(context, 7808, 90102); // a wildkin
    auto treant = creatureBeside(context, 7584, 90103);
    assert(session.castSpell(vessel, SpellTargets(TargetFlags.unit, wrong.guid), true, 0) == SpellCastResult.badTargets);
    assert(session.castSpell(vessel, SpellTargets(TargetFlags.unit, treant.guid), true, 0) == SpellCastResult.ok);
}

/// Stoned (`spell_stoned`): under its stone skin a statue can be neither fought nor spoken to and stands still;
/// without it, it can again.
unittest
{
    import dmangos.world.defines : UnitFlags;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    scripted(context, 10255, SpellEffect.applyAura, "spell_stoned", AuraType.dummy);
    scripted(context, 10254, SpellEffect.dummy, "");
    auto map = context.map(mapEasternKingdoms);
    auto statue = creatureBeside(context, 4857, 90104);
    enum uint stone = UnitFlags.immuneToPlayer | UnitFlags.immuneToNpc | UnitFlags.uninteractible;
    assert((statue.values.get!UNIT_FIELD_FLAGS & stone) == 0);
    statue.ai.castFor(map, 10255, statue.guid, true);
    assert(statue.auras.find(10255) !is null);
    assert((statue.values.get!UNIT_FIELD_FLAGS & stone) == stone && statue.scriptRooted, "stone");
    map.unit(statue.guid).auraRemovedBy(10255);
    assert((statue.values.get!UNIT_FIELD_FLAGS & stone) == 0 && !statue.scriptRooted, "awake");
}

/// Hex of Jammal'an (`spell_hex_of_jammalan`): held to its end, its caster's two curses follow; taken off, nothing.
unittest
{
    import core.time : MonoTime;
    import dmangos.world.auras : makeAura;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto hex = scripted(context, 12479, SpellEffect.applyAura, "spell_hex_of_jammalan", AuraType.dummy);
    foreach (curse; [12480u, 12483])
        scripted(context, curse, SpellEffect.applyAura, "", AuraType.dummy, ImplicitTarget.enemy);
    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 45);
    hero.read();
    auto session = hero.session.inWorld;
    auto jammalan = creatureBeside(context, 5710, 90105);
    session.addAura(makeAura(hex, jammalan.guid, 54, 10_000, false, [0, 0, 0]));
    session.removeAura(session.player.auras.find(12479));
    assert(!session.hasAuraOf(12480), "taken off: no curse");
    session.addAura(makeAura(hex, jammalan.guid, 54, 10_000, false, [0, 0, 0]));
    foreach (_; 0 .. 11)
    {
        now += 1000.msecs;
        context.update(now);
    }
    assert(!session.hasAuraOf(12479) && session.hasAuraOf(12480) && session.hasAuraOf(12483), "its end: both curses");
}

/// The Wondervolt's trap (`spell_wondervolt_trap`): who it is cast at takes one of its four shapes.
unittest
{
    import dmangos.scripts.worldobjects : Wondervolt;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto trap = scripted(context, 26275, SpellEffect.scriptEffect, "spell_wondervolt_trap", AuraType.none,
        ImplicitTarget.unit);
    foreach (shape; Wondervolt.transformations) // each a creature's shape (one the test world lacks)
        scripted(context, shape, SpellEffect.applyAura, "", AuraType.transform, ImplicitTarget.caster, 0, 15838);
    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    auto session = hero.session.inWorld;
    auto v = &session.player.values;
    const own = v.get!UNIT_FIELD_NATIVEDISPLAYID;
    session.castSpell(trap, SpellTargets(TargetFlags.self, 0), true, 0);
    uint taken;
    foreach (shape; Wondervolt.transformations)
        if (session.hasAuraOf(shape))
            taken = shape;
    size_t shapes;
    foreach (shape; Wondervolt.transformations)
        shapes += session.hasAuraOf(shape);
    assert(shapes == 1);
    assert(v.get!UNIT_FIELD_DISPLAYID == 16358, "a creature the world lacks: the pink pig, as CMaNGOS shows");
    session.removeAura(session.player.auras.find(taken));
    assert(v.get!UNIT_FIELD_DISPLAYID == own, "itself again");
}

/// The Orb of Deception (`spell_orb_of_deception`): a human man looks like an orc man of the other side.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto orb = scripted(context, 16739, SpellEffect.applyAura, "spell_orb_of_deception", AuraType.transform);
    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    auto session = hero.session.inWorld;
    auto v = &session.player.values;
    v.set!UNIT_FIELD_NATIVEDISPLAYID(49u); // a human man
    v.set!UNIT_FIELD_DISPLAYID(49u);
    session.castSpell(orb, SpellTargets(TargetFlags.self, 0), true, 0);
    assert(v.get!UNIT_FIELD_DISPLAYID == 10137);
    session.removeAura(session.player.auras.find(16739));
    assert(v.get!UNIT_FIELD_DISPLAYID == 49);
}

/// Mark of Kazzak (`spell_mark_of_lord_kazzak`): it drains mana each second; drained dry, the marked one bursts.
unittest
{
    import core.time : MonoTime;
    import dmangos.world.auras : makeAura;
    import dmangos.world.defines : Power;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto mark = scripted(context, 21056, SpellEffect.applyAura, "spell_mark_of_lord_kazzak", AuraType.periodicManaLeech,
        ImplicitTarget.enemy, 1000);
    scripted(context, 21058, SpellEffect.dummy, "");
    auto hunter = loggedIn(context, db, 7, "Thrall", here, AccountLevel.player, raceOrc, mapEasternKingdoms, 60);
    hunter.read();
    auto session = hunter.session.inWorld;
    auto v = &session.player.values;
    const top = v.get!UNIT_FIELD_MAXPOWER1(Power.mana);
    assert(top > 0, "a hunter has mana");
    v.set!UNIT_FIELD_POWER1(Power.mana, top);
    auto kazzak = creatureBeside(context, 12397, 90107);
    void second()
    {
        now += 1000.msecs;
        context.update(now);
    }

    second(); // the session's clock starts
    v.set!UNIT_FIELD_POWER1(Power.mana, top);
    session.addAura(makeAura(mark, kazzak.guid, 63, 60_000, false, [40, 0, 0]));

    second();
    assert(v.get!UNIT_FIELD_POWER1(Power.mana) < top, "drained");
    foreach (_; 0 .. 60)
        if (session.hasAuraOf(21056))
            second();
    assert(!session.hasAuraOf(21056), "dry: it burst, the mark gone");
}

/// Hate to 50% (`spell_hate_to_half`), a creature's spell: half of its target's threat on it is gone.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto hate = scripted(context, 19707, SpellEffect.scriptEffect, "spell_hate_to_half");
    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 60);
    hero.read();
    auto map = context.map(mapEasternKingdoms);
    auto boss = creatureBeside(context, 11583, 90106);
    boss.ai.attackedBy(hero.session.inWorld.unit, map);
    boss.ai.damageTaken(hero.session.inWorld.unit, 100);
    const guid = hero.session.character.guid;
    const before = boss.ai.threatOf(guid);
    assert(before > 0);
    boss.ai.spellEffectScript(hate, 0, guid, 0);
    assert(boss.ai.threatOf(guid) == before / 2, "half its hate gone");
}

/// Scourge Strike (`spell_scourge_strike`), a creature's spell: it passes a player over (`TargetChecked`).
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto strike = SpellInfo(28265);
    strike.effect[0] = SpellEffect.schoolDamage;
    strike.implicitTargetA[0] = ImplicitTarget.enemy;
    strike.basePoints[0] = 99;
    context.data.spells.spells[28265] = strike;
    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 60);
    hero.read();
    auto map = context.map(mapEasternKingdoms);
    auto guardian = creatureBeside(context, 16384, 90108);
    auto v = &hero.session.inWorld.player.values;
    const health = v.get!UNIT_FIELD_HEALTH;
    guardian.ai.castFor(map, 28265, hero.session.character.guid, true);
    assert(v.get!UNIT_FIELD_HEALTH < health, "without its script it strikes");
    v.set!UNIT_FIELD_HEALTH(health);
    context.data.spellScriptNames[28265] = "spell_scourge_strike";
    guardian.ai.castFor(map, 28265, hero.session.character.guid, true);
    assert(v.get!UNIT_FIELD_HEALTH == health, "a player passed over");
}

/// The spells CMaNGOS's core scripts by id (`@spellIds`), with no `spell_scripts` row: the Deviate Fish's surprise,
/// a costume of the target's sex, a tribute of the user's race, Hourglass Sand taking the bronze affliction.
unittest
{
    import dmangos.scripts.itemeffects : DeviateFish;
    import dmangos.world.auras : makeAura;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto fish = scripted(context, 8063, SpellEffect.dummy, "");
    foreach (surprise; DeviateFish.surprises)
        scripted(context, surprise, SpellEffect.applyAura, "", AuraType.dummy);
    auto costume = scripted(context, 24717, SpellEffect.scriptEffect, "", AuraType.none, ImplicitTarget.unitRaid);
    foreach (pirate; [24708u, 24709])
        scripted(context, pirate, SpellEffect.applyAura, "", AuraType.dummy);
    auto tribute = scripted(context, 24194, SpellEffect.scriptEffect, "");
    scripted(context, 24105, SpellEffect.applyAura, "", AuraType.dummy); // the human's
    auto sand = scripted(context, 23645, SpellEffect.dummy, "");
    auto bronze = scripted(context, 23170, SpellEffect.applyAura, "", AuraType.dummy);
    assert(8063 !in context.data.spellScriptNames);

    auto hero = loggedIn(context, db, 7, "Varian", here, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    auto session = hero.session.inWorld;
    session.castSpell(fish, SpellTargets(TargetFlags.self, 0), true, 0);
    size_t surprises;
    foreach (surprise; DeviateFish.surprises)
        surprises += session.hasAuraOf(surprise);
    assert(surprises == 1, "one surprise");

    const man = session.player.values.getByte!UNIT_FIELD_BYTES_0(2) == 0;
    session.castSpell(costume, SpellTargets(TargetFlags.self, 0), true, 0);
    assert(session.hasAuraOf(man ? 24708 : 24709) && !session.hasAuraOf(man ? 24709 : 24708), "its own sex's pirate");

    session.castSpell(tribute, SpellTargets(TargetFlags.self, 0), true, 0);
    assert(session.hasAuraOf(24105), "a human's blessing");

    session.addAura(makeAura(bronze, session.player.guid, 63, 60_000, false, [0, 0, 0]));
    session.castSpell(sand, SpellTargets(TargetFlags.self, 0), true, 0);
    assert(!session.hasAuraOf(23170), "the affliction gone");
}
