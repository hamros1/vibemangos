/**
 * What the GM command handlers do to players, shared by the handler groups
 * (`gmlevel0` .. `gmlevel3`, `gmdebug`, `gmrecall`): levels, speeds, spells,
 * skills, items, saving, teleports, and messages to everyone. Mixed into
 * `dmangos.world.session.WorldSession`; a handler calls them on the session of
 * the player it acts on.
 */
module dmangos.world.gmactions;

/// See the module documentation.
mixin template GmActions()
{
    import std.algorithm.comparison : min;
    import std.array : replicate;
    import std.conv : to;
    import dmangos.bytes : ByteWriter;
    import dmangos.log;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.map : deliverPacket, packetBody;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.movement : MovementInfo, MoveType;
    import dmangos.world.objects : seenByOwner, seenBySelf, UpdateData;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : ItemRecord;
    import dmangos.world.queries : chatMessage;
    import dmangos.world.updatefields;

private:
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

    /// ArcEmu's `.modify speed` (`Player::SetPlayerSpeed` for RUN, SWIM and RUNBACK): the player is told with
    /// forced changes, those around it with moves. Swimming backwards keeps its speed.
    void applySpeed(float speed)
    {
        player.speeds[MoveType.run] = speed;
        player.speeds[MoveType.swim] = speed;
        player.speeds[MoveType.runBack] = speed;
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed));
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed));
        send(ServerForceSpeedChange!(Opcode.SMSG_FORCE_RUN_BACK_SPEED_CHANGE)(player.guid, moveOrderCounter++, speed));
        if (!transferring)
            foreach (opcode; [Opcode.MSG_MOVE_SET_RUN_SPEED, Opcode.MSG_MOVE_SET_SWIM_SPEED,
                Opcode.MSG_MOVE_SET_RUN_BACK_SPEED])
            {
                ByteWriter w;
                w.putPackedGuid(player.guid);
                MovementInfo now = player.movement;
                now.time = serverTime();
                now.write(w);
                w.put(speed);
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
     * player carries, then into free slots, as many as the item's maximum count and the free slots allow.
     * Returns how many were given.
     */
    uint giveItem(uint entry, uint count)
    {
        const template_ = entry in context.data.items;
        if (template_ is null)
            return 0;
        if (template_.maxCount > 0 && player.itemCount(entry) + count > template_.maxCount)
            count = player.itemCount(entry) >= template_.maxCount ? 0 : template_.maxCount - player.itemCount(entry);
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
                break;
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
            return inventorySlotBag0;
        foreach (ref item; player.items)
            if (item.guid == bag)
                return item.slot;
        return inventorySlotBag0;
    }

    /// `Player::SaveToDB`, as far as this server saves.
    void savePlayer()
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        saveTimer.reset();
    }

    /// `World::SendWorldText`: a system message to everyone in the world.
    void sendWorldText(string text)
    {
        toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text));
    }

    /// `World::SendGMWorldText`: a system message to everyone with the `u` permission.
    void sendGMWorldText(string text)
    {
        const body_ = chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text);
        foreach (other; context.onlinePlayers)
            if (other.canUseCommand('u'))
                other.deliver(Opcode.SMSG_MESSAGECHAT, body_);
    }

    /// `World::SendWorldWideScreenText`: `SMSG_AREA_TRIGGER_MESSAGE` to everyone, in the middle of the screen.
    void sendWorldWideScreenText(string text)
    {
        toEveryone(Opcode.SMSG_AREA_TRIGGER_MESSAGE, packetBody(ServerAreaTriggerMessage(text)));
    }

    /// Sends a body to everyone in the world.
    void toEveryone(Opcode opcode, const(ubyte)[] body_)
    {
        foreach (other; context.onlinePlayers)
            other.deliver(opcode, body_);
    }
}
