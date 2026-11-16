/**
 * GM commands that change a character (ArcEmu `Level2.cpp`/`Level3.cpp`:
 * the `.modify` and `.character` groups, `.levelup`, `.learn`, `.additem`,
 * `.mount`, `.cheat`, `.playerinfo`, ...). Mixed into
 * `dmangos.world.session.WorldSession`.
 *
 * Most act on the selected player, or on oneself if no player is selected,
 * as ArcEmu's `getSelectedChar` does. Like ArcEmu, `.modify` changes a field
 * until the character's stats are computed again (at the next login); level,
 * money, explored zones, skills, spells and items are saved.
 *
 * `.modify`'s plain fields are one table, `modifiableFields`; a command is
 * generated for each row.
 */
module dmangos.world.gmcharacter;

import dmangos.world.updatefields;

/// A field `.modify NAME value` sets (ArcEmu's `modifyCommandTable` rows with a field).
struct ModifiableField
{
    string name;
    UpdateFieldId field;
    size_t index;               /// element of `field`
    bool alsoMaximum;           /// sets `maximum` (same index) too, as `.modify hp` sets the maximum health
    UpdateFieldId maximum;
    string help;
}

private alias F = ModifiableField;

/// See the module documentation.
enum ModifiableField[] modifiableFields = [
    F("hp", UNIT_FIELD_HEALTH, 0, true, UNIT_FIELD_MAXHEALTH, "Sets health and maximum health."),
    F("mana", UNIT_FIELD_POWER1, 0, true, UNIT_FIELD_MAXPOWER1, "Sets mana and maximum mana."),
    F("rage", UNIT_FIELD_POWER1, 1, true, UNIT_FIELD_MAXPOWER1, "Sets rage and maximum rage (tenths)."),
    F("energy", UNIT_FIELD_POWER1, 3, true, UNIT_FIELD_MAXPOWER1, "Sets energy and maximum energy."),
    F("strength", UNIT_FIELD_STAT0, 0, false, UNIT_FIELD_STAT0, "Sets strength."),
    F("agility", UNIT_FIELD_STAT0, 1, false, UNIT_FIELD_STAT0, "Sets agility."),
    F("stamina", UNIT_FIELD_STAT0, 2, false, UNIT_FIELD_STAT0, "Sets stamina."),
    F("intelligence", UNIT_FIELD_STAT0, 3, false, UNIT_FIELD_STAT0, "Sets intelligence."),
    F("spirit", UNIT_FIELD_STAT0, 4, false, UNIT_FIELD_STAT0, "Sets spirit."),
    F("armor", UNIT_FIELD_RESISTANCES, 0, false, UNIT_FIELD_RESISTANCES, "Sets armor."),
    F("holy", UNIT_FIELD_RESISTANCES, 1, false, UNIT_FIELD_RESISTANCES, "Sets holy resistance."),
    F("fire", UNIT_FIELD_RESISTANCES, 2, false, UNIT_FIELD_RESISTANCES, "Sets fire resistance."),
    F("nature", UNIT_FIELD_RESISTANCES, 3, false, UNIT_FIELD_RESISTANCES, "Sets nature resistance."),
    F("frost", UNIT_FIELD_RESISTANCES, 4, false, UNIT_FIELD_RESISTANCES, "Sets frost resistance."),
    F("shadow", UNIT_FIELD_RESISTANCES, 5, false, UNIT_FIELD_RESISTANCES, "Sets shadow resistance."),
    F("arcane", UNIT_FIELD_RESISTANCES, 6, false, UNIT_FIELD_RESISTANCES, "Sets arcane resistance."),
    F("damage", UNIT_FIELD_MINDAMAGE, 0, true, UNIT_FIELD_MAXDAMAGE, "Sets the main hand's minimum and maximum damage."),
    F("ap", UNIT_FIELD_ATTACK_POWER, 0, false, UNIT_FIELD_ATTACK_POWER, "Sets attack power."),
    F("rangeap", UNIT_FIELD_RANGED_ATTACK_POWER, 0, false, UNIT_FIELD_RANGED_ATTACK_POWER, "Sets ranged attack power."),
    F("scale", OBJECT_FIELD_SCALE_X, 0, false, OBJECT_FIELD_SCALE_X, "Sets the model's scale."),
    F("nativedisplayid", UNIT_FIELD_NATIVEDISPLAYID, 0, false, UNIT_FIELD_NATIVEDISPLAYID, "Sets the native model."),
    F("displayid", UNIT_FIELD_DISPLAYID, 0, false, UNIT_FIELD_DISPLAYID, "Sets the model shown."),
    F("flags", UNIT_FIELD_FLAGS, 0, false, UNIT_FIELD_FLAGS, "Sets the unit flags."),
    F("faction", UNIT_FIELD_FACTIONTEMPLATE, 0, false, UNIT_FIELD_FACTIONTEMPLATE, "Sets the faction template."),
    F("dynamicflags", UNIT_DYNAMIC_FLAGS, 0, false, UNIT_DYNAMIC_FLAGS, "Sets the dynamic flags."),
    F("talentpoints", PLAYER_CHARACTER_POINTS1, 0, false, PLAYER_CHARACTER_POINTS1, "Sets the unspent talent points."),
    F("boundingradius", UNIT_FIELD_BOUNDINGRADIUS, 0, false, UNIT_FIELD_BOUNDINGRADIUS, "Sets the bounding radius."),
    F("combatreach", UNIT_FIELD_COMBATREACH, 0, false, UNIT_FIELD_COMBATREACH, "Sets the combat reach."),
    F("npcemotestate", UNIT_NPC_EMOTESTATE, 0, false, UNIT_NPC_EMOTESTATE, "Sets the looping emote."),
    F("bytes", UNIT_FIELD_BYTES_0, 0, false, UNIT_FIELD_BYTES_0, "Sets UNIT_FIELD_BYTES_0: race, class, gender, power."),
];

/// The method a `modifiableFields` row becomes: "hp" is `commandModifyHp`.
string modifyMethodName(string field) pure @safe
{
    import std.ascii : toUpper;

    return "commandModify" ~ cast(char) toUpper(field[0]) ~ field[1 .. $];
}

/// See the module documentation.
mixin template CharacterCommands()
{
    import std.algorithm.comparison : min;
    import std.array : array, join, replicate, split;
    import std.conv : to;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands : Command, readArguments;
    import dmangos.world.gmcharacter : modifiableFields, modifyMethodName;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.map : deliverPacket, packetBody;
    import dmangos.world.movement : MovementInfo, MoveType;
    import dmangos.world.objects : seenByOwner, seenBySelf;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : ItemRecord, PlayerFlags;
    import dmangos.world.updatefields;

private:
    // -----------------------------------------------------------------------
    // What the commands do to a session's player (on this session or another one)
    // -----------------------------------------------------------------------

    /// `Player::GiveLevel`: the new level's stats, `SMSG_LEVELUP_INFO`, and the group told.
    void applyLevel(uint level)
    {
        const info = player.changeLevel(level, context.data, context.client);
        send(info);
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.level | GroupUpdate.currentHealth | GroupUpdate.maxHealth
                | GroupUpdate.powerType);
    }

    /// `Unit::SetSpeedRate` for running and swimming (ArcEmu's `.modify speed`): forwards at `speed`,
    /// backwards at half of it. The player is told with forced changes, those around it with moves.
    void applySpeed(float speed)
    {
        player.speeds[MoveType.run] = speed;
        player.speeds[MoveType.swim] = speed;
        player.speeds[MoveType.runBack] = speed / 2;
        player.speeds[MoveType.swimBack] = speed / 2;
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed));
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed));
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_RUN_BACK_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed / 2));
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_SWIM_BACK_SPEED_CHANGE)(player.guid, moveOrderCounter++,
            speed / 2));
        if (!transferring)
            foreach (opcode, value; [Opcode.MSG_MOVE_SET_RUN_SPEED: speed, Opcode.MSG_MOVE_SET_SWIM_SPEED: speed,
                Opcode.MSG_MOVE_SET_RUN_BACK_SPEED: speed / 2, Opcode.MSG_MOVE_SET_SWIM_BACK_SPEED: speed / 2])
            {
                ByteWriter w;
                w.putPackedGuid(player.guid);
                MovementInfo now = player.movement;
                now.time = serverTime();
                now.write(w);
                w.put(value);
                map.sendToWatchers(this, opcode, w.data);
            }
        resetMovementCheck();
    }

    /// An order that only names the player: root, unroot, water walk, land walk.
    void sendMovementOrder(Opcode opcode)()
    {
        send(ServerMovementOrder!opcode(player.guid, moveOrderCounter++));
    }

    /// `Player::learnSpell` for a GM: the spellbook, `SMSG_LEARNED_SPELL`, and `character_spell`.
    bool learn(uint spell)
    {
        if (player.knowsSpell(spell) || context.data.spells.spell(spell) is null)
            return false;
        player.spells ~= spell;
        send(ServerLearnedSpell(spell));
        context.database.saveSpell(player.data.guid, spell, true);
        return true;
    }

    /// `Player::removeSpell`. A spell taught by default comes back at the next login, as in CMaNGOS.
    bool unlearn(uint spell)
    {
        import std.algorithm.mutation : remove;

        if (!player.knowsSpell(spell))
            return false;
        player.spells = player.spells.remove!(id => id == spell);
        send(ServerRemovedSpell(cast(ushort) spell));
        context.database.saveSpell(player.data.guid, spell, false);
        return true;
    }

    /// `Player::SetSkill` and its row; a maximum of 0 removes the skill.
    bool applySkill(uint skill, ushort value, ushort maximum)
    {
        if (!player.setSkill(skill, value, maximum))
            return false;
        flushPlayerChanges();
        context.database.saveSkill(player.data.guid, skill, value, maximum);
        return true;
    }

    /**
     * `Player::StoreNewItemInInventorySlot` for a GM: `count` of `entry`, first onto the stacks the
     * player carries, then into free slots. Returns how many were given; `why` says why not all.
     */
    uint giveItem(uint entry, uint count, out string why)
    {
        const template_ = entry in context.data.items;
        if (template_ is null)
        {
            why = format!"Item %s does not exist."(entry);
            return 0;
        }
        if (template_.maxCount > 0 && player.itemCount(entry) + count > template_.maxCount)
        {
            why = "You can't carry any more of those.";
            count = player.itemCount(entry) >= template_.maxCount ? 0 : template_.maxCount - player.itemCount(entry);
        }
        const stack = template_.stackable ? template_.stackable : 1;
        uint given;

        // Onto the stacks carried.
        foreach (ref item; player.items)
        {
            if (given == count)
                break;
            const has = item.values[ITEM_FIELD_STACK_COUNT];
            if (item.template_.entry != entry || has >= stack || player.inBank(item))
                continue;
            const added = min(stack - has, count - given);
            item.values.set!ITEM_FIELD_STACK_COUNT(has + added);
            context.database.updateItem(item.guid, has + added, item.values[ITEM_FIELD_DURABILITY]);
            UpdateData change;
            change.addValues(item.fullGuid, item.values, seenBySelf | seenByOwner);
            item.values.clearChanges();
            sendUpdate(change);
            send(ServerItemPushResult(player.guid, 0, 1, 1, bagSlotOfItem(item.bag), uint.max, entry, 0, 0, added));
            given += added;
        }

        // New stacks in free slots.
        while (given < count)
        {
            uint bag;
            ubyte slot;
            if (!player.freeSlot(*template_, bag, slot))
            {
                why = "Your inventory is full.";
                break;
            }
            const amount = min(stack, count - given);
            ItemRecord record;
            record.bag = bag;
            record.slot = slot;
            record.guid = context.nextItemGuid();
            record.entry = entry;
            record.count = amount;
            record.duration = template_.duration;
            foreach (charges; template_.spellCharges)
                record.charges ~= charges.to!string ~ " ";
            // Bound when picked up, or a quest item (BIND_WHEN_PICKED_UP, BIND_QUEST_ITEM): ITEM_DYNFLAG_BINDED.
            record.flags = template_.bonding == 1 || template_.bonding == 4 ? 1 : 0;
            record.enchantments = "0 ".replicate(21);
            record.durability = template_.maxDurability;
            if (const problem = player.addItem(record, context.data))
            {
                warning!"'%s': item %s not given: %s"(player.data.name, entry, problem);
                break;
            }
            context.database.insertItem(player.data.guid, record);
            const created = player.createItemForSelf(record.guid);
            sendUpdate(created);
            flushPlayerChanges(); // the slot now points at the item
            send(ServerItemPushResult(player.guid, 0, 1, 1, bagSlotOfItem(bag), slot, entry, 0, 0, amount));
            given += amount;
        }
        return given;
    }

    /// `Player::DestroyItemCount`: takes up to `count` of `entry` away, last stacks first. Returns how many.
    uint takeItem(uint entry, uint count)
    {
        uint taken;
        for (size_t i = player.items.length; i-- > 0 && taken < count;)
        {
            auto item = &player.items[i];
            if (item.template_.entry != entry || player.inBank(*item))
                continue;
            const has = item.values[ITEM_FIELD_STACK_COUNT];
            if (has > count - taken)
            {
                const left = has - (count - taken);
                item.values.set!ITEM_FIELD_STACK_COUNT(left);
                context.database.updateItem(item.guid, left, item.values[ITEM_FIELD_DURABILITY]);
                UpdateData change;
                change.addValues(item.fullGuid, item.values, seenBySelf | seenByOwner);
                item.values.clearChanges();
                sendUpdate(change);
                taken = count;
            }
            else
            {
                const itemGuid = item.guid, fullGuid = item.fullGuid;
                taken += has;
                player.removeItem(itemGuid);
                context.database.deleteItem(itemGuid);
                flushPlayerChanges();
                deliverPacket(this, ServerDestroyObject(fullGuid));
            }
        }
        return taken;
    }

    /// The `SMSG_ITEM_PUSH_RESULT` bag slot of an item in the bag `bag` (a low guid, 0 for none).
    ubyte bagSlotOfItem(uint bag)
    {
        if (bag == 0)
            return 255; // INVENTORY_SLOT_BAG_0
        foreach (ref item; player.items)
            if (item.guid == bag)
                return item.slot;
        return 255;
    }

    // -----------------------------------------------------------------------
    // .modify
    // -----------------------------------------------------------------------

    /// One `.modify` row: parses the value as the field's type and sets it on the selected player.
    bool modifyField(alias row)(string args)
    {
        auto target = selectedOrSelf();
        import std.traits : Unqual;

        alias T = Unqual!(typeof(target.player.values.get!(row.field)(row.index)));
        T value;
        if (!readArguments!1(args, value))
            return false;
        target.player.values.set!(row.field)(row.index, value);
        static if (row.alsoMaximum)
            target.player.values.set!(row.maximum)(row.index, value);
        target.flushPlayerChanges();
        tellBoth(target, format!"You changed %s of %s to %s."(row.name, target.player.data.name, value),
            format!"%s changed your %s to %s."(player.data.name, row.name, value));
        return true;
    }

    static foreach (i, row; modifiableFields)
        mixin(`@Command("modify ` ~ row.name ~ `", AccountLevel.gameMaster, "value", "` ~ row.help
            ~ (row.name == "npcemotestate" ? `", ["modify emotestate"])` : `")`)
            ~ ` bool ` ~ modifyMethodName(row.name) ~ `(string args) { return modifyField!(modifiableFields[` ~ i.stringof
            ~ `])(args); }`);

    @Command("modify level", AccountLevel.gameMaster, "level", "Sets the level of the selected player.")
    bool commandModifyLevel(string args)
    {
        uint level;
        if (!readArguments!1(args, level) || level < 1 || level > 255)
            return false;
        auto target = selectedOrSelf();
        target.applyLevel(level);
        tellBoth(target, format!"You set %s's level to %s."(target.player.data.name, level),
            format!"%s set your level to %s."(player.data.name, level));
        return true;
    }

    @Command("modify gold", AccountLevel.gameMaster, "copper", "Gives (or with a minus, takes) money, in copper.",
        ["modify money"])
    bool commandModifyGold(string args)
    {
        long copper;
        if (!readArguments!1(args, copper))
            return false;
        auto target = selectedOrSelf();
        const have = long(target.player.values.get!PLAYER_FIELD_COINAGE);
        const now = cast(uint) (have + copper < 0 ? 0 : have + copper > uint.max ? uint.max : have + copper);
        target.player.values.set!PLAYER_FIELD_COINAGE(now);
        target.flushPlayerChanges();
        target.savePlayer();
        tellBoth(target, format!"%s now has %s copper."(target.player.data.name, now),
            format!"%s changed your money to %s copper."(player.data.name, now));
        return true;
    }

    @Command("modify speed", AccountLevel.gameMaster, "yards per second", "Sets the running and swimming speed (7 is normal).")
    bool commandModifySpeed(string args)
    {
        float speed;
        if (!readArguments!1(args, speed) || speed < 1 || speed > 255)
            return false;
        auto target = selectedOrSelf();
        target.applySpeed(speed);
        tellBoth(target, format!"You set %s's speed to %s."(target.player.data.name, speed),
            format!"%s set your speed to %s."(player.data.name, speed));
        return true;
    }

    @Command("modify gender", AccountLevel.gameMaster, "0|1", "Changes the selected player's gender (0 male, 1 female), until the next login.")
    bool commandModifyGender(string args)
    {
        uint gender;
        if (!readArguments!1(args, gender) || gender > 1)
            return false;
        auto target = selectedOrSelf();
        auto p = target.player;
        const race = context.client.races.lookup(p.data.race);
        p.data.gender = cast(ubyte) gender;
        p.values.setByte!UNIT_FIELD_BYTES_0(2, cast(ubyte) gender);
        p.values.setHalf!PLAYER_BYTES_3(0, cast(ushort) gender);
        if (race !is null)
        {
            const display = gender ? race.femaleDisplayId : race.maleDisplayId;
            p.values.set!UNIT_FIELD_DISPLAYID(display);
            p.values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        }
        target.flushPlayerChanges();
        sendSystemMessage(format!"%s is now %s."(p.data.name, gender ? "female" : "male"));
        return true;
    }

    // -----------------------------------------------------------------------
    // Level, looks
    // -----------------------------------------------------------------------

    @Command("levelup", AccountLevel.gameMaster, "[levels]", "Raises the selected player's level, by one or by levels.")
    bool commandLevelUp(string args)
    {
        uint levels = 1;
        if (!readArguments!0(args, levels))
            return false;
        auto target = selectedOrSelf();
        const level = min(target.player.data.level + levels, 255u);
        target.applyLevel(level);
        tellBoth(target, format!"%s is now level %s."(target.player.data.name, level),
            format!"%s raised your level to %s."(player.data.name, level));
        return true;
    }

    @Command("demorph", AccountLevel.gameMaster, "", "Gives the selected player its own model back.")
    bool commandDemorph(string)
    {
        auto target = selectedOrSelf();
        target.player.values.set!UNIT_FIELD_DISPLAYID(target.player.values.get!UNIT_FIELD_NATIVEDISPLAYID);
        target.flushPlayerChanges();
        return true;
    }

    @Command("mount", AccountLevel.gameMaster, "display id", "Mounts the selected player on a creature model (the look only).")
    bool commandMount(string args)
    {
        enum uint unitFlagMount = 0x08000000; // UNIT_FLAG_MOUNT
        uint display;
        if (!readArguments!1(args, display))
            return false;
        auto target = selectedOrSelf();
        target.player.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
        target.player.values.set!UNIT_FIELD_FLAGS(target.player.values.get!UNIT_FIELD_FLAGS | unitFlagMount);
        target.flushPlayerChanges();
        return true;
    }

    @Command("dismount", AccountLevel.moderator, "", "Takes the selected player off its mount.")
    bool commandDismount(string)
    {
        enum uint unitFlagMount = 0x08000000;
        auto target = selectedOrSelf();
        if (target.player.values.get!UNIT_FIELD_MOUNTDISPLAYID == 0)
        {
            sendSystemMessage(format!"%s is not mounted."(target.player.data.name));
            return true;
        }
        target.player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        target.player.values.set!UNIT_FIELD_FLAGS(target.player.values.get!UNIT_FIELD_FLAGS & ~unitFlagMount);
        target.flushPlayerChanges();
        return true;
    }

    @Command("playerinfo", AccountLevel.moderator, "[name]", "Shows who a player, or the selected one, is: account, level, place, time played.")
    bool commandPlayerInfo(string args)
    {
        auto found = args.length ? context.onlinePlayer(args.split[0]) : selectedOrSelf();
        if (found is null)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(args));
            return true;
        }
        auto target = sessionOf(found);
        const p = target.player;
        const race = context.client.races.lookup(p.data.race), class_ = context.client.classes.lookup(p.data.classId);
        sendSystemMessage(format!"%s (guid %s): level %s %s %s, account %s (id %s, level %s), from %s, latency %s ms"(
            p.data.name, p.data.guid, p.data.level, race is null ? "?" : race.name[0], class_ is null ? "?" : class_.name[0],
            target.account.username, target.account.id, target.account.level, target.address, target.latencyMs));
        const played = p.progress(target.secondsInWorld()).totalTime;
        sendSystemMessage(format!"Map %s, zone %s; %s copper; played %sh %sm%s%s"(p.data.map, p.data.zone,
            p.values.get!PLAYER_FIELD_COINAGE, played / 3600, played / 60 % 60, target.gameMaster ? "; GM mode" : "",
            p.hasFlag(PlayerFlags.afk) ? "; AFK" : p.hasFlag(PlayerFlags.dnd) ? "; DND" : ""));
        return true;
    }

    // -----------------------------------------------------------------------
    // Spells and skills (the character group)
    // -----------------------------------------------------------------------

    @Command("character learn", AccountLevel.gameMaster, "spell", "Teaches the selected player a spell.", ["learn"])
    bool commandLearn(string args)
    {
        uint spell;
        if (!readArguments!1(args, spell))
            return false;
        auto target = selectedOrSelf();
        if (context.data.spells.spell(spell) is null)
            sendSystemMessage(format!"Spell %s does not exist."(spell));
        else if (!target.learn(spell))
            sendSystemMessage(format!"%s already knows that spell."(target.player.data.name));
        else
            tellBoth(target, format!"%s learned spell %s."(target.player.data.name, spell), "");
        return true;
    }

    @Command("character unlearn", AccountLevel.gameMaster, "spell", "Makes the selected player forget a spell.", ["unlearn"])
    bool commandUnlearn(string args)
    {
        uint spell;
        if (!readArguments!1(args, spell))
            return false;
        auto target = selectedOrSelf();
        if (!target.unlearn(spell))
            sendSystemMessage(format!"%s does not know that spell."(target.player.data.name));
        else
            sendSystemMessage(format!"%s forgot spell %s."(target.player.data.name, spell));
        return true;
    }

    @Command("character learnskill", AccountLevel.gameMaster, "skill [value] [max]", "Gives the selected player a skill.",
        ["learnskill"])
    bool commandLearnSkill(string args)
    {
        uint skill, value = 1, maximum = 0;
        if (!readArguments!1(args, skill, value, maximum))
            return false;
        if (context.client.skillLines.lookup(skill) is null || skill > ushort.max)
        {
            sendSystemMessage(format!"Skill %s does not exist."(skill));
            return true;
        }
        if (maximum == 0)
            maximum = value > 300 ? value : 300;
        auto target = selectedOrSelf();
        if (!target.applySkill(skill, cast(ushort) min(value, maximum), cast(ushort) maximum))
            sendSystemMessage("No free skill slot.");
        else
            sendSystemMessage(format!"%s now has skill %s at %s/%s."(target.player.data.name, skill, min(value, maximum),
                maximum));
        return true;
    }

    @Command("character advanceskill", AccountLevel.gameMaster, "skill [points]", "Raises one of the selected player's skills.",
        ["advanceskill"])
    bool commandAdvanceSkill(string args)
    {
        uint skill, points = 1;
        if (!readArguments!1(args, skill, points))
            return false;
        auto target = selectedOrSelf();
        const now = target.player.skillValue(skill);
        if (now[1] == 0)
        {
            sendSystemMessage(format!"%s does not have skill %s."(target.player.data.name, skill));
            return true;
        }
        const value = cast(ushort) min(now[0] + points, now[1]);
        target.applySkill(skill, value, now[1]);
        sendSystemMessage(format!"%s's skill %s is now %s/%s."(target.player.data.name, skill, value, now[1]));
        return true;
    }

    @Command("character advanceallskills", AccountLevel.gameMaster, "[points]", "Raises every skill of the selected player.",
        ["advanceallskills"])
    bool commandAdvanceAllSkills(string args)
    {
        uint points = 1;
        if (!readArguments!0(args, points))
            return false;
        auto target = selectedOrSelf();
        foreach (skill; target.player.skillList)
            target.applySkill(skill[0], cast(ushort) min(skill[1] + points, skill[2]), cast(ushort) skill[2]);
        sendSystemMessage(format!"Every skill of %s raised by %s."(target.player.data.name, points));
        return true;
    }

    @Command("character removeskill", AccountLevel.gameMaster, "skill", "Takes a skill away from the selected player.",
        ["removeskill"])
    bool commandRemoveSkill(string args)
    {
        uint skill;
        if (!readArguments!1(args, skill))
            return false;
        auto target = selectedOrSelf();
        if (target.player.skillValue(skill)[1] == 0)
            sendSystemMessage(format!"%s does not have skill %s."(target.player.data.name, skill));
        else
        {
            target.applySkill(skill, 0, 0);
            sendSystemMessage(format!"Skill %s removed from %s."(skill, target.player.data.name));
        }
        return true;
    }

    @Command("character getskillinfo", AccountLevel.moderator, "", "Lists the selected player's skills.",
        ["getskillinfo", "character showskills"])
    bool commandGetSkillInfo(string)
    {
        auto target = selectedOrSelf();
        string[] lines;
        foreach (skill; target.player.skillList)
        {
            const line = context.client.skillLines.lookup(skill[0]);
            lines ~= format!"%s (%s) %s/%s"(line is null ? "?" : line.name[0], skill[0], skill[1], skill[2]);
        }
        sendSystemMessage(format!"%s has %s skills:"(target.player.data.name, lines.length));
        for (size_t i = 0; i < lines.length; i += 6)
            sendSystemMessage(lines[i .. min(i + 6, lines.length)].join(", "));
        return true;
    }

    @Command("getskilllevel", AccountLevel.moderator, "skill", "Shows the selected player's value in a skill.")
    bool commandGetSkillLevel(string args)
    {
        uint skill;
        if (!readArguments!1(args, skill))
            return false;
        auto target = selectedOrSelf();
        const value = target.player.skillValue(skill);
        sendSystemMessage(format!"%s's skill %s: %s/%s"(target.player.data.name, skill, value[0], value[1]));
        return true;
    }

    // -----------------------------------------------------------------------
    // Items
    // -----------------------------------------------------------------------

    @Command("character additem", AccountLevel.gameMaster, "item [count]", "Gives the selected player items.", ["additem"])
    bool commandAddItem(string args)
    {
        uint entry, count = 1;
        if (!readArguments!1(args, entry, count) || count == 0)
            return false;
        auto target = selectedOrSelf();
        string why;
        const given = target.giveItem(entry, count, why);
        const item = entry in context.data.items;
        if (given)
            sendSystemMessage(format!"Gave %s x %s (%s) to %s."(given, item.details.name, entry, target.player.data.name));
        if (why.length)
            sendSystemMessage(why);
        return true;
    }

    @Command("character additemset", AccountLevel.gameMaster, "set", "Gives the selected player every item of an item set.",
        ["additemset"])
    bool commandAddItemSet(string args)
    {
        uint set;
        if (!readArguments!1(args, set) || set == 0)
            return false;
        auto target = selectedOrSelf();
        uint[] entries;
        foreach (entry, ref item; context.data.items)
            if (item.details.itemSet == set)
                entries ~= entry;
        if (entries.length == 0)
        {
            sendSystemMessage(format!"Item set %s does not exist."(set));
            return true;
        }
        foreach (entry; entries)
        {
            string why;
            if (target.giveItem(entry, 1, why) == 0)
            {
                sendSystemMessage(why);
                break;
            }
        }
        sendSystemMessage(format!"Gave item set %s (%s items) to %s."(set, entries.length, target.player.data.name));
        return true;
    }

    @Command("character removeitem", AccountLevel.gameMaster, "item [count]", "Takes items away from the selected player.",
        ["removeitem"])
    bool commandRemoveItem(string args)
    {
        uint entry, count = 1;
        if (!readArguments!1(args, entry, count))
            return false;
        auto target = selectedOrSelf();
        const taken = target.takeItem(entry, count);
        sendSystemMessage(format!"Took %s of item %s from %s."(taken, entry, target.player.data.name));
        return true;
    }

    @Command("character showitems", AccountLevel.moderator, "", "Lists the selected player's items.", ["showitems"])
    bool commandShowItems(string)
    {
        auto target = selectedOrSelf();
        sendSystemMessage(format!"%s has %s items:"(target.player.data.name, target.player.items.length));
        foreach (ref item; target.player.items)
            sendSystemMessage(format!"%s x %s (%s) in %s slot %s"(item.values[ITEM_FIELD_STACK_COUNT],
                item.template_.details.name, item.template_.entry, item.bag ? format!"bag %s"(item.bag) : "inventory",
                item.slot));
        return true;
    }

    @Command("character repairitems", AccountLevel.gameMaster, "", "Repairs every item of the selected player.",
        ["repairitems"])
    bool commandRepairItems(string)
    {
        auto target = selectedOrSelf();
        size_t repaired;
        foreach (ref item; target.player.items)
        {
            const maximum = item.values[ITEM_FIELD_MAXDURABILITY];
            if (item.values[ITEM_FIELD_DURABILITY] == maximum)
                continue;
            item.values.set!ITEM_FIELD_DURABILITY(maximum);
            context.database.updateItem(item.guid, item.values[ITEM_FIELD_STACK_COUNT], maximum);
            UpdateData change;
            change.addValues(item.fullGuid, item.values, seenBySelf | seenByOwner);
            item.values.clearChanges();
            target.sendUpdate(change);
            ++repaired;
        }
        tellBoth(target, format!"Repaired %s items of %s."(repaired, target.player.data.name),
            format!"%s repaired your items."(player.data.name));
        return true;
    }

    @Command("character rename", AccountLevel.gameMaster, "name new-name", "Renames a character that is not online.",
        ["renamechar"])
    bool commandRename(string args)
    {
        import dmangos.world.names : checkPlayerName, CharNameResult, normalizePlayerName;
        import dmangos.world.worlddata : toLowerName;

        string from, to;
        if (!readArguments!2(args, from, to) || !normalizePlayerName(from) || !normalizePlayerName(to))
            return false;
        if (context.onlinePlayer(from) !is null)
        {
            sendSystemMessage(format!"%s is online; rename when the character is offline."(from));
            return true;
        }
        const guid = context.database.characterGuid(from);
        if (guid == 0)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(from));
            return true;
        }
        if (context.database.nameTaken(to) || toLowerName(to) in context.data.reservedNames)
        {
            sendSystemMessage(format!"The name %s is taken."(to));
            return true;
        }
        context.database.renameCharacter(guid, to);
        sendSystemMessage(format!"%s is now called %s."(from, to));
        return true;
    }

    // -----------------------------------------------------------------------
    // Cheats (the ones that mean something without combat)
    // -----------------------------------------------------------------------

    @Command("cheat explore", AccountLevel.gameMaster, "", "Reveals the whole map to the selected player.")
    bool commandCheatExplore(string)
    {
        auto target = selectedOrSelf();
        target.player.exploreAll();
        target.flushPlayerChanges();
        target.savePlayer();
        tellBoth(target, format!"%s has explored everything."(target.player.data.name),
            format!"%s has revealed the map to you."(player.data.name));
        return true;
    }

    @Command("cheat triggerpass", AccountLevel.gameMaster, "", "Lets the selected player through area triggers regardless of their requirements.")
    bool commandCheatTriggerPass(string)
    {
        auto target = selectedOrSelf();
        target.ignoreTriggerRequirements = !target.ignoreTriggerRequirements;
        sendSystemMessage(format!"Area trigger requirements %s for %s."(target.ignoreTriggerRequirements ? "ignored"
            : "apply again", target.player.data.name));
        return true;
    }

    @Command("cheat status", AccountLevel.gameMaster, "", "Shows the selected player's cheats.")
    bool commandCheatStatus(string)
    {
        auto target = selectedOrSelf();
        sendSystemMessage(format!"%s: trigger pass %s, speed %s, GM mode %s"(target.player.data.name,
            target.ignoreTriggerRequirements ? "on" : "off", target.player.speeds[MoveType.run],
            target.gameMaster ? "on" : "off"));
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : count;
    import dmangos.world.testclient;
}

/// `.modify`, `.levelup`, money and speed, on oneself and on the selected player.
unittest
{
    import dmangos.world.movement : MoveType;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0));
    gm.read();
    jaina.read();

    gm.say(".modify hp 500");
    const me = gm.session.character;
    assert(me.values[UNIT_FIELD_HEALTH] == 500 && me.values[UNIT_FIELD_MAXHEALTH] == 500);
    assert(systemMessages(gm.read()) == ["You changed hp of Anduin to 500."]);
    gm.say(".modify scale 2.5");
    assert(me.values.get!OBJECT_FIELD_SCALE_X == 2.5f);
    gm.say(".modify scale big");
    assert(systemMessages(gm.read())[$ - 1] == "Syntax: .modify scale value");

    // Jaina selected: the commands act on her, and she is told.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientSetSelection(8));
    gm.read();
    jaina.read();
    gm.say(".levelup 4");
    const her = jaina.session.character;
    assert(her.data.level == 5 && her.values[UNIT_FIELD_LEVEL] == 5);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_LEVELUP_INFO));
    gm.say(".modify gold 12345");
    assert(her.values[PLAYER_FIELD_COINAGE] == 12345 && db.progressSaves[$ - 1].money == 12345
        && db.progressSaves[$ - 1].level == 5, "money and level are saved");
    gm.say(".modify speed 14");
    assert(her.speeds[MoveType.run] == 14 && her.speeds[MoveType.runBack] == 7);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE));
    assert(opcodesOf(gm.read()).canFind(Opcode.MSG_MOVE_SET_RUN_SPEED), "those around see the new speed");
}

/// Items, spells, skills, explored zones and renaming.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    gm.read();
    const me = gm.session.character;

    // Jerky stacks by 20: 25 make two stacks in the backpack, then 22 are taken back.
    gm.say(".additem 117 25");
    const given = gm.read();
    assert(opcodesOf(given).count(Opcode.SMSG_ITEM_PUSH_RESULT) == 2 && me.itemCount(itemJerky) == 25);
    assert(db.itemRows.length == 2 && db.itemOwners.values == [7u, 7u]);
    assert(me.values.get!PLAYER_FIELD_INV_SLOT_HEAD(23) != 0 && me.values.get!PLAYER_FIELD_INV_SLOT_HEAD(24) != 0);
    gm.say(".additem 117 3");
    assert(me.itemCount(itemJerky) == 28 && db.itemRows.length == 2, "onto the second stack");
    gm.say(".removeitem 117 22");
    assert(me.itemCount(itemJerky) == 6 && db.itemRows.length == 1);
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_DESTROY_OBJECT));
    gm.say(".additem 999999");
    assert(systemMessages(gm.read()) == ["Item 999999 does not exist."]);

    // Spells and skills, saved.
    gm.say(".learn " ~ spellFireball.stringof[0 .. $ - 1]);
    assert(me.knowsSpell(spellFireball) && spellFireball in db.spellRows[7]);
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_LEARNED_SPELL));
    gm.say(".unlearn " ~ spellFireball.stringof[0 .. $ - 1]);
    assert(!me.knowsSpell(spellFireball) && spellFireball !in db.spellRows[7]);
    gm.say(".character learnskill " ~ skillBows.stringof[0 .. $ - 1] ~ " 10 75");
    assert(me.skillValue(skillBows) == [10, 75] && db.skillRows[7][skillBows] == [10, 75]);
    gm.say(".advanceskill " ~ skillBows.stringof[0 .. $ - 1] ~ " 100");
    assert(me.skillValue(skillBows) == [75, 75]);
    gm.say(".removeskill " ~ skillBows.stringof[0 .. $ - 1]);
    assert(me.skillValue(skillBows) == [0, 0] && skillBows !in db.skillRows[7]);

    // The map revealed, and saved.
    gm.say(".cheat explore");
    assert(db.progressSaves[$ - 1].exploredZones[0 .. 11] == "4294967295 ");

    // Renaming works on characters that are offline.
    db.loadable[50] = db.loadable[7];
    db.loadable[50].guid = 50;
    db.loadable[50].name = "Varian";
    gm.read();
    gm.say(".character rename anduin Llane");
    assert(systemMessages(gm.read())[0].canFind("online"));
    gm.say(".character rename varian Llane");
    assert(db.loadable[50].name == "Llane");
}
