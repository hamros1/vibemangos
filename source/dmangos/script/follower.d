/**
 * A follower: a creature that follows a player on a quest (a lost kitten, a sleepwalking druid, a
 * runaway shredder) until the script says it is home. Like `Escort` it is a component, a field of the
 * script ticked with it: started with a player and a quest, it follows the player (taking its NPC
 * flags away, and a faction if one is given), goes when the player dies or is more than 100 yards
 * away (failing the quest if it was the player's to do), and after `complete` stands, or goes.
 */
module dmangos.script.follower;

import dmangos.script.api;

/// See the module documentation.
struct Follower
{
    EntityRef player;        /// whom it follows
    uint quest;              /// the quest that fails if it is lost
    bool active;
    bool paused;             /// it stands where it is for a while (an event of its script)
    bool completed;          /// it reached what it followed the player for
    int checkLeft;           /// ms to its next look for the player
    float maxDistance = 100; /// the player farther than this: lost
    uint despawnAfterMs = 0; /// complete (and not kept for a scene of its script), it goes this long after

    /// Starts following `player` on `quest`; `faction` (0: its own) until it respawns.
    void start(ref CreatureContext me, EntityRef player, uint quest, uint faction = 0)
    {
        const distance = maxDistance, despawn = despawnAfterMs;
        this = Follower.init;
        maxDistance = distance;
        despawnAfterMs = despawn;
        this.player = player;
        this.quest = quest;
        active = true;
        checkLeft = 1000;
        if (faction)
            me.setFaction(faction);
        me.npcFlags(0);
        me.follow(player);
    }

    /// It is where it was led: it stops following; `stay` keeps it for its script's scene, otherwise
    /// it goes after `despawnAfterMs`.
    void complete(ref CreatureContext me, bool stay = false)
    {
        if (!active)
            return;
        active = false;
        completed = true;
        me.follow(EntityRef.init);
        if (!stay)
            me.despawn(despawnAfterMs ? despawnAfterMs : 1);
    }

    /// It stands for a while (`true`), or follows on (`false`).
    void pause(ref CreatureContext me, bool on)
    {
        if (!active || paused == on)
            return;
        paused = on;
        me.follow(on ? EntityRef.init : player);
    }

    /// Lost: the quest fails (if still under way) and it goes.
    void fail(ref CreatureContext me)
    {
        if (!active)
            return;
        active = false;
        if (quest && me.questStatus(player, quest) == QuestProgress.incomplete)
            me.failQuest(player, quest);
        me.despawn(1);
    }

    /// Ticked with its script: once a second, whether the player is still there.
    void tick(ref CreatureContext me, int ms)
    {
        if (!active || me.inCombat)
            return;
        checkLeft -= ms;
        if (checkLeft > 0)
            return;
        checkLeft = 1000;
        if (!me.alive(player) || me.distanceTo(player) > maxDistance)
            fail(me);
    }

    /// Whether it needs ticks.
    @property bool busy() const
    {
        return active;
    }
}
