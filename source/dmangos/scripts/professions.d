/**
 * The profession specializations (ScriptDevAI's `npc_professions`): the blacksmiths who teach (and
 * take back) Armorsmithing and Weaponsmithing and the three weapon masteries, and the leatherworkers
 * of the Dragonscale, Elemental and Tribal schools.
 *
 * Classic has no "unlearn specialization" spells (they came with the next expansion), so forgetting one
 * is done here directly: the specialization goes, with the recipes its plans and patterns taught, for
 * the price CMaNGOS asks; nobody may forget one while wearing an item that needs it.
 */
module dmangos.scripts.professions;

import dmangos.script;

/// `SkillLine`s.
private enum : uint { skillBlacksmithing = 164, skillLeatherworking = 165 }

/// The cost of forgetting a specialization by the player's level (`GetUnlearnCostMedium`, `GetUnlearnCostLow`).
uint unlearnCostMedium(uint level) pure nothrow @nogc @safe
{
    return level < 51 ? 250_000 : level < 66 ? 500_000 : 1_000_000;
}

/// ditto
uint unlearnCostLow(uint level) pure nothrow @nogc @safe
{
    return level < 66 ? 50_000 : 100_000;
}

/**
 * The blacksmiths of the specializations: Myolor Sunderfury and Krathok Moltenfist choose Armorsmith or
 * Weaponsmith for the journeyman (225) friendly with that guild; the armorsmith and weaponsmith trainers
 * train, and unlearn, their own; Lilith, Kilram and Seril teach a weaponsmith of level 50 with 250 skill
 * their weapon (one of the three), and take it back.
 */
@creature("npc_prof_blacksmith")
struct ProfessionBlacksmith
{
    enum : uint
    {
        spellWeapon = 9787, spellArmor = 9788, spellHammer = 17040, spellAxe = 17041, spellSword = 17039,
        spellLearnWeapon = 9789, spellLearnArmor = 9790, spellLearnHammer = 17044, spellLearnAxe = 17043,
        spellLearnSword = 17042,
        factionArmor = 46, factionWeapon = 289,
        // Trainers.
        omni1 = 11145, omni2 = 11176, weapon1 = 11146, weapon2 = 11178, armor1 = 5164, armor2 = 11177,
        hammer = 11191, axe = 11192, sword = 11193,
    }

    /// What an option does.
    enum Action : uint
    {
        train = 1, learnArmor, learnWeapon,
        // Asking first, then doing it.
        askUnlearnWeapon, askUnlearnArmor, askLearnHammer, askLearnAxe, askLearnSword,
        askUnlearnHammer, askUnlearnAxe, askUnlearnSword,
        unlearnWeapon, unlearnArmor, learnHammer, learnAxe, learnSword, unlearnHammer, unlearnAxe, unlearnSword,
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        const p = e.player;
        GossipMenu menu;
        const entry = me.self.entry;
        if (me.skillOf(p, skillBlacksmithing) >= 225)
        {
            const specialized = me.knowsSpell(p, spellArmor) || me.knowsSpell(p, spellWeapon);
            switch (entry)
            {
            case omni1, omni2:
                if (!specialized && me.standingOf(p, factionArmor) == Standing.friendly)
                    menu.add(GossipIcon.chat, "Please teach me how to become an Armorsmith", Action.learnArmor);
                if (!specialized && me.standingOf(p, factionWeapon) == Standing.friendly)
                    menu.add(GossipIcon.chat, "Please teach me how to become a Weaponsmith", Action.learnWeapon);
                break;
            case weapon1, weapon2:
                if (me.knowsSpell(p, spellWeapon))
                {
                    menu.add(GossipIcon.chat, "I wish to unlearn the art of Weaponsmithing", Action.askUnlearnWeapon);
                    menu.add(GossipIcon.trainer, "Train me.", Action.train);
                }
                break;
            case armor1, armor2:
                if (me.knowsSpell(p, spellArmor))
                {
                    menu.add(GossipIcon.chat, "I wish to unlearn the art of Armorsmithing", Action.askUnlearnArmor);
                    menu.add(GossipIcon.trainer, "Train me.", Action.train);
                }
                break;
            default:
                break;
            }
        }
        if (me.knowsSpell(p, spellWeapon) && me.levelOf(p) > 49 && me.skillOf(p, skillBlacksmithing) >= 250)
        {
            const mastered = me.knowsSpell(p, spellHammer) || me.knowsSpell(p, spellAxe) || me.knowsSpell(p, spellSword);
            switch (entry)
            {
            case hammer:
                if (!mastered)
                    menu.add(GossipIcon.chat, "Please teach me how to become a Hammersmith, Lilith", Action.askLearnHammer);
                if (me.knowsSpell(p, spellHammer))
                    menu.add(GossipIcon.chat, "I wish to unlearn Hammersmithing", Action.askUnlearnHammer);
                break;
            case axe:
                if (!mastered)
                    menu.add(GossipIcon.chat, "Please teach me how to become an Axesmith, Kilram", Action.askLearnAxe);
                if (me.knowsSpell(p, spellAxe))
                    menu.add(GossipIcon.chat, "I wish to unlearn Axesmithing", Action.askUnlearnAxe);
                break;
            case sword:
                if (!mastered)
                    menu.add(GossipIcon.chat, "Please teach me how to become a Swordsmith, Seril", Action.askLearnSword);
                if (me.knowsSpell(p, spellSword))
                    menu.add(GossipIcon.chat, "I wish to unlearn Swordsmithing", Action.askUnlearnSword);
                break;
            default:
                break;
            }
        }
        me.sendGossip(p, 0, menu);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        const p = e.player;
        const level = me.levelOf(p);
        switch (e.action)
        {
        case Action.train:
            return me.openWindow(p, NpcWindow.trainer);
        // The second step: the same words again, now meaning it (and its price, to forget one).
        case Action.askUnlearnWeapon, Action.askUnlearnArmor:
            return confirm(me, p, "I wish to unlearn my blacksmith specialty", e.action + (Action.unlearnWeapon - Action.askUnlearnWeapon));
        case Action.askLearnHammer:
            return confirm(me, p, "Please teach me how to become a Hammersmith, Lilith", Action.learnHammer);
        case Action.askLearnAxe:
            return confirm(me, p, "Please teach me how to become an Axesmith, Kilram", Action.learnAxe);
        case Action.askLearnSword:
            return confirm(me, p, "Please teach me how to become a Swordsmith, Seril", Action.learnSword);
        case Action.askUnlearnHammer:
            return confirm(me, p, "I wish to unlearn Hammersmithing", Action.unlearnHammer);
        case Action.askUnlearnAxe:
            return confirm(me, p, "I wish to unlearn Axesmithing", Action.unlearnAxe);
        case Action.askUnlearnSword:
            return confirm(me, p, "I wish to unlearn Swordsmithing", Action.unlearnSword);
        // Doing it.
        case Action.learnArmor:
            if (!me.knowsSpell(p, spellArmor) && !me.knowsSpell(p, spellWeapon))
                me.castAs(p, spellLearnArmor, p, true);
            break;
        case Action.learnWeapon:
            if (!me.knowsSpell(p, spellWeapon) && !me.knowsSpell(p, spellArmor))
                me.castAs(p, spellLearnWeapon, p, true);
            break;
        case Action.learnHammer:
            me.castAs(p, spellLearnHammer, p, true);
            break;
        case Action.learnAxe:
            me.castAs(p, spellLearnAxe, p, true);
            break;
        case Action.learnSword:
            me.castAs(p, spellLearnSword, p, true);
            break;
        case Action.unlearnWeapon:
            // A master of a weapon forgets it with the art it is part of.
            if (forget(me, p, spellWeapon, unlearnCostLow(level)))
                foreach (mastery; [spellHammer, spellAxe, spellSword])
                    if (me.knowsSpell(p, mastery))
                        me.unlearnSpell(p, mastery);
            break;
        case Action.unlearnArmor:
            forget(me, p, spellArmor, unlearnCostLow(level));
            break;
        case Action.unlearnHammer:
            forget(me, p, spellHammer, unlearnCostMedium(level));
            break;
        case Action.unlearnAxe:
            forget(me, p, spellAxe, unlearnCostMedium(level));
            break;
        case Action.unlearnSword:
            forget(me, p, spellSword, unlearnCostMedium(level));
            break;
        default:
            break;
        }
        me.closeGossip(p);
    }

    private static void confirm(ref CreatureContext me, EntityRef player, string text, uint action)
    {
        GossipMenu menu;
        menu.add(GossipIcon.chat, text, action);
        me.sendGossip(player, 0, menu, false);
    }
}

/**
 * The leatherworkers of the three schools: one who has done a school's quest (any school's, to choose
 * again after forgetting one) and has none, with 225 skill at level 40, may learn the trainer's school;
 * one of the school trains and may forget it.
 */
@creature("npc_prof_leather")
struct ProfessionLeather
{
    enum : uint
    {
        spellDragon = 10656, spellElemental = 10658, spellTribal = 10660,
        spellLearnDragon = 10657, spellLearnElemental = 10659, spellLearnTribal = 10661,
        // Trainers.
        dragon1 = 7866, dragon2 = 7867, elemental1 = 7868, elemental2 = 7869, tribal1 = 7870, tribal2 = 7871,
    }

    /// The schools' quests, Alliance and Horde (`Q_DRAGON_ALLY` ...).
    private static immutable uint[6] schoolQuests = [5141, 5145, 5144, 5146, 5143, 5148];

    /// A school of a trainer: its specialization, the spell that teaches it, the words.
    private static struct School
    {
        uint spell, learn;
        string learnText, unlearnText;
    }

    private static immutable School[3] schools = [
        School(spellDragon, spellLearnDragon, "Please teach me how to become a Dragonscale leatherworker.",
            "I wish to unlearn my Dragonscale Leatherworking specialization!"),
        School(spellElemental, spellLearnElemental, "Please teach me how to become an Elemental leatherworker.",
            "I wish to unlearn my Elemental Leatherworking specialization!"),
        School(spellTribal, spellLearnTribal, "Please teach me how to become a Tribal leatherworker.",
            "I wish to unlearn my Tribal Leatherworking specialization!"),
    ];

    enum Action : uint { train = 1, learn, unlearn }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        me.consume();
        const p = e.player;
        GossipMenu menu;
        const school = schoolOf(me.self.entry);
        if (school !is null && me.skillOf(p, skillLeatherworking) >= 225 && me.levelOf(p) > 39)
        {
            if (me.knowsSpell(p, school.spell))
            {
                menu.add(GossipIcon.chat, school.unlearnText, Action.unlearn);
                menu.add(GossipIcon.trainer, "Train me.", Action.train);
            }
            else if (mayChoose(me, p))
                menu.add(GossipIcon.chat, school.learnText, Action.learn);
        }
        me.sendGossip(p, 0, menu);
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        me.consume();
        const p = e.player;
        const school = schoolOf(me.self.entry);
        if (school !is null)
            final switch (cast(Action) e.action)
            {
            case Action.train:
                return me.openWindow(p, NpcWindow.trainer);
            case Action.learn:
                if (mayChoose(me, p))
                    me.castAs(p, school.learn, p, true);
                break;
            case Action.unlearn:
                if (me.knowsSpell(p, school.spell))
                    forget(me, p, school.spell, unlearnCostMedium(me.levelOf(p)));
                break;
            }
        me.closeGossip(p);
    }

    /// Whether the player may choose a school: it has none, and has done a school's quest.
    private static bool mayChoose(ref CreatureContext me, EntityRef player)
    {
        foreach (s; schools)
            if (me.knowsSpell(player, s.spell))
                return false;
        foreach (quest; schoolQuests)
            if (me.questStatus(player, quest) == QuestProgress.rewarded)
                return true;
        return false;
    }

    private static immutable(School)* schoolOf(uint entry)
    {
        switch (entry)
        {
        case dragon1, dragon2:
            return &schools[0];
        case elemental1, elemental2:
            return &schools[1];
        case tribal1, tribal2:
            return &schools[2];
        default:
            return null;
        }
    }
}

/// A player forgets `spell` (and what it taught) for `cost`: not while wearing what needs it, nor
/// without the money. Whether it was forgotten.
private bool forget(ref CreatureContext me, EntityRef player, uint spell, uint cost)
{
    if (!me.knowsSpell(player, spell) || me.wearsItemNeeding(player, spell) || !me.takeMoney(player, cost))
        return false;
    me.unlearnSpell(player, spell);
    return true;
}

unittest
{
    import dmangos.scripts.kalimdortesting;

    alias self = dmangos.scripts.professions;

    assert(unlearnCostMedium(50) == 250_000 && unlearnCostMedium(60) == 500_000 && unlearnCostLow(60) == 50_000);

    // Myolor: a journeyman friendly with the armorsmiths becomes one.
    auto myolor = Driven!self("npc_prof_blacksmith", ProfessionBlacksmith.omni1);
    myolor.host.skills[164] = 230;
    myolor.host.standings[ProfessionBlacksmith.factionArmor] = Standing.friendly;
    assert(myolor.raise(GossipHello(hero)));
    assert(myolor.host.menu.length == 1 && myolor.host.menu[0].action == ProfessionBlacksmith.Action.learnArmor);
    myolor.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.learnArmor));
    assert(myolor.host.has("cast as hero 9790") && myolor.host.has("close"));

    // Lilith: the hammer, asked twice; then forgotten, for its price.
    auto lilith = Driven!self("npc_prof_blacksmith", ProfessionBlacksmith.hammer);
    lilith.host.skills[164] = 260;
    lilith.host.spells[ProfessionBlacksmith.spellWeapon] = true;
    lilith.raise(GossipHello(hero));
    assert(lilith.host.menu.length == 1 && lilith.host.menu[0].action == ProfessionBlacksmith.Action.askLearnHammer);
    lilith.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.askLearnHammer));
    assert(lilith.host.menu[0].action == ProfessionBlacksmith.Action.learnHammer);
    lilith.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.learnHammer));
    assert(lilith.host.has("cast as hero 17044"));
    lilith.host.spells[ProfessionBlacksmith.spellHammer] = true;
    lilith.host.money = 100_000;
    lilith.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.unlearnHammer));
    assert(!lilith.host.has("unlearn 17040"), "too poor");
    lilith.host.money = 600_000;
    lilith.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.unlearnHammer));
    assert(lilith.host.has("pay 500000") && lilith.host.has("unlearn 17040"));

    // A weaponsmith forgetting the art forgets its mastery too.
    auto ironus = Driven!self("npc_prof_blacksmith", ProfessionBlacksmith.weapon1);
    ironus.host.skills[164] = 300;
    ironus.host.spells[ProfessionBlacksmith.spellWeapon] = true;
    ironus.host.spells[ProfessionBlacksmith.spellSword] = true;
    ironus.host.money = 50_000;
    ironus.raise(GossipHello(hero));
    assert(ironus.host.menu.length == 2);
    ironus.raise(GossipSelect(hero, 0, 1, ProfessionBlacksmith.Action.train));
    assert(ironus.host.has("trainer"));
    ironus.raise(GossipSelect(hero, 0, 0, ProfessionBlacksmith.Action.unlearnWeapon));
    assert(ironus.host.has("unlearn 9787") && ironus.host.has("unlearn 17039"));

    // Peter Galen: Dragonscale for one who did a school's quest; not forgotten while worn.
    auto peter = Driven!self("npc_prof_leather", ProfessionLeather.dragon1);
    peter.host.skills[165] = 250;
    peter.raise(GossipHello(hero));
    assert(peter.host.menu.length == 0, "no school's quest done");
    peter.host.quests[5146] = QuestProgress.rewarded;
    peter.raise(GossipHello(hero));
    assert(peter.host.menu.length == 1 && peter.host.menu[0].action == ProfessionLeather.Action.learn);
    peter.raise(GossipSelect(hero, 0, 0, ProfessionLeather.Action.learn));
    assert(peter.host.has("cast as hero 10657"));
    peter.host.spells[ProfessionLeather.spellDragon] = true;
    peter.host.money = 1_000_000;
    peter.host.wearing = true;
    peter.raise(GossipSelect(hero, 0, 0, ProfessionLeather.Action.unlearn));
    assert(!peter.host.has("unlearn 10656"));
    peter.host.wearing = false;
    peter.raise(GossipSelect(hero, 0, 0, ProfessionLeather.Action.unlearn));
    assert(peter.host.has("unlearn 10656") && peter.host.money == 500_000);
}
