/**
 * The creatures that died on this node (`WorldContext.deadCreatures`): the death and when each comes back
 * (`respawnAt`), a dead creature's corpse and loot (and a pickpocketed one's) kept for a crash and given back, and the
 * corpse removed in its time.
 */
module dmangos.world.creaturedeath;

import dmangos.bytes : ByteReader, ByteWriter;
import core.time : MonoTime;
import dmangos.world.creature : Creature, CreatureSpawn, TempSpawnType;
import dmangos.world.migration : Migrant, encodeBundle;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.objects : temporaryCounterStart;
import dmangos.world.bgqueue : battlegroundOfMap;
import dmangos.world.database : DungeonFightCheckpoint, InstanceChestRecord, InstanceCorpseRecord, PickpocketRecord,
    QuestActorCheckpoint, WorldDatabase;
import dmangos.world.loot : Loot, LootItem;
import dmangos.world.map : Map, MapObject;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class DeadCreatures
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// Creatures that are dead now: spawn guid -> when they come back (Unix time), as `creature_respawn` has it.
    package long[uint] respawnAt;

    package MonoTime lastRespawnCheck;

    package InstanceCorpseRecord[uint] outdoorCorpses;

    package bool moltenCoreTrash(const ref CreatureSpawn spawn)
    {
        enum moltenCore = 409, lockout = 7 * 24 * 60 * 60, worldBossRank = 3, instanceBind = 0x01;
        if (spawn.map != moltenCore || spawn.respawnSeconds == 0 || spawn.respawnSeconds >= lockout)
            return false;
        const template_ = spawn.entry in world.data.creatureTemplates;
        return template_ !is null && template_.rank != worldBossRank && !(template_.extraFlags & instanceBind);
    }

    /// A creature died: its respawn time is saved at once; it comes back when it says.
    void creatureDied(Creature creature)
    {
        import dmangos.script.api : CreatureDied, EntityRef;

        const summoned = creature.summon.type != TempSpawnType.none;
        if (creature.instanceId)
        {
            // A script can flush a checkpoint in its death handler. Queue the spawn death first.
            if (!summoned)
                if (auto state = creature.instanceId in world.dungeons.instances)
                {
                    const guid = creature.spawn.guid;
                    state.dead[guid] = true;
                    if (auto copy = world.battlegrounds.find(creature.instanceId))
                        copy.objectiveChanged();
                    else if (guid !in state.corpses)
                    {
                        world.database.saveInstanceRespawn(false, guid, creature.instanceId,
                            instanceDeathDeadline(*state, creature));
                    }
                    world.discardDungeonFight(creature.instanceId, guid);
                }
            // What the script makes of the death is a checkpoint: the death is queued already, and a crash between
            // the two writes would leave the creature dead but its encounter waiting on it (a door shut for good).
            if (auto script = creature.instanceId in world.instanceScripts)
                script.raiseCheckpointed(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient),
                    summoned));
            return;
        }
        if (auto script = creature.spawn.map in world.worldScripts)
            script.raise(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient), summoned));
        if (summoned)
            return;
        if (creature.spawn.guid in outdoorCorpses)
            return; // saved alongside the original loot
        if (world.creaturePools.manages(creature.spawn.guid))
            world.creaturePools.dead(creature.spawn.guid, creature.respawnAt);
        else
        {
            respawnAt[creature.spawn.guid] = creature.respawnAt;
            world.database.saveCreatureRespawn(creature.spawn.guid, creature.respawnAt);
        }
    }

    package bool canCheckpointCorpse(const Creature creature)
    {
        if (creature.alive || creature.corpseTimer <= 0 || creature.petOwner || creature.guardianOwner || creature.totemOwner)
            return false;
        if (creature.instanceId)
            return (creature.instanceId in world.dungeons.instances) !is null && !battlegroundOfMap(creature.spawn.map);
        return world.config.cluster.enabled;
    }

    package long instanceDeathDeadline(ref world.dungeons.InstanceState state, const Creature creature)
    {
        auto until = state.resetAt ? state.resetAt : world.unixTime + 86_400;
        if (moltenCoreTrash(creature.spawn) && creature.respawnAt < until)
            state.trashRespawns[creature.spawn.guid] = until = creature.respawnAt;
        return until;
    }

    /// Record the original loot and the death before exposing the loot to players.
    package void saveNewCorpse(Creature creature)
    {
        if (!canCheckpointCorpse(creature))
            return;
        if (auto state = creature.instanceId in world.dungeons.instances)
        {
            state.dead[creature.spawn.guid] = true;
            world.database.saveInstanceCorpse(checkpointCorpse(creature), instanceDeathDeadline(*state, creature));
        }
        else
        {
            saveOutdoorLootPositions(world.existingMap(creature.spawn.map), creature.loot);
            const record = checkpointCorpse(creature);
            if (creature.summon.type != TempSpawnType.none)
                world.database.saveInstanceCorpse(record, 0);
            else if (world.creaturePools.manages(record.spawn))
                world.creaturePools.dead(record.spawn, creature.respawnAt, false, record);
            else
            {
                respawnAt[record.spawn] = creature.respawnAt;
                world.database.saveInstanceCorpse(record, creature.respawnAt);
            }
        }
    }

    package void saveOutdoorLootPositions(Map map, Loot loot)
    {
        if (loot is null)
            return;
        foreach (guid; loot.owners.byKey)
            if (auto session = world.onlinePlayer(guid))
                if (session.character !is null && session.currentMap is map && !session.transferring)
                {
                    const progress = session.character.progress(session.secondsInWorld());
                    world.database.saveProgress(progress);
                }
    }

    package bool canCheckpointPickpocket(const Creature creature)
    {
        return world.config.cluster.enabled && creature.alive && creature.summon.type == TempSpawnType.none
            && !creature.petOwner && creature.spawn.guid < temporaryCounterStart
            && (!creature.instanceId || (creature.instanceId in world.dungeons.instances && !battlegroundOfMap(creature.spawn.map)));
    }

    package PickpocketRecord checkpointPickpocket(Creature creature, const LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.world.instancescripting : toHex;
        import std.algorithm.searching : all;

        ByteWriter state;
        auto loot = creature.loot;
        loot.saveHandoff(state, claimed, looter, true);
        auto restock = creature.pocketsRestockAt;
        if (!restock && !loot.gold && loot.items.all!(item => item is claimed || !item.allowed.length))
            restock = world.unixTime + world.config.creaturePickpocketRestockDelay;
        return PickpocketRecord(creature.instanceId, creature.spawn.guid, restock, toHex(state.data));
    }

    package void restorePickpocket(Map map, Creature creature)
    {
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.loothandlers : bindCreatureLoot;

        if (!canCheckpointPickpocket(creature))
            return;
        const record = world.database.loadPickpocket(creature.instanceId, creature.spawn.guid);
        if (!record.spawn || (record.restockAt && record.restockAt <= world.unixTime))
            return;
        auto state = ByteReader(fromHex(record.loot));
        creature.loot = Loot.loadHandoff(creature.guid, state, true);
        creature.pocketsRestockAt = record.restockAt;
        creature.pocketsEmptied = record.restockAt != 0;
        bindCreatureLoot(world, map, creature, creature.loot);
    }

    package InstanceCorpseRecord checkpointCorpse(Creature creature, const LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.world.instancescripting : toHex;

        const expiresAt = world.unixTime + (creature.corpseTimer + 999L) / 1000;
        const record = InstanceCorpseRecord(creature.instanceId, creature.spawn.guid, expiresAt,
            toHex(world.saveMigratingObject(creature, false, claimed, looter).state));
        if (auto state = creature.instanceId in world.dungeons.instances)
            state.corpses[record.spawn] = record;
        else if (!creature.instanceId)
            outdoorCorpses[record.spawn] = record;
        return record;
    }

    package void saveCorpseLoot(Creature creature)
    {
        auto state = creature.instanceId in world.dungeons.instances;
        if (creature.instanceId && state is null)
            return;
        auto corpses = state is null ? &outdoorCorpses : &state.corpses;
        if (creature.spawn.guid !in *corpses)
            return;
        if (creature.loot is null && !creature.skinnable)
        {
            (*corpses).remove(creature.spawn.guid);
            world.database.deleteInstanceCorpse(creature.instanceId, creature.spawn.guid);
        }
        else
            world.database.saveInstanceCorpse(checkpointCorpse(creature), 0);
    }

    package void restoreInstanceCorpses(Map map)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.migration : MigrantKind;

        const state = map.instanceId in world.dungeons.instances;
        if (state is null)
            return;
        Migrant[] corpses;
        foreach (guid, corpse; state.corpses)
        {
            if (corpse.expiresAt <= world.unixTime || guid !in state.dead)
                continue;
            try
            {
                const bytes = fromHex(corpse.state);
                if (guid >= temporaryCounterStart)
                {
                    auto reader = ByteReader(bytes);
                    const spawn = deserialize!CreatureSpawn(reader);
                    if (spawn.map == map.id && spawn.guid == guid)
                        corpses ~= Migrant(MigrantKind.summonedCreature, guid, cellKeyAt(spawn.x, spawn.y), bytes);
                }
                else if (const spawn = world.creatureSpawnOf(guid))
                {
                    if (spawn.map == map.id)
                        corpses ~= Migrant(MigrantKind.creature, guid, cellKeyAt(spawn.x, spawn.y), bytes);
                }
            }
            catch (Exception error)
                warning!"instance %s: could not read corpse %s: %s"(map.instanceId, guid, error.msg);
        }
        if (corpses.length)
            map.migrateIn(encodeBundle(null, corpses), (const ref Migrant saved) => restoreSavedCorpse(map, saved));
    }

    package MapObject restoreSavedCorpse(Map map, const ref Migrant migrant)
    {
        import dmangos.log : warning;

        try
        {
            auto creature = cast(Creature) world.restoreWorldMigrant(migrant, map);
            if (creature is null || creature.alive || creature.summon.update(creature, 0))
                return null;
            // The inventory transaction may have committed before the corpse was cleared.
            if (creature.loot !is null && creature.loot.lootedForEveryone())
                creature.lootedOut();
            if (creature.loot !is null)
                creature.loot.resumeRemoteRolls();
            return creature.loot !is null || creature.skinnable ? cast(MapObject) creature : null;
        }
        catch (Exception error)
        {
            warning!"map %s copy %s: could not restore corpse %s: %s"(map.id, map.instanceId, migrant.spawn, error.msg);
            return null;
        }
    }

    /// A corpse went; if it died elsewhere, restore the original respawn deadline.
    package void corpseRemoved(Creature creature)
    {
        import std.algorithm.comparison : max;

        if (creature.petOwner)
        {
            if (auto owner = world.onlinePlayer(creature.petOwner))
                if (owner.character !is null)
                    owner.petCorpseGone(creature);
            return;
        }
        if (creature.instanceId)
        {
            if (auto state = creature.instanceId in world.dungeons.instances)
                if (state.corpses.remove(creature.spawn.guid))
                    world.database.deleteInstanceCorpse(creature.instanceId, creature.spawn.guid);
            return;
        }
        if (outdoorCorpses.remove(creature.spawn.guid))
            world.database.deleteInstanceCorpse(0, creature.spawn.guid);
        if (creature.summon.type != TempSpawnType.none)
            return;
        if (world.creaturePools.manages(creature.spawn.guid))
        {
            const next = creature.respawnAt ? max(world.unixTime, creature.respawnAt) : world.unixTime + creature.spawn.respawnSeconds;
            world.creaturePools.dead(creature.spawn.guid, next);
            return;
        }
        if (creature.spawn.guid !in respawnAt)
        {
            const next = creature.respawnAt ? max(world.unixTime, creature.respawnAt) : world.unixTime + creature.spawn.respawnSeconds;
            respawnAt[creature.spawn.guid] = next;
            world.database.saveCreatureRespawn(creature.spawn.guid, respawnAt[creature.spawn.guid]);
        }
    }
}
