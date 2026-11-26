/**
 * Molten Core (map 409): the copy's script (its ten encounters, the runes of warding the bosses guard
 * and the flame circles round them, Majordomo Executus summoned once every rune is doused, the Cache
 * of the Firelord), the bosses Lucifron, Magmadar, Gehennas, Garr and his Firesworn, Shazzrah, Baron
 * Geddon, Golemagg and his Core Ragers, Sulfuron Harbinger and his priests, Majordomo Executus (his
 * fight, his surrender and the summoning of Ragnaros) and Ragnaros, and the runes players douse.
 */
module dmangos.scripts.moltencore;

import core.time : Duration;

import dmangos.script;

/// Where `who` is, as `ctx` sees it (`Location.init` if it is not here).
private Location where(C)(ref C ctx, EntityRef who)
{
    Location at;
    ctx.locationOf(who, at);
    return at;
}

/// The encounters, in the order of the copy's state (CMaNGOS's `TYPE_*`).
enum Encounter : ubyte
{
    lucifron,
    magmadar,
    gehennas,
    garr,
    shazzrah,
    geddon,
    golemagg,
    sulfuron,
    majordomo,
    ragnaros,
}

/// Creatures and objects of the copy.
enum : uint
{
    npcLucifron = 12118,
    npcMagmadar = 11982,
    npcGehennas = 12259,
    npcGarr = 12057,
    npcShazzrah = 12264,
    npcGeddon = 12056,
    npcGolemagg = 11988,
    npcSulfuron = 12098,
    npcMajordomo = 12018,
    npcRagnaros = 11502,
    npcFiresworn = 12099,
    npcCoreRager = 11672,
    npcFlamewakerHealer = 11663,
    npcFlamewakerElite = 11664,
    npcSonOfFlame = 12143,

    goLavaSteam = 178107,
    goLavaSplash = 178108,
    goLavaBomb = 177704,
    goCacheOfTheFireLord = 179703,
}

/// Each rune, the flame circle round it, and the encounter of the boss guarding it.
private struct Rune
{
    uint rune, circle;
    Encounter guard;
}

private static immutable Rune[7] runes = [
    Rune(176956, 178192, Encounter.magmadar), // Kress
    Rune(176957, 178193, Encounter.gehennas), // Mohn
    Rune(176955, 178191, Encounter.garr),     // Blaz
    Rune(176953, 178189, Encounter.shazzrah), // Mazj
    Rune(176952, 178188, Encounter.geddon),   // Zeth
    Rune(176954, 178190, Encounter.golemagg), // Theri
    Rune(176951, 178187, Encounter.sulfuron), // Koro
];

/// Where Majordomo is summoned: for his fight, and (his fight won) by Ragnaros' lair.
private static immutable Location[2] majordomoAt = [
    Location(758.0892f, -1176.712f, -118.6403f, 3.124139f),
    Location(848.933f, -812.875f, -229.601f, 4.046f),
];

/// His guard: four Flamewaker Elites, four Flamewaker Healers.
private static immutable uint[8] majordomoAddEntries = [npcFlamewakerElite, npcFlamewakerElite, npcFlamewakerElite,
    npcFlamewakerElite, npcFlamewakerHealer, npcFlamewakerHealer, npcFlamewakerHealer, npcFlamewakerHealer];
/// ditto
private static immutable Location[8] majordomoAddsAt = [
    Location(737.945f, -1156.48f, -118.945f, 4.46804f),
    Location(752.520f, -1191.02f, -118.218f, 2.49582f),
    Location(752.953f, -1163.94f, -118.869f, 3.70010f),
    Location(738.814f, -1197.40f, -118.018f, 1.83260f),
    Location(746.939f, -1194.87f, -118.016f, 2.21657f),
    Location(747.132f, -1158.87f, -118.897f, 4.03171f),
    Location(757.116f, -1170.12f, -118.793f, 3.40339f),
    Location(755.910f, -1184.46f, -118.449f, 2.80998f),
];

/// What scripts of the copy say to each other, beyond the encounters' states (signal ids 0 .. 9).
enum McSignal : uint
{
    unsummonAdds = 100, /// Majordomo to the copy: his guard goes
    addsLeft = 101,     /// the copy to Majordomo: one of his guard died, `value` left
    setUp = 102,        /// the copy to Majordomo: summoned for his fight (0) or by Ragnaros (1)
    erupt = 103,        /// Garr to a Firesworn: erupt
    enrage = 104,       /// a Firesworn to Garr, as it dies: enrage
    suicide = 105,      /// Golemagg to his Core Ragers, as he dies
    ragnarosSay = 106,  /// Majordomo to Ragnaros: say line `value` of the summoning
    majordomoDown = 107, /// Majordomo to Ragnaros: killed by his fire; the fight is near
    lavaBomb = 108,    /// Magmadar's landed bomb, `value`: the target's player GUID
    lavaBombMana = 109,
    saveRagnaros = 110, /// Ragnaros to the copy: a phase or a timer of his fight changed (checkpoint me)
}

/// A random length between `low` and `high` milliseconds.
private Duration between(ref CreatureContext me, uint low, uint high)
{
    return (low + me.random(high - low + 1)).msecs;
}

/// A step whose cast failed is tried again this soon.
private enum retry = 400.msecs;

/**
 * What the copy remembers: its encounters (saved in `instance.data`). While Ragnaros' fight is under way he and his
 * Sons of Flame, summons, are kept in the copy's checkpoint (`setRagnaros`): a worker's crash resumes his fight, and
 * one saved without him fails, so that Majordomo comes again to summon him.
 */
@instance("instance_molten_core")
struct MoltenCore
{
    EncounterState[Encounter.max + 1] encounters;

    @transient EntityRef[7] circles;   /// the flame circles, as they load
    @transient EntityRef majordomo;    /// once summoned (or loaded) in this run of the server
    @transient EntityRef[8] guard;     /// his guard, summoned with him
    @transient EntityRef ragnaros;     /// once Majordomo summons him (or the checkpoint brings him back)
    /// His living Sons of Flame while his fight is under way: saved in the checkpoint, not in this layout, each back in
    /// the list as it comes back into the world (`CreatureLoaded`).
    @transient EntityRef[] sons;

    private bool ragnarosActive() const
    {
        return encounters[Encounter.ragnaros] == EncounterState.inProgress;
    }

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        foreach (i, ref r; runes)
        {
            if (e.object.entry == r.rune && encounters[r.guard] == EncounterState.special)
                copy.door(e.object, true); // doused already
            if (e.object.entry == r.circle)
            {
                circles[i] = e.object;
                if (encounters[r.guard] == EncounterState.done || encounters[r.guard] == EncounterState.special)
                    copy.despawnObject(e.object);
            }
        }
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        import std.algorithm.searching : canFind;

        switch (e.creature.entry)
        {
        case npcMajordomo:
            majordomo = e.creature;
            break;
        case npcRagnaros:
            ragnaros = e.creature;
            if (ragnarosActive) // a clean handoff brings him in without a signal: he stays in the checkpoint
                copy.checkpointCreature(ragnaros);
            break;
        case npcSonOfFlame:
            // His sons as they come, and as a handoff or the checkpoint brings them back: kept with his fight.
            if (e.summoned && ragnarosActive && !sons.canFind(e.creature))
            {
                sons ~= e.creature;
                copy.checkpointCreature(e.creature);
            }
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext copy, const ref PlayerEntered e)
    {
        if (ragnarosActive && ragnaros && copy.alive(ragnaros))
        {
            // Back in the copy (after a crash, say): back in his fight, his idle sons after whoever is here.
            copy.zoneCombat(ragnaros);
            foreach (son; sons)
                if (copy.alive(son) && !copy.alive(copy.victimOf(son)))
                    copy.attack(son, e.player);
        }
        summonMajordomo(copy, true);
    }

    /**
     * The copy came back from its save. Ragnaros' fight under way resumes from its checkpoint when a player comes
     * back; one saved without him (an older save) failed, and Majordomo comes again to summon him.
     */
    void on(ref InstanceContext copy, const ref Restored e)
    {
        if (!ragnarosActive)
            return;
        if (copy.hasSavedCreature(npcRagnaros))
            copy.waitForPlayer();
        else
            setRagnaros(copy, EncounterState.failed);
    }

    /// Ragnaros gave up his fight, or his checkpoint could not bring him back: Majordomo may summon him again.
    void on(ref InstanceContext copy, const ref CreatureEvaded e)
    {
        if (e.creature.entry == npcRagnaros && ragnarosActive)
            setRagnaros(copy, EncounterState.failed);
    }

    /**
     * Ragnaros' encounter in `state`. While his fight is under way he and his Sons of Flame are saved with the copy;
     * a wipe or his death lets them go.
     */
    private void setRagnaros(ref InstanceContext copy, EncounterState state)
    {
        encounters[Encounter.ragnaros] = state;
        if (ragnarosActive)
        {
            if (ragnaros && copy.alive(ragnaros))
                copy.checkpointCreature(ragnaros);
        }
        else
        {
            if (ragnaros)
                copy.releaseCheckpointActor(ragnaros);
            foreach (son; sons)
                copy.releaseCheckpointActor(son);
            sons = null;
        }
        copy.checkpoint();
    }

    void on(ref InstanceContext copy, const ref Asked e)
    {
        if (e.id <= Encounter.max)
            copy.answer(encounters[e.id]);
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        const slain = sons.countUntil(e.creature);
        if (slain >= 0)
        {
            sons = sons.remove(slain);
            copy.releaseCheckpointActor(e.creature); // a son slain stays slain
            return;
        }
        if (e.creature.entry != npcFlamewakerHealer && e.creature.entry != npcFlamewakerElite)
            return;
        bool his;
        int left;
        foreach (g; guard)
        {
            if (g == e.creature)
                his = true;
            else if (g && copy.alive(g))
                ++left;
        }
        if (his && majordomo)
            copy.signal(majordomo, McSignal.addsLeft, left);
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == McSignal.lavaBomb || e.id == McSignal.lavaBombMana)
        {
            const target = EntityRef(cast(uint) e.value);
            Location at;
            if (e.from.entry == npcMagmadar && copy.locationOf(target, at))
                copy.summonObject(goLavaBomb, at, e.id == McSignal.lavaBombMana ? 60 : 30);
            return;
        }
        if (e.id == McSignal.saveRagnaros)
        {
            if (ragnarosActive && copy.alive(e.from))
            {
                ragnaros = e.from;
                copy.checkpointCreature(ragnaros);
            }
            return;
        }
        if (e.id == McSignal.unsummonAdds)
        {
            foreach (ref g; guard)
                if (g)
                {
                    copy.despawn(g);
                    g = EntityRef.init;
                }
            return;
        }
        if (e.id > Encounter.max)
            return;
        const which = cast(Encounter) e.id;
        const state = cast(EncounterState) e.value;
        if (which >= Encounter.magmadar && which <= Encounter.sulfuron && state == EncounterState.done)
            foreach (i, ref r; runes)
                if (r.guard == which && circles[i])
                    copy.despawnObject(circles[i]);
        // A rune is doused only once its guard has fallen.
        if (state == EncounterState.special && encounters[which] != EncounterState.done)
            return;
        if (which == Encounter.ragnaros)
        {
            if (e.from.isCreature && e.from.entry == npcRagnaros)
                ragnaros = e.from;
            return setRagnaros(copy, state);
        }
        encounters[which] = state;
        if (which == Encounter.majordomo && state == EncounterState.done)
            copy.respawnObject(goCacheOfTheFireLord, 3600);
        if (state == EncounterState.special)
            summonMajordomo(copy, false);
    }

    /// Majordomo comes once every rune is doused, to fight (or, his fight won, to summon Ragnaros).
    private void summonMajordomo(ref InstanceContext copy, bool byPlayerEnter)
    {
        if (encounters[Encounter.majordomo] == EncounterState.done && encounters[Encounter.ragnaros] == EncounterState.done)
            return;
        if (majordomo)
            return;
        foreach (i; Encounter.magmadar .. Encounter.majordomo)
            if (encounters[i] != EncounterState.special)
                return;
        if (copy.playerCount == 0)
            return;
        const won = encounters[Encounter.majordomo] == EncounterState.done;
        // Burnt by his master, he comes no more while Ragnaros is here (his fight resumed, or home after a wipe).
        if (won && (ragnarosActive || (ragnaros && copy.alive(ragnaros))))
            return;
        majordomo = copy.summon(npcMajordomo, majordomoAt[won ? 1 : 0], 2 * 3600 * 1000);
        if (!majordomo)
            return;
        copy.log(won ? "Majordomo waits by Ragnaros' lair" : "the runes are doused: Majordomo Executus comes");
        copy.signal(majordomo, McSignal.setUp, won ? 1 : 0);
        if (won)
            return;
        if (!byPlayerEnter)
            copy.say(majordomo, Majordomo.sayDoused);
        foreach (i, entry; majordomoAddEntries)
            guard[i] = copy.summon(entry, majordomoAddsAt[i], 0);
    }
}

/// A rune of warding: a player may douse it once the boss guarding it has fallen.
@gameObject("go_molten_core_rune")
struct MoltenCoreRune
{
    void on(ref GameObjectContext rune, const ref ObjectUsed e)
    {
        foreach (ref r; runes)
            if (rune.self.entry == r.rune)
            {
                if (rune.askDungeon(r.guard) != EncounterState.done)
                    return rune.consume(); // its guard lives (or it is doused already)
                rune.signalDungeon(r.guard, EncounterState.special);
                return;
            }
        rune.consume();
    }
}

/// The part every boss of the copy plays in its encounter: in progress, failed, done (its `Died` and
/// `Reset`; a `reset(me)` of the script's own runs on `Reset` too). Mixed in as text, so its handlers
/// join the script's own.
private enum encounterOf(string which, string onReset = "EncounterState.failed") = `
    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, EncounterState.done);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.signalDungeon(` ~ which ~ `, ` ~ onReset ~ `);
        static if (__traits(hasMember, typeof(this), "reset"))
            reset(me);
    }
`;

/// Lucifron: Impending Doom, his curse, and Shadow Shock.
@creature("boss_lucifron")
struct Lucifron
{
    enum : uint { shadowShock = 19460, impendingDoom = 19702, lucifronsCurse = 19703 }
    enum Step : ubyte { doom, curse, shock }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.lucifron"));

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.lucifron, EncounterState.inProgress);
        steps.after(Step.doom, between(me, 5000, 10_000));
        steps.after(Step.curse, between(me, 10_000, 15_000));
        steps.after(Step.shock, between(me, 3000, 6000));
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.doom:
            steps.after(step, me.castSelf(impendingDoom) == ActionResult.ok ? between(me, 20_000, 25_000) : retry);
            break;
        case Step.curse:
            steps.after(step, me.castSelf(lucifronsCurse) == ActionResult.ok ? between(me, 20_000, 25_000) : retry);
            break;
        case Step.shock:
            steps.after(step, me.castSpell(shadowShock) == ActionResult.ok ? between(me, 3000, 6000) : retry);
            break;
        }
    }
}

/// Magmadar: frenzies, panics everyone, and throws one Lava Bomb at a time.
@creature("boss_magmadar")
struct Magmadar
{
    enum : uint { frenzy = 19451, magmaSpit = 19449, panic = 19408, lavaBomb = 19411, lavaBombMana = 20474 }
    enum int emoteFrenzy = -1_000_001;
    enum Step : ubyte { frenzy, panic, bomb, oldManaBomb }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.magmadar", "EncounterState.notStarted"));

    void on(ref CreatureContext me, const ref Spawned e)
    {
        reset(me);
    }

    void reset(ref CreatureContext me)
    {
        if (!me.hasAura(me.self, magmaSpit))
            me.castSelf(magmaSpit, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.magmadar, EncounterState.inProgress);
        steps.after(Step.frenzy, 30.seconds);
        steps.after(Step.panic, between(me, 6000, 10_000));
        steps.after(Step.bomb, 12.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.from == me.self && (e.id == McSignal.lavaBomb || e.id == McSignal.lavaBombMana))
            me.signalDungeon(e.id, e.value);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.frenzy:
            if (me.castSelf(frenzy) == ActionResult.ok)
            {
                me.say(emoteFrenzy);
                steps.after(step, between(me, 15_000, 20_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.panic:
            steps.after(step, me.castSelf(panic) == ActionResult.ok ? between(me, 30_000, 35_000) : retry);
            break;
        case Step.bomb:
            const mana = me.selectTarget(Pick.random, PickFilter.player | PickFilter.manaUser);
            const other = me.selectTarget(Pick.random, PickFilter.player | PickFilter.notManaUser);
            const chooseMana = mana && (!other || me.random(2));
            const target = chooseMana ? mana : other;
            const ok = target && me.castSpell(chooseMana ? lavaBombMana : lavaBomb, target) == ActionResult.ok;
            steps.after(step, ok ? between(me, 12_000, 15_000) : retry);
            break;
        case Step.oldManaBomb: // A queued step restored from a copy running the older script.
            break;
        }
    }
}

/// Lava Bomb places its fire only when the dummy spell hits a player.
@spell("spell_magmadar_lava_bomb")
@spellIds(Magmadar.lavaBomb, Magmadar.lavaBombMana)
struct MagmadarLavaBomb
{
    void on(ref SpellContext spell, const ref EffectHit e)
    {
        if (e.caster.entry == npcMagmadar && e.target.isPlayer)
        {
            const signal = spell.spellId == Magmadar.lavaBombMana ? McSignal.lavaBombMana : McSignal.lavaBomb;
            spell.signal(e.caster, signal, cast(int) e.target.guid);
        }
    }
}

/// The fire patch keeps applying Conflagration to players within the trap radius.
@gameObject("go_magmadar_lava_bomb")
struct MagmadarLavaBombTrap
{
    enum Step : ubyte { pulse }
    Schedule!Step steps;

    void on(ref GameObjectContext trap, const ref Spawned e)
    {
        if (!steps.busy)
            steps.every(Step.pulse, 1.seconds);
    }

    void on(ref GameObjectContext trap, const ref TrapSprung e)
    {
        trap.consume();
    }

    void on(ref GameObjectContext trap, Step step)
    {
        trap.pulseTrap();
    }
}

/// Gehennas: his curse, Rain of Fire, and shadow bolts at his victim and at random.
@creature("boss_gehennas")
struct Gehennas
{
    enum : uint { curse = 19716, rainOfFire = 19717, shadowBoltRandom = 19729, shadowBoltTarget = 19728 }
    enum Step : ubyte { curse, rain, boltRandom, boltTarget }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.gehennas"));

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.gehennas, EncounterState.inProgress);
        steps.after(Step.curse, between(me, 5000, 10_000));
        steps.after(Step.rain, between(me, 6000, 12_000));
        steps.after(Step.boltRandom, between(me, 3000, 6000));
        steps.after(Step.boltTarget, between(me, 3000, 6000));
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.curse:
            steps.after(step, me.castSelf(curse) == ActionResult.ok ? between(me, 25_000, 30_000) : retry);
            break;
        case Step.rain, Step.boltRandom:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            const ok = target && me.castSpell(step == Step.rain ? rainOfFire : shadowBoltRandom, target) == ActionResult.ok;
            steps.after(step, !ok ? retry : step == Step.rain ? between(me, 6000, 12_000) : between(me, 3000, 6000));
            break;
        case Step.boltTarget:
            steps.after(step, me.castSpell(shadowBoltTarget) == ActionResult.ok ? between(me, 3000, 6000) : retry);
            break;
        }
    }
}

/// Garr: Antimagic Pulse, Magma Shackles; after six minutes he makes a Firesworn erupt every 20 seconds,
/// and each Firesworn that dies enrages him.
@creature("boss_garr")
struct Garr
{
    enum : uint { antimagicPulse = 19492, magmaShackles = 19496, enrage = 19516, separationAnxiety = 23487 }
    enum int emoteMassiveEruption = -1_409_025;
    enum Step : ubyte { pulse, shackles, eruption }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.garr"));

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.garr, EncounterState.inProgress);
        if (!me.hasAura(me.self, separationAnxiety))
            me.castSelf(separationAnxiety, true);
        steps.after(Step.pulse, between(me, 10_000, 15_000));
        steps.after(Step.shackles, between(me, 5000, 10_000));
        steps.after(Step.eruption, 6 * 60.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == McSignal.enrage)
            me.castSelf(enrage, true);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.pulse:
            steps.after(step, me.castSelf(antimagicPulse) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.shackles:
            steps.after(step, me.castSelf(magmaShackles) == ActionResult.ok ? between(me, 10_000, 15_000) : retry);
            break;
        case Step.eruption:
            EntityRef[8] near;
            const n = me.creaturesNearby(npcFiresworn, 100, near[]);
            if (n)
            {
                me.signal(near[me.random(cast(uint) n)], McSignal.erupt);
                me.say(emoteMassiveEruption);
            }
            steps.after(step, 20.seconds);
            break;
        }
    }
}

/// A Firesworn: thrashes and burns; erupts when it dies (or when Garr makes it), enraging Garr.
@creature("mob_firesworn")
struct Firesworn
{
    enum : uint { eruption = 19497, massiveEruption = 20483, thrash = 8876, immolate = 15733 }
    bool erupted;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        auras(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        auras(me);
    }

    private void auras(ref CreatureContext me)
    {
        if (!me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
        if (!me.hasAura(me.self, immolate))
            me.castSelf(immolate, true);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (e.after > 0 || erupted)
            return;
        // The blow that kills it: it erupts as it falls, and Garr feels it.
        erupted = true;
        me.castSelf(eruption, true);
        EntityRef[1] garr;
        if (me.creaturesNearby(npcGarr, 100, garr[]))
            me.signal(garr[0], McSignal.enrage);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == McSignal.erupt)
            me.castSelf(massiveEruption, true);
    }
}

/// Shazzrah: Arcane Explosion, his curse, Counterspell, Magic Grounding, and the Gate of Shazzrah.
@creature("boss_shazzrah")
struct Shazzrah
{
    enum : uint { arcaneExplosion = 19712, curse = 19713, magicGrounding = 19714, counterspell = 19715, gate = 23138 }
    enum Step : ubyte { explosion, curse, counterspell, grounding, gate, explodeAfterGate }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.shazzrah", "EncounterState.notStarted"));

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.shazzrah, EncounterState.inProgress);
        steps.after(Step.explosion, 6.seconds);
        steps.after(Step.curse, 10.seconds);
        steps.after(Step.counterspell, 15.seconds);
        steps.after(Step.grounding, 24.seconds);
        steps.after(Step.gate, 30.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.explosion:
            steps.after(step, me.castSelf(arcaneExplosion) == ActionResult.ok ? between(me, 5000, 9000) : retry);
            break;
        case Step.curse:
            steps.after(step, me.castSelf(curse) == ActionResult.ok ? 20.seconds : retry);
            break;
        case Step.counterspell:
            steps.after(step, me.castSelf(counterspell) == ActionResult.ok ? between(me, 16_000, 20_000) : retry);
            break;
        case Step.grounding:
            steps.after(step, me.castSelf(magicGrounding) == ActionResult.ok ? 35.seconds : retry);
            break;
        case Step.gate:
            // The gate takes him to someone at random: his hatred starts afresh, and he explodes there.
            const target = me.selectTarget(Pick.random, PickFilter.player);
            if (target && me.castSelf(gate) == ActionResult.ok)
            {
                me.teleport(where(me, target));
                me.resetThreat();
                me.attack(target);
                steps.after(Step.explodeAfterGate, 100.msecs);
                steps.after(step, 45.seconds);
            }
            else
                steps.after(step, retry);
            break;
        case Step.explodeAfterGate:
            me.castSelf(arcaneExplosion);
            break;
        }
    }
}

/// Baron Geddon: Inferno, Ignite Mana, Living Bomb, and Armageddon as he falls.
@creature("boss_baron_geddon")
struct BaronGeddon
{
    enum : uint { inferno = 19695, igniteMana = 19659, livingBomb = 20475, armageddon = 20478 }
    enum int emoteService = -1_409_000;
    enum Step : ubyte { inferno, igniteMana, livingBomb }
    Schedule!Step steps;
    bool armageddonCast;

    mixin(encounterOf!("Encounter.geddon", "EncounterState.notStarted"));

    void reset(ref CreatureContext me)
    {
        armageddonCast = false;
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.geddon, EncounterState.inProgress);
        steps.after(Step.inferno, 45.seconds);
        steps.after(Step.igniteMana, 30.seconds);
        steps.after(Step.livingBomb, 35.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!armageddonCast && e.after <= 2 && e.after > 0 && me.castSelf(armageddon) == ActionResult.ok)
        {
            armageddonCast = true;
            me.say(emoteService);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.inferno:
            steps.after(step, me.castSelf(inferno) == ActionResult.ok ? 45.seconds : retry);
            break;
        case Step.igniteMana:
            steps.after(step, me.castSelf(igniteMana) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.livingBomb:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(livingBomb, target) == ActionResult.ok ? 35.seconds : retry);
            break;
        }
    }
}

/// Golemagg the Incinerator: Pyroblast at random, an earthquake under ten percent; his Core Ragers
/// die with him.
@creature("boss_golemagg")
struct Golemagg
{
    enum : uint { magmaSplash = 13879, pyroblast = 20228, earthquake = 19798, golemaggsTrust = 20556, doubleAttack = 18943 }
    enum Step : ubyte { pyroblast, earthquake }
    Schedule!Step steps;
    bool enraged;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        auras(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        enraged = false;
        auras(me);
        me.signalDungeon(Encounter.golemagg, EncounterState.failed);
    }

    private void auras(ref CreatureContext me)
    {
        foreach (spell; [magmaSplash, doubleAttack, golemaggsTrust])
            if (!me.hasAura(me.self, spell))
                me.castSelf(spell, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.golemagg, EncounterState.inProgress);
        steps.after(Step.pyroblast, 7.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!enraged && e.crossed(10))
        {
            enraged = true;
            steps.after(Step.earthquake, 0.msecs);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        EntityRef[8] ragers;
        foreach (rager; ragers[0 .. me.creaturesNearby(npcCoreRager, 100, ragers[])])
            me.signal(rager, McSignal.suicide);
        me.signalDungeon(Encounter.golemagg, EncounterState.done);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.pyroblast:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(pyroblast, target) == ActionResult.ok ? 7.seconds : retry);
            break;
        case Step.earthquake:
            steps.after(step, me.castSelf(earthquake) == ActionResult.ok ? 3.seconds : retry);
            break;
        }
    }
}

/// A Core Rager: will not die while Golemagg lives (it heals itself fully at half health); mangles.
@creature("mob_core_rager")
struct CoreRager
{
    enum : uint { quietSuicide = 3617, thrash = 12787, fullHeal = 17683, mangle = 19820 }
    enum int emoteLowHp = -1_409_002;
    enum Step : ubyte { mangle, heal }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
        if (!me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        if (!me.hasAura(me.self, thrash))
            me.castSelf(thrash, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.mangle, 7.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (e.after <= 50 && !steps.pending(Step.heal))
            steps.after(Step.heal, 0.msecs);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != McSignal.suicide)
            return;
        steps.clear();
        me.deathPrevention(false);
        me.castSelf(quietSuicide, true);
        me.die();
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.mangle:
            steps.after(step, me.castSpell(mangle) == ActionResult.ok ? 10.seconds : retry);
            break;
        case Step.heal:
            if (me.healthPercent > 50)
                break;
            if (me.castSelf(fullHeal) == ActionResult.ok)
                me.say(emoteLowHp);
            else
                steps.after(step, retry);
            break;
        }
    }
}

/// Sulfuron Harbinger: Demoralizing Shout, Inspire on his priests, Hand of Ragnaros, and Flame Spear.
@creature("boss_sulfuron")
struct Sulfuron
{
    enum : uint { demoralizingShout = 19778, inspire = 19779, handOfRagnaros = 19780, flamespear = 19781 }
    enum uint npcFlamewakerPriest = 11662;
    enum Step : ubyte { shout, inspire, hand, spear }
    Schedule!Step steps;

    mixin(encounterOf!("Encounter.sulfuron"));

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.signalDungeon(Encounter.sulfuron, EncounterState.inProgress);
        steps.after(Step.shout, 15.seconds);
        steps.after(Step.inspire, 3.seconds);
        steps.after(Step.hand, 6.seconds);
        steps.after(Step.spear, 2.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shout:
            steps.after(step, me.castSelf(demoralizingShout) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.inspire:
            // A priest without it (at random), else himself.
            EntityRef[8] priests;
            EntityRef[8] without;
            size_t n;
            foreach (p; priests[0 .. me.creaturesNearby(npcFlamewakerPriest, 45, priests[])])
                if (!me.hasAura(p, inspire))
                    without[n++] = p;
            const target = n ? without[me.random(cast(uint) n)] : me.self;
            steps.after(step, me.castSpell(inspire, target) == ActionResult.ok ? 10.seconds : retry);
            break;
        case Step.hand:
            steps.after(step, me.castSelf(handOfRagnaros) == ActionResult.ok ? between(me, 12_000, 15_000) : retry);
            break;
        case Step.spear:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            steps.after(step, target && me.castSpell(flamespear, target) == ActionResult.ok
                ? between(me, 12_000, 16_000) : retry);
            break;
        }
    }
}

/// A Flamewaker Priest of Sulfuron's: Dark Strike, Dark Mending on the most hurt friend, Shadow Word:
/// Pain and Immolate at random.
@creature("mob_flamewaker_priest")
struct FlamewakerPriest
{
    enum : uint { darkStrike = 19777, darkMending = 19775, shadowWordPain = 19776, immolate = 20294 }
    enum Step : ubyte { strike, mending, pain, immolate }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.strike, 10.seconds);
        steps.after(Step.mending, between(me, 15_000, 30_000));
        steps.after(Step.pain, 2.seconds);
        steps.after(Step.immolate, 8.seconds);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.strike:
            steps.after(step, me.castSpell(darkStrike) == ActionResult.ok ? between(me, 15_000, 18_000) : retry);
            break;
        case Step.mending:
            // The most hurt of Sulfuron's company (himself, his priests), if any is hurt.
            EntityRef[9] near;
            size_t n = me.creaturesNearby(Sulfuron.npcFlamewakerPriest, 60, near[0 .. 8]);
            n += me.creaturesNearby(npcSulfuron, 60, near[n .. n + 1]);
            EntityRef best = me.self;
            uint lowest = me.healthPercent;
            foreach (other; near[0 .. n])
                if (me.healthPercentOf(other) < lowest)
                {
                    lowest = me.healthPercentOf(other);
                    best = other;
                }
            if (lowest >= 100)
            {
                steps.after(step, 1.seconds);
                break;
            }
            steps.after(step, me.castSpell(darkMending, best) == ActionResult.ok ? between(me, 15_000, 20_000) : retry);
            break;
        case Step.pain, Step.immolate:
            const target = me.selectTarget(Pick.random, PickFilter.player);
            const pain = step == Step.pain;
            const ok = target && me.castSpell(pain ? shadowWordPain : immolate, target) == ActionResult.ok;
            steps.after(step, !ok ? retry : pain ? between(me, 18_000, 26_000) : between(me, 15_000, 25_000));
            break;
        }
    }
}

/**
 * Majordomo Executus: fights behind his reflection shields, teleporting his foes, while his eight
 * guards live; he cannot die. When the last guard falls he submits, speaks, and goes to Ragnaros'
 * lair, where (asked) he summons his master and is burnt for his failure.
 */
@creature("boss_majordomo")
struct Majordomo
{
    enum : int
    {
        sayAggro = -1_409_003,
        sayLastAdd = -1_409_019,
        sayDefeat1 = -1_409_007,
        sayDefeat2 = -1_409_020,
        sayDefeat3 = -1_409_021,
        sayDoused = -1_409_004,
        saySummon0 = -1_409_023,
        saySummon1 = -1_409_024,
        saySummonMaj = -1_409_008,
        sayArrival2Maj = -1_409_010,
    }
    enum uint slayText = 9425; /// broadcast text
    enum : uint
    {
        magicReflection = 20619,
        damageReflection = 21075,
        aegis = 20620,
        teleportRandom = 20618,
        teleportTarget = 20534,
        hateToZero = 20538,
        immunePoly = 21087,
        separationAnxiety = 21094,
        encouragement = 21086,
        champion = 21090,
        summonRagnaros = 19774,
        elementalFire = 19773,
    }
    enum : uint { textSummon1 = 4995, textSummon2 = 5011, textSummon3 = 5012 }
    enum uint factionFriendly = 1080;
    enum uint npcFlagGossip = 1;

    enum Step : ubyte { shield, teleportRandom, teleportTarget, aegis, speech }
    Schedule!Step steps;

    bool finished;      /// his guard is down: he submits
    ubyte speech;       /// the stage of his speech (1 .. 5: his surrender; 10 .. 17: Ragnaros summoned)
    EntityRef ragnaros;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        switch (e.id)
        {
        case McSignal.setUp:
            if (e.value == 1)
                friendly(me);
            break;
        case McSignal.addsLeft:
            if (finished || !me.inCombat)
                break;
            if (e.value == 1)
            {
                me.say(sayLastAdd);
                me.castSelf(champion);
            }
            else if (e.value == 0)
            {
                // His guard is down: he goes back to where he stood and submits.
                finished = true;
                steps.clear();
                me.evade();
                break;
            }
            if (e.value <= 4)
                me.castSelf(immunePoly);
            me.castSelf(encouragement);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (e.enemy.entry == npcRagnaros)
            return;
        me.say(sayAggro);
        if (!me.hasAura(me.self, separationAnxiety))
            me.castSelf(separationAnxiety, true);
        if (!me.hasAura(me.self, aegis))
            me.castSelf(aegis, true);
        me.signalDungeon(Encounter.majordomo, EncounterState.inProgress);
        steps.after(Step.shield, 15.seconds);
        steps.after(Step.teleportRandom, 15.seconds);
        steps.after(Step.teleportTarget, 30.seconds);
        steps.after(Step.aegis, 5.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slayText);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!finished)
        {
            steps.clear();
            me.signalDungeon(Encounter.majordomo, EncounterState.failed);
            return;
        }
        if (speech)
            return; // his speech goes on
        friendly(me);
        speech = 1;
        steps.after(Step.speech, 0.msecs);
        me.signalDungeon(Encounter.majordomo, EncounterState.done);
    }

    /// He fights no more: friendly to the players, who may speak to him.
    private void friendly(ref CreatureContext me)
    {
        finished = true;
        me.unitFlags(UnitFlag.immuneToPlayer, true);
        me.setFaction(factionFriendly);
        me.npcFlags(npcFlagGossip);
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        const ragnarosState = me.askDungeon(Encounter.ragnaros);
        if (speech || (ragnarosState != EncounterState.notStarted && ragnarosState != EncounterState.failed))
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Tell me more.", 1);
        me.sendGossip(e.player, textSummon1, menu, false);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        GossipMenu menu;
        switch (e.action)
        {
        case 1:
            menu.add(GossipIcon.chat, "What else do you have to say?", 2);
            me.sendGossip(e.player, textSummon2, menu, false);
            break;
        case 2:
            menu.add(GossipIcon.chat, "You challenged us and we have come. Where is this master you speak of?", 3);
            me.sendGossip(e.player, textSummon3, menu, false);
            break;
        case 3:
            me.closeGossip(e.player);
            if (speech || (ragnaros && me.alive(ragnaros)))
                break;
            me.npcFlags(0);
            me.say(saySummon0, e.player);
            speech = 10;
            steps.after(Step.speech, 5.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.shield:
            const which = me.random(2) ? damageReflection : magicReflection;
            steps.after(step, me.castSelf(which) == ActionResult.ok ? 30.seconds : retry);
            break;
        case Step.teleportRandom:
            if (me.castSpell(teleportTarget) == ActionResult.ok)
            {
                me.castSelf(hateToZero);
                steps.after(step, between(me, 25_000, 30_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.teleportTarget:
            const target = me.selectTarget(Pick.random);
            if (target && me.castSpell(teleportRandom, target) == ActionResult.ok)
            {
                me.castSelf(hateToZero);
                steps.after(step, between(me, 25_000, 30_000));
            }
            else
                steps.after(step, retry);
            break;
        case Step.aegis:
            if (me.hasAura(me.self, aegis) || me.castSelf(aegis, true) == ActionResult.ok)
                steps.after(step, between(me, 25_000, 30_000));
            else
                steps.after(step, retry);
            break;
        case Step.speech:
            speak(me);
            break;
        }
    }

    /// His speech, a stage at a time.
    private void speak(ref CreatureContext me)
    {
        static immutable ragnarosAt = Location(838.3082f, -831.4665f, -232.1853f, 2.199115f);
        uint next;
        switch (speech)
        {
        // His surrender.
        case 1:
            me.say(sayDefeat1);
            next = 7500;
            break;
        case 2:
            me.say(sayDefeat2);
            next = 8000;
            break;
        case 3:
            me.say(sayDefeat3);
            next = 21_500;
            break;
        case 4:
            me.teleport(majordomoAt[1]);
            next = 900;
            break;
        case 5:
            me.signalDungeon(McSignal.unsummonAdds);
            me.npcFlags(npcFlagGossip);
            speech = 0;
            return;
        // Ragnaros summoned.
        case 10:
            me.say(saySummon1);
            next = 1000;
            break;
        case 11:
            me.castSelf(summonRagnaros);
            me.moveTo(Location(830.9636f, -814.7055f, -228.9733f), 1);
            next = 11_500;
            break;
        case 12:
            me.say(saySummonMaj);
            next = 8000;
            break;
        case 13:
            ragnaros = me.summon(npcRagnaros, ragnarosAt, 2 * 3600 * 1000);
            if (ragnaros)
                me.face(ragnaros);
            next = 8700;
            break;
        case 14:
            me.signal(ragnaros, McSignal.ragnarosSay, Ragnaros.sayArrival1);
            next = 11_700;
            break;
        case 15:
            me.say(sayArrival2Maj);
            next = 8700;
            break;
        case 16:
            me.signal(ragnaros, McSignal.ragnarosSay, Ragnaros.sayArrival3);
            next = 16_500;
            break;
        case 17:
            // Burnt by his master: Ragnaros takes it from here.
            me.deathPrevention(false);
            me.castAs(ragnaros, elementalFire, me.self, true);
            me.signal(ragnaros, McSignal.majordomoDown);
            speech = 0;
            me.die();
            return;
        default:
            speech = 0;
            return;
        }
        ++speech;
        steps.after(Step.speech, next.msecs);
    }
}

/**
 * Ragnaros: rooted in his lava, Wrath of Ragnaros knocks his foes back, the Hand of Ragnaros falls on
 * those with mana, Magma Blast whoever is out of his reach, lava bursts; every three minutes he sinks
 * into the lava for ninety seconds and his Sons of Flame fight for him.
 *
 * The copy saves him and his sons while he fights (`MoltenCore.setRagnaros`); he asks it to
 * (`McSignal.saveRagnaros`) as his fight begins, after each ability and as he sinks and rises, after the change, so
 * that a worker's crash resumes him in his phase with its timers.
 */
@creature("boss_ragnaros")
struct Ragnaros
{
    enum : int
    {
        sayArrival1 = -1_409_009,
        sayArrival3 = -1_409_011,
        sayArrival5 = -1_409_012,
        sayReinforcements1 = -1_409_013,
        sayReinforcements2 = -1_409_014,
        sayHammer = -1_409_015,
        sayWrath = -1_409_016,
    }
    enum uint slayText = 7626;
    enum : uint
    {
        wrathOfRagnaros = 20566,
        elementalFireAura = 20563,
        magmaBlast = 20565,
        meltWeapon = 21387,
        submerge = 21107,
        submergeVisual = 20567,
        emerge = 20568,
        submergeEffect = 21859,
        mightOfRagnaros = 21154,
        lavaBurst = 21908,
        doubleAttack = 19818,
        lavaShield = 21857,
    }
    enum Phase : ubyte { emerged, submerging, submerged, emerging }
    enum Step : ubyte { intro, transition, wrath, might, magmaBlast, lavaBurst, sonsCheck }
    Schedule!Step steps;

    Phase phase;
    bool introSaid, submergedOnce;
    byte rangeChecks = -1;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.rooted(true);
        me.combatMovement(false);
        me.castSelf(emerge);
        auras(me);
    }

    private void auras(ref CreatureContext me)
    {
        if (!me.hasAura(me.self, meltWeapon))
            me.castSelf(meltWeapon, true);
        if (!me.hasAura(me.self, elementalFireAura))
            me.castSelf(elementalFireAura, true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == McSignal.ragnarosSay)
        {
            me.emote(15); // roar
            me.say(e.value);
        }
        else if (e.id == McSignal.majordomoDown)
            steps.after(Step.intro, 10.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (e.enemy.entry == npcMajordomo)
            return;
        me.signalDungeon(Encounter.ragnaros, EncounterState.inProgress);
        startFight();
        save(me); // his timers with the fight the copy saved as it began
    }

    /// The copy checkpoints him as he is now: called last, after the change.
    private void save(ref CreatureContext me)
    {
        me.signalDungeon(McSignal.saveRagnaros);
    }

    private void startFight()
    {
        steps.after(Step.transition, 3 * 60.seconds);
        steps.after(Step.wrath, 30.seconds);
        steps.after(Step.might, 11.seconds);
        steps.after(Step.magmaBlast, 2.seconds);
        steps.after(Step.lavaBurst, 20.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.sayText(slayText);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        me.signalDungeon(Encounter.ragnaros, EncounterState.failed);
        if (phase != Phase.emerged)
            me.castSelf(emerge);
        me.unitFlags(UnitFlag.uninteractible, false);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        phase = Phase.emerged;
        rangeChecks = -1;
        submergedOnce = false;
        me.rooted(true);
        me.combatMovement(false);
        me.melee(true);
        me.standState(StandState.stand);
        me.removeAura(me.self, submerge);
        me.removeAura(me.self, submergeEffect);
        auras(me);
        EntityRef[8] sons;
        foreach (son; sons[0 .. me.creaturesNearby(npcSonOfFlame, 150, sons[])])
            me.despawn(son);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.signalDungeon(Encounter.ragnaros, EncounterState.done);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.intro:
            if (!introSaid)
            {
                introSaid = true;
                me.say(sayArrival5);
                steps.after(step, 3.seconds);
                break;
            }
            // Now he may be fought: everyone in his lair is his foe.
            me.unitFlags(UnitFlag.immuneToPlayer, false);
            me.zoneCombat();
            if (const nearest = me.selectTarget(Pick.nearest))
                me.attack(nearest);
            break;
        case Step.transition:
            transition(me);
            break;
        case Step.wrath:
            if (me.castSelf(wrathOfRagnaros) == ActionResult.ok)
            {
                me.say(sayWrath);
                // Those it knocked back are forgotten (his melee range is the one place to be).
                EntityRef[40] near;
                foreach (p; near[0 .. me.playersNear(10, near[])])
                    me.modifyThreat(p, -100);
                steps.after(step, 25.seconds);
                save(me);
            }
            else
                steps.after(step, retry);
            break;
        case Step.might:
            const target = me.selectTarget(Pick.random, PickFilter.manaUser);
            if (target && me.castSpell(mightOfRagnaros, target) == ActionResult.ok)
            {
                me.say(sayHammer);
                steps.after(step, between(me, 11_000, 30_000));
                save(me);
            }
            else
                steps.after(step, retry);
            break;
        case Step.magmaBlast:
            uint next = 500;
            // Nobody within his reach: after a moment he blasts someone at random.
            if (me.selectTarget(Pick.topThreat, PickFilter.inMelee))
                rangeChecks = -1;
            else if (++rangeChecks > 1)
            {
                const target = me.selectTarget(Pick.random, PickFilter.player);
                if (target && me.castSpell(magmaBlast, target) == ActionResult.ok)
                    next = 2500;
            }
            steps.after(step, next.msecs);
            if (next > 500)
                save(me);
            break;
        case Step.lavaBurst:
            const burst = me.castSelf(lavaBurst) == ActionResult.ok;
            steps.after(step, burst ? between(me, 5000, 25_000) : retry);
            if (burst)
                save(me);
            break;
        case Step.sonsCheck:
            // All his sons slain: he comes up soon.
            EntityRef[8] sons;
            if (phase == Phase.submerged && me.creaturesNearby(npcSonOfFlame, 150, sons[]) == 0)
            {
                if (steps.remaining(Step.transition) > 1000)
                {
                    steps.after(Step.transition, 1.seconds);
                    save(me);
                }
            }
            else if (phase == Phase.submerged)
                steps.after(step, 1.seconds);
            break;
        }
    }

    /// Down into the lava, his sons called, and up again.
    private void transition(ref CreatureContext me)
    {
        final switch (phase)
        {
        case Phase.emerged:
            me.castSelf(submergeVisual, true);
            me.castSelf(submergeEffect, true);
            me.standState(cast(StandState) 9); // UNIT_STAND_STATE_CUSTOM: under the lava
            me.unitFlags(UnitFlag.uninteractible, true);
            me.say(submergedOnce ? sayReinforcements2 : sayReinforcements1);
            submergedOnce = true;
            summonSons(me);
            foreach (s; [Step.wrath, Step.might, Step.magmaBlast, Step.lavaBurst])
                steps.cancel(s);
            me.melee(false);
            phase = Phase.submerging;
            steps.after(Step.transition, 3.seconds);
            break;
        case Phase.submerging:
            me.castSelf(submerge, true);
            phase = Phase.submerged;
            steps.after(Step.transition, 90.seconds);
            steps.after(Step.sonsCheck, 1.seconds);
            break;
        case Phase.submerged:
            me.removeAura(me.self, submerge);
            me.removeAura(me.self, submergeEffect);
            me.removeAura(me.self, submergeVisual);
            phase = Phase.emerging;
            steps.after(Step.transition, 500.msecs);
            break;
        case Phase.emerging:
            me.standState(StandState.stand);
            me.castSelf(emerge);
            me.unitFlags(UnitFlag.uninteractible, false);
            phase = Phase.emerged;
            steps.after(Step.transition, 3 * 60.seconds);
            steps.after(Step.wrath, 20.seconds);
            steps.after(Step.might, between(me, 11_000, 30_000));
            steps.after(Step.magmaBlast, 3.seconds);
            steps.after(Step.lavaBurst, between(me, 5000, 25_000));
            me.melee(true);
            break;
        }
        save(me);
    }

    /// Eight Sons of Flame, round him, each fighting whoever is nearest.
    private void summonSons(ref CreatureContext me)
    {
        import std.math : cos, sin, PI;

        const at = me.location;
        foreach (i; 0 .. 8)
        {
            const angle = i * PI / 4;
            const spot = Location(at.x + 18 * cos(angle), at.y + 18 * sin(angle), at.z, angle + PI);
            const son = me.summon(npcSonOfFlame, spot, 0, me.selectTarget(Pick.random));
            if (son)
            {
                me.castAs(son, doubleAttack, son, true);
                me.castAs(son, lavaShield, son, true);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.typecons : BlackHole;
    import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;

    /// A copy that records what its script does.
    class FakeCopy : BlackHole!InstanceHost
    {
        EntityRef[] summoned, despawned, doorsOpened, objectsGone;
        uint[] respawned;
        uint players = 1;
        bool[ulong] dead;
        Signal[] signals;
        int[] said;
        ulong next = 1;

        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            auto made = EntityRef(0xF130_0000_0000_0000UL | (ulong(entry) << 24) | next++);
            summoned ~= made;
            return made;
        }
        override bool hostAlive(EntityRef who) { return (who.guid in dead) is null; }
        override uint hostPlayerCount() { return players; }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override ActionResult hostDoor(EntityRef door, bool open)
        {
            if (open)
                doorsOpened ~= door;
            return ActionResult.ok;
        }
        override ActionResult hostDespawnObject(EntityRef o) { objectsGone ~= o; return ActionResult.ok; }
        override bool hostRespawnObject(uint entry, uint) { respawned ~= entry; return true; }
        override ActionResult hostDespawn(EntityRef c, uint) { despawned ~= c; return ActionResult.ok; }
        override ActionResult hostSay(EntityRef, int text, EntityRef) { said ~= text; return ActionResult.ok; }
    }

    EntityRef objectRef(uint entry, uint spawn)
    {
        return EntityRef(0xF110_0000_0000_0000UL | (ulong(entry) << 24) | spawn);
    }
}

/// Molten Core's copy: circles go as their guards fall, runes are doused only after, and the last rune
/// brings Majordomo and his eight guards; their deaths are counted for him; his defeat brings the cache.
unittest
{
    alias self = dmangos.scripts.moltencore;
    auto runtime = ScriptRuntime.of!self();
    auto copy = new FakeCopy;
    auto c = InstanceContext(copy);
    auto h = runtime.create(ScriptKind.instance, "instance_molten_core");
    assert(h);

    // The circle round Kress loads; Magmadar falls: it goes.
    const circle = objectRef(178192, 1);
    runtime.raise(h, c, ObjectLoaded(circle));
    assert(copy.objectsGone.length == 0);
    runtime.raise(h, c, Signal(EntityRef.init, Encounter.magmadar, EncounterState.inProgress));
    runtime.raise(h, c, Signal(EntityRef.init, Encounter.magmadar, EncounterState.done));
    assert(copy.objectsGone == [circle]);

    // A rune cannot be doused before its guard falls.
    runtime.raise(h, c, Signal(EntityRef.init, Encounter.garr, EncounterState.special));
    {
        auto q = InstanceContext(copy);
        runtime.raise(h, q, Asked(EntityRef.init, Encounter.garr));
        assert(q.answerGiven == EncounterState.notStarted);
    }

    // Every guard falls and every rune is doused: Majordomo comes with his guard, the last rune's yell his.
    foreach (which; Encounter.magmadar .. Encounter.majordomo)
    {
        runtime.raise(h, c, Signal(EntityRef.init, which, EncounterState.done));
        assert(copy.summoned.length == 0);
        runtime.raise(h, c, Signal(EntityRef.init, which, EncounterState.special));
    }
    assert(copy.summoned.length == 9 && copy.summoned[0].entry == npcMajordomo);
    assert(copy.said == [Majordomo.sayDoused]);
    assert(copy.signals[$ - 1] == Signal(copy.summoned[0], McSignal.setUp, 0));

    // A player entering does not bring a second one.
    runtime.raise(h, c, PlayerEntered(EntityRef(7)));
    assert(copy.summoned.length == 9);

    // His guards die one by one: he hears how many are left.
    foreach (i, g; copy.summoned[1 .. $])
    {
        copy.dead[g.guid] = true;
        runtime.raise(h, c, CreatureDied(g, EntityRef(7)));
        assert(copy.signals[$ - 1] == Signal(copy.summoned[0], McSignal.addsLeft, cast(int)(7 - i)));
    }

    // He submits: the cache appears; he sends his guard away.
    runtime.raise(h, c, Signal(copy.summoned[0], Encounter.majordomo, EncounterState.done));
    assert(copy.respawned == [goCacheOfTheFireLord]);
    runtime.raise(h, c, Signal(copy.summoned[0], McSignal.unsummonAdds, 0));
    assert(copy.despawned.length == 8);

    // The state survives a save; after a restart a player entering finds him by Ragnaros' lair.
    import dmangos.bytes : ByteReader, ByteWriter;

    ByteWriter w;
    runtime.save(h, w);
    auto again = runtime.create(ScriptKind.instance, "instance_molten_core");
    auto r = ByteReader(w.data);
    assert(runtime.load(again, r));
    auto copy2 = new FakeCopy;
    auto c2 = InstanceContext(copy2);
    runtime.raise(again, c2, PlayerEntered(EntityRef(7)));
    assert(copy2.summoned.length == 1 && copy2.signals[$ - 1] == Signal(copy2.summoned[0], McSignal.setUp, 1));
    // A doused rune loads doused.
    runtime.raise(again, c2, ObjectLoaded(objectRef(176956, 2)));
    assert(copy2.doorsOpened == [objectRef(176956, 2)]);
}

/// Ragnaros' fight keeps him and his sons in the copy's checkpoint, and Majordomo away; saved without him (an older
/// save), it fails as the copy comes back, and Majordomo comes again to summon him.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;

    alias self = dmangos.scripts.moltencore;
    auto runtime = ScriptRuntime.of!self();
    auto copy = new FakeCopy;
    auto c = InstanceContext(copy);
    auto h = runtime.create(ScriptKind.instance, "instance_molten_core");
    runtime.raise(h, c, Signal(EntityRef.init, Encounter.lucifron, EncounterState.done));
    runtime.raise(h, c, Signal(EntityRef.init, Encounter.majordomo, EncounterState.done));
    foreach (which; Encounter.magmadar .. Encounter.majordomo)
    {
        runtime.raise(h, c, Signal(EntityRef.init, which, EncounterState.done));
        runtime.raise(h, c, Signal(EntityRef.init, which, EncounterState.special));
    }
    assert(copy.summoned.length == 1 && copy.summoned[0].entry == npcMajordomo, "Majordomo not by the lair");

    const ragnaros = EntityRef(0xF130_0000_0000_0100UL | (ulong(npcRagnaros) << 24));
    const son = EntityRef(0xF130_0000_0000_0101UL | (ulong(npcSonOfFlame) << 24));
    runtime.raise(h, c, CreatureLoaded(ragnaros, true));
    auto fight = InstanceContext(copy);
    runtime.raise(h, fight, Signal(ragnaros, Encounter.ragnaros, EncounterState.inProgress));
    assert(fight.checkpointSummons == [ragnaros] && fight.checkpointRequested, "his pull does not save him");
    auto sons = InstanceContext(copy);
    runtime.raise(h, sons, CreatureLoaded(son, true));
    assert(sons.checkpointSummons == [son], "a Son of Flame is not saved with his fight");
    ByteWriter saved;
    runtime.save(h, saved);

    // Back from the checkpoint with him: his fight waits for the raid, and Majordomo stays burnt.
    {
        auto back = runtime.create(ScriptKind.instance, "instance_molten_core");
        auto reader = ByteReader(saved.data);
        assert(runtime.load(back, reader));
        auto again = new FakeCopy;
        auto restored = InstanceContext(again);
        const EntityRef[1] kept = [ragnaros];
        restored.savedSummons = kept[];
        runtime.raise(back, restored, Restored());
        assert(restored.waitingForPlayer, "his fight does not wait for the raid");
        auto loaded = InstanceContext(again);
        runtime.raise(back, loaded, CreatureLoaded(ragnaros, true));
        runtime.raise(back, loaded, PlayerEntered(EntityRef(7)));
        auto q = InstanceContext(again);
        runtime.raise(back, q, Asked(EntityRef.init, Encounter.ragnaros));
        assert(q.answerGiven == EncounterState.inProgress && again.summoned.length == 0,
            "Majordomo came back during Ragnaros' fight");
    }

    // Saved without him: his fight failed, and Majordomo comes to summon him again.
    auto back = runtime.create(ScriptKind.instance, "instance_molten_core");
    auto reader = ByteReader(saved.data);
    assert(runtime.load(back, reader));
    auto again = new FakeCopy;
    auto restored = InstanceContext(again);
    runtime.raise(back, restored, Restored());
    assert(!restored.waitingForPlayer && restored.checkpointRequested);
    runtime.raise(back, restored, PlayerEntered(EntityRef(7)));
    auto q = InstanceContext(again);
    runtime.raise(back, q, Asked(EntityRef.init, Encounter.ragnaros));
    assert(q.answerGiven == EncounterState.failed, "his fight, saved without him, stays under way for good");
    assert(again.summoned.length == 1 && again.summoned[0].entry == npcMajordomo
        && again.signals[$ - 1] == Signal(again.summoned[0], McSignal.setUp, 1), "no Majordomo to summon him again");
}

version (unittest)
{
    /// A creature that records what its script has it do.
    class FakeBoss : BlackHole!CreatureHost
    {
        uint[] casts;
        int[] said;
        Signal[] signals, dungeon;
        uint health = 100;
        bool fighting = true, dying;
        EntityRef target = EntityRef(7);
        uint flags;
        uint factionNow;
        uint npcFlagsNow;
        bool evaded;
        EntityRef[] summoned;
        Location at;

        override EntityRef hostSelf() { return EntityRef(0xF130_0000_0000_0001UL | (ulong(npcMajordomo) << 24)); }
        override EntityRef hostVictim() { return target; }
        override uint hostHealthPercent() { return health; }
        override bool hostInCombat() { return fighting; }
        override ActionResult hostCast(uint spell, EntityRef, bool) { casts ~= spell; return ActionResult.ok; }
        override ActionResult hostSay(int text, EntityRef) { said ~= text; return ActionResult.ok; }
        override void hostSignalDungeon(uint id, int value) { dungeon ~= Signal(EntityRef.init, id, value); }
        override ActionResult hostSignal(EntityRef to, uint id, int value)
        {
            signals ~= Signal(to, id, value);
            return ActionResult.ok;
        }
        override EntityRef hostSelectTarget(Pick, uint, uint) { return target; }
        override void hostUnitFlags(uint f, bool set) { flags = set ? flags | f : flags & ~f; }
        override void hostSetFaction(uint f) { factionNow = f; }
        override void hostNpcFlags(uint f) { npcFlagsNow = f; }
        override void hostEvade() { evaded = true; fighting = false; }
        override void hostDie() { dying = true; }
        override EntityRef hostSummon(uint entry, Location, uint, EntityRef)
        {
            summoned ~= EntityRef(0xF130_0000_0000_0100UL | (ulong(entry) << 24));
            return summoned[$ - 1];
        }
        override void hostTeleport(Location l) { at = l; }
        override bool hostAlive(EntityRef) { return true; }
    }
}

/// Majordomo: the fight, his surrender when his guard is down, his speech and the summoning of Ragnaros.
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.moltencore;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeBoss;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_majordomo");
    void run(int ms)
    {
        foreach (_; 0 .. ms / 100)
            runtime.tick(h, me, 100);
    }

    runtime.raise(h, me, Spawned());
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    assert(host.said == [Majordomo.sayAggro] && host.casts.canFind(Majordomo.aegis));
    assert(host.dungeon[$ - 1] == Signal(EntityRef.init, Encounter.majordomo, EncounterState.inProgress));
    run(15_000);
    assert(host.casts.canFind(Majordomo.teleportTarget) && host.casts.canFind(Majordomo.hateToZero));

    // One guard left: he yells and makes it a champion; none left: he goes home.
    runtime.raise(h, me, Signal(EntityRef.init, McSignal.addsLeft, 1));
    assert(host.said[$ - 1] == Majordomo.sayLastAdd && host.casts.canFind(Majordomo.champion));
    runtime.raise(h, me, Signal(EntityRef.init, McSignal.addsLeft, 0));
    assert(host.evaded);
    runtime.raise(h, me, Reset());
    assert(host.factionNow == Majordomo.factionFriendly && (host.flags & UnitFlag.immuneToPlayer));
    assert(host.dungeon[$ - 1] == Signal(EntityRef.init, Encounter.majordomo, EncounterState.done));

    // His speech: three lines, then he is by Ragnaros' lair and sends his guard away.
    run(100);
    assert(host.said[$ - 1] == Majordomo.sayDefeat1);
    run(7500 + 8000 + 21_500 + 1000);
    assert(host.said.canFind(Majordomo.sayDefeat3) && host.at == majordomoAt[1]);
    assert(host.dungeon[$ - 1].id == McSignal.unsummonAdds && host.npcFlagsNow == Majordomo.npcFlagGossip);

    // Asked thrice, he summons Ragnaros, who speaks; then Majordomo burns.
    runtime.raise(h, me, GossipSelect(EntityRef(7), 0, 0, 3));
    assert(host.said[$ - 1] == Majordomo.saySummon0 && host.npcFlagsNow == 0);
    run(5000 + 1000 + 11_500 + 8000 + 200);
    assert(host.summoned.length == 1 && host.summoned[0].entry == npcRagnaros);
    run(8700 + 11_700 + 8700 + 16_500 + 500);
    assert(host.signals.canFind(Signal(host.summoned[0], McSignal.ragnarosSay, Ragnaros.sayArrival1)));
    assert(host.signals.canFind(Signal(host.summoned[0], McSignal.majordomoDown, 0)) && host.dying);
}

/// Ragnaros: the intro after Majordomo's death, then down into the lava with his sons at three minutes,
/// and up again once they are slain.
unittest
{
    import std.algorithm.searching : canFind;

    alias self = dmangos.scripts.moltencore;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeBoss;
    host.fighting = false;
    host.flags = UnitFlag.immuneToPlayer;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_ragnaros");
    void run(int ms)
    {
        foreach (_; 0 .. ms / 100)
            runtime.tick(h, me, 100);
    }

    runtime.raise(h, me, Spawned());
    runtime.raise(h, me, Signal(EntityRef.init, McSignal.majordomoDown, 0));
    run(10_000);
    assert(host.said == [Ragnaros.sayArrival5]);
    run(3000);
    assert(!(host.flags & UnitFlag.immuneToPlayer), "he may be fought");

    host.fighting = true;
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    run(30_000);
    assert(host.casts.canFind(Ragnaros.wrathOfRagnaros) && host.said.canFind(Ragnaros.sayWrath));
    run(150_000);
    assert(host.summoned.length == 8 && (host.flags & UnitFlag.uninteractible), "submerged, his sons out");
    assert(host.said.canFind(Ragnaros.sayReinforcements1));
    // No sons near (the fake finds none): he comes up within seconds.
    run(3000 + 3000);
    assert(!(host.flags & UnitFlag.uninteractible), "emerged");
}

/// The bosses tell the copy how their encounters go: begun, failed (home again), done.
unittest
{
    alias self = dmangos.scripts.moltencore;
    auto runtime = ScriptRuntime.of!self();
    auto host = new FakeBoss;
    auto me = CreatureContext(host);
    auto h = runtime.create(ScriptKind.creature, "boss_lucifron");
    assert(runtime.handles!Died(h) && runtime.handles!Reset(h));
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Reset());
    runtime.raise(h, me, EnteredCombat(EntityRef(7)));
    runtime.raise(h, me, Died(EntityRef(7)));
    assert(host.dungeon == [Signal(EntityRef.init, Encounter.lucifron, EncounterState.inProgress),
        Signal(EntityRef.init, Encounter.lucifron, EncounterState.failed),
        Signal(EntityRef.init, Encounter.lucifron, EncounterState.inProgress),
        Signal(EntityRef.init, Encounter.lucifron, EncounterState.done)]);
}
