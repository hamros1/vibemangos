/**
 * Objects moving to another node with a region (docs/CLUSTER.md): what their last owner
 * writes (`encodeBundle`) and their next owner reads (`decodeBundle`). A bundle lists the region's
 * cells the old owner had loaded, and every object homed there with its kind, spawn, home cell and
 * state (`Creature.saveState`, `GameObject.saveState`): the new owner rebuilds each from its spawn
 * and loads the state, so the creature goes on where it was, as it was.
 */
module dmangos.world.migration;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart, UpdateValues;
import dmangos.world.loot : Loot, LootItem, maxLootItems;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings, VisibilityFacts;
import dmangos.world.context : WorldContext;


/// What kind of object a migrant is.
enum MigrantKind : ubyte
{
    none = 0,     /// not carried
    creature = 1,
    gameObject = 2,
    creatureRespawn = 3,   /// a timer, potentially with no live object in the bundle
    gameObjectRespawn = 4, /// ditto
    summonedCreature = 5,  /// a temporary spawn with its own placement and lifetime
    summonedGameObject = 6, /// a temporary unowned object and its placement
    scriptRun = 7,          /// an outdoor database script anchored to a home cell
}

/// An object on its way to its next owner.
struct Migrant
{
    MigrantKind kind;
    uint spawn;          /// its saved spawn or temporary GUID counter
    ulong home;          /// the cell it spawned in
    const(ubyte)[] state;
}

/// See the module documentation.
const(ubyte)[] encodeBundle(const(ulong)[] cells, const(Migrant)[] objects)
{
    ByteWriter w;
    w.put(cast(uint) cells.length);
    foreach (cell; cells)
        w.put(cell);
    w.put(cast(uint) objects.length);
    foreach (ref m; objects)
    {
        w.put(cast(ubyte) m.kind);
        w.put(m.spawn);
        w.put(m.home);
        w.put(cast(uint) m.state.length);
        w.putBytes(m.state);
    }
    return w.data;
}

/// See `encodeBundle`.
void decodeBundle(const(ubyte)[] bytes, out ulong[] cells, out Migrant[] objects)
{
    auto r = ByteReader(bytes);
    // Each count is checked against the bytes left before anything is allocated (a peer's frame).
    const cellCount = r.read!uint;
    r.ensureAvailable(cellCount * ulong.sizeof);
    cells = new ulong[cellCount];
    foreach (ref cell; cells)
        cell = r.read!ulong;
    const objectCount = r.read!uint;
    r.ensureAvailable(objectCount * (ubyte.sizeof + uint.sizeof + ulong.sizeof + uint.sizeof));
    objects = new Migrant[objectCount];
    foreach (ref m; objects)
    {
        m.kind = cast(MigrantKind) r.read!ubyte;
        m.spawn = r.read!uint;
        m.home = r.read!ulong;
        m.state = r.readBytes(r.read!uint).dup;
    }
}

/**
 * How this node saves the objects that leave it and makes the ones that come (`WorldContext.migrants`): a creature,
 * a player's summon or a game object saved as a `Migrant`, and one made again on its new map or dungeon copy, with
 * its loot and expiry.
 */
final class MigrantKeeper
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// An object's state for its next owner; kind 0 for one that does not move (a player's corpse stays with its player).
    Migrant saveMigrant(MapObject object)
    {
        if (auto creature = cast(Creature) object)
            if (creature.meleeController || creature.totemOwner)
                return Migrant.init; // controlled creatures follow their owner's rules
        return saveMigratingObject(object);
    }

    package Migrant savePlayerSummon(Creature creature, bool departing)
    {
        if (!(creature.guardianOwner || creature.totemOwner) || creature.summon.type == TempSpawnType.none
            || creature.spawn.guid < temporaryCounterStart)
            return Migrant.init;
        auto migrant = saveMigratingObject(creature, departing, carryImpacts: departing);
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        return migrant;
    }

    package Migrant saveMigratingObject(MapObject object, bool departing = true,
        const LootItem claimed = null, ulong looter = 0, long expiresOverride = 0, bool carryImpacts = true,
        scope const uint* factionOverride = null)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.serialization : serialize;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        ByteWriter w;
        if (auto creature = cast(Creature) object)
        {
            if (departing && creature.loot !is null)
                creature.loot.sendReleaseForAll();
            const now = world.fleet.transportNow();
            auto kind = MigrantKind.creature;
            if (creature.spawn.guid >= temporaryCounterStart && creature.summon.type != TempSpawnType.none)
            {
                kind = MigrantKind.summonedCreature;
                serialize(w, creature.spawn);
                serialize(w, creature.summon);
                w.put(now);
            }
            ByteWriter state;
            creature.saveState(state, now, claimed, looter, factionOverride);
            w.put(cast(uint) state.data.length);
            w.putBytes(state.data);
            if (carryImpacts)
                world.remoteSpells.writeReplicaImpacts(creature.guid, w, departing);
            else
                w.put(0u);
            if (departing)
                creature.ai.detachGroundHandoff();
            return Migrant(kind, creature.spawn.guid, 0, w.data);
        }
        auto gameObject = cast(GameObject) object;
        if (gameObject is null)
            return Migrant.init;
        if (gameObject.owner && (gameObject.type == GameObjectType.fishingNode
            || gameObject.type == GameObjectType.summoningRitual || gameObject.type == GameObjectType.trap))
            return Migrant.init; // follows its player's handoff
        if (departing && gameObject.loot !is null)
            gameObject.loot.sendReleaseForAll();
        long expires = expiresOverride;
        if (!gameObject.instanceId && !expires)
            if (auto active = world.existingMap(gameObject.spawn.map))
                expires = world.scriptedGameObjects.get(WorldContext.GameObjectOnMap(active, gameObject.guid), 0L);
        auto kind = MigrantKind.gameObject;
        if ((gameObject.instanceId || expires) && !gameObject.owner && gameObject.spawn.guid >= temporaryCounterStart)
        {
            kind = MigrantKind.summonedGameObject;
            serialize(w, gameObject.spawn);
        }
        gameObject.saveState(w, world.fleet.transportNow(), expires);
        return Migrant(kind, gameObject.spawn.guid, 0, w.data);
    }

    package Creature restorePlayerSummon(Map destination, const ref Migrant migrant, ulong owner)
    {
        import dmangos.serialization : deserialize;
        import dmangos.world.migration : MigrantKind;

        if (migrant.kind != MigrantKind.summonedCreature)
            return null;
        auto reader = ByteReader(migrant.state);
        deserialize!CreatureSpawn(reader);
        const summon = deserialize!TempSpawn(reader);
        const elapsed = cast(int) (world.fleet.transportNow() - reader.read!uint);
        if (summon.summoner != owner || (summon.timed && summon.timer <= elapsed))
            return null;
        return cast(Creature) restoreWorldMigrant(migrant, destination);
    }

    /// An object rebuilt from its spawn and the state its last owner sent; null if the spawn is unknown here.
    MapObject restoreMigrant(const ref Migrant m)
    {
        return restoreMigrantInInstance(m, 0);
    }

    package MapObject restoreMigrantInInstance(const ref Migrant m, uint instance)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        world.indexSpawns();
        auto r = ByteReader(m.state);
        if (m.kind == MigrantKind.creature)
        {
            const at = m.spawn in world.spawnIndex;
            if (at is null)
                return null;
            auto creature = world.makeCreature(&world.data.creatureSpawns[*at]);
            if (creature is null)
                return null;
            loadMigrantCreature(creature, instance, world.fleet.transportNow(), r);
            return creature;
        }
        const at = m.spawn in world.gameObjectSpawnIndex;
        if (at is null)
        {
            warning!"migration: game object spawn %s is not known here"(m.spawn);
            return null;
        }
        auto gameObject = world.makeGameObject(world.data.gameObjectSpawns[*at]);
        gameObject.loadState(r, world.fleet.transportNow());
        return gameObject;
    }

    package void loadMigrantCreature(Creature creature, uint instance, uint now, ref ByteReader reader)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        auto state = ByteReader(reader.readBytes(reader.read!uint));
        creature.instanceId = instance;
        creature.loadState(state, now, &world.spellInfo, world.data.waypoints);
        creature.factionTemplate = world.client.factionTemplates.lookup(creature.values.get!UNIT_FIELD_FACTIONTEMPLATE);
        world.remoteSpells.readReplicaImpacts(creature.guid, creature.spawn.map, instance, reader);
    }

    /// A region may bring a saved GM spawn created after this node loaded its world data.
    package MapObject restoreWorldMigrant(const ref Migrant migrant, Map destination)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.serialization : deserialize;
        import dmangos.world.migration : MigrantKind;

        world.indexSpawns();
        const durable = migrant.spawn < temporaryCounterStart;
        bool atHome(uint mapId, float x, float y, float z)
        {
            return mapId == destination.id && world.client.isValidMapCoord(mapId, x, y, z) && cellKeyAt(x, y) == migrant.home;
        }
        if (migrant.kind == MigrantKind.summonedGameObject)
        {
            auto state = ByteReader(migrant.state);
            const spawn = deserialize!GameObjectSpawn(state);
            const template_ = spawn.entry in world.data.gameObjectTemplates;
            if (durable || migrant.spawn > 0xFF_FFFF || spawn.guid != migrant.spawn
                || template_ is null || template_.type == GameObjectType.moTransport
                || !atHome(spawn.map, spawn.x, spawn.y, spawn.z)
                || !world.client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z, spawn.orientation))
                return null;
            auto restored = world.makeGameObject(spawn);
            restored.instanceId = destination.instanceId;
            restored.loadState(state, world.fleet.transportNow());
            if (!registerMigratedExpiry(restored, destination, !destination.instanceId))
                return null;
            bindMigrantLoot(restored, destination);
            return restored;
        }
        if (migrant.kind == MigrantKind.summonedCreature)
        {
            auto state = ByteReader(migrant.state);
            const spawn = deserialize!CreatureSpawn(state);
            const summon = deserialize!TempSpawn(state);
            const now = world.fleet.transportNow();
            const transit = cast(int)(now - state.read!uint);
            if (durable || migrant.spawn > 0xFF_FFFF || spawn.guid != migrant.spawn
                || spawn.entry !in world.data.creatureTemplates || summon.type > TempSpawnType.timedOutOfCombatOrCorpse
                || !atHome(spawn.map, spawn.x, spawn.y, spawn.z)
                || !world.client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z, spawn.orientation))
                return null;
            auto restored = world.makeCreature(&spawn);
            if (restored is null)
                return null;
            restored.summon = summon;
            loadMigrantCreature(restored, destination.instanceId, now, state);
            if (transit > 0)
                restored.summon.update(restored, transit);
            bindMigrantLoot(restored, destination);
            return restored;
        }
        try
        {
            if (durable && migrant.kind == MigrantKind.creature && migrant.spawn !in world.spawnIndex)
            {
                const saved = world.database.savedCreatureSpawn(migrant.spawn);
                if (saved.isNull || saved.get.entry !in world.data.creatureTemplates
                    || !atHome(saved.get.map, saved.get.x, saved.get.y, saved.get.z))
                    return null;
                world.spawnEditor.registerCreatureSpawn(saved.get);
            }
            else if (durable && migrant.kind == MigrantKind.gameObject && migrant.spawn !in world.gameObjectSpawnIndex)
            {
                const saved = world.database.savedGameObjectSpawn(migrant.spawn);
                if (saved.isNull || !atHome(saved.get.map, saved.get.x, saved.get.y, saved.get.z))
                    return null;
                const template_ = saved.get.entry in world.data.gameObjectTemplates;
                if (template_ is null || template_.type == GameObjectType.moTransport)
                    return null;
                world.spawnEditor.registerGameObjectSpawn(saved.get);
                if (template_.type == GameObjectType.transport)
                    world.fleet.refreshElevatorHomes(destination);
            }
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not load the saved spawn %s: %s"(migrant.spawn, error.msg);
            return null;
        }
        if (durable && migrant.kind == MigrantKind.gameObject)
            if (const index = migrant.spawn in world.gameObjectSpawnIndex)
            {
                const previous = &world.data.gameObjectSpawns[*index];
                const placement = GameObject.migrantPlacement(*previous, migrant.state);
                if (!atHome(placement.map, placement.x, placement.y, placement.z)
                    || !world.client.isValidMapCoord(placement.map, placement.x, placement.y, placement.z, placement.orientation))
                    return null;
                if (placement != *previous)
                {
                    world.spawnEditor.replaceGameObjectSpawn(*index, placement);
                    if (const template_ = placement.entry in world.data.gameObjectTemplates)
                        if (template_.type == GameObjectType.transport)
                            world.fleet.refreshElevatorHomes(destination);
                }
            }
        auto restored = restoreMigrantInInstance(migrant, destination.instanceId);
        if (auto go = cast(GameObject) restored)
        {
            go.instanceId = destination.instanceId;
            if (!registerMigratedExpiry(go, destination, false))
                return null;
        }
        bindMigrantLoot(restored, destination);
        return restored;
    }

    package bool registerMigratedExpiry(GameObject go, Map destination, bool requiresExpiry)
    {
        const at = go.carriedExpiry;
        if (at > world.unixTime)
        {
            world.scriptedGameObjects[WorldContext.GameObjectOnMap(destination, go.guid)] = at;
            return true;
        }
        if (!at && !requiresExpiry)
            return true;
        world.scripts.destroy(go.behaviour);
        return false;
    }

    package void bindMigrantLoot(MapObject restored, Map destination)
    {
        import dmangos.world.gameobjecthandlers : bindChestLoot;
        import dmangos.world.loothandlers : bindCreatureLoot, bindLootDelivery;
        import dmangos.world.loot : Loot, LootRule;

        Loot loot;
        if (auto chest = cast(GameObject) restored)
        {
            if ((loot = chest.loot) !is null)
                bindChestLoot(world, destination, chest, loot);
        }
        else if (auto creature = cast(Creature) restored)
        {
            if ((loot = creature.loot) !is null)
                bindCreatureLoot(world, destination, creature, loot);
        }
        if (loot !is null)
        {
            if (loot.rule != LootRule.notGroup || loot.checkpoint !is null)
                bindLootDelivery(world, destination, loot,
                    loot.rule == LootRule.groupLoot || loot.rule == LootRule.needBeforeGreed, loot.rule == LootRule.masterLoot);
            loot.resumeQuestLootChecks(destination.id, world.sendQuestLootCheck);
        }
    }
}

unittest
{
    const objects = [Migrant(MigrantKind.creature, 89, 7, [1, 2, 3]), Migrant(MigrantKind.gameObject, 4, 8, [])];
    ulong[] cells;
    Migrant[] back;
    decodeBundle(encodeBundle([7, 8, 9], objects), cells, back);
    assert(cells == [7, 8, 9] && back == objects);
}

// A bundle whose counts the bytes cannot hold is refused before anything is allocated.
unittest
{
    import std.exception : assertThrown;
    import dmangos.bytes : IncompletePacketException;

    ulong[] cells;
    Migrant[] objects;
    assertThrown!IncompletePacketException(decodeBundle([0xFF, 0xFF, 0xFF, 0x7F], cells, objects));
    assertThrown!IncompletePacketException(decodeBundle([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F], cells, objects));
}
