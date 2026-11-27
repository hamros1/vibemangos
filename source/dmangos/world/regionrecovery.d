/**
 * What a cluster member does as regions move to and from it (`WorldContext.recovery`, docs/CLUSTER.md): what was
 * lost leaves its maps, what was gained loads; and what it keeps of the open world and dungeons for a crash and
 * brings back: outdoor quests' actors, outdoor and dungeon fights, scripted objects, corpses and chests, charms,
 * and respawn times.
 */
module dmangos.world.regionrecovery;

import dmangos.bytes : ByteReader;
import dmangos.cluster.regions : Region;
import dmangos.world.creature : Creature, CreatureSpawn, TempSpawnType;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType;
import dmangos.world.migration : Migrant, MigrantKind, encodeBundle;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart;
import dmangos.world.bgqueue : battlegroundOfMap;
import dmangos.script.api : EntityRef;
import dmangos.world.database : DungeonFightCheckpoint, InstanceChestRecord, InstanceCorpseRecord, PickpocketRecord,
    QuestActorCheckpoint, WorldDatabase;
import dmangos.world.map : Map, MapObject;
import dmangos.world.character : Character;
import dmangos.world.worlddata : PoolMember;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class RegionRecoverer
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /**
     * The cluster moved regions: what was lost leaves the maps, players near what was
     * gained see it load.
     */
    void regionsChanged(const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
        ref ubyte[][uint] leaving)
    {
        import dmangos.log : info;
        import dmangos.cluster.services : isServiceMap, serviceOfMap;
        import dmangos.world.migration : encodeBundle;
        import std.format : format;

        // Load additions before restoring live bundles or loading newly owned cells.
        world.discoverSavedSpawns(gained);
        forgetQuestActors(lost);
        foreach (ref r; lost)
            pendingRegionRecovery.remove(r.id);

        // Retire a returned creature before handing over any newly revoked physical home region.
        foreach (ref r; lost)
            if (r.creature.spawn)
                world.loans.creatureLoanLost(r);

        foreach (ref r; lost)
            if (world.dungeons.instanceable(r.map) || physicalWorldRegion(r))
                releaseRegionCharms(r);

        // A service's region (docs/SERVICES.md): it stops here, its state going along with it, or starts.
        foreach (ref r; lost)
            if (isServiceMap(r.map))
            {
                auto state = world.services.stop(serviceOfMap(r.map));
                if (r.next)
                    leaving[r.id] = state;
                info!"services: %s moves %s"(serviceOfMap(r.map), r.next ? format!"to node %s"(r.next) : "off");
            }
        foreach (ref r; gained)
            if (isServiceMap(r.map) && world.services.start(serviceOfMap(r.map), arriving.get(r.id, null)))
                info!"services: %s runs here"(serviceOfMap(r.map));

        // A dungeon's region: its copies' creatures and objects go along, copy by copy, before what was
        // known of the copies is forgotten here (the new host has read their rows by then).
        foreach (ref r; lost)
            if (world.dungeons.instanceable(r.map))
            {
                if (r.next)
                    leaving[r.id] = cast(ubyte[]) world.dungeons.dungeonCopiesOut(r.map, r.next);
                world.dungeons.dungeonLost(r.map);
            }
        foreach (ref r; gained)
            if (world.dungeons.instanceable(r.map))
            {
                world.dungeons.dungeonGained(r.map);
                if (auto copies = r.id in arriving)
                    world.dungeons.dungeonCopiesIn(r.map, *copies);
                if (battlegroundOfMap(r.map) && world.battlegroundMapEpoch !is null
                    && (world.battlegroup is null || world.battlegroup.host is world))
                    world.battlegrounds.recoverMap(r.map, (r.id in arriving) !is null);
            }
        foreach (ref r; lost)
            if (physicalWorldRegion(r))
            {
                auto timers = takeRegionRespawns(r);
                if (auto m = r.map in world.maps)
                {
                    timers ~= world.takeRegionScriptRuns(*m, r);
                    if (r.next) // moving to another node: its objects and timers go along
                    {
                        const before = m.objectCount - m.replicaCount;
                        leaving[r.id] = cast(ubyte[]) m.migrateOut((ulong cell) => r.rect.containsKey(cell), r.next,
                            &world.migrants.saveMigrant, timers);
                        info!"migration: region %s leaves for node %s with %s objects (%s KiB)"(r.id, r.next,
                            before - (m.objectCount - m.replicaCount), leaving[r.id].length / 1024);
                    }
                    else
                        m.release((ulong cell) => r.rect.containsKey(cell));
                }
                else if (r.next)
                    leaving[r.id] = cast(ubyte[]) encodeBundle(null, timers);
            }
        const editedSpawns = refreshSavedGameObjectPlacements(gained, arriving);
        bool recoveryRead = refreshRegionRespawns(gained, arriving);
        // Every arrival first: a map that looks around for gained cells would otherwise spawn afresh what is
        // still on its way in another region's bundle.
        foreach (ref r; gained)
            if (auto objects = r.id in arriving)
            {
                if (!physicalWorldRegion(r))
                    continue; // its copies' bundles, read above
                auto m = world.map(r.map);
                const before = m.objectCount - m.replicaCount;
                m.migrateIn(*objects, (const ref Migrant migrant) => restoreRegionMigrant(migrant, m, r));
                info!"migration: region %s arrived with %s objects"(r.id, m.objectCount - m.replicaCount - before);
            }
        foreach (index; editedSpawns)
        {
            const spawn = &world.data.gameObjectSpawns[index];
            if (auto m = world.existingMap(spawn.map))
            {
                const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
                if (auto live = m.gameObjectAt(guid))
                {
                    if (live.spawn == *spawn)
                        continue; // a clean bundle in the same batch already restored it
                    m.removeObject(guid);
                }
                const home = cellKeyAt(spawn.x, spawn.y);
                if (m.cellLoaded(home) && (world.ownsCell is null || world.ownsCell(spawn.map, home)))
                    if (auto object = world.spawnWorldGameObject(*spawn))
                        m.addObject(object);
            }
        }
        foreach (ref r; gained)
            if (r.creature.spawn)
                world.loans.creatureLoanGained(r, arriving.get(r.id, null));
        recoveryRead &= refreshOutdoorCorpses(gained, lost);
        recoveryRead &= refreshOutdoorChests(gained, lost);
        if (!recoveryRead)
            holdRegionRecovery(gained, arriving);
        queueQuestActorRecovery(gained, arriving);
        world.restoreOutdoorScripts(gained);
        bool[uint] looked;
        foreach (ref r; gained)
            if (r.map !in looked)
            {
                looked[r.map] = true;
                if (auto m = r.map in world.maps)
                    m.ownershipGained();
            }
    }

    package bool physicalWorldRegion(const ref Region region)
    {
        return !region.creature.spawn && world.client.maps.lookup(region.map) !is null && !world.dungeons.instanceable(region.map);
    }

    package bool outdoorRegionCovers(Spawn)(const(Spawn)* spawn, const(Region)[] regions)
    {
        import std.algorithm.searching : any;

        return regions.any!(r => physicalWorldRegion(r) && r.map == spawn.map
            && r.rect.containsKey(cellKeyAt(spawn.x, spawn.y)));
    }

    package QuestActorCheckpoint[ulong] outdoorQuestActors;
    package struct QuestActorRegionGrant
    {
        Region region;
        bool clean;
    }
    package QuestActorRegionGrant[uint] pendingQuestActorRegions;
    package long retryQuestActorRecoveryAt;

    /// A gained region whose corpses, chests or respawn timers could not be read yet (`retryRegionRecovery`).
    package struct RegionRecovery
    {
        Region region;
        bool clean; // its bundle arrived: only the database's corpses and chests are still to read
    }
    package RegionRecovery[uint] pendingRegionRecovery;
    package long retryRegionRecoveryAt;

    /**
     * Whether a gained cell waits for its region's recovery reads before it loads. Loaded first, the cell would
     * spawn afresh what the database still holds: an opened chest with new loot, a dead creature alive, an
     * escort's NPC without its escort (which the quest-actor recovery would then take for the escort's own).
     */
    package bool recoveryHolds(uint map, ulong cell) const
    {
        foreach (const ref pending; pendingRegionRecovery)
            if (pending.region.map == map && pending.region.rect.containsKey(cell))
                return true;
        foreach (const ref grant; pendingQuestActorRegions)
            if (!grant.clean && grant.region.map == map && grant.region.rect.containsKey(cell))
                return true;
        return false;
    }

    package void holdRegionRecovery(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        import dmangos.log : warning;

        foreach (ref region; gained)
            if (physicalWorldRegion(region))
                pendingRegionRecovery[region.id] = RegionRecovery(region, arriving.get(region.id, null).length != 0);
        retryRegionRecoveryAt = world.unixTime + 1;
        warning!"migration: %s gained region(s) wait to load until their corpses, chests and respawn timers are read"(
            pendingRegionRecovery.length);
    }

    /// Reads again what a gained region's recovery could not (`holdRegionRecovery`), then loads its cells.
    package void retryRegionRecovery()
    {
        import dmangos.log : info;

        if (!pendingRegionRecovery.length || world.unixTime < retryRegionRecoveryAt)
            return;
        Region[] all, cold;
        foreach (ref pending; pendingRegionRecovery)
        {
            all ~= pending.region;
            if (!pending.clean)
                cold ~= pending.region;
        }
        if (!syncColdRespawns(cold) || !refreshOutdoorCorpses(all, null) || !refreshOutdoorChests(all, null))
        {
            retryRegionRecoveryAt = world.unixTime + 1;
            return;
        }
        pendingRegionRecovery = null;
        info!"migration: %s gained region(s) read their corpses, chests and respawn timers and load now"(all.length);
        loadHeldCells(all);
    }

    /// Loads, near players and peers, the cells of `regions` that waited for their recovery.
    package void loadHeldCells(const(Region)[] regions)
    {
        bool[uint] looked;
        foreach (ref r; regions)
            if (r.map !in looked) // cells another recovery still holds stay as they are (`recoveryHolds`)
            {
                looked[r.map] = true;
                if (auto m = r.map in world.maps)
                    m.ownershipGained();
            }
    }

    package bool ownsQuestActor(const Creature creature)
    {
        return world.canWrite() && !creature.instanceId && !world.loans.creatureOnLoan(creature.spawn.guid)
            && (world.ownsCell is null || world.ownsCell(creature.spawn.map, cellKeyAt(creature.spawn.x, creature.spawn.y)));
    }

    package void discardQuestActor(const Creature creature)
    {
        if (const actor = creature.guid in outdoorQuestActors)
            if (ownsQuestActor(creature))
            {
                const owner = actor.player;
                if (auto player = world.onlinePlayer(owner))
                    player.saveQuests();
                outdoorQuestActors.remove(creature.guid);
                world.database.deleteQuestActor(world.config.realmId, creature.guid);
                if (!owner)
                    world.settleWrites();
            }
    }

    package void checkpointQuestActor(Map map, Creature creature, ulong player, bool immediate)
    {
        import dmangos.world.instancescripting : toHex;

        if (!creature.alive)
            return discardQuestActor(creature);
        if (!ownsQuestActor(creature))
            return;
        const previous = outdoorQuestActors.get(creature.guid, QuestActorCheckpoint.init);
        if (!player)
        {
            if (previous.player)
            {
                if (creature.summon.type != TempSpawnType.none || hasOutdoorFactionChange(creature))
                    checkpointOutdoorCreature(creature);
                else
                    discardQuestActor(creature);
            }
            return;
        }
        if (!immediate && previous.player == player && previous.savedAt + 2 > world.unixTime)
            return;
        auto root = world.migrants.saveMigratingObject(creature, false);
        root.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        Migrant[] actors = [root];
        foreach (child; map.creaturesNear(creature.position, 150))
            if (child.alive && child.summon.summoner == creature.guid && ownsQuestActor(child))
            {
                auto snapshot = world.migrants.saveMigratingObject(child, false);
                snapshot.home = cellKeyAt(child.spawn.x, child.spawn.y);
                actors ~= snapshot;
            }
        if (auto session = world.onlinePlayer(player))
            if (session.character !is null && session.currentMap is map && !session.transferring)
            {
                session.saveQuests();
                const progress = session.character.progress(session.secondsInWorld());
                world.database.saveProgress(progress);
            }
        const state = QuestActorCheckpoint(map.id, creature.guid, root.home, player, world.unixTime,
            toHex(encodeBundle(null, actors)));
        outdoorQuestActors[creature.guid] = state;
        world.database.saveQuestActor(world.config.realmId, state);
    }

    package void checkpointOutdoorFight(Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        if (creature.spawn.guid >= temporaryCounterStart || creature.summon.type != TempSpawnType.none
            || creature.ai is null || !creature.alive || !ownsQuestActor(creature) || controlledByPlayer(creature))
            return; // (held by a player: as `checkpointDungeonFight`)
        const saved = creature.guid in outdoorQuestActors;
        if (saved !is null && saved.player)
            return; // the active escort or follower also owns this creature's checkpoint
        if ((saved is null || !hasOutdoorFactionChange(creature)) && !creature.ai.inCombat
            && creature.values.get!UNIT_FIELD_HEALTH >= creature.values.get!UNIT_FIELD_MAXHEALTH)
            return discardQuestActor(creature);
        if (saved is null || saved.savedAt + 2 <= world.unixTime)
            checkpointOutdoorCreature(creature);
    }

    /// Whether a player charms or possesses `creature` (Mind Control, the Orb of Domination's Razorgore).
    package static bool controlledByPlayer(const Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_CHARMEDBY;

        return creature.petOwner || creature.meleeController || creature.values.get!UNIT_FIELD_CHARMEDBY != 0;
    }

    package static bool hasOutdoorFactionChange(const Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        return creature.summon.type == TempSpawnType.none
            && creature.values.get!UNIT_FIELD_FACTIONTEMPLATE != creature.template_.faction;
    }

    package struct ActiveDungeonFight
    {
        ulong guid;
        long savedAt;
    }
    package ActiveDungeonFight[uint][uint] dungeonFights;
    package bool[uint] pendingDungeonFights; // whether the map already has its live handoff bundle
    package long retryDungeonFightsAt;

    package bool ownsDungeonFights(Map where)
    {
        return world.config.cluster.enabled && where.instanceId && !battlegroundOfMap(where.id)
            && world.canWrite() && world.dungeons.hostsDungeon(where.id);
    }

    package void checkpointDungeonFight(Map where, Creature creature)
    {
        import dmangos.world.instancescripting : toHex;
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        const spawn = creature.spawn.guid, instance = where.instanceId;
        if (!ownsDungeonFights(where) || spawn >= temporaryCounterStart || creature.summon.type != TempSpawnType.none
            || creature.ai is null || !creature.alive)
            return;
        // Held by a player (charmed, possessed): its state now is the player's faction, flags and charm aura, which a
        // restore would bring back with no one holding it. Its last snapshot from before stays.
        if (controlledByPlayer(creature))
            return;
        const current = dungeonFights.get(instance, null);
        const tracked = spawn in current;
        if (auto script = world.instanceScripts.get(instance, null))
            if (script.keepsCheckpoint(EntityRef(creature.guid)))
            {
                if (tracked !is null)
                    discardDungeonFight(instance, spawn);
                return; // the encounter supplies the creature and its phase together
            }
        if (!creature.ai.inCombat && creature.values.get!UNIT_FIELD_HEALTH >= creature.values.get!UNIT_FIELD_MAXHEALTH)
        {
            if (tracked !is null)
                discardDungeonFight(instance, spawn);
            return;
        }
        if (tracked !is null && tracked.savedAt + 2 > world.unixTime)
            return;
        auto migrant = world.migrants.saveMigratingObject(creature, false);
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        dungeonFights[instance][spawn] = ActiveDungeonFight(creature.guid, world.unixTime);
        world.database.saveDungeonFight(instance, DungeonFightCheckpoint(spawn, toHex(encodeBundle(null, [migrant]))));
        if (tracked is null)
        {
            foreach (who; where.playersNow())
                if (auto session = cast(Character) who)
                {
                    const progress = who.character.progress(session.secondsInWorld());
                    world.database.saveProgress(progress);
                }
            world.settleWrites();
        }
    }

    package void discardDungeonFight(uint instance, uint spawn)
    {
        if (auto fights = instance in dungeonFights)
            if ((*fights).remove(spawn))
                world.database.deleteDungeonFight(instance, spawn);
    }

    package void restoreDungeonFights(Map where, bool clean)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.instancescripting : fromHex;

        const instance = where.instanceId;
        DungeonFightCheckpoint[] records;
        try
            records = world.database.loadDungeonFights(instance);
        catch (DatabaseException error)
        {
            warning!"instance %s: could not read native fights: %s"(instance, error.msg);
            pendingDungeonFights[instance] = clean;
            retryDungeonFightsAt = world.unixTime + 1;
            return;
        }
        pendingDungeonFights.remove(instance);
        ulong[] restored;
        foreach (ref saved; records)
        {
            const spawn = world.creatureSpawnOf(saved.spawn);
            if (spawn is null || spawn.map != where.id || world.dungeons.deadInInstance(instance, saved.spawn)
                || !world.calendar.creatureInEvents(saved.spawn) || !world.upInPool(PoolMember.Kind.creature, saved.spawn)
                || world.cantSpawnWhileBossDead(*spawn, instance in world.dungeons.instances))
            {
                world.database.deleteDungeonFight(instance, saved.spawn);
                continue;
            }
            const guid = makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
            if (auto script = instance in world.instanceScripts)
                if (script.restoringEntity(EntityRef(guid)))
                {
                    world.database.deleteDungeonFight(instance, saved.spawn);
                    continue; // the encounter's own snapshot carries this creature and its encounter state
                }
            if (clean)
            {
                if (auto creature = where.creatureAt(guid))
                {
                    dungeonFights[instance][saved.spawn] = ActiveDungeonFight(guid, world.unixTime - 2);
                    checkpointDungeonFight(where, creature);
                }
                else
                    world.database.deleteDungeonFight(instance, saved.spawn);
                continue;
            }
            if (saved.spawn in dungeonFights.get(instance, null))
                continue; // a new fight already superseded the checkpoint while the read was retried
            try
                where.migrateIn(fromHex(saved.state), (const ref Migrant migrant) {
                    if (migrant.kind != MigrantKind.creature || migrant.spawn != saved.spawn)
                        return null;
                    auto creature = cast(Creature) world.migrants.restoreWorldMigrant(migrant, where);
                    if (creature is null || !creature.alive)
                        return null;
                    waitForCombatPlayer(creature);
                    dungeonFights[instance][saved.spawn] = ActiveDungeonFight(guid, world.unixTime);
                    restored ~= guid;
                    return cast(MapObject) creature;
                });
            catch (Exception error)
                warning!"instance %s: could not restore creature %s: %s"(instance, saved.spawn, error.msg);
        }
        // Its cell skips a creature already back (`spawnCellIn`): the script learns it here, or it would hold no
        // reference to a boss that came back from his fight.
        if (auto script = world.instanceScripts.get(instance, null))
            foreach (guid; restored)
            {
                import dmangos.script.api : CreatureLoaded, EntityRef;

                script.raise(CreatureLoaded(EntityRef(guid)));
            }
    }

    package void updateDungeonFights()
    {
        if (pendingDungeonFights.length && world.unixTime >= retryDungeonFightsAt)
            foreach (instance; pendingDungeonFights.keys)
                if (auto where = world.dungeons.instanceMaps.get(instance, null))
                    if (ownsDungeonFights(where))
                        restoreDungeonFights(where, pendingDungeonFights[instance]);
        foreach (instance, ref active; dungeonFights)
            if (auto where = world.dungeons.instanceMaps.get(instance, null))
                if (ownsDungeonFights(where))
                    foreach (spawn; active.keys)
                    {
                        const saved = active[spawn];
                        if (saved.savedAt + 2 <= world.unixTime)
                        {
                            auto creature = where.creatureAt(saved.guid);
                            if (creature is null)
                                discardDungeonFight(instance, spawn);
                            else if (creature.alive)
                                checkpointDungeonFight(where, creature);
                        }
                    }
    }

    package void waitForCombatPlayer(Creature creature)
    {
        if (creature.ai !is null && creature.ai.inCombat)
            foreach (target; creature.ai.threatList.byKey)
                if (highGuidOf(target) == HighGuid.player)
                {
                    creature.questActorWait = cast(int)((long(world.config.cluster.leaseMs) + world.config.cluster.failureTimeoutMs + 10_000));
                    creature.questActorWaitFor = target;
                    break;
                }
    }

    /// The player field is zero for a living scripted summon or native outdoor combatant.
    package void checkpointOutdoorCreature(Creature creature, bool immediate = false)
    {
        const state = outdoorCreatureCheckpoint(creature);
        if (state.actor)
            saveOutdoorScriptActor(state, immediate);
    }

    package QuestActorCheckpoint outdoorCreatureCheckpoint(Creature creature, scope const uint* faction = null)
    {
        if (!world.config.cluster.enabled || !creature.alive || !ownsQuestActor(creature))
            return QuestActorCheckpoint.init;
        auto migrant = world.migrants.saveMigratingObject(creature, false, carryImpacts: false, factionOverride: faction);
        if (migrant.kind != MigrantKind.summonedCreature && migrant.kind != MigrantKind.creature)
            return QuestActorCheckpoint.init;
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        return outdoorScriptActorState(creature.spawn.map, creature.guid, migrant);
    }

    package void checkpointOutdoorScriptObject(Map map, GameObject go, bool immediate = false)
    {
        const expires = world.scriptedGameObjects.get(WorldContext.GameObjectOnMap(map, go.guid), 0L);
        const state = outdoorObjectCheckpoint(map, go, expires);
        if (state.actor)
            saveOutdoorScriptActor(state, immediate);
    }

    package bool durableOutdoorObject(Map map, uint type)
    {
        import std.algorithm.comparison : among;

        return world.config.cluster.enabled && !map.instanceId && type.among(GameObjectType.generic, GameObjectType.spellFocus);
    }

    package static bool durableScriptedSpawn(const ref GameObjectSpawn spawn, const ref GameObjectTemplate proto)
    {
        import std.algorithm.comparison : among;

        return spawn.guid < temporaryCounterStart && spawn.respawnSeconds < 0
            && (proto.type.among(GameObjectType.generic, GameObjectType.spellFocus, GameObjectType.questGiver,
                    GameObjectType.goober, GameObjectType.button)
                || (proto.type == GameObjectType.chest && proto.data[3] && !proto.data[4] && !proto.data[5]));
    }

    package QuestActorCheckpoint outdoorObjectCheckpoint(Map map, GameObject go, long expires)
    {
        const nativeSpawn = durableScriptedSpawn(go.spawn, *go.template_);
        if ((!nativeSpawn && !durableOutdoorObject(map, go.type)) || map.instanceId || !world.config.cluster.enabled
            || !world.canWrite() || go.owner)
            return QuestActorCheckpoint.init;
        const home = cellKeyAt(go.spawn.x, go.spawn.y);
        if (expires <= world.unixTime || (world.ownsCell !is null && !world.ownsCell(map.id, home)))
            return QuestActorCheckpoint.init;
        auto migrant = world.migrants.saveMigratingObject(go, false, expiresOverride: expires);
        if (migrant.kind != (nativeSpawn ? MigrantKind.gameObject : MigrantKind.summonedGameObject))
            return QuestActorCheckpoint.init;
        migrant.home = home;
        return outdoorScriptActorState(map.id, go.guid, migrant);
    }

    package bool durableStaticDespawn(const ref GameObjectSpawn spawn, const ref GameObjectTemplate proto)
    {
        return spawn.guid < temporaryCounterStart && spawn.respawnSeconds >= 0
            && proto.type != GameObjectType.transport && proto.type != GameObjectType.moTransport
            && spawn.guid !in world.spawnEditor.unsavedGameObjectSpawns && !world.objectRespawns.gameObjectPools.manages(spawn.guid)
            && (world.data.pools is null || !world.data.pools.inPool(PoolMember.Kind.gameObject, spawn.guid));
    }

    package QuestActorCheckpoint outdoorScriptActorState(uint map, ulong guid, ref Migrant migrant)
    {
        import dmangos.world.instancescripting : toHex;

        return QuestActorCheckpoint(map, guid, migrant.home, 0, world.unixTime,
            toHex(encodeBundle(null, [migrant])));
    }

    package void saveOutdoorScriptActor(const ref QuestActorCheckpoint state, bool immediate)
    {
        outdoorQuestActors[state.actor] = state;
        world.database.saveQuestActor(world.config.realmId, state);
        if (immediate)
            world.settleWrites();
    }

    package void updateOutdoorScriptActors()
    {
        import dmangos.world.gameobject : GoLootState;

        if (world.unixTime < nextScriptActorCheckpoint || !outdoorQuestActors.length || !world.canWrite())
            return;
        nextScriptActorCheckpoint = world.unixTime + 1;
        foreach (actor; outdoorQuestActors.values)
            if (!actor.player && actor.savedAt + 2 <= world.unixTime)
                if (auto where = world.existingMap(actor.map))
                {
                    if (auto creature = where.creatureAt(actor.actor))
                    {
                        if (creature.summon.type == TempSpawnType.none)
                            checkpointOutdoorFight(creature);
                        else
                            checkpointOutdoorCreature(creature);
                    }
                    else if (auto object = where.gameObjectAt(actor.actor))
                    {
                        if (!outdoorOpenableActor(actor))
                        {
                            // Opened chests save their loot atomically with item claims. Their actor row holds placement.
                            if (object.type != GameObjectType.chest)
                                checkpointOutdoorScriptObject(where, object);
                        }
                        else if (object.lootState == GoLootState.ready)
                        {
                            if (WorldContext.GameObjectOnMap(where, object.guid) in world.scriptedGameObjects)
                                checkpointOutdoorScriptObject(where, object);
                            else
                            {
                                outdoorQuestActors.remove(actor.actor);
                                world.database.deleteQuestActor(world.config.realmId, actor.actor);
                            }
                        }
                    }
                }
    }

    package bool outdoorOpenableActor(const ref QuestActorCheckpoint actor)
    {
        import dmangos.world.objects : counterOf;
        import std.algorithm.comparison : among;

        if (!world.savedOpenableToggle(actor.state))
            return false;
        const guid = actor.actor;
        const counter = counterOf(guid);
        if (highGuidOf(guid) != HighGuid.gameObject || counter >= temporaryCounterStart)
            return false;
        world.indexSpawns();
        if (const index = counter in world.gameObjectSpawnIndex)
            if (const proto = world.data.gameObjectSpawns[*index].entry in world.data.gameObjectTemplates)
                return proto.type.among(GameObjectType.door, GameObjectType.button) != 0;
        return false;
    }

    package long nextScriptActorCheckpoint;

    package bool questActorRegion(const ref Region region, uint map, ulong home)
    {
        return physicalWorldRegion(region) && region.map == map && region.rect.containsKey(home);
    }

    package void forgetQuestActors(const(Region)[] lost)
    {
        import std.algorithm.searching : any;

        if (!lost.length)
            return;
        foreach (ref region; lost)
            pendingQuestActorRegions.remove(region.id);
        foreach (guid; outdoorQuestActors.keys)
        {
            const actor = outdoorQuestActors[guid];
            if (lost.any!(r => questActorRegion(r, actor.map, actor.home)))
                outdoorQuestActors.remove(guid);
        }
    }

    package void queueQuestActorRecovery(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        if (!world.config.cluster.enabled)
            return;
        foreach (ref region; gained)
            if (physicalWorldRegion(region))
                pendingQuestActorRegions[region.id] = QuestActorRegionGrant(region, arriving.get(region.id, null).length != 0);
        refreshQuestActors();
    }

    package void refreshQuestActors(bool retry = false)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.objects : counterOf;
        import std.algorithm.searching : any;

        if (!pendingQuestActorRegions.length || world.unixTime < retryQuestActorRecoveryAt || !world.canWrite())
            return;
        QuestActorCheckpoint[] actors;
        try
            actors = world.database.loadQuestActors(world.config.realmId);
        catch (DatabaseException error)
        {
            warning!"migration: could not load outdoor quest actors: %s"(error.msg);
            retryQuestActorRecoveryAt = world.unixTime + 1;
            return;
        }
        const grants = pendingQuestActorRegions.values;
        pendingQuestActorRegions = null;
        scope (exit)
            if (retry)
            {
                Region[] done;
                foreach (ref grant; grants)
                    if (grant.region.id !in pendingQuestActorRegions)
                        done ~= grant.region;
                loadHeldCells(done);
            }
        foreach (actor; actors)
        {
            if (!grants.any!(grant => questActorRegion(grant.region, actor.map, actor.home)))
                continue;
            const spawn = counterOf(actor.actor);
            const openable = outdoorOpenableActor(actor);
            const nativeFight = !actor.player && highGuidOf(actor.actor) == HighGuid.unit && spawn < temporaryCounterStart;
            if (highGuidOf(actor.actor) != HighGuid.gameObject
                && ((actor.player && actor.savedAt + 300 <= world.unixTime) || world.deadCreatures.awaitingRespawn(spawn) || spawn in world.deadCreatures.outdoorCorpses
                || (nativeFight && (world.loans.creatureOnLoan(spawn) || !world.calendar.creatureInEvents(spawn)
                    || !world.upInPool(PoolMember.Kind.creature, spawn)))))
            {
                world.database.deleteQuestActor(world.config.realmId, actor.actor);
                continue;
            }
            auto where = world.map(actor.map);
            const clean = grants.any!(grant => grant.clean && questActorRegion(grant.region, actor.map, actor.home));
            if (!clean && openable)
            {
                world.restoreOutdoorOpenable(where, actor);
                continue;
            }
            if ((where.creatureAt(actor.actor) !is null || where.gameObjectAt(actor.actor) !is null)
                && (!nativeFight || clean || actor.actor in outdoorQuestActors))
            {
                outdoorQuestActors[actor.actor] = actor;
                continue;
            }
            if (clean)
            {
                world.database.deleteQuestActor(world.config.realmId, actor.actor);
                continue; // the clean bundle has the newer state and did not carry this actor
            }
            try
                restoreQuestActor(where, actor, nativeFight,
                    home => grants.any!(grant => !grant.clean && questActorRegion(grant.region, actor.map, home)));
            catch (DatabaseException error)
            {
                warning!"migration: could not load loot for outdoor actor %s: %s"(actor.actor, error.msg);
                foreach (ref grant; grants)
                    if (questActorRegion(grant.region, actor.map, actor.home))
                        pendingQuestActorRegions[grant.region.id] = grant;
                retryQuestActorRecoveryAt = world.unixTime + 1;
            }
        }
    }

    package bool restoreQueuedSummon(Map where, const ref QuestActorCheckpoint actor)
    {
        import dmangos.world.objects : counterOf;

        const spawn = counterOf(actor.actor);
        if (highGuidOf(actor.actor) == HighGuid.gameObject || (!world.deadCreatures.awaitingRespawn(spawn) && spawn !in world.deadCreatures.outdoorCorpses))
            return restoreQuestActor(where, actor, false, home => home == actor.home);
        world.database.deleteQuestActor(world.config.realmId, actor.actor);
        return true;
    }

    package bool restoreQuestActor(Map where, const ref QuestActorCheckpoint actor, bool nativeFight,
        scope bool delegate(ulong) ownsHome)
    {
        import dmangos.log : warning;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.objects : counterOf;

        const spawn = counterOf(actor.actor);
        InstanceChestRecord savedChest;
        if (highGuidOf(actor.actor) == HighGuid.gameObject && spawn < temporaryCounterStart)
            if (const placement = world.gameObjectSpawnOf(spawn))
                if (const proto = placement.entry in world.data.gameObjectTemplates)
                    if (proto.type == GameObjectType.chest)
                        savedChest = world.database.loadOutdoorChest(spawn);
        try
        {
            bool restoredActor;
            const recoveryWait = cast(int)((long(world.config.cluster.leaseMs) + world.config.cluster.failureTimeoutMs + 10_000));
            where.migrateIn(fromHex(actor.state), (const ref Migrant saved) {
                const root = saved.spawn == spawn;
                const kind = highGuidOf(actor.actor) == HighGuid.gameObject
                    ? (spawn < temporaryCounterStart ? MigrantKind.gameObject : MigrantKind.summonedGameObject)
                    : nativeFight ? MigrantKind.creature : MigrantKind.summonedCreature;
                if ((!root && !restoredActor) || (!actor.player && (!root || saved.kind != kind))
                    || !ownsHome(saved.home))
                    return null;
                auto object = world.migrants.restoreWorldMigrant(saved, where);
                if (auto go = cast(GameObject) object)
                {
                    if (actor.player || go.guid != actor.actor)
                    {
                        world.objectGone(where, go);
                        return null;
                    }
                    if (savedChest.spawn)
                    {
                        world.objectRespawns.outdoorChests[spawn] = savedChest;
                        world.objectRespawns.restoreOutdoorChest(go, savedChest);
                    }
                    restoredActor = true;
                    return object;
                }
                auto creature = cast(Creature) object;
                if (creature is null || !creature.alive)
                    return null;
                if (root)
                {
                    if (creature.guid != actor.actor || (actor.player ? creature.ai.questActorPlayer() != actor.player
                            : creature.summon.update(creature, 0)))
                    {
                        creature.ai.releaseBehaviour();
                        return null;
                    }
                    restoredActor = true;
                }
                else if (where.creatureAt(creature.guid) !is null)
                {
                    creature.ai.releaseBehaviour();
                    return null;
                }
                if (actor.player)
                {
                    creature.questActorWait = recoveryWait;
                    creature.questActorWaitFor = actor.player;
                }
                else if (nativeFight)
                    waitForCombatPlayer(creature);
                return cast(MapObject) creature;
            });
            if (restoredActor)
                outdoorQuestActors[actor.actor] = actor;
            else if (savedChest.spawn)
            {
                world.objectRespawns.outdoorChests.remove(spawn);
                world.database.finishScriptedOutdoorChest(world.config.realmId, actor.actor, spawn);
            }
            else if (!actor.player)
                world.database.deleteQuestActor(world.config.realmId, actor.actor);
            return true;
        }
        catch (Exception error)
            warning!"map %s: could not restore quest actor %s: %s"(actor.map, actor.actor, error.msg);
        return false;
    }

    /// False if the corpses could not be read (`holdRegionRecovery`).
    package bool refreshOutdoorCorpses(const(Region)[] gained, const(Region)[] lost)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.searching : any;

        if (!world.config.cluster.enabled)
            return true;
        foreach (guid; world.deadCreatures.outdoorCorpses.keys)
        {
            const spawn = outdoorCorpseSpawn(world.deadCreatures.outdoorCorpses[guid]);
            if (spawn.guid && outdoorRegionCovers(&spawn, lost))
                world.deadCreatures.outdoorCorpses.remove(guid);
        }
        if (!gained.any!(r => physicalWorldRegion(r)))
            return true;
        InstanceCorpseRecord[] records;
        try
            records = world.database.loadOutdoorCorpses();
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh outdoor corpses: %s"(error.msg);
            return false;
        }
        foreach (corpse; records)
        {
            const spawn = outdoorCorpseSpawn(corpse);
            if (!spawn.guid || corpse.expiresAt <= world.unixTime || !outdoorRegionCovers(&spawn, gained))
                continue;
            if (spawn.guid < temporaryCounterStart && (world.loans.creatureOnLoan(spawn.guid) || !hasOutdoorRespawn(spawn.guid)))
                continue;
            auto where = world.map(spawn.map);
            world.deadCreatures.outdoorCorpses[corpse.spawn] = corpse;
            if (where.creatureAt(world.loans.loanGuid(&spawn)) !is null)
                continue; // the clean bundle contains the newer live state
            try
            {
                const migrant = outdoorCorpseMigrant(spawn, corpse);
                where.migrateIn(encodeBundle(null, [migrant]), (const ref Migrant saved) => world.deadCreatures.restoreSavedCorpse(where, saved));
            }
            catch (Exception error)
                warning!"migration: could not read outdoor corpse %s: %s"(corpse.spawn, error.msg);
        }
        return true;
    }

    package CreatureSpawn outdoorCorpseSpawn(const ref InstanceCorpseRecord corpse)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize;
        import dmangos.world.instancescripting : fromHex;

        if (corpse.spawn < temporaryCounterStart)
        {
            const spawn = world.creatureSpawnOf(corpse.spawn);
            return spawn is null ? CreatureSpawn.init : *spawn;
        }
        try
        {
            auto bytes = ByteReader(fromHex(corpse.state));
            const spawn = deserialize!CreatureSpawn(bytes);
            if (spawn.guid == corpse.spawn && world.client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z))
                return spawn;
        }
        catch (Exception error)
            warning!"migration: could not read outdoor summon %s: %s"(corpse.spawn, error.msg);
        return CreatureSpawn.init;
    }

    package bool hasOutdoorRespawn(uint spawn) const
    {
        return world.creaturePools.manages(spawn) ? world.creaturePools.waiting(spawn) : (spawn in world.deadCreatures.respawnAt) !is null;
    }

    package static Migrant outdoorCorpseMigrant(const ref CreatureSpawn spawn, const ref InstanceCorpseRecord corpse)
    {
        import dmangos.world.instancescripting : fromHex;

        const kind = corpse.spawn < temporaryCounterStart ? MigrantKind.creature : MigrantKind.summonedCreature;
        return Migrant(kind, corpse.spawn, cellKeyAt(spawn.x, spawn.y), fromHex(corpse.state));
    }

    /// False if the opened chests could not be read (`holdRegionRecovery`).
    package bool refreshOutdoorChests(const(Region)[] gained, const(Region)[] lost)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.searching : any;

        if (!world.config.cluster.enabled)
            return true;
        foreach (guid; world.objectRespawns.outdoorChests.keys)
            if (const index = guid in world.gameObjectSpawnIndex)
                if (outdoorRegionCovers(&world.data.gameObjectSpawns[*index], lost))
                    world.objectRespawns.outdoorChests.remove(guid);
        if (!gained.any!(r => physicalWorldRegion(r)))
            return true;
        try
        {
            foreach (chest; world.database.loadOutdoorChests())
                if (const index = chest.spawn in world.gameObjectSpawnIndex)
                    if (outdoorRegionCovers(&world.data.gameObjectSpawns[*index], gained))
                        world.objectRespawns.outdoorChests[chest.spawn] = chest;
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh outdoor chests: %s"(error.msg);
            return false;
        }
        return true;
    }

    package void releaseRegionCharms(const ref Region region)
    {
        import dmangos.world.objects : highGuidOf;

        const wholeMap = world.dungeons.instanceable(region.map);
        foreach (who; world.online.values)
            if (auto controller = cast(Character) who)
                if (auto creature = controller.charmed)
                    if (highGuidOf(creature.guid) == HighGuid.unit && creature.spawn.map == region.map
                        && (wholeMap || region.rect.containsKey(cellKeyAt(creature.spawn.x, creature.spawn.y))))
                        controller.releaseCharmForHandoff();
    }

    /// With no live bundle, refresh previously known placements before loading the gained cells.
    package size_t[] refreshSavedGameObjectPlacements(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        import std.algorithm.searching : any;
        import dmangos.cluster.regions : CellRect;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        CellRect[][uint] coldCells;
        foreach (ref region; gained)
            if (physicalWorldRegion(region) && !arriving.get(region.id, null).length)
                coldCells.require(region.map, null) ~= region.rect;
        if (!coldCells.length)
            return null;

        world.indexSpawns();
        size_t[] edited;
        foreach (mapId, cells; coldCells)
        {
            bool contains(float x, float y)
            {
                const key = cellKeyAt(x, y);
                return cells.any!(cell => cell.containsKey(key));
            }
            bool movedElevator;
            try
            {
                foreach (saved; world.database.savedGameObjectSpawnsOnMap(mapId))
                {
                    const index = saved.guid in world.gameObjectSpawnIndex;
                    if (index is null || saved.guid >= temporaryCounterStart
                        || !world.client.isValidMapCoord(mapId, saved.x, saved.y, saved.z, saved.orientation))
                        continue;
                    const old = world.data.gameObjectSpawns[*index];
                    if (old.map != mapId)
                        continue;
                    // Only the saved transform changes. A spawn group can supply the entry.
                    saved.entry = old.entry;
                    saved.respawnSeconds = old.respawnSeconds;
                    if (saved == old || (!contains(old.x, old.y) && !contains(saved.x, saved.y)))
                        continue;
                    world.spawnEditor.replaceGameObjectSpawn(*index, saved);
                    edited ~= *index;
                    if (const template_ = old.entry in world.data.gameObjectTemplates)
                        movedElevator |= template_.type == GameObjectType.transport;
                }
            }
            catch (DatabaseException error)
                warning!"migration: could not refresh saved game-object placements on map %s: %s"(mapId, error.msg);
            if (movedElevator)
            {
                world.fleet.longElevatorHomes.remove(mapId);
                if (auto m = world.existingMap(mapId))
                    m.elevatorHomes = world.fleet.elevatorHomesFor(mapId);
            }
        }
        return edited;
    }

    package bool timerHome(Spawn)(const ref Region region, uint guid, const(Spawn)[] spawns, const(size_t[uint]) index,
        out ulong cell)
    {
        if (const slot = guid in index)
        {
            const spawn = &spawns[*slot];
            cell = cellKeyAt(spawn.x, spawn.y);
            return region.map == spawn.map && region.rect.containsKey(cell);
        }
        return false;
    }

    /// Timed-out-of-world spawns move with their home cells even when there is no live object.
    package Migrant[] takeRegionRespawns(const ref Region region)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.migration : MigrantKind;

        world.indexSpawns();
        Migrant[] timers;
        void take(Spawn)(ref long[uint] cached, const(Spawn)[] spawns, const(size_t[uint]) index, MigrantKind kind)
        {
            foreach (guid; cached.keys)
            {
                ulong home;
                if (!timerHome(region, guid, spawns, index, home))
                    continue;
                if (region.next)
                {
                    ByteWriter state;
                    state.put(cached[guid]);
                    timers ~= Migrant(kind, guid, home, state.data);
                }
                cached.remove(guid);
            }
        }
        take(world.deadCreatures.respawnAt, world.data.creatureSpawns, world.spawnIndex, MigrantKind.creatureRespawn);
        take(world.objectRespawns.gameObjectRespawnAt, world.data.gameObjectSpawns, world.gameObjectSpawnIndex, MigrantKind.gameObjectRespawn);
        return timers;
    }

    /**
     * A clean handoff supplies its timers in the bundle. A crash only leaves the database rows. False if they
     * could not be read (`holdRegionRecovery`).
     */
    package bool refreshRegionRespawns(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        if (!gained.length)
            return true;
        world.creaturePools.refresh();
        world.objectRespawns.gameObjectPools.refresh();
        const(Region)[] cold;
        foreach (ref region; gained)
        {
            if (!physicalWorldRegion(region))
                continue;
            if (arriving.get(region.id, null).length)
                takeRegionRespawns(region); // discard any cached timers from an earlier ownership
            else
                cold ~= region;
        }
        return syncColdRespawns(cold);
    }

    /// The respawn timers of regions gained without a bundle, from the database. False if they could not be read.
    package bool syncColdRespawns(const(Region)[] cold)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!cold.length)
            return true;
        world.indexSpawns();
        void sync(Spawn)(ref long[uint] cached, const(long[uint]) saved, const(Spawn)[] spawns,
            const(size_t[uint]) index)
        {
            import std.algorithm.searching : any;

            bool here(uint guid)
            {
                static if (is(Spawn == CreatureSpawn))
                {
                    if (world.creaturePools.manages(guid))
                        return false; // the durable pool row owns this deadline
                }
                else
                    if (world.objectRespawns.gameObjectPools.manages(guid))
                        return false;
                ulong home;
                return cold.any!(region => timerHome(region, guid, spawns, index, home));
            }
            foreach (guid; cached.keys)
                if (guid !in saved && here(guid))
                    cached.remove(guid);
            foreach (guid, at; saved)
                if (here(guid))
                    cached[guid] = at;
        }
        try
        {
            sync(world.deadCreatures.respawnAt, world.database.loadCreatureRespawns(), world.data.creatureSpawns, world.spawnIndex);
            sync(world.objectRespawns.gameObjectRespawnAt, world.database.loadGameObjectRespawns(), world.data.gameObjectSpawns, world.gameObjectSpawnIndex);
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh respawn timers: %s"(error.msg);
            return false;
        }
        return true;
    }

    package MapObject restoreRegionMigrant(const ref Migrant migrant, Map destination, const ref Region region)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.migration : MigrantKind;

        if (migrant.kind == MigrantKind.scriptRun)
        {
            if (region.rect.containsKey(migrant.home))
                world.restoreRegionScriptRun(destination.id, migrant);
            return null;
        }
        const creature = migrant.kind == MigrantKind.creatureRespawn;
        if (migrant.kind == MigrantKind.summonedCreature && !region.rect.containsKey(migrant.home))
            return null;
        if (!creature && migrant.kind != MigrantKind.gameObjectRespawn)
            return world.migrants.restoreWorldMigrant(migrant, destination);
        ulong home;
        const inside = creature ? timerHome(region, migrant.spawn, world.data.creatureSpawns, world.spawnIndex, home)
            : timerHome(region, migrant.spawn, world.data.gameObjectSpawns, world.gameObjectSpawnIndex, home);
        if (!inside || home != migrant.home)
            return null;
        auto state = ByteReader(migrant.state);
        const at = state.read!long;
        if (at > 0)
        {
            if (creature && !world.creaturePools.manages(migrant.spawn))
                world.deadCreatures.respawnAt[migrant.spawn] = at;
            else if (!creature)
                world.objectRespawns.gameObjectRespawnAt[migrant.spawn] = at;
        }
        return null;
    }
}
