/**
 * Stormwind: Lady Katrana Prestor, whose advice the player on "The True Masters" (4185) seeks (the
 * conversation, three gossip steps, is the quest's event); Bartleby and Dashel Stonefist, who fight
 * the player on "Beat Bartleby" (1640) and "The Missing Diplomat" (1447) until they give up; and Major
 * Mattingly and Field Marshal Afrasiabi, who talk of the dragon's head on its pike while it is there.
 */
module dmangos.scripts.stormwind;

import dmangos.script;

/// Lady Katrana Prestor: her conversation for "The True Masters", and her usual menu otherwise.
@creature("npc_lady_katrana_prestor")
struct LadyKatranaPrestor
{
    enum uint questTrueMasters = 4185;
    enum : uint { textGreeting = 2693, textAdvice = 2694, textWarning = 2695, textFarewell = 2696 }
    enum : uint { askAdvice = 1, apologize = 2, beg = 3 }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questTrueMasters) != QuestProgress.incomplete)
            return; // her usual menu
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Pardon the intrusion, Lady Prestor, but Highlord Bolvar suggested that I seek your advice.",
            askAdvice);
        me.sendGossip(e.player, textGreeting, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        GossipMenu menu;
        switch (e.action)
        {
        case askAdvice:
            menu.add(GossipIcon.chat, "My apologies, Lady Prestor.", apologize);
            me.sendGossip(e.player, textAdvice, menu, false);
            break;
        case apologize:
            menu.add(GossipIcon.chat, "Begging your pardon, Lady Prestor. That was not my intent.", beg);
            me.sendGossip(e.player, textWarning, menu, false);
            break;
        case beg:
            me.sendGossip(e.player, textFarewell, menu, false);
            me.questEvent(e.player, questTrueMasters);
            break;
        default:
            break;
        }
    }
}

/// Faction 168: hostile to all.
private enum uint factionEnemy = 168;

/**
 * Bartleby: taken on the quest, he turns on the player; brought below 15% of his health (he cannot
 * die meanwhile), he gives up: the quest's event happens and he is himself again.
 */
@creature("npc_bartleby")
struct Bartleby
{
    enum uint questBeat = 1640;
    bool fighting;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questBeat || fighting)
            return;
        fighting = true;
        me.setFaction(factionEnemy);
        me.deathPrevention(true);
        me.attack(e.player);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!fighting || e.after >= 15)
            return;
        if (e.attacker.isPlayer)
            me.questEvent(e.attacker, questBeat);
        calm(me);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        if (fighting)
            calm(me);
    }

    private void calm(ref CreatureContext me)
    {
        fighting = false;
        me.deathPrevention(false);
        me.setFaction(0);
    }
}

/**
 * Dashel Stonefist: taken on the quest he threatens the player, two Old Town Thugs run in, and two
 * seconds on he attacks too. Brought to a fifth of his health (he cannot die meanwhile) he begs, stops,
 * goes back to his place and sends the thugs off, and the quest's event happens. Should he give up
 * the fight otherwise, the quest fails.
 */
@creature("npc_dashel_stonefist")
struct DashelStonefist
{
    enum uint questMissingDiplomat8 = 1447, oldTownThug = 4969;
    enum uint factionNeutral = 189, factionFriendlyToAll = 35, immuneToNpc = 0x200;
    /// `broadcast_text` rows.
    enum : uint { sayThreat = 1961, sayEnough = 1712, sayBackOff = 1713, sayThugSure = 1716, sayThugOkay = 1715 }
    enum uint emoteBeg = 20;
    /// `moveCreature` points of the thugs: at the player, back to their place.
    enum : uint { thugsAtPlayer = 1, thugsBack = 10 }

    private static immutable Location[2] thugFrom = [Location(-8687.311f, 446.7531f, 100.05593f, 5.12632f),
        Location(-8669.205f, 448.4405f, 99.74935f, 3.75387f)];
    private static immutable Location[2] thugTo = [Location(-8684.558f, 442.7352f, 99.480316f),
        Location(-8675.7f, 443.8787f, 99.641556f)];
    private static immutable Location[2] thugBack = [Location(-8686.397461f, 447.595703f, 99.994408f),
        Location(-8669.338867f, 448.362976f, 99.740005f)];

    enum Step : ubyte { attack, thugSure, thugOkay, thugsBack, done }
    Schedule!Step steps;
    EntityRef player;
    EntityRef[2] thugs;
    bool fighting, beaten;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMissingDiplomat8 || fighting || beaten)
            return;
        me.sayText(sayThreat, e.player);
        me.setFaction(factionNeutral);
        me.npcFlags(0);
        me.reactState(Reaction.aggressive);
        player = e.player;
        foreach (i, ref thug; thugs)
            if ((thug = me.summon(oldTownThug, thugFrom[i], 120_000)) != EntityRef.init)
                me.moveCreature(thug, thugTo[i], thugsAtPlayer, true);
        fighting = true;
        steps.after(Step.attack, 2.seconds);
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.point == thugsAtPlayer && fighting)
            me.attack(e.summoned, player);
        else if (e.point == thugsBack)
        {
            me.face(e.summoned);
            me.despawn(e.summoned, 2000);
        }
    }

    void on(ref CreatureContext me, const ref SummonedDied e)
    {
        foreach (ref thug; thugs)
            if (thug == e.summoned)
                thug = EntityRef.init;
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!fighting || e.after > 20)
            return;
        // He has had enough.
        fighting = false;
        beaten = true;
        me.sayText(sayEnough);
        me.setFaction(factionFriendlyToAll);
        me.emote(emoteBeg);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (fighting)
        {
            // He gave up the fight unbeaten: the quest fails.
            me.failQuest(player, questMissingDiplomat8);
            foreach (thug; thugs)
                if (thug)
                    me.despawn(thug, 0);
            return over(me);
        }
        if (!beaten || steps.busy)
            return;
        me.sayText(sayBackOff);
        steps.after(thugs[0] || thugs[1] ? Step.thugSure : Step.done, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.attack:
            if (!fighting)
                break;
            me.deathPrevention(true);
            me.attack(player);
            break;
        case Step.thugSure:
            if (thugs[0])
                me.sayAs(thugs[0], sayThugSure);
            steps.after(Step.thugOkay, 1500.msecs);
            break;
        case Step.thugOkay:
            if (thugs[1])
                me.sayAs(thugs[1], sayThugOkay);
            steps.after(Step.thugsBack, 1.seconds);
            break;
        case Step.thugsBack:
            foreach (i, thug; thugs)
                if (thug)
                    me.moveCreature(thug, thugBack[i], thugsBack);
            steps.after(Step.done, 2500.msecs);
            break;
        case Step.done:
            me.questEvent(player, questMissingDiplomat8);
            over(me);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        foreach (thug; thugs)
            if (thug)
                me.despawn(thug, 0);
        over(me);
    }

    private void over(ref CreatureContext me)
    {
        fighting = beaten = false;
        player = EntityRef.init;
        thugs[] = EntityRef.init;
        steps.clear();
        me.deathPrevention(false);
        me.setFaction(0);
        me.restoreNpcFlags();
        me.reactState(Reaction.passive);
    }
}

/// The heads on their pikes in Stormwind: Onyxia's (Major Mattingly's), Nefarian's (Field Marshal Afrasiabi's).
private enum uint headOfOnyxia = 179558, headOfNefarian = 179882;

/// Major Mattingly: while Onyxia's head hangs in Stormwind, he talks of it.
@creature("npc_major_mattingly")
struct MajorMattingly
{
    enum uint menuHead = 5754;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!me.objectNearby(headOfOnyxia, 100))
            return;
        me.gossipMenu(e.player, menuHead);
        me.consume();
    }
}

/// Field Marshal Afrasiabi: while Nefarian's head hangs in Stormwind, he talks of it.
@creature("npc_field_marshal_afrasiabi")
struct FieldMarshalAfrasiabi
{
    enum uint menuHead = 6027;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (!me.objectNearby(headOfNefarian, 100))
            return;
        me.gossipMenu(e.player, menuHead);
        me.consume();
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.stormwind;
    auto b = Driven!zone.make("npc_bartleby");
    b.raise(QuestAccepted(b.host.player, 1640));
    assert(b.host.faction == 168 && b.host.did("attack 0 0"));
    b.raise(Damaged(b.host.player, 10, 20, 14));
    assert(b.host.did("event 1640") && b.host.did("evade") && b.host.faction == 0);

    auto d = Driven!zone.make("npc_dashel_stonefist");
    d.raise(Spawned());
    d.raise(QuestAccepted(d.host.player, 1447));
    assert(d.host.did("text 1961") && d.host.summons == 2 && d.host.did("move other 4969 1"));
    d.raise(SummonedArrived(creatureRef(4969, 1), 1));
    assert(d.host.did("attack 4969 0"));
    d.tick(2000);
    assert(d.host.did("death prevention true"));
    d.raise(Damaged(d.host.player, 10, 30, 20));
    assert(d.host.did("text 1712") && d.host.faction == 35 && d.host.did("evade"));
    d.raise(Reset());
    d.tick(10_000);
    assert(d.host.did("text 1713") && d.host.did("text of 4969 1716") && d.host.did("event 1447"));
    assert(!d.host.did("fail 1447") && d.host.did("npc flags back"));

    auto m = Driven!zone.make("npc_major_mattingly");
    m.raise(GossipHello(m.host.player));
    assert(!m.host.did("menu 5754"));
    m.host.nearby[179558] = EntityRef(0xF110_0000_0000_0000 | (ulong(179558) << 24) | 1);
    m.raise(GossipHello(m.host.player));
    assert(m.host.did("menu 5754"));
}
