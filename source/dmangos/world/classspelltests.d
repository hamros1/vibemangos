/**
 * Session tests of the class abilities (`dmangos.world.classspells`, `dmangos.scripts.spells`): each played
 * through a logged-in player against a hostile creature, with the spells as the world database has them (the
 * fields that matter), asserting what changes and what the client is sent.
 */
module dmangos.world.classspelltests;

import dmangos.world.spellids;

version (unittest):

import core.time : MonoTime, msecs;
import std.algorithm.searching : canFind;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes : ByteReader;
import dmangos.dbc : buildDbc;
import dmangos.world.auras : Aura, makeAura;
import dmangos.world.aurastate;
import dmangos.world.character : Character;
import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat, spellRadiusFormat,
    spellRangeFormat;
import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
import dmangos.world.context : WorldContext;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.database : MemoryWorldDatabase;
import dmangos.world.defines : PlayerClass;
import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : Player;
import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.spells : SpellInfo, SpellProcEvent;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.unit : Blow, dealDamage;
import dmangos.world.updatefields;

/// A player of a class, level 60, beside a hostile creature (level 1, 10000 health, no armor) facing it.
private final class Arena
{
    MemoryWorldDatabase db;
    WorldContext context;
    MonoTime now;
    TestClient hero;
    Character me;
    Player player;
    Map map;
    Creature foe;

    this(ubyte classId)
    {
        db = newDatabase();
        context = newCreationContext(db);
        now = MonoTime.currTime;
        context.clock = () => now;
        static uint bits(float f) { return *cast(uint*) &f; }
        context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
            [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
        context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
            [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            [2u, bits(0), bits(5), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
        context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 10_000, 0, 10_000], [2u, 12_000, 0, 12_000], [3u, 4000, 0, 4000], [4u, -1, 0, -1]]),
            "SpellDuration.dbc");
        context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
            [[12u, bits(100), 0, 0]]), "SpellRadius.dbc");
        hero = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
            raceHuman, mapEasternKingdoms, 60);
        hero.read();
        me = hero.session.inWorld;
        player = cast(Player) hero.session.character;
        player.data.classId = classId;
        map = context.map(mapEasternKingdoms);
        // The creature an enemy of the player's.
        enum uint players = 1, monsters = 8;
        const humans = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, players,
            0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
        foe = context.summonCreature(map, creatureInnkeeper, Position(-8948.5f, -132.49f, 83.53f, 3.14159f),
            TempSpawnType.dead, 0, 0);
        foe.factionTemplate = context.client.factionTemplates.lookup(14);
        foe.values.set!UNIT_FIELD_LEVEL(1u);
        foe.values.set!UNIT_FIELD_MAXHEALTH(10_000u);
        foe.values.set!UNIT_FIELD_HEALTH(10_000u);
        foe.values.set!UNIT_FIELD_RESISTANCES(0, 0u);
        hero.read();
    }

    /// A spell of the world's, with its first effect, its target and amount (`value`; the dice's one included).
    SpellInfo* spell(uint id, SpellEffect effect, ImplicitTarget target, int value = 1)
    {
        SpellInfo s;
        s.id = id;
        s.effect[0] = effect;
        s.implicitTargetA[0] = target;
        s.basePoints[0] = value - 1;
        s.baseDice[0] = 1;
        s.casting.rangeIndex = 1;
        s.casting.dmgClass = DamageClass.magic;
        context.data.spells.spells[id] = s;
        return context.data.spells.spells.edit(id);
    }

    /// `spell`'s effect `i` an aura of `type` (on the effect's target).
    void auraEffect(SpellInfo* s, size_t i, AuraType type, ImplicitTarget target, int value = 0, int misc = 0)
    {
        s.effect[i] = SpellEffect.applyAura;
        s.casting.applyAuraName[i] = type;
        s.implicitTargetA[i] = target;
        s.basePoints[i] = value - 1;
        s.baseDice[i] = 1;
        s.miscValue[i] = misc;
    }

    /// The player casts `id` at `target` (0: itself), as the client asks.
    SpellCastResult cast_(uint id, ulong target = 0)
    {
        return me.castSpell(id in context.data.spells.spells, target ? SpellTargets(TargetFlags.unit, target)
            : SpellTargets(TargetFlags.self, player.guid), false, 0);
    }

    /// Time passes for the player and the map.
    void tick(int ms)
    {
        now += ms.msecs;
        me.update(ms.msecs);
        map.update(ms.msecs);
    }

    /// The damage logs (`SMSG_SPELLNONMELEEDAMAGELOG`) the player was sent since the last read: spell, damage.
    uint[2][] damageLogs()
    {
        uint[2][] logs;
        foreach (p; hero.read())
            if (p.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
            {
                auto r = ByteReader(p.body_);
                r.readPackedGuid();
                r.readPackedGuid();
                const spell = r.read!uint;
                logs ~= [spell, r.read!uint];
            }
        return logs;
    }

    /// The first packet of `opcode` since the last read, its body; null if none.
    ubyte[] packet(ushort opcode)
    {
        foreach (p; hero.read())
            if (p.opcode == opcode)
                return p.body_;
        return null;
    }

    /// A swing of `attacker` at `victim` of `outcome` (and `damage`).
    void swing(bool byFoe, MeleeHitOutcome outcome, uint damage = 0)
    {
        MeleeDamage d;
        d.attacker = byFoe ? foe.guid : player.guid;
        d.target = byFoe ? player.guid : foe.guid;
        d.outcome = outcome;
        d.damage = damage;
        auto foeUnit = map.unitOf(foe);
        if (byFoe)
            dealDamage(foeUnit, me.unit, damage, Blow.swing(d));
        else
            dealDamage(me.unit, foeUnit, damage, Blow.swing(d));
    }

    /// Whether `who` has an aura of `spell`.
    bool hasAura(Creature who, uint spell) { return who.auras.find(spell) !is null; }
    /// ditto
    bool hasAura(uint spell) { return player.auras.find(spell) !is null; }
}

/**
 * The aura states the client reads to allow a spell: a unit under a fifth of its health shows it to everyone
 * (Execute, Hammer of Wrath); a dodge, a parry or a block lets the player answer it for four seconds (Revenge,
 * Mongoose Bite; a hunter's parry: Counterattack); a warrior's dodged swing gives Overpower its point on the dodger.
 */
unittest
{
    auto a = new Arena(PlayerClass.warrior);
    a.foe.values.set!UNIT_FIELD_HEALTH(1999u);
    assert(a.foe.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.healthless20Percent), "under a fifth");
    a.map.flushObjectChanges(a.foe);
    a.hero.read();
    assert(a.hero.view.fields[a.foe.guid][UNIT_FIELD_AURASTATE] & 2, "the client sees it (Execute lights up)");
    a.foe.values.set!UNIT_FIELD_HEALTH(2000u);
    assert(!(a.foe.values.get!UNIT_FIELD_AURASTATE & 2), "a fifth is not under");

    // Revenge: a dodge (and a block) sets the defensive state for four seconds.
    a.swing(true, MeleeHitOutcome.dodge);
    assert(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.defense));
    a.tick(3000);
    a.swing(true, MeleeHitOutcome.block, 5);
    a.tick(3000);
    assert(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.defense), "the block started it again");
    a.tick(1500);
    assert(!(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.defense)), "four seconds on, gone");

    // Overpower: the warrior's swing dodged: a point on the dodger, gone four seconds on.
    a.swing(false, MeleeHitOutcome.dodge);
    assert(a.me.comboPoints == 1 && a.me.comboTarget == a.foe.guid);
    a.tick(4100);
    assert(a.me.comboPoints == 0, "too late for Overpower");

    // A hunter's parry is Counterattack's; a rogue's dodge is not Revenge's kind.
    a.player.data.classId = PlayerClass.hunter;
    a.swing(true, MeleeHitOutcome.parry);
    assert(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.hunterParry));
    a.player.data.classId = PlayerClass.rogue;
    a.swing(true, MeleeHitOutcome.dodge);
    assert(!(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.defense)));
}

/**
 * Execute (`spell_warrior_execute`, `spell_warrior_execute_damage`): its damage spell strikes for its amount and three
 * a point of the rage left after its cost, and the rage is all spent.
 */
unittest
{
    import dmangos.world.defines : Power;

    auto a = new Arena(PlayerClass.warrior);
    with (a.spell(5308, SpellEffect.dummy, ImplicitTarget.enemy, 125))
    {
        casting.dmgClass = DamageClass.melee;
        casting.powerType = Power.rage;
        casting.manaCost = 150;
        casting.targetAuraState = AuraState.healthless20Percent;
        casting.dmgMultiplier[0] = 0.3f;
        casting.spellFamilyName = 4;
        casting.spellFamilyFlags = 0x20000000;
    }
    with (a.spell(20647, SpellEffect.schoolDamage, ImplicitTarget.enemy, 0))
        casting.dmgClass = DamageClass.melee;
    a.context.data.spellScriptNames[5308] = "spell_warrior_execute";
    a.context.data.spellScriptNames[20647] = "spell_warrior_execute_damage";
    a.foe.values.set!UNIT_FIELD_HEALTH(1500u);
    uint[2][] logs;
    foreach (attempt; 0 .. 30) // (until it is not dodged or missed)
    {
        a.tick(2000);
        a.player.values.set!UNIT_FIELD_POWER1(Power.rage, 500u); // (after the tick: rage fades out of combat)
        a.hero.read();
        assert(a.cast_(5308, a.foe.guid) == SpellCastResult.ok);
        logs = a.damageLogs();
        if (logs.canFind!(l => l[0] == 20647 && l[1]))
            break;
    }
    assert(logs.canFind!(l => l[0] == 20647 && (l[1] == 125 + 105 || l[1] == 2 * (125 + 105))),
        "125 and 35 rage at 3 each (a crit twice it)");
    assert(a.player.values.get!UNIT_FIELD_POWER1(Power.rage) == 0, "every point spent");
}

/**
 * Bloodthirst: its damage is 45% of the attack power, and its aura goes on the warrior (healing on its next hits).
 */
unittest
{
    auto a = new Arena(PlayerClass.warrior);
    with (a.spell(23881, SpellEffect.schoolDamage, ImplicitTarget.enemy, 45))
    {
        casting.dmgClass = DamageClass.melee;
        casting.spellFamilyName = 4;
        casting.spellFamilyFlags = 0x2000000;
        casting.spellIconId = 38;
    }
    auto heal = a.spell(23885, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(heal, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    heal.casting.durationIndex = 1;
    a.player.stats.attackPower = 1000;
    uint[2][] logs;
    foreach (attempt; 0 .. 30)
    {
        a.tick(7000);
        a.cast_(23881, a.foe.guid);
        logs = a.damageLogs();
        if (logs.canFind!(l => l[0] == 23881))
            break;
    }
    assert(logs.canFind!(l => l[0] == 23881 && (l[1] == 450 || l[1] == 900)), "45% of 1000 (a crit twice it)");
    assert(a.hasAura(23885), "the healing aura");
}

/**
 * The seals and Judgement (`spell_judgement`): a seal lets the paladin judge (`AURA_STATE_JUDGEMENT`) and puts out
 * the one before; Seal of Righteousness deals holy damage on each swing; Judgement spends the seal for its
 * judgement, which always lands.
 */
unittest
{
    auto a = new Arena(PlayerClass.paladin);
    foreach (id, damage; [21084u: 25741u, 20287u: 25740u])
    {
        auto seal = a.spell(id, SpellEffect.applyAura, ImplicitTarget.caster);
        a.auraEffect(seal, 0, AuraType.dummy, ImplicitTarget.caster, 108);
        a.auraEffect(seal, 2, AuraType.dummy, ImplicitTarget.caster, id == 21084 ? 20187 : 20280);
        with (seal.casting)
        {
            spellFamilyName = 10;
            spellFamilyFlags = 0x8000000;
            procFlags = 0x4;
            procChance = 100;
            durationIndex = 1;
            school = 1;
        }
        with (a.spell(damage, SpellEffect.schoolDamage, ImplicitTarget.enemy, 0))
            casting.school = 1;
    }
    with (a.spell(20271, SpellEffect.scriptEffect, ImplicitTarget.enemy))
    {
        casterAuraState = AuraState.judgement;
        casting.school = 1;
        casting.spellFamilyName = 10;
    }
    with (a.spell(20187, SpellEffect.schoolDamage, ImplicitTarget.enemy, 20))
        casting.school = 1;
    a.context.data.spellScriptNames[20271] = "spell_judgement";

    a.cast_(20287);
    a.tick(2000);
    a.cast_(21084);
    assert(a.hasAura(21084) && !a.hasAura(20287), "one seal at a time");
    assert(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.judgement), "judgement allowed");

    // A swing that lands: the seal's holy damage, by the weapon's speed and damage.
    a.hero.read();
    foreach (attempt; 0 .. 30)
    {
        a.me.swing(a.foe, imported!"dmangos.world.combat".AttackType.mainHand);
        if (a.damageLogs().canFind!(l => l[0] == 25741 && l[1] > 0))
            break;
        assert(attempt < 29, "a swing lands");
    }

    a.tick(2000);
    a.hero.read();
    assert(a.cast_(20271, a.foe.guid) == SpellCastResult.ok);
    assert(a.damageLogs().canFind!(l => l[0] == 20187 && l[1] >= 20), "the judgement strikes");
    assert(!a.hasAura(21084), "the seal spent");
    assert(!(a.player.values.get!UNIT_FIELD_AURASTATE & auraStateFlag(AuraState.judgement)), "nothing left to judge");
}

/**
 * Judgement of Command (`spell_judgement_of_command`): judging Seal of Command strikes with the judgement's damage
 * spell (20467: spell_template gives it no family), at half unless the target is stunned.
 */
unittest
{
    auto a = new Arena(PlayerClass.paladin);
    auto seal = a.spell(20375, SpellEffect.applyAura, ImplicitTarget.caster); // Seal of Command, rank 1
    a.auraEffect(seal, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    a.auraEffect(seal, 2, AuraType.dummy, ImplicitTarget.caster, 20425);
    with (seal.casting)
    {
        school = 1;
        spellFamilyName = 10;
        spellFamilyFlags = 0x2000000;
        spellIconId = 561;
        durationIndex = 1;
    }
    with (a.spell(20271, SpellEffect.scriptEffect, ImplicitTarget.enemy, 0)) // Judgement
    {
        casterAuraState = AuraState.judgement;
        casting.school = 1;
        casting.spellFamilyName = 10;
        casting.spellFamilyFlags = 0x800000;
    }
    a.context.data.spellScriptNames[20271] = "spell_judgement";
    with (a.spell(20425, SpellEffect.dummy, ImplicitTarget.enemy, 20467)) // Judgement of Command, rank 1
    {
        casting.school = 1;
        casting.spellFamilyName = 10;
        casting.spellIconId = 561;
    }
    with (a.spell(20467, SpellEffect.schoolDamage, ImplicitTarget.enemy, 93)) // its damage: no family
    {
        casting.school = 1;
        casting.spellIconId = 561;
        casting.dmgClass = DamageClass.melee;
    }
    uint[] judged()
    {
        uint[] damage;
        foreach (attempt; 0 .. 20)
        {
            a.tick(2000);
            a.cast_(20375);
            a.tick(1600);
            a.hero.read();
            a.cast_(20271, a.foe.guid);
            foreach (l; a.damageLogs())
                if (l[0] == 20467 && l[1])
                    damage ~= l[1];
        }
        return damage;
    }
    assert(judged().canFind!(d => d == 46), "93 halved: the target is not stunned");
    auto stun = a.spell(90101, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(stun, 0, AuraType.modStun, ImplicitTarget.enemy);
    bool isNew;
    a.foe.auras.apply(makeAura(stun, a.player.guid, 60, -1, false, [0, 0, 0]), a.foe.values, isNew);
    assert(judged().canFind!(d => d == 93), "whole against a stunned target");
}

/// Conflagrate: refused without the warlock's Immolate on the target; with it, it strikes and the Immolate goes.
unittest
{
    auto a = new Arena(PlayerClass.warlock);
    auto immolate = a.spell(348, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(immolate, 0, AuraType.periodicDamage, ImplicitTarget.enemy, 8);
    with (immolate.casting)
    {
        school = 2;
        spellFamilyName = 5;
        spellFamilyFlags = 0x4;
        durationIndex = 1;
        amplitude[0] = 3000;
    }
    with (a.spell(17962, SpellEffect.schoolDamage, ImplicitTarget.enemy, 249))
    {
        casting.school = 2;
        casting.spellFamilyName = 5;
        casting.spellFamilyFlags = 0x200;
    }
    assert(a.cast_(17962, a.foe.guid) == SpellCastResult.targetAuraState, "no Immolate");
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.cast_(348, a.foe.guid);
        if (a.hasAura(a.foe, 348))
            break;
    }
    a.hero.read();
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        assert(a.cast_(17962, a.foe.guid) == SpellCastResult.ok);
        if (!a.hasAura(a.foe, 348))
            break;
    }
    assert(a.damageLogs().canFind!(l => l[0] == 17962), "it strikes");
    assert(!a.hasAura(a.foe, 348), "the Immolate consumed");
}

/// Cold Snap: the mage's frost spells with a cooldown are ready again, the client told (`SMSG_CLEAR_COOLDOWN`).
unittest
{
    auto a = new Arena(PlayerClass.mage);
    with (a.spell(122, SpellEffect.dummy, ImplicitTarget.caster))
    {
        recoveryTime = 25_000;
        casting.school = 4;
        casting.spellFamilyName = 3;
    }
    with (a.spell(2136, SpellEffect.dummy, ImplicitTarget.caster)) // fire: not reset
    {
        recoveryTime = 8000;
        casting.school = 2;
        casting.spellFamilyName = 3;
    }
    // Ice Block as spell_template has it: no cooldown of its own, its category's 5 minutes.
    with (a.spell(11958, SpellEffect.dummy, ImplicitTarget.caster))
    {
        recoveryTime = 0;
        category = 37;
        categoryRecoveryTime = 300_000;
        casting.school = 4;
        casting.spellFamilyName = 3;
        casting.spellFamilyFlags = 0x80000;
    }
    with (a.spell(12472, SpellEffect.dummy, ImplicitTarget.caster))
        casting.spellFamilyName = 3;
    a.cast_(122);
    a.cast_(2136);
    a.tick(1600);
    a.cast_(11958);
    assert(!a.me.spellIsReady(122) && !a.me.spellIsReady(2136) && !a.me.spellIsReady(11958));
    a.tick(1600);
    a.hero.read();
    a.cast_(12472);
    uint[] cleared;
    foreach (p; a.hero.read())
        if (p.opcode == Opcode.SMSG_CLEAR_COOLDOWN)
            cleared ~= ByteReader(p.body_).read!uint;
    import std.algorithm.searching : canFind;
    assert(cleared.canFind(122) && cleared.canFind(11958) && !cleared.canFind(2136), "the client told, frost only");
    assert(a.me.spellIsReady(122) && a.me.spellIsReady(11958) && !a.me.spellIsReady(2136), "frost only");
}

/// Preparation (`spell_preparation`): the rogue's other abilities are ready again.
unittest
{
    auto a = new Arena(PlayerClass.rogue);
    with (a.spell(1856, SpellEffect.dummy, ImplicitTarget.caster))
    {
        recoveryTime = 300_000;
        casting.spellFamilyName = 8;
    }
    with (a.spell(14185, SpellEffect.dummy, ImplicitTarget.caster))
        recoveryTime = 600_000;
    a.context.data.spellScriptNames[14185] = "spell_preparation";
    a.cast_(1856);
    a.tick(1600);
    a.cast_(14185);
    assert(a.me.spellIsReady(1856) && !a.me.spellIsReady(14185), "all but itself");
}

/**
 * Life Tap (`spell_life_tap`): health becomes mana through its own spell (31818: the energize log the client
 * shows), more by Improved Life Tap.
 */
unittest
{
    import dmangos.world.defines : Power;

    auto a = new Arena(PlayerClass.warlock);
    with (a.spell(1454, SpellEffect.dummy, ImplicitTarget.caster, 20))
    {
        casting.spellFamilyName = 5;
        casting.spellFamilyFlags = 0x40000;
    }
    with (a.spell(31818, SpellEffect.energize, ImplicitTarget.caster, 0))
        miscValue[0] = Power.mana;
    a.context.data.spellScriptNames[1454] = "spell_life_tap";
    a.player.values.set!UNIT_FIELD_MAXPOWER1(Power.mana, 1000u); // (a warrior's character, with mana)
    a.player.values.set!UNIT_FIELD_POWER1(Power.mana, 0u);
    const health = a.player.values.get!UNIT_FIELD_HEALTH;
    a.hero.read();
    a.cast_(1454);
    auto log = a.packet(Opcode.SMSG_SPELLENERGIZELOG);
    assert(log !is null);
    auto r = ByteReader(log);
    r.readPackedGuid();
    r.readPackedGuid();
    assert(r.read!uint == 31818 && r.read!uint == Power.mana && r.read!uint == 20, "20 mana by 31818");
    assert(a.player.values.get!UNIT_FIELD_HEALTH == health - 20 && a.player.values.get!UNIT_FIELD_POWER1(Power.mana) == 20);

    auto improved = a.spell(18182, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(improved, 0, AuraType.dummy, ImplicitTarget.caster, 10);
    improved.itemType[0] = 0x40000;
    improved.casting.spellFamilyName = 5;
    improved.attributes |= 0x40; // passive
    a.me.addAura(makeAura(improved, a.player.guid, 60, -1, true, [10, 0, 0]));
    a.tick(1600);
    a.cast_(1454);
    assert(a.player.values.get!UNIT_FIELD_POWER1(Power.mana) == 20 + 22, "a tenth more");
}

/**
 * Ignite: a fire spell's crit burns its target for a share of it (rank 1: 4% a tick, on two ticks), through the
 * talent's dummy aura and its `spell_proc_event` (fire, crits only).
 */
unittest
{
    auto a = new Arena(PlayerClass.mage);
    auto ignite = a.spell(11119, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(ignite, 0, AuraType.dummy, ImplicitTarget.caster);
    ignite.casting.procFlags = 0x10000;
    ignite.casting.procChance = 100;
    ignite.casting.spellFamilyName = 3;
    a.context.data.spells.procEvents[11119] = SpellProcEvent(1 << 2, 0, [0, 0, 0], 0, 0x2);
    auto burn = a.spell(12654, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(burn, 0, AuraType.periodicDamage, ImplicitTarget.enemy, 0);
    burn.casting.school = 2;
    burn.casting.durationIndex = 3;
    burn.casting.amplitude[0] = 2000;
    with (a.spell(133, SpellEffect.schoolDamage, ImplicitTarget.enemy, 100))
        casting.school = 2;
    auto sure = a.spell(90100, SpellEffect.applyAura, ImplicitTarget.caster); // every spell crits
    a.auraEffect(sure, 0, AuraType.modSpellCritChance, ImplicitTarget.caster, 100);
    a.me.addAura(makeAura(ignite, a.player.guid, 60, -1, true, [0, 0, 0]));
    a.me.addAura(makeAura(sure, a.player.guid, 60, -1, true, [100, 0, 0]));
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.cast_(133, a.foe.guid);
        if (a.hasAura(a.foe, 12654))
            break;
    }
    auto burning = a.foe.auras.find(12654);
    assert(burning !is null, "it burns");
    assert(burning.amount[0] == 150 * 4 / 100, "4% of the 150 crit a tick");
}

/**
 * Power Word: Shield leaves Weakened Soul on its target, which takes no other shield while it lasts
 * (`SPELL_FAILED_TARGET_AURASTATE`).
 */
unittest
{
    auto a = new Arena(PlayerClass.priest);
    auto shield = a.spell(17, SpellEffect.applyAura, ImplicitTarget.friend);
    a.auraEffect(shield, 0, AuraType.schoolAbsorb, ImplicitTarget.friend, 44, 127);
    with (shield.casting)
    {
        spellFamilyName = 6;
        spellFamilyFlags = 0x1;
        mechanic = 19;
        durationIndex = 1;
    }
    auto weakened = a.spell(6788, SpellEffect.applyAura, ImplicitTarget.friend);
    a.auraEffect(weakened, 0, AuraType.mechanicImmunity, ImplicitTarget.friend, 0, 19);
    weakened.casting.durationIndex = 2;
    assert(a.cast_(17) == SpellCastResult.ok);
    assert(a.hasAura(17) && a.hasAura(6788), "the shield, and Weakened Soul");
    a.tick(11_000);
    assert(!a.hasAura(17) && a.hasAura(6788));
    assert(a.cast_(17) == SpellCastResult.targetAuraState, "no shield while the soul is weak");
}

/// Holy Nova (15237) heals the priest's party by its own spell (23455) though no enemy is near to hurt.
unittest
{
    auto a = new Arena(PlayerClass.priest);
    with (a.spell(15237, SpellEffect.schoolDamage, ImplicitTarget.casterSource, 28))
    {
        casting.implicitTargetB[0] = ImplicitTarget.enemiesAroundSource;
        casting.radiusIndex[0] = 12; // (13, 10 yards, in the world: the test's client data has 12)
        casting.school = 1;
        casting.spellFamilyName = 6;
        casting.spellFamilyFlags = 0x400000;
    }
    with (a.spell(23455, SpellEffect.heal, ImplicitTarget.partyInRange, 52))
    {
        casting.radiusIndex[0] = 12;
        casting.school = 1;
        casting.spellFamilyName = 6;
        casting.spellFamilyFlags = 0x8000000;
    }
    // The creature a friend: nothing to hurt.
    a.foe.factionTemplate = a.context.client.factionTemplates.lookup(a.player.values.get!UNIT_FIELD_FACTIONTEMPLATE);
    a.player.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    a.player.values.set!UNIT_FIELD_HEALTH(500u);
    assert(a.cast_(15237) == SpellCastResult.ok);
    assert(a.player.values.get!UNIT_FIELD_HEALTH >= 552, "healed by 23455");
}

/// Ferocious Bite: the energy left after its cost is damage too (by the multiplier), and is spent.
unittest
{
    import dmangos.world.defines : Power;

    auto a = new Arena(PlayerClass.druid);
    with (a.spell(22568, SpellEffect.schoolDamage, ImplicitTarget.enemy, 50))
    {
        casting.dmgClass = DamageClass.melee;
        casting.spellFamilyName = 7;
        casting.spellFamilyFlags = 0x800000;
        casting.spellVisual = 6587;
        casting.dmgMultiplier[0] = 2.5f;
        casting.powerType = Power.energy;
        casting.manaCost = 35;
        attributesEx = 0x00100000; // a finishing move
    }
    with (a.spell(1082, SpellEffect.addComboPoints, ImplicitTarget.enemy, 1))
        casting.dmgClass = DamageClass.melee;
    uint[2][] logs;
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.player.values.set!UNIT_FIELD_MAXPOWER1(Power.energy, 100u);
        a.player.values.set!UNIT_FIELD_POWER1(Power.energy, 75u);
        a.player.stats.attackPower = 100; // 3 a point
        a.me.clearComboPoints(); // (one point, whatever a miss before left)
        a.me.addComboPoints(a.foe.guid, 1);
        a.hero.read();
        a.cast_(22568, a.foe.guid);
        logs = a.damageLogs();
        if (logs.canFind!(l => l[0] == 22568))
            break;
    }
    assert(logs.canFind!(l => l[0] == 22568 && (l[1] == 50 + 100 + 3 || l[1] == 2 * (50 + 100 + 3))),
        "40 energy at 2.5, and 3% of the attack power for its point");
    assert(a.player.values.get!UNIT_FIELD_POWER1(Power.energy) == 0);
}

/// Swiftmend: refused without a Rejuvenation or Regrowth; it heals all of the shortest one's ticks at once, and
/// consumes it.
unittest
{
    auto a = new Arena(PlayerClass.druid);
    auto rejuvenation = a.spell(774, SpellEffect.applyAura, ImplicitTarget.friend);
    a.auraEffect(rejuvenation, 0, AuraType.periodicHeal, ImplicitTarget.friend, 8);
    with (rejuvenation.casting)
    {
        spellFamilyName = 7;
        spellFamilyFlags = 0x10;
        durationIndex = 2;
        amplitude[0] = 3000;
    }
    a.spell(18562, SpellEffect.heal, ImplicitTarget.friend, 1);
    a.player.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    a.player.values.set!UNIT_FIELD_HEALTH(500u);
    assert(a.cast_(18562) == SpellCastResult.targetAuraState, "nothing to consume");
    a.cast_(774);
    a.tick(1600);
    const before = a.player.values.get!UNIT_FIELD_HEALTH;
    assert(a.cast_(18562) == SpellCastResult.ok);
    assert(!a.hasAura(774), "the Rejuvenation consumed");
    const healed = a.player.values.get!UNIT_FIELD_HEALTH - before;
    assert(healed == 33 || healed == 49, "its own 1 and four ticks of 8 (a crit half again)");
}

/// Lightning Shield: a swing that hits the shaman strikes back with its rank's damage and uses a charge.
unittest
{
    auto a = new Arena(PlayerClass.shaman);
    auto shield = a.spell(324, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(shield, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    shield.triggerSpell[0] = 26545; // not a spell: the rank's damage is
    with (shield.casting)
    {
        spellFamilyName = 11;
        spellFamilyFlags = 0x400;
        spellVisual = 37;
        procFlags = 0x8;
        procChance = 100;
        procCharges = 3;
        durationIndex = 1;
        school = 3;
    }
    with (a.spell(26364, SpellEffect.schoolDamage, ImplicitTarget.enemy, 13))
        casting.school = 3;
    a.cast_(324);
    a.hero.read();
    a.swing(true, MeleeHitOutcome.normal, 10);
    assert(a.damageLogs().canFind!(l => l[0] == 26364 && (l[1] == 13 || l[1] == 19)), "13 nature damage back (a crit half again)");
    assert(a.player.auras.find(324).charges == 2);
    a.swing(true, MeleeHitOutcome.dodge);
    assert(a.player.auras.find(324).charges == 2, "a dodged swing does not strike it");
}

/// Wyvern Sting: as its sleep ends on the creature, its poison follows.
unittest
{
    auto a = new Arena(PlayerClass.hunter);
    auto sting = a.spell(19386, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(sting, 0, AuraType.modStun, ImplicitTarget.enemy);
    with (sting.casting)
    {
        spellFamilyName = 9;
        spellFamilyFlags = 0x10000;
        durationIndex = 1;
        school = 3;
    }
    auto poison = a.spell(24131, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(poison, 0, AuraType.periodicDamage, ImplicitTarget.enemy, 50);
    poison.casting.durationIndex = 2;
    poison.casting.amplitude[0] = 3000;
    poison.casting.school = 3;
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.cast_(19386, a.foe.guid);
        if (a.hasAura(a.foe, 19386))
            break;
    }
    assert(!a.hasAura(a.foe, 24131));
    foreach (_; 0 .. 11)
        a.tick(1000);
    assert(!a.hasAura(a.foe, 19386) && a.hasAura(a.foe, 24131), "awake, and poisoned");
}

/**
 * Windfury Weapon: its proc (an attack power aura and an extra attack) brings one more swing (at the next melee
 * update: `dmangos.world.effecthandlers`); Holy Shield
 * strikes back at a blocked swing (`SPELL_AURA_PROC_TRIGGER_DAMAGE`) and uses a charge.
 */
unittest
{
    // (A warrior's character: the test world has the stats of no shaman, and an attack power aura works them out.)
    auto a = new Arena(PlayerClass.warrior);
    auto windfury = a.spell(8233, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(windfury, 0, AuraType.modAttackPower, ImplicitTarget.caster, 46);
    windfury.effect[1] = SpellEffect.addExtraAttacks;
    windfury.implicitTargetA[1] = ImplicitTarget.caster;
    windfury.baseDice[1] = 1;
    windfury.casting.durationIndex = 1;
    a.hero.write(Opcode.CMSG_ATTACKSWING, imported!"dmangos.world.packets".ClientGuid(a.foe.guid));
    a.tick(10);
    a.cast_(8233);
    assert(a.hasAura(8233), "its attack power");
    a.hero.read();
    a.tick(100);
    assert(a.hero.read().canFind!(p => p.opcode == Opcode.SMSG_ATTACKERSTATEUPDATE), "the extra swing");

    auto shield = a.spell(20925, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(shield, 0, AuraType.modShieldBlockvaluePct, ImplicitTarget.caster, 30);
    a.auraEffect(shield, 1, AuraType.procTriggerDamage, ImplicitTarget.caster, 65);
    with (shield.casting)
    {
        school = 1;
        procFlags = 0x28;
        procChance = 100;
        procCharges = 4;
        durationIndex = 1;
    }
    a.context.data.spells.procEvents[20925] = SpellProcEvent(0, 0, [0, 0, 0], 0, 0x40); // blocks only
    a.cast_(20925);
    a.hero.read();
    a.swing(true, MeleeHitOutcome.normal, 10);
    assert(!a.damageLogs().canFind!(l => l[0] == 20925), "not a block");
    a.swing(true, MeleeHitOutcome.block, 5);
    assert(a.damageLogs().canFind!(l => l[0] == 20925 && l[1] >= 65), "65 holy damage back");
    assert(a.player.auras.find(20925).charges == 3);
}

/**
 * Add Target Trigger: Frostbite may freeze the target of the mage's chilling spell (its spell mask), by its amount as
 * a chance.
 */
unittest
{
    auto a = new Arena(PlayerClass.mage);
    auto frostbite = a.spell(11071, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(frostbite, 0, AuraType.addTargetTrigger, ImplicitTarget.caster, 100); // (a sure one, for the test)
    frostbite.triggerSpell[0] = 12494;
    frostbite.itemType[0] = 0x20;
    frostbite.casting.spellFamilyName = 3;
    auto freeze = a.spell(12494, SpellEffect.applyAura, ImplicitTarget.enemy);
    a.auraEffect(freeze, 0, AuraType.modRoot, ImplicitTarget.enemy);
    freeze.casting.durationIndex = 1;
    freeze.casting.school = 4;
    with (a.spell(116, SpellEffect.schoolDamage, ImplicitTarget.enemy, 20)) // Frostbolt
    {
        casting.school = 4;
        casting.spellFamilyName = 3;
        casting.spellFamilyFlags = 0x20;
    }
    with (a.spell(133, SpellEffect.schoolDamage, ImplicitTarget.enemy, 20)) // Fireball: not affected
    {
        casting.school = 2;
        casting.spellFamilyName = 3;
        casting.spellFamilyFlags = 0x1;
    }
    a.me.addAura(makeAura(frostbite, a.player.guid, 60, -1, true, [100, 0, 0]));
    foreach (attempt; 0 .. 10)
    {
        a.tick(2000);
        a.cast_(133, a.foe.guid);
    }
    assert(!a.hasAura(a.foe, 12494), "not by a fire spell");
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.cast_(116, a.foe.guid);
        if (a.hasAura(a.foe, 12494))
            break;
    }
    assert(a.hasAura(a.foe, 12494), "frozen");
}

/// Innervate (`MOD_POWER_REGEN_PERCENT` of mana): the mana from spirit five times as fast.
unittest
{
    auto a = new Arena(PlayerClass.druid);
    const before = a.player.manaRegenPerSecond();
    assert(before > 0);
    auto innervate = a.spell(29166, SpellEffect.applyAura, ImplicitTarget.friend);
    a.auraEffect(innervate, 0, AuraType.modPowerRegenPercent, ImplicitTarget.friend, 400, 0);
    innervate.casting.durationIndex = 1;
    a.cast_(29166);
    assert(a.player.manaRegenPerSecond() == before * 5);
}

/**
 * Holy Shock heals a friend and blasts an enemy (its rank's spells); Holy Light's script effect heals by its own
 * spell (19968), and Illumination gives the mana of the spell cast back when it crits.
 */
unittest
{
    import dmangos.world.defines : Power;

    auto a = new Arena(PlayerClass.paladin);
    with (a.spell(20473, SpellEffect.dummy, ImplicitTarget.unit))
    {
        casting.spellFamilyName = 10;
        casting.spellIconId = 156;
    }
    with (a.spell(25912, SpellEffect.schoolDamage, ImplicitTarget.enemy, 204))
        casting.school = 1;
    a.spell(25914, SpellEffect.heal, ImplicitTarget.friend, 204);
    a.player.values.set!UNIT_FIELD_MAXHEALTH(2000u);
    a.player.values.set!UNIT_FIELD_HEALTH(1000u);
    a.cast_(20473);
    assert(a.player.values.get!UNIT_FIELD_HEALTH >= 1204, "a heal on oneself");
    a.tick(2000);
    a.hero.read();
    foreach (attempt; 0 .. 30)
    {
        a.tick(2000);
        a.cast_(20473, a.foe.guid);
        if (a.damageLogs().canFind!(l => l[0] == 25912))
            break;
        assert(attempt < 29, "a blast at the enemy");
    }

    with (a.spell(635, SpellEffect.scriptEffect, ImplicitTarget.friend, 44))
    {
        casting.spellFamilyName = 10;
        casting.spellFamilyFlags = 0x80000000;
        casting.spellIconId = 70;
        casting.manaCost = 35;
    }
    with (a.spell(19968, SpellEffect.heal, ImplicitTarget.friend, 0))
    {
        casting.spellFamilyName = 10;
        casting.spellFamilyFlags = 0x4000;
    }
    auto illumination = a.spell(20210, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(illumination, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    illumination.triggerSpell[0] = 18350; // a Dummy Trigger, as spell_template has it
    with (illumination.casting)
    {
        spellFamilyName = 10;
        spellIconId = 241;
        procFlags = 0x4400;
        procChance = 100; // (rank 5's)
    }
    a.spell(18350, SpellEffect.dummy, ImplicitTarget.caster);
    a.context.data.spells.procEvents[20210] = SpellProcEvent(0, 10, [0xC0206000, 0xC0206000, 0xC0206000], 0, 0x2);
    with (a.spell(20272, SpellEffect.energize, ImplicitTarget.caster, 0))
        miscValue[0] = Power.mana;
    auto sure = a.spell(90100, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(sure, 0, AuraType.modSpellCritChance, ImplicitTarget.caster, 100);
    a.me.addAura(makeAura(illumination, a.player.guid, 60, -1, true, [0, 0, 0]));
    a.me.addAura(makeAura(sure, a.player.guid, 60, -1, true, [100, 0, 0]));
    a.tick(2000);
    a.player.values.set!UNIT_FIELD_MAXPOWER1(Power.mana, 1000u);
    a.player.values.set!UNIT_FIELD_POWER1(Power.mana, 500u);
    a.player.values.set!UNIT_FIELD_HEALTH(100u);
    a.cast_(635);
    assert(a.player.values.get!UNIT_FIELD_HEALTH == 100 + 66, "44 healed by 19968, a crit");
    assert(a.player.values.get!UNIT_FIELD_POWER1(Power.mana) == 500 - 35 + 35, "Holy Light's mana back");
}

/**
 * What replaces what: a hunter has one aspect, a warlock one curse on a target, and a higher rank of a buff replaces
 * the lower.
 */
unittest
{
    auto a = new Arena(PlayerClass.hunter);
    foreach (id, flags; [13165u: 0x100000UL, 5118u: 0x200000UL])
    {
        auto aspect = a.spell(id, SpellEffect.applyAura, ImplicitTarget.caster);
        a.auraEffect(aspect, 0, AuraType.dummy, ImplicitTarget.caster);
        aspect.casting.spellFamilyName = 9;
        aspect.casting.spellFamilyFlags = flags;
        aspect.casting.durationIndex = 4;
    }
    a.cast_(13165);
    a.tick(1600);
    a.cast_(5118);
    assert(a.hasAura(5118) && !a.hasAura(13165), "one aspect at a time");

    // Power Word: Fortitude, ranks 1 and 2: the second replaces the first.
    foreach (id; [1243u, 1244u])
    {
        auto fortitude = a.spell(id, SpellEffect.applyAura, ImplicitTarget.friend);
        a.auraEffect(fortitude, 0, AuraType.modStat, ImplicitTarget.friend, 3, 2);
        fortitude.casting.durationIndex = 4;
    }
    a.context.data.spells.chains[1243] = imported!"dmangos.world.spells".SpellChainNode(0, 1243, 1, 0);
    a.context.data.spells.chains[1244] = imported!"dmangos.world.spells".SpellChainNode(1243, 1243, 2, 0);
    a.cast_(1243);
    a.tick(1600);
    a.cast_(1244);
    assert(a.hasAura(1244) && !a.hasAura(1243), "the higher rank replaces the lower");

    // Curses: one of the warlock's on its target.
    foreach (id; [702u, 980u])
    {
        auto curse = a.spell(id, SpellEffect.applyAura, ImplicitTarget.enemy);
        a.auraEffect(curse, 0, AuraType.periodicDamage, ImplicitTarget.enemy, 1);
        curse.casting.spellFamilyName = 5;
        curse.casting.dispel = 2;
        curse.casting.durationIndex = 1;
        curse.casting.amplitude[0] = 2000;
    }
    foreach (attempt; 0 .. 30)
    {
        a.tick(1600);
        a.cast_(702, a.foe.guid);
        if (a.hasAura(a.foe, 702))
            break;
    }
    foreach (attempt; 0 .. 30)
    {
        a.tick(1600);
        a.cast_(980, a.foe.guid);
        if (a.hasAura(a.foe, 980))
            break;
    }
    assert(a.hasAura(a.foe, 980) && !a.hasAura(a.foe, 702), "one curse from each warlock");

}

/**
 * A mage has one armor (Ice Armor's flag 0x2000000, Mage Armor's 0x10000000); a frost spell's 0x80000, which Ice Armor
 * has too, makes no armor of Ice Barrier or Frost Ward (spell_template's rows, the fields that matter).
 */
unittest
{
    auto a = new Arena(PlayerClass.mage);
    auto iceArmor = a.spell(7302, SpellEffect.applyAura, ImplicitTarget.caster); // Ice Armor, rank 1
    a.auraEffect(iceArmor, 0, AuraType.modResistance, ImplicitTarget.caster, 290, 16);
    with (iceArmor.casting)
    {
        school = 4;
        spellFamilyName = 3;
        spellFamilyFlags = 0x2080000;
        durationIndex = 4;
    }
    auto barrier = a.spell(11426, SpellEffect.applyAura, ImplicitTarget.caster); // Ice Barrier, rank 1
    a.auraEffect(barrier, 0, AuraType.schoolAbsorb, ImplicitTarget.caster, 438, 127);
    with (barrier.casting)
    {
        school = 4;
        spellFamilyName = 3;
        spellFamilyFlags = 0x80000;
        durationIndex = 1;
    }
    auto frostWard = a.spell(6143, SpellEffect.applyAura, ImplicitTarget.caster); // Frost Ward, rank 1
    a.auraEffect(frostWard, 0, AuraType.schoolAbsorb, ImplicitTarget.caster, 165, 16);
    with (frostWard.casting)
    {
        school = 4;
        spellFamilyName = 3;
        spellFamilyFlags = 0x80100;
        durationIndex = 1;
    }
    auto mageArmor = a.spell(6117, SpellEffect.applyAura, ImplicitTarget.caster); // Mage Armor, rank 1
    a.auraEffect(mageArmor, 0, AuraType.modResistance, ImplicitTarget.caster, 5, 126);
    with (mageArmor.casting)
    {
        school = 6;
        spellFamilyName = 3;
        spellFamilyFlags = 0x10000000;
        durationIndex = 4;
    }
    a.cast_(7302);
    a.tick(1600);
    a.cast_(11426);
    a.tick(1600);
    a.cast_(6143);
    assert(a.hasAura(7302) && a.hasAura(11426) && a.hasAura(6143), "Ice Barrier and Frost Ward are no armor");
    a.tick(1600);
    a.cast_(6117);
    assert(a.hasAura(6117) && !a.hasAura(7302), "Mage Armor replaces Ice Armor");
}

/// Vanish (`spell_vanish`): the rogue stealths at once by the highest Stealth it knows, its cooldown ended.
unittest
{
    auto a = new Arena(PlayerClass.rogue);
    foreach (id; [1784u, 1785u])
    {
        auto stealth = a.spell(id, SpellEffect.applyAura, ImplicitTarget.caster);
        a.auraEffect(stealth, 0, AuraType.modStealth, ImplicitTarget.caster, id == 1784 ? 5 : 10);
        stealth.casting.durationIndex = 4;
        stealth.recoveryTime = 10_000;
    }
    a.context.data.spells.chains[1784] = imported!"dmangos.world.spells".SpellChainNode(0, 1784, 1, 0);
    a.context.data.spells.chains[1785] = imported!"dmangos.world.spells".SpellChainNode(1784, 1784, 2, 0);
    a.player.spells ~= [1784u, 1785u];
    a.spell(1856, SpellEffect.dummy, ImplicitTarget.caster);
    a.context.data.spellScriptNames[1856] = "spell_vanish";
    a.cast_(1785);
    a.me.removeAura(a.player.auras.find(1785));
    assert(!a.me.spellIsReady(1785));
    a.tick(1600);
    a.cast_(1856);
    assert(a.hasAura(1785) && !a.hasAura(1784), "stealthed by rank 2");
}

/**
 * Seal of Righteousness, rank 1 (20154: 108, learned at level 1), on a swing without a weapon (2.0 seconds, a fist's
 * 1 to 2): its holy damage (25742) is of the weapon's own damage, not of the damage the attack power adds; its spell
 * power share is less for a spell learned before level 20 (`CalculateLevelPenalty`: 0.2875 at level 1).
 */
unittest
{
    auto a = new Arena(PlayerClass.paladin);
    auto seal = a.spell(20154, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(seal, 0, AuraType.dummy, ImplicitTarget.caster, 108);
    seal.spellLevel = 1;
    with (seal.casting)
    {
        school = 1;
        spellFamilyName = 10;
        spellFamilyFlags = 0x8000000;
        procFlags = 0x4;
        procChance = 100;
        durationIndex = 1;
    }
    with (a.spell(25742, SpellEffect.schoolDamage, ImplicitTarget.enemy, 0))
    {
        casting.school = 1;
        casting.spellFamilyName = 10;
        casting.dmgClass = DamageClass.melee;
        attributesEx2 = 0x20000000; // it cannot crit
    }
    uint struck()
    {
        foreach (attempt; 0 .. 60)
        {
            a.tick(2000);
            if (!a.hasAura(20154))
                a.cast_(20154);
            // What the attack power makes of a swing, which the seal does not take.
            a.player.values.set!UNIT_FIELD_MINDAMAGE(300.0f);
            a.player.values.set!UNIT_FIELD_MAXDAMAGE(400.0f);
            a.hero.read();
            a.me.swing(a.foe, imported!"dmangos.world.combat".AttackType.mainHand);
            foreach (l; a.damageLogs())
                if (l[0] == 25742)
                    return l[1];
        }
        assert(false, "a swing lands");
    }
    // 0.85 * ceil(108 * 1.2 * 1.03 * 2.0 / 100) - 1 = 1.55; 0.03 of the fist's 1.5; and 1.
    assert(struck() == 2, "of the weapon's own damage");
    auto power = a.spell(90102, SpellEffect.applyAura, ImplicitTarget.caster); // 100 holy spell power
    a.auraEffect(power, 0, AuraType.modDamageDone, ImplicitTarget.caster, 100, 2);
    a.me.addAura(makeAura(power, a.player.guid, 60, -1, true, [100, 0, 0]));
    // 100 * 0.092 * 2.0 * 0.2875 = 5 more (and what every holy spell gets of it besides: 1.5 / 3.5).
    const damage = struck();
    assert(damage == 2 + 5 || damage == 2 + 5 + 42, "a level 1 spell's share of the spell power");
}

/// Mana Shield (1463: 120) absorbs half the arcane spell power more: each stack of Unstable Power (24659: 17).
unittest
{
    auto a = new Arena(PlayerClass.mage);
    auto shield = a.spell(1463, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(shield, 0, AuraType.manaShield, ImplicitTarget.caster, 120);
    shield.spellLevel = 20;
    with (shield.casting)
    {
        school = 6;
        spellFamilyName = 3;
        spellFamilyFlags = 0x8000;
        durationIndex = 1;
    }
    auto unstable = a.spell(24659, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(unstable, 0, AuraType.modDamageDone, ImplicitTarget.caster, 17, 126);
    unstable.casting.stackAmount = 12;
    unstable.casting.durationIndex = 1;
    foreach (_; 0 .. 3)
        a.me.addAura(makeAura(unstable, a.player.guid, 60, 10_000, true, [17, 0, 0]));
    assert(a.player.auras.find(24659).stacks == 3);
    a.cast_(1463);
    assert(a.player.auras.find(1463).amount[0] == 120 + 3 * 17 / 2, "half of three stacks' 51");
}

/// Healing Way (29203: 6% a stack, three at most) adds to Healing Wave (331: 34) by its stacks.
unittest
{
    auto a = new Arena(PlayerClass.shaman);
    auto way = a.spell(29203, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(way, 0, AuraType.dummy, ImplicitTarget.caster, 6);
    way.casting.stackAmount = 3;
    way.casting.durationIndex = 1;
    with (a.spell(331, SpellEffect.heal, ImplicitTarget.friend, 34))
    {
        casting.school = 3;
        casting.spellFamilyName = 11;
        casting.spellFamilyFlags = 0x40;
    }
    foreach (_; 0 .. 3)
        a.me.addAura(makeAura(way, a.player.guid, 60, 10_000, true, [6, 0, 0]));
    a.player.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    a.player.values.set!UNIT_FIELD_HEALTH(500u);
    a.cast_(331);
    const healed = a.player.values.get!UNIT_FIELD_HEALTH - 500;
    assert(healed == 34 * 118 / 100 || healed == 34 * 118 / 100 * 3 / 2, "18% more (a crit half again)");
}

/// Seal of the Crusader: its quicker swings are as much less: the damage a second stays.
unittest
{
    import dmangos.world.classspells : crusaderDamageFactor;
    import std.math : isClose;

    auto a = new Arena(PlayerClass.paladin);
    auto seal = a.spell(20162, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(seal, 0, AuraType.modAttackPower, ImplicitTarget.caster, 50);
    a.auraEffect(seal, 1, AuraType.modAttackSpeed, ImplicitTarget.caster, 40);
    a.auraEffect(seal, 2, AuraType.dummy, ImplicitTarget.caster, 20188);
    seal.casting.spellFamilyName = 10;
    seal.casting.spellFamilyFlags = 0x200;
    seal.casting.durationIndex = 1;
    a.cast_(20162);
    assert(isClose(crusaderDamageFactor(a.player.auras.list), 100.0f / 140), "40% quicker, 1/1.4 the damage");
    assert(isClose(a.player.damageMods.swing[0], 100.0f / 140));
}

/**
 * Sweeping Strikes strikes another enemy in reach for the blow's damage (12723); Retaliation strikes back at a swing
 * from the front, not one from behind.
 */
unittest
{
    auto a = new Arena(PlayerClass.warrior);
    auto second = a.context.summonCreature(a.map, creatureInnkeeper, Position(-8948.6f, -131.8f, 83.53f, 3.14159f),
        TempSpawnType.dead, 0, 0);
    second.factionTemplate = a.foe.factionTemplate;
    second.values.set!UNIT_FIELD_LEVEL(1u); // (the test character has little weapon skill)
    second.values.set!UNIT_FIELD_MAXHEALTH(10_000u);
    second.values.set!UNIT_FIELD_HEALTH(10_000u);
    auto sweeping = a.spell(12292, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(sweeping, 0, AuraType.dummy, ImplicitTarget.caster);
    with (sweeping.casting)
    {
        procFlags = 20;
        procChance = 100;
        procCharges = 5;
        durationIndex = 1;
    }
    with (a.spell(12723, SpellEffect.schoolDamage, ImplicitTarget.enemy, 0))
        casting.dmgClass = DamageClass.melee;
    a.cast_(12292);
    a.hero.read();
    foreach (attempt; 0 .. 60)
    {
        if (!a.hasAura(12292)) // (its strikes may miss, and its charges run out)
            a.cast_(12292);
        a.me.swing(a.foe, imported!"dmangos.world.combat".AttackType.mainHand);
        if (second.values.get!UNIT_FIELD_HEALTH < 10_000)
            break;
    }
    assert(second.values.get!UNIT_FIELD_HEALTH < 10_000, "the second enemy struck too");
    const left = a.player.auras.find(12292);
    assert(left is null || left.charges < 5, "a charge a strike");

    auto retaliation = a.spell(20230, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(retaliation, 0, AuraType.dummy, ImplicitTarget.caster);
    with (retaliation.casting)
    {
        procFlags = 40;
        procChance = 100;
        procCharges = 30;
        durationIndex = 1;
    }
    with (a.spell(22858, SpellEffect.weaponDamageNoschool, ImplicitTarget.enemy, 0))
        casting.dmgClass = DamageClass.melee;
    a.tick(1600);
    a.cast_(20230);
    a.hero.read();
    bool struck; // the strike back is rolled: it may be dodged or parried
    foreach (_; 0 .. 20)
    {
        a.swing(true, MeleeHitOutcome.normal, 5);
        if (a.damageLogs().canFind!(l => l[0] == 22858))
        {
            struck = true;
            break;
        }
    }
    assert(struck, "struck back");
    a.player.movement.position.orientation = 3.14159f; // its back to the creature
    a.swing(true, MeleeHitOutcome.normal, 5);
    assert(!a.damageLogs().canFind!(l => l[0] == 22858), "not from behind");
}

/**
 * A party buff at a friend (`TARGET_UNIT_FRIEND_AND_PARTY`: Prayer of Fortitude) goes on that friend and its party,
 * not on the caster outside it.
 */
unittest
{
    auto a = new Arena(PlayerClass.priest);
    auto jaina = loggedIn(a.context, a.db, 8, "Jaina", Position(-8948.0f, -133.5f, 83.53f, 0), AccountLevel.player,
        raceHuman, mapEasternKingdoms, 60);
    jaina.read();
    auto prayer = a.spell(21562, SpellEffect.applyAura, ImplicitTarget.unitFriendAndParty);
    a.auraEffect(prayer, 0, AuraType.modStat, ImplicitTarget.unitFriendAndParty, 54, 2);
    prayer.casting.durationIndex = 4;
    prayer.casting.radiusIndex[0] = 12;
    assert(a.cast_(21562, jaina.session.character.guid) == SpellCastResult.ok);
    assert((cast(Player) jaina.session.character).auras.find(21562) !is null, "on her");
    assert(!a.hasAura(21562), "not on the priest: no party of hers");
}

/// Shadowguard (`spell_shadowguard`): a swing at the priest brings the rank's shadow damage on the striker.
unittest
{
    auto a = new Arena(PlayerClass.priest);
    auto guard = a.spell(18137, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(guard, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    guard.triggerSpell[0] = 28376;
    with (guard.casting)
    {
        procFlags = 0x8;
        procChance = 100;
        procCharges = 3;
        durationIndex = 1;
    }
    with (a.spell(28376, SpellEffect.dummy, ImplicitTarget.enemy))
        casting.spellFamilyName = 11;
    with (a.spell(28377, SpellEffect.schoolDamage, ImplicitTarget.enemy, 25))
        casting.school = 5;
    a.cast_(18137);
    a.hero.read();
    foreach (attempt; 0 .. 30)
    {
        a.swing(true, MeleeHitOutcome.normal, 5);
        if (a.damageLogs().canFind!(l => l[0] == 28377))
            break;
        assert(attempt < 29, "the rank's shadow damage");
    }
}

/// Seal of Command: its proc strikes for 70% of the weapon's damage as holy damage, which armor does not reduce.
unittest
{
    auto a = new Arena(PlayerClass.paladin);
    auto seal = a.spell(20375, SpellEffect.applyAura, ImplicitTarget.caster);
    a.auraEffect(seal, 0, AuraType.procTriggerSpell, ImplicitTarget.caster);
    seal.triggerSpell[0] = 20424;
    with (seal.casting)
    {
        spellFamilyName = 10;
        spellFamilyFlags = 0x2000000;
        procFlags = 0x4;
        procChance = 100;
        durationIndex = 1;
    }
    with (a.spell(20424, SpellEffect.weaponPercentDamage, ImplicitTarget.enemy, 70))
    {
        casting.school = 1;
        casting.dmgClass = DamageClass.melee;
        attributesEx2 |= 0x20000000; // (no crit, for the test)
    }
    a.foe.values.set!UNIT_FIELD_RESISTANCES(0, 5000u); // much armor
    a.cast_(20375);
    a.hero.read();
    uint[2][] logs;
    foreach (attempt; 0 .. 60)
    {
        a.me.swing(a.foe, imported!"dmangos.world.combat".AttackType.mainHand);
        logs = a.damageLogs();
        if (logs.canFind!(l => l[0] == 20424))
            break;
    }
    const weapon = a.player.fighter.damage[0];
    const low = cast(uint)(weapon[0] < weapon[1] ? weapon[0] : weapon[1]) * 70 / 100;
    assert(logs.canFind!(l => l[0] == 20424 && l[1] >= low && l[1] > 0), "70% of the weapon, holy: through the armor");
}
