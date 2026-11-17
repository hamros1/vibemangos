/**
 * Teleports (CMaNGOS `Player::TeleportTo`, `MovementHandler.cpp`'s
 * acknowledgements, `MiscHandler.cpp`'s area triggers and world teleport).
 *
 * A teleport on the same map is "near": the server sends
 * `MSG_MOVE_TELEPORT_ACK` with the new position, the player is at the
 * destination from then on, and the client answers with the same opcode
 * once it has moved there. A teleport to another map is "far":
 * `SMSG_TRANSFER_PENDING` starts the loading screen, the player leaves its
 * map, `SMSG_NEW_WORLD` names the destination, and the client answers
 * `MSG_MOVE_WORLDPORT_ACK` when it has loaded it. The server then sends the
 * packets of a login again (the client forgets every object on a world
 * change) and puts the player on the new map.
 *
 * Between the order and the answer, movement packets are ignored, as in
 * CMaNGOS (`Player::IsBeingTeleported`). Logging out halfway saves the
 * destination.
 *
 * There is one map per map id, so a dungeon is shared by everyone who
 * enters it; instances per group come with instance binds.
 */
module dmangos.world.teleport;

/// Which teleport is waiting for the client's answer.
enum Teleport
{
    none,
    near, /// `MSG_MOVE_TELEPORT_ACK` expected
    far,  /// `MSG_MOVE_WORLDPORT_ACK` expected
}

/// `AreaLockStatus`: why an area trigger, or a map entrance, does not let a player through.
enum AreaLockStatus
{
    ok,
    tooLowLevel,
    raidLocked,
    missingItem,
    questNotCompleted,
    pvpRank,
    notAllowed,   /// a condition this server cannot check yet
    unknownError,
}

/// See the module documentation.
mixin template TeleportHandlers()
{
    import std.algorithm.comparison : among;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteWriter;
    import dmangos.log;
    import dmangos.world.clientdata : MapEntry;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : MovementFlags, MovementInfo, Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : RestType;
    import dmangos.world.teleport : AreaLockStatus, Teleport;
    import dmangos.world.worlddata : AreaTriggerTeleport;

private:
    /**
     * `Player::TeleportTo`: false if the destination is not valid or the player may not enter the
     * map. `trigger` is the area trigger walked into, if any; a teleport to another map without one
     * is checked against that map's entrance.
     */
    bool teleportTo(uint mapId, Position destination, const(AreaTriggerTeleport)* trigger = null)
    {
        const client = context.client;
        if (!client.isValidMapCoord(mapId, destination.x, destination.y, destination.z, destination.orientation))
        {
            warning!"%s: '%s' cannot be teleported to map %s (%.1f, %.1f, %.1f): not a valid position"(remoteAddress,
                player.data.name, mapId, destination.x, destination.y, destination.z);
            return false;
        }
        const mapEntry = client.maps.lookup(mapId);
        if (mapEntry.isBattleground)
            return false; // only through a battleground queue, which does not exist yet

        if (player.data.map != mapId && trigger is null)
            trigger = context.data.mapEntranceTrigger(mapId, client);
        if (trigger !is null)
        {
            uint requirement;
            const status = lockStatus(*trigger, mapEntry, requirement);
            if (status != AreaLockStatus.ok)
            {
                sendLockStatus(*trigger, status, requirement);
                return false;
            }
        }

        // The client goes on with no movement flags.
        player.movement.flags = 0;
        if (player.data.map == mapId)
        {
            teleporting = Teleport.near;
            player.movement.position = destination;
            ByteWriter ack;
            ack.putPackedGuid(player.guid);
            ack.put(moveOrderCounter++);
            MovementInfo order = player.movement;
            order.time = serverTime();
            order.write(ack);
            deliver(Opcode.MSG_MOVE_TELEPORT_ACK, ack.data);

            // Unit::SendTeleportPacket: the others see the jump; then visibility at the new place.
            ByteWriter seen;
            seen.putPackedGuid(player.guid);
            order.write(seen);
            map.sendToWatchers(this, Opcode.MSG_MOVE_TELEPORT, seen.data);
            map.relocated(this);
        }
        else
        {
            player.setTarget(0);
            releaseLootOnLeave();
            spellsOnLeave();
            cancelTrade(true);
            duelComplete(dmangos.world.duelhandlers.DuelEnd.fled);
            flushPlayerChanges();
            send(ServerTransferPending(mapId));
            map.remove(this);
            // From here on the character is saved at its destination.
            teleporting = Teleport.far;
            player.data.map = mapId;
            player.movement.position = destination;
            send(ServerNewWorld(mapId, destination.x, destination.y, destination.z, destination.orientation));
        }
        info!"%s: '%s' teleported to map %s (%.1f, %.1f, %.1f)"(remoteAddress, player.data.name, mapId, destination.x,
            destination.y, destination.z);
        return true;
    }

    /// `Player::GetAreaTriggerLockStatus`
    AreaLockStatus lockStatus(const ref AreaTriggerTeleport trigger, const(MapEntry)* mapEntry, out uint requirement)
    {
        if (mapEntry is null)
            return AreaLockStatus.unknownError;
        if (triggerpassCheat) // ArcEmu: only `.cheat triggerpass` passes (CheckTriggerPrerequsites)
            return AreaLockStatus.ok;
        if (player.data.level < trigger.requiredLevel && !context.config.instanceIgnoreLevel)
        {
            requirement = trigger.requiredLevel;
            return AreaLockStatus.tooLowLevel;
        }
        if (mapEntry.isRaid && !context.config.instanceIgnoreRaid)
        {
            auto group = context.groups.of(player.guid);
            if (group is null || !group.isRaid)
                return AreaLockStatus.raidLocked;
        }
        // Either of the two items will do; the first missing one is reported.
        if (trigger.requiredItem)
        {
            if (!player.hasItem(trigger.requiredItem)
                && (!trigger.requiredItem2 || !player.hasItem(trigger.requiredItem2)))
            {
                requirement = trigger.requiredItem;
                return AreaLockStatus.missingItem;
            }
        }
        else if (trigger.requiredItem2 && !player.hasItem(trigger.requiredItem2))
        {
            requirement = trigger.requiredItem2;
            return AreaLockStatus.missingItem;
        }
        if (trigger.requiredQuest && trigger.requiredQuest !in player.data.rewardedQuests)
        {
            requirement = trigger.requiredQuest;
            return AreaLockStatus.questNotCompleted;
        }
        enum uint championsHall = 2532, hallOfLegends = 2527; // need PvP rank 6; there are no ranks yet
        if (trigger.id == championsHall || trigger.id == hallOfLegends)
            return AreaLockStatus.pvpRank;
        return AreaLockStatus.ok;
    }

    /// `Player::SendTransferAbortedByLockStatus`
    void sendLockStatus(const ref AreaTriggerTeleport trigger, AreaLockStatus status, uint requirement)
    {
        const ownText = status.among(AreaLockStatus.tooLowLevel, AreaLockStatus.questNotCompleted,
            AreaLockStatus.raidLocked, AreaLockStatus.pvpRank) != 0;
        if (ownText && trigger.failedText.length)
            return send(ServerAreaTriggerMessage(formatRequirement(trigger.failedText, requirement)));
        switch (status)
        {
        case AreaLockStatus.tooLowLevel:
            send(ServerAreaTriggerMessage(format!"You must be at least level %s to enter."(requirement)));
            break;
        case AreaLockStatus.missingItem:
            const item = requirement in context.data.items;
            send(ServerAreaTriggerMessage(format!"You must be at least level %s and have item %s to enter."(
                trigger.requiredLevel, item is null ? "?" : item.details.name)));
            break;
        default:
            break; // CMaNGOS sends nothing for the others either
        }
    }

    /// `SendAreaTriggerMessage(text, requirement)`: the text is a printf format with at most one number.
    static string formatRequirement(string text, uint requirement)
    {
        import std.array : replace;
        import std.conv : to;

        return text.replace("%u", requirement.to!string).replace("%d", requirement.to!string);
    }

    /// `WorldSession::HandleMoveWorldportAckOpcode`: the client has loaded the new map.
    @Handles(Opcode.MSG_MOVE_WORLDPORT_ACK, WorldState.inWorld)
    void handleWorldportAck()
    {
        if (teleporting != Teleport.far)
            return;
        teleporting = Teleport.none;
        sendInitialPacketsBeforeAddToMap();
        const self = player.createForSelf(serverTime());
        sendUpdate(self);
        player.inventory.markAllSent();
        map.add(this);
        sendInitialPacketsAfterAddToMap();
        resetMovementCheck();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.full);
    }

    /// `WorldSession::HandleMoveTeleportAckOpcode`: the client has arrived at a near teleport's destination.
    @Handles(Opcode.MSG_MOVE_TELEPORT_ACK, WorldState.inWorld)
    void handleTeleportAck(const ClientTeleportAck ack)
    {
        if (teleporting != Teleport.near || ack.guid != player.guid)
            return;
        teleporting = Teleport.none;
        resetMovementCheck();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.position);
    }

    /// `WorldSession::HandleAreaTriggerOpcode`: an instance portal, or another trigger that teleports.
    @Handles(Opcode.CMSG_AREATRIGGER, WorldState.inWorld)
    void handleAreaTrigger(const ClientAreaTrigger request)
    {
        if (teleporting != Teleport.none)
            return;
        const entry = context.client.areaTriggers.lookup(request.id);
        if (entry is null)
            return trace!"%s: unknown area trigger %s"(remoteAddress, request.id);
        enum float delta = 5; // the safe radius
        const p = player.position;
        if (!entry.contains(player.data.map, p.x, p.y, p.z, delta))
            return trace!"%s: '%s' is too far from area trigger %s"(remoteAddress, player.data.name, request.id);

        // An inn: rested XP while inside (a city's rest wins). Quest objectives and scripts are not handled yet.
        if (request.id in context.data.taverns)
        {
            if (player.restType != RestType.city)
            {
                player.setRestType(RestType.tavern, context.unixTime, request.id);
                flushPlayerChanges();
            }
            return;
        }
        const trigger = request.id in context.data.areaTriggers;
        if (trigger is null)
            return;
        if (trigger.conditionId && !triggerpassCheat)
        {
            // The `conditions` table is not loaded yet, so a trigger behind one stays closed.
            if (trigger.failedText.length)
                send(ServerAreaTriggerMessage(trigger.failedText));
            return;
        }
        teleportTo(trigger.targetMap, Position(trigger.x, trigger.y, trigger.z, trigger.orientation), trigger);
    }

    /// `WorldSession::HandleWorldTeleportOpcode`: the client's `worldport` command.
    @Handles(Opcode.CMSG_WORLD_TELEPORT, WorldState.inWorld)
    void handleWorldTeleport(const ClientWorldTeleport request)
    {
        if (account.level < AccountLevel.administrator)
            return sendNotification("You do not have permission to use this command.");
        teleportTo(request.map, Position(request.x, request.y, request.z, request.orientation));
    }

    /// ArcEmu's `Player::SafeTeleport`, which GM commands use: nothing happens while a teleport is under way.
    bool commandTeleport(uint mapId, Position destination)
    {
        if (teleporting != Teleport.none)
            return false;
        return teleportTo(mapId, destination);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime, seconds;
    import dmangos.world.testclient;

    /// A movement packet body at `position`.
    ubyte[] moveTo(Position position, uint flags = 0)
    {
        MovementInfo step;
        step.flags = flags;
        step.position = position;
        ByteWriter w;
        step.write(w);
        return w.data.dup;
    }
}

/// A command's near teleport: the order, movement ignored until the answer, then the arrival.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto watcher = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f));
    gm.read();

    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".worldport 0 -9464 62 56"));
    const order = gm.read();
    assert(opcodesOf(order) == [Opcode.MSG_MOVE_TELEPORT_ACK, Opcode.SMSG_UPDATE_OBJECT],
        "the order; Jaina is out of sight");
    auto reader = ByteReader(order[0].body_);
    assert(reader.readPackedGuid() == 7 && reader.read!uint == 0);
    assert(MovementInfo.read(reader).position == Position(-9464, 62, 56, 0));
    assert(opcodesOf(watcher.read()) == [Opcode.MSG_MOVE_TELEPORT, Opcode.SMSG_UPDATE_OBJECT]);
    assert(!context.map(0).seeEachOther(7, 8) && gm.session.character.position.x == -9464);

    // A move from before the teleport is ignored; the answer ends it.
    gm.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(-8949, -132, 83.5f)));
    assert(gm.session.character.position.x == -9464);
    gm.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(7, 0, 0));
    gm.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(-9463, 62, 56)));
    assert(gm.session.character.position.x == -9463);

    // And back.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".worldport 0 -8949.95 -132.49 83.53"));
    assert(gm.read()[0].opcode == Opcode.MSG_MOVE_TELEPORT_ACK && gm.session.character.position.x == -8949.95f);
}

/// `.recall port` to another map: the loading screen, the world change, and the world packets again.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto watcher = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f));
    gm.read();

    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".recall port orgrim"));
    const transfer = gm.read();
    assert(opcodesOf(transfer) == [Opcode.SMSG_TRANSFER_PENDING, Opcode.SMSG_NEW_WORLD]);
    auto reader = ByteReader(transfer[1].body_);
    const newWorld = deserialize!ServerNewWorld(reader);
    assert(newWorld.map == mapKalimdor && newWorld.x == 1629);
    assert(opcodesOf(watcher.read()) == [Opcode.SMSG_DESTROY_OBJECT], "gone from the old map");
    assert(gm.session.transferring && context.map(0).population == 1 && context.map(1).population == 0);

    // Logging out now would save the destination.
    assert(gm.session.character.progress(0).map == mapKalimdor);

    gm.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const arrival = opcodesOf(gm.read());
    with (Opcode)
        assert(arrival == [SMSG_SET_REST_START, SMSG_BINDPOINTUPDATE, SMSG_TUTORIAL_FLAGS, SMSG_INITIAL_SPELLS,
            SMSG_ACTION_BUTTONS, SMSG_INITIALIZE_FACTIONS, SMSG_LOGIN_SETTIMESPEED, SMSG_COMPRESSED_UPDATE_OBJECT,
            SMSG_FRIEND_LIST, SMSG_IGNORE_LIST, SMSG_INIT_WORLD_STATES]);
    assert(!gm.session.transferring && context.map(1).population == 1);

    // `.worldport` brings Anduin back, and Jaina sees him again.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".worldport 0 -8949.95 -132.49 83.53"));
    gm.read();
    gm.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    gm.read();
    assert(context.map(0).seeEachOther(7, 8) && opcodesOf(watcher.read()) == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);
}

/// The Deadmines entrance: too low a level gets the trigger's message; level 10 enters the dungeon.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto novice = loggedIn(context, db, 7, "Anduin", at);
    auto veteran = loggedIn(context, db, 8, "Jaina", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    novice.read();

    novice.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerDeadmines));
    const refused = novice.read();
    assert(opcodesOf(refused) == [Opcode.SMSG_AREA_TRIGGER_MESSAGE]);
    auto reader = ByteReader(refused[0].body_);
    assert(deserialize!ServerAreaTriggerMessage(reader).text == "You must be at least level 10 to enter.");

    // A trigger the player is not near does nothing.
    veteran.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(999));
    assert(veteran.read().length == 0);
    veteran.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerDeadmines));
    assert(opcodesOf(veteran.read()) == [Opcode.SMSG_TRANSFER_PENDING, Opcode.SMSG_NEW_WORLD]);
    veteran.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    assert(context.map(mapDeadmines).population == 1);

    assert(opcodesOf(novice.read()) == [Opcode.SMSG_DESTROY_OBJECT], "Jaina left the map");

    // `worldport` is an administrator's.
    novice.write(Opcode.CMSG_WORLD_TELEPORT, ClientWorldTeleport(0, mapMoltenCore, 1, 2, 3, 0));
    assert(opcodesOf(novice.read()) == [Opcode.SMSG_NOTIFICATION], "not an administrator");
}

/// The movement check: running is fine, a jump across the map is put back.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto runner = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));

    now += 3.seconds;
    runner.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(20, 0, 0), MovementFlags.forward));
    assert(runner.session.character.position.x == 20 && runner.read().length == 0, "20 yards in 3 s: fine");

    runner.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(400, 0, 0), MovementFlags.forward));
    const caught = runner.read();
    assert(opcodesOf(caught) == [Opcode.MSG_MOVE_TELEPORT_ACK] && runner.session.character.position.x == 20);
    runner.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(7, 0, 0));

    // Game masters are not checked.
    auto gm = loggedIn(context, db, 8, "Jaina", Position(0, 0, 0), AccountLevel.gameMaster);
    gm.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(4000, 0, 0)));
    assert(gm.session.character.position.x == 4000);
}
