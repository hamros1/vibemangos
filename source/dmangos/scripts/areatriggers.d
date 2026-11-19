/**
 * Area triggers of the world (ScriptDevAI's world scripts) with a quest behind them: Miran and Huldar
 * ambushed on the road to the excavation, the Manor Ravenholdt, the Twilight Grove's corrupter, and
 * the Ancient Leaf's ancients.
 */
module dmangos.scripts.areatriggers;

import dmangos.script;

/**
 * The road to the Loch Modan excavation: walking there on "Resupplying the Excavation" (273) with
 * Miran and Huldar, the quest's event happens and Dark Iron ambushers (with Saean, if he is not there)
 * come for the player.
 */
@areaTrigger("at_huldar_miran")
struct HuldarMiranAmbush
{
    enum uint questResupplying = 273, saean = 1380, miran = 1379, huldar = 2057, ambusher = 1981;
    enum int sayAmbush = -1010029;

    void on(ref AreaTriggerContext road, const ref TriggerEntered e)
    {
        const status = road.questStatus(e.player, questResupplying);
        if (status != QuestProgress.incomplete)
            return;
        const miranRef = road.creatureNear(miran, e.at, 60), huldarRef = road.creatureNear(huldar, e.at, 60);
        if (!miranRef || !huldarRef)
            return;
        road.say(miranRef, sayAmbush);
        road.questEvent(e.player, questResupplying);
        road.consume();
        if (road.creatureNear(ambusher, e.at, 60))
            return; // ambushed already
        if (!road.creatureNear(saean, e.at, 60))
            road.summon(saean, Location(-5760.73f, -3437.71f, 305.54f, 2.41f), 25_000, e.player);
        road.summon(ambusher, Location(-5759.85f, -3441.29f, 305.57f, 2.24f), 25_000, e.player);
        road.summon(ambusher, Location(-5757.75f, -3437.61f, 304.32f, 2.56f), 25_000, e.player);
    }
}

/// The Manor Ravenholdt: reaching it on "The Manor, Ravenholdt" (6681) counts.
@areaTrigger("at_ravenholdt")
struct ManorRavenholdt
{
    enum uint questManorRavenholdt = 6681, ravenholdt = 13936;

    void on(ref AreaTriggerContext manor, const ref TriggerEntered e)
    {
        if (manor.questStatus(e.player, questManorRavenholdt) == QuestProgress.incomplete)
            manor.killCredit(e.player, ravenholdt);
    }
}

/**
 * The Twilight Grove: walking in on "The Nightmare's Corruption" (8735), the Twilight Corrupter comes
 * out (unless he is about) and calls the player.
 */
@areaTrigger("at_twilight_grove")
struct TwilightGrove
{
    enum uint questNightmareCorruption = 8735, twilightCorrupter = 15625;
    enum int saySpawn = -1000411;

    void on(ref AreaTriggerContext grove, const ref TriggerEntered e)
    {
        if (grove.questStatus(e.player, questNightmareCorruption) != QuestProgress.incomplete)
            return;
        if (grove.creatureNear(twilightCorrupter, e.at, 500))
            return;
        if (const corrupter = grove.summon(twilightCorrupter, Location(-10326.3f, -487.423f, 50.1127f, 5.73692f),
                30 * 60_000))
        {
            grove.say(corrupter, saySpawn, e.player);
            grove.consume();
        }
    }
}

/**
 * The Ancient Leaf's grove in Felwood: with "The Ancient Leaf" (7632) done, Vartus, Stoma and Hastat
 * the ancients come for five minutes (unless they are there).
 */
@areaTrigger("at_ancient_leaf")
struct AncientLeaf
{
    enum uint questAncientLeaf = 7632, vartus = 14524, stoma = 14525, hastat = 14526;

    void on(ref AreaTriggerContext grove, const ref TriggerEntered e)
    {
        if (grove.questStatus(e.player, questAncientLeaf) != QuestProgress.complete)
            return;
        if (grove.creatureNear(vartus, e.at, 50) || grove.creatureNear(stoma, e.at, 50)
                || grove.creatureNear(hastat, e.at, 50))
            return;
        grove.summon(vartus, Location(6204.051758f, -1172.575684f, 370.079224f, 0.86052f), 5 * 60_000);
        grove.summon(stoma, Location(6246.953613f, -1155.985718f, 366.182953f, 2.90269f), 5 * 60_000);
        grove.summon(hastat, Location(6193.449219f, -1137.834106f, 366.260529f, 5.77332f), 5 * 60_000);
    }
}

version (unittest)
{
    /// An event script for the tests of the kind (`@scriptedEvent`): a creature beside the player who started it.
    @scriptedEvent("event_test_summon")
    struct TestEventSummon
    {
        void on(ref EventContext c, const ref EventStarted e)
        {
            c.summon(imported!"dmangos.world.testdata".creatureTrainer, Location(-8945, -132, 83.5f), 60_000);
            c.consume();
        }
    }
}

// A scripted event reaches its script, around the player who started it; consumed, no database script follows.
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.map : MapObject;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.eventScriptNames[7777] = "event_test_summon";
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto map = context.map(0);
    size_t trainers()
    {
        size_t n;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.template_.entry == creatureTrainer)
                    ++n;
        });
        return n;
    }
    const before = trainers();
    context.scriptedEvent(7777, map, anduin.session.character.guid, 0);
    assert(trainers() == before + 1);
    context.scriptedEvent(7778, map, anduin.session.character.guid, 0); // no script: nothing, no harm
    assert(trainers() == before + 1);
}
