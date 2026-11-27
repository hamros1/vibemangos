/**
 * Creatures lent across a region's border (`WorldContext.loans`, docs/CLUSTER.md): a creature here that calls for
 * help asks another node's creatures in reach, which come to this node for the fight and go home after it; their
 * corpses and state come and go with them.
 */
module dmangos.world.creatureloans;

import core.time : MonoTime, seconds;
import dmangos.cluster.regions : Region, RegionState;
import dmangos.world.creature : Creature, CreatureSpawn;
import dmangos.world.migration : Migrant, encodeBundle;
import dmangos.world.unit : UnitRef;
import dmangos.cluster.protocol : AreaDamage, CreatureLoan, CreatureSwing, GameObjectSpell, GmRemote, GroupCommand, GroupLootRoll,
    KillShare, LootCoinShare, PartyHeal, PeriodicResult, QuestLootCheck, ScriptSignal, SwingRetaliation;
import dmangos.world.map : Map, MapObject;
import dmangos.world.worlddata : PoolMember;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class CreatureLoans
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    package Region[uint] localCreatureLoans;

    package MonoTime nextCreatureLoanCheck;

    package bool creatureOnLoan(uint spawn)
    {
        return world.creatureLease !is null && world.creatureLease(spawn).creature.spawn != 0;
    }

    package const(CreatureSpawn)* loanSpawn(uint spawn, uint mapId)
    {
        world.indexSpawns();
        if (const at = spawn in world.spawnIndex)
            if (world.data.creatureSpawns[*at].map == mapId)
                return &world.data.creatureSpawns[*at];
        return null;
    }

    package void askCreatureLoans(Map map_, Creature caller, UnitRef enemy, float radius)
    {
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.objects : counterOf;
        import dmangos.world.relations : reactionTo, Relating, ReputationRank;
        import dmangos.world.updatefields;

        foreach (replica; map_.creatureReplicasNear(caller.position, radius))
        {
            const spawn = counterOf(replica.guid);
            // Event spawns can disappear or change their template and GUID during the loan.
            if (world.creatureLease(spawn).creature.spawn || replica.owner == world.nodeId
                || spawn in world.data.creatureGameEvents || spawn in world.data.eventCreatures)
                continue;
            const values = &replica.fields();
            const flags = values.get!UNIT_FIELD_FLAGS;
            if (!values.get!UNIT_FIELD_HEALTH || flags & (UnitFlags.inCombat | UnitFlags.spawning | UnitFlags.uninteractible))
                continue;
            const faction = world.client.factionTemplates.lookup(values.get!UNIT_FIELD_FACTIONTEMPLATE);
            if (reactionTo(Relating(flags, faction, false, 0, 0, true), caller.ai.relatingOf(), world.client)
                < ReputationRank.friendly || !map_.inLineOfSight(caller.position, replica.position))
                continue;
            const row = loanSpawn(spawn, map_.id);
            if (row !is null && loanGuid(row) == replica.guid)
                world.sendCreatureLoan(CreatureLoan(CreatureLoan.Action.lend, spawn, map_.id, cellKeyAt(row.x, row.y),
                    caller.guid, enemy.combatGuid));
        }
    }

    package ulong loanGuid(const(CreatureSpawn)* spawn)
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        return makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
    }

    ubyte[] releaseCreatureLoan(const ref Region r)
    {
        import dmangos.bytes : ByteWriter;

        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return null;
        auto map_ = world.existingMap(spawn.map);
        if (map_ is null)
            return null;
        const guid = loanGuid(spawn);
        if (r.id !in localCreatureLoans)
        {
            // The initial release can be refused if the creature became busy in transit.
            auto creature = map_.creatureAt(guid);
            if (creature is null || !creature.alive || creature.ai is null || creature.ai.inCombat
                || creature.ai.evading || creature.petOwner)
                return null;
        }
        const bundle = map_.releaseCreatureLoan(guid, r.next, (MapObject object) {
            if (!r.next)
                (cast(Creature) object).ai.finishCreatureChannel(true);
            return world.migrants.saveMigrant(object);
        });
        if (!bundle.length && r.id !in localCreatureLoans)
            return null;
        ByteWriter state;
        state.put(world.deadCreatures.respawnAt.get(spawn.guid, 0L));
        state.putBytes(bundle);
        return cast(ubyte[]) state.data;
    }

    package void creatureLoanGained(const ref Region r, const(ubyte)[] state)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.grid : cellKey, noCell;
        import dmangos.world.migration : decodeBundle;

        localCreatureLoans[r.id] = r;
        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return;
        auto map_ = world.map(spawn.map);
        const guid = loanGuid(spawn);
        auto reader = ByteReader(state);
        const until = state.length ? reader.read!long : 0L;
        const bundle = reader.readBytes(reader.remaining);
        if (until > world.unixTime)
            if (!world.creaturePools.manages(spawn.guid))
                world.deadCreatures.respawnAt[spawn.guid] = until;
        if (bundle.length)
        {
            ulong[] cells;
            Migrant[] migrants;
            decodeBundle(bundle, cells, migrants);
            foreach (ref migrant; migrants)
                migrant.home = noCell; // physical ownership stays reserved until the lease is retired
            map_.migrateIn(encodeBundle(null, migrants), (const ref Migrant migrant) {
                auto restored = world.migrants.restoreMigrant(migrant);
                world.migrants.bindMigrantLoot(restored, map_);
                return restored;
            });
            if (auto corpse = map_.creatureAt(guid))
                if (world.deadCreatures.canCheckpointCorpse(corpse) && (corpse.loot !is null || corpse.skinnable))
                    world.database.saveInstanceCorpse(world.deadCreatures.checkpointCorpse(corpse), 0);
        }
        else if (r.creature.returning && world.ownsCell(spawn.map, cellKey(r.rect.x0, r.rect.y0))
            && map_.creatureAt(guid) is null)
        {
            // The borrower sent nothing back: it crashed (no state at all), or it lost the creature without a clean
            // release when its lease lapsed or the term changed (a deadline at most). Its death, and the corpse
            // with its loot, are in the database: re-read them before rebuilding the spawn.
            if (!until)
            {
                if (world.creaturePools.manages(spawn.guid))
                {
                    if (!world.creaturePools.refresh())
                        return;
                }
                else
                {
                    const saved = world.database.loadCreatureRespawns().get(spawn.guid, 0);
                    if (saved)
                        world.deadCreatures.respawnAt[spawn.guid] = saved;
                }
            }
            if (world.recovery.hasOutdoorRespawn(spawn.guid) && restoreLoanCorpse(map_, *spawn))
                return;
            if (!world.deadCreatures.awaitingRespawn(spawn.guid) && world.calendar.creatureInEvents(spawn.guid)
                && world.dungeons.groupSpawnAllowed(map_, 0, spawn.guid) && world.upInPool(PoolMember.Kind.creature, spawn.guid))
                if (auto creature = world.makeCreature(spawn))
                    map_.addObject(creature);
        }
        if (!r.creature.returning && bundle.length)
            if (auto helper = map_.creatureAt(guid))
                if (helper.ai !is null)
                    helper.ai.answerRemoteAssistance(map_.creatureAt(r.creature.caller), map_.unit(r.creature.enemy), map_);
    }

    package bool restoreLoanCorpse(Map where, const ref CreatureSpawn spawn)
    {
        import dmangos.log : warning;

        try
        {
            foreach (corpse; world.database.loadOutdoorCorpses())
                if (corpse.spawn == spawn.guid && corpse.expiresAt > world.unixTime)
                {
                    const migrant = world.recovery.outdoorCorpseMigrant(spawn, corpse);
                    world.deadCreatures.outdoorCorpses[spawn.guid] = corpse;
                    where.migrateIn(encodeBundle(null, [migrant]),
                        (const ref Migrant saved) => world.deadCreatures.restoreSavedCorpse(where, saved));
                    return true; // the same death still owns this spawn
                }
        }
        catch (Exception error)
            warning!"migration: could not read borrowed corpse %s: %s"(spawn.guid, error.msg);
        return false;
    }

    package void creatureLoanLost(const ref Region r)
    {
        import dmangos.world.grid : cellKey;

        const local = localCreatureLoans.get(r.id, Region.init);
        if (!localCreatureLoans.remove(r.id))
            return;
        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return;
        if (auto map_ = world.existingMap(spawn.map))
        {
            const guid = loanGuid(spawn);
            if (!world.creatureLease(spawn.guid).creature.spawn && local.creature.returning && world.canWrite())
                map_.giveCreatureHome(guid, cellKey(r.rect.x0, r.rect.y0));
            else
            {
                world.deadCreatures.outdoorCorpses.remove(spawn.guid);
                if (map_.creatureAt(guid) !is null)
                    map_.removeObject(guid); // lease expired without a clean release
            }
        }
    }

    package void updateCreatureLoans(MonoTime now)
    {
        import dmangos.world.grid : cellKey;

        if (!localCreatureLoans.length || now < nextCreatureLoanCheck || !world.canWrite())
            return;
        nextCreatureLoanCheck = now + 1.seconds;
        foreach (ref local; localCreatureLoans)
        {
            const r = world.creatureLease(local.creature.spawn);
            if (r.owner != world.nodeId || r.state != RegionState.granted || r.epoch != local.epoch)
                continue;
            const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
            auto map_ = world.existingMap(r.creature.homeMap);
            auto creature = map_ is null || spawn is null ? null : map_.creatureAt(loanGuid(spawn));
            if (r.creature.returning && world.ownsCell(r.creature.homeMap, cellKey(r.rect.x0, r.rect.y0)))
            {
                // Load the other spawns while this creature's reservation still suppresses its row.
                if (map_ !is null)
                    map_.loadCell(cellKey(r.rect.x0, r.rect.y0));
                local.creature.returning = true;
                world.sendCreatureLoan(CreatureLoan(CreatureLoan.Action.retire, r.creature.spawn, epoch: r.epoch));
            }
            // A defeated helper's corpse stays available to loot on the fight's node.
            else if (creature is null || (creature.alive && (creature.ai is null
                || (!creature.ai.inCombat && !creature.ai.evading))))
                world.sendCreatureLoan(CreatureLoan(CreatureLoan.Action.returnHome, r.creature.spawn, epoch: r.epoch));
        }
    }
}
