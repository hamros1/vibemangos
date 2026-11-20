/**
 * Handlers for a character in the world: logging out, movement, queries
 * (names, items, ...), the character's own settings, and chat.
 *
 * `InWorldHandlers` is mixed into `dmangos.world.character.Character`, like
 * `dmangos.world.charscreen.CharacterScreenHandlers`.
 *
 * Movement is shown to those who see the player (`dmangos.world.map`) and
 * checked against the player's speed. Chat reaches those in range, the
 * group, a channel or one player, depending on its type; a message starting
 * with `.` may be a command (`dmangos.world.commands`).
 */
module dmangos.world.inworld;

    import dmangos.world.movement : baseMoveSpeed, MovementFlags, MovementInfo, MoveType, movingOrTurning, Position;
    import dmangos.world.creature : Creature;
/// What a player moving to another node does on arrival (`performArrivalAction`).
struct ArrivalAction
{
    ulong attack;      /// a creature to attack
    uint spell;        /// a spell to cast ...
    ulong spellTarget; /// ... at this unit
    ulong loot;        /// a corpse to loot
    ulong useObject;   /// a game object to use
    ulong castObject;  /// the game object `spell` is cast at (a lock to open)
    ulong noticedBy;   /// a creature that noticed the player (it attacks, if it still would here)
    uint teleportMap = uint.max; /// a far teleport into a dungeon this node hosts (uint.max: none) ...
    Position teleportTo;         /// ... to here ...
    uint teleportInstance = uint.max; /// ... into this copy (uint.max: the player's own), its checks passed
}

mixin template InWorldHandlers()
{
    import core.time : Duration;
    import dmangos.world.inworld : ArrivalAction;

    private ArrivalAction pendingArrival; // what a player moved here for does at its first tick
    private bool battlegroundCheckDue;    // arrived on a battleground's map: is its copy still here?
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteWriter;
    import dmangos.log;
    import dmangos.world.defines : maxActionButtons;
    import dmangos.world.database : TicketRecord;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : baseMoveSpeed, MovementFlags, MovementInfo, MoveType, movingOrTurning, Position;
    import dmangos.world.objects : lowGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.auras : AuraInterrupt;
    import dmangos.world.tradehandlers : TradeStatus;
    import dmangos.world.duelhandlers : DuelEnd;
    import dmangos.world.player : DeathState, PlayerFlags, RestType;
    import dmangos.world.channelservice : ChannelOp;
    import dmangos.world.queries : chatMessage, ClientChat, ClientWho, whoList, WhoEntry, creatureQueryResponse, gameObjectQueryResponse,
        itemQueryResponse;
    import dmangos.world.teleport : Teleport;
    import dmangos.world.updatefields : PLAYER_FIELD_BYTES, UNIT_FIELD_BYTES_1;
    import dmangos.world.worlddata : CreateAction;

private:
    enum ubyte standStateStand = 0;

    /**
     * Saves the character and leaves the world, its channels and
     * (logging out normally, from a party) its group. `loggingOut` is false for a lost connection.
     */
    void leaveWorld(string why, bool loggingOut)
    {
        // The map it is on: `deathOnLogout` may put its saved place at a graveyard of another map.
        auto leaving = map;
        if (loggingOut)
            interruptAuras(AuraInterrupt.leaveWorld);
        releaseLootOnLeave();
        spellsOnLeave();
        petsOnLeave();
        dismissCompanion();
        cancelTrade(false, TradeStatus.targetLogout);
        duelComplete(DuelEnd.fled);
        if (player.deathState == DeathState.alive)
            saveAuras();
        saveCooldowns();
        saveQuests();
        saveReputation();
        saveHonor();
        saveEnchantmentTimes();
        saveItemDurations();
        battlegroundLoggedOut();
        saveBattleground();
        deathOnLogout();
        taxiOnLeave();
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        context.database.setOnline(player.data.guid, account.id, false, context.config.realmId);
        if (context.canWrite())
            info!"%s: '%s' left the world (%s); '%s' saved at map %s %.1f %.1f %.1f"(remoteAddress, account.username,
                why, player.data.name, progress.map, progress.position.x, progress.position.y, progress.position.z);
        else
            warning!"%s: '%s' left the world (%s); '%s' NOT saved: this node may no longer write (cluster lease lapsed)"(
                remoteAddress, account.username, why, player.data.name);
        if (attacking)
            stopAttack(false);
        leaveGroupsOnLogout(loggingOut);
        context.channelCommand(this, ChannelOp.leaveAll, null);
        announceToFriends(false);
        guildLogout();
        auto group = context.groups.of(player.guid);
        context.leaveWorld(this, leaving);
        // The others see the player offline; a party it left tells them itself (in a cluster, the
        // group here is a mirror that has not heard yet).
        if (group !is null && (group.isRaid || !loggingOut))
            group.updatePlayerOnlineStatus(this, false);
        player = null;
        teleporting = Teleport.none;
        state_ = WorldState.characterScreen;
        connection.playing = null; // the connection is back at the character screen
        if (homeNode) // simulated here for another node's client: it hears, and this session ends
        {
            context.playerRelay.left(homeNode, account.id, loggingOut);
            context.playerRelay.remoteDone(account.id);
            state_ = WorldState.closed;
        }
        loggingOut = false;
    }

    // -----------------------------------------------------------------------
    // Moving between nodes (docs/CLUSTER.md)
    // -----------------------------------------------------------------------

    /// How far around a player its ground must all be another node's before it moves there.
    enum float migrationMargin = 25;

    /**
     * The node this player's simulation should move to now, or 0. It moves when it stands well inside
     * another node's ground (`migrationMargin` all round: no going back and forth along a border), not
     * within ten seconds of its last move, nor while teleporting or logging out. Away from home, it
     * goes straight on to a third node, its home told.
     */
    ushort migrationTarget()
    {
        import core.time : seconds;

        if (context.regionOwnerAround is null || teleporting != Teleport.none || loggingOut || transferring)
            return 0;
        if (context.draining)
        {
            // This node is going: a visiting player moves on as soon as its ground is another's; one
            // whose client is here stays, and is logged out (saved) when the node stops.
            if (homeNode == 0)
                return 0;
            const next = context.regionOwnerAround(player.data.map, player.position, 0);
            return next == context.nodeId ? 0 : next;
        }
        if (migratedAt != MonoTime.init && context.clock() - migratedAt < 10.seconds)
            return 0;
        // A fight stays on the node it is on: the creatures it is with are simulated here. A flight too: the node
        // that flies it lands it (its state is not carried), and the player moves on from the ground.
        if (inCombat || flying)
            return 0;
        const owner = context.regionOwnerAround(player.data.map, player.position, migrationMargin);
        if (owner == 0 || owner == context.nodeId)
            return 0;
        return owner;
    }

    /**
     * What a player moved to the node simulating a creature does there at once: what it asked for
     * against the creature's replica on the node it came from (an attack, a spell, its loot).
     */
    void performArrivalAction(const ArrivalAction action)
    {
        pendingArrival = ArrivalAction.init;
        import dmangos.world.packets : ClientGuid;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        if (action.teleportMap != uint.max)
        {
            // Into a dungeon this node hosts: its copy is chosen here. Turned away (a lockout, a full
            // copy), the player goes back to the node of the ground it stands on at the next look.
            if (!teleportTo(action.teleportMap, action.teleportTo, null, action.teleportInstance, true))
                migratedAt = MonoTime.init;
            return;
        }

        if (action.attack)
            handleAttackSwing(ClientGuid(action.attack));
        if (action.noticedBy)
            if (auto creature = cast(Creature) map.findObject(action.noticedBy))
                if (creature.ai !is null && creature.ai.mayNotice)
                    creature.ai.moveInLineOfSight(unit, map);
        if (action.spell)
            if (const spell = context.data.spells.spell(action.spell))
                if (player.knowsSpell(action.spell))
                    castSpell(spell, SpellTargets(TargetFlags.unit, action.spellTarget), false, 0);
        if (action.loot)
            handleLoot(ClientGuid(action.loot));
        if (action.useObject)
            handleGameObjectUse(ClientGuid(action.useObject));
        if (action.spell && action.castObject)
            if (const spell = context.data.spells.spell(action.spell))
                if (player.knowsSpell(action.spell))
                {
                    SpellTargets t;
                    t.mask = TargetFlags.gameObject;
                    t.gameObject = action.castObject;
                    castSpell(spell, t, false, 0);
                }
    }

    /**
     * An action at another node's creature (its replica here): the player moves to that node, and
     * does it there (`performArrivalAction`). True if it moved.
     */
    package bool actAtReplica(ulong target, ArrivalAction action)
    {
        import dmangos.world.replication : Replica;

        auto replica = cast(Replica) map.findObject(target);
        if (replica is null || replica.owner == context.nodeId || context.playerRelay is null || !context.canWrite())
            return false;
        if (teleporting != Teleport.none || loggingOut || transferring)
            return false;
        info!"%s: '%s' acts at %s, which node %s simulates: moving there"(remoteAddress, player.data.name,
            target & 0xFFFF_FFFF, replica.owner);
        migrateTo(replica.owner, action);
        return true;
    }

    /**
     * Moves this player's simulation to node `target`: saved here, then loaded there with what its
     * client already has, so the client sees nothing of it. The client stays connected to its home,
     * whose id the state ends with (0: this node, when the player leaves home).
     */
    void migrateTo(ushort target, ArrivalAction action = ArrivalAction.init)
    {
        if (!context.canWrite())
            return;
        petsOnLeave(); // saved, to come out again there
        flushPlayerChanges();
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        saveAuras(); // the next node loads them, as it loads the rest
        saveCooldowns();
        saveQuests();
        saveReputation();
        saveHonor();
        saveBattleground();
        saveEnchantmentTimes();
        saveItemDurations();
        context.settleWrites(); // in the database before the next node loads it

        ByteWriter w;
        w.put(account.id);
        w.put(cast(uint) account.username.length);
        w.putBytes(cast(const(ubyte)[]) account.username);
        w.put(cast(ubyte) account.level);
        w.put(account.muteTime);
        w.put(player.data.guid);
        player.movement.write(w);
        const known = map.knownTo(player.guid);
        w.put(cast(uint) known.length);
        foreach (k; known)
            w.put(k);
        w.put(action.attack);
        w.put(action.spell);
        w.put(action.spellTarget);
        w.put(action.loot);
        w.put(action.useObject);
        w.put(action.castObject);
        w.put(action.noticedBy);
        w.put(action.teleportMap);
        w.put(action.teleportTo.x);
        w.put(action.teleportTo.y);
        w.put(action.teleportTo.z);
        w.put(action.teleportTo.orientation);
        w.put(action.teleportInstance);
        // The dungeon copy it is in, and where it came into it from (`.instance exit`).
        w.put(instanceId_);
        w.put(entryMap);
        w.put(entryPoint.x);
        w.put(entryPoint.y);
        w.put(entryPoint.z);
        w.put(entryPoint.orientation);
        // The client's address and build, for `.playerinfo` there.
        w.put(cast(uint) address.length);
        w.putBytes(cast(const(ubyte)[]) address);
        w.put(build);
        // The client numbers the movement orders it is sent (teleports, speed changes) and acknowledges
        // them by number: the next one goes on from there. And its speeds (`.modify speed` included).
        w.put(moveOrderCounter);
        foreach (speed; player.speeds)
            w.put(speed);
        w.put(homeNode); // last: `migrationHome` reads it there

        info!"%s: '%s' moves to node %s (at map %s %.1f %.1f)"(remoteAddress, player.data.name, target,
            player.data.map, player.position.x, player.position.y);
        context.leaveWorldForMigration(this, target);
        player = null;
        migratedAt = context.clock();
        if (homeNode == 0)
        {
            // The client's session: from now on it relays (set before the state goes, which may arrive at once).
            ownerNode = target;
            state_ = WorldState.elsewhere;
            connection.playing = null; // the connection relays; the character is simulated there
        }
        context.playerRelay.migrate(target, account.id, w.data);
        if (homeNode)
        {
            // Back home, or on to a third node, which the home is told of: this session's part is over.
            if (target != homeNode)
                context.playerRelay.moved(homeNode, account.id, target);
            context.playerRelay.remoteDone(account.id);
            state_ = WorldState.closed;
            connection.playing = null;
        }
    }

    /// The account a `migrateTo` state is for, to make the session on the node it arrives at.
    package static WorldAccount migrationAccount(const(ubyte)[] state)
    {
        auto r = ByteReader(state);
        WorldAccount a;
        a.id = r.read!uint;
        a.username = r.readString(r.read!uint);
        a.level = cast(AccountLevel) r.read!ubyte;
        a.muteTime = r.read!long;
        return a;
    }

    /// The node holding the client of a `migrateTo` state; 0 if it is the node that sent it.
    package static ushort migrationHome(const(ubyte)[] state)
    {
        if (state.length < 2)
            return 0;
        return cast(ushort)(state[$ - 2] | state[$ - 1] << 8);
    }

    /// The player's simulation arrives here (`migrateTo`'s state): false if its character cannot be loaded.
    package bool arrive(const(ubyte)[] state)
    {
        auto r = ByteReader(state);
        r.read!uint;
        r.readString(r.read!uint);
        r.read!ubyte;
        r.read!long;
        const guid = r.read!uint;
        const movement = MovementInfo.read(r);
        auto known = new ulong[r.read!uint];
        foreach (ref k; known)
            k = r.read!ulong;
        ArrivalAction action;
        action.attack = r.read!ulong;
        action.spell = r.read!uint;
        action.spellTarget = r.read!ulong;
        action.loot = r.read!ulong;
        action.useObject = r.read!ulong;
        action.castObject = r.read!ulong;
        action.noticedBy = r.read!ulong;
        action.teleportMap = r.read!uint;
        action.teleportTo = Position(r.read!float, r.read!float, r.read!float, r.read!float);
        action.teleportInstance = r.read!uint;
        instanceId_ = r.read!uint;
        entryMap = r.read!uint;
        entryPoint = Position(r.read!float, r.read!float, r.read!float, r.read!float);
        carriedAddress = r.readString(r.read!uint).idup;
        build = r.read!uint;
        moveOrderCounter = r.read!uint;
        typeof(Player.speeds) speeds;
        foreach (ref speed; speeds)
            speed = r.read!float;

        auto loaded = context.database.loadCharacter(guid);
        if (loaded.isNull || loaded.get.account != account.id)
            return false;
        auto character = loaded.get;
        character.position = movement.position;
        // In a dungeon this node hosts: its copy, if this node knows it (its last host saved it);
        // else the one the player is bound to, or a new one (it logged in there on another node).
        if (!context.instanceable(character.map))
            instanceId_ = 0; // not a dungeon: no copy, whatever came along
        else if (context.instanceState(instanceId_) is null)
            instanceId_ = context.instanceFor(guid, character.map);
        player = makePlayer(character, false);
        player.movement = movement;
        player.speeds = speeds; // as the client has them; auras loaded below change them as they did there
        saveTimer = IntervalTimer(context.config.playerSaveInterval.seconds);
        regenTimer.reset();
        enteredWorld = context.clock();
        migratedAt = context.clock();
        ownerNode = 0;
        state_ = WorldState.inWorld;
        connection.playing = this; // in the world from here on
        context.enterWorldMigrated(this, known);
        loadAuras();
        loadHonor();
        loadBattleground();
        loadEnchantmentTimers();
        loadItemDurations(0);
        loadCooldowns();
        loadTalentReset();
        loadSocial();
        refreshGuildFields();
        applyPassiveSpells();
        resetMovementCheck();
        petsOnArrival();
        pendingArrival = action; // done at the first tick here, once the move is complete everywhere
        battlegroundCheckDue = action.teleportMap == uint.max; // not on its way into a copy
        info!"%s: '%s' arrived from another node (map %s at %.1f %.1f)"(remoteAddress, character.name, character.map,
            character.position.x, character.position.y);
        return true;
    }

    /**
     * Logging out: not while jumping or falling; at once when resting
     * or for accounts with GM permissions; otherwise sitting, stunned, for `logout_delay` seconds.
     */
    @Handles(Opcode.CMSG_LOGOUT_REQUEST, WorldState.inWorld)
    void handleLogoutRequest()
    {
        const cantLogout = player.movement.has(MovementFlags.jumping) || player.movement.has(MovementFlags.fallingFar);
        const instant = player.hasFlag(PlayerFlags.resting) || hasPermissions || context.config.logoutDelay == 0;
        send(ServerLogoutResponse(cantLogout ? 1 : 0, instant && !cantLogout ? 1 : 0));
        if (cantLogout)
            return;
        if (instant)
            return completeLogout();
        logoutRequestedAt = context.clock();
        loggingOut = true;
        player.setLogoutStun(true);
        send(ServerMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)(player.guid, moveOrderCounter++));
        flushPlayerChanges();
    }

    @Handles(Opcode.CMSG_LOGOUT_CANCEL, WorldState.inWorld)
    void handleLogoutCancel()
    {
        send(ServerLogoutCancelAck());
        if (!loggingOut)
            return;
        loggingOut = false;
        player.setLogoutStun(false);
        send(ServerMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)(player.guid, moveOrderCounter++));
        flushPlayerChanges();
    }

    /// The end of a logout: saved, out of the world, and back on the character screen.
    void completeLogout()
    {
        loggingOut = false;
        leaveWorld("logged out", true);
        send(ServerLogoutComplete());
    }

    /**
     * One tick: the logout countdown, regeneration every
     * two seconds, rest, breath and fatigue, the zone check every second, and the periodic save.
     */
    void updateInWorld(Duration elapsed)
    {
        import core.time : seconds;

        if (loggingOut && context.clock() - logoutRequestedAt >= context.config.logoutDelay.seconds)
            return completeLogout();
        if (transferring)
            return;
        const config = context.config;

        if (pendingArrival != ArrivalAction.init)
            performArrivalAction(pendingArrival);
        if (battlegroundCheckDue)
        {
            battlegroundCheckDue = false;
            battlegroundOnLogin();
        }
        updateMelee(elapsed);
        if (player is null)
            return;
        updateSpells(elapsed);
        updateAuras(elapsed);
        updateMirrorTimers(elapsed);
        if (player is null)
            return;
        updateEnchantments(elapsed);
        updateItemDurations(elapsed);
        updateAutoRepeat(elapsed);
        updateAreaAuras(elapsed);
        updateTotems();
        updateTotemEnchants();
        updatePetMood(elapsed);
        updateTaxi(cast(int) elapsed.total!"msecs");
        updateCrowdControl(cast(int) elapsed.total!"msecs");
        updateReactives(cast(int) elapsed.total!"msecs");
        updateTimedQuests();
        refreshQuestObjects();
        updateRaidReset();
        updateHomebindTimer(cast(int) elapsed.total!"msecs");
        updateDuel();
        updatePvPTimers(cast(int) elapsed.total!"msecs");
        updateDeath(elapsed);
        if (regenTimer.update(elapsed))
        {
            const ms = cast(uint) regenTimer.takeAll().total!"msecs";
            // Only the living regenerate.
            if (player.deathState == DeathState.alive && player.regenerate(ms, config.rateHealth, config.rateMana, config.rateRageLoss, config.rateEnergy,
                    inCombat))
            {
                flushPlayerChanges();
                if (auto group = context.groups.of(player.guid))
                    group.updatePlayerOutOfRange(this, GroupUpdate.currentHealth | GroupUpdate.currentPower);
            }
        }

        if (restTimer.update(elapsed) && restTimer.consume())
        {
            const now = context.unixTime;
            // Leaving the inn ends the rest.
            if (player.restType == RestType.tavern)
            {
                const inn = context.client.areaTriggers.lookup(player.innTrigger);
                const p = player.position;
                if (inn is null || !inn.contains(player.data.map, p.x, p.y, p.z, 0))
                {
                    player.setRestType(RestType.none, now);
                    flushPlayerChanges();
                }
            }
            // Rested XP, counted in steps of 10 seconds.
            if (player.restType != RestType.none && now - player.restCountedAt >= 10)
            {
                player.setRestBonus(player.restBonus + player.computeRest(now - player.restCountedAt,
                    config.rateRestInGame), config.maxPlayerLevel);
                player.restCountedAt = now;
                flushPlayerChanges();
            }
        }

        if (zoneTimer.update(elapsed) && zoneTimer.consume())
        {
            checkZone();
            worldPvpCheck(); // the towers' capture bar, the zones' buffs, the Silithyst (`dmangos.world.worldpvp`)
            if (const target = migrationTarget())
                return migrateTo(target); // the player is simulated there from now on
        }

        // A save starts the interval again: no catching up after a stall.
        if (saveTimer.update(elapsed))
            savePlayer();
    }

    // -----------------------------------------------------------------------
    // Movement
    // -----------------------------------------------------------------------

    @Handles(movementOpcodes, WorldState.inWorld)
    void handleMovement(const MovementInfo movement, Opcode opcode)
    {
        // Possessing a creature (Mind Control, Eyes of the Beast), the client moves it, not the player.
        if (activeMover)
            return moveMover(movement, opcode);
        if (!takeMovement(movement, opcode))
            return;
        // Those who see the player see it move: the same opcode, with the mover's guid and the server's time.
        relayMovement(opcode, movement);
        movedOn(movement, opcode);
    }

    /**
     * `CMSG_MOVE_FALL_RESET`: a jump that hit something on the way up comes down sooner. Taken like any move,
     * but not shown to others: their clients have no handler for it (CMaNGOS).
     */
    @Handles(Opcode.CMSG_MOVE_FALL_RESET, WorldState.inWorld)
    void handleMoveFallReset(const MovementInfo movement)
    {
        if (takeMovement(movement, Opcode.CMSG_MOVE_FALL_RESET))
            movedOn(movement, Opcode.CMSG_MOVE_FALL_RESET);
    }

    /**
     * The first half of taking a client's move (its movement packets, and the acknowledgements that carry one:
     * CMaNGOS `ProcessMovementInfo`): checked, a landing's fall damage, then the player's movement. False if it
     * is not taken (nothing more is done with it). After showing it to others, `movedOn` does the rest.
     */
    package bool takeMovement(const MovementInfo movement, Opcode opcode)
    {
        // In flight, feared or disoriented the server moves the player (the client may still send heartbeats).
        if (flying || !inControl)
            return false;
        // A position the client cannot be at.
        const p = movement.position;
        if (!context.client.isValidMapCoord(player.data.map, p.x, p.y, p.z, p.orientation))
        {
            warning!"%s: '%s' sent an invalid position; disconnecting"(remoteAddress, player.data.name);
            disconnect();
            return false;
        }
        // Until the client confirms a teleport, its movement packets are from before it; a player
        // logging out is rooted.
        if (teleporting != Teleport.none || loggingOut)
            return false;
        // The fall it ends, judged before anything else (`dmangos.world.environment`).
        if (opcode == Opcode.MSG_MOVE_FALL_LAND)
            landed(movement);
        // On a ship or an elevator the player moves with it: not checked, and checked afresh once off.
        if (movement.has(MovementFlags.onTransport))
            checkpoint = p, checkpointTime = context.clock();
        else if (!passesSpeedCheck(p))
            return false;
        player.movement = movement;
        spellsOnMovement(movement.flags);

        // Moving stands the player up and ends a looping emote.
        if (movement.flags & movingOrTurning)
        {
            if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != standStateStand)
                player.setStandState(standStateStand);
            player.setEmoteState(0);
            flushPlayerChanges();
        }
        return true;
    }

    /// Shows the player's move to those who see it: `opcode`, its guid, the move at the server's time, then `extra`.
    /// The possessed creature moves where the client says, as those who see it are shown.
    private void moveMover(const MovementInfo movement, Opcode opcode)
    {
        auto creature = cast(Creature) map.findObject(activeMover);
        if (creature is null || !creature.alive)
            return;
        const p = movement.position;
        if (!context.client.isValidMapCoord(player.data.map, p.x, p.y, p.z, p.orientation))
            return;
        creature.movement.position = p;
        creature.movement.flags = movement.flags;
        ByteWriter relay;
        relay.putPackedGuid(creature.guid);
        MovementInfo relayed = movement;
        relayed.time = serverTime();
        relayed.write(relay);
        map.sendToObservers(creature.guid, opcode, relay.data);
        map.objectRelocated(creature);
    }

    /// The client says which unit it moves (as possession begins and ends): the server already knows.
    @Handles(Opcode.CMSG_SET_ACTIVE_MOVER, WorldState.inWorld)
    void handleSetActiveMover(ref ByteReader reader)
    {
    }

    package void relayMovement(Opcode opcode, const MovementInfo movement, scope const(ubyte)[] extra = null)
    {
        ByteWriter relay;
        relay.putPackedGuid(player.guid);
        MovementInfo relayed = movement;
        relayed.time = serverTime();
        relayed.write(relay);
        relay.putBytes(extra);
        map.sendToWatchers(this, opcode, relay.data);
    }

    /// The second half of taking a move (see `takeMovement`): where the player is now, for the map, the group,
    /// its zone and surroundings, and its fall.
    package void movedOn(const MovementInfo movement, Opcode opcode)
    {
        const p = movement.position;
        map.relocated(this);

        // Group members who do not see the player follow it on their map.
        if (distance2d(groupPositionAt, p) >= context.config.visibilityRelocationLimit)
            if (auto group = context.groups.of(player.guid))
            {
                groupPositionAt = p;
                group.updatePlayerOutOfRange(this, GroupUpdate.position);
            }
        afterMove();
        trackFall(movement, opcode);
        if (p.z < -500)
            fellUnderMap();
    }

    /**
     * Whether the player can have got to `position` since the last checkpoint, running (the fastest
     * it can move without spells or mounts), give or take the configured tolerance. A player that
     * could not is put back at the checkpoint. The checkpoint moves on every two seconds.
     */
    bool passesSpeedCheck(Position position)
    {
        import core.time : seconds;
        import std.algorithm.comparison : max;

        // Accounts with permissions skip the speed check.
        if (!context.config.movementSpeedCheck || hasPermissions)
            return true;
        const now = context.clock();
        const elapsed = (now - checkpointTime).total!"msecs" / 1000.0;
        const fastest = max(baseMoveSpeed[MoveType.run], baseMoveSpeed[MoveType.swim]);
        const allowed = fastest * context.config.movementSpeedTolerance * elapsed + context.config.movementSpeedSlack;
        const moved = distance2d(checkpoint, position);
        if (moved > allowed)
        {
            warning!"%s: '%s' moved %.1f yards in %.1f seconds (at most %.1f allowed); put back"(remoteAddress,
                player.data.name, moved, elapsed, allowed);
            teleportTo(player.data.map, checkpoint);
            return false;
        }
        if (now - checkpointTime >= 2.seconds)
        {
            checkpoint = position;
            checkpointTime = now;
        }
        return true;
    }

    /// Starts the movement check afresh at the player's position: at login and after teleports.
    void resetMovementCheck()
    {
        checkpoint = player.position;
        checkpointTime = context.clock();
        groupPositionAt = player.position;
    }

    static float distance2d(Position a, Position b)
    {
        import std.math : sqrt;

        return sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2);
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_NAME_QUERY, WorldState.inWorld)
    void handleNameQuery(const ClientNameQuery request)
    {
        if (const other = context.onlinePlayer(request.guid))
        {
            const c = other.character;
            return send(ServerNameQueryResponse(c.guid, c.data.name, "", c.data.race, c.data.gender, c.data.classId));
        }
        if (request.guid >> 48 != 0) // only players have names
            return;
        const found = context.database.nameInfo(lowGuid(request.guid));
        if (!found.isNull)
            send(ServerNameQueryResponse(request.guid, found.get.name, "", found.get.race, found.get.gender,
                found.get.classId));
    }

    /// The client asks for a page (a book's, a letter's, a plaque's): it and each page after it, in turn.
    @Handles(Opcode.CMSG_PAGE_TEXT_QUERY, WorldState.inWorld)
    void handlePageTextQuery(ref ByteReader reader)
    {
        uint page = reader.read!uint;
        foreach (_; 0 .. 64) // a chain of pages, not a loop
        {
            if (page == 0)
                break;
            ByteWriter w;
            w.put(page);
            if (const p = page in context.data.pageTexts)
            {
                w.putCString(p.text);
                w.put(p.next);
                page = p.next;
            }
            else
            {
                w.putCString("Item page missing.");
                w.put(0u);
                page = 0;
            }
            deliver(Opcode.SMSG_PAGE_TEXT_QUERY_RESPONSE, w.data);
        }
    }

    /// The client reads a carried item (one with pages): `SMSG_READ_ITEM_OK` and its guid; none there, not found.
    @Handles(Opcode.CMSG_READ_ITEM, WorldState.inWorld)
    void handleReadItem(ref ByteReader reader)
    {
        import dmangos.world.inventory : InventoryResult;

        const bag = reader.read!ubyte, slot = reader.read!ubyte;
        auto item = player.inventory[bag, slot];
        if (item is null || item.proto is null || item.proto.details.pageText == 0)
            return sendEquipError(InventoryResult.itemNotFound);
        ByteWriter w;
        w.put(item.fullGuid);
        deliver(Opcode.SMSG_READ_ITEM_OK, w.data);
    }

    @Handles(Opcode.CMSG_ITEM_QUERY_SINGLE, WorldState.inWorld)
    void handleItemQuery(const ClientItemQuerySingle request)
    {
        send(ServerItemQueryResponse(itemQueryResponse(request.entry, request.entry in context.data.items,
            context.data.spells)));
    }

    @Handles(Opcode.CMSG_CREATURE_QUERY, WorldState.inWorld)
    void handleCreatureQuery(const ClientObjectQuery request)
    {
        send(ServerCreatureQueryResponse(creatureQueryResponse(request.entry,
            request.entry in context.data.creatureTemplates)));
    }

    @Handles(Opcode.CMSG_GAMEOBJECT_QUERY, WorldState.inWorld)
    void handleGameObjectQuery(const ClientObjectQuery request)
    {
        send(ServerGameObjectQueryResponse(gameObjectQueryResponse(request.entry,
            request.entry in context.data.gameObjectTemplates)));
    }

    @Handles(Opcode.CMSG_QUERY_TIME, WorldState.inWorld)
    void handleQueryTime()
    {
        send(ServerQueryTimeResponse(cast(uint) context.unixTime));
    }

    @Handles(Opcode.CMSG_PLAYED_TIME, WorldState.inWorld)
    void handlePlayedTime()
    {
        const progress = player.progress(secondsInWorld());
        send(ServerPlayedTime(progress.totalTime, progress.levelTime));
    }

    // -----------------------------------------------------------------------
    // The character's own state
    // -----------------------------------------------------------------------

    /**
     * The client resets the player's dungeons (alone, or its group's as the leader): `SMSG_INSTANCE_RESET`
     * for each reset, `SMSG_INSTANCE_RESET_FAILED` (players still inside) for each that is not.
     */
    @Handles(Opcode.CMSG_RESET_INSTANCES, WorldState.inWorld)
    void handleResetInstances()
    {
        uint[] reset, busy;
        context.resetDungeonsOf(player.guid, reset, busy);
        foreach (mapId; reset)
        {
            ByteWriter w;
            w.put(mapId);
            deliver(Opcode.SMSG_INSTANCE_RESET, w.data);
        }
        foreach (mapId; busy)
        {
            enum uint playersInside = 0;
            ByteWriter w;
            w.put(playersInside);
            w.put(mapId);
            deliver(Opcode.SMSG_INSTANCE_RESET_FAILED, w.data);
        }
    }

    // -----------------------------------------------------------------------
    // GM tickets: the player's side
    // -----------------------------------------------------------------------

    /// Says `text` in the GM channel (`gm_client_channel`): to everyone in it, or (`toAll` false) to this player only.
    package void ticketChannelSay(string text, bool toAll)
    {
        import dmangos.world.channelservice : ChannelOp;
        import dmangos.world.queries : chatMessage;

        const channel = context.config.gmClientChannel;
        if (channel.length == 0)
            return;
        if (toAll)
            context.channelCommand(this, ChannelOp.forcedSay, channel, text);
        else
            deliver(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_CHANNEL, Language.LANG_UNIVERSAL, player.guid,
                text, 0, channel));
    }

    /// The player's open ticket, if any.
    package bool openTicket(uint playerLow, out TicketRecord ticket)
    {
        foreach (t; context.database.tickets(false))
            if (t.player == playerLow)
            {
                ticket = t;
                return true;
            }
        return false;
    }

    private void ticketResult(Opcode opcode, uint result)
    {
        ByteWriter w;
        w.put(result);
        deliver(opcode, w.data);
    }

    /**
     * The player asks for help: its pending ticket goes (closed), and a new one is made with its words and
     * where it stands; the GM channel hears of it ("GmTicket:1:id:level:name").
     */
    @Handles(Opcode.CMSG_GMTICKET_CREATE, WorldState.inWorld)
    void handleTicketCreate(ref ByteReader reader)
    {
        import std.format : format;

        enum uint createSuccess = 2;
        reader.read!ubyte; // its category
        TicketRecord t;
        t.map = reader.read!uint;
        t.x = reader.read!float;
        t.y = reader.read!float;
        t.z = reader.read!float;
        t.text = reader.readCString();
        TicketRecord pending;
        if (openTicket(cast(uint) player.guid, pending))
            context.database.closeTicket(pending.id);
        t.player = cast(uint) player.guid;
        t.name = player.data.name;
        t.level = player.data.level;
        t.created = context.unixTime;
        t.id = context.database.addTicket(t);
        ticketResult(Opcode.SMSG_GMTICKET_CREATE, createSuccess);
        ticketChannelSay(format!"GmTicket:1:%s:%s:%s"(t.id, t.level, t.name), true);
    }

    /// The player changes its ticket's words; the GM channel hears of it ("GmTicket:7:id").
    @Handles(Opcode.CMSG_GMTICKET_UPDATETEXT, WorldState.inWorld)
    void handleTicketUpdate(ref ByteReader reader)
    {
        import std.format : format;

        enum uint updateSuccess = 4, updateError = 5;
        const text = reader.readCString();
        TicketRecord t;
        if (!openTicket(cast(uint) player.guid, t))
            return ticketResult(Opcode.SMSG_GMTICKET_UPDATETEXT, updateError);
        context.database.updateTicketText(t.id, text, context.unixTime);
        ticketResult(Opcode.SMSG_GMTICKET_UPDATETEXT, updateSuccess);
        ticketChannelSay(format!"GmTicket:7:%s"(t.id), true);
    }

    /// The player takes its ticket back; the GM channel hears of it ("GmTicket:6:id").
    @Handles(Opcode.CMSG_GMTICKET_DELETETICKET, WorldState.inWorld)
    void handleTicketDelete()
    {
        import std.format : format;

        enum uint ticketDeleted = 9;
        TicketRecord t;
        const had = openTicket(cast(uint) player.guid, t);
        if (had)
            context.database.closeTicket(t.id);
        ticketResult(Opcode.SMSG_GMTICKET_DELETETICKET, ticketDeleted);
        if (had)
            ticketChannelSay(format!"GmTicket:6:%s"(t.id), true);
    }

    /// The client asks for the player's ticket: its words, and how long it has waited.
    @Handles(Opcode.CMSG_GMTICKET_GETTICKET, WorldState.inWorld)
    void handleTicketGet()
    {
        enum uint hasText = 6, noTicket = 10;
        TicketRecord t;
        if (!openTicket(cast(uint) player.guid, t))
            return ticketResult(Opcode.SMSG_GMTICKET_GETTICKET, noTicket);
        const days = (context.unixTime - t.created) / 86_400.0f;
        ByteWriter w;
        w.put(hasText);
        w.putCString(t.text);
        w.put(ubyte(0));   // its category
        w.put(days);       // days in the queue
        w.put(days);       // the oldest ticket's
        w.put(0.0f);       // since the oldest was last updated
        w.put(ubyte(0));   // not escalated
        w.put(ubyte(0));   // not read by a GM
        deliver(Opcode.SMSG_GMTICKET_GETTICKET, w.data);
    }

    /// The client asks whether tickets are taken (`.gmTicket toggle`).
    @Handles(Opcode.CMSG_GMTICKET_SYSTEMSTATUS, WorldState.inWorld)
    void handleTicketSystemStatus()
    {
        ticketResult(Opcode.SMSG_GMTICKET_SYSTEMSTATUS, context.gmTicketsOn ? 1 : 0);
    }

    /// Whether the client's settings of `type` are the character's (else the account's): types 1, 3, 5, 6, 7.
    private static bool perCharacterData(uint type) pure nothrow @nogc @safe
    {
        enum uint perCharacterMask = 0xEA;
        return ((1u << type) & perCharacterMask) != 0;
    }

    /// The client saves its settings of a type (zlib-compressed; an empty size erases them).
    @Handles(Opcode.CMSG_UPDATE_ACCOUNT_DATA, WorldState.inWorld)
    void handleUpdateAccountData(ref ByteReader reader)
    {
        import std.zlib : uncompress;

        const type = reader.read!uint, size = reader.read!uint;
        if (type >= 8 || size > 0xFFFF)
            return;
        const perCharacter = perCharacterData(type);
        const owner = perCharacter ? cast(uint) player.guid : account.id;
        const(ubyte)[] data;
        if (size)
        {
            try
                data = cast(const(ubyte)[]) uncompress(reader.readBytes(reader.remaining), size);
            catch (Exception e)
                return;
            // Kept as the text it is, without its final NUL.
            while (data.length && data[$ - 1] == 0)
                data = data[0 .. $ - 1];
        }
        context.database.saveAccountData(perCharacter, owner, type, context.unixTime, data);
    }

    /// The client asks for its settings of a type: `SMSG_UPDATE_ACCOUNT_DATA`, compressed.
    @Handles(Opcode.CMSG_REQUEST_ACCOUNT_DATA, WorldState.inWorld)
    void handleRequestAccountData(ref ByteReader reader)
    {
        import std.zlib : compress;

        const type = reader.read!uint;
        if (type >= 8)
            return;
        const perCharacter = perCharacterData(type);
        const data = context.database.accountData(perCharacter, perCharacter ? cast(uint) player.guid : account.id, type);
        ByteWriter w;
        w.put(type);
        w.put(cast(uint) data.length);
        if (data.length)
            w.putBytes(compress(data));
        deliver(Opcode.SMSG_UPDATE_ACCOUNT_DATA, w.data);
    }

    /// The client asks for an item's name (and its inventory type).
    @Handles(Opcode.CMSG_ITEM_NAME_QUERY, WorldState.inWorld)
    void handleItemNameQuery(ref ByteReader reader)
    {
        const entry = reader.read!uint;
        const item = entry in context.data.items;
        if (item is null)
            return;
        ByteWriter w;
        w.put(entry);
        w.putCString(item.details.name);
        w.put(cast(uint) item.inventoryType);
        deliver(Opcode.SMSG_ITEM_NAME_QUERY_RESPONSE, w.data);
    }

    /// The player's mount rears up: those around see it.
    @Handles(Opcode.CMSG_MOUNTSPECIAL_ANIM, WorldState.inWorld)
    void handleMountSpecialAnim()
    {
        ByteWriter w;
        w.put(player.guid);
        map.sendToWatchers(this, Opcode.SMSG_MOUNTSPECIAL_ANIM, w.data);
    }

    /// The client tells a player who whispered this one that they are ignored (`CHAT_MSG_IGNORED`).
    @Handles(Opcode.CMSG_CHAT_IGNORED, WorldState.inWorld)
    void handleChatIgnored(ref ByteReader reader)
    {
        import dmangos.world.queries : chatMessage;

        const guid = reader.read!ulong;
        if (auto other = cast(typeof(this)) context.onlinePlayer(guid))
            if (other.player !is null)
                other.deliver(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_IGNORED, Language.LANG_UNIVERSAL,
                    player.guid, player.data.name));
    }

    /// The client reports a bug or makes a suggestion: kept in `bugreport`.
    @Handles(Opcode.CMSG_BUG, WorldState.inWorld)
    void handleBug(ref ByteReader reader)
    {
        const suggestion = reader.read!uint;
        reader.read!uint;
        const content = reader.readCString();
        reader.read!uint;
        const type = reader.readCString();
        info!"%s: '%s' %s (%s)"(remoteAddress, player.data.name, suggestion ? "made a suggestion" : "reported a bug", type);
        context.database.saveBugReport(type, content);
    }

    /// The client hides or shows the player's helm, or its cloak.
    @Handles(Opcode.CMSG_TOGGLE_HELM, WorldState.inWorld)
    void handleToggleHelm()
    {
        import dmangos.world.player : PlayerFlags;
        import dmangos.world.updatefields : PLAYER_FLAGS;

        player.values.set!PLAYER_FLAGS(player.values.get!PLAYER_FLAGS ^ PlayerFlags.hideHelm);
        flushPlayerChanges();
    }

    /// ditto
    @Handles(Opcode.CMSG_TOGGLE_CLOAK, WorldState.inWorld)
    void handleToggleCloak()
    {
        import dmangos.world.player : PlayerFlags;
        import dmangos.world.updatefields : PLAYER_FLAGS;

        player.values.set!PLAYER_FLAGS(player.values.get!PLAYER_FLAGS ^ PlayerFlags.hideCloak);
        flushPlayerChanges();
    }

    /// The client's own emote (only none and the wave are allowed): those who see the player see it.
    @Handles(Opcode.CMSG_EMOTE, WorldState.inWorld)
    void handleEmote(ref ByteReader reader)
    {
        import dmangos.world.player : DeathState;

        enum uint emoteNone = 0, emoteWave = 3;
        const emote = reader.read!uint;
        if (player.deathState != DeathState.alive || (emote != emoteNone && emote != emoteWave))
            return;
        interruptAuras(AuraInterrupt.animCancels);
        map.sendToWatchers(this, Opcode.SMSG_EMOTE, packetBody(ServerEmote(emote, player.guid)), true);
    }

    /// The client inspects a player: one it may not attack, within 28 yards, is shown (`SMSG_INSPECT`).
    @Handles(Opcode.CMSG_INSPECT, WorldState.inWorld)
    void handleInspect(ref ByteReader reader)
    {
        import dmangos.world.relations : canAttack;

        const guid = reader.read!ulong;
        auto other = cast(typeof(this)) context.onlinePlayer(guid);
        if (other is null || other.player is null || other.map !is map)
            return;
        const a = player.position, b = other.player.position;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > 28.0f ^^ 2)
            return;
        if (other !is this && canAttack(relatingNow(), other.relatingNow(), context.client))
            return;
        ByteWriter w;
        w.put(guid);
        deliver(Opcode.SMSG_INSPECT, w.data);
    }

    /**
     * The client unlearns a skill (a profession): one its race and class may unlearn
     * (`SkillRaceClassInfo.dbc`'s flag 0x20) goes, with the spells it taught by itself.
     */
    @Handles(Opcode.CMSG_UNLEARN_SKILL, WorldState.inWorld)
    void handleUnlearnSkill(ref ByteReader reader)
    {
        enum uint canUnlearn = 0x20;
        const skill = reader.read!uint;
        if (skill == 0 || skill > ushort.max || player.skillValue(skill)[1] == 0)
            return;
        const raceMask = 1u << (player.data.race - 1), classMask = 1u << (player.data.classId - 1);
        bool may;
        foreach (ref info; context.client.skillRaceClassInfos.rows)
            if (info.skillId == skill && (info.raceMask == 0 || (info.raceMask & raceMask))
                    && (info.classMask == 0 || (info.classMask & classMask)) && (info.flags & canUnlearn))
                may = true;
        if (!may)
            return;
        player.setSkill(skill, 0, 0);
        context.database.saveSkill(player.data.guid, skill, 0, 0);
        // Every spell of the skill goes, however it was learned (`UpdateSkillTrainedSpells` removing the skill): the
        // profession's own rank spells too, which gives a primary profession's slot back (`unlearn`).
        foreach (ability; context.client.abilitiesForSkill(skill))
            unlearn(ability.spellId);
        flushPlayerChanges();
    }

    @Handles(Opcode.CMSG_STANDSTATECHANGE, WorldState.inWorld)
    void handleStandStateChange(const ClientStandStateChange request)
    {
        enum : uint { stand = 0, sit = 1, sleep = 3, kneel = 8 }
        if (request.state != stand && request.state != sit && request.state != sleep && request.state != kneel)
            return;
        interruptAuras(AuraInterrupt.animCancels);
        player.setStandState(cast(ubyte) request.state);
        if (request.state == stand)
            interruptAuras(AuraInterrupt.standingCancels); // food and drink end
        flushPlayerChanges();
        send(ServerStandStateUpdate(cast(ubyte) request.state));
    }

    @Handles(Opcode.CMSG_SET_ACTION_BUTTON, WorldState.inWorld)
    void handleSetActionButton(const ClientSetActionButton request)
    {
        if (request.button >= maxActionButtons)
            return;
        const action = request.packed & 0x00FF_FFFF;
        const type = cast(ubyte)(request.packed >> 24);
        if (request.packed != 0 && !context.data.isActionButtonDataValid(CreateAction(request.button, action, type)))
        {
            warning!"%s: '%s' tried to put invalid action %s (type %s) on button %s"(remoteAddress,
                player.data.name, action, type, request.button);
            return;
        }
        player.actionButtons[request.button] = request.packed;
        context.database.setActionButton(player.data.guid, request.button, action, type);
    }

    @Handles(Opcode.CMSG_SET_ACTIONBAR_TOGGLES, WorldState.inWorld)
    void handleSetActionBarToggles(const ClientSetActionBarToggles request)
    {
        player.values.setByte!PLAYER_FIELD_BYTES(2, request.toggles);
        player.values.clearChanges(); // the client already shows it
    }

    @Handles(Opcode.CMSG_TUTORIAL_FLAG, WorldState.inWorld)
    void handleTutorialFlag(const ClientTutorialFlag request)
    {
        if (request.flag >= 32 * player.data.tutorials.length)
            return;
        player.data.tutorials[request.flag / 32] |= 1u << (request.flag % 32);
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    /// Marks every tutorial as seen.
    @Handles(Opcode.CMSG_TUTORIAL_CLEAR, WorldState.inWorld)
    void handleTutorialClear()
    {
        player.data.tutorials[] = uint.max;
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    /// Shows every tutorial again.
    @Handles(Opcode.CMSG_TUTORIAL_RESET, WorldState.inWorld)
    void handleTutorialReset()
    {
        player.data.tutorials[] = 0;
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    @Handles(Opcode.CMSG_SET_SELECTION, WorldState.inWorld)
    void handleSetSelection(const ClientSetSelection request)
    {
        player.setTarget(request.guid); // others see whom the player has targeted
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Chat
    // -----------------------------------------------------------------------

    /**
     * A chat message, by its type. The GM parts: flood protection for
     * players without permissions, the moderator's mute, commands in the chat types they are read
     * from, everyone understanding the `c` permission, and the GM tag.
     */
    @Handles(Opcode.CMSG_MESSAGECHAT, WorldState.inWorld)
    void handleMessageChat(const ClientChat chat)
    {
        if (chat.language == Language.LANG_ADDON)
            return; // addon messages are ignored
        const config = context.config;
        const now = context.unixTime;
        if (!hasPermissions && config.floodLines && config.floodSeconds)
        {
            if (now >= floodTime)
            {
                floodLines = 0;
                floodTime = now + config.floodSeconds;
            }
            if (++floodLines > config.floodLines)
            {
                if (config.floodMessage)
                    systemMessage(format!("Your message has triggered serverside flood protection. "
                        ~ "You can speak again in %s seconds.")(floodTime - now));
                return;
            }
        }
        switch (chat.type)
        {
        case ChatType.CHAT_MSG_EMOTE, ChatType.CHAT_MSG_SAY, ChatType.CHAT_MSG_YELL, ChatType.CHAT_MSG_WHISPER,
            ChatType.CHAT_MSG_CHANNEL:
            if (account.muteTime && account.muteTime >= now) // `.account mute`
                return systemMessage("Your voice is currently muted by a moderator.");
            break;
        default:
            break;
        }

        // The `c` permission, and with shared chat everyone, are understood by all.
        Language language = chat.language;
        if (canUseCommand('c') || config.allowTwoSideInteractionChat)
            language = Language.LANG_UNIVERSAL;
        else if (config.allowTwoSideInteractionGroup && (chat.type == ChatType.CHAT_MSG_PARTY
            || chat.type == ChatType.CHAT_MSG_RAID || chat.type == ChatType.CHAT_MSG_RAID_LEADER
            || chat.type == ChatType.CHAT_MSG_RAID_WARNING))
            language = Language.LANG_UNIVERSAL;
        else
        {
            // Curse of Tongues: `SPELL_AURA_MOD_LANGUAGE` makes it speak the aura's tongue (CMaNGOS's `HandleMessagechatOpcode`).
            import dmangos.world.spellids : AuraType;

            foreach (aura; player.auras.list)
                foreach (i; 0 .. 3)
                    if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modLanguage)
                        language = cast(Language) aura.misc(i);
        }

        if (chat.type == ChatType.CHAT_MSG_AFK || chat.type == ChatType.CHAT_MSG_DND)
            return setAway(chat.type, chat.text);
        if (chat.text.length == 0)
            return;
        switch (chat.type)
        {
        case ChatType.CHAT_MSG_SAY, ChatType.CHAT_MSG_YELL, ChatType.CHAT_MSG_PARTY, ChatType.CHAT_MSG_RAID,
            ChatType.CHAT_MSG_RAID_LEADER, ChatType.CHAT_MSG_RAID_WARNING, ChatType.CHAT_MSG_GUILD,
            ChatType.CHAT_MSG_OFFICER, ChatType.CHAT_MSG_CHANNEL:
            if (parseCommands(chat.text))
                return;
            break;
        default:
            break;
        }

        switch (chat.type)
        {
        case ChatType.CHAT_MSG_SAY:
            sayAround(chat.type, language, chat.text, config.listenRangeSay);
            break;
        case ChatType.CHAT_MSG_YELL:
            sayAround(chat.type, language, chat.text, config.listenRangeYell);
            break;
        case ChatType.CHAT_MSG_EMOTE:
            sayAround(chat.type, Language.LANG_UNIVERSAL, chat.text, config.listenRangeTextEmote);
            break;
        case ChatType.CHAT_MSG_WHISPER:
            whisper(chat.target, chat.text);
            break;
        case ChatType.CHAT_MSG_PARTY:
            if (auto group = context.groups.of(player.guid))
                group.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                    player.chatTag), group.subGroupOf(player.guid));
            break;
        case ChatType.CHAT_MSG_RAID:
        case ChatType.CHAT_MSG_RAID_LEADER:
            auto raid = context.groups.of(player.guid);
            if (raid is null || !raid.isRaid
                || chat.type == ChatType.CHAT_MSG_RAID_LEADER && !raid.isLeader(player.guid))
                break;
            raid.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                player.chatTag));
            break;
        case ChatType.CHAT_MSG_RAID_WARNING:
            auto group = context.groups.of(player.guid);
            if (group is null)
                break;
            if (group.isRaid ? !group.isLeader(player.guid) && !group.isAssistant(player.guid)
                : config.chatRestrictedRaidWarnings)
                break;
            group.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                player.chatTag));
            break;
        case ChatType.CHAT_MSG_CHANNEL:
            context.channelCommand(this, ChannelOp.say, chat.channel, chat.text, language);
            break;
        case ChatType.CHAT_MSG_BATTLEGROUND, ChatType.CHAT_MSG_BATTLEGROUND_LEADER:
            if (parseCommands(chat.text))
                return;
            if (auto copy = currentBattleground())
                copy.teamChat(player.guid, chat.type, language, chat.text, player.chatTag);
            break;
        case ChatType.CHAT_MSG_GUILD, ChatType.CHAT_MSG_OFFICER:
            guildChat(chat.type == ChatType.CHAT_MSG_OFFICER, language, chat.text);
            break;
        default:
            trace!"%s: chat type %s is not supported yet"(remoteAddress, chat.type);
            break;
        }
    }

    /// Who is online, on this node and (in a cluster) on the others.
    @Handles(Opcode.CMSG_WHO, WorldState.inWorld)
    void handleWho(const ClientWho request)
    {
        WhoEntry[] candidates;
        foreach (who; context.onlinePlayers)
        {
            const p = who.character;
            candidates ~= WhoEntry(p.data.name, "", p.data.level, p.data.classId, p.data.race, p.data.zone,
                cast(uint) context.client.teamForRace(p.data.race), who.security);
        }
        foreach (ref r; context.remotePlayers)
            candidates ~= WhoEntry(r.entry.name, "", r.entry.level, r.entry.classId, r.entry.race, r.entry.zone,
                cast(uint) context.client.teamForRace(r.entry.race), r.entry.security);
        const config = context.config;
        string areaName(uint zone)
        {
            if (const area = context.client.areas.lookup(zone))
                return area.name[0];
            return "";
        }
        deliver(Opcode.SMSG_WHO, whoList(request, candidates, cast(uint) context.client.teamForRace(player.data.race),
            account.level, config.allowTwoSideWhoList, config.gmLevelInWhoList, config.maxWhoListReturns, &areaName));
    }

    /// Everyone within `range` yards hears it, the speaker included (say, yell, text emotes).
    void sayAround(ChatType type, Language language, string text, float range)
    {
        if (teleporting == Teleport.far)
            return;
        map.sendInRange(player.position, range, Opcode.SMSG_MESSAGECHAT,
            chatMessage(type, language, player.guid, text, player.chatTag));
    }

    /**
     * A whisper: anyone online, of the same
     * faction unless one of the two has GM permissions; an away or busy player's message comes back.
     * A player whispering a GM with the GM tag on gets an automatic reply instead, unless the GM
     * allowed it (`.gm allowwhispers`).
     */
    void whisper(string to, string text)
    {
        import dmangos.world.whisper : deliverWhisper, WhisperFrom;

        const from = WhisperFrom(player.guid, player.data.race, hasPermissions, player.chatTag);
        if (auto target = context.onlinePlayer(to))
            return deliverWhisper(target, from, text, context.config.allowTwoSideInteractionChat,
                (ulong sender) => sessionOf(target).allowsWhispersFrom(sender),
                (ubyte race) => cast(uint) context.client.teamForRace(race), (Opcode op, const(ubyte)[] b) => deliver(op, b));
        // Another node's player: its node checks and delivers, and answers this one.
        const remote = context.remotePlayer(to);
        if (remote is null || context.whisperRemote is null)
            return send(ServerChatPlayerNotFound(to));
        context.whisperRemote(remote.node, remote.entry.guid, from, text);
    }

    /// Whether this player, a GM with its tag on, hears whispers from `sender` (`.gm allowwhispers`).
    package bool allowsWhispersFrom(ulong sender)
    {
        return (sender in gmTargets) !is null;
    }

    /**
     * `/afk` and `/dnd`: set with a message, or
     * the default one; the same command without a message clears it; the two exclude each other.
     */
    void setAway(ChatType type, string message)
    {
        const flag = type == ChatType.CHAT_MSG_AFK ? PlayerFlags.afk : PlayerFlags.dnd;
        const other = flag == PlayerFlags.afk ? PlayerFlags.dnd : PlayerFlags.afk;
        const defaultMessage = flag == PlayerFlags.afk ? "Away from Keyboard" : "Do not Disturb";
        if (player.hasFlag(flag))
        {
            if (message.length == 0)
                player.setFlag(flag, false);
            else
                player.autoReply = message;
        }
        else
        {
            player.autoReply = message.length ? message : defaultMessage;
            player.setFlag(other, false);
            player.setFlag(flag, true);
        }
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.status);
    }

    /// A text emote: the animation for those who see the player, the text for those in range.
    @Handles(Opcode.CMSG_TEXT_EMOTE, WorldState.inWorld)
    void handleTextEmote(const ClientTextEmote request)
    {
        if (teleporting == Teleport.far)
            return;
        enum : uint { oneshotNone = 0, stateSleep = 12, stateSit = 13, stateKneel = 68 }
        const textEntry = context.client.emotesText.lookup(request.textEmote);
        if (textEntry is null)
            return;

        // A one-shot animation, or a state that lasts until the player moves.
        const emote = textEntry.emote;
        if (emote != oneshotNone && emote != stateSleep && emote != stateSit && emote != stateKneel)
            interruptAuras(AuraInterrupt.animCancels);
        if (emote != oneshotNone && emote != stateSleep && emote != stateSit && emote != stateKneel)
            if (const entry = context.client.emotes.lookup(emote))
            {
                if (entry.emoteType)
                {
                    player.setEmoteState(emote);
                    flushPlayerChanges();
                }
                else
                    map.sendToWatchers(this, Opcode.SMSG_EMOTE, packetBody(ServerEmote(emote, player.guid)), true);
            }

        // "<player> waves at <target>." for everyone within the text emote range.
        string targetName;
        if (const target = context.onlinePlayer(request.target))
            targetName = target.character.data.name;
        else if (auto creature = cast(Creature) map.findObject(request.target))
        {
            targetName = creature.template_.name;
            // Its script hears it.
            if (creature.ai !is null && creature.alive)
                creature.ai.receivedEmote(player.guid, request.textEmote, map);
        }
        map.sendInRange(player.position, context.config.listenRangeTextEmote, Opcode.SMSG_TEXT_EMOTE,
            packetBody(ServerTextEmote(player.guid, request.textEmote, request.emoteNum,
            cast(uint) targetName.length + 1, targetName)));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime, seconds;
    import std.algorithm.searching : count;
    import std.typecons : tuple;
    import dmangos.world.testclient;
}

/// Entering the world, playing a little, logging out and disconnecting from the world.
unittest
{
    import std.zlib : uncompress;
    import dmangos.world.movement : MovementInfo, Position;
    import dmangos.world.objects : lowGuid;
    import dmangos.world.player : CharacterData, ItemRecord;
    import dmangos.world.playercreate : NewSkill, NewSpell;
    import dmangos.world.worlddata : CreateAction;

    auto db = newDatabase();
    CharacterData anduin;
    anduin.guid = 7;
    anduin.account = 4;
    anduin.name = "Anduin";
    anduin.race = raceHuman;
    anduin.classId = classWarrior;
    anduin.level = 1;
    anduin.position = Position(-8949.95f, -132.493f, 83.5312f, 0);
    anduin.zone = 12;
    anduin.items = [ItemRecord(0, 15, 100, itemSword, 0, 0, 1, 0, "", 0, "", 0, 20),
        ItemRecord(0, 3, 101, itemShirt, 0, 0, 1, 0, "", 0, "", 0, 0),
        ItemRecord(0, 23, 102, itemHearthstone, 0, 0, 1, 0, "", 0, "", 0, 0)];
    anduin.skills = [NewSkill(skillSwords, 1, 5)];
    anduin.spells = [NewSpell(spellOneHandedSwords, true, false), NewSpell(spellLanguageCommon, true, false)];
    anduin.actions = [CreateAction(0, spellOneHandedSwords, 0)];
    db.loadable[7] = anduin;
    CharacterData stranger = anduin;
    stranger.guid = 50;
    stranger.account = 9;
    db.loadable[50] = stranger;

    auto context = newCreationContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(50));
    assert(client.read()[0].body_ == [ubyte(CharacterLoginFailure.CHAR_LOGIN_NO_CHARACTER)], "not their character");

    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    const login = client.read();
    auto opcodes = opcodesOf(login);
    // Then the creatures and objects around Northshire Abbey, after the login packets.
    assert(opcodes[$ - 1] == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT);
    opcodes = opcodes[0 .. $ - 1];
    with (Opcode)
        assert(opcodes == [SMSG_LOGIN_VERIFY_WORLD, SMSG_ACCOUNT_DATA_TIMES, SMSG_EXPECTED_SPAM_RECORDS,
            SMSG_MESSAGECHAT, SMSG_MESSAGECHAT, SMSG_MESSAGECHAT, SMSG_SET_REST_START, SMSG_BINDPOINTUPDATE,
            SMSG_TUTORIAL_FLAGS, SMSG_INITIAL_SPELLS, SMSG_ACTION_BUTTONS, SMSG_INITIALIZE_FACTIONS,
            SMSG_LOGIN_SETTIMESPEED, SMSG_SET_PROFICIENCY, SMSG_SET_PROFICIENCY, SMSG_COMPRESSED_UPDATE_OBJECT,
            SMSG_FRIEND_LIST, SMSG_IGNORE_LIST, SMSG_INIT_WORLD_STATES, SMSG_WEATHER]);
    assert(client.session.state == WorldState.inWorld && (7 in db.online) !is null);
    assert(db.homeBinds[7].zone == 12, "a character without a home gets its start position");

    auto verify = ByteReader(login[0].body_);
    assert(deserialize!ServerLoginVerifyWorld(verify).x == anduin.position.x);
    auto spellsReader = ByteReader(login[9].body_);
    const book = deserialize!ServerInitialSpells(spellsReader).spells;
    assert(book.canFind(InitialSpell(spellOneHandedSwords)) && book.canFind(InitialSpell(spellPassiveTrainer)),
        "saved spells and the re-learned default ones");
    // The update creates three items and the player.
    const update = cast(const(ubyte)[]) uncompress(login[15].body_[4 .. $]);
    assert(update.length == (login[15].body_[0] | login[15].body_[1] << 8) && update[0] == 4);

    // Movement is remembered.
    MovementInfo step;
    step.position = Position(-8950, -130, 83.5f, 0.5f);
    ByteWriter moveBody;
    step.write(moveBody);
    client.write(Opcode.MSG_MOVE_HEARTBEAT, moveBody.data);
    assert(client.session.character.movement.position == Position(-8950, -130, 83.5f, 0.5f));

    // Queries.
    client.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(7));
    auto nameReader = ByteReader(client.read()[0].body_);
    const name = deserialize!ServerNameQueryResponse(nameReader);
    assert(name.name == "Anduin" && name.race == raceHuman && name.classId == classWarrior);
    client.write(Opcode.CMSG_ITEM_QUERY_SINGLE, ClientItemQuerySingle(itemSword, 0));
    const item = client.read();
    assert(item[0].opcode == Opcode.SMSG_ITEM_QUERY_SINGLE_RESPONSE && item[0].body_[0 .. 4] == [25, 0, 0, 0]);
    client.write(Opcode.CMSG_ITEM_QUERY_SINGLE, ClientItemQuerySingle(424242, 0));
    assert(client.read()[0].body_.length == 4);

    // Chat comes back to the speaker; sitting down updates the player.
    ByteWriter say;
    say.put(uint(ChatType.CHAT_MSG_SAY));
    say.put(uint(Language.LANG_COMMON));
    say.putCString("hello");
    client.write(Opcode.CMSG_MESSAGECHAT, say.data);
    const heard = client.read();
    assert(heard.length == 1 && heard[0].opcode == Opcode.SMSG_MESSAGECHAT);
    assert(heard[0].body_[$ - 7 .. $] == ['h', 'e', 'l', 'l', 'o', 0, 0]);
    client.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    const sat = client.read();
    // A values block carries the whole 41-word field mask, so it is big enough to be compressed.
    assert(sat.length == 2 && sat[0].opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT && sat[1].body_ == [1]);

    // Settings are saved as they change.
    client.write(Opcode.CMSG_SET_ACTION_BUTTON, ClientSetActionButton(5, spellLanguageCommon));
    assert(db.actionButtonWrites == [[7, 5, spellLanguageCommon, 0]]);
    client.write(Opcode.CMSG_TUTORIAL_FLAG, ClientTutorialFlag(33));
    assert(db.tutorialSaves[4][1] == 2);

    // The character screen's opcodes are not handled in the world.
    client.write(Opcode.CMSG_CHAR_ENUM, null);
    assert(client.read().length == 0);

    // Logging out saves where the character is and returns to the character screen.
    client.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const logout = client.read();
    assert(logout.length == 2 && logout[0].body_ == [0, 0, 0, 0, 1] && logout[1].opcode == Opcode.SMSG_LOGOUT_COMPLETE);
    assert(client.session.state == WorldState.characterScreen && (7 in db.online) is null);
    assert(db.progressSaves.length == 1 && db.progressSaves[0].position == Position(-8950, -130, 83.5f, 0.5f));
    assert(db.progressSaves[0].cinematic == 1, "the intro is not shown again");

    // Disconnecting from the world saves too.
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();
    client.session.disconnected();
    assert(db.progressSaves.length == 2 && (7 in db.online) is null);
    assert(client.session.state == WorldState.closed && context.sessionCount == 0);
}

/// Two players on one map: they see each other, each other's moves, chat and emotes, and part again.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : emotesFormat, emotesTextFormat;
    import dmangos.world.database : WorldAccount;
    import dmangos.world.movement : MovementFlags, MovementInfo, Position;
    import dmangos.world.player : CharacterData;

    auto db = newDatabase();
    WorldAccount second = db.accounts["PLAYER"];
    second.id = 5;
    second.username = "SECOND";
    db.accounts["SECOND"] = second;
    foreach (t; [tuple(7u, "Anduin", 4u, classWarrior, 0.0f), tuple(8u, "Jaina", 5u, classMage, 20.0f)])
    {
        const guid = t[0], name = t[1], account = t[2], classId = t[3], x = t[4];
        CharacterData c;
        c.guid = guid;
        c.account = account;
        c.name = name;
        c.race = raceHuman;
        c.classId = classId;
        c.level = 1;
        c.cinematic = 1;
        c.position = Position(x, 0, 0);
        db.loadable[guid] = c;
    }
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // /wave: text emote 101 plays the one-shot animation 3.
    auto waveText = new uint[emotesTextFormat.length];
    waveText[0] = 101;
    waveText[2] = 3;
    context.client.emotesText = typeof(context.client.emotesText).parse(buildDbc(emotesTextFormat, [waveText]), "");
    context.client.emotes = typeof(context.client.emotes).parse(buildDbc(emotesFormat, [[3u, 0, 0, 0, 0, 0, 0]]), "");

    auto anduin = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    auto jaina = TestClient(new WorldSession(context, "127.0.0.2"), testKey);
    authenticate(anduin);
    authenticate(jaina, "SECOND");

    // Anduin enters alone; then Jaina, 20 yards away: each is created for the other.
    anduin.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 1, "only itself");
    jaina.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(8));
    assert(opcodesOf(jaina.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 2, "itself, then Anduin");
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT], "Jaina appears");
    assert(context.map(0).seeEachOther(7, 8) && context.worldPopulation == 2);

    // Names of online players.
    anduin.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(8));
    auto nameReader = ByteReader(anduin.read()[0].body_);
    assert(deserialize!ServerNameQueryResponse(nameReader).name == "Jaina");

    // Jaina walks: Anduin sees the same opcode, with her guid in front.
    MovementInfo step;
    step.flags = MovementFlags.forward;
    step.position = Position(25, 0, 0);
    ByteWriter body_;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_START_FORWARD, body_.data);
    const moved = anduin.read();
    assert(moved.length == 1 && moved[0].opcode == Opcode.MSG_MOVE_START_FORWARD);
    auto moveReader = ByteReader(moved[0].body_);
    assert(moveReader.readPackedGuid() == 8 && MovementInfo.read(moveReader).position == Position(25, 0, 0));
    assert(jaina.read().length == 0, "the mover is not told about its own move");

    // Say reaches 25 yards (they are 25 apart), whispers reach anyone online.
    ByteWriter say;
    say.put(uint(ChatType.CHAT_MSG_SAY));
    say.put(uint(Language.LANG_COMMON));
    say.putCString("hello");
    jaina.write(Opcode.CMSG_MESSAGECHAT, say.data);
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_MESSAGECHAT]
        && opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
    ByteWriter whisper;
    whisper.put(uint(ChatType.CHAT_MSG_WHISPER));
    whisper.put(uint(Language.LANG_COMMON));
    whisper.putCString("anduin");
    whisper.putCString("psst");
    jaina.write(Opcode.CMSG_MESSAGECHAT, whisper.data);
    assert(anduin.read()[0].body_[0] == ChatType.CHAT_MSG_WHISPER
        && jaina.read()[0].body_[0] == ChatType.CHAT_MSG_WHISPER_INFORM);
    ByteWriter nobody;
    nobody.put(uint(ChatType.CHAT_MSG_WHISPER));
    nobody.put(uint(Language.LANG_COMMON));
    nobody.putCString("Nobody");
    nobody.putCString("hi");
    jaina.write(Opcode.CMSG_MESSAGECHAT, nobody.data);
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_CHAT_PLAYER_NOT_FOUND]);

    // /wave at Anduin: the animation and the text, for both.
    jaina.write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(101, 0, 7));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_EMOTE, Opcode.SMSG_TEXT_EMOTE]);
    const own = jaina.read();
    assert(opcodesOf(own) == [Opcode.SMSG_EMOTE, Opcode.SMSG_TEXT_EMOTE]);
    auto emoteReader = ByteReader(own[1].body_);
    assert(deserialize!ServerTextEmote(emoteReader).targetName == "Anduin");

    // Sitting down is a public field: Anduin gets a values block.
    jaina.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);
    jaina.read();

    // Walking out of sight and back, taking the time it takes.
    now += 60.seconds;
    step.position = Position(500, 0, 0);
    body_ = ByteWriter.init;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_HEARTBEAT, body_.data);
    assert(!context.map(0).seeEachOther(7, 8));
    const lost = anduin.read();
    assert(opcodesOf(lost)[$ - 1] == Opcode.SMSG_UPDATE_OBJECT && lost[$ - 1].body_[5] == 4, "an out-of-range block");
    now += 60.seconds;
    step.position = Position(30, 0, 0);
    body_ = ByteWriter.init;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_HEARTBEAT, body_.data);
    assert(context.map(0).seeEachOther(7, 8)
        && opcodesOf(anduin.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 1);
    jaina.read();

    // Logging out: Anduin destroys Jaina; disconnecting takes Anduin off the map too.
    jaina.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const gone = anduin.read();
    assert(opcodesOf(gone) == [Opcode.SMSG_DESTROY_OBJECT] && gone[0].body_ == [8, 0, 0, 0, 0, 0, 0, 0]);
    anduin.session.disconnected();
    assert(context.worldPopulation == 0 && context.map(0).population == 0);
}

/// The update tick: the 20-second logout, regeneration, inns and cities, the periodic save.
unittest
{
    import core.time : Duration, MonoTime, seconds;
    import dmangos.world.player : Player, PlayerFlags, RestType;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig c) { c.logoutDelay = 20; c.playerSaveInterval = 60; });
    auto now = MonoTime.currTime;
    context.clock = () => now;
    void tick(Duration step)
    {
        now += step;
        context.update(now);
    }

    context.data.xpForNextLevel = [0, 400];
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = cast(Player) anduin.session.character; // the test changes the player directly
    tick(Duration.zero);

    // Health comes back, faster when sitting; rage drains.
    me.values.set!UNIT_FIELD_HEALTH(10u);
    me.values.set!UNIT_FIELD_POWER1(1, 100u);
    tick(2.seconds);
    const standing = me.values[UNIT_FIELD_HEALTH];
    assert(standing > 10 && me.values[UNIT_FIELD_POWER1 + 1] == 75, "2.5 rage per 2 s");
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT));

    // Logging out takes 20 seconds, sitting and rooted; cancelling stands up.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const asked = anduin.read();
    assert(asked[0].opcode == Opcode.SMSG_LOGOUT_RESPONSE && asked[0].body_ == [0, 0, 0, 0, 0]);
    assert(opcodesOf(asked).canFind(Opcode.SMSG_FORCE_MOVE_ROOT) && me.values.getByte!UNIT_FIELD_BYTES_1(0) == 1);
    anduin.write(Opcode.CMSG_LOGOUT_CANCEL, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_FORCE_MOVE_UNROOT)
        && me.values.getByte!UNIT_FIELD_BYTES_1(0) == 0);
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    tick(19.seconds);
    assert(anduin.session.state == WorldState.inWorld);
    tick(1.seconds);
    assert(anduin.session.state == WorldState.characterScreen);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOGOUT_COMPLETE));

    // An inn: resting, rested XP every 10 seconds, instant logout; walking out ends it.
    anduin = loggedIn(context, db, 7, "Anduin", Position(innPosition[0], innPosition[1], innPosition[2]));
    me = cast(Player) anduin.session.character;
    anduin.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerInn));
    assert(me.hasFlag(PlayerFlags.resting) && me.restType == RestType.tavern);
    tick(1.seconds);
    tick(3600.seconds); // 400 XP to the next level: 400 / 1152000 per second, 1.25 in an hour
    assert(me.restBonus > 1.2f && me.restBonus < 1.3f && me.values[PLAYER_REST_STATE_EXPERIENCE] == 1);
    me.movement.position.x += 50;
    tick(1.seconds);
    assert(!me.hasFlag(PlayerFlags.resting));

    // A capital rests too.
    anduin.write(Opcode.CMSG_ZONEUPDATE, ClientZoneUpdate(zoneStormwind));
    assert(me.restType == RestType.city);
    anduin.write(Opcode.CMSG_ZONEUPDATE, ClientZoneUpdate(zoneElwynn));
    assert(me.restType == RestType.none);

    // The periodic save, every player_save_interval (60 s here); the hour above made one due already.
    tick(1.seconds);
    const saves = db.progressSaves.length;
    foreach (_; 0 .. 60)
        tick(1.seconds);
    assert(db.progressSaves.length == saves + 1 && db.progressSaves[$ - 1].restBonus == me.restBonus);
}

/// Entering Northshire: the deputy and the mailbox appear, and the client can ask what they are.
unittest
{
    import dmangos.world.objects : HighGuid, makeGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    db.loadable[7] = () {
        import dmangos.world.player : CharacterData;

        CharacterData c;
        c.guid = 7;
        c.account = 4;
        c.name = "Anduin";
        c.race = raceHuman;
        c.classId = classWarrior;
        c.level = 1;
        c.cinematic = 1;
        c.position = Position(-8949.95f, -132.49f, 83.53f);
        return c;
    }();
    authenticate(anduin);
    anduin.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    const login = opcodesOf(anduin.read());
    assert(login.count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) + login.count(Opcode.SMSG_UPDATE_OBJECT) == 2,
        "the player, then what it sees");
    const deputy = makeGuid(HighGuid.unit, creatureWillem, 79942);
    // Deputy Willem, the mailbox and the trainer, innkeeper and banker by the start position.
    assert(context.map(0).objectCount == 5 && context.map(0).seesObject(7, deputy));

    anduin.write(Opcode.CMSG_CREATURE_QUERY, ClientObjectQuery(creatureWillem, deputy));
    const reply = anduin.read();
    assert(reply[0].opcode == Opcode.SMSG_CREATURE_QUERY_RESPONSE && reply[0].body_[4 .. 18] == "Deputy Willem\0");
    anduin.write(Opcode.CMSG_GAMEOBJECT_QUERY, ClientObjectQuery(32349, 0));
    assert(anduin.read()[0].opcode == Opcode.SMSG_GAMEOBJECT_QUERY_RESPONSE);
    anduin.write(Opcode.CMSG_CREATURE_QUERY, ClientObjectQuery(424242, 0));
    assert(anduin.read()[0].body_ == [0x32, 0x79, 0x06, 0x80]);
}

/// Pages: a query gets the page and each after it; reading a slot without a readable item is refused.
unittest
{
    import std.algorithm.searching : count;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.worlddata : PageText;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.pageTexts[1] = PageText("Dear sir,", 2);
    context.data.pageTexts[2] = PageText("Yours.", 0);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    ByteWriter w;
    w.put(1u);
    anduin.write(Opcode.CMSG_PAGE_TEXT_QUERY, w.data);
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_PAGE_TEXT_QUERY_RESPONSE) == 2, "both pages");
    anduin.write(Opcode.CMSG_READ_ITEM, [ubyte(255), ubyte(23)]);
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_INVENTORY_CHANGE_FAILURE], "nothing to read there");
}

/// Small requests: hiding the helm, the wave, inspecting a friend.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : PLAYER_FLAGS;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8947, -132.49f, 83.53f));
    anduin.read();
    jaina.read();
    anduin.write(Opcode.CMSG_TOGGLE_HELM, null);
    assert(anduin.session.character.values.get!PLAYER_FLAGS & PlayerFlags.hideHelm);
    anduin.write(Opcode.CMSG_TOGGLE_HELM, null);
    assert(!(anduin.session.character.values.get!PLAYER_FLAGS & PlayerFlags.hideHelm), "shown again");
    anduin.read();
    jaina.read();

    ByteWriter wave;
    wave.put(3u);
    anduin.write(Opcode.CMSG_EMOTE, wave.data);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_EMOTE), "the wave is seen");
    ByteWriter dance;
    dance.put(10u);
    anduin.write(Opcode.CMSG_EMOTE, dance.data);
    assert(!opcodesOf(jaina.read()).canFind(Opcode.SMSG_EMOTE), "only the wave");

    ByteWriter inspect;
    inspect.put(jaina.session.character.guid);
    anduin.write(Opcode.CMSG_INSPECT, inspect.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_INSPECT));
}

/// An item's name asked for; a bug report kept; a whisperer told it is ignored.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8947, -132.49f, 83.53f));
    anduin.read();
    jaina.read();
    ByteWriter q;
    q.put(itemSword);
    q.put(0UL);
    anduin.write(Opcode.CMSG_ITEM_NAME_QUERY, q.data);
    auto named = anduin.read();
    assert(named.length == 1 && named[0].opcode == Opcode.SMSG_ITEM_NAME_QUERY_RESPONSE);

    ByteWriter bug;
    bug.put(0u);
    bug.put(6u);
    bug.putCString("crash");
    bug.put(4u);
    bug.putCString("bug");
    anduin.write(Opcode.CMSG_BUG, bug.data);
    assert(db.bugReports == [["bug", "crash"]]);

    ByteWriter ignored;
    ignored.put(jaina.session.character.guid);
    anduin.write(Opcode.CMSG_CHAT_IGNORED, ignored.data);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_MESSAGECHAT), "she hears she is ignored");
}

/// The client's settings: saved compressed, given back the same.
unittest
{
    import std.zlib : compress, uncompress;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const text = "MACRO 1 \"Charge\" Ability_Warrior_Charge\n/cast Charge\nEND\n\0";
    ByteWriter up;
    up.put(4u); // the account's macros
    up.put(cast(uint) text.length);
    up.putBytes(compress(text));
    anduin.write(Opcode.CMSG_UPDATE_ACCOUNT_DATA, up.data);
    ByteWriter ask;
    ask.put(4u);
    anduin.write(Opcode.CMSG_REQUEST_ACCOUNT_DATA, ask.data);
    auto back = anduin.read();
    assert(back.length == 1 && back[0].opcode == Opcode.SMSG_UPDATE_ACCOUNT_DATA);
    auto r = ByteReader(back[0].body_);
    assert(r.read!uint == 4);
    const size = r.read!uint;
    assert(cast(string) uncompress(r.readBytes(r.remaining), size) == text[0 .. $ - 1], "the same macros");
}

/// A primary profession unlearned: every spell of its skill goes, its own rank spell too, and its slot comes back.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : skillLineAbilityFormat, skillLineFormat, skillRaceClassInfoFormat;
    import dmangos.world.spells : SpellChainNode;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : PLAYER_CHARACTER_POINTS2;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint alchemy = 171, apprentice = 2259, recipe = 2330, professionCategory = 11, canUnlearn = 0x20;
    with (context.client)
    {
        auto line = new uint[skillLineFormat.length];
        line[0] = alchemy;
        line[1] = professionCategory;
        skillLines = typeof(skillLines).parse(buildDbc(skillLineFormat, [line]), "SkillLine.dbc");
        skillRaceClassInfos = typeof(skillRaceClassInfos).parse(buildDbc(skillRaceClassInfoFormat,
            [[1u, alchemy, 0xFF, 0x5DF, canUnlearn, 0, 0, 0]]), "SkillRaceClassInfo.dbc");
        uint[] ability(uint id, uint spell, uint onGetSkill)
        {
            auto r = new uint[skillLineAbilityFormat.length];
            r[0] = id;
            r[1] = alchemy;
            r[2] = spell;
            r[9] = onGetSkill;
            return r;
        }
        skillLineAbilities = typeof(skillLineAbilities).parse(buildDbc(skillLineAbilityFormat,
            [ability(1, apprentice, 0), ability(2, recipe, 1)]), "SkillLineAbility.dbc");
        buildIndexes();
    }
    with (context.data.spells)
    {
        spells[apprentice] = testSpell(apprentice, SpellEffect.dummy, 1, 0);
        spells.edit(apprentice).effect[1] = SpellEffect.skill;
        spells.edit(apprentice).miscValue[1] = alchemy;
        spells[recipe] = testSpell(recipe, SpellEffect.createItem, 1, 0);
        chains[apprentice] = SpellChainNode(0, apprentice, 1, 0);
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = anduin.session.inWorld;
    me.player.spells ~= [apprentice, recipe];
    me.player.values.set!PLAYER_CHARACTER_POINTS2(1u); // one of the two slots taken
    me.player.setSkill(alchemy, 1, 75);
    anduin.read();

    ByteWriter w;
    w.put(alchemy);
    anduin.write(Opcode.CMSG_UNLEARN_SKILL, w.data);
    assert(!me.player.knowsSpell(apprentice) && !me.player.knowsSpell(recipe), "both spells gone");
    assert(me.player.skillValue(alchemy)[1] == 0);
    assert(me.player.values.get!PLAYER_CHARACTER_POINTS2 == 2, "the slot back");
}
