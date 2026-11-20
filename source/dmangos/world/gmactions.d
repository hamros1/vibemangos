/**
 * What the GM command handlers do to players, shared by the handler groups
 * (`gmlevel0` .. `gmlevel3`, `gmdebug`, `gmrecall`): levels, speeds, spells,
 * skills, items, saving, teleports, and messages to everyone. Mixed into
 * `dmangos.world.character.Character`; a handler calls them on the session of
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
    /// The player at `level`: the new level's stats, `SMSG_LEVELUP_INFO`, and the group told.
    void applyLevel(uint level)
    {
        const changed = level != player.data.level;
        const info = player.changeLevel(level, context.data, context.client);
        if (changed)
            player.restartLevelTime(secondsInWorld()); // the time played at this level starts again
        send(info);
        if (changed)
            levelRewardLetter(level);
        flushPlayerChanges();
        petOwnerLevelChanged();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.level | GroupUpdate.currentHealth | GroupUpdate.maxHealth
                | GroupUpdate.powerType);
    }

    /**
     * At a new level, the letter `mail_level_reward` has for it and the player's race (`Player::GiveLevel`). Only
     * a template the client knows is sent (`ObjectMgr::LoadMailLevelRewards` drops the others): the rows of the
     * classic database are TBC's riding letters, which a 1.12 client has no template for.
     */
    void levelRewardLetter(uint level)
    {
        const raceMask = 1u << (player.data.race - 1);
        foreach (ref m; context.data.levelRewardMails.get(level, null))
            if ((m.raceMask & raceMask) && context.client.mailTemplates.lookup(m.mailTemplate) !is null)
            {
                context.templateLetter(m.mailTemplate, m.sender, player.data.guid);
                break; // one letter a level (`GetMailLevelReward`)
            }
    }

    /// `.modify speed`: the run, swim and run-back speeds; the player is told with
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

    /// A spell learned by a GM's command: the spellbook, `SMSG_LEARNED_SPELL`, and `character_spell`.
    package bool learn(uint spell)
    {
        if (player.knowsSpell(spell) || context.data.spells.spell(spell) is null)
            return false;
        player.spells ~= spell;
        send(ServerLearnedSpell(spell));
        context.database.saveSpell(player.data.guid, spell, true, false);
        player.recordSpellRow(NewSpell(spell, true, false));
        // A primary profession takes one of the free slots, while there is one (`Player::learnSpell`).
        const free = player.values.get!PLAYER_CHARACTER_POINTS2;
        if (free && isPrimaryProfessionFirstRank(spell))
            player.values.set!PLAYER_CHARACTER_POINTS2(free - 1);
        return true;
    }

    /// A spell forgotten. A spell taught by default comes back at the next login.
    bool unlearn(uint spell)
    {
        import std.algorithm.mutation : remove;

        if (!player.knowsSpell(spell))
            return false;
        player.spells = player.spells.remove!(id => id == spell);
        send(ServerRemovedSpell(cast(ushort) spell));
        context.database.deleteSpell(player.data.guid, spell);
        player.forgetSpellRow(spell);
        // A primary profession forgotten gives its slot back, up to the most (`Player::removeSpell`).
        if (isPrimaryProfessionFirstRank(spell))
        {
            const settings = context.creationSettings;
            const most = cast(uint) account.level < settings.gmIgnoreMaxPrimarySkills ? settings.maxPrimaryTradeSkill : 10;
            const free = player.values.get!PLAYER_CHARACTER_POINTS2 + 1;
            if (free <= most)
                player.values.set!PLAYER_CHARACTER_POINTS2(free);
        }
        return true;
    }

    /// A skill's value and maximum set, and its row saved; a maximum of 0 removes the skill.
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
     * An item given: `count` of `entry` carried, onto stacks first, then into free slots; as many as the item's
     * limit and the room allow. Returns how many were given. The client's line (`SMSG_ITEM_PUSH_RESULT`) is a
     * GM's gift by default ("You create"); a quest's item is `received` and not `created`, a spell's both.
     */
    package uint giveItem(uint entry, uint count, bool received = false, bool created = true, bool showInChat = true)
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
        sendNewItem(item, count, received, created, showInChat);
        flushInventory();
        return count;
    }

    /// Takes up to `count` of `entry` away, the backpack first. Returns how many.
    uint takeItem(uint entry, uint count)
    {
        const left = player.inventory.destroyCount(entry, count);
        flushInventory();
        return count - left;
    }

    /// The player saved, as far as this server saves.
    void savePlayer()
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        saveAuras();
        saveCooldowns();
        saveQuests();
        saveReputation();
        saveHonor();
        saveBattleground();
        saveEnchantmentTimes();
        saveItemDurations();
        saveTimer.reset();
    }

    /// A system message to everyone in the world.
    void sendWorldText(string text)
    {
        toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text));
    }

    /// A system message to everyone with the `u` permission.
    void sendGMWorldText(string text)
    {
        context.toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            text), 'u');
    }

    /// `SMSG_AREA_TRIGGER_MESSAGE` to everyone, in the middle of the screen.
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
