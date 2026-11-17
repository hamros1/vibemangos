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
    import dmangos.world.gminstance : describeInstance, instanceHere, resetAllHere, resetInstanceHere,
        shutdownInstanceHere;
    import dmangos.world.gmtargets : GmRemoteOp;

private:

    /**
     * In a cluster, the copy `id` is another node's (its dungeon's host): the command goes there and
     * its answer comes back. False if this node hosts it, or it is nobody's (no such instance).
     */
    bool instanceElsewhere(uint id, GmRemoteOp op, ulong target = 0)
    {
        import dmangos.cluster.protocol : GmRemote;

        if (context.gmRemote is null || instanceHere(context, id))
            return false;
        const mapId = context.database.instanceMapOf(id);
        if (mapId == uint.max)
            return false;
        const host = context.dungeonHost(mapId);
        if (host == 0 || host == context.nodeId)
            return false;
        GmRemote m;
        m.op = op;
        m.gm = player.guid;
        m.gmName = player.data.name;
        m.gmCanKickGms = canUseCommand('z');
        m.target = target;
        m.instance = id;
        context.gmRemote(host, m);
        return true;
    }

    bool handleResetAllInstancesCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        systemMessage(format!"Trying to reset all instances of player %s..."(plr.player.data.name));
        resetAllHere(context, plr.player.guid);
        // In a cluster each dungeon's host resets its own copies.
        if (context.gmRemote !is null)
        {
            import dmangos.cluster.protocol : GmRemote;

            GmRemote m;
            m.op = GmRemoteOp.instanceResetAll;
            m.gm = player.guid;
            m.gmName = player.data.name;
            m.target = plr.player.guid;
            foreach (node; context.otherNodes())
                context.gmRemote(node, m);
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
        if (!instanceElsewhere(instanceId, GmRemoteOp.instanceReset, plr.player.guid))
            resetInstanceHere(context, instanceId, plr.player.guid, plr.player.data.name, canUseCommand('z'), gmSink);
        gmLog(format!"used reset instance command on %s, instance %u,"(plr.player.data.name, instanceId));
        return true;
    }

    bool handleShutdownInstanceCommand(uint instanceId = 0)
    {
        if (instanceId == 0)
            return false;
        if (!instanceElsewhere(instanceId, GmRemoteOp.instanceShutdown))
            shutdownInstanceHere(context, instanceId, gmSink);
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
        if (userInput && instanceElsewhere(instanceId, GmRemoteOp.instanceInfo))
            return true;
        if (context.instanceState(instanceId) is null)
        {
            if (userInput)
            {
                redSystemMessage(format!"Instance with id %u not found."(instanceId));
                return true;
            }
            return false;
        }
        describeInstance(context, instanceId, gmSink);
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
        import dmangos.world.gminstance : mapName, mapTypeString;

        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        uint count;
        string ss = "Show persistent instances of " ~ MSG_COLOR_CYAN ~ plr.player.data.name ~ "|r\n";
        // The binds this node knows, and (in a cluster) those of dungeons other nodes host, as saved.
        uint[uint] binds = cast(uint[uint]) context.bindsOf(plr.player.guid).dup;
        if (context.gmRemote !is null)
            foreach (mapId, id; context.database.instanceBindsOf(cast(uint) plr.player.guid))
                if (mapId !in binds)
                    binds[mapId] = id;
        foreach (mapId, id; binds)
        {
            ++count;
            ss ~= " - " ~ MSG_COLOR_CYAN ~ format!"%s"(id) ~ "|r";
            ss ~= " (" ~ MSG_COLOR_CYAN ~ mapName(context, mapId) ~ "|r)";
            const host = context.dungeonHost(mapId);
            if (context.gmRemote !is null && host != context.nodeId)
                ss ~= " [" ~ mapTypeString(context, mapId) ~ "] - " ~ MSG_COLOR_CYAN ~ format!"node %s"(host) ~ "|r";
            else if (context.instanceState(id) is null)
                ss ~= " - " ~ MSG_COLOR_RED ~ "Expired!|r";
            else
            {
                ss ~= " [" ~ mapTypeString(context, mapId) ~ "] - ";
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
    /// ArcEmu's `Player::ExitInstance`: back to where it was before going into an instance; false if that is not known.
    bool exitInstance()
    {
        if (entryMap == uint.max)
            return false;
        commandTeleport(entryMap, entryPoint, 0);
        return true;
    }
}

// ---------------------------------------------------------------------------
// The commands' work on the node hosting the copy (the GM's, or in a cluster its dungeon's host)
// ---------------------------------------------------------------------------

import dmangos.world.context : WorldContext;
import dmangos.world.gmtargets : GmSink;

/// Whether this node knows copy `id` (it hosts its dungeon).
bool instanceHere(WorldContext context, uint id)
{
    return context.instanceState(id) !is null;
}

/// ArcEmu's `GetMapTypeString` for a map of this server.
string mapTypeString(WorldContext context, uint mapId)
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
string mapName(WorldContext context, uint mapId)
{
    import std.format : format;

    const entry = context.client.maps.lookup(mapId);
    return entry is null ? format!"%s"(mapId) : entry.name[0];
}

/// `.instance info`'s lines about copy `id` (known here).
void describeInstance(WorldContext context, uint id, GmSink sink)
{
    import std.array : split;
    import std.format : format;
    import core.time : seconds;
    import dmangos.world.commands;

    const state = context.instanceState(id);
    if (state is null)
        return sink.red(format!"Instance with id %u not found."(id));
    string ss = "Instance ID: " ~ MSG_COLOR_CYAN ~ format!"%s"(id) ~ "|r (" ~ MSG_COLOR_CYAN
        ~ mapName(context, state.mapId) ~ "|r)\n";
    ss ~= "Persistent: " ~ MSG_COLOR_CYAN ~ (state.resetAt ? "Yes" : "No") ~ "|r\n";
    ss ~= "Type: " ~ MSG_COLOR_CYAN ~ mapTypeString(context, state.mapId) ~ "|r\n";
    ss ~= "Created: " ~ MSG_COLOR_CYAN ~ convertTimeStampToDataTime(state.createdAt) ~ "|r\n";
    ss ~= "Expires: " ~ MSG_COLOR_CYAN ~ convertTimeStampToDataTime(state.resetAt) ~ "|r\n";
    auto m = context.instanceMap(id);
    if (m is null)
        ss ~= "Status: " ~ MSG_COLOR_LIGHTRED ~ "Shut Down|r\n";
    else if (m.population == 0)
    {
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
    foreach (line; ss.split('\n'))
        if (line.length)
            sink.system(line);
}

/// `.instance shutdown`'s work on copy `id`: everyone inside goes back out, and the copy unloads.
void shutdownInstanceHere(WorldContext context, uint id, GmSink sink)
{
    import std.format : format;
    import dmangos.world.session : WorldSession;

    if (context.instanceState(id) is null)
        return sink.red(format!"There's no instance with id %u."(id));
    auto m = context.instanceMap(id);
    if (m is null)
        return sink.red(format!"Instance with id %u already shut down."(id));
    sink.system(format!"Attempting to shutdown instance with id %u..."(id));
    // `MapMgr::InstanceShutdown`: everyone inside goes back out first.
    foreach (other; context.onlinePlayers)
        if (auto inside = cast(WorldSession) other)
            if (inside.instanceId == id && inside.character !is null)
                inside.exitInstance();
    context.shutdownInstance(id);
    sink.system("...done");
}

/// `.instance reset`'s work on copy `id` for player `who` (`canRevoke`: the GM has the `z` permission).
void resetInstanceHere(WorldContext context, uint id, ulong who, string name, bool canRevoke, GmSink sink)
{
    import std.format : format;

    const state = context.instanceState(id);
    if (state is null)
        return sink.red(format!"There's no instance with id %u."(id));
    const binds = context.bindsOf(who);
    const bound = state.mapId in binds;
    if (state.resetAt) // persistent
    {
        if (!canRevoke)
            return sink.red(format!"Instance with id %u is persistent and can only be removed from player by admins."(id));
        if (bound !is null && *bound == id)
        {
            context.revokeBind(who, state.mapId);
            return sink.system(format!"Instance with id %u (%s) is persistent and will only be revoked from player."(id,
                "normal"));
        }
        return sink.red(format!"Player is not assigned to persistent instance with id %u."(id));
    }
    auto m = context.instanceMap(id);
    if (m !is null && m.population)
        return sink.red(format!"Failed to reset non-persistent instance with id %u, due to player still inside."(id));
    if (bound is null || *bound != id)
        return sink.red(format!"Player %s is not assigned to instance with id %u."(name, id));
    sink.red("Resetting single non-persistent instances is not available yet."); // as ArcEmu says
}

/// `.instance resetall`'s work here: the player's copies this node hosts that are not persistent and empty.
void resetAllHere(WorldContext context, ulong who)
{
    // `InstanceMgr::ResetSavedInstances`
    foreach (mapId, id; context.bindsOf(who).dup)
    {
        const state = context.instanceState(id);
        if (state is null || state.resetAt)
            continue;
        auto m = context.instanceMap(id);
        if (m !is null && m.population)
            continue;
        context.resetInstance(id);
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
