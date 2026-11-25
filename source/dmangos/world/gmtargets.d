/**
 * What the GM commands that name a player do to that player, as methods of the player's
 * `Character` (mixed in), so that they run where the player is simulated: on this node, or in a
 * cluster on another (docs/CLUSTER.md), the GM's messages then going back to its node.
 * The GM's side (finding the player, logging) stays in the command handlers.
 */
module dmangos.world.gmtargets;

public import dmangos.cluster.protocol : GmRemoteOp; // a cluster message's field

import dmangos.world.chatstyle : ChatColor, colored, systemChatText;

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

/// Where a GM command's messages go: the GM's client, here or on its node (in the command colours).
struct GmSink
{
    void delegate(string text) send;

    /// A plain system message.
    void system(string text)
    {
        send(systemChatText(text));
    }

    /// A system message in `color`.
    void colored(ChatColor color, string text)
    {
        send(systemChatText(text, color));
    }

    void red(string text) { colored(ChatColor.softRed, text); }   /// An error or refusal.
    void green(string text) { colored(ChatColor.green, text); }   /// A change made.
    void blue(string text) { colored(ChatColor.sky, text); }      /// A notice.
}

/// See the module documentation.
mixin template GmTargets()
{
    import std.conv : ConvException, to;
    import std.format : format;
    import dmangos.cluster.protocol : GmRemote;
    import dmangos.world.chatstyle : ChatColor, colored;
    import dmangos.world.gmtargets : GmRemoteOp, GmSink;
    import dmangos.world.movement : Position;
    import dmangos.world.player : DeathState;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    /// This GM's messages, for the target-side methods when the target is here.
    package GmSink gmSink()
    {
        return GmSink(&systemMessage);
    }

    /// `op` from this GM, with its map and position (for a summons), for another node.
    private GmRemote gmOrder(GmRemoteOp op, string text)
    {
        GmRemote order;
        order.op = op;
        order.gm = player.guid;
        order.gmName = player.data.name;
        order.gmCanKickGms = allowsStaff("staff.admin");
        order.map = player.data.map;
        order.instance = instanceId_;
        const at = player.position;
        order.x = at.x;
        order.y = at.y;
        order.z = at.z;
        order.orientation = at.orientation;
        order.text = text;
        return order;
    }

    /// Sends `op` to the node simulating `name`, if another node does; false if none.
    package bool gmElsewhere(string name, GmRemoteOp op, string text = null)
    {
        if (context.gmRemote is null)
            return false;
        const remote = context.remotePlayer(name);
        if (remote is null)
            return false;
        auto order = gmOrder(op, text);
        order.target = remote.entry.guid;
        context.gmRemote(remote.node, order);
        return true;
    }

    /// A GM's command from another node for this player: done here, the GM told through `gm`; `reply`
    /// sends a command back to the GM's node (`appearAt`).
    package void gmTargeted(const ref GmRemote order, GmSink gm, void delegate(GmRemote) reply)
    {
        const at = Position(order.x, order.y, order.z, order.orientation);
        final switch (order.op) // the deserializer refused any other value
        {
        case GmRemoteOp.kick:
            return kickedBy(gm, order.gmName, order.gmCanKickGms, order.text);
        case GmRemoteOp.summon:
            return summonedBy(gm, order.gmName, order.map, at, order.instance);
        case GmRemoteOp.appear:
            return appearedToBy(gm, order.gmName, (uint map, Position there, uint instance) {
                GmRemote back;
                back.instance = instance;
                back.op = GmRemoteOp.appearAt;
                back.gm = order.gm;
                back.target = order.gm;
                back.map = map;
                back.x = there.x;
                back.y = there.y;
                back.z = there.z;
                back.orientation = there.orientation;
                reply(back);
            });
        case GmRemoteOp.appearAt:
            commandTeleport(order.map, at, order.instance);
            return;
        case GmRemoteOp.disconnect:
            return disconnectedBy(gm, order.gmName);
        case GmRemoteOp.banKick:
            return bannedBy(gm, order.gmName);
        case GmRemoteOp.rename:
            return renamedBy(gm, order.gmName, order.text);
        case GmRemoteOp.playerInfo:
            return describeTo(gm);
        case GmRemoteOp.kill:
            return killedByName(gm, order.gmName, order.text);
        case GmRemoteOp.revive:
            return revivedByName(gm, order.text);
        case GmRemoteOp.saveAll:
            return savePlayer();
        case GmRemoteOp.instanceInfo, GmRemoteOp.instanceShutdown, GmRemoteOp.instanceReset,
            GmRemoteOp.instanceResetAll:
            return; // the node's, not a player's (`ClusterBridge.gmRemote`)
        case GmRemoteOp.massSummon:
            uint zone;
            try
                zone = order.text.to!uint;
            catch (ConvException) {}
            return summonRequest(order.gm, zone, order.map, at);
        }
    }

    /// `op` for every other node of a cluster (`everywhere`), with this GM's place; how many nodes it went to.
    package size_t gmEverywhere(GmRemoteOp op, string text = null)
    {
        if (context.gmRemote is null)
            return 0;
        const order = gmOrder(op, text);
        const nodes = context.otherNodes();
        foreach (node; nodes)
            context.gmRemote(node, order);
        return nodes.length;
    }

    /// `.kill`'s part on a player: health 0, and it dies; it is told who did it.
    package void killedByGm(string gmName)
    {
        if (player.deathState != DeathState.alive)
            return;
        player.values.set!UNIT_FIELD_HEALTH(0u);
        playerDied(false);
        blueSystemMessage(format!"%s killed you with a GM command."(gmName));
    }

    /// `.killplr`'s part on the player (`name`: its name as the GM typed it).
    package void killedByName(GmSink gm, string gmName, string name)
    {
        if (player.deathState != DeathState.alive)
            return gm.red(format!"Player %s is already dead."(name));
        player.values.set!UNIT_FIELD_HEALTH(0u);
        playerDied(false);
        blueSystemMessage(format!"You were killed by %s with a GM command."(gmName));
        gm.green(format!"Killed player %s."(name));
    }

    /// `.reviveplr`'s part on the player (`name`: its name as the GM typed it): `remoteRevive`.
    package void revivedByName(GmSink gm, string name)
    {
        if (player.deathState == DeathState.alive)
            return gm.green(format!"Player %s is not dead."(name));
        remoteRevive();
        gm.green(format!"Revived player %s."(name));
    }

    /// Resurrected, unrooted, with full health; its corpse turns to bones.
    package void remoteRevive()
    {
        bringBack(1);
        spawnCorpseBones();
        player.values.set!UNIT_FIELD_HEALTH(player.values.get!UNIT_FIELD_MAXHEALTH);
        flushPlayerChanges();
    }

    /// `.kick`'s part on the player: administrators may only be kicked by other administrators.
    package void kickedBy(GmSink gm, string gmName, bool gmCanKickGms, string reason)
    {
        const name = player.data.name;
        gm.blue(format!"Attempting to kick %s from the server for \"%s\"."(name, reason));
        if (!gmCanKickGms && allowsStaff("staff.admin"))
            return gm.red(format!"You cannot kick %s, as they are a higher level gm than you."(name));
        const message = format!"GM: %s was kicked from the server by %s. Reason: %s"(name, gmName, reason);
        sendWorldText(colored(ChatColor.red, message.length > 187 ? message[0 .. 187] : message));
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

    /// `.kill`-by-name's part on the session: the player is disconnected.
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
        const data = player.data;
        const progress = player.progress(secondsInWorld());
        const female = data.gender != 0;
        const pronoun = female ? "She" : "He";
        gm.green(format!"%s is a %s %s %s"(data.name, female ? "Female" : "Male",
            races[data.race < races.length ? data.race : 0],
            classes[data.classId < classes.length ? data.classId : 0]));
        gm.blue(format!"%s has played %s at this level"(pronoun, playedText(progress.levelTime)));
        gm.blue(format!"and %s overall"(playedText(progress.totalTime)));
        gm.blue(format!"%s is connecting from account '%s'[%u] with permissions '%s'"(pronoun, account.username,
            account.id, staffRoles));
        gm.blue(format!"%s uses %s (build %u)"(pronoun, "WoW", build));
        gm.blue(format!"%s IP is '%s', and has a latency of %ums"(female ? "Her" : "His", address, latencyMs));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * GM commands naming a player another node simulates: sent there; there, done to the
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
    import dmangos.world.character : Character;
    import dmangos.world.session : WorldState;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    GmRemote[] sent;
    ushort sentTo;
    context.gmRemote = (ushort node, const ref GmRemote m) { sentTo = node; sent ~= m; };
    ushort[] elsewhere;
    context.toEveryoneElsewhere = (ushort opcode, bool, const(ubyte)[]) { elsewhere ~= opcode; };
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.administrator);
    gm.read();
    context.presence(2, true, [PresenceEntry(0x55, "Faraway", 5, 1, 1, 10, 0, 12, 0, 0, ""),
        PresenceEntry(0x56, "Keeper", 6, 1, 1, 60, 0, 12, PresenceFlags.staff | PresenceFlags.gmTag, 3, "",
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
    target.session.inWorld.gmTargeted(summon, sink, (GmRemote) {});
    assert(told == ["You are summoning Anduin."]);
    assert(systemMessages(target.read()) == ["You are being summoned by Jaina."]);

    // A mass summons from another node's GM: asked to its place.
    GmRemote mass;
    mass.op = GmRemoteOp.massSummon;
    mass.gm = 9;
    mass.text = "12";
    mass.x = -8945;
    target.session.inWorld.gmTargeted(mass, sink, (GmRemote) {});
    assert(opcodesOf(target.read()) == [Opcode.SMSG_SUMMON_REQUEST]);

    // `.appear`: the target's place goes back to the GM's node.
    GmRemote appear;
    appear.op = GmRemoteOp.appear;
    appear.gm = 9;
    appear.gmName = "Jaina";
    GmRemote back;
    target.session.inWorld.gmTargeted(appear, sink, (GmRemote m) { back = m; });
    assert(back.op == GmRemoteOp.appearAt && back.target == 9 && back.map == target.session.character.data.map);

    // A kick: the world text goes everywhere, and the player goes.
    GmRemote kick;
    kick.op = GmRemoteOp.kick;
    kick.gmName = "Jaina";
    kick.text = "testing";
    elsewhere = null;
    target.session.inWorld.gmTargeted(kick, sink, (GmRemote) {});
    assert(elsewhere == [Opcode.SMSG_MESSAGECHAT] && target.session.state != WorldState.inWorld);
}
