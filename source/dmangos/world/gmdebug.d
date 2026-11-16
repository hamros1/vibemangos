/**
 * GM commands that look things up or poke at the protocol (ArcEmu's
 * `.lookup` and `.debug` groups, `.paralyze`, and the battleground group's
 * `playsound` and `setworldstate`). Mixed into
 * `dmangos.world.session.WorldSession`.
 *
 * `.lookup item` and `.lookup skill` search what the server has loaded;
 * quests, creatures, game objects and spells are searched in the world
 * database, since the server does not load their names.
 */
module dmangos.world.gmdebug;

/// See the module documentation.
mixin template DebugCommands()
{
    import std.algorithm.comparison : min;
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.math : cos, sin, sqrt;
    import std.uni : toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : Command, readArguments;
    import dmangos.world.database : LookupResult, LookupTable;
    import dmangos.world.map : packetBody;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.updatefields;

private:
    /// The most results a lookup shows.
    enum maxLookupResults = 50;

    void showLookup(string what, const(LookupResult)[] found)
    {
        if (found.length == 0)
        {
            sendSystemMessage(format!"No %s found."(what));
            return;
        }
        foreach (row; found)
            sendSystemMessage(format!"%s - %s"(row.id, row.name));
        if (found.length == maxLookupResults)
            sendSystemMessage(format!"Only the first %s are shown."(maxLookupResults));
    }

    @Command("lookup item", AccountLevel.moderator, "text", "Finds items by name.", ["lookupitem"])
    bool commandLookupItem(string args)
    {
        if (args.length == 0)
            return false;
        LookupResult[] found;
        foreach (entry, ref item; context.data.items)
            if (item.details.name.toLower.canFind(args.toLower))
                found ~= LookupResult(entry, item.details.name);
        found.sort!((a, b) => a.id < b.id);
        showLookup("items", found[0 .. min(found.length, maxLookupResults)]);
        return true;
    }

    @Command("lookup skill", AccountLevel.moderator, "text", "Finds skills by name.")
    bool commandLookupSkill(string args)
    {
        if (args.length == 0)
            return false;
        LookupResult[] found;
        foreach (ref skill; context.client.skillLines.rows)
            if (skill.name[0].toLower.canFind(args.toLower))
                found ~= LookupResult(skill.id, skill.name[0]);
        showLookup("skills", found[0 .. min(found.length, maxLookupResults)]);
        return true;
    }

    /// The lookups that search a world table.
    bool lookupInDatabase(LookupTable table, string what, string args)
    {
        if (args.length == 0)
            return false;
        showLookup(what, context.database.lookup(table, args, maxLookupResults));
        return true;
    }

    @Command("lookup quest", AccountLevel.moderator, "text", "Finds quests by title.", ["lookupquest", "quest lookup"])
    bool commandLookupQuest(string args)
    {
        return lookupInDatabase(LookupTable.quest, "quests", args);
    }

    @Command("lookup creature", AccountLevel.moderator, "text", "Finds creatures by name.", ["lookupcreature"])
    bool commandLookupCreature(string args)
    {
        return lookupInDatabase(LookupTable.creature, "creatures", args);
    }

    @Command("lookup object", AccountLevel.moderator, "text", "Finds game objects by name.")
    bool commandLookupObject(string args)
    {
        return lookupInDatabase(LookupTable.gameObject, "game objects", args);
    }

    @Command("lookup spell", AccountLevel.moderator, "text", "Finds spells by name.")
    bool commandLookupSpell(string args)
    {
        return lookupInDatabase(LookupTable.spell, "spells", args);
    }

    // -----------------------------------------------------------------------
    // Movement orders
    // -----------------------------------------------------------------------

    @Command("paralyze", AccountLevel.gameMaster, "", "Roots the selected player to the spot.", ["debug root"])
    bool commandParalyze(string)
    {
        auto target = selectedOrSelf();
        target.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        tellBoth(target, format!"%s is rooted."(target.player.data.name), "You have been rooted by a game master.");
        return true;
    }

    @Command("unparalyze", AccountLevel.gameMaster, "", "Lets the selected player move again.", ["debug unroot"])
    bool commandUnparalyze(string)
    {
        auto target = selectedOrSelf();
        target.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        tellBoth(target, format!"%s can move again."(target.player.data.name), "You can move again.");
        return true;
    }

    @Command("debug waterwalk", AccountLevel.administrator, "", "The selected player walks on water.")
    bool commandWaterWalk(string)
    {
        selectedOrSelf().sendMovementOrder!(Opcode.SMSG_MOVE_WATER_WALK)();
        return true;
    }

    @Command("debug landwalk", AccountLevel.administrator, "", "The selected player sinks in water again.")
    bool commandLandWalk(string)
    {
        selectedOrSelf().sendMovementOrder!(Opcode.SMSG_MOVE_LAND_WALK)();
        return true;
    }

    @Command("debug knockback", AccountLevel.administrator, "[speed]", "Knocks you back (and up).")
    bool commandKnockBack(string args)
    {
        float speed = 10;
        if (!readArguments!0(args, speed))
            return false;
        const o = player.position.orientation;
        send(ServerKnockBack(player.guid, moveOrderCounter++, -cos(o), -sin(o), speed, -speed));
        resetMovementCheck();
        return true;
    }

    // -----------------------------------------------------------------------
    // Fields, distances, packets
    // -----------------------------------------------------------------------

    @Command("debug dist", AccountLevel.administrator, "", "Shows the distance to the selected player.",
        ["debug rangecheck"])
    bool commandDistance(string)
    {
        auto target = selectedOrSelf();
        const a = player.position, b = target.player.position;
        sendSystemMessage(format!"Distance to %s: %.2f yards (%.2f on the ground)."(target.player.data.name,
            sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2), sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2)));
        return true;
    }

    @Command("debug getvalue", AccountLevel.administrator, "slot", "Shows an update field slot of the selected player.",
        ["debug getUint32Value"])
    bool commandGetValue(string args)
    {
        uint slot;
        if (!readArguments!1(args, slot))
            return false;
        auto target = selectedOrSelf();
        if (slot >= target.player.values.length)
        {
            sendSystemMessage(format!"A player has %s slots."(target.player.values.length));
            return true;
        }
        const value = target.player.values[slot];
        sendSystemMessage(format!"%s's slot %s: %s (0x%08X, as a float %s)"(target.player.data.name, slot, value,
            value, *cast(const float*)&value));
        return true;
    }

    @Command("debug setvalue", AccountLevel.administrator, "slot value",
        "Sets an update field slot of the selected player to a number (0x... for hex).")
    bool commandSetValue(string args)
    {
        uint slot;
        string text;
        if (!readArguments!2(args, slot, text))
            return false;
        uint value;
        try
            value = text.length > 2 && text[0 .. 2] == "0x" ? text[2 .. $].to!uint(16) : text.to!uint;
        catch (ConvException)
            return false;
        auto target = selectedOrSelf();
        if (slot >= target.player.values.length)
            return false;
        target.player.values.setSlot(slot, value);
        target.flushPlayerChanges();
        sendSystemMessage(format!"%s's slot %s is now %s."(target.player.data.name, slot, value));
        return true;
    }

    @Command("debug setbit", AccountLevel.administrator, "slot bit", "Sets a bit (0-31) of an update field slot.")
    bool commandSetBit(string args)
    {
        uint slot, bit;
        if (!readArguments!2(args, slot, bit) || bit > 31)
            return false;
        auto target = selectedOrSelf();
        if (slot >= target.player.values.length)
            return false;
        target.player.values.setSlot(slot, target.player.values[slot] | 1u << bit);
        target.flushPlayerChanges();
        return true;
    }

    @Command("debug getbytes", AccountLevel.administrator, "slot", "Shows the four bytes of an update field slot.")
    bool commandGetBytes(string args)
    {
        uint slot;
        if (!readArguments!1(args, slot))
            return false;
        auto target = selectedOrSelf();
        if (slot >= target.player.values.length)
            return false;
        const v = target.player.values[slot];
        sendSystemMessage(format!"Slot %s: %s %s %s %s"(slot, v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF, v >> 24));
        return true;
    }

    @Command("debug setbytes", AccountLevel.administrator, "slot b0 b1 b2 b3", "Sets the four bytes of an update field slot.")
    bool commandSetBytes(string args)
    {
        uint slot;
        ubyte b0, b1, b2, b3;
        if (!readArguments!5(args, slot, b0, b1, b2, b3))
            return false;
        auto target = selectedOrSelf();
        if (slot >= target.player.values.length)
            return false;
        target.player.values.setSlot(slot, b0 | b1 << 8 | b2 << 16 | uint(b3) << 24);
        target.flushPlayerChanges();
        return true;
    }

    @Command("debug sendpacket", AccountLevel.administrator, "opcode [hex body]", "Sends yourself a packet (opcode 0x...).")
    bool commandSendPacket(string args)
    {
        import std.ascii : isHexDigit;

        string opcodeText, hex;
        if (!readArguments!1(args, opcodeText, hex))
            return false;
        uint opcode;
        ubyte[] body_;
        try
        {
            opcode = opcodeText.length > 2 && opcodeText[0 .. 2] == "0x" ? opcodeText[2 .. $].to!uint(16) : opcodeText.to!uint;
            string digits;
            foreach (c; hex)
                if (c.isHexDigit)
                    digits ~= c;
            if (digits.length % 2)
                return false;
            for (size_t i = 0; i < digits.length; i += 2)
                body_ ~= digits[i .. i + 2].to!ubyte(16);
        }
        catch (ConvException)
            return false;
        if (opcode >= numMessageTypes)
            return false;
        deliver(cast(Opcode) opcode, body_);
        sendSystemMessage(format!"Sent opcode 0x%03X with %s bytes."(opcode, body_.length));
        return true;
    }

    @Command("npc info", AccountLevel.moderator, "", "Shows the selected creature: entry, spawn, level, faction, flags, model.")
    bool commandNpcInfo(string)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.objects : counterOf;

        auto creature = cast(Creature) map.findObject(player.values.get!UNIT_FIELD_TARGET);
        if (creature is null)
        {
            sendSystemMessage("Select a creature first.");
            return true;
        }
        const t = creature.template_;
        const v = &creature.values;
        sendSystemMessage(format!"%s <%s>: entry %s, spawn %s, level %s, health %s/%s"(t.name, t.subName, t.entry,
            counterOf(creature.guid), (*v)[UNIT_FIELD_LEVEL], (*v)[UNIT_FIELD_HEALTH], (*v)[UNIT_FIELD_MAXHEALTH]));
        sendSystemMessage(format!"faction %s, npc flags 0x%X, unit flags 0x%X, model %s, respawn %s s, movement type %s"(
            (*v)[UNIT_FIELD_FACTIONTEMPLATE], (*v)[UNIT_NPC_FLAGS], (*v)[UNIT_FIELD_FLAGS], (*v)[UNIT_FIELD_DISPLAYID],
            creature.spawn.respawnSeconds, creature.spawn.movementType));
        return true;
    }

    @Command("battleground playsound", AccountLevel.gameMaster, "sound", "Plays a sound (SoundEntries.dbc) to you.",
        ["playsound"])
    bool commandPlaySound(string args)
    {
        uint sound;
        if (!readArguments!1(args, sound))
            return false;
        send(ServerPlaySound(sound));
        return true;
    }

    @Command("battleground setworldstate", AccountLevel.gameMaster, "state value", "Sends you a world state.",
        ["setworldstate"])
    bool commandSetWorldState(string args)
    {
        uint state, value;
        if (!readArguments!2(args, state, value))
            return false;
        send(ServerUpdateWorldState(state, value));
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testclient;
}

/// Lookups in loaded data and in the world database; fields and orders.
unittest
{
    import dmangos.world.database : LookupResult, LookupTable;

    auto db = newDatabase();
    db.lookupRows[LookupTable.quest] = [LookupResult(7, "Kobold Camp Cleanup"), LookupResult(33, "Wolves Across the Border")];
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    gm.read();

    gm.say(".lookup item shortsword");
    assert(systemMessages(gm.read()) == ["25 - Worn Shortsword"]);
    gm.say(".lookupquest kobold");
    assert(systemMessages(gm.read()) == ["7 - Kobold Camp Cleanup"]);
    gm.say(".lookup creature hogger");
    assert(systemMessages(gm.read()) == ["No creatures found."]);

    // Deputy Willem stands by the abbey (see testdata): select him and ask.
    import dmangos.world.objects : HighGuid, makeGuid;

    gm.say(".npc info");
    assert(systemMessages(gm.read()) == ["Select a creature first."]);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientSetSelection(makeGuid(HighGuid.unit, creatureWillem, 79942)));
    gm.read();
    gm.say(".npc info");
    assert(systemMessages(gm.read())[0].canFind("Deputy Willem"));

    gm.say(".debug setvalue 22 0x2A");
    assert(gm.session.character.values[22] == 42);
    gm.say(".paralyze");
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_FORCE_MOVE_ROOT));
    gm.say(".debug sendpacket 0x2D2 01000000");
    assert(gm.read()[0].opcode == Opcode.SMSG_PLAY_SOUND);
}
