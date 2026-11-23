/**
 * Eastern Plaguelands: Eris Havenfire, whose test for the priest on "The Balance of Light and
 * Shadow" (7622) is to save fifty peasants fleeing the Scourge before fifteen of them die, and the
 * Battle of Darrowshire and its aftermath.
 */
module dmangos.scripts.easternplaguelands;

import std.math : cos, sin;
import dmangos.script;

private enum : uint
{
    relicBundle = 177526,
    worldTrigger = 15384,
    questBattleOfDarrowshire = 5721,
    pamelaRedpath = 10926,
    josephRedpath = 10936,
    captainRedpath = 10937,
    corruptedRedpath = 10938,
    marduk = 10939,
    davilLightfire = 10944,
    davilCrokford = 10945,
    horgus = 10946,
    defender = 10948,
    disciple = 10949,
    militia = 10950,
    maraudingCorpse = 10951,
    maraudingSkeleton = 10952,
    servant = 10953,
    bloodletter = 10954,
    corruptCaptain = 1,
    faceJoseph = 2,
}

/// A spot within `radius` yards of `center`, at random.
private Location around(ref CreatureContext me, Location center, float radius)
{
    const angle = me.random(360) * 0.0174533f, distance = me.random(cast(uint)(radius * 10) + 1) / 10.0f;
    return Location(center.x + distance * cos(angle), center.y + distance * sin(angle), center.z);
}

/// Placing the quest's Relic Bundle starts a single Battle of Darrowshire in the town square.
@gameObject("go_darrowshire_relic_bundle")
struct DarrowshireRelicBundle
{
    void on(ref GameObjectContext bundle, const ref Spawned e)
    {
        if (!bundle.creatureNearby(worldTrigger, 100) && !bundle.creatureNearby(josephRedpath, 150))
            bundle.summon(worldTrigger, bundle.location, 16 * 60_000);
    }
}

/**
 * Runs only for the World Trigger summoned by the Relic Bundle. The quest's defenders hold the square
 * through the attack on Davil, Horgus's defeat and Captain Redpath's corruption. The redeemed Joseph
 * appears only after the last battle.
 */
@creature("npc_darrowshire_controller")
struct DarrowshireBattle
{
    enum Step : ubyte { first, corpses, defenders, davil, servants, disciples, horgusArrives, davilReplies,
        davilLeaves, redpath, bloodletters, militia, mardukArrives, corruption, timeout }
    Schedule!Step steps;
    EntityRef davil, captain, ravager, corrupted;
    EntityRef[] troops;
    bool active;

    private enum Location well = Location(1446.8f, -3694.27f, 76.5966f, 0.401503f);
    private enum Location bloodletterStart = Location(1537.6f, -3677.1f, 88.7f, 3.14884f);
    private static immutable Location[3] attackFrom = [Location(1500.04f, -3662.67f, 82.832f, 3.70805f),
        Location(1506.17f, -3686.72f, 82.8769f, 5.75945f), Location(1512.81f, -3724.64f, 87.12099f, 1.64164f)];
    private static immutable Location[3] defendFrom = [Location(1484.68f, -3668.74f, 80.6953f, 0.236567f),
        Location(1493.53f, -3695.01f, 80.1347f, 0.264055f), Location(1505.28f, -3718.83f, 83.343f, 1.36911f)];

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.owner.entry != relicBundle)
            return;
        active = true;
        me.reactState(Reaction.passive);
        steps.after(Step.first, 6.seconds);
        steps.every(Step.corpses, 15.seconds, 25.seconds);
        steps.every(Step.defenders, 17.seconds, 45.seconds);
        steps.after(Step.timeout, (15 * 60).seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.first:
            const lead = spawn(me, defender, well);
            me.sayAs(lead, 7358);
            me.moveCreature(lead, defendFrom[0], 0, true);
            steps.after(Step.davil, (120_000 + me.random(60_001)).msecs);
            break;
        case Step.corpses, Step.servants:
            foreach (i, at; attackFrom)
                foreach (_; 0 .. 1 + me.random(2))
                    attacker(me, step == Step.servants ? servant : (me.random(2) ? maraudingSkeleton : maraudingCorpse),
                        at, defendFrom[i]);
            break;
        case Step.defenders, Step.disciples, Step.militia:
            const entry = step == Step.defenders ? defender : step == Step.disciples ? disciple : militia;
            foreach (i, at; defendFrom)
                if (auto ally = spawn(me, entry, around(me, at, 5)))
                {
                    if (!i && step == Step.militia)
                        me.sayAs(ally, 7347 + me.random(8));
                    if (auto enemy = me.creatureNearby(maraudingCorpse, 100))
                        me.attack(ally, enemy);
                }
            break;
        case Step.davil:
            davil = spawn(me, davilLightfire, well, 0);
            me.sayAs(davil, 7343);
            me.moveCreature(davil, defendFrom[0], 1, true);
            steps.every(Step.servants, 4.seconds, 35.seconds);
            steps.every(Step.disciples, 6.seconds, 45.seconds);
            steps.after(Step.horgusArrives, 60.seconds);
            break;
        case Step.horgusArrives:
        {
            Location at;
            if (!me.locationOf(davil, at) || !me.alive(davil))
                return finish(me, 7366);
            ravager = spawn(me, horgus, around(me, at, 6), 0);
            me.attack(ravager, davil);
            me.sayAs(ravager, 7344);
            steps.after(Step.davilReplies, 3.seconds);
            break;
        }
        case Step.davilReplies:
            me.sayAs(davil, 7346);
            break;
        case Step.davilLeaves:
            me.sayAs(davil, 7227);
            me.despawn(davil, 2000);
            davil = EntityRef.init;
            steps.after(Step.redpath, 10.seconds);
            break;
        case Step.redpath:
            captain = spawn(me, captainRedpath, well, 0);
            me.sayAs(captain, 7355);
            me.moveCreature(captain, defendFrom[0], 1, true);
            steps.every(Step.bloodletters, 4.seconds, 35.seconds);
            steps.every(Step.militia, 6.seconds, 45.seconds);
            steps.after(Step.mardukArrives, (300_000 + me.random(50_001)).msecs);
            break;
        case Step.bloodletters:
            foreach (at; defendFrom)
                attacker(me, bloodletter, bloodletterStart, at);
            break;
        case Step.mardukArrives:
        {
            Location at;
            if (!me.locationOf(captain, at) || !me.alive(captain))
                return finish(me, 7369);
            const enemy = spawn(me, marduk, around(me, at, 10), 12_000);
            me.sayAs(enemy, 7471);
            steps.after(Step.corruption, 5.seconds);
            break;
        }
        case Step.corruption:
        {
            Location at;
            if (!me.locationOf(captain, at) || !me.alive(captain))
                return finish(me, 7369);
            const livingCaptain = captain;
            captain = EntityRef.init; // This death is part of the reenactment.
            me.signal(livingCaptain, corruptCaptain);
            corrupted = spawn(me, corruptedRedpath, at, 120_000);
            me.sayAs(corrupted, 7357);
            break;
        }
        case Step.timeout:
            finish(me);
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        import std.algorithm.mutation : remove;

        troops = troops.remove!(troop => troop == e.summoned);
        if (!active)
            return;
        if (e.summoned == ravager)
        {
            ravager = EntityRef.init;
            if (e.gone)
                return finish(me);
            steps.cancel(Step.servants);
            steps.cancel(Step.davilReplies);
            sayFromDefender(me, 7368);
            steps.after(Step.davilLeaves, 8.seconds);
        }
        else if (e.summoned == davil && !steps.pending(Step.davilLeaves))
            finish(me, 7366);
        else if (e.summoned == captain)
            finish(me, 7369);
        else if (e.summoned == corrupted)
        {
            if (!e.gone)
            {
                sayFromDefender(me, 7407);
                me.summon(josephRedpath, well, 600_000);
                me.summon(davilCrokford, Location(1465.43f, -3678.48f, 78.0816f, 0.0402176f), 120_000);
            }
            finish(me);
        }
    }

    private EntityRef spawn(ref CreatureContext me, uint entry, Location at, uint despawnMs = 120_000)
    {
        auto troop = me.summon(entry, at, despawnMs);
        if (troop)
            troops ~= troop;
        return troop;
    }

    private void attacker(ref CreatureContext me, uint entry, Location at, Location destination)
    {
        if (auto enemy = spawn(me, entry, around(me, at, 5)))
            me.moveCreature(enemy, destination, 0);
    }

    private void sayFromDefender(ref CreatureContext me, uint text)
    {
        if (const speaker = me.creatureNearby(defender, 150))
            me.sayAs(speaker, text);
    }

    private void finish(ref CreatureContext me, uint message = 0)
    {
        active = false;
        steps.clear();
        if (message)
            sayFromDefender(me, message);
        auto survivors = troops;
        troops = null;
        foreach (troop; survivors)
            me.despawn(troop, 5000);
        me.despawn();
    }
}

/// Several imported actors are friendly or neutral outside this reenactment. Their sides here are opposed.
@creature("npc_darrowshire_combatant")
struct DarrowshireCombatant
{
    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.owner.entry != worldTrigger)
            return;
        switch (me.self.entry)
        {
        case captainRedpath, davilLightfire, defender, disciple, militia:
            me.setFaction(EscortFaction.neutralFriendActive);
            break;
        case corruptedRedpath, bloodletter:
            me.setFaction(14);
            me.npcFlags(0);
            break;
        case marduk:
            me.unitFlags(UnitFlag.notAttackable | UnitFlag.uninteractible | UnitFlag.immuneToNpc);
            me.reactState(Reaction.passive);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == corruptCaptain && me.self.entry == captainRedpath && e.from == me.owner)
            me.die();
    }
}

/// Joseph's ordinary gossip grants forgiveness. After a short wait he walks to Pamela and they reunite.
@creature("npc_darrowshire_joseph")
struct DarrowshireJoseph
{
    enum Step : ubyte { leave, daughterHears, embraces, laugh, missed, home }
    Schedule!Step steps;
    bool started;
    EntityRef pamela;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!started && me.questStatus(e.player, questBattleOfDarrowshire) == QuestProgress.incomplete)
        {
            started = true;
            me.emote(20); // EMOTE_ONESHOT_BEG
            steps.after(Step.leave, 30.seconds);
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (e.point)
        {
        case 0:
            me.moveTo(Location(1434.22f, -3668.756f, 76.671f), 1);
            break;
        case 1:
            me.moveTo(Location(1438.526f, -3632.733f, 78.268f), 2);
            me.sayText(7397);
            steps.after(Step.daughterHears, 3.seconds);
            break;
        case 2:
        {
            import std.math : sqrt;

            Location at;
            if (!pamela || !me.locationOf(pamela, at))
                return;
            me.sayAs(pamela, 7400);
            const here = me.location;
            const dx = here.x - at.x, dy = here.y - at.y;
            const distance = sqrt(dx * dx + dy * dy);
            if (distance > 1)
            {
                at.x += dx / distance;
                at.y += dy / distance;
            }
            me.moveTo(at, 3, true);
            break;
        }
        case 3:
            me.face(pamela);
            me.signal(pamela, faceJoseph);
            steps.after(Step.embraces, 2.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.leave:
            me.npcFlags(0);
            me.moveTo(Location(1431.501f, -3684.229f, 75.726f), 0);
            break;
        case Step.daughterHears:
            pamela = me.creatureNearby(pamelaRedpath, 150);
            if (pamela)
            {
                me.sayAs(pamela, 7399);
                me.moveCreature(pamela, Location(1450.733f, -3599.974f, 85.621f), 0, true);
            }
            break;
        case Step.embraces:
            me.sayAs(pamela, 7401);
            steps.after(Step.laugh, 5.seconds);
            break;
        case Step.laugh:
            me.sayText(7398);
            steps.after(Step.missed, 3.seconds);
            break;
        case Step.missed:
            me.sayAs(pamela, 7402);
            steps.after(Step.home, 4.seconds);
            break;
        case Step.home:
            me.sayText(7403);
            me.restoreNpcFlags();
            me.despawn(pamela, 4000);
            me.despawn(6000);
            break;
        }
    }
}

/// Pamela turns to Joseph as he comes up to her.
@creature("npc_darrowshire_pamela")
struct DarrowshirePamela
{
    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == faceJoseph && e.from.entry == josephRedpath)
            me.face(e.from);
    }
}

/**
 * Eris Havenfire: taken on the quest, eight Scourge Archers take their places on the hills and waves
 * of peasants (eleven, then one more each wave) come down the road to the light, where those who
 * make it are saved; the archers shoot at them, and Scourge Footsoldiers keep coming for the priest.
 * Each wave over, the priest is blessed and the next comes. Fifty saved, the quest's event happens;
 * fifteen dead, it fails and she goes.
 */
@creature("npc_eris_havenfire")
struct ErisHavenfire
{
    enum uint questBalanceOfLightAndShadow = 7622;
    enum uint injuredPeasant = 14484, plaguedPeasant = 14485, scourgeArcher = 14489, scourgeFootsoldier = 14486;
    enum uint spellEnterTheLight = 23107, spellBlessingOfNordrassil = 23108;
    /// `script_texts` rows.
    enum : int
    {
        sayPhaseHeal = -1000815, sayEventEnd = -1000816, sayEventFail1 = -1000817, sayEventFail2 = -1000818,
        sayPeasantAppear1 = -1000819,
    }
    enum uint basePeasantsPerWave = 11, maxKilled = 15, maxSaved = 50, waves = 5;
    enum uint pointSaved = 1, outsideAid = 1, cleaner = 14503;
    @transient Location[ulong] lastSeen;


    private static immutable Location[8] archersAt = [Location(3327.42f, -3021.11f, 170.57f, 6.01f),
        Location(3335.4f, -3054.3f, 173.63f, 0.49f), Location(3351.3f, -3079.08f, 178.67f, 1.15f),
        Location(3358.93f, -3076.1f, 174.87f, 1.57f), Location(3371.58f, -3069.24f, 175.20f, 1.99f),
        Location(3369.46f, -3023.11f, 171.83f, 3.69f), Location(3383.25f, -3057.01f, 181.53f, 2.21f),
        Location(3380.03f, -3062.73f, 181.90f, 2.31f)];
    private enum Location peasantsFrom = Location(3360.12f, -3047.79f, 165.26f);
    private enum Location peasantsTo = Location(3335.0f, -2994.04f, 161.14f);

    enum Step : ubyte { archers, wave, footsoldiers, aim, sadEnd }
    Schedule!Step steps;
    EntityRef player;
    EntityRef[] peasants;   /// on their way
    EntityRef[8] archers;
    EntityRef[8] aimedAt;   /// each archer's peasant
    EntityRef[] others;     /// footsoldiers
    ubyte wave, killed, saved, total;
    bool active;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questBalanceOfLightAndShadow || active)
            return;
        this = ErisHavenfire.init;
        active = true;
        player = e.player;
        me.npcFlags(0);
        steps.after(Step.archers, 5.seconds);
        steps.every(Step.aim, 2.seconds);
        observeProcession(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.archers:
            foreach (i, at; archersAt)
                archers[i] = me.summon(scourgeArcher, at);
            steps.after(Step.wave, 5.seconds);
            break;
        case Step.wave:
            sendWave(me);
            steps.after(Step.footsoldiers, (60_000 + me.random(20_001)).msecs);
            break;
        case Step.footsoldiers:
            foreach (_; 0 .. 2 + me.random(2))
                others ~= me.summon(scourgeFootsoldier, around(me, peasantsFrom, 15), 0, player);
            steps.after(Step.footsoldiers, (5000 + me.random(25_001)).msecs);
            break;
        case Step.aim:
            observeProcession(me);
            if (active)
                aim(me);
            break;
        case Step.sadEnd:
            me.say(sayEventFail2);
            clearSummons(me, true);
            me.despawn(5000);
            active = false;
            steps.clear();
            break;
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (active && e.id == outsideAid && e.from == player)
            interference(me);
    }

    private void interference(ref CreatureContext me)
    {
        if (!active || steps.pending(Step.sadEnd))
            return;
        Location at;
        if (!me.locationOf(player, at))
            return;
        active = false;
        steps.clear();
        me.summon(cleaner, at, 60_000, player);
        me.failQuest(player, questBalanceOfLightAndShadow);
        clearSummons(me, true);
        me.despawn(5000);
    }

    // Detect crossing a live peasant's path. Stationary observers and players staying up by Eris can help.
    private void observeProcession(ref CreatureContext me)
    {
        EntityRef[64] nearby;
        Location[ulong] current;
        foreach (observer; nearby[0 .. me.playersNear(100, nearby[])])
        {
            Location at;
            if (observer == player || !me.locationOf(observer, at))
                continue;
            current[observer.guid] = at;
            if (const before = observer.guid in lastSeen)
                foreach (peasant; peasants)
                {
                    Location onRoad;
                    if (me.locationOf(peasant, onRoad) && crossed(*before, at, onRoad))
                    {
                        interference(me);
                        return;
                    }
                }
        }
        lastSeen = current;
    }

    private static bool crossed(Location a, Location b, Location peasant)
    {
        import std.algorithm.comparison : clamp;
        const dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z;
        const lengthSquared = dx * dx + dy * dy + dz * dz;
        if (lengthSquared < 0.01f)
            return false;
        const t = clamp(((peasant.x - a.x) * dx + (peasant.y - a.y) * dy + (peasant.z - a.z) * dz)
            / lengthSquared, 0.0f, 1.0f);
        // Two ordinary humanoids passing within their combined melee reach.
        return (a.x + t * dx - peasant.x) ^^ 2 + (a.y + t * dy - peasant.y) ^^ 2
            + (a.z + t * dz - peasant.z) ^^ 2 <= 9;
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (!active || e.point != pointSaved || !forget(e.summoned))
            return;
        ++saved;
        me.castSpell(spellEnterTheLight, e.summoned, true);
        me.despawn(e.summoned, 10_000);
        if (saved >= maxSaved)
            end(me);
        else if (saved + killed == total)
            waveOver(me);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (!active || !forget(e.summoned))
            return;
        if (e.gone) // not lost: it is just not there any more
        {
            if (--total == saved + killed)
                waveOver(me);
            return;
        }
        if (++killed == maxKilled)
        {
            me.failQuest(player, questBalanceOfLightAndShadow);
            me.say(sayEventFail1);
            steps.clear();
            steps.after(Step.sadEnd, 4.seconds);
        }
        else if (saved + killed == total)
            waveOver(me);
    }

    /// Peasants of the next wave, down the road to the light.
    private void sendWave(ref CreatureContext me)
    {
        foreach (i; 0 .. basePeasantsPerWave + wave)
        {
            const entry = me.random(100) < 70 ? injuredPeasant : plaguedPeasant;
            const peasant = me.summon(entry, around(me, peasantsFrom, 10));
            if (!peasant)
                continue;
            ++total;
            peasants ~= peasant;
            if (i == 0)
                me.sayOther(peasant, sayPeasantAppear1 - cast(int) me.random(3));
            me.moveCreature(peasant, around(me, peasantsTo, 10), pointSaved);
        }
        ++wave;
    }

    private void waveOver(ref CreatureContext me)
    {
        me.castSpell(spellBlessingOfNordrassil, player, true);
        me.say(sayPhaseHeal);
        if (wave < waves)
            sendWave(me);
    }

    private void end(ref CreatureContext me)
    {
        me.groupQuestEvent(player, questBalanceOfLightAndShadow);
        me.say(sayEventEnd);
        clearSummons(me, false);
        active = false;
        steps.clear();
        me.restoreNpcFlags();
    }

    /// Each archer without a peasant to shoot at takes one.
    private void aim(ref CreatureContext me)
    {
        if (peasants.length == 0)
            return;
        foreach (i, archer; archers)
        {
            if (!archer || !me.alive(archer))
                continue;
            if (aimedAt[i] && isOnTheRoad(aimedAt[i]))
                continue;
            aimedAt[i] = peasants[me.random(cast(uint) peasants.length)];
            me.attack(archer, aimedAt[i]);
        }
    }

    private bool isOnTheRoad(EntityRef peasant) const
    {
        foreach (p; peasants)
            if (p == peasant)
                return true;
        return false;
    }

    /// A peasant is saved or dead: off the road. False if it was not one on it.
    private bool forget(EntityRef peasant)
    {
        foreach (i, p; peasants)
            if (p == peasant)
            {
                peasants[i] = peasants[$ - 1];
                peasants = peasants[0 .. $ - 1];
                return true;
            }
        return false;
    }

    /// The Scourge go (and the peasants too, if `all`).
    private void clearSummons(ref CreatureContext me, bool all)
    {
        foreach (a; archers)
            if (a)
                me.despawn(a, 0);
        foreach (o; others)
            me.despawn(o, 0);
        if (all)
            foreach (p; peasants)
                me.despawn(p, 0);
        archers[] = EntityRef.init;
        others = null;
    }

}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto eris = Driven!(dmangos.scripts.easternplaguelands).make("npc_eris_havenfire");
    eris.raise(QuestAccepted(eris.host.player, 7622));
    eris.tick(10_000);
    assert(eris.host.summons == 8 + 11 && eris.host.did("attack 14489 14484"));
    // Peasants of each wave: those the host made, in order (its summons are numbered).
    EntityRef peasant(uint n) { return EntityRef(0xF130_0000_0000_0000 | (ulong(14484) << 24) | n); }
    foreach (n; 9 .. 9 + 11)
        eris.raise(SummonedArrived(peasant(n), 1));
    assert(eris.host.did("say -1000815") && eris.host.did("cast 23108") && eris.host.summons == 8 + 11 + 12);
    foreach (n; 20 .. 20 + 12)
        eris.raise(SummonedDied(peasant(n)));
    assert(!eris.host.did("fail 7622") && eris.host.summons == 8 + 11 + 12 + 13, "twelve dead: the third wave");
    foreach (n; 32 .. 32 + 3)
        eris.raise(SummonedDied(peasant(n)));
    assert(eris.host.did("fail 7622") && eris.host.did("say -1000817"), "the fifteenth dead");
    eris.tick(4000);
    assert(eris.host.did("say -1000818") && eris.host.did("despawn"));
}


unittest
{
    const peasant = Location(10, 10, 0);
    assert(ErisHavenfire.crossed(Location(5, 10, 0), Location(15, 10, 0), peasant));
    assert(!ErisHavenfire.crossed(peasant, peasant, peasant));
    assert(!ErisHavenfire.crossed(Location(5, 10, 9), Location(15, 10, 9), peasant));
}
