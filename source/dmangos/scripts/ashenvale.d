/**
 * Ashenvale: the escorts of Muglash, to light the Naga Brazier and slay Vorsha the Lasher ("Vorsha
 * the Lasher", 6641); of Ruul Snowhoof out of the Thistlefur hold ("Freedom to Ruul", 6482); of
 * Torek to the Silverwing Outpost ("Torek's Assault", 6544); and of Feero Ironhand with his supplies
 * ("Supplies to Auberdine", 976).
 */
module dmangos.scripts.ashenvale;

import dmangos.script;

/// `Emotes` these scripts play.
private enum : uint { emoteTalk = 1, emoteBow = 2, emoteCheer = 4, emotePoint = 25 }

/**
 * Muglash: walks to the Naga Brazier and waits for the player to light it (five minutes, or he gives
 * up); the brazier lit, two waves of naga come out of the water, then Vorsha the Lasher. With Vorsha
 * dead, he thanks the player (the quest's event) and goes.
 */
@creature("npc_muglash")
struct Muglash
{
    enum uint questVorsha = 6641, spellWaiting = 20861, nagaBrazier = 178247, signalBrazierLit = 1;
    enum : uint { wrathRider = 3713, wrathSorceress = 3717, wrathRazortail = 3712, wrathPriestess = 3944,
        wrathMyrmidon = 3711, wrathSeawitch = 3715, vorsha = 12940 }
    /// `broadcast_text` rows.
    enum : uint { sayAggro = 8412, sayBrazier = 8556, sayFail = 8409, sayEvent1 = 8410, sayEvent2 = 8413,
        sayEvent3 = 8567, sayEvent4 = 8568, saySuccess = 8569, saySuccess2 = 8558, saySuccess3 = 8564, saySuccess4 = 8565 }

    private static immutable uint[3] firstWave = [wrathRazortail, wrathRider, wrathSorceress];
    private static immutable Location[3] firstWaveAt = [Location(3629.9194f, 1169.9987f, -3.4472558f),
        Location(3617.8516f, 1097.7166f, -4.0877485f), Location(3583.1497f, 1165.5658f, -5.3660164f)];
    private static immutable uint[3] secondWave = [wrathMyrmidon, wrathSeawitch, wrathPriestess];
    private static immutable Location[3] secondWaveAt = [Location(3575.009f, 1119.8704f, -4.2547455f),
        Location(3606.9448f, 1176.3822f, -2.9632108f), Location(3651.5383f, 1155.5522f, -3.9628646f)];

    enum Step : ubyte { event, fail }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    ubyte eventId, firstAlive, secondAlive;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questVorsha || escort.active)
            return;
        me.setFaction(EscortFaction.hordeNeutralPassive);
        eventId = firstAlive = secondAlive = 0;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (escort.paused && me.random(2))
            me.sayText(sayAggro, escort.player);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 15: // at the brazier
            escort.paused = true;
            eventId = 0;
            steps.after(Step.event, 2.seconds);
            break;
        case 16:
            escort.paused = true;
            break;
        case 17:
            escort.paused = true;
            eventId = 5;
            steps.after(Step.event, 2.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != signalBrazierLit || !escort.active || eventId != 1) // 1: waiting at the brazier
            return;
        steps.cancel(Step.fail);
        me.removeAura(me.self, spellWaiting);
        eventId = 2;
        steps.after(Step.event, 2.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        switch (e.summoned.entry)
        {
        case wrathRazortail, wrathRider, wrathSorceress:
            if (firstAlive && --firstAlive == 0)
            {
                foreach (i, entry; secondWave)
                    if (me.attack(me.summon(entry, secondWaveAt[i], 60_000), me.self) == ActionResult.ok)
                        ++secondAlive;
                eventId = 3;
                steps.after(Step.event, 5.seconds);
            }
            break;
        case wrathMyrmidon, wrathSeawitch, wrathPriestess:
            if (secondAlive && --secondAlive == 0)
            {
                me.attack(me.summon(vorsha, Location(3630.2092f, 1190.3536f, -16.624332f), 60_000), me.self);
                escort.paused = false;
            }
            break;
        case vorsha:
            eventId = 7;
            steps.after(Step.event, 2.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.fail)
        {
            // Nobody lit the brazier.
            me.sayText(sayFail, escort.player);
            me.emote(emoteTalk);
            if (const brazier = me.objectNearby(nagaBrazier, 10))
                me.objectUsable(brazier, false);
            escort.fail(me);
            return;
        }
        switch (eventId)
        {
        case 0:
            me.sayText(sayBrazier, escort.player);
            me.emote(emoteTalk);
            steps.after(Step.fail, 300.seconds);
            eventId = 1;
            steps.after(Step.event, 2.seconds);
            break;
        case 1:
            if (const brazier = me.objectNearby(nagaBrazier, 10))
                me.objectUsable(brazier, true);
            me.castSelf(spellWaiting);
            break;
        case 2:
            me.sayText(sayEvent1, escort.player);
            foreach (i, entry; firstWave)
                if (me.attack(me.summon(entry, firstWaveAt[i], 60_000), me.self) == ActionResult.ok)
                    ++firstAlive;
            escort.paused = false;
            break;
        case 3:
            me.sayText(sayEvent2);
            me.standState(StandState.sit);
            eventId = 4;
            steps.after(Step.event, 9.seconds);
            break;
        case 4:
            me.standState(StandState.sit);
            eventId = 5;
            break;
        case 5:
            me.standState(StandState.stand);
            me.sayText(sayEvent3);
            eventId = 6;
            steps.after(Step.event, 3.seconds);
            break;
        case 6:
            me.emote(emotePoint);
            me.sayText(sayEvent4);
            break;
        case 7:
            me.emote(emoteCheer);
            me.sayText(saySuccess, escort.player);
            eventId = 8;
            steps.after(Step.event, 8.seconds);
            break;
        case 8:
            me.groupQuestEvent(escort.player, questVorsha);
            me.emote(emoteBow);
            me.sayText(saySuccess2, escort.player);
            eventId = 9;
            steps.after(Step.event, 3.seconds);
            break;
        case 9:
            me.emote(emoteTalk);
            me.sayText(saySuccess3);
            eventId = 10;
            steps.after(Step.event, 5.seconds);
            break;
        case 10:
            me.sayText(saySuccess4);
            eventId = 11;
            steps.after(Step.event, 5.seconds);
            break;
        case 11:
            escort.active = false;
            me.despawn(14_000);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }
}

/// The Naga Brazier: lit, it tells Muglash, and cannot be lit again.
@gameObject("go_naga_brazier")
struct NagaBrazier
{
    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        if (const muglash = it.creatureNearby(12_717, 10))
            it.signal(muglash, Muglash.signalBrazierLit);
        it.objectFlags(it.self, 0x10, true); // not usable any more
    }
}

/// Ruul Snowhoof: a bear until freed; led out of the Thistlefur hold, ambushed twice on the way.
@creature("npc_ruul_snowhoof")
struct RuulSnowhoof
{
    enum uint questFreedomToRuul = 6482, spellShapechange = 20514;
    enum : uint { thistlefurAvenger = 3925, thistlefurShaman = 3924, thistlefurPathfinder = 3926 }
    enum int sayComplete = -1010022;

    private static immutable Location[2] ambushAt = [Location(3425.33f, -595.93f, 178.31f),
        Location(3245.34f, -506.66f, 150.05f)];

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spellShapechange, true);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        me.castSelf(spellShapechange, true);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questFreedomToRuul || escort.active)
            return;
        me.setFaction(EscortFaction.hordeNeutralPassive);
        me.standState(StandState.stand);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 14: ambush(me, 0); break;
        case 31: ambush(me, 1); break;
        case 32:
            me.unitFlags(UnitFlag.immuneToNpc);
            me.removeAura(me.self, spellShapechange);
            me.face(escort.player);
            me.groupQuestEvent(escort.player, questFreedomToRuul);
            break;
        case 33:
            me.say(sayComplete, escort.player);
            me.face(escort.player);
            me.emote(emoteBow);
            escort.run = true;
            break;
        case 34:
            me.castSelf(spellShapechange);
            break;
        case 36:
            me.unitFlags(UnitFlag.immuneToNpc, false);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    private void ambush(ref CreatureContext me, size_t index)
    {
        static immutable uint[3] ambushers = [thistlefurAvenger, thistlefurShaman, thistlefurPathfinder];
        foreach (i, entry; ambushers)
        {
            const at = ambushAt[index];
            const spot = Location(at.x + (cast(int) me.random(15) - 7), at.y + (cast(int) me.random(15) - 7), at.z);
            me.attack(me.summon(entry, spot, 60_000), me.self);
        }
    }
}

/// Torek: leads the Splintertree raiders to the Silverwing Outpost; with Duriel's guard beaten, the
/// assault succeeded.
@creature("npc_torek")
struct Torek
{
    enum uint questTorekAssault = 6544, spellRend = 11977, spellThunderclap = 8078;
    enum : uint { duriel = 12860, silverwingSentinel = 12896, silverwingWarrior = 12897 }
    enum : int { sayReady = -1000106, sayMove = -1000107, sayPrepare = -1000108, sayWin = -1000109, sayEnd = -1000110 }

    enum Step : ubyte { rend, thunderclap }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questTorekAssault || escort.active)
            return;
        me.say(sayReady, e.player);
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 2: me.say(sayMove, escort.player); break;
        case 9: me.say(sayPrepare, escort.player); break;
        case 20:
            me.attack(me.summon(duriel, Location(1776.73f, -2049.06f, 109.83f, 1.54f), 25_000), me.self);
            me.attack(me.summon(silverwingSentinel, Location(1774.64f, -2049.41f, 109.83f, 1.40f), 25_000), me.self);
            me.attack(me.summon(silverwingWarrior, Location(1778.73f, -2049.50f, 109.83f, 1.67f), 25_000), me.self);
            break;
        case 21:
            me.say(sayWin, escort.player);
            me.groupQuestEvent(escort.player, questTorekAssault);
            break;
        case 22: me.say(sayEnd, escort.player); break;
        default: break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.rend, 5.seconds, 20.seconds);
        steps.every(Step.thunderclap, 8.seconds, 30.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return steps.clear();
        if (step == Step.rend)
            me.castSpell(spellRend);
        else
            me.castSelf(spellThunderclap);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }
}

/**
 * Feero Ironhand: takes his supplies to Auberdine; Dark Strand assassins, then Forsaken scouts, then
 * three of the Forsaken's elite lie in wait on the way.
 */
@creature("npc_feero_ironhand")
struct FeeroIronhand
{
    enum uint questSuppliesToAuberdine = 976;
    enum : uint { darkStrandAssassin = 3879, forsakenScout = 3893, aligar = 3898, balizar = 3899, caedakar = 3900 }
    enum : int
    {
        sayQuestStart = -1000771, sayFirstAmbushStart = -1000772, sayFirstAmbushEnd = -1000773,
        saySecondAmbushStart = -1000774, sayScoutSecondAmbush = -1000775, saySecondAmbushEnd = -1000776,
        sayFinalAmbushStart = -1000777, sayBalizarFinalAmbush = -1000778, sayFinalAmbushAttack = -1000779,
        sayQuestEnd = -1000780,
    }

    Escort escort = { despawnAfterMs: 1000 };
    ubyte alive;
    bool balizarAttacked;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questSuppliesToAuberdine || escort.active)
            return;
        me.say(sayQuestStart, e.player);
        me.setFaction(EscortFaction.allianceNeutralPassive);
        alive = 0;
        balizarAttacked = false;
        escort.start(me, e.player, e.quest, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        import std.math : PI;

        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 15:
            me.say(sayFirstAmbushStart);
            foreach (i; 0 .. 4)
                spawnAround(me, darkStrandAssassin, 30, 1.25f - PI / 4 * i);
            break;
        case 21:
            me.say(saySecondAmbushStart);
            foreach (i; 0 .. 3)
            {
                const scout = spawnAround(me, forsakenScout, 30, 0.95f - PI / 3 * i);
                if (i == 0)
                    me.sayOther(scout, sayScoutSecondAmbush, me.self);
            }
            break;
        case 30:
            me.say(sayFinalAmbushStart);
            const balizarRef = me.summon(balizar, Location(4243.12f, 108.22f, 38.12f, 3.62f), 20_000);
            me.sayOther(balizarRef, sayBalizarFinalAmbush);
            engage(me, balizarRef);
            engage(me, me.summon(aligar, Location(4240.95f, 114.04f, 38.35f, 3.56f), 20_000));
            engage(me, me.summon(caedakar, Location(4235.78f, 118.09f, 38.08f, 4.12f), 20_000));
            break;
        case 31:
            me.groupQuestEvent(escort.player, questSuppliesToAuberdine);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!balizarAttacked && e.attacker.entry == balizar && !e.attacker.isPlayer)
        {
            balizarAttacked = true;
            me.say(sayFinalAmbushAttack);
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (e.gone)
            return;
        if (!alive || --alive)
            return;
        switch (e.summoned.entry)
        {
        case darkStrandAssassin: me.say(sayFirstAmbushEnd); break;
        case forsakenScout: me.say(saySecondAmbushEnd); break;
        case aligar, balizar, caedakar: me.say(sayQuestEnd); break;
        default: break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    private EntityRef spawnAround(ref CreatureContext me, uint entry, float distance, float angle)
    {
        import std.math : cos, sin;

        const at = me.location;
        const summoned = me.summon(entry, Location(at.x + distance * cos(angle), at.y + distance * sin(angle), at.z), 20_000);
        engage(me, summoned);
        return summoned;
    }

    private void engage(ref CreatureContext me, EntityRef summoned)
    {
        if (summoned)
        {
            ++alive;
            me.attack(summoned, me.self);
        }
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.ashenvale;

    // Muglash: the brazier waits for the player; lit, the waves, Vorsha, and the quest.
    auto m = Driven!self("npc_muglash", 12_717, 30);
    m.host.objects[Muglash.nagaBrazier] = EntityRef(0xF110_0000_0000_0001);
    m.raise(QuestAccepted(hero, Muglash.questVorsha));
    assert(m.host.has("faction 33"));
    m.walkTo(14);
    m.run(5000);
    assert(m.host.has("text 8556") && m.host.has("usable") && m.host.has("cast 20861"));
    assert(!m.host.has("move 15"), "he waits at the brazier");
    m.raise(Signal(EntityRef(0xF110_0000_0000_0001), Muglash.signalBrazierLit));
    m.run(2100);
    assert(m.host.has("text 8410") && m.host.summons == 3 && m.host.has("move 15"));
    m.walkTo(15);
    foreach (c; m.host.summoned[0 .. 3])
        m.raise(SummonedDied(c, hero));
    assert(m.host.summons == 6, "the second wave");
    m.run(5000);
    assert(m.host.has("text 8413"));
    foreach (c; m.host.summoned[3 .. 6])
        m.raise(SummonedDied(c, hero));
    m.run(100);
    assert(m.host.has("summon 12940") && m.host.has("move 16"));
    m.walkTo(16);
    m.raise(SummonedDied(m.host.summoned[6], hero));
    m.run(20_000);
    assert(m.host.has("event 6641") && m.host.has("text 8565"));
    m.run(6000);
    assert(m.host.has("despawn") && !m.host.has("fail 6641"));

    // Nobody lights the brazier: he gives up.
    auto late = Driven!self("npc_muglash", 12_717, 30);
    late.raise(QuestAccepted(hero, Muglash.questVorsha));
    late.walkTo(14);
    late.run(305_000);
    assert(late.host.has("text 8409") && late.host.has("fail 6641"));

    // The brazier tells him.
    auto brazier = new RecordingObject(Muglash.nagaBrazier);
    brazier.nearby[12_717] = creatureRef(12_717);
    assert(!use!self("go_naga_brazier", brazier), "it is used as usual too");
    assert(brazier.has("signal 12717 1") && brazier.has("flags+ 16"));

    // Feero: the assassins' end said when the last of them falls.
    auto f = Driven!self("npc_feero_ironhand", 4484, 33);
    f.raise(QuestAccepted(hero, FeeroIronhand.questSuppliesToAuberdine));
    f.walkTo(14);
    assert(f.host.summons == 4 && f.host.has("say -1000772"));
    foreach (i, c; f.host.summoned)
    {
        assert(!f.host.has("say -1000773"));
        f.raise(SummonedDied(c, hero));
    }
    assert(f.host.has("say -1000773"));
    f.walkTo(30);
    assert(f.host.has("event 976"));

    // Ruul: ambushed at 14 and 31, freed at 32.
    auto r = Driven!self("npc_ruul_snowhoof", 12_818, 36);
    r.raise(QuestAccepted(hero, RuulSnowhoof.questFreedomToRuul));
    r.walkTo(35);
    assert(r.host.summons == 6 && r.host.has("event 6482") && r.host.has("say -1010022") && r.host.has("despawn"));
}
