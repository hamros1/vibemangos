/**
 * Winterspring: Ranshalla, who leads the player through the Owl Wing Thicket lighting the fires of
 * Elune to the altar, where the priestesses of Elune bind the wildkin's guardian ("Guardians of the
 * Altar", 4901); and Artorius the Amiable, who is Artorius the Doombringer, for a hunter on "Stave of
 * the Ancients" (7636) to fight alone.
 */
module dmangos.scripts.winterspring;

import dmangos.script;

/**
 * Ranshalla: at each of the caverns' fires she waits, chanting, until the player lights it; at the
 * altar the same; then the priestesses of Elune come, and with the Voice of Elune bind the guardian.
 * Done, she kneels at the altar (the quest's event).
 */
@creature("npc_ranshalla")
struct Ranshalla
{
    enum uint questGuardiansAltar = 4901, signalLit = 1;
    enum : uint { spellLightTorch = 18953, spellRanshallaDespawn = 18954, spellBindWildkin = 18994 }
    enum : uint { priestessElune = 12116, voiceElune = 12152, guardianElune = 12140, eluneAltar = 177404, eluneFire = 177417 }
    enum : int
    {
        sayQuestStart = -1000739, sayEnterOwlThicket = -1000707, sayReachTorch1 = -1000708, sayAfterTorch1 = -1000711,
        sayReachAltar1 = -1000713, sayReachAltar2 = -1000714, sayAltar1 = -1000715, sayAltar2 = -1000716,
        sayPriestess3 = -1000717, sayPriestess4 = -1000718, sayAltar5 = -1000719, sayAltar6 = -1000720,
        sayPriestess7 = -1000721, sayPriestess8 = -1000722, sayPriestess9 = -1000723, sayPriestess10 = -1000724,
        sayPriestess11 = -1000725, sayPriestess12 = -1000726, sayPriestess13 = -1000727, sayPriestess14 = -1000728,
        sayVoice15 = -1000729, sayPriestess16 = -1000730, sayPriestess17 = -1000731, sayPriestess18 = -1000732,
        sayPriestess19 = -1000733, sayPriestess20 = -1000734, sayPriestess21 = -1000735, sayQuestEnd1 = -1000736,
        sayQuestEnd2 = -1000737, emoteChantSpell = -1000738,
    }

    /// Who speaks a line of the scene.
    enum Speaker : ubyte { none, ranshalla, rightPriestess, leftPriestess, voice }
    /// What happens with a line of the scene.
    enum Act : ubyte
    {
        none, channelAltar, walkOn, firstPriestessCloser, guardianAndVoice, secondPriestessCloser, guardianLeaves,
        firstPriestessLeaves, secondPriestessLeaves, turnToPlayer, kneel,
    }
    /// A line of the scene: said, done, and the next after `delayMs` (0: the scene waits).
    static struct Line
    {
        int text;
        Speaker speaker;
        Act act;
        uint delayMs;
    }

    private static immutable Line[] scene = [
        Line(sayReachAltar1, Speaker.ranshalla, Act.none, 2000),
        Line(sayReachAltar2, Speaker.ranshalla, Act.none, 3000),
        Line(0, Speaker.none, Act.channelAltar, 0),                 // 2: until the altar is lit
        Line(sayPriestess3, Speaker.leftPriestess, Act.none, 1000), // 3: the priestesses are here
        Line(sayPriestess4, Speaker.rightPriestess, Act.none, 4000),
        Line(sayAltar5, Speaker.ranshalla, Act.none, 4000),
        Line(sayAltar6, Speaker.ranshalla, Act.walkOn, 4000),
        Line(sayPriestess7, Speaker.leftPriestess, Act.none, 4000),
        Line(sayPriestess8, Speaker.leftPriestess, Act.none, 5000),
        Line(0, Speaker.none, Act.none, 5000),                      // the gem shows
        Line(sayPriestess9, Speaker.rightPriestess, Act.firstPriestessCloser, 4000),
        Line(0, Speaker.none, Act.none, 3000),
        Line(sayPriestess10, Speaker.rightPriestess, Act.none, 5000),
        Line(sayPriestess11, Speaker.rightPriestess, Act.none, 4000),
        Line(sayPriestess12, Speaker.rightPriestess, Act.none, 5000),
        Line(sayPriestess13, Speaker.rightPriestess, Act.guardianAndVoice, 8000),
        Line(0, Speaker.none, Act.none, 12_000),
        Line(sayVoice15, Speaker.voice, Act.secondPriestessCloser, 5000),
        Line(0, Speaker.none, Act.none, 3000),
        Line(sayPriestess16, Speaker.leftPriestess, Act.none, 4000),
        Line(sayPriestess17, Speaker.leftPriestess, Act.none, 6000),
        Line(sayPriestess18, Speaker.rightPriestess, Act.none, 5000),
        Line(sayPriestess19, Speaker.rightPriestess, Act.guardianLeaves, 3000),
        Line(0, Speaker.none, Act.none, 2000),
        Line(sayPriestess20, Speaker.rightPriestess, Act.firstPriestessLeaves, 4000),
        Line(sayPriestess21, Speaker.leftPriestess, Act.secondPriestessLeaves, 10_000),
        Line(0, Speaker.none, Act.none, 6000),
        Line(0, Speaker.none, Act.turnToPlayer, 2000),
        Line(sayQuestEnd2, Speaker.ranshalla, Act.kneel, 0),
    ];
    enum size_t priestessesHere = 3;

    private static immutable Location[8] thicket = [
        Location(5515.98f, -4903.43f, 846.30f, 4.58f), // right priestess comes
        Location(5501.94f, -4920.20f, 848.69f, 6.15f), // left priestess comes
        Location(5497.35f, -4906.49f, 850.83f, 2.76f), // the guardian comes
        Location(5518.38f, -4913.47f, 845.57f),        // the right priestess goes to
        Location(5510.36f, -4921.17f, 846.33f),        // the left priestess goes to
        Location(5511.31f, -4913.82f, 847.17f),        // the guardian goes to
        Location(5518.51f, -4917.56f, 845.23f),        // the right priestess, closer
        Location(5514.40f, -4921.16f, 845.49f),        // the left priestess, closer
    ];

    enum Step : ubyte { line, walkOn }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    size_t next;                          // the scene's next line
    EntityRef rightPriestess, leftPriestess, guardian, voice, altar;
    bool waitingForAltar;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questGuardiansAltar || escort.active)
            return;
        me.say(sayQuestStart);
        me.setFaction(EscortFaction.allianceNeutralPassive);
        next = 0;
        waitingForAltar = false;
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 3:
            me.say(sayEnterOwlThicket);
            break;
        case 10, 15, 20, 25, 36: // the caverns' fires
            channel(me, false);
            break;
        case 39:
            escort.paused = true;
            next = 0;
            steps.after(Step.line, 1.msecs);
            break;
        case 41:
            if (altar)
                me.face(altar);
            break;
        case 42:
            escort.paused = true;
            rightPriestess = me.summon(priestessElune, thicket[0]);
            me.moveCreature(rightPriestess, thicket[3], 0);
            leftPriestess = me.summon(priestessElune, thicket[1]);
            me.moveCreature(leftPriestess, thicket[4], 0);
            me.say(sayAltar2);
            next = priestessesHere;
            steps.after(Step.line, 4.seconds); // as they arrive
            break;
        case 44:
            escort.paused = true;
            if (altar)
                me.face(altar);
            break;
        default:
            break;
        }
    }

    /// The fire (or the altar) lit: she goes on.
    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != signalLit || !escort.active || !escort.paused)
            return;
        if (e.value)
        {
            if (!waitingForAltar)
                return;
            waitingForAltar = false;
            me.say(sayAltar1);
        }
        else
            me.say(sayAfterTorch1 - cast(int) me.random(2));
        steps.after(Step.walkOn, 2.seconds);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        // Waited too long at a fire: she gives up.
        if (e.spell == spellRanshallaDespawn)
        {
            escort.fail(me);
            me.despawn(1);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.walkOn:
            me.removeAura(me.self, spellLightTorch);
            escort.paused = false;
            break;
        case Step.line:
            if (next >= scene.length)
                return;
            const line = scene[next++];
            if (line.text)
                speak(me, line);
            act(me, line.act);
            if (line.delayMs)
                steps.after(Step.line, line.delayMs.msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
        steps.clear();
    }

    private void speak(ref CreatureContext me, const Line line)
    {
        final switch (line.speaker)
        {
        case Speaker.none: break;
        case Speaker.ranshalla: me.say(line.text); break;
        case Speaker.rightPriestess: me.sayOther(rightPriestess, line.text); break;
        case Speaker.leftPriestess: me.sayOther(leftPriestess, line.text); break;
        case Speaker.voice: me.sayOther(voice, line.text); break;
        }
    }

    private void act(ref CreatureContext me, Act what)
    {
        final switch (what)
        {
        case Act.none:
            break;
        case Act.channelAltar:
            channel(me, true);
            break;
        case Act.walkOn:
            escort.paused = false;
            break;
        case Act.firstPriestessCloser:
            me.moveCreature(rightPriestess, thicket[6], 0);
            break;
        case Act.guardianAndVoice:
            guardian = me.summon(guardianElune, thicket[2]);
            me.moveCreature(guardian, thicket[5], 0);
            Location at;
            if (altar && me.locationOf(altar, at))
                voice = me.summon(voiceElune, at, 30_000);
            break;
        case Act.secondPriestessCloser:
            me.sayOther(leftPriestess, sayPriestess14);
            me.moveCreature(leftPriestess, thicket[7], 0);
            me.castAs(guardian, spellBindWildkin, guardian);
            break;
        case Act.guardianLeaves:
            me.moveCreature(guardian, thicket[2], 0);
            me.despawn(guardian, 4000);
            break;
        case Act.firstPriestessLeaves:
            me.moveCreature(rightPriestess, thicket[0], 0);
            me.despawn(rightPriestess, 4000);
            break;
        case Act.secondPriestessLeaves:
            me.moveCreature(leftPriestess, thicket[1], 0);
            me.despawn(leftPriestess, 4000);
            break;
        case Act.turnToPlayer:
            me.face(escort.player);
            me.say(sayQuestEnd1, escort.player);
            break;
        case Act.kneel:
            if (altar)
                me.face(altar);
            me.standState(StandState.kneel);
            me.groupQuestEvent(escort.player, questGuardiansAltar);
            escort.active = false;
            me.despawn(60_000);
            break;
        }
    }

    /// At a fire (the altar): it may be lit now, and she chants until it is.
    private void channel(ref CreatureContext me, bool atAltar)
    {
        if (atAltar)
        {
            altar = me.objectNearby(eluneAltar, 10);
            if (altar)
            {
                me.objectUsable(altar, true);
                me.face(altar);
            }
            waitingForAltar = true;
        }
        else if (const fire = me.objectNearby(eluneFire, 10))
            me.objectUsable(fire, true);
        me.say(sayReachTorch1 - cast(int) me.random(3));
        me.say(emoteChantSpell);
        me.castSelf(spellLightTorch);
        escort.paused = true;
    }
}

/// A fire of Elune, or the altar: lit by the player, it tells Ranshalla.
@gameObject("go_elune_fire")
struct EluneFire
{
    void on(ref GameObjectContext it, const ref ObjectUsed e)
    {
        if (const ranshalla = it.creatureNearby(10_300, 10))
            it.signal(ranshalla, Ranshalla.signalLit, it.self.entry == Ranshalla.eluneAltar);
    }
}

/**
 * Artorius the Amiable and, after the question, Artorius the Doombringer: Demonic Frenzy and Demonic
 * Doom; a Serpent Sting brings him Stinging Trauma. One hunter fights him: anyone else joining in,
 * he goes and The Cleaner comes. Unfought for twenty minutes, he goes.
 */
@creature("npc_artorius")
struct Artorius
{
    enum uint questStaveOfTheAncients = 7636, doombringer = 14535, theCleaner = 14503, showFace = 1, emoteRoar = 15;
    enum : uint { spellDemonicFrenzy = 23257, spellDemonicDoom = 23298, spellStingingTrauma = 23299,
        spellSerpentSting8 = 13555, spellSerpentSting9 = 25295 }
    enum int emotePoison = -1001251;

    enum Step : ubyte { roar, transform, frenzy, doom, leave }
    Schedule!Step steps;
    EntityRef hunter;
    bool demon;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (demon || me.questStatus(e.player, questStaveOfTheAncients) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Show me your real face, demon.", showFace);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != showFace || demon)
            return;
        me.closeGossip(e.player);
        hunter = e.player;
        me.npcFlags(0);
        me.follow(EntityRef.init);
        steps.after(Step.roar, 5.seconds);
        steps.after(Step.transform, 10.seconds);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!demon)
            return;
        if (e.enemy.isPlayer && hunter && e.enemy != hunter)
            return leave(me, e.enemy);
        if (e.enemy.isPlayer)
            hunter = e.enemy;
        steps.after(Step.frenzy, (5 + me.random(4)).seconds);
        steps.after(Step.doom, 7500.msecs);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (demon && e.attacker.isPlayer && hunter && e.attacker != hunter)
            leave(me, e.attacker);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (demon && (e.spell == spellSerpentSting8 || e.spell == spellSerpentSting9)
            && me.castSelf(spellStingingTrauma, true) == ActionResult.ok)
            me.say(emotePoison);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.roar:
            me.emote(emoteRoar);
            break;
        case Step.transform:
            demon = true;
            me.changeEntry(doombringer);
            steps.after(Step.leave, 20 * 60.seconds);
            break;
        case Step.frenzy:
            if (me.inCombat)
                steps.after(Step.frenzy, me.castSelf(spellDemonicFrenzy) == ActionResult.ok
                    ? (15 + me.random(6)).seconds : 1.seconds);
            break;
        case Step.doom:
            if (!me.inCombat)
                return;
            if (me.victim && me.distanceTo(me.victim) <= 25)
                me.castSpell(spellDemonicDoom);
            steps.after(Step.doom, 7500.msecs);
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 10.seconds);
            me.despawn(1);
            break;
        }
    }

    private void leave(ref CreatureContext me, EntityRef intruder)
    {
        const cleaner = me.summon(theCleaner, Location.init, 20 * 60_000);
        me.attack(cleaner, intruder);
        if (hunter)
            me.attack(cleaner, hunter);
        steps.clear();
        me.despawn(1);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.winterspring;

    auto r = Driven!self("npc_ranshalla", 10_300, 44);
    const fire = EntityRef(0xF110_0000_0000_0010), altar = EntityRef(0xF110_0000_0000_0011);
    r.host.objects[Ranshalla.eluneFire] = fire;
    r.host.objects[Ranshalla.eluneAltar] = altar;
    r.raise(QuestAccepted(hero, Ranshalla.questGuardiansAltar));
    r.walkTo(9);
    assert(r.host.has("usable") && r.host.has("cast 18953") && r.host.has("say -1000738"));
    r.run(1000);
    assert(!r.host.has("move 10"), "she waits for the fire");
    r.raise(Signal(fire, Ranshalla.signalLit, 0));
    r.run(2100);
    assert(r.host.has("move 10"));
    foreach (stop; [14, 19, 24, 35])
    {
        r.walkTo(stop);
        r.raise(Signal(fire, Ranshalla.signalLit, 0));
        r.run(2100);
    }
    r.walkTo(38);
    r.run(6000);
    assert(r.host.has("say -1000714") && !r.host.has("move 39"), "at the altar");
    r.raise(Signal(altar, Ranshalla.signalLit, 1));
    r.run(2100);
    r.walkTo(41);
    assert(r.host.summons == 2 && r.host.has("say -1000716"));
    r.run(20_000);
    assert(r.host.has("say -1000720") && r.host.has("move 42"), "on, as the priestesses talk");
    r.walkTo(43);
    r.run(120_000);
    assert(r.host.has("say as 12152 -1000729") && r.host.has("event 4901") && r.host.has("stand 8"));

    // The fire tells her, and is used as usual.
    auto f = new RecordingObject(Ranshalla.eluneFire);
    f.nearby[10_300] = creatureRef(10_300);
    assert(!use!self("go_elune_fire", f) && f.has("signal 10300 1"));

    auto a = Driven!self("npc_artorius", 14_531);
    a.host.quests[Artorius.questStaveOfTheAncients] = QuestProgress.incomplete;
    assert(a.raise(GossipHello(hero)));
    a.raise(GossipSelect(hero, 0, 0, Artorius.showFace));
    a.run(10_000);
    assert(a.host.has("emote 15") && a.host.has("entry 14535"));
}
