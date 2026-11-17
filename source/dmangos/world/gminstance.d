/**
 * ArcEmu's `InstanceCommands.cpp`: `.instance reset`, `.instance resetall`, `.instance shutdown`,
 * `.instance info`, `.instance exit`, and `.character showinstances`, on this server's instances
 * (`WorldContext`'s copies and binds). Vanilla has one difficulty, ArcEmu's "normal"; a persistent
 * instance is a raid copy (it lasts until its reset). Mixed into `dmangos.world.session.WorldSession`.
 */
module dmangos.world.gminstance;

/// See the module documentation.
mixin template InstanceCommands()
{
    import std.format : format;
    import dmangos.world.commands;

private:

    /// ArcEmu's `GetMapTypeString` for a map of this server.
    string mapTypeString(uint mapId)
    {
        const entry = context.client.maps.lookup(mapId);
        if (entry is null)
            return "Unknown";
        if (entry.isRaid)
            return "Raid";
        if (entry.isDungeon)
            return "Non-Raid";
        if (entry.isBattleground)
            return "PvP";
        return "Continent";
    }

    /// The map's name, as ArcEmu's `MapInfo.name`.
    string mapName(uint mapId)
    {
        const entry = context.client.maps.lookup(mapId);
        return entry is null ? format!"%s"(mapId) : entry.name[0];
    }

    bool handleResetAllInstancesCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        systemMessage(format!"Trying to reset all instances of player %s..."(plr.player.data.name));
        // `InstanceMgr::ResetSavedInstances`: its copies that are not persistent and have nobody in them.
        foreach (mapId, id; context.bindsOf(plr.player.guid).dup)
        {
            const state = context.instanceState(id);
            if (state is null || state.resetAt)
                continue;
            auto m = context.instanceMap(id);
            if (m !is null && m.population)
                continue;
            context.resetInstance(id);
        }
        systemMessage("...done");
        gmLog(format!"used reset all instances command on %s,"(plr.player.data.name));
        return true;
    }

    bool handleResetInstanceCommand(uint instanceId = 0)
    {
        if (instanceId == 0)
            return false;
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        const state = context.instanceState(instanceId);
        if (state is null)
        {
            redSystemMessage(format!"There's no instance with id %u."(instanceId));
            return true;
        }
        if (state.resetAt) // persistent
        {
            if (canUseCommand('z'))
            {
                const binds = context.bindsOf(plr.player.guid);
                if (const bound = state.mapId in binds)
                    if (*bound == instanceId)
                    {
                        context.revokeBind(plr.player.guid, state.mapId);
                        systemMessage(format!"Instance with id %u (%s) is persistent and will only be revoked from player."(
                            instanceId, "normal"));
                        return true;
                    }
                redSystemMessage(format!"Player is not assigned to persistent instance with id %u."(instanceId));
                return true;
            }
            redSystemMessage(format!"Instance with id %u is persistent and can only be removed from player by admins."(
                instanceId));
            return true;
        }
        auto m = context.instanceMap(instanceId);
        if (m !is null && m.population)
        {
            redSystemMessage(format!"Failed to reset non-persistent instance with id %u, due to player still inside."(
                instanceId));
            return true;
        }
        const binds = context.bindsOf(plr.player.guid);
        const bound = state.mapId in binds;
        if (bound is null || *bound != instanceId)
        {
            redSystemMessage(format!"Player %s is not assigned to instance with id %u."(plr.player.data.name, instanceId));
            return true;
        }
        redSystemMessage("Resetting single non-persistent instances is not available yet."); // as ArcEmu says
        gmLog(format!"used reset instance command on %s, instance %u,"(plr.player.data.name, instanceId));
        return true;
    }

    bool handleShutdownInstanceCommand(uint instanceId = 0)
    {
        import dmangos.world.session : WorldSession;

        if (instanceId == 0)
            return false;
        if (context.instanceState(instanceId) is null)
        {
            redSystemMessage(format!"There's no instance with id %u."(instanceId));
            return true;
        }
        auto m = context.instanceMap(instanceId);
        if (m is null)
        {
            redSystemMessage(format!"Instance with id %u already shut down."(instanceId));
            return true;
        }
        systemMessage(format!"Attempting to shutdown instance with id %u..."(instanceId));
        // `MapMgr::InstanceShutdown`: everyone inside goes back out first.
        foreach (other; context.onlinePlayers)
            if (auto inside = cast(WorldSession) other)
                if (inside.instanceId == instanceId && inside.player !is null)
                    inside.exitInstance();
        context.shutdownInstance(instanceId);
        systemMessage("...done");
        gmLog(format!"used shutdown instance command on instance %u,"(instanceId));
        return true;
    }

    bool handleGetInstanceInfoCommand(uint instanceId = 0)
    {
        if (player is null)
            return false;
        bool userInput = true;
        if (instanceId == 0)
        {
            userInput = false;
            instanceId = instanceId_;
            if (instanceId == 0)
                return false;
        }
        const state = context.instanceState(instanceId);
        if (state is null)
        {
            if (userInput)
            {
                redSystemMessage(format!"Instance with id %u not found."(instanceId));
                return true;
            }
            return false;
        }
        string ss = "Instance ID: " ~ MSG_COLOR_CYAN ~ format!"%s"(instanceId) ~ "|r (" ~ MSG_COLOR_CYAN
            ~ mapName(state.mapId) ~ "|r)\n";
        ss ~= "Persistent: " ~ MSG_COLOR_CYAN ~ (state.resetAt ? "Yes" : "No") ~ "|r\n";
        ss ~= "Type: " ~ MSG_COLOR_CYAN ~ mapTypeString(state.mapId) ~ "|r\n";
        ss ~= "Created: " ~ MSG_COLOR_CYAN ~ convertTimeStampToDataTime(state.createdAt) ~ "|r\n";
        ss ~= "Expires: " ~ MSG_COLOR_CYAN ~ convertTimeStampToDataTime(state.resetAt) ~ "|r\n";
        auto m = context.instanceMap(instanceId);
        if (m is null)
            ss ~= "Status: " ~ MSG_COLOR_LIGHTRED ~ "Shut Down|r\n";
        else if (m.population == 0)
        {
            import core.time : seconds;

            ss ~= "Status: " ~ MSG_COLOR_LIGHTRED ~ "Idle|r";
            if (state.emptySince != state.emptySince.init)
            {
                const left = state.emptySince + context.config.instanceUnloadDelay.seconds - context.clock();
                ss ~= " (" ~ MSG_COLOR_CYAN ~ "Shutdown in " ~ MSG_COLOR_LIGHTRED ~ format!"%s"(left.total!"minutes")
                    ~ MSG_COLOR_CYAN ~ " minutes|r)";
            }
            ss ~= "\n";
        }
        else
            ss ~= "Status: " ~ MSG_COLOR_GREEN ~ "In use|r (" ~ MSG_COLOR_GREEN ~ format!"%s"(m.population)
                ~ MSG_COLOR_CYAN ~ " players inside|r)\n";
        sendMultilineMessage(ss);
        return true;
    }

    bool handleExitInstanceCommand()
    {
        blueSystemMessage("Attempting to exit from instance...");
        if (!exitInstance())
        {
            redSystemMessage("Entry points not found.");
            return true;
        }
        greenSystemMessage("Removal successful.");
        return true;
    }

    bool handleShowInstancesCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        uint count;
        string ss = "Show persistent instances of " ~ MSG_COLOR_CYAN ~ plr.player.data.name ~ "|r\n";
        foreach (mapId, id; context.bindsOf(plr.player.guid))
        {
            ++count;
            ss ~= " - " ~ MSG_COLOR_CYAN ~ format!"%s"(id) ~ "|r";
            ss ~= " (" ~ MSG_COLOR_CYAN ~ mapName(mapId) ~ "|r)";
            if (context.instanceState(id) is null)
                ss ~= " - " ~ MSG_COLOR_RED ~ "Expired!|r";
            else
            {
                ss ~= " [" ~ mapTypeString(mapId) ~ "] - ";
                auto m = context.instanceMap(id);
                if (m is null)
                    ss ~= MSG_COLOR_LIGHTRED ~ "Shut Down|r";
                else if (m.population == 0)
                    ss ~= MSG_COLOR_LIGHTRED ~ "Idle|r";
                else
                    ss ~= MSG_COLOR_GREEN ~ "In use|r";
            }
            ss ~= "\n";
        }
        if (count == 0)
            ss ~= "Player is not assigned to any persistent instances.\n";
        else
            ss ~= "Player is assigned to " ~ MSG_COLOR_CYAN ~ format!"%s"(count) ~ "|r persistent instances.\n";
        sendMultilineMessage(ss);
        gmLog(format!"used show instances command on %s,"(plr.player.data.name));
        return true;
    }

package:
    /// ArcEmu's `Player::ExitInstance`: back to where it was before going in; false if that is not known.
    bool exitInstance()
    {
        if (entryMap == uint.max)
            return false;
        commandTeleport(entryMap, entryPoint, 0);
        return true;
    }
}

/**
 * A GM in an instance: `.instance info` describes it, `.character showinstances` lists the bind,
 * `.instance exit` goes back to where it came from, and `.instance shutdown` sends whoever is inside
 * out and unloads the copy.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : MSG_COLOR_LIGHTRED;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const outside = Position(-8949.95f, -132.49f, 83.53f);
    auto gm = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    gm.read();

    gm.say(".instance info");
    assert(systemMessages(gm.read()).length > 0, "not in an instance: the help");
    gm.say(".worldport 36 -16 -383 61");
    gm.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const id = gm.session.instanceId;
    assert(id);
    gm.read();

    gm.say(".instance info");
    const info = systemMessages(gm.read());
    assert(info.canFind!(m => m.canFind("Instance ID: ")) && info.canFind!(m => m.canFind("Non-Raid")));
    assert(info.canFind!(m => m.canFind("In use|r")), "it is in it");

    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(gm.session.character.guid));
    gm.say(".character showinstances");
    const shown = systemMessages(gm.read());
    assert(shown.canFind!(m => m.canFind("Player is assigned to ")), "one bind");

    gm.say(".instance exit");
    gm.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const exited = systemMessages(gm.read());
    assert(exited.canFind!(m => m.canFind("Removal successful.")));
    assert(gm.session.instanceId == 0 && gm.session.character.data.map == 0 && gm.session.character.position == outside);

    gm.say(".instance shutdown 999");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "There's no instance with id 999.|r"]);
    gm.say(format!".instance shutdown %s"(id));
    assert(systemMessages(gm.read()) == ["Attempting to shutdown instance with id " ~ format!"%s"(id) ~ "...", "...done"]);
    assert(context.instanceMap(id) is null && context.instanceState(id) !is null, "unloaded, kept");
    gm.say(format!".instance shutdown %s"(id));
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Instance with id " ~ format!"%s"(id)
        ~ " already shut down.|r"]);
}
