/**
 * An escort: a creature walking its `script_waypoint` path with a player who must keep it alive and
 * stay near. It is a component, not a base class: a script holds an `Escort` among its fields,
 * starts it, and passes it its `MovementDone`s; the framework
 * ticks it with the script. It is plain data, so a creature handed to another node goes on walking
 * there (if its movement did not come along, the escort sends it on again).
 */
module dmangos.script.escort;

import dmangos.script.api;

/// See the module documentation.
struct Escort
{
    EntityRef player;       /// whom it walks with
    uint quest;             /// whose quest it is (failed if the escort fails)
    uint point;             /// the point it walks to, or waits at
    int waitLeft;           /// how long it still waits there (ms)
    bool active;
    bool waiting;
    bool run;
    bool finished;          /// it reached its last point and waited there
    float maxDistance = 50; /// the player farther than this: the escort fails
    uint despawnAfterMs;    /// over (done or failed), it goes this long after, to come back home; 0: it stays
    bool paused;            /// it stays where it is (an ambush to fight off, a scene) until unpaused

    /// Sets off with `player` on `quest`, walking (running) from the first point; its NPC flags go
    /// (nobody else can take it on its way).
    void start(ref CreatureContext me, EntityRef player, uint quest, bool run = false)
    {
        const despawn = despawnAfterMs, distance = maxDistance;
        this = Escort.init;
        despawnAfterMs = despawn;
        maxDistance = distance;
        this.player = player;
        this.quest = quest;
        this.run = run;
        active = true;
        me.npcFlags(0);
        moveOn(me);
    }

    /// Its script's `MovementDone`: the point of the path it reached, or uint.max (not the escort's).
    uint reached(ref CreatureContext me, const ref MovementDone e)
    {
        if (!active || e.point != point)
            return uint.max;
        Waypoint w;
        me.waypoint(point, w);
        waiting = true;
        waitLeft = w.waitMs;
        return point;
    }

    /// The escort fails: the player's quest with it, and the creature stops where it is.
    void fail(ref CreatureContext me)
    {
        if (!active)
            return;
        me.failQuest(player, quest);
        active = false;
        over(me);
    }

    /// Whether the player is still with it: alive and near.
    bool playerNear(ref CreatureContext me)
    {
        return me.alive(player) && me.distanceTo(player) <= maxDistance;
    }

    /// Ticked with its script: waits, goes on, and fails when the player is gone.
    void tick(ref CreatureContext me, int ms)
    {
        if (!active)
            return;
        if (!playerNear(me))
            return fail(me);
        if (me.inCombat || paused)
            return;
        if (waiting)
        {
            waitLeft -= ms;
            if (waitLeft > 0)
                return;
            waiting = false;
            if (++point >= me.waypointCount)
            {
                active = false;
                finished = true;
                over(me);
                return;
            }
            return moveOn(me);
        }
        if (!me.moving)
            moveOn(me); // after a move between nodes, or a fight that left it still
    }

    /// Whether it needs ticks.
    @property bool busy() const
    {
        return active;
    }

    private void over(ref CreatureContext me)
    {
        me.restoreNpcFlags();
        if (despawnAfterMs)
            me.despawn(despawnAfterMs);
    }

    private void moveOn(ref CreatureContext me)
    {
        Waypoint w;
        if (me.waypoint(point, w))
            me.moveTo(w.at, point, run);
    }
}
