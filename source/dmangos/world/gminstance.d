/**
 * The instance commands: `.instance reset`, `.instance resetall`, `.instance shutdown`,
 * `.instance info`, `.instance exit`, and `.character showinstances`, on this server's instances
 * (`WorldContext`'s copies and binds). Their behaviour and messages match ArcEmu 2.4.3's exactly.
 * Vanilla has one difficulty, the one the messages call "normal"; a persistent
 * instance is a raid copy (it lasts until its reset). Mixed into `dmangos.world.session.Character`.
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
        m.gmCanKickGms = allowsStaff("staff.admin");
        m.target = target;
        m.instance = id;
        context.gmRemote(host, m);
        return true;
    }

    bool handleResetAllInstancesCommand()
    {
        auto plr = selectedCharacter(true);
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
        auto plr = selectedCharacter(true);
        if (plr is null)
            return true;
        if (!instanceElsewhere(instanceId, GmRemoteOp.instanceReset, plr.player.guid))
            resetInstanceHere(context, instanceId, plr.player.guid, plr.player.data.name, allowsStaff("staff.admin"), gmSink);
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

        auto plr = selectedCharacter(true);
        if (plr is null)
            return true;
        systemMessage("Persistent instances for " ~ colored(ChatColor.cyan, plr.player.data.name));
        auto binds = context.bindsOf(plr.player.guid).dup;
        if (context.gmRemote !is null)
            foreach (mapId, id; context.database.instanceBindsOf(cast(uint) plr.player.guid))
                if (mapId !in binds)
                    binds[mapId] = id;
        foreach (mapId, id; binds)
        {
            const host = context.dungeonHost(mapId);
            auto m = context.instanceMap(id);
            string status;
            if (context.gmRemote !is null && host != context.nodeId)
                status = colored(ChatColor.cyan, format!"Node %s"(host));
            else if (context.instanceState(id) is null)
                status = colored(ChatColor.red, "Expired");
            else if (m is null || !m.population)
                status = colored(ChatColor.softRed, m is null ? "Shut down" : "Idle");
            else
                status = colored(ChatColor.green, "In use");
            systemMessage(format!"%s  ·  %s  ·  %s  ·  %s"(colored(ChatColor.cyan, format!"%s"(id)),
                colored(ChatColor.cyan, mapName(context, mapId)), mapTypeString(context, mapId), status));
        }
        if (!binds.length)
            systemMessage("This player has no persistent instance binds.");
        else
            systemMessage(format!"Player is assigned to %s persistent instances."(
                colored(ChatColor.cyan, format!"%s"(binds.length))));
        gmLog(format!"used show instances command on %s,"(plr.player.data.name));
        return true;
    }

package:
    /// Back to where the player was before going into an instance; false if that is not known.
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

/// The kind of a map, as `.instance info` names it: raid, dungeon ("Non-Raid"), battleground ("PvP") or continent.
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

/// The map's name from `Map.dbc` (its id if unknown), as the commands show it.
string mapName(WorldContext context, uint mapId)
{
    import std.format : format;

    const entry = context.client.maps.lookup(mapId);
    return entry is null ? format!"%s"(mapId) : entry.name[0];
}

/// `.instance info`'s lines about copy `id` (known here).
void describeInstance(WorldContext context, uint id, GmSink sink)
{
    import std.format : format;
    import core.time : seconds;
    import dmangos.world.commands;

    const state = context.instanceState(id);
    if (state is null)
        return sink.red(format!"Instance with id %u not found."(id));
    void field(string label, string value, ChatColor color = ChatColor.cyan)
    {
        sink.system(label ~ ": " ~ colored(color, value));
    }
    field("Instance ID", format!"%s (%s)"(id, mapName(context, state.mapId)));
    field("Persistent", state.resetAt ? "Yes" : "No");
    field("Type", mapTypeString(context, state.mapId));
    field("Created", convertTimeStampToDataTime(state.createdAt));
    field("Expires", convertTimeStampToDataTime(state.resetAt));

    auto map = context.instanceMap(id);
    if (map is null)
        field("Status", "Shut down", ChatColor.softRed);
    else if (map.population)
    {
        field("Status", "In use", ChatColor.green);
        field("Players inside", format!"%s"(map.population));
    }
    else
    {
        field("Status", "Idle", ChatColor.softRed);
        if (state.emptySince != state.emptySince.init)
        {
            const left = state.emptySince + context.config.instanceUnloadDelay.seconds - context.clock();
            field("Shutdown in", format!"%s minutes"(left.total!"minutes"));
        }
    }
}

/// `.instance shutdown`'s work on copy `id`: everyone inside goes back out, and the copy unloads.
void shutdownInstanceHere(WorldContext context, uint id, GmSink sink)
{
    import std.format : format;
    import dmangos.world.character : Character;

    if (context.instanceState(id) is null)
        return sink.red(format!"There's no instance with id %u."(id));
    auto m = context.instanceMap(id);
    if (m is null)
        return sink.red(format!"Instance with id %u already shut down."(id));
    sink.system(format!"Attempting to shutdown instance with id %u..."(id));
    // Everyone inside goes back out first.
    foreach (inside; context.onlinePlayers)
        if (inside.instanceId == id && inside.character !is null)
            inside.exitInstance();
    context.shutdownInstance(id);
    sink.system("...done");
}

/// `.instance reset`'s work on copy `id` for player `who` (`canRevoke`: the issuer has `staff.admin`).
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
    sink.red("Resetting single non-persistent instances is not available yet."); // the required reply, word for word
}

/// `.instance resetall`'s work here: the player's copies this node hosts that are not persistent and empty.
void resetAllHere(WorldContext context, ulong who)
{
    // Resets each bound copy that is not persistent and has no one inside.
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
    import dmangos.world.commands : ChatColor;
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
    const id = gm.session.inWorld.instanceId;
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
    assert(gm.session.inWorld.instanceId == 0 && gm.session.character.data.map == 0 && gm.session.character.position == outside);

    gm.say(".instance shutdown 999");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "There's no instance with id 999.|r"]);
    gm.say(format!".instance shutdown %s"(id));
    assert(systemMessages(gm.read()) == ["Attempting to shutdown instance with id " ~ format!"%s"(id) ~ "...", "...done"]);
    assert(context.instanceMap(id) is null && context.instanceState(id) !is null, "unloaded, kept");
    gm.say(format!".instance shutdown %s"(id));
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Instance with id " ~ format!"%s"(id)
        ~ " already shut down.|r"]);
}
