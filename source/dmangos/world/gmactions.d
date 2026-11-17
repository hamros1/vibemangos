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
    import dmangos.bytes : ByteWriter;
    import dmangos.log;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : MovementInfo, MoveType;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.playercreate : NewSkill, NewSpell;
    import dmangos.world.queries : chatMessage;
    import dmangos.world.updatefields;

private:
    /// `Player::GiveLevel`: the new level's stats, `SMSG_LEVELUP_INFO`, and the group told.
    void applyLevel(uint level)
    {
        const changed = level != player.data.level;
        const info = player.changeLevel(level, context.data, context.client);
        if (changed)
            player.restartLevelTime(secondsInWorld()); // `m_Played_time[PLAYED_TIME_LEVEL] = 0`
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
        context.database.saveSpell(player.data.guid, spell, true, false);
        player.recordSpellRow(NewSpell(spell, true, false));
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
        context.database.deleteSpell(player.data.guid, spell);
        player.forgetSpellRow(spell);
        return true;
    }

    /// `Player::SetSkill` and its row; a maximum of 0 removes the skill.
    bool applySkill(uint skill, ushort value, ushort maximum)
    {
        if (!player.setSkill(skill, value, maximum))
            return false;
        flushPlayerChanges();
        context.database.saveSkill(player.data.guid, skill, value, maximum);
        player.recordSkillRow(NewSkill(skill, value, maximum));
        return true;
    }

    /**
     * CMaNGOS's `.additem`: `count` of `entry` carried, onto stacks first, then into free slots; as
     * many as the item's limit and the room allow. Returns how many were given.
     */
    uint giveItem(uint entry, uint count)
    {
        import dmangos.world.inventory : InventoryResult, ItemPosCount;
        import dmangos.world.defines : nullBag, nullSlot;

        ItemPosCount[] dest;
        uint noSpace;
        if (player.inventory.canStoreNew(nullBag, nullSlot, dest, entry, count, &noSpace) != InventoryResult.ok)
            count -= noSpace; // what fits is still placed in `dest`
        if (count == 0 || dest.length == 0)
            return 0;
        auto item = player.inventory.storeNew(dest, entry);
        if (item is null)
            return 0;
        sendNewItem(item, count, false, true);
        flushInventory();
        return count;
    }

    /// `Player::DestroyItemCount`: takes up to `count` of `entry` away, the backpack first. Returns how many.
    uint takeItem(uint entry, uint count)
    {
        const left = player.inventory.destroyCount(entry, count);
        flushInventory();
        return count - left;
    }

    /// `Player::SaveToDB`, as far as this server saves.
    void savePlayer()
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        saveAuras();
        saveQuests();
        saveReputation();
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
        context.toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            text), 'u');
    }

    /// `World::SendWorldWideScreenText`: `SMSG_AREA_TRIGGER_MESSAGE` to everyone, in the middle of the screen.
    void sendWorldWideScreenText(string text)
    {
        toEveryone(Opcode.SMSG_AREA_TRIGGER_MESSAGE, packetBody(ServerAreaTriggerMessage(text)));
    }

    /// Sends a body to everyone in the world, on every node.
    void toEveryone(Opcode opcode, const(ubyte)[] body_)
    {
        context.toEveryone(opcode, body_);
    }
}
