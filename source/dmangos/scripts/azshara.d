/**
 * Azshara: the Spitelash naga's abilities (and their sheep's backfire for "Fragmented Magic",
 * 9364); the Felhound Tracker that sniffs out Azsharite for its master on "Azsharite" (3602);
 * Maws; and Azuregos, the blue dragon.
 */
module dmangos.scripts.azshara;

// Open-world round 2: and Loramus Thalipedes, who helps and tells his story (2744, 3141).

import dmangos.script;

/// The Spitelash naga: each kind with its abilities; polymorphed by a player on "Fragmented Magic", the sheep backfires.
@creature("mobs_spitelashes")
struct Spitelash
{
    enum : uint { warrior = 6190, screamer = 6193, serpentGuard = 6194, siren = 6195, myrmidon = 6196 }
    enum uint questFragmentedMagic = 9364, spellPolymorphBackfire = 28406;
    /// Whom an ability is cast at.
    enum Target : ubyte { random, victim, self }
    /// An ability of a kind: its spell, first after `firstMs` in a fight, then every `cooldownMs`.
    static struct Ability
    {
        uint entry, spell;
        Target target;
        uint firstMs, cooldownMs;
    }

    private static immutable Ability[8] abilities = [
        Ability(warrior, 6713, Target.victim, 4000, 10_000),       // Disarm
        Ability(screamer, 3589, Target.self, 7000, 15_000),        // Screech
        Ability(serpentGuard, 12548, Target.victim, 7000, 13_000), // Frost Shock
        Ability(siren, 11640, Target.self, 4000, 7000),            // Renew (on the siren: her friends' health is not known here)
        Ability(siren, 6660, Target.random, 3000, 9000),           // Shoot
        Ability(siren, 12551, Target.random, 7000, 10_000),        // Frost Shot
        Ability(siren, 11831, Target.self, 10_000, 15_000),        // Frost Nova
        Ability(myrmidon, 11976, Target.victim, 3000, 7000),       // Strike
    ];

    enum Step : ubyte { a0, a1, a2, a3, a4, a5, a6, a7, backfire }
    Schedule!(Step, 10) steps;
    bool polymorphed;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        const entry = me.self.entry;
        foreach (i, a; abilities)
            if (a.entry == entry)
                steps.after(cast(Step) i, a.firstMs.msecs);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        polymorphed = false;
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        import std.algorithm.comparison : among;

        if (polymorphed || !e.caster.isPlayer || !e.spell.among(118, 12_824, 12_825, 12_826))
            return;
        if (me.questStatus(e.caster, questFragmentedMagic) != QuestProgress.incomplete)
            return;
        polymorphed = true;
        steps.after(Step.backfire, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (step == Step.backfire)
        {
            me.castSelf(spellPolymorphBackfire, true);
            me.despawn(1);
            return;
        }
        if (!me.inCombat)
            return;
        const a = abilities[step];
        EntityRef target;
        final switch (a.target)
        {
        case Target.self: target = me.self; break;
        case Target.victim: target = me.victim; break;
        case Target.random: target = me.randomTarget(); break;
        }
        const done = target && me.castSpell(a.spell, target) == ActionResult.ok;
        steps.after(step, done ? a.cooldownMs.msecs : 1.seconds);
    }
}

/**
 * The Felhound Tracker: its master on "Azsharite" roars at it, and it runs to the nearest Azsharite
 * crystal it smells, waits there twenty seconds, and comes back.
 */
@creature("npc_felhound_tracker")
struct FelhoundTracker
{
    enum uint questAzsharite = 3602, textEmoteRoar = 75, pointCrystal = 1;
    private static immutable uint[4] crystals = [152_620, 152_621, 152_622, 152_631];

    enum Step : ubyte { back }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        if (e.textEmote != textEmoteRoar || me.questStatus(e.player, questAzsharite) != QuestProgress.incomplete)
            return;
        foreach (entry; crystals)
        {
            Location at;
            const crystal = me.objectNearby(entry, 40);
            if (crystal && me.locationOf(crystal, at))
            {
                steps.cancel(Step.back);
                me.moveTo(Location(at.x + 2, at.y, at.z), pointCrystal, true);
                return;
            }
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == pointCrystal)
            steps.after(Step.back, 20.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (const master = me.owner)
            me.follow(master);
    }
}

/// Maws: Thrash; Frenzy and Rampage, and Dark Water when nearly dead. Two and a half hours on, it goes.
@creature("boss_maws")
struct Maws
{
    enum : uint { spellThrash = 8876, spellFrenzy = 19812, spellDarkWater = 25743, spellRampage = 25744 }
    enum : int { emoteFrenzyKill = -1000001, emoteMawsKill = -1010000 }

    enum Step : ubyte { frenzy, rampage, darkWater, leave }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.castSelf(spellThrash, true);
        steps.after(Step.leave, 150 * 60.seconds);
        me.walkPath(); // Open-world round 2: called up by the Arcanite Buoy, it swims its way (`MoveWaypoint`)
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!me.hasAura(me.self, spellThrash))
            me.castSelf(spellThrash, true);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.frenzy, 25.seconds);
        steps.after(Step.rampage, (20 + me.random(101)).seconds);
        steps.after(Step.darkWater, 15.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        const low = me.healthPercent < 20;
        final switch (step)
        {
        case Step.frenzy:
            if (!me.inCombat)
                return;
            me.castSelf(spellFrenzy);
            me.say(emoteFrenzyKill);
            steps.after(Step.frenzy, (low ? 15 : 25).seconds);
            break;
        case Step.rampage:
            if (!me.inCombat)
                return;
            me.castSpell(spellRampage);
            steps.after(Step.rampage, (low ? 12 : 20 + me.random(101)).seconds);
            break;
        case Step.darkWater:
            if (!me.inCombat)
                return;
            if (low)
                me.castSelf(spellDarkWater);
            steps.after(Step.darkWater, 15.seconds);
            break;
        case Step.leave:
            me.say(emoteMawsKill);
            me.despawn(1);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        me.say(emoteMawsKill);
        steps.clear();
    }
}

/**
 * Azuregos: Mana Storm, Chill, Frost Breath, Reflection and Cleave; Arcane Vacuum pulls all to him.
 * His Mark of Frost stuns those he killed who come back. Out of a fight, he talks.
 */
@creature("boss_azuregos")
struct Azuregos
{
    enum : uint { spellArcaneVacuum = 21147, spellMarkOfFrostAura = 23184, spellManaStorm = 21097, spellChill = 21098,
        spellFrostBreath = 21099, spellReflect = 22067, spellCleave = 19983 }
    enum int sayTeleport = -1000100;

    enum Step : ubyte { manaStorm, chill, frostBreath, teleport, reflect, cleave }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(spellMarkOfFrostAura);
        me.npcFlags(0);
        steps.after(Step.manaStorm, (5 + me.random(13)).seconds);
        steps.after(Step.chill, (10 + me.random(21)).seconds);
        steps.after(Step.frostBreath, (2 + me.random(7)).seconds);
        steps.after(Step.teleport, 30.seconds);
        steps.after(Step.reflect, (15 + me.random(16)).seconds);
        steps.after(Step.cleave, 7.seconds);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
        me.restoreNpcFlags();
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return;
        final switch (step)
        {
        case Step.manaStorm:
            retry(me, step, me.castSpell(spellManaStorm, me.randomTarget()), 18, 35);
            break;
        case Step.teleport:
            const ok = me.castSelf(spellArcaneVacuum);
            if (ok == ActionResult.ok)
                me.say(sayTeleport);
            retry(me, step, ok, 20, 30);
            break;
        case Step.chill:
            retry(me, step, me.castSelf(spellChill), 13, 25);
            break;
        case Step.frostBreath:
            retry(me, step, me.castSelf(spellFrostBreath), 10, 25);
            break;
        case Step.reflect:
            retry(me, step, me.castSelf(spellReflect), 20, 35);
            break;
        case Step.cleave:
            retry(me, step, me.castSpell(spellCleave), 7, 7);
            break;
        }
    }

    private void retry(ref CreatureContext me, Step step, ActionResult result, uint low, uint high)
    {
        steps.after(step, result == ActionResult.ok ? (low + me.random(high - low + 1)).seconds : 1.seconds);
    }
}

// Open-world round 2:

/**
 * Loramus Thalipedes: asked for help (2744) it is the quest's event; on
 * "Loramus" (3141) he tells his story page after page, the last answer the quest's event.
 */
@creature("npc_loramus_thalipedes")
struct LoramusThalipedes
{
    enum uint questCanYouHelpMe = 2744, questStory = 3141;
    enum : uint { help = 1, story = 2 }

    private static immutable uint[5] pages = [1813, 1814, 1815, 1816, 1817];
    private static immutable string[5] answers = ["Please continue", "I do not understand", "Indeed",
        "I will do this with or your help, Loramus", "Yes"];

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        GossipMenu menu;
        if (me.questStatus(e.player, questCanYouHelpMe) == QuestProgress.incomplete)
            menu.add(GossipIcon.chat, "Can you help me?", help);
        if (me.questStatus(e.player, questStory) == QuestProgress.incomplete)
            menu.add(GossipIcon.chat, "Tell me your story", story);
        me.sendGossip(e.player, 0, menu);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        if (e.action == help)
        {
            me.closeGossip(e.player);
            return me.questEvent(e.player, questCanYouHelpMe);
        }
        // The story: actions 20 + page.
        const page = e.action == story ? 0 : e.action - 20;
        if (e.action == story || (e.action > 20 && page < pages.length))
        {
            GossipMenu menu;
            menu.add(GossipIcon.chat, answers[page], 21 + page);
            return me.sendGossip(e.player, pages[page], menu, false);
        }
        me.closeGossip(e.player);
        if (e.action == 20 + pages.length)
            me.questEvent(e.player, questStory);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.azshara;

    // A siren's abilities, on their timers.
    auto s = Driven!self("mobs_spitelashes", Spitelash.siren);
    s.host.fighting = true;
    s.raise(EnteredCombat(hero));
    s.run(10_000);
    assert(s.host.has("cast 11640") && s.host.has("cast 6660") && s.host.has("cast 12551") && s.host.has("cast 11831"));
    assert(!s.host.has("cast 6713"), "a warrior's");

    // The sheep backfires for a player on the quest.
    auto w = Driven!self("mobs_spitelashes", Spitelash.warrior);
    w.host.quests[Spitelash.questFragmentedMagic] = QuestProgress.incomplete;
    w.raise(SpellHit(hero, 118));
    w.run(5000);
    assert(w.host.has("cast 28406") && w.host.has("despawn"));

    auto a = Driven!self("boss_azuregos", 6109);
    a.host.fighting = true;
    a.raise(EnteredCombat(hero));
    a.run(31_000);
    assert(a.host.has("cast 21147") && a.host.has("say -1000100") && a.host.has("cast 19983"));
}

unittest // Open-world round 2
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.azshara;

    auto l = Driven!self("npc_loramus_thalipedes", 7783);
    l.host.quests[LoramusThalipedes.questStory] = QuestProgress.incomplete;
    l.raise(GossipHello(hero));
    assert(l.host.menu.length == 1);
    l.raise(GossipSelect(hero, 0, 0, l.host.menu[0].action));
    foreach (_; 0 .. 4)
        l.raise(GossipSelect(hero, 0, 0, l.host.menu[0].action));
    assert(l.host.menuText == 1817 && !l.host.has("event 3141"));
    l.raise(GossipSelect(hero, 0, 0, l.host.menu[0].action));
    assert(l.host.has("event 3141"));
}
