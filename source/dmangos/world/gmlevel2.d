/**
 * ArcEmu's `Level2.cpp` handlers that this server's systems support:
 * `.server saveall`, `.character repairitems`, `.demorph`, `.mount`,
 * `.invincible`, `.npc flags`, `.npc say` and `.npc yell`. Mixed into
 * `dmangos.world.session.WorldSession`.
 */
module dmangos.world.gmlevel2;

/// See the module documentation.
mixin template Level2Commands()
{
    import core.time : MonoTime;
    import std.format : format;
    import dmangos.world.commands;
    import dmangos.world.objects : seenByOwner, seenBySelf, UpdateData;
    import dmangos.world.opcodes;
    import dmangos.world.queries : chatMessage, monsterChatMessage;
    import dmangos.world.updatefields;

private:
    bool invincible; // `.invincible` (Player::bInvincible): nothing attacks yet, so nothing reads it

    bool handleSaveAllCommand()
    {
        const started = MonoTime.currTime;
        uint count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).savePlayer();
            ++count;
        }
        const message = format!"Saved all %d online players in %d msec."(count,
            (MonoTime.currTime - started).total!"msecs");
        sendWorldText(message);
        sendWorldWideScreenText(message);
        gmLog("saved all players");
        return true;
    }

    bool handleRepairItemsCommand()
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
            return false;
        foreach (ref item; plr.player.items) // RepairItem2: back to full durability
        {
            const maximum = item.values[ITEM_FIELD_MAXDURABILITY];
            if (item.values[ITEM_FIELD_DURABILITY] == maximum)
                continue;
            item.values.set!ITEM_FIELD_DURABILITY(maximum);
            context.database.updateItem(item.guid, item.values[ITEM_FIELD_STACK_COUNT], maximum);
            UpdateData change;
            change.addValues(item.fullGuid, item.values, seenBySelf | seenByOwner);
            item.values.clearChanges();
            plr.sendUpdate(change);
        }
        systemMessage("Items Repaired");
        return true;
    }

    bool handleDeMorphCommand()
    {
        auto target = getSelectedChar(true);
        if (target is null)
            target = this;
        auto values = &target.player.values; // Unit::DeMorph
        values.set!UNIT_FIELD_DISPLAYID(values.get!UNIT_FIELD_NATIVEDISPLAYID);
        target.flushPlayerChanges();
        return true;
    }

    bool handleMountCommand(uint modelId = 0)
    {
        if (modelId == 0)
        {
            redSystemMessage("No model specified");
            return true;
        }
        auto plr = getSelectedChar(false);
        auto creature = plr is null ? getSelectedCreature(false) : null;
        if (plr is null && creature is null)
        {
            redSystemMessage("No target found.");
            return true;
        }
        auto values = plr !is null ? &plr.player.values : &creature.values;
        if (values.get!UNIT_FIELD_MOUNTDISPLAYID != 0)
        {
            redSystemMessage("Target is already mounted.");
            return true;
        }
        values.set!UNIT_FIELD_MOUNTDISPLAYID(modelId);
        if (plr !is null)
            plr.flushPlayerChanges();
        else
            map.flushObjectChanges(creature);
        blueSystemMessage(format!"Now mounted with model %d."(modelId));
        gmLog(format!"used mount command to model %u"(modelId));
        return true;
    }

    bool handleInvincibleCommand()
    {
        auto chr = getSelectedChar(true);
        string message;
        if (chr !is null)
        {
            chr.invincible = !chr.invincible;
            message = "Invincibility is now " ~ (chr.invincible
                ? "ON. You may have to leave and re-enter this zone for changes to take effect."
                : "OFF. Exit and re-enter this zone for this change to take effect.");
        }
        else
            message = "Select a player or yourself first.";
        if (chr !is null && chr !is this)
            gmLog("toggled invincibility on " ~ chr.player.data.name);
        systemMessage(message.length > 99 ? message[0 .. 99] : message); // ArcEmu's 100-byte buffer
        return true;
    }

    bool handleNPCFlagCommand(uint flags)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        auto creature = getSelectedCreature(false);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        creature.values.set!UNIT_NPC_FLAGS(flags);
        map.flushObjectChanges(creature);
        // ArcEmu saves its spawn row; CMaNGOS keeps npc flags in creature_template, which stays as it is.
        systemMessage("Value saved, you may need to rejoin or clean your client cache.");
        gmLog(format!"changed npc flags of creature %u [%s] to %u"(creature.template_.entry, creature.template_.name,
            flags));
        return true;
    }

    /// `.npc say` and `.npc yell`: the selected creature (or player) says it.
    bool monsterChat(string text, bool yell)
    {
        if (auto creature = getSelectedCreature(false))
        {
            const range = yell ? context.config.listenRangeYell : context.config.listenRangeSay;
            const type = yell ? ChatType.CHAT_MSG_MONSTER_YELL : ChatType.CHAT_MSG_MONSTER_SAY;
            map.sendInRange(creature.position, range, Opcode.SMSG_MESSAGECHAT,
                monsterChatMessage(type, creature.guid, creature.template_.name, text));
            return true;
        }
        if (auto plr = getSelectedChar(false))
        {
            const body_ = chatMessage(yell ? ChatType.CHAT_MSG_YELL : ChatType.CHAT_MSG_SAY, Language.LANG_UNIVERSAL,
                plr.player.guid, text);
            plr.map.sendToWatchers(plr, Opcode.SMSG_MESSAGECHAT, body_, true);
            return true;
        }
        redSystemMessage("Please select a creature or player before using this command.");
        return true;
    }

    bool handleMonsterSayCommand(Rest text = Rest.init)
    {
        return monsterChat(text, false);
    }

    bool handleMonsterYellCommand(Rest text = Rest.init)
    {
        return monsterChat(text, true);
    }
}
