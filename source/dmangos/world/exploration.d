/**
 * Where a player is, from the map data (`dmangos.world.terrain`), and what that brings: the zone
 * and area (`Player::UpdateZone`, `UpdateArea`, the once-a-second zone check of `Player::Update`
 * and the client's `CMSG_ZONEUPDATE`), explored areas and their experience
 * (`Player::CheckAreaExploreAndOutdoor`), and experience itself (`Player::GiveXP`). Mixed into
 * `dmangos.world.character.Character`.
 *
 * As in CMaNGOS, the server decides the zone: the client's `CMSG_ZONEUPDATE` only asks it to look
 * at the next position. Where there is no map data (none extracted, or a map without files and
 * without an area of its own), the client's zone is taken as it comes, and its area is the zone,
 * which is how this server worked before it read maps. Without vmaps every point is outdoors.
 */
module dmangos.world.exploration;

/// See the module documentation.
mixin template Exploration()
{
    import dmangos.world.channelservice : ChannelOp;
    import std.algorithm.comparison : max, min;
    import dmangos.log;
    import dmangos.world.defines : exploredZonesSize;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : RestType;
    import dmangos.world.terrain : Terrain;
    import dmangos.world.updatefields;

private:
    /// `AREA_FLAG_CAPITAL`
    enum uint areaFlagCapital = 0x100;

    /// The player's map's terrain, if it has data where the player is.
    Terrain mappedTerrain()
    {
        auto terrain = context.terrain(player.data.map);
        const p = player.position;
        return terrain.knows(p.x, p.y) ? terrain : null;
    }

    /// `Player::GetZoneAndAreaId`: [zone, area] where the player is; null where there is no map data.
    bool serverZoneAndArea(out uint[2] zoneAndArea)
    {
        auto terrain = mappedTerrain();
        if (terrain is null)
            return false;
        const p = player.position;
        zoneAndArea = terrain.zoneAndArea(p.x, p.y, p.z);
        return true;
    }

    /// The zone and area on arrival (logging in, a far teleport), before `SMSG_INIT_WORLD_STATES` names the zone.
    void setZoneOnArrival()
    {
        uint[2] found;
        if (serverZoneAndArea(found) && context.client.areas.lookup(found[0]) !is null)
        {
            player.data.zone = found[0];
            player.area = found[1];
        }
        else
            player.area = player.data.zone;
        zoneTimer.reset();
        lastPositionCheck = serverTime() - 100; // the first move is checked
    }

    /// `WorldSession::HandleZoneUpdateOpcode`: the client thinks it entered `zone`; the next move tells.
    @Handles(Opcode.CMSG_ZONEUPDATE, WorldState.inWorld)
    void handleZoneUpdate(const ClientZoneUpdate request)
    {
        if (mappedTerrain() is null)
        {
            // No map data: the client's word is all there is.
            if (request.zone != player.data.zone)
                updateZone(request.zone, request.zone);
            return;
        }
        zoneUpdatePending = true;
        pendingZone = request.zone;
    }

    /**
     * After the player moved (`Player::SetPosition`): a zone the client announced is checked against
     * the map data, and, at most every 100 ms, what the player has explored.
     */
    void afterMove()
    {
        if (zoneUpdatePending)
        {
            zoneUpdatePending = false;
            uint[2] found;
            if (serverZoneAndArea(found))
            {
                if (found[0] != pendingZone)
                    trace!"'%s' announced zone %s, the map says %s"(player.data.name, pendingZone, found[0]);
                updateZone(found[0], found[1]);
            }
        }
        const now = serverTime();
        if (now - lastPositionCheck >= 100) // m_positionStatusUpdateTimer
        {
            lastPositionCheck = now;
            checkAreaExplore();
        }
    }

    /// `Player::Update`'s zone check, every second: a new zone, or a new area in the same zone.
    void checkZone()
    {
        uint[2] found;
        if (!serverZoneAndArea(found))
            return;
        if (found[0] != player.data.zone)
            updateZone(found[0], found[1]);
        else if (found[1] != player.area)
            updateArea(found[1]);
    }

    /**
     * `Player::UpdateZone`: world states for the zone, its channels, rest in a capital, and the area.
     * A zone `AreaTable.dbc` does not know changes nothing.
     */
    void updateZone(uint zone, uint area)
    {
        const entry = context.client.areas.lookup(zone);
        if (entry is null)
            return;
        if (zone != player.data.zone)
        {
            player.data.zone = zone;
            sendInitWorldStates(zone);
            deliver(Opcode.SMSG_WEATHER, context.weatherFor(zone)); // `Player::UpdateZone`
            if (const zoneName = context.client.areaName(zone))
                context.channelCommand(this, ChannelOp.zoneChanged, null, zoneName);
        }
        zoneTimer.reset();
        updateArea(area);
        pvpZoneChanged(zone);

        // A capital rests; leaving it (not an inn: its trigger ends that) does not.
        const now = context.unixTime;
        if (entry.flags & areaFlagCapital)
        {
            if (player.restType != RestType.city)
                player.setRestType(RestType.city, now);
        }
        else if (player.restType == RestType.city)
            player.setRestType(RestType.none, now);
        flushPlayerChanges();
    }

    /// `Player::UpdateArea`: the group hears of the move.
    void updateArea(uint area)
    {
        const changed = area != player.area;
        player.area = area;
        if (changed)
            pvpAreaChanged(area);
        if (changed)
            if (auto group = context.groups.of(player.guid))
                group.updatePlayerOutOfRange(this, GroupUpdate.zone);
    }

    /// `Player::CheckAreaExploreAndOutdoor`: an area entered for the first time is explored, for experience.
    void checkAreaExplore()
    {
        if (!player.alive)
            return;
        auto terrain = mappedTerrain();
        if (terrain is null)
            return;
        const p = player.position;
        const flag = terrain.areaFlag(p.x, p.y, p.z);
        if (flag == 0xFFFF)
            return;
        const offset = flag / 32;
        if (offset >= exploredZonesSize)
        {
            error!"wrong area flag %s in map data at %s %s, map %s"(flag, p.x, p.y, player.data.map);
            return;
        }
        const bit = 1u << (flag % 32);
        const fields = player.values.get!PLAYER_EXPLORED_ZONES_1(offset);
        if (fields & bit)
            return;
        player.values.set!PLAYER_EXPLORED_ZONES_1(offset, fields | bit);
        flushPlayerChanges();

        const area = context.client.areaByFlag(flag, player.data.map);
        if (area is null)
        {
            error!"'%s' discovered an unknown area at %s %s, map %s"(player.data.name, p.x, p.y, player.data.map);
            return;
        }
        if (area.areaLevel <= 0)
            return;
        const level = player.data.level;
        if (level >= context.config.maxPlayerLevel)
            return send(ServerExplorationExperience(area.id, 0));
        const rate = context.config.rateXpExplore;
        const diff = cast(int) level - area.areaLevel;
        uint xp;
        if (diff < -5)
            xp = cast(uint)(baseXp(level + 5) * rate);
        else if (diff > 5)
        {
            const percent = max(0, min(100, 100 - (diff - 5) * 5));
            xp = cast(uint)(baseXp(area.areaLevel) * percent / 100 * rate);
        }
        else
            xp = cast(uint)(baseXp(area.areaLevel) * rate);
        giveXP(xp);
        send(ServerExplorationExperience(area.id, xp));
    }

    /// `ObjectMgr::GetBaseXP`
    uint baseXp(uint level)
    {
        return context.data.baseXp.get(level, 0);
    }

    /**
     * `Player::GiveXP` for experience not from a kill: logged to the client, and levels gained while
     * it lasts. Nothing past the highest level. Kills and quests will give theirs through it too.
     */
    package void giveXP(uint xp, ulong victim = 0, float groupRate = 1)
    {
        if (xp < 1 || !player.alive)
            return;
        const maxLevel = context.config.maxPlayerLevel;
        uint level = player.data.level;
        if (level >= maxLevel)
            return;
        // `GetXPRestBonus`: a kill gives as much again from the rested pool, while it lasts.
        uint rested;
        if (victim)
        {
            rested = cast(uint) player.restBonus;
            if (rested > xp)
                rested = xp;
            player.setRestBonus(player.restBonus - rested, maxLevel);
        }
        if (victim)
        {
            // `SendLogXPGain` for a kill: the victim, the whole gain, the gain without the rest, the group's rate.
            ByteWriter w;
            w.put(victim);
            w.put(xp + rested);
            w.put(ubyte(0));
            w.put(xp);
            w.put(groupRate);
            deliver(Opcode.SMSG_LOG_XPGAIN, w.data);
        }
        else
            send(ServerLogXpGain(0, xp));
        xp += rested;
        uint next = player.values[PLAYER_NEXT_LEVEL_XP];
        uint total = player.values[PLAYER_XP] + xp;
        while (total >= next && level < maxLevel)
        {
            total -= next;
            applyLevel(level + 1); // Player::GiveLevel
            level = player.data.level;
            next = player.values[PLAYER_NEXT_LEVEL_XP];
        }
        player.values.set!PLAYER_XP(total);
        flushPlayerChanges();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The map decides the zone and area; a new area is explored once, for experience.
unittest
{
    import core.time : Duration, MonoTime, seconds;
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import dmangos.bytes : ByteReader;
    import dmangos.extractor.maps : buildTestAdt, convertAdt, TestTerrain;
    import dmangos.serialization : deserialize;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : Player;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.terrain : pointAt;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    // One tile: Elwynn in its first eight rows of cells, Goldshire beyond.
    const dir = buildPath(tempDir, "dmangos-exploration-test");
    scope (exit)
        rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "maps"));
    TestTerrain land;
    land.height = (row, column) => 60.0f;
    land.areaId = (i, j) => i < 8 ? zoneElwynn : areaGoldshire;
    string problem;
    const ushort[uint] flags = [zoneElwynn: exploreElwynn, areaGoldshire: exploreGoldshire];
    write(buildPath(dir, "maps", "0004831.map"), convertAdt(buildTestAdt(land), flags, problem));

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig c) { c.dataDir = dir; });
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.xpForNextLevel = [0, 400, 900];
    context.data.baseXp[5] = 50;

    const elwynn = pointAt(48, 31, 10, 10), goldshire = pointAt(48, 31, 100, 10);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(elwynn[0], elwynn[1], 60));
    anduin.read();
    context.update(now); // starts the update clock
    const me = anduin.session.character;
    assert(me.data.zone == zoneElwynn && me.area == zoneElwynn, "the map's zone at login");

    // The client claims Stormwind; the next move shows it is still in Elwynn.
    anduin.write(Opcode.CMSG_ZONEUPDATE, ClientZoneUpdate(zoneStormwind));
    now += 1.seconds;
    anduin.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(elwynn[0], elwynn[1], 60)));
    assert(me.data.zone == zoneElwynn);
    const elwynnBit = 1u << (exploreElwynn % 32);
    assert(me.values.get!PLAYER_EXPLORED_ZONES_1(exploreElwynn / 32) & elwynnBit, "Elwynn explored");
    anduin.read();

    // Into Goldshire, 375 yards on (a minute's run): explored, for its level's base experience.
    now += 60.seconds;
    anduin.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(goldshire[0], goldshire[1], 60)));
    const discovered = anduin.read();
    auto reader = ByteReader(bodyOf(discovered, Opcode.SMSG_EXPLORATION_EXPERIENCE));
    const found = deserialize!ServerExplorationExperience(reader);
    assert(found.area == areaGoldshire && found.experience == 50);
    assert(opcodesOf(discovered).canFind(Opcode.SMSG_LOG_XPGAIN) && me.values[PLAYER_XP] == 50);
    context.update(now += 1.seconds); // the zone check
    assert(me.area == areaGoldshire && me.data.zone == zoneElwynn);

    // Once only.
    now += 1.seconds;
    anduin.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(goldshire[0], goldshire[1] + 1, 60)));
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_EXPLORATION_EXPERIENCE) && me.values[PLAYER_XP] == 50);

    // Enough experience levels the player up, and the rest carries over.
    (cast(Player) me).values.set!PLAYER_XP(390u); // the test changes the player directly
    anduin.session.inWorld.giveXP(30);
    assert(me.data.level == 2 && me.values[PLAYER_XP] == 20);
}
