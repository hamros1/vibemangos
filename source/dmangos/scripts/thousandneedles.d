/**
 * Thousand Needles: the escorts of Kanati Greycloud ("Protect Kanati Greycloud", 4966), Lakota
 * Windsong ("Free at Last", 4904) and Pao'ka Swiftmountain ("Homeward Bound", 4770); and "Plucky"
 * Johnson, a chicken until someone beckons or clucks at him, who tells the phrase ("Get the Scoop",
 * 1950).
 */
module dmangos.scripts.thousandneedles;

import dmangos.script;

/// Attackers of `entry` at `at`, gone `despawnMs` after a fight; set on the creature (`atMe`).
private void ambush(ref CreatureContext me, uint entry, const Location[] at, uint despawnMs, bool atMe = true)
{
    foreach (spot; at)
    {
        const summoned = me.summon(entry, spot, despawnMs);
        if (atMe)
            me.attack(summoned, me.self);
    }
}

/// Kanati Greycloud: three Galak assassins come for him as he sets off (`waypoint_path` 10638).
@creature("npc_kanati")
struct Kanati
{
    enum uint questProtectKanati = 4966, galakAssassin = 10720, sayStart = 6149, factionEscort = 232;
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questProtectKanati || escort.active)
            return;
        me.setFaction(factionEscort);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 1)
        {
            me.unitFlags(UnitFlag.immuneToNpc, false);
            me.sayText(sayStart);
            const at = Location(-4867.387695f, -1357.353760f, -48.226f);
            ambush(me, galakAssassin, [at, at, at], 25_000);
        }
        else if (point + 1 == 2)
        {
            me.unitFlags(UnitFlag.immuneToNpc);
            me.groupQuestEvent(escort.player, questProtectKanati);
            me.setFaction(0);
        }
    }
}

/// Lakota Windsong: Grimtotem bandits waylay her three times on her way out of the Grimtotem's hold.
@creature("npc_lakota_windsong")
struct LakotaWindsong
{
    enum uint questFreeAtLast = 4904, grimBandit = 10758;
    enum : int { sayStart = -1000365, sayLookOut = -1000366, sayHereCome = -1000367, sayMore = -1000368, sayEnd = -1000369 }
    private static immutable Location[6] banditAt = [
        Location(-4905.479492f, -2062.732666f, 84.352f), Location(-4915.201172f, -2073.528320f, 84.733f),
        Location(-4878.883301f, -1986.947876f, 91.966f), Location(-4877.503906f, -1966.113403f, 91.859f),
        Location(-4767.985352f, -1873.169189f, 90.192f), Location(-4788.861328f, -1888.007813f, 89.888f),
    ];
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questFreeAtLast || escort.active)
            return;
        me.say(sayStart, e.player);
        me.setFaction(EscortFaction.hordeNeutralActive);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == uint.max)
            return;
        switch (point + 1)
        {
        case 9: me.say(sayLookOut); ambush(me, grimBandit, banditAt[0 .. 2], 60_000); break;
        case 15: me.say(sayHereCome); ambush(me, grimBandit, banditAt[2 .. 4], 60_000); break;
        case 22: me.say(sayMore); ambush(me, grimBandit, banditAt[4 .. 6], 60_000); break;
        case 46:
            me.say(sayEnd);
            me.groupQuestEvent(escort.player, questFreeAtLast);
            break;
        default: break;
        }
    }
}

/// Pao'ka Swiftmountain: wyverns come at him on the way home to Freewind Post.
@creature("npc_paoka_swiftmountain")
struct PaokaSwiftmountain
{
    enum uint questHomeward = 4770, wyvern = 4107;
    enum : int { sayStart = -1000362, sayWyvern = -1000363, sayComplete = -1000364 }
    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questHomeward || escort.active)
            return;
        me.say(sayStart, e.player);
        me.setFaction(EscortFaction.hordeNeutralActive);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 16)
        {
            me.say(sayWyvern);
            // The wyverns come on their own (they are hostile to whoever is there).
            ambush(me, wyvern, [Location(-4990.606f, -906.057f, -5.343f), Location(-4970.241f, -927.378f, -4.951f),
                Location(-4985.364f, -952.528f, -5.199f)], 60_000, false);
        }
        else if (point + 1 == 27)
            me.say(sayComplete);
        else if (point + 1 == 28)
            me.groupQuestEvent(escort.player, questHomeward);
    }
}

/**
 * "Plucky" Johnson: a chicken; a player on "The Scoop" beckoning at him (or anyone clucking at him)
 * turns him back into a human for two minutes, and he tells the phrase.
 */
@creature("npc_plucky_johnson")
struct PluckyJohnson
{
    enum uint questScoop = 1950, factionFriendly = 35, gossipFlag = 1, textHello = 720, textPhrase = 738, tellPhrase = 1;
    enum : uint { spellPluckyHuman = 9192, spellPluckyChicken = 9220, textEmoteBeckon = 7, textEmoteChicken = 22, emoteWave = 3 }

    enum Step : ubyte { chicken }
    Schedule!Step steps;
    bool human;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        becomeChicken(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        becomeChicken(me);
    }

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        if (human)
            return;
        if (e.textEmote == textEmoteBeckon && me.questStatus(e.player, questScoop) == QuestProgress.incomplete)
            becomeHuman(me);
        else if (e.textEmote == textEmoteChicken)
        {
            becomeHuman(me);
            me.emote(emoteWave);
        }
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        GossipMenu menu;
        if (me.questStatus(e.player, questScoop) == QuestProgress.incomplete)
            menu.add(GossipIcon.chat, "Please tell me the Phrase..", tellPhrase);
        me.sendGossip(e.player, textHello, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != tellPhrase)
            return;
        GossipMenu none;
        me.sendGossip(e.player, textPhrase, none, false);
        me.questEvent(e.player, questScoop);
    }

    void on(ref CreatureContext me, Step step)
    {
        if (me.inCombat)
            me.restoreNpcFlags();
        else
            becomeChicken(me);
    }

    private void becomeHuman(ref CreatureContext me)
    {
        human = true;
        me.setFaction(factionFriendly);
        me.npcFlags(gossipFlag);
        me.removeAura(me.self, spellPluckyChicken);
        me.castSelf(spellPluckyHuman);
        steps.after(Step.chicken, 120.seconds);
    }

    private void becomeChicken(ref CreatureContext me)
    {
        human = false;
        steps.clear();
        me.restoreNpcFlags();
        me.setFaction(0);
        me.removeAura(me.self, spellPluckyHuman);
        me.castSelf(spellPluckyChicken);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.thousandneedles;

    auto l = Driven!self("npc_lakota_windsong", 10_646, 46);
    l.raise(QuestAccepted(hero, LakotaWindsong.questFreeAtLast));
    l.walkTo(45);
    assert(l.host.summons == 6 && l.host.has("event 4904") && l.host.has("attack 10758 10646"));

    auto k = Driven!self("npc_kanati", 10_638, 2);
    k.raise(QuestAccepted(hero, Kanati.questProtectKanati));
    k.walkTo(1);
    assert(k.host.summons == 3 && k.host.has("event 4966") && k.host.has("faction 0"));

    auto p = Driven!self("npc_plucky_johnson", 6626);
    p.raise(Spawned());
    p.raise(EmoteReceived(hero, PluckyJohnson.textEmoteBeckon));
    assert(!p.host.has("npcflags 1"), "not on the quest");
    p.host.quests[PluckyJohnson.questScoop] = QuestProgress.incomplete;
    p.raise(EmoteReceived(hero, PluckyJohnson.textEmoteBeckon));
    assert(p.host.has("npcflags 1") && p.host.has("cast 9192"));
    p.raise(GossipSelect(hero, 0, 0, PluckyJohnson.tellPhrase));
    assert(p.host.has("event 1950"));
    p.run(120_000);
    assert(p.host.did[$ - 1] == "cast 9220", "a chicken again");
}
