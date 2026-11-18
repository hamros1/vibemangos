/**
 * Teleports: ordering one, the client's acknowledgements, area triggers and
 * the client's world teleport.
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
 * Between the order and the answer, movement packets are ignored.
 * Logging out halfway saves the
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

/// Why an area trigger, or a map entrance, does not let a player through.
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
    import dmangos.world.player : DeathState;
    import dmangos.world.quests : QuestState;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : RestType;
    import dmangos.world.teleport : AreaLockStatus, Teleport;
    import dmangos.world.worlddata : AreaTriggerTeleport;

private:
    private ulong ridingShip;     /// the ship a far teleport carries the player across on (0: none)
    private uint ridingShipEntry;
    private Position rideOffset;  /// where on the ship

    /**
     * The ship the player is on (its movement says so) crosses to map `mapId`, arriving at `shipAt`: the
     * player goes with it, at the same place aboard. The loading screen names the ship, and the player is
     * on it when it arrives.
     */
    public void rideShipAcross(uint mapId, Position shipAt, ulong shipGuid, uint shipEntry)
    {
        import dmangos.world.transports : passengerPosition;

        const offset = player.movement.transportOffset;
        float x, y, z, o;
        passengerPosition(shipAt.x, shipAt.y, shipAt.z, shipAt.orientation, offset.x, offset.y, offset.z,
            offset.orientation, x, y, z, o);
        ridingShip = shipGuid;
        ridingShipEntry = shipEntry;
        rideOffset = offset;
        scope (exit)
            ridingShip = 0;
        if (!teleportTo(mapId, Position(x, y, z, o), null, uint.max, true))
            warning!"%s: '%s' could not cross on ship %s to map %s"(remoteAddress, player.data.name, shipEntry, mapId);
    }

    /**
     * Teleports the player: false if the destination is not valid or the player may not enter the
     * map. `trigger` is the area trigger walked into, if any; a teleport to another map without one
     * is checked against that map's entrance. `toInstance` is the dungeon copy to go into (a GM
     * appearing to a player there); by default the player's own (`instanceFor`). `checked`: the
     * entrance was checked on the node the player came from (it moved here to go in).
     *
     * In a cluster, a dungeon another node hosts is entered there: the player moves to that node
     * first (`migrateTo`), which teleports it into its copy.
     */
    package bool teleportTo(uint mapId, Position destination, const(AreaTriggerTeleport)* trigger = null,
        uint toInstance = uint.max, bool checked = false)
    {
        const client = context.client;
        if (!client.isValidMapCoord(mapId, destination.x, destination.y, destination.z, destination.orientation))
        {
            warning!"%s: '%s' cannot be teleported to map %s (%.1f, %.1f, %.1f): not a valid position"(remoteAddress,
                player.data.name, mapId, destination.x, destination.y, destination.z);
            return false;
        }
        const mapEntry = client.maps.lookup(mapId);
        // A battleground's map only into the copy the queue sent the player to (game
        // masters also into the copy of a player they go to).
        if (mapEntry.isBattleground)
        {
            const mine = battleground_.instance && (toInstance == uint.max || toInstance == battleground_.instance);
            if (!mine && !(toInstance != uint.max && account.level >= AccountLevel.gameMaster))
                return false;
            if (toInstance == uint.max)
                toInstance = battleground_.instance;
        }
        // Leaving a battleground's map for another: out of the copy.
        if (player.data.map != mapId && battleground_.instance && client.maps.lookup(player.data.map) !is null
            && client.maps.lookup(player.data.map).isBattleground)
            leaveBattleground(false);

        if (player.data.map != mapId && trigger is null && !checked)
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

        if (context.instanceable(mapId) && !context.hostsDungeon(mapId))
        {
            import dmangos.world.inworld : ArrivalAction;

            const host = context.dungeonHost(mapId);
            if (host == 0 || context.playerRelay is null || !context.canWrite() || transferring)
            {
                enum ubyte transferAbortNotFound = 0x02; // nobody hosts it this moment (its node is changing)
                deliver(Opcode.SMSG_TRANSFER_ABORTED, [transferAbortNotFound]);
                return false;
            }
            ArrivalAction action;
            action.teleportMap = mapId;
            action.teleportTo = destination;
            action.teleportInstance = toInstance;
            if (context.askDungeonEntry is null)
            {
                migrateTo(host, action);
                return true;
            }
            // The host decides (a lockout, a full copy): asked first, the player only moves to go in.
            if (dungeonEntryAsked != MonoTime.init && context.clock() - dungeonEntryAsked < 5.seconds)
                return false; // one question at a time
            dungeonEntryAsked = context.clock();
            const asked = player.guid;
            context.askDungeonEntry(host, player.guid, mapId, toInstance, account.level >= AccountLevel.gameMaster,
                (ubyte abort) {
                    dungeonEntryAsked = MonoTime.init;
                    if (player is null || player.guid != asked || state_ != WorldState.inWorld || transferring
                        || teleporting != Teleport.none)
                        return;
                    if (abort)
                        return deliver(Opcode.SMSG_TRANSFER_ABORTED, [abort]);
                    info!"%s: '%s' goes into map %s, which node %s hosts: moving there"(remoteAddress,
                        player.data.name, mapId, host);
                    migrateTo(host, action);
                });
            return true;
        }

        // Another node's ground on another map (a hearthstone, a graveyard, a GM's port): the player
        // moves there first and is teleported there, so the client never sees a world this node does
        // not simulate.
        if (player.data.map != mapId && !checked && context.regionOwnerAround !is null && context.playerRelay !is null
            && context.canWrite() && !transferring)
        {
            import dmangos.world.inworld : ArrivalAction;

            const owner = context.regionOwnerAround(mapId, destination, 0);
            if (owner && owner != context.nodeId)
            {
                ArrivalAction action;
                action.teleportMap = mapId;
                action.teleportTo = destination;
                action.teleportInstance = toInstance;
                info!"%s: '%s' goes to map %s, where node %s simulates: moving there"(remoteAddress, player.data.name,
                    mapId, owner);
                migrateTo(owner, action);
                return true;
            }
        }

        // A raid's lockout: bound to another copy than the group's, it does not go in.
        if (player.data.map != mapId && toInstance == uint.max && context.lockedOutOfGroupRaid(player.guid, mapId))
        {
            enum ubyte transferAbortNotFound = 0x02;
            deliver(Opcode.SMSG_TRANSFER_ABORTED, [transferAbortNotFound]);
            return false;
        }

        // The client goes on with no movement flags. Another copy of the same dungeon is another map.
        player.movement.flags = 0;
        const instance = toInstance != uint.max ? toInstance
            : player.data.map == mapId ? instanceId_ : context.instanceFor(player.guid, mapId);
        // No entering a copy of a dungeon with its most players already in (game masters aside).
        if (instance && (player.data.map != mapId || instance != instanceId_) && account.level < AccountLevel.gameMaster)
            if (const most = mapId in context.data.instanceMaxPlayers)
                if (auto there = context.existingMap(mapId, instance))
                    if (there.population >= *most)
                    {
                        enum ubyte transferAbortMaxPlayers = 0x01;
                        deliver(Opcode.SMSG_TRANSFER_ABORTED, [transferAbortMaxPlayers]);
                        return false;
                    }
        if (player.data.map == mapId && instance == instanceId_)
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

            // The others see the jump; then visibility at the new place.
            ByteWriter seen;
            seen.putPackedGuid(player.guid);
            order.write(seen);
            map.sendToWatchers(this, Opcode.MSG_MOVE_TELEPORT, seen.data);
            map.relocated(this);
            // The pet comes along.
            if (ownPet !is null && ownPet.alive)
            {
                petsOnLeave();
                petsOnArrival();
            }
        }
        else
        {
            player.setTarget(0);
            releaseLootOnLeave();
            spellsOnLeave();
            cancelTrade(true);
            duelComplete(dmangos.world.duelhandlers.DuelEnd.fled);
            petsOnLeave(); // it comes out again on the other side
            flushPlayerChanges();
            if (ridingShip)
            {
                // The loading screen of a crossing: the ship and the map it leaves.
                ByteWriter pending;
                pending.put(mapId);
                pending.put(ridingShipEntry);
                pending.put(player.data.map);
                deliver(Opcode.SMSG_TRANSFER_PENDING, pending.data);
            }
            else
                send(ServerTransferPending(mapId));
            map.remove(this);
            // From here on the character is saved at its destination (a dungeon: its instance).
            teleporting = Teleport.far;
            // Where it was before going into an instance, for `.instance exit`.
            if (instance && instanceId_ == 0)
            {
                entryMap = player.data.map;
                entryPoint = player.position;
            }
            instanceId_ = instance;
            if (mapEntry.isBattleground && instance == battleground_.instance) // the copy starts with its first player
            {
                import dmangos.world.bgqueue : battlegroundOfMap;

                context.battlegrounds.open(instance, battlegroundOfMap(mapId));
            }
            if (toInstance != uint.max && account.level < AccountLevel.gameMaster)
                context.bindOnEntering(player.guid, mapId, instance);
            player.data.map = mapId;
            player.movement.position = destination;
            if (ridingShip)
            {
                // Aboard: the new world gives the place on the ship, and the player stays on it.
                player.movement.flags = MovementFlags.onTransport;
                player.movement.transportGuid = ridingShip;
                player.movement.transportOffset = rideOffset;
                send(ServerNewWorld(mapId, rideOffset.x, rideOffset.y, rideOffset.z, rideOffset.orientation));
            }
            else
                send(ServerNewWorld(mapId, destination.x, destination.y, destination.z, destination.orientation));
        }
        info!"%s: '%s' teleported to map %s (%.1f, %.1f, %.1f)"(remoteAddress, player.data.name, mapId, destination.x,
            destination.y, destination.z);
        return true;
    }

    /// Whether the player may pass an area trigger into a map, and if not, why (and the level, item or quest needed).
    AreaLockStatus lockStatus(const ref AreaTriggerTeleport trigger, const(MapEntry)* mapEntry, out uint requirement)
    {
        if (mapEntry is null)
            return AreaLockStatus.unknownError;
        if (triggerpassCheat) // only `.cheat triggerpass` skips the requirements
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
        // The Hall of Champions and the Hall of Legends take a visual rank of 6.
        enum uint championsHall = 2532, hallOfLegends = 2527;
        if ((trigger.id == championsHall || trigger.id == hallOfLegends) && honorRank.visualRank < 6)
            return AreaLockStatus.pvpRank;
        return AreaLockStatus.ok;
    }

    /// Tells the player why it may not pass, in an area trigger message, for the reasons that have one.
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
            break; // nothing is sent for the others
        }
    }

    /// An area trigger message's text with its requirement: the text is a printf format with at most one number.
    static string formatRequirement(string text, uint requirement)
    {
        import std.array : replace;
        import std.conv : to;

        return text.replace("%u", requirement.to!string).replace("%d", requirement.to!string);
    }

    /// The client has loaded the new map.
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
        petsOnArrival();
        pvpArrived();
        battlegroundArrived();
        raidArrived();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.full);
    }

    private uint raidWarned; /// the last of a raid's reset warnings sent (seconds before it), in this copy
    private uint raidWarnedIn;

    /// `SMSG_RAID_INSTANCE_MESSAGE`: 4 welcome (more than an hour left), 1 hours, 2 minutes, 3 minutes: leave.
    private void sendRaidMessage(long left)
    {
        ByteWriter w;
        w.put(uint(left > 3600 ? 4 : left > 900 ? 1 : left > 300 ? 2 : 3));
        w.put(player.data.map);
        w.put(cast(uint)(left > 0 ? left : 0));
        deliver(Opcode.SMSG_RAID_INSTANCE_MESSAGE, w.data);
    }

    /// In a raid copy: welcomed with the time to its reset as it arrives.
    private void raidArrived()
    {
        const left = context.instanceResetAt(instanceId) - context.unixTime;
        if (instanceId == 0 || context.instanceResetAt(instanceId) == 0)
            return;
        raidWarnedIn = instanceId;
        raidWarned = uint.max;
        sendRaidMessage(left);
    }

    /**
     * In a raid copy as its reset comes: warned an hour, 15, 5 and 1 minute(s) before; at the reset it is
     * sent to its home (the copy, empty, resets).
     */
    package void updateRaidReset()
    {
        if (instanceId == 0 || teleporting != Teleport.none)
            return;
        const at = context.instanceResetAt(instanceId);
        if (at == 0)
            return;
        if (raidWarnedIn != instanceId)
        {
            raidWarnedIn = instanceId;
            raidWarned = uint.max;
        }
        const left = at - context.unixTime;
        if (left <= 0)
        {
            const home = player.data.homeBind;
            commandTeleport(home.map, Position(home.x, home.y, home.z, player.position.orientation));
            return;
        }
        foreach (mark; [3600u, 900, 300, 60])
            if (left <= mark && mark < raidWarned)
            {
                raidWarned = mark;
                sendRaidMessage(left);
                break;
            }
    }

    /// The client has arrived at a near teleport's destination.
    @Handles(Opcode.MSG_MOVE_TELEPORT_ACK, WorldState.inWorld)
    void handleTeleportAck(const ClientTeleportAck ack)
    {
        if (teleporting != Teleport.near || ack.guid != player.guid)
            return;
        teleporting = Teleport.none;
        resetMovementCheck();
        pvpArrived();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.position);
    }

    /// The player walked into an area trigger: an instance portal, or another trigger that teleports.
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

        // A battleground's own triggers (its flag rooms, exit portals) first.
        if (auto copy = currentBattleground())
            if (copy.rules.areaTrigger(copy, player.guid, request.id))
                return;

        // Its script first (`scripted_areatrigger`): it may handle the trigger itself.
        {
            import dmangos.script.api : Location;

            if (areaTriggerScript(request.id, Location(entry.x, entry.y, entry.z)))
                return;
        }

        // The place a quest under way asks for.
        if (const quest = request.id in context.data.quests.triggerQuests)
            if (player.deathState == DeathState.alive && questState(*quest) == QuestState.incomplete)
                areaExploredOrEventHappens(*quest);

        // An inn: rested XP while inside (a city's rest wins). Area trigger scripts are not handled yet.
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
        if (trigger.conditionId && !triggerpassCheat && !conditionMet(trigger.conditionId))
        {
            if (trigger.failedText.length)
                send(ServerAreaTriggerMessage(trigger.failedText));
            return;
        }
        teleportTo(trigger.targetMap, Position(trigger.x, trigger.y, trigger.z, trigger.orientation), trigger);
    }

    /// The client's `worldport` command.
    @Handles(Opcode.CMSG_WORLD_TELEPORT, WorldState.inWorld)
    void handleWorldTeleport(const ClientWorldTeleport request)
    {
        if (account.level < AccountLevel.administrator)
            return sendNotification("You do not have permission to use this command.");
        teleportTo(request.map, Position(request.x, request.y, request.z, request.orientation));
    }

    /// The teleport GM commands use: nothing happens while a teleport is under way.
    package bool commandTeleport(uint mapId, Position destination, uint toInstance = uint.max)
    {
        if (teleporting != Teleport.none)
            return false;
        return teleportTo(mapId, destination, null, toInstance);
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
    assert(gm.session.inWorld.transferring && context.map(0).population == 1 && context.map(1).population == 0);

    // Logging out now would save the destination.
    assert(gm.session.character.progress(0).map == mapKalimdor);

    gm.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const arrival = opcodesOf(gm.read());
    with (Opcode)
        assert(arrival == [SMSG_SET_REST_START, SMSG_BINDPOINTUPDATE, SMSG_TUTORIAL_FLAGS, SMSG_INITIAL_SPELLS,
            SMSG_ACTION_BUTTONS, SMSG_INITIALIZE_FACTIONS, SMSG_LOGIN_SETTIMESPEED, SMSG_COMPRESSED_UPDATE_OBJECT,
            SMSG_FRIEND_LIST, SMSG_IGNORE_LIST, SMSG_INIT_WORLD_STATES, SMSG_WEATHER]);
    assert(!gm.session.inWorld.transferring && context.map(1).population == 1);

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
    const instance = veteran.session.inWorld.instanceId;
    assert(instance != 0 && context.map(mapDeadmines, instance).population == 1, "in an instance of its own");

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

/**
 * Dungeon instances: two players on their own get a copy each; a group shares its leader's; a
 * creature killed in one copy is alive in the other; an empty copy goes after its unload delay,
 * and with it the binds to it.
 */
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.packets : ClientGroupName;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.config.instanceUnloadDelay = 60;
    const at = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    auto jaina = loggedIn(context, db, 8, "Jaina", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    auto varian = loggedIn(context, db, 9, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    assert(context.instanceable(mapDeadmines) && !context.instanceable(mapEasternKingdoms));

    const mine = context.instanceFor(7, mapDeadmines), hers = context.instanceFor(8, mapDeadmines);
    assert(mine && hers && mine != hers, "alone: a copy each");
    assert(context.instanceFor(7, mapDeadmines) == mine, "bound to it");

    // A group: Varian joins Jaina's and goes where her group is bound (she was bound before the group).
    jaina.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    assert(context.groups.of(9) !is null);
    // The group is bound by its first member to go in after it formed.
    jaina.session.inWorld.teleportTo(mapDeadmines, Position(-16, -383, 61));
    jaina.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const groupCopy = jaina.session.inWorld.instanceId;
    assert(context.instanceFor(9, mapDeadmines) == groupCopy, "the group's copy");

    // A creature of the dungeon killed in one copy lives in the other.
    CreatureSpawn defias = {guid: 79999, entry: creatureInnkeeper, map: mapDeadmines, x: -16, y: -383, z: 61};
    auto inCopy = context.map(mapDeadmines, groupCopy), inMine = context.map(mapDeadmines, mine);
    auto a = context.makeCreature(&defias), b = context.makeCreature(&defias);
    a.instanceId = groupCopy;
    b.instanceId = mine;
    inCopy.addObject(a);
    inMine.addObject(b);
    a.die(inCopy, context.unixTime);
    context.creatureDied(a);
    assert(b.alive && a.guid == b.guid, "the same spawn, two copies");

    // Everyone out of Anduin's copy (he was never in it): it goes after a minute, and his bind with it.
    const count = context.instanceCount;
    now += 30.seconds;
    context.update(now);
    now += 31.seconds;
    context.update(now);
    now += 31.seconds;
    context.update(now);
    assert(context.instanceCount < count && context.existingMap(mapDeadmines, mine) is null, "reset");
    assert(context.existingMap(mapDeadmines, groupCopy) !is null, "Jaina's group's copy is in use");
    const again = context.instanceFor(7, mapDeadmines);
    assert(again != mine && again != groupCopy, "a fresh copy next time");

    // A full copy: no way in (here a limit of one, Jaina in it).
    context.data.instanceMaxPlayers[mapDeadmines] = 1;
    varian.read();
    assert(!varian.session.inWorld.commandTeleport(mapDeadmines, Position(-16, -381, 61), groupCopy), "full");
    assert(opcodesOf(varian.read()) == [Opcode.SMSG_TRANSFER_ABORTED]);
    context.data.instanceMaxPlayers[mapDeadmines] = 10;

    // Taken into another's copy (a GM's `.appear`): there, and they see each other.
    anduin.session.inWorld.commandTeleport(mapDeadmines, Position(-16, -382, 61), groupCopy);
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    assert(anduin.session.inWorld.instanceId == groupCopy && context.seeEachOther(7, 8));
    assert(!context.seeEachOther(7, 9), "Varian is still outside");
}

/**
 * Instances saved: a raid copy, its binds and its dead come back after a restart, its lockout with
 * them; a player bound to one raid copy cannot follow a group bound to another.
 */
unittest
{
    import dmangos.world.creature : Creature, CreatureSpawn;
    import dmangos.world.packets : ClientGroupName;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 60);
    auto jaina = loggedIn(context, db, 8, "Jaina", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 60);

    const his = context.instanceFor(7, mapMoltenCore), hers = context.instanceFor(8, mapMoltenCore);
    assert(his && hers && his != hers);
    CreatureSpawn rager = {guid: 56000, entry: creatureInnkeeper, map: mapMoltenCore, x: 1, y: 1, z: 1};
    auto creature = context.makeCreature(&rager);
    creature.instanceId = his;
    context.map(mapMoltenCore, his).addObject(creature);
    creature.die(context.map(mapMoltenCore, his), context.unixTime);
    context.creatureDied(creature);
    assert(context.deadInInstance(his, 56000));

    // Grouped under Jaina, whose copy the group is bound to: Anduin is locked to his own.
    jaina.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("anduin"));
    anduin.write(Opcode.CMSG_GROUP_ACCEPT, null);
    assert(context.instanceFor(8, mapMoltenCore) == hers);
    assert(context.lockedOutOfGroupRaid(7, mapMoltenCore) && !context.lockedOutOfGroupRaid(8, mapMoltenCore));
    context.config.instanceIgnoreRaid = true; // a party may enter, for the test
    anduin.read();
    assert(!anduin.session.inWorld.commandTeleport(mapMoltenCore, Position(1, 1, 1)), "locked out");
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_TRANSFER_ABORTED]);

    // A restart: the copies, binds and dead are read back.
    auto again = newCreationContext(db);
    assert(again.instanceCount == 2);
    assert(again.instanceFor(7, mapMoltenCore) == his, "his lockout");
    assert(again.deadInInstance(his, 56000), "its dead stay dead");
}

/**
 * Dungeons in a cluster (docs/CLUSTER.md): node 2 hosts the Deadmines, node 1 the ground
 * outside. A player on node 1 going in moves to node 2 first and gets its copy there, with an id of
 * the cluster's; another player sent into that copy (as `.appear` and `.summon` do) joins it there;
 * `.instance exit` brings the first out, and on node 1's ground it moves back home. A player saved
 * in the dungeon logging in on node 1 goes to node 2, into the copy it is bound to.
 */
unittest
{
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.context : PlayerRelay, WorldContext;
    import dmangos.world.character : Character;
    import dmangos.world.session : WorldSession, WorldState;

    auto db = newDatabase();
    WorldContext[ushort] nodes = [1: newCreationContext(db), 2: newCreationContext(db)];
    auto now = MonoTime.currTime;
    foreach (id, node; nodes)
    {
        node.nodeId = id;
        node.clock = () => now;
        node.regionOwnerAround = (uint m, Position, float) => m == mapDeadmines ? ushort(2) : ushort(1);
    }

    static final class Mesh
    {
        WorldContext[ushort] nodes;
        WorldSession[uint][ushort] remotes; // node -> account -> owner-side session
        string[] log;
    }
    static final class Relay : PlayerRelay
    {
        Mesh mesh;
        ushort self;
        this(Mesh mesh, ushort self) { this.mesh = mesh; this.self = self; }
        void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
        {
            (cast(WorldSession) mesh.nodes[home].sessionOf(account)).fromOwner(opcode, body_);
        }
        void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
        {
            if (auto s = account in mesh.remotes.require(owner, null))
                s.fromHome(opcode, body_);
        }
        void disconnect(ushort owner, uint account) { mesh.remotes[owner][account].clientGone(); }
        void migrate(ushort target, uint account, const(ubyte)[] state)
        {
            mesh.log ~= format!"migrate %s->%s"(self, target);
            if (auto home = cast(WorldSession) mesh.nodes[target].sessionOf(account))
                if (home.state == WorldState.elsewhere)
                {
                    assert(home.arrive(state));
                    return;
                }
            const homeNode = Character.migrationHome(state);
            auto session = new WorldSession(mesh.nodes[target], Character.migrationAccount(state),
                homeNode ? homeNode : self);
            mesh.remotes.require(target, null)[account] = session;
            assert(session.arrive(state));
        }
        void left(ushort home, uint account, bool toCharacterScreen)
        {
            (cast(WorldSession) mesh.nodes[home].sessionOf(account)).ownerLeft(toCharacterScreen);
        }
        void remoteDone(uint account) { mesh.remotes[self].remove(account); }
        void moved(ushort home, uint account, ushort next)
        {
            (cast(WorldSession) mesh.nodes[home].sessionOf(account)).ownerMoved(next);
        }
    }
    auto mesh = new Mesh;
    mesh.nodes = nodes;
    foreach (id, node; nodes)
        node.playerRelay = new Relay(mesh, id);
    assert(nodes[2].hostsDungeon(mapDeadmines) && !nodes[1].hostsDungeon(mapDeadmines));
    assert(nodes[1].instanceFor(7, mapDeadmines) == 0, "node 1 does not choose copies of node 2's dungeon");

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto anduin = loggedIn(nodes[1], db, 7, "Anduin", outside, AccountLevel.administrator, raceHuman,
        mapEasternKingdoms, 60);
    auto jaina = loggedIn(nodes[1], db, 8, "Jaina", outside, AccountLevel.player, raceHuman, mapEasternKingdoms, 60);
    anduin.read();
    jaina.read();
    const anduinAccount = db.loadable[7].account, jainaAccount = db.loadable[8].account;

    // In: node 1 sends Anduin to node 2, which teleports him into a copy of its own making.
    anduin.say(".worldport 36 -16 -383 61");
    assert(mesh.log == ["migrate 1->2"] && anduin.session.state == WorldState.elsewhere);
    auto there = mesh.remotes[2][anduinAccount];
    there.update(1.seconds); // the arrival: the teleport, its packets through node 1 to the client
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_NEW_WORLD));
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const copy = there.inWorld.instanceId;
    assert(copy && nodes[2].instanceMap(copy).population == 1 && nodes[1].instanceCount == 0);
    assert(db.loadInstances().instances.canFind!(r => r.id == copy && r.map == mapDeadmines), "saved");

    // The host is asked first: with the copy full, Jaina does not move at all, and is told why.
    nodes[1].askDungeonEntry = (ushort host, ulong player, uint map, uint instance, bool gm, void delegate(ubyte) then)
        => then(nodes[host].dungeonEntryProblem(player, map, instance, gm));
    nodes[2].data.instanceMaxPlayers[mapDeadmines] = 1;
    jaina.read();
    jaina.session.inWorld.commandTeleport(mapDeadmines, Position(-16, -381, 61), copy);
    assert(mesh.log == ["migrate 1->2"] && jaina.session.state == WorldState.inWorld, "turned away where she is");
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_TRANSFER_ABORTED));
    nodes[2].data.instanceMaxPlayers[mapDeadmines] = 10;
    now += 6.seconds;

    // Jaina is sent into Anduin's copy: she moves to node 2 and goes into that one.
    jaina.session.inWorld.commandTeleport(mapDeadmines, Position(-16, -381, 61), copy);
    auto hers = mesh.remotes[2][jainaAccount];
    hers.update(1.seconds);
    jaina.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    assert(hers.inWorld.instanceId == copy && nodes[2].instanceMap(copy).population == 2);
    assert(nodes[2].seeEachOther(7, 8));

    // Out: Anduin goes back where he came in from, on node 1's ground: he moves home first and is
    // teleported there.
    anduin.say(".instance exit");
    assert(mesh.log[$ - 1] == "migrate 2->1" && anduin.session.state == WorldState.inWorld);
    anduin.session.update(1.seconds); // the arrival: the teleport
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    assert(anduin.session.character.data.map == mapEasternKingdoms);

    // `.instance info` of the copy from node 1: sent to node 2, which hosts it, and answered from there.
    {
        import dmangos.cluster.protocol : GmRemote;
        import dmangos.world.gminstance : describeInstance;
        import dmangos.world.gmtargets : GmRemoteOp, GmSink;

        GmRemote asked;
        ushort askedNode;
        nodes[1].gmRemote = (ushort node, const ref GmRemote m) { askedNode = node; asked = m; };
        anduin.read();
        anduin.say(format!".instance info %s"(copy));
        assert(askedNode == 2 && asked.op == GmRemoteOp.instanceInfo && asked.instance == copy);
        string[] lines;
        describeInstance(nodes[2], copy, GmSink((string text) { lines ~= text; }));
        assert(lines.length >= 5 && lines[0].canFind("Instance ID:") && lines[2].canFind("Non-Raid"), "node 2 answers");
        nodes[1].gmRemote = null;
    }
    assert(anduin.session.inWorld.instanceId == 0 && nodes[1].onlinePlayer(anduin.session.character.guid) !is null);

    // Jaina logs out in the dungeon; logging in again on node 1, she goes to node 2, into her copy.
    jaina.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    now += 30.seconds;
    hers.update(30.seconds);
    assert(jaina.session.state == WorldState.characterScreen);
    db.moveOfflineCharacter(8, mapDeadmines, -16, -381, 61, 1581); // as she was saved (the memory database keeps no progress)
    jaina.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(8));
    jaina.read();
    assert(jaina.session.state == WorldState.elsewhere && jaina.session.inWorld is null,
        "node 1 has no copy for her: she is simulated on node 2");
    jaina.session.update(1.seconds);
    assert(mesh.log[$ - 1] == "migrate 1->2");
    assert(mesh.remotes[2][jainaAccount].inWorld.instanceId == copy, "the copy she is bound to");
}

/**
 * A dungeon's region moving to another node (a rebalance, a takeover): the new host reads the copies,
 * binds and dead the last host saved, and goes on with ids above them; the last host forgets them
 * (from memory: the rows are the new host's now).
 */
unittest
{
    import dmangos.cluster.regions : Region;

    auto db = newDatabase();
    auto a = newCreationContext(db), b = newCreationContext(db);
    auto now = MonoTime.currTime;
    ushort host = 1;
    a.nodeId = 1;
    b.nodeId = 2;
    foreach (n; [a, b])
    {
        n.clock = () => now;
        n.regionOwnerAround = (uint, Position, float) => host;
    }
    const copy = a.instanceFor(7, mapDeadmines);
    assert(copy && b.instanceFor(7, mapDeadmines) == 0, "node 2 does not host it");
    db.saveInstanceRespawn(false, 79999, copy, 0); // a creature killed there

    // A creature of the copy, loaded and hurt on node 1.
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    CreatureSpawn defias = {guid: 79998, entry: creatureInnkeeper, map: mapDeadmines, x: -16, y: -383, z: 61};
    a.data.creatureSpawns ~= defias;
    b.data.creatureSpawns ~= defias;
    auto inCopy = a.map(mapDeadmines, copy);
    auto hurt = a.makeCreature(&a.data.creatureSpawns[$ - 1]);
    hurt.instanceId = copy;
    hurt.values.set!UNIT_FIELD_HEALTH(7u);
    inCopy.addObject(hurt);

    host = 2;
    ubyte[][uint] leaving;
    auto dungeon = [Region(40, mapDeadmines)];
    auto moving = dungeon.dup;
    moving[0].next = 2;
    a.regionsChanged(null, moving, null, leaving);
    const(ubyte)[][uint] arriving;
    foreach (id, bytes; leaving)
        arriving[id] = bytes;
    b.regionsChanged(dungeon, null, arriving, leaving);
    import dmangos.world.creature : Creature;

    auto there = b.instanceMap(copy);
    assert(there !is null, "the copy came along");
    auto same = cast(Creature) there.findObject(hurt.guid);
    assert(same !is null && same.instanceId == copy && same.values.get!UNIT_FIELD_HEALTH == 7, "as it was");
    assert(b.instanceFor(7, mapDeadmines) == copy, "the bind, as saved");
    assert(b.deadInInstance(copy, 79999), "its dead stay dead");
    const another = b.instanceFor(8, mapDeadmines);
    assert(another && another > copy, "new ids above the saved ones");
    assert(a.instanceState(copy) is null, "node 1 forgot it");
    assert(db.loadInstances().instances.length == 2, "and deleted nothing");
}

/// Resetting one's dungeons: an empty copy goes (and the bind with it); one with the player inside does not.
unittest
{
    import std.algorithm.searching : canFind;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    anduin.read();
    const first = context.instanceFor(7, mapDeadmines);
    anduin.write(Opcode.CMSG_RESET_INSTANCES, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_INSTANCE_RESET), "reset");
    assert(context.instanceFor(7, mapDeadmines) != first, "a new copy next time");

    anduin.session.inWorld.teleportTo(mapDeadmines, Position(-16, -383, 61));
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    anduin.read();
    anduin.write(Opcode.CMSG_RESET_INSTANCES, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_INSTANCE_RESET_FAILED), "not while inside");
}

/// A raid's copies reset all together at fixed times: welcomed with the time left, warned before, sent home at it.
unittest
{
    import core.time : minutes;
    import dmangos.world.context : WorldContext;

    // The schedule: the first a period after today at the hour, then a period on from the last.
    enum long day = 86_400;
    const now = 20_000 * day + 10 * 3600; // 10:00
    assert(WorldContext.nextRaidReset(0, now, 7, 4) == 20_007 * day + 4 * 3600);
    assert(WorldContext.nextRaidReset(20_000 * day + 4 * 3600, now, 7, 4) == 20_007 * day + 4 * 3600,
        "this morning's past: a week on");
    assert(WorldContext.nextRaidReset(19_990 * day + 4 * 3600, now, 3, 4) == 20_002 * day + 4 * 3600, "missed ones skipped");

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto clock = MonoTime.currTime;
    context.clock = () => clock;
    const reset = context.raidResetAt(mapMoltenCore);
    assert(reset > context.unixTime && db.loadRaidResets()[mapMoltenCore] == reset, "kept in instance_reset");

    auto ragna = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    ragna.read();
    ragna.write(Opcode.CMSG_WORLD_TELEPORT, ClientWorldTeleport(0, mapMoltenCore, 1, 2, 3, 0));
    ragna.read();
    ragna.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const copy = ragna.session.inWorld.instanceId;
    assert(copy && context.instanceResetAt(copy) == reset, "its copy resets with the raid");
    const welcome = bodyOf(ragna.read(), Opcode.SMSG_RAID_INSTANCE_MESSAGE);
    assert(welcome.length == 12 && ByteReader(welcome).read!uint == 4, "welcomed");

    // An hour before: the warning in hours; a minute before: leave.
    clock += (reset - context.unixTime - 3500).seconds;
    ragna.session.update(1.seconds);
    auto warned = bodyOf(ragna.read(), Opcode.SMSG_RAID_INSTANCE_MESSAGE);
    assert(warned.length == 12 && ByteReader(warned).read!uint == 1, "hours");
    ragna.session.update(1.seconds);
    assert(bodyOf(ragna.read(), Opcode.SMSG_RAID_INSTANCE_MESSAGE).length == 0, "once");
    clock += (reset - context.unixTime - 50).seconds;
    ragna.session.update(1.seconds);
    warned = bodyOf(ragna.read(), Opcode.SMSG_RAID_INSTANCE_MESSAGE);
    assert(warned.length == 12 && ByteReader(warned).read!uint == 3, "a minute: leave");

    // The reset: sent home; the copy, empty, goes.
    clock += 60.seconds;
    ragna.session.update(1.seconds);
    assert(opcodesOf(ragna.read()).canFind(Opcode.SMSG_TRANSFER_PENDING), "sent home");
    ragna.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    assert(ragna.session.character.data.map == mapEasternKingdoms);
    context.update(clock);
    context.update(clock + 1.seconds);
    assert(context.instanceResetAt(copy) == 0, "the copy reset");
    assert(context.raidResetAt(mapMoltenCore) > reset, "the next one");
}
