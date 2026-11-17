/**
 * What ArcEmu's GM commands that name a player do to that player, as methods of the player's
 * `WorldSession` (mixed in), so that they run where the player is simulated: on this node, or in a
 * cluster on another (docs/CLUSTER.md, phase 5b), the GM's messages then going back to its node.
 * The GM's side (finding the player, logging) stays in the command handlers.
 */
module dmangos.world.gmtargets;

import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;

/// What a `GmRemote` does to its target.
enum GmRemoteOp : ubyte
{
    kick,         /// `.kick`; `text`: the reason
    summon,       /// `.summon`: to the GM's map and position
    appear,       /// `.appear`: the GM comes to the target (`appearAt` goes back)
    appearAt,     /// the target's map and position, for the GM
    disconnect,   /// `.kill`-by-name (`World::DisconnectUsersWithPlayerName`)
    banKick,      /// `.ban character`: the account is banned already; the player goes
    rename,       /// `.rename`: the database has the new name (`text`) already
    playerInfo,   /// `.playerinfo`
    kill,         /// `.killplr`; `text`: the name as the GM typed it
    revive,       /// `.reviveplr`; `text`: ditto
    saveAll,      /// `.server saveall`: every node saves its players (no target)
    massSummon,   /// `.masssummon`: every node asks its players to the GM's place; `text`: the GM's zone
    instanceInfo,     /// `.instance info` of copy `instance`, on its dungeon's host (no target)
    instanceShutdown, /// `.instance shutdown` of copy `instance`, ditto
    instanceReset,    /// `.instance reset` of copy `instance` for the player `target`, ditto
    instanceResetAll, /// `.instance resetall`: the player `target`'s copies each node hosts
}

/// Whether `op` is about a dungeon copy (or a player's), done on the node hosting it.
bool aboutInstances(GmRemoteOp op) pure nothrow @nogc @safe
{
    return op >= GmRemoteOp.instanceInfo && op <= GmRemoteOp.instanceResetAll;
}

/// Whether `op` is for every node's players rather than one target.
bool everywhere(GmRemoteOp op) pure nothrow @nogc @safe
{
    return op == GmRemoteOp.saveAll || op == GmRemoteOp.massSummon;
}

/// Where a GM command's messages go: the GM's client, here or on its node (`ChatHandler`'s colours).
struct GmSink
{
    void delegate(string text) send;

    void system(string text)
    {
        send(text.length > 1023 ? text[0 .. 1023] : text);
    }

    void colored(string color, string text)
    {
        system(color ~ (text.length > 1023 ? text[0 .. 1023] : text) ~ "|r");
    }

    void red(string text) { colored(MSG_COLOR_LIGHTRED, text); }
    void green(string text) { colored(MSG_COLOR_GREEN, text); }
    void blue(string text) { colored(MSG_COLOR_LIGHTBLUE, text); }
}

/// See the module documentation.
mixin template GmTargets()
{
    import std.format : format;
    import dmangos.cluster.protocol : GmRemote;
    import dmangos.world.commands : MSG_COLOR_RED;
    import dmangos.world.gmtargets : GmRemoteOp, GmSink;
    import dmangos.world.movement : Position;

    /// This GM's messages, for the target-side methods when the target is here.
    package GmSink gmSink()
    {
        return GmSink(&systemMessage);
    }

    /**
     * Sends `op` to the node simulating `name`, if another node does (phase 5b); false if none.
     * `map` and `at` are the GM's map and position, for a summons.
     */
    package bool gmElsewhere(string name, GmRemoteOp op, string text = null)
    {
        if (context.gmRemote is null)
            return false;
        const remote = context.remotePlayer(name);
        if (remote is null)
            return false;
        GmRemote m;
        m.op = op;
        m.gm = player.guid;
        m.gmName = player.data.name;
        m.gmCanKickGms = canUseCommand('z');
        m.target = remote.entry.guid;
        m.map = player.data.map;
        m.instance = instanceId_;
        const at = player.position;
        m.x = at.x;
        m.y = at.y;
        m.z = at.z;
        m.orientation = at.orientation;
        m.text = text;
        context.gmRemote(remote.node, m);
        return true;
    }

    /// A GM's command from another node for this player: done here, the GM told through `gm`; `reply`
    /// sends a command back to the GM's node (`appearAt`).
    package void gmTargeted(const ref GmRemote m, GmSink gm, void delegate(GmRemote) reply)
    {
        if (m.op > GmRemoteOp.max)
            return;
        final switch (cast(GmRemoteOp) m.op)
        {
        case GmRemoteOp.kick:
            return kickedBy(gm, m.gmName, m.gmCanKickGms, m.text);
        case GmRemoteOp.summon:
            return summonedBy(gm, m.gmName, m.map, Position(m.x, m.y, m.z, m.orientation), m.instance);
        case GmRemoteOp.appear:
            return appearedToBy(gm, m.gmName, (uint map, Position at, uint instance) {
                GmRemote back;
                back.instance = instance;
                back.op = GmRemoteOp.appearAt;
                back.gm = m.gm;
                back.target = m.gm;
                back.map = map;
                back.x = at.x;
                back.y = at.y;
                back.z = at.z;
                back.orientation = at.orientation;
                reply(back);
            });
        case GmRemoteOp.appearAt:
            commandTeleport(m.map, Position(m.x, m.y, m.z, m.orientation), m.instance);
            return;
        case GmRemoteOp.disconnect:
            return disconnectedBy(gm, m.gmName);
        case GmRemoteOp.banKick:
            return bannedBy(gm, m.gmName);
        case GmRemoteOp.rename:
            return renamedBy(gm, m.gmName, m.text);
        case GmRemoteOp.playerInfo:
            return describeTo(gm);
        case GmRemoteOp.kill:
            return killedByName(gm, m.gmName, m.text);
        case GmRemoteOp.revive:
            return revivedByName(gm, m.text);
        case GmRemoteOp.saveAll:
            return savePlayer();
        case GmRemoteOp.instanceInfo, GmRemoteOp.instanceShutdown, GmRemoteOp.instanceReset,
            GmRemoteOp.instanceResetAll:
            return; // the node's, not a player's (`ClusterBridge.gmRemote`)
        case GmRemoteOp.massSummon:
        {
            import std.conv : to, ConvException;

            uint zone;
            try
                zone = m.text.to!uint;
            catch (ConvException) {}
            return summonRequest(m.gm, zone, m.map, Position(m.x, m.y, m.z, m.orientation));
        }
        }
    }

    /// `op` for every other node of a cluster (`everywhere`), with this GM's place; how many nodes it went to.
    package size_t gmEverywhere(GmRemoteOp op, string text = null)
    {
        if (context.gmRemote is null)
            return 0;
        GmRemote m;
        m.op = op;
        m.gm = player.guid;
        m.gmName = player.data.name;
        m.gmCanKickGms = canUseCommand('z');
        m.map = player.data.map;
        m.instance = instanceId_;
        const at = player.position;
        m.x = at.x;
        m.y = at.y;
        m.z = at.z;
        m.orientation = at.orientation;
        m.text = text;
        const nodes = context.otherNodes();
        foreach (node; nodes)
            context.gmRemote(node, m);
        return nodes.length;
    }

    /// `.kill`'s part on a player: health 0 and `KillPlayer`; it is told who did it.
    package void killedByGm(string gmName)
    {
        import dmangos.world.player : DeathState;
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

        if (player.deathState != DeathState.alive)
            return;
        player.values.set!UNIT_FIELD_HEALTH(0u);
        playerDied(false);
        blueSystemMessage(format!"%s killed you with a GM command."(gmName));
    }

    /// `.killplr`'s part on the player (`args`: its name as the GM typed it).
    package void killedByName(GmSink gm, string gmName, string args)
    {
        import dmangos.world.player : DeathState;
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

        if (player.deathState != DeathState.alive)
            return gm.red(format!"Player %s is already dead."(args));
        player.values.set!UNIT_FIELD_HEALTH(0u);
        playerDied(false);
        blueSystemMessage(format!"You were killed by %s with a GM command."(gmName));
        gm.green(format!"Killed player %s."(args));
    }

    /// `.reviveplr`'s part on the player: `RemoteRevive` (alive with full health, its corpse gone).
    package void revivedByName(GmSink gm, string args)
    {
        import dmangos.world.player : DeathState;

        if (player.deathState == DeathState.alive)
            return gm.green(format!"Player %s is not dead."(args));
        remoteRevive();
        gm.green(format!"Revived player %s."(args));
    }

    /// `Player::RemoteRevive`: `ResurrectPlayer`, unrooted, full health.
    package void remoteRevive()
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        resurrect(1);
        spawnCorpseBones();
        player.values.set!UNIT_FIELD_HEALTH(player.values.get!UNIT_FIELD_MAXHEALTH);
        flushPlayerChanges();
    }

    /// `.kick`'s part on the player: a GM without the `z` permission cannot kick one who has it.
    package void kickedBy(GmSink gm, string gmName, bool gmCanKickGms, string reason)
    {
        const chrName = player.data.name;
        gm.blue(format!"Attempting to kick %s from the server for \"%s\"."(chrName, reason));
        if (!gmCanKickGms && canUseCommand('z'))
            return gm.red(format!"You cannot kick %s, as they are a higher level gm than you."(chrName));
        const message = format!"%sGM: %s was kicked from the server by %s. Reason: %s"(MSG_COLOR_RED, chrName,
            gmName, reason);
        sendWorldText(message.length > 199 ? message[0 .. 199] : message);
        systemMessage(format!"You are being kicked from the server by %s. Reason: %s"(gmName, reason));
        kick(format!"kicked by %s: %s"(gmName, reason));
    }

    /// `.summon`'s part on the player.
    package void summonedBy(GmSink gm, string gmName, uint map, Position at, uint instance = uint.max)
    {
        if (transferring)
            return gm.system(format!"%s is already being teleported."(player.data.name));
        gm.system(format!"You are summoning %s."(player.data.name));
        systemMessage(format!"You are being summoned by %s."(gmName));
        commandTeleport(map, at, instance);
    }

    /// `.appear`'s part on the player: where it is, for `goThere` to take the GM.
    package void appearedToBy(GmSink gm, string gmName,
        scope void delegate(uint map, Position at, uint instance) goThere)
    {
        if (transferring)
            return gm.system(format!"%s is already being teleported."(player.data.name));
        gm.system(format!"Appearing at %s's location."(player.data.name));
        systemMessage(format!"%s is appearing to your location."(gmName));
        goThere(player.data.map, player.position, instanceId_);
    }

    /// `World::DisconnectUsersWithPlayerName`'s part on the session.
    package void disconnectedBy(GmSink gm, string gmName)
    {
        gm.system(format!"Disconnecting user with account `%s` IP `%s` Player `%s`."(account.username, address,
            player is null ? "noplayer" : player.data.name));
        kick(format!"disconnected by %s"(gmName));
    }

    /// `.ban character`'s part on the player, once its account is banned.
    package void bannedBy(GmSink gm, string gmName)
    {
        gm.system(format!"Kicking %s."(player.data.name));
        kick(format!"banned by %s"(gmName));
    }

    /// `.rename`'s part on the player, once the database has the new name.
    package void renamedBy(GmSink gm, string gmName, string newName)
    {
        const oldName = player.data.name;
        player.data.name = newName;
        context.renamed(this, oldName);
        blueSystemMessage(format!"%s changed your name to '%s'."(gmName, newName));
        savePlayer();
    }

    /// `.playerinfo`: who the player is, for the GM.
    package void describeTo(GmSink gm)
    {
        static immutable string[12] classes = ["None", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "None",
            "Shaman", "Mage", "Warlock", "None", "Druid"];
        static immutable string[12] races = ["None", "Human", "Orc", "Dwarf", "Night Elf", "Undead", "Tauren", "Gnome",
            "Troll", "None", "Blood Elf", "Draenei"];
        const p = player;
        const progress = p.progress(secondsInWorld());
        const female = p.data.gender != 0;
        gm.green(format!"%s is a %s %s %s"(p.data.name, female ? "Female" : "Male",
            races[p.data.race < races.length ? p.data.race : 0],
            classes[p.data.classId < classes.length ? p.data.classId : 0]));
        gm.blue(format!"%s has played %s at this level"(female ? "She" : "He", playedText(progress.levelTime)));
        gm.blue(format!"and %s overall"(playedText(progress.totalTime)));
        gm.blue(format!"%s is connecting from account '%s'[%u] with permissions '%s'"(female ? "She" : "He",
            account.username, account.id, permissions));
        gm.blue(format!"%s uses %s (build %u)"(female ? "She" : "He", "WoW", build));
        gm.blue(format!"%s IP is '%s', and has a latency of %ums"(female ? "Her" : "His", address, latencyMs));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * GM commands naming a player another node simulates (phase 5b): sent there; there, done to the
 * player, the GM told through its sink; and world texts reaching the other nodes.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.cluster.protocol : GmRemote, PresenceEntry;
    import dmangos.world.context : PresenceFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.session : WorldSession, WorldState;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    GmRemote[] sent;
    ushort sentTo;
    context.gmRemote = (ushort node, const ref GmRemote m) { sentTo = node; sent ~= m; };
    ushort[] elsewhere;
    context.toEveryoneElsewhere = (ushort opcode, char, const(ubyte)[]) { elsewhere ~= opcode; };
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.administrator);
    gm.read();
    context.presence(2, true, [PresenceEntry(0x55, "Faraway", 5, 1, 1, 10, 0, 12, 0, 0, ""),
        PresenceEntry(0x56, "Keeper", 6, 1, 1, 60, 0, 12, PresenceFlags.permissions | PresenceFlags.gmTag, 3, "",
        "az")], null);

    // `.summon` and `.kickplayer` name a player of node 2: the command goes there, with the GM's place.
    gm.say(".summon faraway");
    assert(sentTo == 2 && sent[$ - 1].op == GmRemoteOp.summon && sent[$ - 1].target == 0x55);
    assert(sent[$ - 1].map == gm.session.character.data.map && sent[$ - 1].gmName == "Jaina");
    gm.say(".kickplayer Faraway spamming");
    assert(sent[$ - 1].op == GmRemoteOp.kick && sent[$ - 1].text == "spamming" && sent[$ - 1].gmCanKickGms);

    // `.server saveall` and `.admin masssummon` go to every other node, which run them for their players.
    gm.read();
    gm.say(".server saveall");
    assert(sent[$ - 1].op == GmRemoteOp.saveAll && sentTo == 2);
    assert(systemMessages(gm.read()).canFind!(m => m.canFind("Saved all 3 online players")), "1 here, 2 on node 2");
    gm.say(".admin masssummon");
    assert(sent[$ - 1].op == GmRemoteOp.massSummon && sent[$ - 1].text.length);

    // `.gm list` names node 2's GM, as presence says; the kick message went to every node.
    gm.read();
    gm.say(".gm list");
    assert(systemMessages(gm.read()).canFind(" - Keeper [az]"));

    // On the target's node: summoned, the GM told through its sink.
    auto target = loggedIn(context, db, 10, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    target.read();
    string[] told;
    auto sink = GmSink((string text) { told ~= text; });
    GmRemote summon;
    summon.op = GmRemoteOp.summon;
    summon.gmName = "Jaina";
    summon.map = 0;
    summon.x = -8945;
    summon.y = -130;
    summon.z = 83.5f;
    target.session.gmTargeted(summon, sink, (GmRemote) {});
    assert(told == ["You are summoning Anduin."]);
    assert(systemMessages(target.read()) == ["You are being summoned by Jaina."]);

    // A mass summons from another node's GM: asked to its place.
    GmRemote mass;
    mass.op = GmRemoteOp.massSummon;
    mass.gm = 9;
    mass.text = "12";
    mass.x = -8945;
    target.session.gmTargeted(mass, sink, (GmRemote) {});
    assert(opcodesOf(target.read()) == [Opcode.SMSG_SUMMON_REQUEST]);

    // `.appear`: the target's place goes back to the GM's node.
    GmRemote appear;
    appear.op = GmRemoteOp.appear;
    appear.gm = 9;
    appear.gmName = "Jaina";
    GmRemote back;
    target.session.gmTargeted(appear, sink, (GmRemote m) { back = m; });
    assert(back.op == GmRemoteOp.appearAt && back.target == 9 && back.map == target.session.character.data.map);

    // A kick: the world text goes everywhere, and the player goes.
    GmRemote kick;
    kick.op = GmRemoteOp.kick;
    kick.gmName = "Jaina";
    kick.text = "testing";
    elsewhere = null;
    target.session.gmTargeted(kick, sink, (GmRemote) {});
    assert(elsewhere == [Opcode.SMSG_MESSAGECHAT] && target.session.state != WorldState.inWorld);
}
