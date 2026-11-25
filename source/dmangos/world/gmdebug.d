/// GM movement and combat diagnostics, plus database-backed recall locations.
module dmangos.world.gmdebug;

/// See the module documentation.
mixin template DebugCommands()
{
    import std.algorithm.searching : canFind, startsWith;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import std.math : cos, sin, sqrt;
    import std.uni : sicmp;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.commands;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : GameTele;

private:
    /// The selected unit, or oneself without a selection.
    struct SelectedUnit
    {
        Character player;
        Creature creature;

        @property bool found() const
        {
            return player !is null || creature !is null;
        }

        ref UpdateValues values() return
        {
            return player !is null ? player.player.values : creature.values;
        }

        /// Sends the changed fields to whoever sees them.
        void flush(Character by)
        {
            if (player !is null)
                player.flushPlayerChanges();
            else
                by.map.flushObjectChanges(creature);
        }
    }

    /// The selected unit, oneself without a selection; not found after "Select a player or creature first.".
    SelectedUnit selectedUnit()
    {
        SelectedUnit unit;
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
            unit.player = this;
        else
        {
            unit.player = cast(Character) map.find(guid);
            if (unit.player is null)
                unit.creature = cast(Creature) map.findObject(guid);
        }
        if (!unit.found)
            redSystemMessage("Select a player or creature first.");
        return unit;
    }

    /// Where the selected player or object stands, oneself without a selection; false after
    /// "Select a player or creature first." if the selection is not on the map.
    bool selectedPosition(out Position at)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        at = player.position;
        if (guid == 0)
            return true;
        if (auto other = map.find(guid))
            at = other.character.position;
        else if (auto object = map.findObject(guid))
            at = object.position;
        else
        {
            redSystemMessage("Select a player or creature first.");
            return false;
        }
        return true;
    }

    /// The map's collision data; null after "Collision is not enabled." without vmaps.
    auto vmapTerrain()
    {
        auto terrain = map.collision;
        if (terrain is null || !terrain.hasVmaps)
        {
            redSystemMessage("Collision is not enabled.");
            return null;
        }
        return terrain;
    }

    /// The battleground the player is in; null after "Join a battleground first.".
    auto joinedBattleground()
    {
        auto copy = currentBattleground();
        if (copy is null)
            redSystemMessage("Join a battleground first.");
        return copy;
    }

    // -----------------------------------------------------------------------
    // .debug
    // -----------------------------------------------------------------------

    /// `.debug aimove`: the selected creature walks to a point on this map.
    bool handleAiMoveCommand(float x, float y, float z)
    {
        if (!context.client.isValidMapCoord(map.id, x, y, z))
            return false;
        if (auto creature = selectedCreature(true))
            npcWalkTo(creature, Position(x, y, z));
        return true;
    }

    /// `.debug moveinfo`: the selected creature's spawn, movement generator, position and combat state.
    bool handleMoveInfoCommand()
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        const at = creature.position;
        systemMessage(format!"Spawn %s, movement %s, position %.3f %.3f %.3f, orientation %.3f, combat %s."
            (creature.spawn.guid, creature.generator.type, at.x, at.y, at.z, at.orientation, creature.ai.inCombat));
        return true;
    }

    /// `.debug gettptime`: how far the ship the player is aboard is into its circuit.
    bool handleGetTransporterTimeCommand()
    {
        import dmangos.world.objects : HighGuid, counterOf, highGuidOf;

        const guid = player.movement.transportGuid;
        if (highGuidOf(guid) == HighGuid.moTransport)
            foreach (const ref ship; context.data.ships)
                if (ship.entry == counterOf(guid) && ship.period)
                {
                    systemMessage(format!"%s is %s ms into its %s ms circuit."
                        (ship.name, context.transportNow() % ship.period, ship.period));
                    return true;
                }
        redSystemMessage("Board a scheduled ship or zeppelin first.");
        return true;
    }

    /// `.debug position`: the map, copy, coordinates and facing.
    bool handleDebugDumpCoordsCommand()
    {
        const at = player.position;
        systemMessage(format!"Map %s, copy %s, x %.6f, y %.6f, z %.6f, facing %.6f."
            (map.id, map.instanceId, at.x, at.y, at.z, at.orientation));
        return true;
    }

    /// `.debug fade`: the player's threat on the selected creature lowered by a percentage.
    bool handleFadeCommand(uint percent)
    {
        return percent <= 100 && handleThreatModCommand(-cast(int) percent);
    }

    /// `.debug threatMod`: the player's threat on the selected creature changed by a signed percentage.
    bool handleThreatModCommand(int percent)
    {
        if (percent < -100 || percent > 100)
            return false;
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        const before = creature.ai.threatOf(player.guid);
        creature.ai.modifyThreatPercent(player.guid, percent);
        const after = creature.ai.threatOf(player.guid);
        greenSystemMessage(format!"Your threat on %s was %.2f and is now %.2f."
            (creature.template_.name, before, after));
        gmLog(format!"adjusted own threat on spawn %s by %s percent"(creature.spawn.guid, percent));
        return true;
    }

    /// `.debug calcThreat`: the threat a spell's damage gives with the player's modifiers.
    bool handleCalcThreatCommand(uint damage, uint spellId)
    {
        import dmangos.world.spellmods : SpellModOp;

        const spell = context.data.spells.spell(spellId);
        if (spell is null || spell.casting.school >= player.damageMods.threat.length)
            return false;
        const schoolFactor = player.damageMods.threat[spell.casting.school];
        const spellFactor = spellMod(SpellModOp.threat, spell, 1.0f);
        systemMessage(format!"%s damage gives %.2f threat with your current modifiers (school %.3f, spell %.3f)."
            (damage, damage * schoolFactor * spellFactor, schoolFactor, spellFactor));
        return true;
    }

    /// `.debug threatList`: the selected creature's threat entries for units on the map.
    bool handleThreatListCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto target = cast(Creature) map.findObject(guid);
        if (target is null || target.ai is null)
        {
            redSystemMessage("Select a creature first.");
            return true;
        }
        string text = format!"threatlist of creature: %s %s\n"(guid & 0xFFFF_FFFF, guid >> 32);
        foreach (who, amount; target.ai.threatList)
            if (amount && map.find(who) !is null)
                text ~= format!"guid: %s | threat: %s| threat after mod: %s\n"(who, amount, amount);
        sendMultilineMessage(text);
        return true;
    }

    /// `.debug aggro`: the selected creature's aggro range against the player.
    bool handleAggroRangeCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto creature = guid ? cast(Creature) map.findObject(guid) : null;
        if (creature is null || creature.ai is null)
        {
            redSystemMessage("Select a player or creature first.");
            return true;
        }
        systemMessage(format!"Aggrorange is: %s"(creature.ai.aggroRangeFor(unit)));
        return true;
    }

    /// `.debug infront`: 1 if the selection is within the half circle the player faces, else 0.
    bool handleDebugInFrontCommand()
    {
        import std.math : atan2, PI;

        Position at;
        if (!selectedPosition(at))
            return true;
        const me = player.position;
        double angle = atan2(at.y - me.y, at.x - me.x);
        angle = angle >= 0 ? angle : 2 * PI + angle;
        angle -= me.orientation;
        while (angle > PI)
            angle -= 2 * PI;
        while (angle < -PI)
            angle += 2 * PI;
        systemMessage(format!"%d"(angle >= -PI / 2 && angle <= PI / 2 ? 1 : 0));
        return true;
    }

    /// `.debug los`: line of sight to the selection, from the ground, 2 and 5 yards up.
    bool handleCollisionTestLineOfSightCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Position at;
        if (auto creature = selectedCreature(false))
            at = creature.position;
        else if (auto who = guid ? map.find(guid) : null)
            at = who.character.position;
        else
        {
            redSystemMessage("Invalid target.");
            return true;
        }
        const me = player.position;
        string sight(float dz)
        {
            return map.lineOfSightBetween(Position(me.x, me.y, me.z + dz), Position(at.x, at.y, at.z + dz))
                ? "in LOS" : "not in LOS";
        }
        systemMessage(format!"Result was: %s %s %s."(sight(0), sight(2), sight(5)));
        return true;
    }

    /// `.debug showreact`: an `SMSG_AI_REACTION` for the selected creature.
    bool handleShowReactionCommand(uint reaction)
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        ByteWriter w;
        w.put(creature.guid);
        w.put(reaction);
        deliver(Opcode.SMSG_AI_REACTION, w.data);
        systemMessage(format!"Sent Reaction of %s to %s"(reaction, cast(uint) creature.guid));
        return true;
    }

    /// `.debug itempushresult`: an `SMSG_ITEM_PUSH_RESULT` laid out as in 2.4.3.
    bool handleSendItemPushResultCommand(uint itemId, uint count = 0, uint type = 0, uint unk1 = 0, uint unk2 = 0,
        uint unk3 = 0, uint unk4 = 0)
    {
        if (itemId == 0)
            return false;
        ByteWriter w;
        w.put(player.guid);
        w.put(type);
        w.put(uint(1));
        w.put(count);
        w.put(ubyte(0xFF));
        w.put(unk1);
        w.put(itemId);
        w.put(unk2);
        w.put(unk3);
        w.put(unk4);
        deliver(Opcode.SMSG_ITEM_PUSH_RESULT, w.data);
        return true;
    }

    /// `.debug face`: the creature's facing, in degrees, changed here only (the clients are not told).
    bool handleFaceCommand(uint degrees = 0)
    {
        if (auto creature = selectedCreature(true))
            creature.movement.position.orientation = degrees / (360 / 6.28f);
        return true;
    }

    /// `.debug testindoor`: whether the player stands indoors, by the vmaps.
    bool handleCollisionTestIndoorCommand()
    {
        auto terrain = vmapTerrain();
        if (terrain is null)
            return true;
        const at = player.position;
        const indoors = !terrain.isOutdoors(at.x, at.y, at.z + 2.0f);
        systemMessage(format!"Result was: %s."(indoors ? "indoors" : "outside"));
        return true;
    }

    /// `.debug getheight`: the vmap heights above and at the player, the land's, and whether 5 yards ahead
    /// is blocked.
    bool handleCollisionGetHeightCommand()
    {
        auto terrain = vmapTerrain();
        if (terrain is null)
            return true;
        enum float radius = 5.0f;
        const at = player.position;
        const from2 = terrain.vmapHeight(at.x, at.y, at.z + 2.0f);
        const from5 = terrain.vmapHeight(at.x, at.y, at.z + 5.0f);
        const fromFeet = terrain.vmapHeight(at.x, at.y, at.z);
        const land = terrain.height(at.x, at.y);
        // Whether something stands in the way 5 yards ahead (1.5 yards short of the point).
        const blocked = !terrain.isInLineOfSight(at.x, at.y, at.z, at.x + radius * cos(at.orientation),
            at.y + radius * sin(at.orientation), at.z);
        systemMessage(format!("Results were: %f(offset2.0f) | %f(offset5.0f) | %f(org) | landheight:%f"
            ~ " | target radius5 FP:%d")(from2, from5, fromFeet, land, blocked ? 1 : 0));
        return true;
    }

    /// `.debug getpos`: a spell's icon; nothing for an unknown spell.
    bool handleGetPosCommand(uint id)
    {
        if (const spell = context.data.spells.spell(id))
            blueSystemMessage(format!"SpellIcon for %d is %d"(spell.id, spell.casting.spellIconId));
        return true;
    }

    /// `.debug distance`: the distance to the selection.
    bool handleDistanceCommand()
    {
        Position at;
        if (!selectedPosition(at))
            return true;
        const me = player.position;
        systemMessage(format!"Distance is: %g"(sqrt((at.x - me.x) ^^ 2 + (at.y - me.y) ^^ 2 + (at.z - me.z) ^^ 2)));
        return true;
    }

    /// `.debug setbytes`: an update field of the selected unit set byte by byte.
    bool handleSetBytesCommand(uint index, ubyte b0, ubyte b1, ubyte b2, ubyte b3)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (index >= unit.values.length)
            return false; // past the object's fields: refused, not written
        unit.values.setSlot(index, b0 | b1 << 8 | b2 << 16 | uint(b3) << 24);
        unit.flush(this);
        greenSystemMessage(format!"Set Field %s bytes to %s %s %s %s"(index, b0, b1, b2, b3));
        return true;
    }

    /// `.debug getbytes`: an update field of the selected unit, byte by byte.
    bool handleGetBytesCommand(uint slot)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (slot >= unit.values.length)
            return false;
        const value = unit.values[slot];
        systemMessage(format!"bytes for Field %s are %s %s %s %s"(slot, value & 0xFF, value >> 8 & 0xFF,
            value >> 16 & 0xFF, value >> 24));
        return true;
    }

    /// The four movement tests: an order to the selected player, then "... Test Ran.".
    bool movementTest(Opcode opcode)(string what, bool failWithoutSelection)
    {
        auto target = selectedCharacter(true);
        if (target is null)
        {
            redSystemMessage("No character selected.");
            return !failWithoutSelection;
        }
        target.sendMovementOrder!opcode();
        greenSystemMessage(what ~ " Test Ran.");
        return true;
    }

    /// `.debug unroot`.
    bool handleDebugUnrootCommand()
    {
        return movementTest!(Opcode.SMSG_FORCE_MOVE_UNROOT)("UnRoot", true);
    }

    /// `.debug root`.
    bool handleDebugRootCommand()
    {
        return movementTest!(Opcode.SMSG_FORCE_MOVE_ROOT)("Root", false);
    }

    /// `.debug landwalk`.
    bool handleDebugLandWalkCommand()
    {
        return movementTest!(Opcode.SMSG_MOVE_LAND_WALK)("Land Walk", true);
    }

    /// `.debug waterwalk`.
    bool handleDebugWaterWalkCommand()
    {
        return movementTest!(Opcode.SMSG_MOVE_WATER_WALK)("Water Walk", true);
    }

    /// `.debug knockback`: the player knocked back the way it faces (5 by default, or for 0).
    bool handleKnockBackCommand(float speed = 5)
    {
        const strength = speed == 0 ? 5 : speed;
        const facing = player.position.orientation;
        // The packet: cos, sin, the speed, and two thirds of it upwards.
        send(ServerKnockBack(player.guid, moveOrderCounter++, cos(facing), sin(facing), strength, strength * 0.66f));
        resetMovementCheck();
        return true;
    }

    /// `.debug setbit`: one bit of an update field of the selected unit flipped.
    bool handleModifyBitCommand(ushort field, uint bit)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (field < 1 || field >= PLAYER_END || field >= unit.values.length || bit < 1 || bit > 32)
        {
            redSystemMessage("Incorrect values.");
            return true;
        }
        const mask = 1u << (bit - 1);
        const value = unit.values[field];
        unit.values.setSlot(field, value ^ mask);
        unit.flush(this);
        greenSystemMessage(value & mask ? format!"Removed bit %d in field %d."(bit, field)
            : format!"Set bit %d in field %d."(bit, field));
        return true;
    }

    /// `.debug setvalue`: an update field of the selected unit set.
    bool handleModifyValueCommand(ushort field, uint value)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (field < 1 || field >= PLAYER_END || field >= unit.values.length)
        {
            redSystemMessage("Choose a valid update field.");
            return true;
        }
        const oldValue = unit.values[field];
        unit.values.setSlot(field, value);
        unit.flush(this);
        greenSystemMessage(format!"Set Field %d from %d to %d."(field, oldValue, value));
        return true;
    }

    /// `.debug getUint32Value`: an update field of the selected player or creature (not oneself by default).
    bool handleGetUint32ValueCommand(uint index)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        SelectedUnit unit;
        unit.player = cast(Character) map.find(guid);
        if (unit.player is null)
            unit.creature = cast(Creature) map.findObject(guid);
        if (!unit.found)
        {
            redSystemMessage("You need to select a creature or character.");
            return true;
        }
        const end = unit.player !is null ? PLAYER_END : UNIT_END;
        if (index >= end)
        {
            redSystemMessage(format!"index must be less than %s."(end));
            return true;
        }
        blueSystemMessage(format!"Value at index %s: %s."(index, unit.values[index]));
        return true;
    }

    // -----------------------------------------------------------------------
    // .recall, on game_tele
    // -----------------------------------------------------------------------

    /// The recall locations, in name order.
    GameTele[] recallLocations()
    {
        auto places = context.data.teleports.dup;
        places.sort!((a, b) => a.name < b.name);
        return places;
    }

    /// The first `length` letters of the two are the same, in any case.
    static bool sameStart(string text, string name, size_t length)
    {
        const a = text.length < length ? text : text[0 .. length];
        const b = name.length < length ? name : name[0 .. length];
        return sicmp(a, b) == 0;
    }

    /// `.recall list`: the locations' names, five to a line.
    bool handleRecallListCommand()
    {
        const places = recallLocations();
        if (places.length == 0)
            return false;
        string text = colored(ChatColor.green, "Recall locations") ~ ":\n\n";
        foreach (i, const ref place; places)
        {
            text ~= colored(ChatColor.sky, place.name) ~ ", ";
            if (i % 5 == 4)
                text ~= "\n";
        }
        sendMultilineMessage(text);
        return true;
    }

    /// `.recall go`: to the first location (in name order) whose name starts with the one given.
    bool handleRecallGoCommand(Rest name)
    {
        foreach (const ref place; recallLocations())
            if (sameStart(name, place.name, name.length))
            {
                commandTeleport(place.map, Position(place.x, place.y, place.z, 0));
                return true;
            }
        return false;
    }

    /// `.recall add`: the player's position saved under a name.
    bool handleRecallAddCommand(Rest name)
    {
        if (context.data.teleports.canFind!(place => name.startsWith(place.name)))
        {
            redSystemMessage("Name in use, please use another name for your location.");
            return true;
        }
        const at = player.position;
        const place = GameTele(at.x, at.y, at.z, 0, player.data.map, name);
        context.database.addTeleport(place);
        context.data.teleports ~= place;
        greenSystemMessage(format!"Added location to DB with MapID: %d, X: %f, Y: %f, Z: %f"(player.data.map, at.x,
            at.y, at.z));
        gmLog(format!"used recall add, added \"%s\" location to database."(name));
        return true;
    }

    /// `.recall delete`: the first location whose whole name begins the name given.
    bool handleRecallDelCommand(Rest name)
    {
        import std.algorithm.mutation : remove;

        foreach (const ref place; recallLocations())
            if (sameStart(name, place.name, place.name.length))
            {
                const placeName = place.name;
                if (!context.database.deleteTeleport(placeName))
                    return false;
                context.data.teleports = context.data.teleports.remove!(t => t.name == placeName);
                greenSystemMessage("Recall location removed.");
                gmLog(format!"used recall delete, removed \"%s\" location from database."(name));
                return true;
            }
        return false;
    }

    /// `.recall portplayer`: an online player sent to a location.
    bool handleRecallPortPlayerCommand(string name, string location)
    {
        auto found = context.onlinePlayer(name);
        if (found is null)
            return false;
        auto target = sessionOf(found);
        // A location matches when its name starts with the name given (in any case): the name's
        // length counts, not the whole command line's, which would match only names that long.
        foreach (const ref place; recallLocations())
            if (sameStart(location, place.name, location.length))
            {
                gmLog(format!"ported %s to %s ( map: %u, x: %f, y: %f, z: %f )"(target.player.data.name, place.name,
                    place.map, place.x, place.y, place.z));
                target.commandTeleport(place.map, Position(place.x, place.y, place.z, 0));
                return true;
            }
        return false;
    }

    // -----------------------------------------------------------------------
    // Battleground commands
    // -----------------------------------------------------------------------

    /// Starts every queued battleground: a copy for whoever waits, however few.
    bool handleInitializeAllQueuedBattlegroundsCommand()
    {
        import dmangos.world.bgqueue : BattlegroundInstance, BattlegroundQueueHost;

        systemMessage("Starting queued battlegrounds.");
        context.services.call!(BattlegroundQueueHost.forceStart)(BattlegroundInstance(0));
        greenSystemMessage("...done");
        return true;
    }

    /// The player leaves their own slot in the current battleground.
    bool handleBattlegroundExitCommand()
    {
        if (joinedBattleground() !is null)
            leaveBattleground(true);
        return true;
    }

    /// `.bg pause`: the current match paused or resumed (toggled without an argument).
    bool handlePauseBGCommand(Nullable!OnOff state)
    {
        auto copy = joinedBattleground();
        if (copy is null)
            return true;
        const pause = state.isNull ? !copy.paused : state.get == OnOff.on;
        if (!copy.setPaused(pause))
        {
            redSystemMessage("Only an active match or its countdown can be paused.");
            return true;
        }
        context.battlegrounds.flushCheckpoints();
        gmLog(format!"set battleground %s paused=%s"(copy.instance, pause));
        greenSystemMessage(pause ? "Battleground paused." : "Battleground resumed.");
        return true;
    }

    /// `.bg start`: the current battleground started now.
    bool handleStartBGCommand()
    {
        if (auto copy = joinedBattleground())
            copy.start();
        return true;
    }

    /// `.bg status`: the current match's type, copy and status.
    bool handleBattlegroundInfoCommand()
    {
        import std.conv : to;

        if (auto copy = joinedBattleground())
            systemMessage(format!"%s · Copy %s · %s"(copy.type, copy.instance,
                copy.paused ? "Paused" : copy.status.to!string));
        return true;
    }

    /// `.bg battleground`: the current match, and where to find the other commands.
    bool handleBattlegroundCommand()
    {
        handleBattlegroundInfoCommand();
        systemMessage("Use .bg to see battleground commands.");
        return true;
    }

    /// `.bg queue`: the battlegroup's queued players and matches, as the queue host counts them.
    bool handleGetBattlegroundQueueCommand()
    {
        import dmangos.world.bgqueue : BattlegroundPlayer, BattlegroundQueueHost, BattlegroundQueueStats;

        context.services.call!(BattlegroundQueueHost.stats)(BattlegroundPlayer(player.guid, context.nodeId),
            (BattlegroundQueueStats report) {
                if (player !is null)
                    systemMessage(format!"%s queued or invited across all brackets, %s active matches."
                        (report.queuedPlayers, report.activeMatches));
            });
        return true;
    }

    /// `.bg setbfstatus start`: as `.bg start`.
    bool handleSetBattlefieldStatusCommand(string action)
    {
        return action == "start" && handleStartBGCommand();
    }

    /// `.bg score`: a team's score in Warsong Gulch or Arathi Basin, short of a win.
    bool handleSetBGScoreCommand(string teamName, uint score)
    {
        import dmangos.world.arathi : resourceStates, maxResources;
        import dmangos.world.bgqueue : BattlegroundStatus, BattlegroundType;
        import dmangos.world.warsong : captureStates, maxCaptures;

        if (teamName != "alliance" && teamName != "horde")
            return false;
        const team = teamName == "alliance" ? 0 : 1;
        auto copy = currentBattleground();
        if (copy is null || copy.status != BattlegroundStatus.inProgress)
        {
            redSystemMessage("Join a match in progress first.");
            return true;
        }
        if (copy.type == BattlegroundType.warsongGulch && score < maxCaptures)
            copy.setWorldState(captureStates[team], score);
        else if (copy.type == BattlegroundType.arathiBasin && score < maxResources)
            copy.setWorldState(resourceStates[team], score);
        else
            redSystemMessage("Set a below-win score in Warsong Gulch or Arathi Basin.");
        return true;
    }

    /// `.bg worldstate`: a world state of the current battleground set.
    bool handleSetWorldStateCommand(uint id, uint value)
    {
        if (auto copy = joinedBattleground())
            copy.setWorldState(id, value);
        return true;
    }

    /// `.bg setworldstates`: as `.bg worldstate`.
    bool handleSetWorldStatesCommand(uint id, uint value)
    {
        return handleSetWorldStateCommand(id, value);
    }

    /// `.bg sound`: a sound played to the current battleground.
    bool handlePlaySoundCommand(uint sound)
    {
        if (auto copy = joinedBattleground())
            copy.playSound(sound);
        return true;
    }
}

/// `.debug threatList`, `.debug aggrorange`, `.debug infront` and `.debug testlos` at a creature.
unittest
{
    import std.format : format;
    import std.math : abs;
    import std.algorithm.searching : canFind, startsWith;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.chatstyle : ChatColor;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.administrator);
    gm.read();
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    gm.say(".debug threatList");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Select a creature first.|r"]);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
    gm.say(".debug threatList");
    assert(systemMessages(gm.read())[0].startsWith("threatlist of creature: "));
    gm.say(".debug aggrorange");
    assert(systemMessages(gm.read())[0].startsWith("Aggrorange is: "));
    gm.say(".debug infront");
    const front = systemMessages(gm.read());
    assert(front == ["0"] || front == ["1"]);
    gm.say(".debug testlos");
    assert(systemMessages(gm.read()) == ["Result was: in LOS in LOS in LOS."], "no terrain in the test: all in sight");
    gm.say(".debug testindoor");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Collision is not enabled.|r"]);
    gm.say(".debug getheight");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Collision is not enabled.|r"]);
    gm.say(".debug showreact 2");
    {
        const sent = gm.read();
        assert(opcodesOf(sent).canFind(Opcode.SMSG_AI_REACTION));
        assert(systemMessages(sent) == [format!"Sent Reaction of 2 to %s"(cast(uint) keeper.guid)]);
    }
    gm.say(".debug face 90");
    gm.read();
    assert(abs(keeper.position.orientation - 90 / (360 / 6.28f)) < 0.001f);
    gm.say(".debug itempushresult 25 1");
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_ITEM_PUSH_RESULT));
    gm.say(".debug getpos 999999");
    assert(systemMessages(gm.read()).length == 0, "no such spell: nothing");
}
