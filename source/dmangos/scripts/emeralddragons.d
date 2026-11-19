/**
 * The Emerald Dragons (ScriptDevAI's `bosses_emerald_dragons`): Emeriss, Lethon, Taerar and Ysondre,
 * the corrupted green dragons who come out of the Dream at the great trees. What they share is a
 * component (`DreamDragon`); each adds its own spells and the ability it uses at 75, 50 and 25 percent.
 *
 * Their spells that summon by a dummy or a demon's summoning (Ysondre's druids, Taerar's shades, Lethon's
 * shades) are done here by summoning the creatures themselves.
 */
module dmangos.scripts.emeralddragons;

import dmangos.script;

/// The creatures.
enum : uint { npcYsondre = 14887, npcLethon = 14888, npcEmeriss = 14889, npcTaerar = 14890,
    npcSpiritShade = 15261, npcDementedDruid = 15260, npcShadeOfTaerar = 15302 }

/**
 * What the four share (`boss_emerald_dragonAI`): Mark of Nature on themselves when the fight begins and
 * on the players they kill, Seeping Fog every minute, Noxious Breath, Tail Sweep, and the count of their
 * special abilities. Its spells wait while it is `held` (Taerar banished).
 */
struct DreamDragon
{
    enum : uint { spellMarkOfNaturePlayer = 25040, spellMarkOfNatureAura = 25041, spellSeepingFogR = 24813,
        spellSeepingFogL = 24814, spellNoxiousBreath = 24818, spellTailSweep = 15847 }

    int fogMs, breathMs, sweepMs;
    ubyte abilitiesUsed; /// at 75, 50 and 25 percent: how many it has used
    bool fighting, held;

    /// The fight begins.
    void engage(ref CreatureContext me)
    {
        me.castSelf(spellMarkOfNatureAura, true);
        fogMs = 30_000;
        breathMs = 9000 + me.random(3001);
        sweepMs = 10_000 + me.random(10_001);
        abilitiesUsed = 0;
        fighting = true;
        held = false;
    }

    /// The fight is over.
    void disengage()
    {
        fighting = held = false;
    }

    /// Whether its health is below the next mark for its ability (75, 50, 25 percent).
    bool abilityDue(uint healthPercent) const
    {
        return abilitiesUsed < 3 && healthPercent < 100 - (abilitiesUsed + 1) * 25;
    }

    /// It killed `victim`: a player gets the Mark of Nature, from it.
    void killed(ref CreatureContext me, EntityRef victim)
    {
        if (victim.isPlayer)
            me.castAs(victim, spellMarkOfNaturePlayer, victim, true);
    }

    /// Its shared spells, `ms` on.
    void tick(ref CreatureContext me, int ms)
    {
        if (!fighting || held || !me.inCombat)
            return;
        if ((fogMs -= ms) <= 0)
        {
            me.castSelf(spellSeepingFogR, true);
            me.castSelf(spellSeepingFogL, true);
            fogMs = 60_000;
        }
        if ((breathMs -= ms) <= 0)
            breathMs = me.castSpell(spellNoxiousBreath) == ActionResult.ok ? 9000 + me.random(3001) : 0;
        if ((sweepMs -= ms) <= 0)
            sweepMs = me.castSpell(spellTailSweep) == ActionResult.ok ? 10_000 + me.random(20_001) : 0;
    }

    /// Whether it has anything to do.
    @property bool busy() const
    {
        return fighting;
    }
}

/// Casts `spell` at one of those it fights, at random; whether it was cast.
private bool castAtRandom(ref CreatureContext me, uint spell)
{
    const target = me.selectTarget(Pick.random);
    return target && me.castSpell(spell, target) == ActionResult.ok;
}

/// Emeriss: Volatile Infection; Corruption of Earth at 75, 50 and 25 percent; a Putrid Mushroom where a player dies.
@creature("boss_emeriss")
struct Emeriss
{
    enum : uint { spellVolatileInfection = 24928, spellCorruptionOfEarth = 24910, spellPutridMushroom = 24904,
        spellDespawnMushrooms = 24958 }
    enum : int { sayAggro = -1000401, sayCorruption = -1000402 }

    enum Step : ubyte { infection }
    Schedule!Step steps;
    DreamDragon dragon;

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        dragon.disengage();
        me.castSelf(spellDespawnMushrooms, true); // what a wipe left
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        dragon.engage(me);
        me.say(sayAggro);
        steps.after(Step.infection, 12.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.castAs(e.victim, spellPutridMushroom, e.victim, true);
        dragon.killed(me, e.victim);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (dragon.abilityDue(e.after) && me.castSelf(spellCorruptionOfEarth) == ActionResult.ok)
        {
            me.say(sayCorruption);
            ++dragon.abilitiesUsed;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            steps.after(Step.infection, castAtRandom(me, spellVolatileInfection) ? (7000 + me.random(5001)).msecs : 1.seconds);
    }
}

/**
 * Lethon: a whirl of Shadow Bolts about him; at 75, 50 and 25 percent he draws the spirit of everyone
 * near, and their shades walk to him to heal him.
 */
@creature("boss_lethon")
struct Lethon
{
    enum : uint { spellShadowBoltWhirl = 24834, spellDrawSpirit = 24811 }
    enum : int { sayAggro = -1000666, sayDrawSpirit = -1000667 }
    enum float drawRange = 100; /// Draw Spirit's radius

    DreamDragon dragon;

    void on(ref CreatureContext me, const ref Reset e)
    {
        dragon.disengage();
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        dragon.engage(me);
        me.say(sayAggro);
        me.castSelf(spellShadowBoltWhirl, true);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        dragon.killed(me, e.victim);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!dragon.abilityDue(e.after) || me.castSelf(spellDrawSpirit) != ActionResult.ok)
            return;
        me.say(sayDrawSpirit);
        ++dragon.abilitiesUsed;
        // A shade of each player the spell drew (`SpellHitTarget`), where the player stands, for a minute.
        EntityRef[40] players;
        foreach (player; players[0 .. me.playersNear(drawRange, players[])])
        {
            Location at;
            if (me.locationOf(player, at))
                me.summon(npcSpiritShade, at, 60_000);
        }
    }
}

/// A Spirit Shade of Lethon: it waits a moment, then walks to him and heals him with Dark Offering.
@creature("npc_spirit_shade")
struct SpiritShade
{
    enum : uint { spellDarkOffering = 24804, spellSpiritShapeVisual = 24809 }

    enum Step : ubyte { seek }
    Schedule!Step steps;
    bool healed;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.castSelf(spellSpiritShapeVisual, true);
        steps.after(Step.seek, 3.seconds);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.despawn();
    }

    void on(ref CreatureContext me, Step step)
    {
        if (healed)
            return;
        const lethon = me.creatureNearby(npcLethon, 100);
        if (!lethon)
            return cast(void) steps.after(Step.seek, 1.seconds);
        if (me.distanceTo(lethon) <= 3)
        {
            if (me.castSpell(spellDarkOffering, lethon) == ActionResult.ok)
            {
                healed = true;
                me.despawn(1000);
                return;
            }
        }
        else
        {
            Location at;
            if (me.locationOf(lethon, at))
                me.moveTo(at, 0);
        }
        steps.after(Step.seek, 1.seconds);
    }
}

/**
 * Taerar: Arcane Blast and Bellowing Roar; at 75, 50 and 25 percent he stuns himself and three Shades of
 * Taerar come, until they are dead or a minute is over.
 */
@creature("boss_taerar")
struct Taerar
{
    enum : uint { spellArcaneBlast = 24857, spellBellowingRoar = 22686, spellSelfStun = 24883,
        spellDespawnShades = 24886 }
    enum : int { sayAggro = -1000399, saySummonShades = -1000400 }

    enum Step : ubyte { arcaneBlast, roar, unbanish }
    Schedule!Step steps;
    DreamDragon dragon;
    ubyte shadesDead;

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        dragon.disengage();
        shadesDead = 0;
        me.unitFlags(UnitFlag.uninteractible, false);
        me.castSelf(spellDespawnShades, true); // what a wipe left
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        dragon.engage(me);
        me.say(sayAggro);
        steps.after(Step.arcaneBlast, 12.seconds);
        steps.after(Step.roar, 30.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        dragon.killed(me, e.victim);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (dragon.held || !dragon.abilityDue(e.after) || me.castSelf(spellSelfStun) != ActionResult.ok)
            return;
        ++dragon.abilitiesUsed;
        foreach (_; 0 .. 3)
            me.summon(npcShadeOfTaerar, me.location, 0, me.randomTarget);
        me.unitFlags(UnitFlag.uninteractible);
        me.say(saySummonShades);
        dragon.held = true;
        shadesDead = 0;
        steps.after(Step.unbanish, 60.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.summoned.entry == npcShadeOfTaerar && !e.gone && dragon.held && ++shadesDead == 3)
            unbanish(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return;
        final switch (step)
        {
        case Step.arcaneBlast:
            if (dragon.held)
                return cast(void) steps.after(step, 1.seconds);
            steps.after(step, castAtRandom(me, spellArcaneBlast) ? (7000 + me.random(5001)).msecs : 1.seconds);
            break;
        case Step.roar:
            if (dragon.held)
                return cast(void) steps.after(step, 1.seconds);
            steps.after(step, me.castSelf(spellBellowingRoar) == ActionResult.ok ? (20_000 + me.random(10_001)).msecs
                : 1.seconds);
            break;
        case Step.unbanish:
            unbanish(me);
            break;
        }
    }

    private void unbanish(ref CreatureContext me)
    {
        me.removeAura(me.self, spellSelfStun);
        me.unitFlags(UnitFlag.uninteractible, false);
        dragon.held = false;
        shadesDead = 0;
        steps.cancel(Step.unbanish);
    }
}

/// Ysondre: Lightning Wave; at 75, 50 and 25 percent a Demented Druid Spirit for each player she fights.
@creature("boss_ysondre")
struct Ysondre
{
    enum : uint { spellLightningWave = 24819, spellSummonDruids = 24796 }
    enum : int { sayAggro = -1000360, saySummonDruids = -1000361 }

    enum Step : ubyte { lightningWave }
    Schedule!Step steps;
    DreamDragon dragon;

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        dragon.disengage();
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        dragon.engage(me);
        me.say(sayAggro);
        steps.after(Step.lightningWave, 12.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        dragon.killed(me, e.victim);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!dragon.abilityDue(e.after) || me.castSelf(spellSummonDruids, true) != ActionResult.ok)
            return;
        me.say(saySummonDruids);
        ++dragon.abilitiesUsed;
        // One druid for each player she fights (the spell's dummy part, `Summon Demented Druid Spirit`).
        EntityRef[40] foes;
        foreach (foe; foes[0 .. me.threatList(foes[])])
        {
            Location at;
            if (foe.isPlayer && me.locationOf(foe, at))
                me.summon(npcDementedDruid, at, 0, foe);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            steps.after(step, castAtRandom(me, spellLightningWave) ? (7000 + me.random(5001)).msecs : 1.seconds);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;

    alias self = dmangos.scripts.emeralddragons;

    // The shared part: abilities at 75, 50 and 25 percent, once each.
    DreamDragon d;
    assert(!d.abilityDue(80) && d.abilityDue(74));
    d.abilitiesUsed = 3;
    assert(!d.abilityDue(1));

    // Emeriss: the fight's spells, Corruption at 75, the mark and the mushroom on a dead player.
    auto emeriss = Driven!self("boss_emeriss", npcEmeriss);
    emeriss.raise(Reset());
    assert(emeriss.host.has("cast 24958"));
    emeriss.host.fighting = true;
    emeriss.raise(EnteredCombat(hero));
    assert(emeriss.host.has("cast 25041") && emeriss.host.has("say -1000401"));
    emeriss.run(31_000);
    assert(emeriss.host.has("cast 24813") && emeriss.host.has("cast 24818") && emeriss.host.has("cast 15847"));
    emeriss.raise(Damaged(hero, 1000, 80, 70));
    assert(emeriss.host.has("cast 24910") && emeriss.host.has("say -1000402"));
    emeriss.raise(KilledUnit(hero));
    assert(emeriss.host.has("cast as hero 24904") && emeriss.host.has("cast as hero 25040"));

    // Taerar: banished at 75 with three shades, back when they are dead.
    auto taerar = Driven!self("boss_taerar", npcTaerar);
    taerar.host.fighting = true;
    taerar.raise(EnteredCombat(hero));
    taerar.raise(Damaged(hero, 1000, 80, 70));
    assert(taerar.host.has("cast 24883") && taerar.host.summons == 3 && taerar.host.has("flags+ 33554432"));
    foreach (shade; taerar.host.summoned)
        taerar.raise(SummonedDied(shade, hero));
    assert(taerar.host.has("unaura 24883") && taerar.host.has("flags- 33554432"));

    // A Spirit Shade walks to Lethon, and heals him once there.
    auto shade = Driven!self("npc_spirit_shade", npcSpiritShade);
    shade.raise(Spawned());
    shade.host.nearby[npcLethon] = creatureRef(npcLethon);
    shade.host.distance = 20;
    shade.run(3000);
    assert(shade.host.has("move 0"));
    shade.host.distance = 2;
    shade.run(1000);
    assert(shade.host.has("cast 24804") && shade.host.has("despawn"));
}
