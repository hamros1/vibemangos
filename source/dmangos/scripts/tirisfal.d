/**
 * Tirisfal Glades: the mausoleum of "Ulag the Cleaver" (1819), whose trigger stone unlocks the door
 * that lets Ulag out; and Calvin Montague, who fights the player on "A Rogue's Deal" (590) until he
 * gives up.
 */
module dmangos.scripts.tirisfal;

import dmangos.script;

/// The quest of the mausoleum.
enum uint questUlag = 1819;
/// The mausoleum's door and its trigger stone.
enum uint mausoleumDoor = 176594, mausoleumTrigger = 104593;

/// The mausoleum door: opened on the quest, the trigger stone closes and Ulag comes out (the door opens as usual).
@gameObject("go_mausoleum_door")
struct MausoleumDoor
{
    enum uint ulag = 6390;

    void on(ref GameObjectContext door, const ref ObjectUsed e)
    {
        if (door.questStatus(e.player, questUlag) != QuestProgress.incomplete)
            return;
        const trigger = door.objectNearby(mausoleumTrigger, 30);
        if (!trigger)
            return;
        door.open(trigger, false);
        door.summon(ulag, Location(2390.26f, 336.47f, 40.01f, 2.26f), 300_000, e.player);
    }
}

/// The trigger stone: used on the quest, it sinks and the door may be opened.
@gameObject("go_mausoleum_trigger")
struct MausoleumTrigger
{
    enum uint flagInteractCondition = 0x4; /// `GO_FLAG_INTERACT_COND`

    void on(ref GameObjectContext trigger, const ref ObjectUsed e)
    {
        if (trigger.questStatus(e.player, questUlag) != QuestProgress.incomplete)
            return;
        const door = trigger.objectNearby(mausoleumDoor, 30);
        if (!door)
            return;
        trigger.open(trigger.self, true);
        trigger.objectFlags(door, flagInteractCondition, false);
        trigger.consume();
    }
}

/**
 * Calvin Montague: taken on the quest, he turns on the player; brought below 15% of his health he
 * stops (he cannot die meanwhile), gives up, and a little later the quest's event happens and he
 * drinks to recover.
 */
@creature("npc_calvin_montague")
struct CalvinMontague
{
    enum uint quest590 = 590, spellDrink = 2639;
    enum uint factionHostile = 168, immuneToPlayer = 0x100;
    enum int sayComplete = -1000356;

    enum Step : ubyte { giveUp, drink }
    Schedule!Step steps;
    EntityRef player;
    bool beaten;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        calm(me);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!beaten)
            calm(me);
    }

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != quest590 || beaten || me.inCombat)
            return;
        me.unitFlags(immuneToPlayer, false);
        me.setFaction(factionHostile);
        me.deathPrevention(true);
        me.attack(e.player);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (beaten || e.after >= 15)
            return;
        beaten = true;
        if (e.attacker.isPlayer)
            player = e.attacker;
        me.reactState(Reaction.passive);
        me.setFaction(0);
        me.evade();
        steps.after(Step.giveUp, 5.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.giveUp:
            me.say(sayComplete);
            steps.after(Step.drink, 7500.msecs);
            break;
        case Step.drink:
            if (player)
                me.questEvent(player, quest590);
            me.castSelf(spellDrink, true);
            beaten = false;
            player = EntityRef.init;
            calm(me);
            break;
        }
    }

    /// As he stands at the inn: friendly, players cannot touch him.
    private void calm(ref CreatureContext me)
    {
        me.deathPrevention(false);
        me.reactState(Reaction.aggressive);
        me.unitFlags(immuneToPlayer);
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto c = Driven!(dmangos.scripts.tirisfal).make("npc_calvin_montague");
    c.raise(Spawned());
    c.raise(QuestAccepted(c.host.player, 590));
    assert(c.host.faction == 168 && c.host.did("attack 0 0") && c.host.did("flags off 256"));
    c.host.fighting = true;
    c.raise(Damaged(c.host.player, 50, 40, 20));
    assert(!c.host.did("evade"));
    c.raise(Damaged(c.host.player, 50, 20, 10));
    assert(c.host.did("evade") && c.host.faction == 0);
    c.raise(Reset());
    c.tick(5000);
    assert(c.host.did("say -1000356") && !c.host.did("event 590"));
    c.tick(7500);
    assert(c.host.did("event 590") && c.host.did("cast 2639"));
}
