/**
 * Game objects used up and coming back (`WorldContext.objectRespawns`): a dungeon's reward chest and an outdoor
 * chest checkpointed as opened or still unopened and restored so after a crash or handoff; a used-up object's
 * respawn time (`gameobject_respawn`); the objects and pool rolls that come due each update.
 */
module dmangos.world.objectrespawns;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.gameobjectpools : GameObjectPools;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart, UpdateValues;
import dmangos.world.map : Map;
import dmangos.world.database : DungeonFightCheckpoint, InstanceChestRecord, InstanceCorpseRecord, PickpocketRecord,
    QuestActorCheckpoint, WorldDatabase;
import dmangos.world.worlddata : EventCreature, EventMail, PoolMember, Ship, SpawnGroupCondition, SpellListEntry, WorldData;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class ObjectRespawns
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// Game objects used up: spawn guid -> when they come back (Unix time), as `gameobject_respawn` has it.
    package long[uint] gameObjectRespawnAt;
    package GameObjectPools gameObjectPools;
    package InstanceChestRecord[uint] outdoorChests;

    /// Persistent rewards are one-shot dungeon chest spawns with no gathering refills.
    package bool isInstanceReward(const GameObject go)
    {
        import dmangos.world.gameobject : GameObjectType;

        return go.instanceId in world.dungeons.instances && go.spawn.guid < temporaryCounterStart
            && go.type == GameObjectType.chest && go.consumable && go.spawn.respawnSeconds < 0
            && !go.template_.data[4] && !go.template_.data[5];
    }

    package bool canCheckpointChest(const GameObject go)
    {
        if (go.instanceId)
            return isInstanceReward(go);
        if (!world.config.cluster.enabled || go.spawn.guid >= temporaryCounterStart || go.type != GameObjectType.chest
            || !go.consumable || go.spawn.guid in world.spawnEditor.unsavedGameObjectSpawns)
            return false;
        if (go.spawn.respawnSeconds < 0)
            return world.recovery.durableScriptedSpawn(go.spawn, *go.template_)
                && WorldContext.GameObjectOnMap(world.existingMap(go.spawn.map), go.guid) in world.scriptedGameObjects;
        return gameObjectPools.manages(go.spawn.guid)
            || world.data.pools is null || !world.data.pools.inPool(PoolMember.Kind.gameObject, go.spawn.guid);
    }

    package void saveOpenedChest(Map map, GameObject go)
    {
        if (!canCheckpointChest(go))
            return;
        if (!go.instanceId)
            world.deadCreatures.saveOutdoorLootPositions(map, go.loot);
        world.database.saveInstanceChest(checkpointReward(map, go));
    }

    package void saveRefilledChest(Map map, GameObject go)
    {
        if (!go.instanceId && go.spawn.guid in outdoorChests)
            world.database.saveInstanceChest(checkpointReward(map, go));
    }

    package InstanceChestRecord checkpointReward(Map map, GameObject go,
        const imported!"dmangos.world.loot".LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.instancescripting : toHex;

        if (!go.instanceId)
        {
            import std.algorithm.comparison : min;

            const visibleUntil = world.scriptedGameObjects.get(WorldContext.GameObjectOnMap(map, go.guid), long.max);
            ByteWriter w;
            go.saveState(w, world.fleet.transportNow(), 0, claimed, looter);
            const previous = outdoorChests.get(go.spawn.guid, InstanceChestRecord.init);
            const openedUntil = go.despawnTimer > 0 ? world.unixTime + (go.despawnTimer + 999L) / 1000 : 0;
            auto record = InstanceChestRecord(0, go.spawn.guid,
                min(visibleUntil, openedUntil && previous.expiresAt ? previous.expiresAt : openedUntil), toHex(w.data));
            outdoorChests[go.spawn.guid] = record;
            return record;
        }
        auto state = go.instanceId in world.dungeons.instances;
        if (state is null)
            return InstanceChestRecord.init;
        const now = world.unixTime;
        const visibleUntil = world.scriptedGameObjects.get(WorldContext.GameObjectOnMap(map, go.guid), long.max);
        const openedUntil = now + (go.despawnTimer + 999) / 1000;
        const previous = state.chests.get(go.spawn.guid, InstanceChestRecord.init);
        ByteWriter w;
        w.put(ubyte(1));
        go.loot.saveHandoff(w, claimed, looter);
        auto record = InstanceChestRecord(go.instanceId, go.spawn.guid,
            previous.loot.length ? previous.expiresAt : visibleUntil < openedUntil ? visibleUntil : openedUntil,
            toHex(w.data));
        state.chests[go.spawn.guid] = record;
        return record;
    }

    package void rememberUnopenedReward(GameObject go, long deadline)
    {
        if (!isInstanceReward(go))
            return;
        auto record = InstanceChestRecord(go.instanceId, go.spawn.guid, deadline, null);
        world.dungeons.instances[go.instanceId].chests[go.spawn.guid] = record;
        world.database.saveInstanceChest(record);
    }

    package bool restoreReward(GameObject go, const ref InstanceChestRecord reward)
    {
        import dmangos.bytes : ByteReader, PacketException;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GoLootState;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.loot : Loot;
        import std.algorithm.searching : all;

        const remaining = reward.expiresAt - world.unixTime;
        if (remaining <= 0 || !isInstanceReward(go))
            return false;
        if (!reward.loot.length)
        {
            world.scriptedGameObjects[WorldContext.GameObjectOnMap(world.dungeons.instanceMaps[go.instanceId], go.guid)] = reward.expiresAt;
            return true;
        }
        auto r = ByteReader(fromHex(reward.loot));
        try
        {
            if (r.read!ubyte != 1)
                throw new PacketException("unknown instance reward version");
            auto loot = Loot.loadHandoff(go.guid, r);
            if (!loot.gold && loot.items.all!(item => item.allowed.length == 0))
                return false;
            go.loot = loot;
            go.lootState = GoLootState.activated;
            go.despawnTimer = cast(int)(remaining > int.max / 1000 ? int.max : remaining * 1000);
            world.migrants.bindMigrantLoot(go, world.dungeons.instanceMaps[go.instanceId]);
            return true;
        }
        catch (PacketException e)
        {
            warning!"could not restore reward chest %s of instance %s: %s"(reward.spawn, reward.instance, e.msg);
            return false;
        }
    }

    package void restoreOutdoorChest(GameObject go, const ref InstanceChestRecord chest)
    {
        import dmangos.log : warning;
        import dmangos.world.instancescripting : fromHex;

        if (!canCheckpointChest(go))
            return;
        try
        {
            auto bytes = ByteReader(fromHex(chest.loot));
            go.loadState(bytes, world.fleet.transportNow());
            if (chest.expiresAt && chest.expiresAt <= world.unixTime)
            {
                go.loot = null;
                go.lootState = GoLootState.justDeactivated;
                return;
            }
            if (go.loot is null)
                return;
            go.despawnTimer = cast(int)((chest.expiresAt - world.unixTime) * 1000);
            world.migrants.bindMigrantLoot(go, world.existingMap(go.spawn.map));
            if (go.lootState == GoLootState.activated && go.loot.lootedForEveryone())
                go.loot.lootedForAll();
            else
                go.loot.resumeRemoteRolls();
        }
        catch (Exception error)
            warning!"map %s: could not restore outdoor chest %s: %s"(go.spawn.map, chest.spawn, error.msg);
    }

    /// A game object used up: it comes back after its spawn's respawn time.
    package void gameObjectUsedUp(GameObject go)
    {
        if (go.spawn.guid >= temporaryCounterStart)
            return;
        if (go.instanceId)
        {
            if (auto state = go.instanceId in world.dungeons.instances)
            {
                state.usedUp[go.spawn.guid] = true;
                if (auto copy = world.battlegrounds.find(go.instanceId))
                    return copy.objectiveChanged();
                world.database.saveInstanceRespawn(true, go.spawn.guid, go.instanceId,
                    state.resetAt ? state.resetAt : world.unixTime + 86_400);
            }
            return;
        }
        if (go.spawn.respawnSeconds < 0)
            return;
        const at = outdoorObjectRespawnDeadline(go);
        const hadChest = outdoorChests.remove(go.spawn.guid);
        if (gameObjectPools.manages(go.spawn.guid))
            return gameObjectPools.exhausted(go.spawn.guid, at, hadChest);
        gameObjectRespawnAt[go.spawn.guid] = at;
        if (hadChest)
            world.database.finishOutdoorChest(go.spawn.guid, at);
        else
            world.database.saveGameObjectRespawn(go.spawn.guid, at);
    }

    package long outdoorObjectRespawnDeadline(const GameObject go)
    {
        const saved = go.spawn.guid in outdoorChests;
        const finished = saved !is null && saved.expiresAt && saved.expiresAt < world.unixTime ? saved.expiresAt : world.unixTime;
        return finished + (go.spawn.respawnSeconds > 0 ? go.spawn.respawnSeconds : 0);
    }

    /// Whether a game object spawn is used up and waiting to come back.
    bool gameObjectAwaitingRespawn(uint spawnGuid)
    {
        if (gameObjectPools.manages(spawnGuid))
            return gameObjectPools.waiting(spawnGuid);
        if (auto at = spawnGuid in gameObjectRespawnAt)
            return *at > world.unixTime;
        return false;
    }

    /// The game objects whose time has come, made anew where their cell is loaded.
    package void gameObjectsDue()
    {
        const time = world.unixTime;
        gameObjectPoolsDue(time);
        uint[] due;
        foreach (guid, at; gameObjectRespawnAt)
            if (at <= time)
                due ~= guid;
        if (due.length)
            world.indexSpawns();
        foreach (guid; due)
        {
            const index = guid in world.gameObjectSpawnIndex;
            const spawn = index is null ? null : &world.data.gameObjectSpawns[*index];
            gameObjectRespawnAt.remove(guid);
            if (world.ownsCell !is null && (spawn is null || !world.ownsCell(spawn.map, cellKeyAt(spawn.x, spawn.y))))
                continue;
            world.database.saveGameObjectRespawn(guid, 0);
            if (spawn is null)
                continue;
            if (!world.rerolledBack(PoolMember.Kind.gameObject, guid, (uint member) {
                    if (const i = member in world.gameObjectSpawnIndex)
                    {
                        gameObjectRespawnAt[member] = time + world.data.gameObjectSpawns[*i].respawnSeconds;
                        world.database.saveGameObjectRespawn(member, gameObjectRespawnAt[member]);
                    }
                }))
                continue;
            auto there = world.existingMap(spawn.map);
            if (there !is null && there.cellLoaded(cellKeyAt(spawn.x, spawn.y)))
                there.addObject(world.makeGameObject(*spawn));
        }
    }

    package uint[uint] rollsInDoubt; // pool -> the placement a refused roll kept (`gameObjectPoolsDue`)

    package void gameObjectPoolsDue(long time)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.database : GameObjectPoolPlacement, GameObjectPoolState;

        if (!gameObjectPools.refresh())
            return;
        // A roll that kept its placement whose answer was lost reads as refused, though it committed: the saved
        // selection, read again, says so, and the object comes back now rather than when its cell next loads.
        foreach (pool, kept; rollsInDoubt)
            if (const state = pool in gameObjectPools.states())
                if (state.placements.canFind!(slot => slot.spawn == kept && !slot.due))
                    if (const spawn = world.gameObjectSpawnOf(kept))
                    {
                        const home = cellKeyAt(spawn.x, spawn.y);
                        auto where = world.existingMap(spawn.map);
                        if (where !is null && where.cellLoaded(home) && (world.ownsCell is null || world.ownsCell(spawn.map, home))
                            && where.gameObjectAt(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid)) is null)
                            if (auto object = world.spawnWorldGameObject(*spawn))
                                where.addObject(object);
                    }
        rollsInDoubt = null;
        foreach (pool, state; gameObjectPools.states())
            foreach (i, slot; state.placements)
            {
                if (!slot.due || slot.due > time)
                    continue;
                const spawn = world.gameObjectSpawnOf(slot.spawn);
                if (spawn is null)
                    continue;
                const home = cellKeyAt(spawn.x, spawn.y);
                if (world.ownsCell !is null && !world.ownsCell(spawn.map, home))
                    continue;
                const next = world.gameObjectSpawnOf(gameObjectPools.roll(pool, slot.spawn, state, world.spawnRandom));
                if (next is null)
                    continue;
                const due = next.guid == slot.spawn ? 0 : time + next.respawnSeconds;
                auto placements = state.placements.dup;
                placements[i] = GameObjectPoolPlacement(next.guid, due);
                const selection = GameObjectPoolState(state.revision, placements);
                if (!gameObjectPools.change(pool, selection))
                {
                    if (!due)
                        rollsInDoubt[pool] = next.guid;
                    continue;
                }
                if (!due)
                    if (auto where = world.existingMap(spawn.map))
                        if (where.cellLoaded(home))
                            if (auto object = world.spawnWorldGameObject(*spawn))
                                where.addObject(object);
                break;
            }
    }
}
