/**
 * A walk: a creature going along its `script_waypoint` path on its own, nobody escorting it (a
 * prisoner's guard on his round, a drunk on his way to the keg, a boss's trainee coming down the
 * hall). Like `Escort` it is a component among the script's fields, ticked with the script: it waits
 * where the path says, may pause and resume, and reports the points it reaches through `reached`.
 */
module dmangos.script.walk;

import dmangos.script.api;

/// See the module documentation.
struct Walk
{
    uint point;     /// the point it walks to, or waits at
    int waitLeft;   /// how long it still waits there (ms)
    bool active;
    bool waiting;
    bool run;
    bool paused;    /// it stays at the point it reached until `resume`
    bool finished;  /// it reached its last point and waited there
    uint stopAt = uint.max; /// it stops (pauses) on reaching this point

    /// Sets off from point `from` (by default the first), walking or running.
    void start(ref CreatureContext me, bool run = false, uint from = 0)
    {
        this = Walk.init;
        this.run = run;
        point = from;
        active = true;
        moveOn(me);
    }

    /// Its script's `MovementDone`: the point of the path it reached, or uint.max (not the walk's).
    uint reached(ref CreatureContext me, const ref MovementDone e)
    {
        if (!active || e.point != point)
            return uint.max;
        Waypoint w;
        me.waypoint(point, w);
        waiting = true;
        waitLeft = w.waitMs;
        if (point == stopAt)
            paused = true;
        return point;
    }

    /// It goes on (after a pause), past the point it waits at.
    void resume()
    {
        paused = false;
    }

    /// It stops for good where it is.
    void stop()
    {
        active = false;
    }

    /// Ticked with its script: waits, goes on.
    void tick(ref CreatureContext me, int ms)
    {
        if (!active || me.inCombat || paused)
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
                return;
            }
            return moveOn(me);
        }
        if (!me.moving)
            moveOn(me); // after a fight that left it still, or a move between nodes
    }

    /// Whether it needs ticks.
    @property bool busy() const
    {
        return active;
    }

    private void moveOn(ref CreatureContext me)
    {
        Waypoint w;
        if (me.waypoint(point, w))
            me.moveTo(w.at, point, run);
        else
            active = false;
    }
}
