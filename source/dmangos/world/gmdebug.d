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
