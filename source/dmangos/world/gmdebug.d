/**
 * ArcEmu's `debugcmds.cpp` handlers (the `.debug` group) that need no AI,
 * spells or line of sight, `RecallCommands.cpp` (the `.recall` group) and
 * `BattlegroundCommands.cpp`'s `playsound` and `setworldstate`. Mixed into
 * `dmangos.world.session.WorldSession`.
 *
 * ArcEmu's recall locations are its `recall` table; CMaNGOS's is `game_tele`,
 * which `.recall` reads and writes here, in name order.
 */
module dmangos.world.gmdebug;

/// See the module documentation.
mixin template DebugCommands()
{
    import std.algorithm.searching : canFind, startsWith;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import std.math : cos, sin, sqrt;
    import std.uni : sicmp;
    import dmangos.world.commands;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : GameTele;

private:
    /// What `GetMapMgr()->GetUnit(selection)` finds, or oneself without a selection.
    struct SelectedUnit
    {
        WorldSession player;
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
        void flush(WorldSession by)
        {
            if (player !is null)
                player.flushPlayerChanges();
            else
                by.map.flushObjectChanges(creature);
        }
    }

    /// The selected unit, oneself without a selection; not found after "You should select a character or a creature.".
    SelectedUnit selectedUnit()
    {
        SelectedUnit unit;
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
            unit.player = this;
        else
        {
            unit.player = cast(WorldSession) map.find(guid);
            if (unit.player is null)
                unit.creature = cast(Creature) map.findObject(guid);
        }
        if (!unit.found)
            systemMessage("You should select a character or a creature.");
        return unit;
    }

    // -----------------------------------------------------------------------
    // debugcmds.cpp
    // -----------------------------------------------------------------------

    bool handleThreatListCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto target = cast(Creature) map.findObject(guid);
        if (target is null || target.ai is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        string text = format!"threatlist of creature: %s %s\n"(guid & 0xFFFF_FFFF, guid >> 32);
        foreach (who, amount; target.ai.threatList)
            if (amount && (map.find(who) !is null))
                text ~= format!"guid: %s | threat: %s| threat after mod: %s\n"(who, amount, amount);
        sendMultilineMessage(text);
        return true;
    }

    bool handleAggroRangeCommand()
    {
        import dmangos.world.creatureai : Combatant;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto creature = guid ? cast(Creature) map.findObject(guid) : null;
        if (creature is null || creature.ai is null)
        {
            systemMessage("You should select a character or a creature.");
            return true;
        }
        systemMessage(format!"Aggrorange is: %s"(creature.ai.aggroRangeFor(cast(Combatant) this)));
        return true;
    }

    bool handleDebugInFrontCommand()
    {
        import std.math : atan2, PI;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        Position at = player.position;
        if (guid)
        {
            if (auto o = map.findObject(guid))
                at = o.position;
            else if (auto who = map.find(guid))
                at = who.character.position;
            else
            {
                systemMessage("You should select a character or a creature.");
                return true;
            }
        }
        // `Object::isInFront`: within the half circle it faces.
        const me = player.position;
        double angle = atan2(at.y - me.y, at.x - me.x);
        angle = angle >= 0 ? angle : 2 * PI + angle;
        angle -= me.orientation;
        while (angle > PI)
            angle -= 2 * PI;
        while (angle < -PI)
            angle += 2 * PI;
        const left = -PI / 2, right = PI / 2;
        systemMessage(format!"%d"(angle >= left && angle <= right ? 1 : 0));
        return true;
    }

    bool handleCollisionTestLOS()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Position at;
        if (auto creature = getSelectedCreature(false))
            at = creature.position;
        else if (auto who = guid ? map.find(guid) : null)
            at = who.character.position;
        else
        {
            systemMessage("Invalid target.");
            return true;
        }
        const me = player.position;
        string los(float dz)
        {
            return map.lineOfSightBetween(Position(me.x, me.y, me.z + dz), Position(at.x, at.y, at.z + dz))
                ? "in LOS" : "not in LOS";
        }
        systemMessage(format!"Result was: %s %s %s."(los(0), los(2), los(5)));
        return true;
    }

    bool handleShowReactionCommand(uint reaction)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.opcodes : Opcode;

        auto creature = getSelectedCreature(false);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        ByteWriter w;
        w.put(creature.guid);
        w.put(reaction);
        deliver(Opcode.SMSG_AI_REACTION, w.data);
        systemMessage(format!"Sent Reaction of %s to %s"(reaction, cast(uint) creature.guid));
        return true;
    }

    /// ArcEmu's `.debug itempushresult`: an `SMSG_ITEM_PUSH_RESULT` laid out as ArcEmu's (2.4.3's) is.
    bool handleSendItemPushResult(uint itemId, uint count = 0, uint type = 0, uint unk1 = 0, uint unk2 = 0,
        uint unk3 = 0, uint unk4 = 0)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.opcodes : Opcode;

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

    /// ArcEmu's `.debug face`: the creature's facing, in degrees, changed here only (the clients are not told).
    bool handleFaceCommand(uint degrees = 0)
    {
        auto creature = getSelectedCreature(false);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        creature.movement.position.orientation = degrees / (360 / 6.28f);
        return true;
    }

    bool handleCollisionTestIndoor()
    {
        auto terrain = map.collision;
        if (terrain is null || !terrain.hasVmaps)
        {
            systemMessage("Collision is not enabled.");
            return true;
        }
        const at = player.position;
        const indoors = !terrain.isOutdoors(at.x, at.y, at.z + 2.0f);
        systemMessage(format!"Result was: %s."(indoors ? "indoors" : "outside"));
        return true;
    }

    bool handleCollisionGetHeight()
    {
        import std.math : cos, sin;

        auto terrain = map.collision;
        if (terrain is null || !terrain.hasVmaps)
        {
            systemMessage("Collision is not enabled.");
            return true;
        }
        enum float radius = 5.0f;
        const at = player.position;
        const z = terrain.vmapHeight(at.x, at.y, at.z + 2.0f);
        const z2 = terrain.vmapHeight(at.x, at.y, at.z + 5.0f);
        const z3 = terrain.vmapHeight(at.x, at.y, at.z);
        const z4 = terrain.height(at.x, at.y);
        // `GetFirstPoint` with -1.5: whether something stands in the way 5 yards ahead.
        const fp = !terrain.isInLineOfSight(at.x, at.y, at.z, at.x + radius * cos(at.orientation),
            at.y + radius * sin(at.orientation), at.z);
        systemMessage(format!"Results were: %f(offset2.0f) | %f(offset5.0f) | %f(org) | landheight:%f | target radius5 FP:%d"(
            z, z2, z3, z4, fp ? 1 : 0));
        return true;
    }

    bool handleGetPosCommand(uint id)
    {
        if (const spell = context.data.spells.spell(id))
            blueSystemMessage(format!"SpellIcon for %d is %d"(spell.id, spell.casting.spellIconId));
        return true;
    }

    bool handleDistanceCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Position at = player.position;
        if (guid != 0)
        {
            if (auto other = map.find(guid))
                at = other.character.position;
            else if (auto object = map.findObject(guid))
                at = object.position;
            else
            {
                systemMessage("You should select a character or a creature.");
                return true;
            }
        }
        const me = player.position;
        systemMessage(format!"Distance is: %g"(sqrt((at.x - me.x) ^^ 2 + (at.y - me.y) ^^ 2 + (at.z - me.z) ^^ 2)));
        return true;
    }

    bool handleSetBytesCommand(uint index, ubyte b0, ubyte b1, ubyte b2, ubyte b3)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        const ubyte[4] b = [b0, b1, b2, b3];
        if (index >= unit.values.length)
            return false; // past the object's fields (ArcEmu writes there regardless)
        unit.values.setSlot(index, b[0] | b[1] << 8 | b[2] << 16 | uint(b[3]) << 24);
        unit.flush(this);
        systemMessage(format!"Set Field %s bytes to %s %s %s %s"(index, b[0], b[1], b[2], b[3]));
        return true;
    }

    bool handleGetBytesCommand(uint slot)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (slot >= unit.values.length)
            return false;
        const v = unit.values[slot];
        systemMessage(format!"bytes for Field %s are %s %s %s %s"(slot, v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF,
            v >> 24));
        return true;
    }

    /// The four `SetMovement` tests: an order to the selected player, then "... Test Ran.".
    bool movementTest(Opcode opcode)(string what, bool failWithoutSelection)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
        {
            systemMessage("No character selected.");
            return !failWithoutSelection;
        }
        chr.sendMovementOrder!opcode();
        systemMessage(what ~ " Test Ran.");
        return true;
    }

    bool handleDebugUnroot()
    {
        return movementTest!(Opcode.SMSG_FORCE_MOVE_UNROOT)("UnRoot", true);
    }

    bool handleDebugRoot()
    {
        return movementTest!(Opcode.SMSG_FORCE_MOVE_ROOT)("Root", false);
    }

    bool handleDebugLandWalk()
    {
        return movementTest!(Opcode.SMSG_MOVE_LAND_WALK)("Land Walk", true);
    }

    bool handleDebugWaterWalk()
    {
        return movementTest!(Opcode.SMSG_MOVE_WATER_WALK)("Water Walk", true);
    }

    bool handleKnockBackCommand(float f = 5)
    {
        if (f == 0)
            f = 5;
        const o = player.position.orientation;
        // ArcEmu's packet: cos, sin, the speed, and two thirds of it upwards.
        send(ServerKnockBack(player.guid, moveOrderCounter++, cos(o), sin(o), f, f * 0.66f));
        resetMovementCheck();
        return true;
    }

    bool handleModifyBitCommand(ushort field, uint bit)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (field < 1 || field >= PLAYER_END || field >= unit.values.length || bit < 1 || bit > 32)
        {
            systemMessage("Incorrect values.");
            return true;
        }
        const mask = 1u << (bit - 1);
        const value = unit.values[field];
        unit.values.setSlot(field, value ^ mask);
        unit.flush(this);
        systemMessage(format(value & mask ? "Removed bit %d in field %d." : "Set bit %d in field %d.", bit, field));
        return true;
    }

    bool handleModifyValueCommand(ushort field, uint value)
    {
        auto unit = selectedUnit();
        if (!unit.found)
            return true;
        if (field < 1 || field >= PLAYER_END || field >= unit.values.length)
        {
            systemMessage("Incorrect Field.");
            return true;
        }
        const oldValue = unit.values[field];
        unit.values.setSlot(field, value);
        unit.flush(this);
        systemMessage(format!"Set Field %d from %d to %d."(field, oldValue, value));
        return true;
    }

    /// ArcEmu compiles this command's body out (`_ONLY_FOOLS_TRY_THIS_`): it does nothing.
    bool handleSendpacket()
    {
        return true;
    }

    bool handleGetUint32ValueCommand(uint index)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        SelectedUnit unit;
        unit.player = cast(WorldSession) map.find(guid);
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
    // RecallCommands.cpp, on game_tele
    // -----------------------------------------------------------------------

    /// `SELECT * FROM recall ORDER BY name`
    GameTele[] recallLocations()
    {
        auto places = context.data.teleports.dup;
        places.sort!((a, b) => a.name < b.name);
        return places;
    }

    /// `strnicmp(text, name, length)`: the first `length` letters of the two are the same, in any case.
    static bool sameStart(string text, string name, size_t length)
    {
        const a = text.length < length ? text : text[0 .. length];
        const b = name.length < length ? name : name[0 .. length];
        return sicmp(a, b) == 0;
    }

    bool handleRecallListCommand()
    {
        auto places = recallLocations();
        if (places.length == 0)
            return false;
        string text = MSG_COLOR_GREEN ~ "Recall locations|r:\n\n";
        uint count;
        foreach (ref place; places)
        {
            text ~= MSG_COLOR_LIGHTBLUE ~ place.name ~ "|r, ";
            if (++count == 5)
            {
                text ~= "\n";
                count = 0;
            }
        }
        sendMultilineMessage(text);
        return true;
    }

    bool handleRecallGoCommand(Rest name)
    {
        foreach (ref place; recallLocations())
            if (sameStart(name, place.name, name.length))
            {
                commandTeleport(place.map, Position(place.x, place.y, place.z, 0));
                return true;
            }
        return false;
    }

    bool handleRecallAddCommand(Rest name)
    {
        if (context.data.teleports.canFind!(place => name.startsWith(place.name)))
        {
            redSystemMessage("Name in use, please use another name for your location.");
            return true;
        }
        const p = player.position;
        const place = GameTele(p.x, p.y, p.z, 0, player.data.map, name);
        context.database.addTeleport(place);
        context.data.teleports ~= place;
        greenSystemMessage(format!"Added location to DB with MapID: %d, X: %f, Y: %f, Z: %f"(player.data.map, p.x, p.y,
            p.z));
        gmLog(format!"used recall add, added \"%s\" location to database."(name));
        return true;
    }

    bool handleRecallDelCommand(Rest name)
    {
        import std.algorithm.mutation : remove;

        foreach (ref place; recallLocations())
            if (sameStart(name, place.name, place.name.length))
            {
                const placeName = place.name;
                context.database.deleteTeleport(placeName);
                context.data.teleports = context.data.teleports.remove!(t => t.name == placeName);
                greenSystemMessage("Recall location removed.");
                gmLog(format!"used recall delete, removed \"%s\" location from database."(name));
                return true;
            }
        return false;
    }

    bool handleRecallPortPlayerCommand(string name, string location)
    {
        auto found = context.onlinePlayer(name);
        if (found is null)
            return false;
        auto plr = sessionOf(found);
        // ArcEmu compares `strlen(args)` letters, the whole command line, and so finds nothing unless the
        // location's name is that long; this compares the location's letters.
        foreach (ref place; recallLocations())
            if (sameStart(location, place.name, location.length))
            {
                gmLog(format!"ported %s to %s ( map: %u, x: %f, y: %f, z: %f )"(plr.player.data.name, place.name,
                    place.map, place.x, place.y, place.z));
                plr.commandTeleport(place.map, Position(place.x, place.y, place.z, 0));
                return true;
            }
        return false;
    }

    // -----------------------------------------------------------------------
    // BattlegroundCommands.cpp: there are no battlegrounds yet, so nobody is in one
    // -----------------------------------------------------------------------

    bool handleSetWorldStateCommand(uint id, uint value)
    {
        return true; // ArcEmu sets it in the player's battleground, if any
    }

    bool handlePlaySoundCommand()
    {
        systemMessage("You're not in a battleground!");
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
    assert(systemMessages(gm.read()) == ["You should select a creature."]);
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
    assert(systemMessages(gm.read()) == ["Collision is not enabled."]);
    gm.say(".debug getheight");
    assert(systemMessages(gm.read()) == ["Collision is not enabled."]);
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
