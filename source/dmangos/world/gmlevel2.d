/**
 * ArcEmu's `Level2.cpp` handlers that this server's systems support:
 * `.server saveall`, `.character repairitems`, `.demorph`, `.mount`,
 * `.invincible`, `.npc flags`, `.npc say` and `.npc yell`, `.kill`, `.killplr`, `.reviveplr`,
 * `.castspell`, `.castspellne` and `.castself`. Mixed into
 * `dmangos.world.session.WorldSession`.
 */
module dmangos.world.gmlevel2;

/// See the module documentation.
mixin template Level2Commands()
{
    import core.time : MonoTime;
    import std.format : format;
    import dmangos.world.commands;
    import dmangos.world.inventory : ItemState;
    import dmangos.world.opcodes;
    import dmangos.world.queries : chatMessage, monsterChatMessage;
    import dmangos.world.updatefields;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.player : DeathState;
    import dmangos.world.spells : SpellInfo;

    package bool invincible; // `.invincible` (Player::bInvincible): creatures do not attack it

private:

    bool handleSaveAllCommand()
    {
        const started = MonoTime.currTime;
        uint count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).savePlayer();
            ++count;
        }
        // Every other node of a cluster saves its own (counted by presence).
        if (gmEverywhere(GmRemoteOp.saveAll))
            count += cast(uint) context.remotePlayers.length;
        const message = format!"Saved all %d online players in %d msec."(count,
            (MonoTime.currTime - started).total!"msecs");
        sendWorldText(message);
        sendWorldWideScreenText(message);
        gmLog("saved all players");
        return true;
    }

    bool handleResetReputationCommand()
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
        {
            systemMessage("Select a player or yourself first.");
            return true;
        }
        if (plr.player.reputation !is null) // `_InitialReputation`: every standing back to its start
        {
            plr.player.reputation.initialize();
            plr.saveReputation();
        }
        systemMessage("Done. Relog for changes to take effect.");
        gmLog(format!"used reset reputation for %s"(plr.player.data.name));
        return true;
    }

    bool handleRepairItemsCommand()
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
            return false;
        foreach (item; plr.player.inventory.all()) // RepairItem2: back to full durability
        {
            if (item.durability == item.maxDurability)
                continue;
            if (item.durability == 0 && item.isEquipped)
                plr.player.inventory.equipmentChanged = true; // a broken worn item gives its stats again
            item.values.set!ITEM_FIELD_DURABILITY(item.maxDurability);
            plr.player.inventory.setState(item, ItemState.changed);
        }
        plr.flushInventory();
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

    // -----------------------------------------------------------------------
    // Killing, reviving and casting (`HandleKillCommand`, `HandleCastSpellCommand`, ...)
    // -----------------------------------------------------------------------

    bool handleKillCommand()
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto plr = cast(WorldSession) map.find(guid);
        auto creature = plr is null ? cast(Creature) map.findObject(guid) : null;
        if (plr is null && creature is null)
        {
            redSystemMessage("A valid selection is required.");
            return true;
        }
        if (plr !is null)
        {
            gmLog("used kill command on PLAYER " ~ plr.player.data.name);
            // `KillPlayer` (not `DealDamage`: god mode does not stop it).
            plr.killedByGm(player.data.name);
            return true;
        }
        gmLog(format!"used kill command on CREATURE %u [%s], sqlid %u%s"(creature.spawn.entry, creature.template_.name,
            creature.spawn.guid, context.groups.of(player.guid) !is null ? ", in group" : ""));
        // Cast insta-kill (Death Touch).
        const deathTouch = context.data.spells.spell(5);
        if (deathTouch is null)
            return false;
        castSpell(deathTouch, SpellTargets(TargetFlags.unit, creature.guid), true, 0);
        return true;
    }

    bool handleKillByPlrCommand(Rest args = Rest.init)
    {
        auto found = context.onlinePlayer(args);
        if (found is null)
        {
            if (const remote = context.remotePlayer(args))
                if (gmElsewhere(args, GmRemoteOp.kill, args))
                {
                    gmLog(format!"remote killed %s (Name: %s)"(remote.entry.guid, remote.entry.name));
                    return true;
                }
            redSystemMessage(format!"Player %s is not online or does not exist."(args));
            return true;
        }
        auto plr = sessionOf(found);
        const wasAlive = plr.player.deathState == DeathState.alive;
        plr.killedByName(gmSink, player.data.name, args);
        if (wasAlive)
            gmLog(format!"remote killed %s (Name: %s)"(plr.player.guid, plr.player.data.name));
        return true;
    }

    bool handleReviveStringcommand(Rest args = Rest.init)
    {
        auto found = context.onlinePlayer(args);
        if (found is null)
        {
            if (context.remotePlayer(args) !is null && gmElsewhere(args, GmRemoteOp.revive, args))
            {
                gmLog("revived player " ~ args);
                return true;
            }
            redSystemMessage(format!"Could not find player %s."(args));
            return true;
        }
        auto plr = sessionOf(found);
        const wasDead = plr.player.deathState != DeathState.alive;
        plr.revivedByName(gmSink, args);
        if (wasDead)
            gmLog("revived player " ~ args);
        return true;
    }

    /// `getSelectedChar(false)`, else `getSelectedCreature(false)`: the cast commands' target, or null after the message.
    Object castTarget()
    {
        if (auto plr = getSelectedChar(false))
            return plr;
        if (auto creature = getSelectedCreature(false))
            return creature;
        redSystemMessage("Must select a char or creature.");
        return null;
    }

    /// `atol`: the number its text starts with (0 if none), and its spell; null after "Invalid spell id!".
    const(SpellInfo)* spellNamed(string args, out uint id)
    {
        import std.ascii : isDigit;
        import std.conv : to;

        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        id = n ? args[0 .. n].to!uint : 0;
        const spell = context.data.spells.spell(id);
        if (spell is null)
            redSystemMessage("Invalid spell id!");
        return spell;
    }

    /// The GM log line for a cast command at `target`.
    void logCast(string what, uint spellId, Object target, bool self)
    {
        import dmangos.world.creature : Creature;

        if (auto plr = cast(WorldSession) target)
        {
            if (!self)
                gmLog(format!"%s %d on PLAYER %s"(what, spellId, plr.player.data.name));
        }
        else if (auto creature = cast(Creature) target)
            gmLog(format!"%s %d on CREATURE %u [%s], sqlid %u"(what, spellId, creature.spawn.entry,
                creature.template_.name, creature.spawn.guid));
    }

    bool handleCastSpellCommand(Rest args = Rest.init)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Casting spell %d on target."(id));
        const guid = guidOf(target);
        castSpell(spell, SpellTargets(TargetFlags.unit, guid), false, 0);
        logCast("casted spell", id, target, target is this);
        return true;
    }

    bool handleCastSpellNECommand(Rest args = Rest.init)
    {
        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Casting spell %d on target."(id));
        // The look of a cast and nothing else, for this GM only (in the 1.12 client's layout).
        import dmangos.world.spellcast : spellGoPacket, spellStartPacket, SpellMissInfo, SpellTargets, TargetFlags,
            TargetResult;

        const targets = SpellTargets(TargetFlags.unit, guidOf(target));
        deliver(Opcode.SMSG_SPELL_START, spellStartPacket(player.guid, id, 0, targets));
        deliver(Opcode.SMSG_SPELL_GO, spellGoPacket(player.guid, id, [TargetResult(guidOf(target), SpellMissInfo.none)],
            targets));
        logCast("casted spell", id, target, target is this);
        return true;
    }

    bool handleCastSelfCommand(Rest args = Rest.init)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Target is casting spell %d on himself."(id));
        if (auto plr = cast(WorldSession) target)
            plr.castSpell(spell, SpellTargets(TargetFlags.unit, plr.player.guid), false, 0);
        else if (auto creature = cast(Creature) target)
            creature.ai.castFromCommand(spell, map);
        logCast("used castself with spell", id, target, target is this);
        return true;
    }

    /// The guid of a cast command's target.
    ulong guidOf(Object target)
    {
        import dmangos.world.creature : Creature;

        if (auto plr = cast(WorldSession) target)
            return plr.player.guid;
        return (cast(Creature) target).guid;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * `.kill` on a creature (Death Touch) and on a player, `.killplr`, `.reviveplr`, `.npc respawn`, and the
 * cheats that change casting and damage (`.cheat god`, `.cheat casttime`, `.cheat status`).
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.spells.spells[5] = testSpell(5, 1, 25, 0); // Death Touch
    context.data.spells.spells[5].casting.dmgClass = 0;
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto victim = cast(Player) anduin.session.character;

    // Nothing selected.
    gm.say(".kill");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "A valid selection is required.|r"]);

    // A creature: Death Touch.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
    gm.say(".kill");
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_SPELLINSTAKILLLOG) && !keeper.alive, "dead");

    // `.npc respawn` on its corpse: gone now, back a second later.
    gm.say(".npc respawn");
    assert(systemMessages(gm.read())[0].canFind("Respawning a Creature: `"));
    assert(map.findObject(keeper.guid) is null);
    now += 2.seconds;
    context.update(now);
    auto again = cast(Creature) map.findObject(keeper.guid);
    assert(again !is null && again.alive, "back");

    // A player, by selection and by name; and back to life by name.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".kill");
    gm.read();
    assert(victim.deathState == DeathState.corpse);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_LIGHTBLUE ~ "Varian killed you with a GM command.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Player anduin is already dead.|r"]);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Revived player anduin.|r"]);
    assert(victim.deathState == DeathState.alive
        && victim.values.get!UNIT_FIELD_HEALTH == victim.values.get!UNIT_FIELD_MAXHEALTH);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Player anduin is not dead.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Killed player anduin.|r"]);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_LIGHTBLUE ~ "You were killed by Varian with a GM command.|r"]);
    gm.say(".killplr nobody");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Player nobody is not online or does not exist.|r"]);
    gm.say(".reviveplr anduin");
    gm.read();

    // God mode: no damage taken.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".cheat god");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "activated the god mode cheat on Anduin.|r"]);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_GREEN ~ "activated the god mode cheat on you.|r"]);
    const health = victim.values.get!UNIT_FIELD_HEALTH;
    anduin.session.takeDamageFrom(keeper.guid, 50);
    assert(victim.values.get!UNIT_FIELD_HEALTH == health);
    gm.say(".cheat casttime on");
    gm.say(".cheat status");
    const status = systemMessages(gm.read());
    assert(status.canFind(MSG_COLOR_LIGHTBLUE ~ "GodMode: " ~ MSG_COLOR_LIGHTRED ~ "Active"));
    assert(status.canFind(MSG_COLOR_LIGHTBLUE ~ "CastTime: " ~ MSG_COLOR_LIGHTRED ~ "Active"));
    assert(status[$ - 1] == "2 cheats active, 5 inactive.");
}
