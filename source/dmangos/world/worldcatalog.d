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
    /// between changing its world row and recording completion.
    void change(WorldCatalogKey key, scope void delegate() update = null)
    {
        prepare();
        const pending = update is null ? 0u : 1u;
        world.execute!("INSERT INTO dmangos_world_catalog (catalog, entry, revision, pending) VALUES (?, ?, 1, ?) "
            ~ "ON DUPLICATE KEY UPDATE revision = revision + 1, pending = pending + VALUES(pending)")(
                ubyte(key.catalog), key.entry, pending);
        if (update !is null)
        {
            update();
            world.execute!("UPDATE dmangos_world_catalog SET revision = revision + 1, pending = pending - 1 "
                ~ "WHERE catalog = ? AND entry = ? AND pending > 0")(ubyte(key.catalog), key.entry);
        }
    }
}

/// Workers refresh saved GM edits without a peer message or a restart.
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
