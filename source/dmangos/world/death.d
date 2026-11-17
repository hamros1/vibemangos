/**
 * A player's death and return (CMaNGOS `Player::KillPlayer`, `BuildPlayerRepop`, `RepopAtGraveyard`,
 * `ResurrectPlayer`, `SpawnCorpseBones`, `DurabilityLossAll`; `MiscHandler.cpp`'s repop and reclaim,
 * `NPCHandler.cpp`'s spirit healer, `QueryHandler.cpp`'s corpse query; the graveyards of
 * `GraveyardManager`), mixed into `dmangos.world.character.Character`.
 *
 * Dead, a player lies rooted where it fell; released (or after six minutes, or logging out), it is a
 * ghost at the nearest graveyard of its team, its corpse left behind. Back within 39 yards of the
 * corpse, after a delay (30 seconds, longer for deaths close together), it comes back to life there
 * with half its health and mana; or the spirit healer brings it back at once, at the price of a
 * quarter of its gear's durability. Dying costs a tenth of what it wears.
 *
 * The ghost aura (spell 8326) and the night elf's wisp (20584) are applied by hand until there are
 * auras: the ghost flag, 25% more speed (50% and the wisp's look for night elves), and walking on
 * water. Not yet: resurrection sickness (an aura), ghosts hidden from the living (players see each
 * other both ways or not at all).
 */
module dmangos.world.death;

import dmangos.world.clientdata : ClientData, Team, WorldSafeLocsEntry;
import dmangos.world.movement : Position;
import dmangos.world.worlddata : graveyardLinkKey, WorldData;

/// `CORPSE_RECLAIM_DELAY`s: 30 s, then 60 and 120 for deaths close together; `DEATH_EXPIRE_STEP` apart.
enum uint[3] corpseReclaimDelays = [30, 60, 120];
enum long deathExpireStep = 5 * 60; /// ditto
enum uint maxDeathCount = 3;        /// ditto

/// `CONFIG_UINT32_DEATH_... m_deathTimer`: a player not released after this is released anyway.
enum uint autoReleaseMs = 6 * 60 * 1000;

/// The team ids `game_graveyard_zone.faction` uses.
enum uint teamAlliance = 469, teamHorde = 67;

/// `TEAM_INVALID`: a graveyard a battleground has closed.
enum uint teamInvalid = 1;

/**
 * `GraveyardManager::GetClosestGraveYard`: the nearest graveyard for `team` linked to the area, else
 * the zone, else the map; on another map than the death (an instance), the one nearest to its ghost
 * entrance; null if none.
 */
const(WorldSafeLocsEntry)* closestGraveyard(const WorldData data, const ClientData client, uint map, Position at,
    uint team, uint zone, uint area, const(uint[uint]) linkTeams = null)
{
    const(WorldSafeLocsEntry)* fromLinks(uint key)
    {
        const links = data.graveyards.get(key, null);
        const(WorldSafeLocsEntry)* near, entrance, far;
        float nearDist = float.max, entranceDist = float.max;
        const ghost = map in data.ghostEntrances;
        foreach (link; links)
        {
            const entry = client.worldSafeLocs.lookup(link.safeLoc);
            // A battleground's own say first (`SetGraveYardLinkTeam`): whose it is, or nobody's.
            uint linkTeam = link.team;
            if (auto own = link.safeLoc in linkTeams)
                linkTeam = *own;
            if (entry is null || linkTeam == teamInvalid || (linkTeam != 0 && linkTeam != team))
                continue;
            if (entry.map != map)
            {
                if (ghost is null || ghost.map < 0 || uint(ghost.map) != entry.map || (ghost.x == 0 && ghost.y == 0))
                {
                    far = entry;
                    continue;
                }
                const d = (entry.x - ghost.x) ^^ 2 + (entry.y - ghost.y) ^^ 2;
                if (d < entranceDist)
                {
                    entranceDist = d;
                    entrance = entry;
                }
            }
            else
            {
                const d = (entry.x - at.x) ^^ 2 + (entry.y - at.y) ^^ 2 + (entry.z - at.z) ^^ 2;
                if (d < nearDist)
                {
                    nearDist = d;
                    near = entry;
                }
            }
        }
        return near !is null ? near : entrance !is null ? entrance : far;
    }

    enum uint areaLink = 0, mapLink = 1;
    const(WorldSafeLocsEntry)* found;
    if (area)
        found = fromLinks(graveyardLinkKey(area, areaLink));
    if (found is null && zone)
        found = fromLinks(graveyardLinkKey(zone, areaLink));
    if (found is null)
        found = fromLinks(graveyardLinkKey(map, mapLink));
    return found;
}

/// `Player::getCorpseReclaimDelayHelper`: seconds a ghost waits by its corpse, by how many deaths are recent.
uint corpseReclaimDelay(long deathExpireTime, long now) pure nothrow @nogc @safe
{
    uint count;
    if (deathExpireTime > now)
    {
        count = cast(uint)((deathExpireTime - now) / deathExpireStep);
        if (count >= maxDeathCount)
            count = maxDeathCount - 1;
    }
    return corpseReclaimDelays[count];
}

/// `Player::UpdateCorpseReclaimDelay`: one more death; the next corpse waits longer if it comes soon.
long nextDeathExpireTime(long deathExpireTime, long now) pure nothrow @nogc @safe
{
    if (now < deathExpireTime)
    {
        const count = cast(uint)((deathExpireTime - now) / deathExpireStep + 1);
        return now + (count < maxDeathCount ? count + 1 : maxDeathCount) * deathExpireStep;
    }
    return now + deathExpireStep;
}

unittest
{
    assert(corpseReclaimDelay(0, 1000) == 30);
    // A death at 1000, released a second later: 30 s (in the very second of the death, CMaNGOS's whole
    // division makes it 60).
    const once = nextDeathExpireTime(0, 1000);
    assert(once == 1300 && corpseReclaimDelay(once, 1001) == 30 && corpseReclaimDelay(once, 1000) == 60);
    const twice = nextDeathExpireTime(once, 1010);
    assert(corpseReclaimDelay(twice, 1011) == 60, "another within five minutes: 60 s");
    const thrice = nextDeathExpireTime(twice, 1020);
    assert(corpseReclaimDelay(thrice, 1021) == 120 && corpseReclaimDelay(thrice, 1020 + 900) == 30);
}

/// See the module documentation.
mixin template DeathHandlers()
{
    import core.time : Duration;
    import dmangos.log : info;
    import dmangos.world.clientdata : WorldSafeLocsEntry;
    import dmangos.world.corpse : Corpse, CorpseType, corpseReclaimRadius;
    import dmangos.world.database : CorpseRecord;
    import dmangos.world.death;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.movement : baseMoveSpeed, MoveType, Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : DeathState, PlayerFlags;
    import dmangos.world.updatefields;

private:
    int deathTimer;                // `m_deathTimer`: until a body not released is released anyway
    Corpse corpse;                 // the body, while there is one

    /**
     * `Unit::Kill` of the player and `Player::KillPlayer`: a tenth of what it wears is worn out (killed
     * by a creature), it stops fighting, and lies rooted where it fell until it releases its spirit.
     */
    void playerDied(bool byCreature)
    {
        info!"%s: '%s' died"(remoteAddress, player.data.name);
        spellsOnLeave();
        removeAurasOnDeath();
        cancelTrade(true);
        stopAttack(false);
        if (byCreature)
        {
            durabilityLossAll(0.10, false);
            deliver(Opcode.SMSG_DURABILITY_DAMAGE_DEATH, null);
        }
        player.values.set!UNIT_FIELD_HEALTH(0u);
        player.deathState = DeathState.corpse;
        sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        player.values.set!UNIT_DYNAMIC_FLAGS(0u);
        enum ubyte releaseTimer = 0x08; // PLAYER_FIELD_BYTE_RELEASE_TIMER: the client counts down to the release
        player.values.setByte!PLAYER_FIELD_BYTES(0, player.values.getByte!PLAYER_FIELD_BYTES(0) | releaseTimer);
        deathTimer = autoReleaseMs;
        player.data.deathExpireTime = nextDeathExpireTime(player.data.deathExpireTime, context.unixTime);
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.status | GroupUpdate.currentHealth);
    }

    /// `HandleRepopRequestOpcode`: the player releases its spirit.
    @Handles(Opcode.CMSG_REPOP_REQUEST, WorldState.inWorld)
    void handleRepopRequest()
    {
        if (player.deathState != DeathState.corpse)
            return;
        buildPlayerRepop();
        repopAtGraveyard();
    }

    /**
     * `BuildPlayerRepop`: a ghost (the ghost aura), its corpse left where it lay (and saved), with one
     * health; it can move again, and is told how long its corpse makes it wait.
     */
    void buildPlayerRepop()
    {
        deathTimer = 0;
        player.deathState = DeathState.ghost;
        setGhost(true);
        corpse = new Corpse(player, CorpseType.resurrectablePve, context.unixTime);
        corpse.instanceId = instanceId_;
        map.addObject(corpse);
        auto record = CorpseRecord(player.data.guid, corpse.at.x, corpse.at.y, corpse.at.z, corpse.at.orientation,
            corpse.map, corpse.ghostTime, cast(ubyte) corpse.type);
        context.database.saveCorpse(record);
        player.values.set!UNIT_FIELD_HEALTH(1u);
        sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        sendReclaimDelay();
        flushPlayerChanges();
    }

    /// `SendCorpseReclaimDelay`: how long until the ghost may take its body back, in milliseconds.
    void sendReclaimDelay()
    {
        if (corpse is null)
            return;
        const now = context.unixTime;
        const ready = corpse.ghostTime + corpseReclaimDelay(player.data.deathExpireTime, corpse.ghostTime);
        if (now >= ready)
            return;
        ByteWriter w;
        w.put(cast(uint)((ready - now) * 1000));
        deliver(Opcode.SMSG_CORPSE_RECLAIM_DELAY, w.data);
    }

    /// `RepopAtGraveyard`: to the nearest graveyard of the player's team; where it is if there is none.
    void repopAtGraveyard()
    {
        const at = player.position;
        uint[2] zoneAndArea = [player.data.zone, player.area];
        serverZoneAndArea(zoneAndArea);
        const grave = closestGraveyard(context.data, context.client, player.data.map, at, teamId,
            zoneAndArea[0], zoneAndArea[1], battlegroundGraveyards());
        deathTimer = 0;
        if (grave !is null)
            commandTeleport(grave.map, Position(grave.x, grave.y, grave.z, 0));
        else
            map.refreshVisibility(this); // the spirit healers here, now that it is dead
    }

    /// The player's team as `game_graveyard_zone` knows it.
    @property uint teamId()
    {
        return context.client.teamForRace(player.data.race) == Team.horde ? teamHorde : teamAlliance;
    }

    /**
     * The ghost aura (8326), and the night elf's wisp (20584): the ghost flag, run and swim speeds
     * 25% up (the wisp's 50%, and its look), and walking on water; or all of it gone.
     */
    void setGhost(bool on)
    {
        enum uint wispDisplay = 1825; // creature 12861, the wisp of spell 20584's transform
        enum ubyte raceNightElf = 4;
        const wisp = player.data.race == raceNightElf;
        const flags = player.values.get!PLAYER_FLAGS;
        player.values.set!PLAYER_FLAGS(on ? flags | PlayerFlags.ghost : flags & ~PlayerFlags.ghost);
        if (wisp)
            player.values.set!UNIT_FIELD_DISPLAYID(on ? wispDisplay : player.values.get!UNIT_FIELD_NATIVEDISPLAYID);
        const factor = !on ? 1.0f : wisp ? 1.5f : 1.25f;
        forceSpeed!(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)(MoveType.run, baseMoveSpeed[MoveType.run] * factor);
        forceSpeed!(Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE)(MoveType.swim, baseMoveSpeed[MoveType.swim] * factor);
        if (on)
            sendMovementOrder!(Opcode.SMSG_MOVE_WATER_WALK)();
        else
            sendMovementOrder!(Opcode.SMSG_MOVE_LAND_WALK)();
    }

    /// `SMSG_FORCE_*_SPEED_CHANGE` for one kind of movement.
    void forceSpeed(Opcode opcode)(MoveType type, float speed)
    {
        player.speeds[type] = speed;
        send(ServerForceSpeedChange!opcode(player.guid, moveOrderCounter++, speed));
        resetMovementCheck();
    }

    /// `HandleReclaimCorpseOpcode`: the ghost takes its body back, if near it and the delay is over.
    @Handles(Opcode.CMSG_RECLAIM_CORPSE, WorldState.inWorld)
    void handleReclaimCorpse(const ClientGuid request)
    {
        if (player.deathState != DeathState.ghost || corpse is null)
            return;
        const now = context.unixTime;
        if (corpse.ghostTime + corpseReclaimDelay(player.data.deathExpireTime, corpse.ghostTime) > now)
            return;
        if (corpse.map != player.data.map || corpse.instanceId != instanceId_)
            return;
        const d = corpse.at, p = player.position;
        if ((d.x - p.x) ^^ 2 + (d.y - p.y) ^^ 2 + (d.z - p.z) ^^ 2 > corpseReclaimRadius ^^ 2)
            return;
        resurrect(0.5f);
        spawnCorpseBones();
    }

    /// `HandleSpiritHealerActivateOpcode` and `SendSpiritResurrect`: back to life at once, gear a quarter worn.
    @Handles(Opcode.CMSG_SPIRIT_HEALER_ACTIVATE, WorldState.inWorld)
    void handleSpiritHealerActivate(const ClientGuid request)
    {
        enum uint spiritHealer = 0x20; // UNIT_NPC_FLAG_SPIRITHEALER
        if (player.deathState != DeathState.ghost)
            return;
        if (interactableNpc(request.guid, spiritHealer) is null)
            return;
        resurrect(0.5f);
        durabilityLossAll(0.25, true);
        // To the graveyard nearest the corpse, if that is another than the one nearest the ghost.
        const(WorldSafeLocsEntry)* corpseGrave, ghostGrave;
        if (corpse !is null)
        {
            corpseGrave = closestGraveyard(context.data, context.client, corpse.map, corpse.at, teamId, 0, 0);
            ghostGrave = closestGraveyard(context.data, context.client, player.data.map, player.position, teamId, 0, 0,
                battlegroundGraveyards());
        }
        spawnCorpseBones();
        if (corpseGrave !is null && corpseGrave !is ghostGrave)
            commandTeleport(corpseGrave.map, Position(corpseGrave.x, corpseGrave.y, corpseGrave.z, 0));
    }

    /// `HandleCorpseQueryOpcode`: where the corpse is, for the map (its instance's entrance on another map).
    @Handles(Opcode.MSG_CORPSE_QUERY, WorldState.inWorld)
    void handleCorpseQuery()
    {
        ByteWriter w;
        if (corpse is null)
        {
            w.put(ubyte(0));
            return deliver(Opcode.MSG_CORPSE_QUERY, w.data);
        }
        int mapId = corpse.map;
        float x = corpse.at.x, y = corpse.at.y, z = corpse.at.z;
        if (corpse.map != player.data.map)
            if (const entrance = corpse.map in context.data.ghostEntrances)
                if (entrance.map >= 0)
                {
                    mapId = entrance.map;
                    x = entrance.x;
                    y = entrance.y;
                    z = context.terrain(entrance.map) is null ? 0 : context.terrain(entrance.map).heightStatic(x, y,
                        1000);
                }
        w.put(ubyte(1));
        w.put(mapId);
        w.put(x);
        w.put(y);
        w.put(z);
        w.put(corpse.map);
        deliver(Opcode.MSG_CORPSE_QUERY, w.data);
    }

    /// `ResurrectPlayer`: alive, the ghost aura gone, with `restore` of its health, mana and energy (no rage).
    void resurrect(float restore)
    {
        player.deathState = DeathState.alive;
        deathTimer = 0;
        setGhost(false);
        sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        enum ubyte releaseTimer = 0x08;
        player.values.setByte!PLAYER_FIELD_BYTES(0, player.values.getByte!PLAYER_FIELD_BYTES(0) & ~releaseTimer);
        auto v = &player.values;
        if (restore > 0)
        {
            v.set!UNIT_FIELD_HEALTH(cast(uint)(v.get!UNIT_FIELD_MAXHEALTH * restore));
            v.set!UNIT_FIELD_POWER1(Power.mana, cast(uint)(v.get!UNIT_FIELD_MAXPOWER1(Power.mana) * restore));
            v.set!UNIT_FIELD_POWER1(Power.rage, 0u);
            v.set!UNIT_FIELD_POWER1(Power.energy, cast(uint)(v.get!UNIT_FIELD_MAXPOWER1(Power.energy) * restore));
        }
        flushPlayerChanges();
        map.refreshVisibility(this); // the spirit healers go
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.status | GroupUpdate.currentHealth | GroupUpdate.currentPower);
        info!"%s: '%s' came back to life"(remoteAddress, player.data.name);
    }

    /// `SpawnCorpseBones`: the corpse is gone (bones are not kept), and so is its row.
    void spawnCorpseBones()
    {
        if (corpse is null)
            return;
        if (auto there = context.existingMap(corpse.map, corpse.instanceId))
            there.removeObject(corpse.guid);
        context.database.deleteCorpse(player.data.guid);
        corpse = null;
        savePlayer();
    }

    /// `DurabilityLossAll`: what it wears (and with `inventory` what it carries) loses `percent` of its durability.
    void durabilityLossAll(double percent, bool inventory)
    {
        import dmangos.world.defines : equipmentSlotEnd, inventorySlotBag0, inventorySlotItemEnd,
            inventorySlotItemStart;
        import dmangos.world.inventory : ItemState;

        void lose(ubyte bag, ubyte slot)
        {
            auto item = player.inventory[bag, slot];
            if (item is null || item.maxDurability == 0)
                return;
            uint points = cast(uint)(item.maxDurability * percent);
            if (points < 1)
                points = 1;
            const old = item.durability;
            const now = old > points ? old - points : 0;
            if (now == old)
                return;
            item.values.set!ITEM_FIELD_DURABILITY(now);
            player.inventory.setState(item, ItemState.changed);
            if (now == 0 && slot < equipmentSlotEnd && bag == inventorySlotBag0)
                player.inventory.equipmentChanged = true; // broken: its stats go
        }

        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            lose(inventorySlotBag0, slot);
        if (inventory)
            foreach (ubyte slot; inventorySlotItemStart .. inventorySlotItemEnd)
                lose(inventorySlotBag0, slot);
        flushInventory(true);
    }

    /// `Player::Update`'s death timer: a body not released in six minutes is released.
    void updateDeath(Duration elapsed)
    {
        if (player.deathState != DeathState.corpse || deathTimer <= 0)
            return;
        deathTimer -= cast(int) elapsed.total!"msecs";
        if (deathTimer > 0)
            return;
        buildPlayerRepop();
        repopAtGraveyard();
    }

    /**
     * Entering the world: a player saved as a ghost (`PLAYER_FLAGS_GHOST`) is one again, with its
     * corpse where it lay; one saved dead without being released (it never was: logging out releases)
     * comes back to life.
     */
    void deathOnLogin()
    {
        if (!(player.data.playerFlags & PlayerFlags.ghost))
            return;
        const saved = context.database.loadCorpse(player.data.guid);
        if (saved.isNull)
        {
            // No corpse: nothing to come back to; CMaNGOS would leave a ghost without one. Back to life.
            player.values.set!PLAYER_FLAGS(player.values.get!PLAYER_FLAGS & ~PlayerFlags.ghost);
            return;
        }
        player.deathState = DeathState.ghost;
        const c = saved.get;
        corpse = new Corpse(player, cast(CorpseType) c.type, c.time);
        corpse.at = Position(c.x, c.y, c.z, c.orientation);
        corpse.values.set!CORPSE_FIELD_POS_X(c.x);
        corpse.values.set!CORPSE_FIELD_POS_Y(c.y);
        corpse.values.set!CORPSE_FIELD_POS_Z(c.z);
        corpse.values.set!CORPSE_FIELD_FACING(c.orientation);
        corpse.values.clearChanges();
        if (c.map == player.data.map)
            map.addObject(corpse);
        else
            context.map(c.map).addObject(corpse);
        player.values.set!UNIT_FIELD_HEALTH(1u);
        setGhost(true);
        sendReclaimDelay();
        flushPlayerChanges();
        map.refreshVisibility(this);
    }

    /// `WorldSession::LogoutPlayer`: a body not released is released (and goes to its graveyard) before the save.
    void deathOnLogout()
    {
        if (player.deathState != DeathState.corpse)
            return;
        buildPlayerRepop();
        const at = player.position;
        uint[2] zoneAndArea = [player.data.zone, player.area];
        serverZoneAndArea(zoneAndArea);
        if (const grave = closestGraveyard(context.data, context.client, player.data.map, at, teamId,
                zoneAndArea[0], zoneAndArea[1], battlegroundGraveyards()))
        {
            // No teleport while leaving: the save puts the ghost at its graveyard.
            player.data.map = grave.map;
            instanceId_ = 0; // graveyards are outside
            player.movement.position = Position(grave.x, grave.y, grave.z, 0);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A player killed lies rooted; released, it is a ghost at its graveyard with its corpse saved where
 * it fell; it can take its body back near it once the delay is over, or come back at once at a
 * spirit healer. A creature killed leaves a corpse for a while, then goes, and comes back when its
 * respawn time is up (saved, so a restart keeps it).
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : worldSafeLocsFormat;
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.creature : Creature;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid, ClientTeleportAck;
    import dmangos.world.player : DeathState, PlayerFlags;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : GraveyardLink;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // One graveyard for the whole map, 60 yards west of Goldshire's inn.
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.worldSafeLocs = typeof(context.client.worldSafeLocs).parse(buildDbc(worldSafeLocsFormat,
        [[7u, 0, bits(-9010), bits(-132), bits(83.5f), 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "WorldSafeLocs.dbc");
    context.data.graveyards[graveyardLinkKey(0, 1)] = [GraveyardLink(7, 0)];
    foreach (ref spawn; context.data.creatureSpawns)
        if (spawn.guid == innkeeperSpawn)
            spawn.respawnSeconds = spawn.respawnSecondsMax = 120;

    const fell = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    auto anduin = loggedIn(context, db, 7, "Anduin", fell);
    anduin.read();
    auto me = anduin.session.character;

    // Killed by a creature: no health, rooted, gear worn by a tenth.
    MeleeDamage blow;
    blow.damage = 10_000;
    blow.outcome = MeleeHitOutcome.normal;
    anduin.session.inWorld.unit.meleeHitBy(0xF130_0000_0000_0001, blow);
    auto died = opcodesOf(anduin.read());
    assert(me.deathState == DeathState.corpse && me.values.get!UNIT_FIELD_HEALTH == 0);
    assert(died.canFind(Opcode.SMSG_FORCE_MOVE_ROOT) && died.canFind(Opcode.SMSG_DURABILITY_DAMAGE_DEATH));

    // Released: a ghost (25% faster, walking on water) at the graveyard, its corpse saved where it fell.
    anduin.write(Opcode.CMSG_REPOP_REQUEST, null);
    auto released = opcodesOf(anduin.read());
    assert(me.deathState == DeathState.ghost && (me.values.get!PLAYER_FLAGS & PlayerFlags.ghost));
    assert(released.canFind(Opcode.SMSG_CORPSE_RECLAIM_DELAY) && released.canFind(Opcode.SMSG_MOVE_WATER_WALK)
        && released.canFind(Opcode.MSG_MOVE_TELEPORT_ACK));
    assert(7 in db.corpses && db.corpses[7].x == fell.x && me.values.get!UNIT_FIELD_HEALTH == 1);
    assert(me.speeds[1] > 8.7f && me.speeds[1] < 8.8f);
    anduin.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.guid, 0, 0));
    anduin.read();
    assert(me.position.x == -9010);

    // The corpse's place, for the map.
    anduin.write(Opcode.MSG_CORPSE_QUERY, null);
    auto query = anduin.read();
    assert(query[0].body_[0] == 1);

    // Taking the body back: not from the graveyard, and not before the delay is over (60 s: released in the
    // second it died).
    anduin.write(Opcode.CMSG_RECLAIM_CORPSE, ClientGuid(0));
    assert(me.deathState == DeathState.ghost);
    now += 70.seconds;
    anduin.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(fell.x - 5, fell.y, fell.z)));
    anduin.read();
    anduin.write(Opcode.CMSG_RECLAIM_CORPSE, ClientGuid(0));
    assert(me.deathState == DeathState.alive && !(me.values.get!PLAYER_FLAGS & PlayerFlags.ghost));
    assert(me.values.get!UNIT_FIELD_HEALTH == me.values.get!UNIT_FIELD_MAXHEALTH / 2 && 7 !in db.corpses);
    anduin.read();

    // Again, and this time the spirit healer (the innkeeper stands in for one).
    anduin.session.inWorld.unit.meleeHitBy(0xF130_0000_0000_0001, blow);
    anduin.write(Opcode.CMSG_REPOP_REQUEST, null);
    anduin.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.guid, 0, 0));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto keeper = cast(Creature) context.map(0).findObject(innkeeper);
    keeper.values.set!UNIT_NPC_FLAGS(0x20u);
    keeper.movement.position = Position(-9011, -132, 83.5f);
    anduin.write(Opcode.CMSG_SPIRIT_HEALER_ACTIVATE, ClientGuid(innkeeper));
    assert(me.deathState == DeathState.alive && 7 !in db.corpses);
    anduin.read();

    // A creature killed: its corpse lasts 60 s, then it goes; it comes back 120 s after its death.
    keeper.values.set!UNIT_FIELD_HEALTH(0u);
    keeper.die(context.map(0), context.unixTime);
    context.creatureDied(keeper);
    assert(innkeeperSpawn in db.creatureRespawns);
    foreach (_; 0 .. 70)
    {
        now += 1.seconds;
        context.update(now);
    }
    assert(context.map(0).findObject(innkeeper) is null, "its corpse is gone");
    assert(context.awaitingRespawn(innkeeperSpawn));
    foreach (_; 0 .. 60)
    {
        now += 1.seconds;
        context.update(now);
    }
    auto back = cast(Creature) context.map(0).findObject(innkeeper);
    assert(back !is null && back.alive && back !is keeper, "made anew at its spawn");
    assert(innkeeperSpawn !in db.creatureRespawns);
}

/// A ghost logging in is one again, by its saved corpse; it takes its body back, and is saved alive.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.world.database : CorpseRecord;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : CharacterData, DeathState, PlayerFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    db.corpses[7] = CorpseRecord(7, at.x + 3, at.y, at.z, 0, 0, context.unixTime - 100, 1);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.player, raceHuman, 0, 1,
        (ref CharacterData c) { c.playerFlags = PlayerFlags.ghost; c.health = 60; });
    anduin.read();
    auto me = anduin.session.character;
    assert(me.deathState == DeathState.ghost && me.values.get!UNIT_FIELD_HEALTH == 1);
    now += 5.seconds;
    anduin.session.update(5.seconds);
    assert(me.values.get!UNIT_FIELD_HEALTH == 1, "a ghost does not heal");
    anduin.write(Opcode.CMSG_RECLAIM_CORPSE, ClientGuid(0));
    assert(me.deathState == DeathState.alive);
    const half = me.values.get!UNIT_FIELD_MAXHEALTH / 2;
    assert(me.values.get!UNIT_FIELD_HEALTH == half);
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    now += 25.seconds;
    anduin.session.update(25.seconds);
    const saved = db.progressSaves[$ - 1];
    assert(saved.playerFlags == 0 && saved.health >= half, "saved alive");
}
