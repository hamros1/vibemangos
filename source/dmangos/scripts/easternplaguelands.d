/**
 * Eastern Plaguelands: Eris Havenfire, whose test for the priest on "The Balance of Light and
 * Shadow" (7622) is to save fifty peasants fleeing the Scourge before fifteen of them die.
 */
module dmangos.scripts.easternplaguelands;

import std.math : cos, sin;
import dmangos.script;

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
    enum uint pointSaved = 1;

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
        me.questEvent(player, questBalanceOfLightAndShadow);
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

    /// A spot within `radius` yards of `center`, at random.
    private static Location around(ref CreatureContext me, Location center, float radius)
    {
        const angle = me.random(360) * 0.0174533f, distance = me.random(cast(uint)(radius * 10) + 1) / 10.0f;
        return Location(center.x + distance * cos(angle), center.y + distance * sin(angle), center.z);
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
