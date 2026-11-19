/**
 * Wetlands: "The Missing Diplomat" (1249). Mikhail, who gives the quest, sends Tapoke "Slim" Jahn
 * (hidden in Menethil's inn) off; at the door Slim shows himself and fights with a friend he calls,
 * and beaten, he talks.
 */
module dmangos.scripts.wetlands;

import dmangos.script;

/// The quest both scripts serve.
enum uint questMissingDiplomat = 1249;
/// Tapoke "Slim" Jahn.
enum uint tapokeSlimJahn = 4962;
/// A `Signal` from Mikhail to Slim: off with the player (`value`: the player's guid).
enum uint signalStartEscort = 1;

/// Mikhail: the quest taken, Slim (stealthed) sets off with the player.
@creature("npc_mikhail")
struct Mikhail
{
    enum uint spellStealth = 1785;

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questMissingDiplomat)
            return;
        const slim = me.creatureNearby(tapokeSlimJahn, 25);
        if (!slim)
            return;
        if (!me.hasAura(slim, spellStealth))
            me.castSpell(spellStealth, slim, true);
        // A player's guid is its low part only (`EntityRef.isPlayer`): it fits the signal's value.
        me.signal(slim, signalStartEscort, cast(int) cast(uint) e.player.guid);
    }
}

/**
 * Tapoke "Slim" Jahn: sent off by Mikhail, he walks to the inn's door (`script_waypoint`, points
 * counted from 1), where he drops his stealth, turns hostile and runs; attacked, he calls a friend.
 * Brought below a fifth of his health (he cannot die meanwhile), his friend gives up, he stops
 * fighting and, back where the fight began, admits defeat and hands over his notes (the quest's
 * event). Should he reach the end of his path, he has escaped and the quest fails.
 */
@creature("npc_tapoke_slim_jahn")
struct TapokeSlimJahn
{
    enum uint spellStealth = 1785, slimsFriend = 4971;
    enum uint factionEnemy = 168;
    enum : int { sayAggro = -1000977, sayDefeat = -1000978, sayFriendDefeat = -1000979, sayNotes = -1000980 }
    enum uint immuneToPlayer = 0x100;
    enum : uint { hostilePoint = 3, escapedPoint = 7 }

    enum Step : ubyte { notes, done }
    Schedule!Step steps;
    Escort escort = { despawnAfterMs: 1000 };
    EntityRef friend;
    bool beaten;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        calm(me);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id != signalStartEscort || escort.active || beaten)
            return;
        friend = EntityRef.init;
        me.deathPrevention(true);
        escort.start(me, EntityRef(cast(uint) e.value), questMissingDiplomat);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (escort.reached(me, e) + 1) // the database's point; 0: not the escort's
        {
        case hostilePoint:
            escort.run = true;
            me.removeAura(me.self, spellStealth);
            me.setFaction(factionEnemy);
            me.unitFlags(immuneToPlayer, false);
            me.reactState(Reaction.aggressive);
            break;
        case escapedPoint:
            escort.fail(me); // he got away
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!escort.active || friend)
            return;
        friend = me.summon(slimsFriend, Location.init, 60_000, escort.player);
        if (friend)
            me.say(sayAggro);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (!escort.active || beaten || e.after >= 20)
            return;
        if (friend && me.alive(friend))
        {
            me.sayOther(friend, sayFriendDefeat);
            me.despawn(friend, 1000);
        }
        beaten = true;
        escort.paused = true;
        me.setFaction(0);
        me.reactState(Reaction.passive);
        me.evade();
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        if (!beaten || steps.busy)
            return calm(me);
        // Back where the fight began: he gives up.
        me.face(escort.player);
        me.say(sayDefeat);
        steps.after(Step.notes, 4.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.notes:
            me.say(sayNotes);
            steps.after(Step.done, 7.seconds);
            break;
        case Step.done:
            me.questEvent(escort.player, questMissingDiplomat);
            escort.active = false; // over: he goes, to be back at the inn
            beaten = false;
            me.deathPrevention(false);
            me.despawn(1000);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }

    /// Hidden at the inn: players cannot touch him, and he touches nobody.
    private void calm(ref CreatureContext me)
    {
        me.unitFlags(immuneToPlayer);
        me.reactState(Reaction.passive);
    }
}

unittest
{
    import dmangos.scripts.testhost : creatureRef, Driven;

    alias zone = dmangos.scripts.wetlands;
    auto mikhail = Driven!zone.make("npc_mikhail");
    mikhail.host.nearby[4962] = creatureRef(4962);
    mikhail.raise(QuestAccepted(mikhail.host.player, 1249));
    assert(mikhail.host.did("cast 1785") && mikhail.host.did("signal 4962 1"));

    auto slim = Driven!zone.make("npc_tapoke_slim_jahn");
    slim.host.pathLength = 7;
    slim.raise(Signal(creatureRef(4964), 1, 7));
    slim.walk(2);
    assert(slim.host.faction == 168 && slim.host.did("react 2"));
    slim.host.fighting = true;
    slim.raise(EnteredCombat(slim.host.player));
    assert(slim.host.did("summon 4971") && slim.host.did("say -1000977"));
    slim.raise(Damaged(slim.host.player, 100, 30, 15));
    assert(slim.host.did("say of 4971 -1000979") && slim.host.did("evade") && slim.host.faction == 0);
    slim.raise(Reset());
    slim.tick(12_000);
    assert(slim.host.did("say -1000978") && slim.host.did("say -1000980") && slim.host.did("event 1249"));
    assert(!slim.host.did("fail 1249"));
}
