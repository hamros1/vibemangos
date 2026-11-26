/// Versions of world catalog rows that a GM can change while workers are online.
module dmangos.world.worldcatalog;

import dmangos.mysql : MySqlConnection;

enum WorldCatalog : ubyte
{
    vendor = 1,
    questStarter,
    questFinisher,
    creatureScale,
    teleports,
    quests,
    trainer,
}

struct WorldCatalogKey
{
    WorldCatalog catalog;
    uint entry;
}

struct WorldCatalogVersion
{
    WorldCatalogKey key;
    ulong revision;
    bool pending;
}

/// World data can be shared by several realms. Keep the revisions beside those rows.
struct WorldCatalogJournal
{
    private MySqlConnection world;
    private bool ready;

    this(MySqlConnection world)
    {
        this.world = world;
    }

    private void prepare()
    {
        if (ready)
            return;
        world.execute!("CREATE TABLE IF NOT EXISTS dmangos_world_catalog ("
            ~ "catalog TINYINT UNSIGNED NOT NULL, entry INT UNSIGNED NOT NULL, revision BIGINT UNSIGNED NOT NULL, "
            ~ "pending INT UNSIGNED NOT NULL DEFAULT 0, "
            ~ "PRIMARY KEY (catalog, entry)) ENGINE=InnoDB")();
        ready = true;
    }

    WorldCatalogVersion[] current()
    {
        prepare();
        WorldCatalogVersion[] versions;
        foreach (row; world.query!"SELECT catalog, entry, revision, pending FROM dmangos_world_catalog"())
        {
            const kind = cast(WorldCatalog) row.get!ubyte(0);
            if (kind >= WorldCatalog.min && kind <= WorldCatalog.max)
                versions ~= WorldCatalogVersion(WorldCatalogKey(kind, row.get!uint(1)), row.get!ulong(2),
                    row.get!uint(3) != 0);
        }
        return versions;
    }

    /// The original world tables use MyISAM. Workers keep watching an edit that was interrupted
    /// between changing its world row and recording completion. An update that fails is complete
    /// too: workers reload once for whatever it changed, then stop watching.
    void change(WorldCatalogKey key, scope void delegate() update = null)
    {
        prepare();
        const pending = update is null ? 0u : 1u;
        world.execute!("INSERT INTO dmangos_world_catalog (catalog, entry, revision, pending) VALUES (?, ?, 1, ?) "
            ~ "ON DUPLICATE KEY UPDATE revision = revision + 1, pending = pending + VALUES(pending)")(
                ubyte(key.catalog), key.entry, pending);
        if (update is null)
            return;
        try
            update();
        catch (Exception failure)
        {
            // Best effort: when the world database itself is gone, the edit stays pending as after a crash.
            try
                complete(key);
            catch (Exception)
            {
            }
            throw failure;
        }
        complete(key);
    }

    private void complete(WorldCatalogKey key)
    {
        world.execute!("UPDATE dmangos_world_catalog SET revision = revision + 1, pending = pending - 1 "
            ~ "WHERE catalog = ? AND entry = ? AND pending > 0")(ubyte(key.catalog), key.entry);
    }
}

/// Workers refresh saved GM edits without a peer message or a restart.
/**
 * What a node has loaded of the world catalogs: every five seconds (on a cluster member) the journal's versions are
 * read, and a catalog another node's staff changed is loaded again (`WorldCatalogJournal`).
 */
struct CatalogFollower
{
    import core.time : MonoTime;
    import dmangos.world.context : WorldContext;

    private MonoTime nextPoll;
    private ulong[WorldCatalogKey] loaded; // the revision loaded of each

    /// Each tick: the changed catalogs of `world` loaded again.
    void poll(WorldContext world, MonoTime now)
    {
        import core.time : seconds;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!world.config.cluster.nodeId || now < nextPoll)
            return;
        nextPoll = now + 5.seconds;
        try
        {
            foreach (ref version_; world.database.worldCatalogVersions())
            {
                const key = version_.key;
                if (!version_.pending && loaded.get(key, 0) == version_.revision)
                    continue;
                final switch (key.catalog)
                {
                case WorldCatalog.vendor:
                    world.data.npcs.vendors[key.entry] = world.database.loadVendorItems(key.entry);
                    break;
                case WorldCatalog.questStarter:
                    world.data.quests.creatureStarts[key.entry] = world.database.loadCreatureQuestRelations(true, key.entry);
                    break;
                case WorldCatalog.questFinisher:
                    world.data.quests.creatureEnds[key.entry] = world.database.loadCreatureQuestRelations(false, key.entry);
                    break;
                case WorldCatalog.creatureScale:
                    const scale = world.database.loadCreatureScale(key.entry);
                    if (!scale.isNull)
                        if (auto creature = world.data.creatureTemplates.edit(key.entry))
                            creature.scale = scale.get;
                    break;
                case WorldCatalog.teleports:
                    world.data.setTeleports(world.database.loadAreaTriggerTeleports(), world.database.loadTeleports(), world.client);
                    break;
                case WorldCatalog.quests:
                    world.data.quests = world.database.loadQuestCatalog();
                    break;
                case WorldCatalog.trainer:
                    world.data.npcs.trainers[key.entry] = world.database.loadTrainerLessons(key.entry, world.data.spells);
                    break;
                }
                loaded[key] = version_.revision;
            }
        }
        catch (DatabaseException error)
            warning!"world catalog updates will be retried: %s"(error.msg);
    }
}

unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper, itemJerky;
    import dmangos.world.worlddata : GameTele;

    auto db = newDatabase();
    auto first = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 1; });
    auto second = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 2; });
    auto now = MonoTime.currTime;
    first.update(now);
    second.update(now);
    const home = GameTele(-8949.95f, -132.49f, 83.53f, 0, 0, "CatalogTest");
    const npc = creatureInnkeeper;
    db.insertVendorItem(npc, itemJerky);
    db.insertQuestRelation(true, npc, 788);
    db.insertQuestRelation(false, npc, 789);
    db.updateCreatureScale(npc, 1.75f);
    db.addTeleport(home);

    now += 6.seconds;
    foreach (worker; [first, second])
    {
        worker.update(now);
        assert(worker.data.npcs.vendors[npc].length == 1 && worker.data.npcs.vendors[npc][0].item == itemJerky);
        assert(worker.data.quests.creatureStarts[npc] == [788u]);
        assert(worker.data.quests.creatureEnds[npc] == [789u]);
        assert(worker.data.creatureTemplates[npc].scale == 1.75f);
        assert(worker.data.teleports.length == 1 && worker.data.teleports[0] == home);
    }

    db.deleteVendorItem(npc, itemJerky);
    db.deleteQuestRelation(true, npc, 788);
    db.deleteQuestRelation(false, npc, 789);
    assert(db.deleteTeleport(home.name));
    auto restarted = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 3; });
    now += 6.seconds;
    foreach (worker; [first, second, restarted])
    {
        worker.update(now);
        assert(!worker.data.npcs.vendors[npc].length);
        assert(!worker.data.quests.creatureStarts[npc].length && !worker.data.quests.creatureEnds[npc].length);
        assert(!worker.data.teleports.length);
        assert(worker.data.creatureTemplates[npc].scale == 1.75f);
    }
}
