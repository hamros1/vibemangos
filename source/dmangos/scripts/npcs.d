/**
 * Special creatures found all over the world (ScriptDevAI's world scripts): the Triage doctors and
 * their patients, the priests' wounded of the starting areas, the paladins' redemption targets, Cluck
 * the chicken, The Cleaner, Stormwind's guards saluting Reginald Windsor, and quest spells' dummies.
 */
module dmangos.scripts.npcs;

import dmangos.script;

/// Unit flags the scripts here use.
private enum uint uninteractible = 0x0200_0000;
/// `NPC_FLAG_QUESTGIVER`.
private enum uint npcFlagQuestGiver = 2;

/// `Signal`s between a Triage doctor and his patients: who the doctor is and which bunk (`value`);
/// a patient saved by the player (`value`: the bunk).
enum TriageSignal : uint { yourDoctor = 1, saved }

/// The Triage quests: the Alliance's Gustaf VanHowzen and the Horde's Gregory Victor.
enum uint questTriageAlliance = 6624, questTriageHorde = 6622, doctorAlliance = 12939, doctorHorde = 12920;

/**
 * A Triage doctor: taken on the quest, wounded soldiers are brought in to his bunks, two or three at a
 * time, and the player bandages them before they die. Fifteen saved, the quest's event happens; more
 * than five dead, it fails.
 */
@creature("npc_doctor")
struct TriageDoctor
{
    enum uint saveCount = 15, deathCount = 5, mostPatients = 21;

    private static immutable Location[7] allianceBunks = [Location(-3757.38f, -4533.05f, 14.16f, 3.62f),
        Location(-3754.36f, -4539.13f, 14.16f, 5.13f), Location(-3749.54f, -4540.25f, 14.28f, 3.34f),
        Location(-3742.10f, -4536.85f, 14.28f, 3.64f), Location(-3755.89f, -4529.07f, 14.05f, 0.57f),
        Location(-3749.51f, -4527.08f, 14.07f, 5.26f), Location(-3746.37f, -4525.35f, 14.16f, 5.22f)];
    private static immutable Location[6] hordeBunks = [Location(-1013.75f, -3492.59f, 62.62f, 4.34f),
        Location(-1017.72f, -3490.92f, 62.62f, 4.34f), Location(-1015.77f, -3497.15f, 62.82f, 4.34f),
        Location(-1019.51f, -3495.49f, 62.82f, 4.34f), Location(-1017.25f, -3500.85f, 62.98f, 4.34f),
        Location(-1020.95f, -3499.21f, 62.98f, 4.34f)];
    private static immutable uint[3] allianceSoldiers = [12938, 12936, 12937], hordeSoldiers = [12923, 12924, 12925];

    enum Step : ubyte { bringIn }
    Schedule!Step steps;
    EntityRef player;
    EntityRef[7] inBunk;  /// the patient in each bunk
    ubyte brought, saved, died;
    bool active;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if ((e.quest != questTriageAlliance && e.quest != questTriageHorde) || active)
            return;
        reset(me);
        active = true;
        player = e.player;
        me.unitFlags(uninteractible);
        steps.after(Step.bringIn, 10.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        // Stop bringing in patients at the cap. The patients still in bunks
        // must be allowed to finish so the final save or death can settle the quest.
        if (!active || brought >= mostPatients)
            return;
        uint lying;
        foreach (p; inBunk)
            if (p)
                ++lying;
        const wanted = lying == 0 ? 2 + me.random(2) : lying == 1 ? 1 + me.random(2) : 0;
        uint came;
        foreach (_; 0 .. wanted)
        {
            if (brought + came >= mostPatients)
                break;
            const bunk = freeBunk(me);
            if (bunk == size_t.max)
                break;
            const alliance = me.self.entry == doctorAlliance;
            const entry = alliance ? allianceSoldiers[me.random(3)] : hordeSoldiers[me.random(3)];
            const patient = me.summon(entry, alliance ? allianceBunks[bunk] : hordeBunks[bunk]);
            if (!patient)
                continue;
            inBunk[bunk] = patient;
            me.signal(patient, TriageSignal.yourDoctor, cast(int) bunk);
            ++came;
        }
        brought += came;
        steps.after(Step.bringIn, came == 0 ? (2000 + me.random(1001)).msecs
            : came == 1 ? (8000 + me.random(1001)).msecs : 10.seconds);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (!active || e.id != TriageSignal.saved || e.value < 0 || e.value >= inBunk.length || inBunk[e.value] != e.from)
            return;
        inBunk[e.value] = EntityRef.init;
        if (++saved < saveCount)
            return;
        foreach (p; inBunk)
            if (p)
                me.despawn(p, 0);
        me.questEvent(player, me.self.entry == doctorAlliance ? questTriageAlliance : questTriageHorde);
        reset(me);
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        if (!active)
            return;
        foreach (ref p; inBunk)
            if (p == e.summoned)
            {
                p = EntityRef.init;
                if (++died > deathCount)
                {
                    me.failQuest(player, me.self.entry == doctorAlliance ? questTriageAlliance : questTriageHorde);
                    reset(me);
                }
            }
    }

    private size_t freeBunk(ref CreatureContext me)
    {
        const bunks = me.self.entry == doctorAlliance ? allianceBunks.length : hordeBunks.length;
        size_t[7] free;
        size_t count;
        foreach (i; 0 .. bunks)
            if (!inBunk[i])
                free[count++] = i;
        return count ? free[me.random(cast(uint) count)] : size_t.max;
    }

    private void reset(ref CreatureContext me)
    {
        active = false;
        player = EntityRef.init;
        inBunk[] = EntityRef.init;
        brought = saved = died = 0;
        steps.clear();
        me.unitFlags(uninteractible, false);
    }
}

/**
 * A wounded soldier of Triage: lying in its bunk it bleeds to death (the worse its wounds, the sooner)
 * unless the player on the quest bandages it with Triage; then it thanks the player, gets up and runs
 * out.
 */
@creature("npc_injured_patient")
struct InjuredPatient
{
    enum uint spellTriage = 20804;
    enum : int { sayDoc1 = -1000201 }
    private enum Location allianceExit = Location(-3742.96f, -4531.52f, 11.91f),
        hordeExit = Location(-1016.44f, -3508.48f, 62.96f);

    enum Step : ubyte { bleedOut }
    Schedule!Step steps;
    EntityRef doctor;
    int bunk = -1;
    bool saved;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.dead);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != TriageSignal.yourDoctor)
            return;
        doctor = e.from;
        bunk = e.value;
        // Its health runs out: injured, badly injured, critically injured.
        switch (me.self.entry)
        {
        case 12923, 12938:
            steps.after(Step.bleedOut, 26.seconds);
            break;
        case 12924, 12936:
            steps.after(Step.bleedOut, 18.seconds);
            break;
        default:
            steps.after(Step.bleedOut, 12.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellTriage || !e.caster.isPlayer || saved)
            return;
        if (me.questStatus(e.caster, questTriageAlliance) == QuestProgress.incomplete
                || me.questStatus(e.caster, questTriageHorde) == QuestProgress.incomplete)
            me.signal(doctor, TriageSignal.saved, bunk);
        saved = true;
        steps.clear();
        me.unitFlags(uninteractible);
        me.standState(StandState.stand);
        me.say(sayDoc1 - cast(int) me.random(3));
        const alliance = me.self.entry >= 12936;
        me.moveTo(alliance ? allianceExit : hordeExit, 0, true);
        me.despawn(8000);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!saved)
            me.die();
    }
}

/**
 * The wounded of the priests' starting quests (Garments of the Moon, Light, Spirit, Darkness): healed
 * with Lesser Heal and then given Power Word: Fortitude by the priest on its quest, it thanks them,
 * counts for the quest, and a moment later says goodbye and runs off.
 */
@creature("npc_garments_of_quests")
struct GarmentsOfQuests
{
    enum uint spellLesserHeal2 = 2052, spellFortitude1 = 1243;
    enum int sayHealed = -1000231;

    private static struct Wounded
    {
        uint entry, quest;
        int thanks, goodbye;
    }
    private static immutable Wounded[5] wounded = [
        Wounded(12429, 5621, -1000262, -1000263), // Sentinel Shaya: Garments of the Moon
        Wounded(12423, 5624, -1000256, -1000257), // Guard Roberts: Garments of the Light
        Wounded(12427, 5625, -1000260, -1000261), // Mountaineer Dolf: Garments of the Light
        Wounded(12430, 5648, -1000258, -1000259), // Grunt Kor'ja: Garments of Spirit
        Wounded(12428, 5650, -1000232, -1000233), // Deathguard Kel: Garments of Darkness
    ];

    enum Step : ubyte { leave }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    EntityRef player;
    bool healed, thanked;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.standState(StandState.kneel);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if ((e.spell != spellLesserHeal2 && e.spell != spellFortitude1) || me.inCombat || thanked || !e.caster.isPlayer)
            return;
        const w = which(me.self.entry);
        if (w is null || me.questStatus(e.caster, w.quest) != QuestProgress.incomplete)
            return;
        if (!healed && e.spell == spellLesserHeal2)
        {
            healed = true;
            player = e.caster;
            me.standState(StandState.stand);
            me.say(sayHealed, e.caster);
        }
        else if (healed && e.spell == spellFortitude1)
        {
            thanked = true;
            me.say(w.thanks, e.caster);
            me.killCredit(e.caster, me.self.entry);
            steps.after(Step.leave, 5.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            return cast(void) steps.after(step, 5.seconds);
        if (const w = which(me.self.entry))
            me.say(w.goodbye, player);
        escort.start(me, player, 0, true);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        escort.reached(me, e);
    }

    private static immutable(Wounded)* which(uint entry)
    {
        foreach (ref w; wounded)
            if (w.entry == entry)
                return &w;
        return null;
    }
}

/**
 * Henze and Narm Faulk, lying dead for the paladins' Symbol of Life: brought back by it, they stand,
 * turn to the paladin, thank them and give the quest's reward; two minutes on they lie down again.
 */
@creature("npc_redemption_target")
struct RedemptionTarget
{
    enum uint spellSymbolOfLife = 8593, spellQuestSelfHealing = 25155, sayHealed = 2283, emoteKneel = 16;

    enum Step : ubyte { face, thank, kneel, lieDown }
    Schedule!Step steps;
    EntityRef player;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        lieDown(me);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellSymbolOfLife || steps.pending(Step.lieDown))
            return;
        player = e.caster;
        me.castSelf(spellQuestSelfHealing);
        me.standState(StandState.stand);
        steps.after(Step.face, 3.seconds);
        steps.after(Step.thank, 4.seconds);
        steps.after(Step.kneel, 7.seconds);
        steps.after(Step.lieDown, 120.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.face:
            me.face(player);
            break;
        case Step.thank:
            me.npcFlags(npcFlagQuestGiver);
            me.sayText(sayHealed, player);
            break;
        case Step.kneel:
            me.emote(emoteKneel);
            break;
        case Step.lieDown:
            lieDown(me);
            break;
        }
    }

    private void lieDown(ref CreatureContext me)
    {
        me.npcFlags(0);
        me.standState(StandState.dead);
    }
}

/**
 * Cluck the chicken: clucked at (one time in fifty), or cheered at by a player who has done "CLUCK!"
 * (3861), it turns friendly and gives the quest; twenty seconds later it is a chicken again.
 */
@creature("npc_chicken_cluck")
struct ChickenCluck
{
    enum uint questCluck = 3861, factionFriendly = 35, textEmoteChicken = 22, textEmoteCheer = 21;
    enum : int { emoteCluck1 = -1000204, emoteCluck2 = -1000205 }

    enum Step : ubyte { chickenAgain }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        chicken(me);
    }

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        if (e.textEmote == textEmoteChicken && me.random(50) == 0)
            befriend(me, emoteCluck1);
        else if (e.textEmote == textEmoteCheer && me.questStatus(e.player, questCluck) == QuestProgress.complete)
            befriend(me, emoteCluck2);
    }

    void on(ref CreatureContext me, Step step)
    {
        chicken(me);
    }

    private void befriend(ref CreatureContext me, int text)
    {
        me.npcFlags(npcFlagQuestGiver);
        me.setFaction(factionFriendly);
        me.say(text);
        steps.after(Step.chickenAgain, 20.seconds);
    }

    private void chicken(ref CreatureContext me)
    {
        me.setFaction(0);
        me.npcFlags(0);
    }
}

/**
 * The Cleaner: called when someone meddles in a class quest's fight, it is immune to everything,
 * kills whoever it was set on, and goes once nobody is left to fight.
 */
@creature("npc_the_cleaner")
struct TheCleaner
{
    enum uint spellImmunity = 29230;
    enum int sayAggro = -1001253;

    enum Step : ubyte { check }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spellImmunity, true);
        steps.after(Step.check, 3.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        me.despawn();
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            steps.after(Step.check, 3.seconds);
        else
            me.despawn();
    }
}

/**
 * A Stormwind guard: Reginald Windsor's inspiration passing by, it salutes him (at most once in two
 * minutes). Like every guard, killed by a player it puts its zone under attack, and
 * it answers the emotes of the Alliance.
 */
@creature("guard_stormwind")
struct GuardStormwind
{
    enum uint spellWindsorInspirationEffect = 20275;
    enum int saySalute = -1000842;
    enum uint factionStormwind = 72;

    void on(ref CreatureContext me, const ref Died e)
    {
        import dmangos.scripts.guards : guardDied;

        guardDied(me, e);
    }

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        import dmangos.scripts.guards : replyToEmote;

        if (me.standingOf(e.player, factionStormwind) >= Standing.neutral) // one of the Alliance
            replyToEmote(me, e.textEmote);
    }

    enum Step : ubyte { saluteAgain }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellWindsorInspirationEffect || steps.pending(Step.saluteAgain))
            return;
        me.say(saySalute - cast(int) me.random(7));
        steps.after(Step.saluteAgain, 120.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
    }
}

/**
 * Creatures that quest spells are cast on, or that only the dead see: Franclorn Forgewright and
 * Gaeriyan wear a shroud of death; a Deeprun Rat charmed by Melodious Rapture becomes an Enthralled
 * Deeprun Rat and counts for the player's quest.
 */
@creature("spell_dummy_npc")
struct SpellDummyNpc
{
    enum uint franclornForgewright = 8888, gaeriyan = 9299, deeprunRat = 13016, enthralledDeeprunRat = 13017;
    enum uint spellShroudOfDeath = 10848, spellSpiritParticles = 17327, spellMelodiousRapture = 21050,
        spellMelodiousRaptureVisual = 21051;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        const entry = me.self.entry;
        if (entry == franclornForgewright || entry == gaeriyan)
        {
            me.castSelf(spellShroudOfDeath, true);
            me.castSelf(spellSpiritParticles, true);
        }
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellMelodiousRapture || !e.caster.isPlayer || me.self.entry != deeprunRat)
            return;
        if (!me.changeEntry(enthralledDeeprunRat))
            return;
        me.castSelf(spellMelodiousRaptureVisual, true);
        me.killCredit(e.caster, enthralledDeeprunRat);
    }
}



/**
 * A Guardian of Blizzard, keeping players out of where they may not go: whoever it fights it touches
 * with death, at its every swing.
 */
@creature("npc_guardian")
struct GuardianOfBlizzard
{
    enum uint spellDeathtouch = 5, sayAggro = 2077;

    enum Step : ubyte { touch }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.sayText(sayAggro, e.enemy);
        me.melee(false); // its swing is Deathtouch
        steps.every(Step.touch, 0.msecs, 2.seconds);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        me.melee(true);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return steps.clear();
        if (const victim = me.victim)
            me.castSpell(spellDeathtouch, victim, true);
    }
}

/// The Advanced Target Dummy an engineer sets up: it draws the attacks for fifteen seconds and blows up.
@creature("npc_advanced_target_dummy")
struct AdvancedTargetDummy
{
    enum uint spellPassive = 4048, spellSpawnEffect = 4507, spellSuicide = 7;

    enum Step : ubyte { die }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.castSelf(spellPassive, true); // what its EventAI casts
        me.castSelf(spellSpawnEffect);
        steps.after(Step.die, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.castSelf(spellSuicide, true);
    }
}

/// A Void Zone (Naxxramas's Lady Blaumeux): passive; it keeps its Consumption up, looked at every 2.5 seconds.
@creature("npc_aoe_damage_trigger")
struct AoeDamageTrigger
{
    enum uint spellConsumption = 28874;

    enum Step : ubyte { consume }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        steps.every(Step.consume, 2500.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.hasAura(me.self, spellConsumption))
            me.castSelf(spellConsumption, true);
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.npcs;

    // Triage: patients brought in, saved and lost.
    auto doc = Driven!zone.make("npc_doctor");
    doc.host.me = creatureRef(doctorAlliance);
    doc.raise(QuestAccepted(doc.host.player, questTriageAlliance));
    doc.tick(10_000);
    assert(doc.host.summons == 2 && doc.host.did("signal 12938 1"));
    // Bunks are chosen at random among the free ones; the test host's random gives the first.
    doc.raise(Signal(creatureRef(12938, 1), TriageSignal.saved, 0));
    doc.raise(Signal(creatureRef(12938, 2), TriageSignal.saved, 1));
    foreach (_; 0 .. 6)
    {
        doc.tick(10_000);
        doc.raise(SummonedDied(creatureRef(12938, doc.host.summons)));
    }
    assert(doc.host.did("fail 6624") && !doc.host.did("event 6624"));

    // The final patient already in a bunk can still finish the quest once spawning stops.
    auto lastHost = new imported!"dmangos.scripts.testhost".TestCreature;
    lastHost.me = creatureRef(doctorAlliance);
    auto lastContext = CreatureContext(lastHost);
    auto lastDoctor = TriageDoctor(active: true, player: lastHost.player, brought: TriageDoctor.mostPatients,
        saved: TriageDoctor.saveCount - 1, died: TriageDoctor.deathCount);
    const lastPatient = creatureRef(12938, 20);
    lastDoctor.inBunk[0] = lastPatient;
    lastDoctor.on(lastContext, TriageDoctor.Step.bringIn);
    assert(lastDoctor.active && lastHost.summons == 0);
    const savedLast = Signal(lastPatient, TriageSignal.saved, 0);
    lastDoctor.on(lastContext, savedLast);
    assert(lastHost.did("event 6624") && !lastDoctor.active);

    auto patient = Driven!zone.make("npc_injured_patient");
    patient.host.me = creatureRef(12938);
    patient.raise(Spawned());
    patient.raise(Signal(creatureRef(doctorAlliance), TriageSignal.yourDoctor, 3));
    patient.raise(SpellHit(patient.host.player, 20804));
    assert(patient.host.did("signal 12939 2") && patient.host.did("stand 0") && patient.host.did("despawn"));
    patient.tick(30_000);
    assert(!patient.host.did("die"), "saved: it does not bleed out");

    auto shaya = Driven!zone.make("npc_garments_of_quests");
    shaya.host.me = creatureRef(12429);
    shaya.host.pathLength = 2;
    shaya.raise(SpellHit(shaya.host.player, 2052));
    shaya.raise(SpellHit(shaya.host.player, 1243));
    assert(shaya.host.did("say -1000262") && shaya.host.did("credit 12429"));
    shaya.tick(5000);
    assert(shaya.host.did("say -1000263") && shaya.host.lastPoint == 0);

    auto cluck = Driven!zone.make("npc_chicken_cluck");
    cluck.host.progress = QuestProgress.complete;
    cluck.raise(EmoteReceived(cluck.host.player, 21));
    assert(cluck.host.faction == 35 && cluck.host.did("npc flags 2"));
    cluck.tick(20_000);
    assert(cluck.host.faction == 0);

    auto henze = Driven!zone.make("npc_redemption_target");
    henze.raise(Spawned());
    henze.raise(SpellHit(henze.host.player, 8593));
    henze.tick(7000);
    assert(henze.host.did("text 2283") && henze.host.did("emote 16"));
    henze.tick(120_000);
    assert(henze.host.log[$ - 1] == "stand 7");
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.npcs;

    auto g = Driven!self("npc_guardian", 5764);
    g.host.fighting = true;
    g.raise(EnteredCombat(hero));
    g.run(100);
    assert(g.host.has("text 2077") && g.host.has("cast 5"));

    auto dummy = Driven!self("npc_advanced_target_dummy", 2674);
    dummy.raise(Spawned());
    assert(dummy.host.has("passive") && dummy.host.has("cast 4048"));
    dummy.run(15_000);
    assert(dummy.host.has("cast 7"));

    auto zone = Driven!self("npc_aoe_damage_trigger", 16_697);
    zone.raise(Spawned());
    zone.run(2500);
    assert(zone.host.has("cast 28874"));
}
