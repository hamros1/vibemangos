/// Account administration, server operations, and shared character management.
module dmangos.world.gmadmin;

import core.time : MonoTime;

/// The number `text` starts with, read as `atoi` reads it (at most nine digits); 0 if none.
package uint numberAtStart(const(char)[] text) pure nothrow @nogc @safe
{
    import std.ascii : isDigit;

    uint number;
    foreach (c; text[0 .. text.length < 9 ? text.length : 9])
    {
        if (!c.isDigit)
            break;
        number = number * 10 + (c - '0');
    }
    return number;
}

///
unittest
{
    assert(numberAtStart("95900 rest") == 95_900 && numberAtStart("x1") == 0 && numberAtStart("") == 0);
    assert(numberAtStart("1234567890") == 123_456_789);
}

/// The milliseconds since `started`, for the commands that say how long they took.
package long msecsSince(MonoTime started)
{
    return (MonoTime.currTime - started).total!"msecs";
}

/// See the module documentation.
mixin template AdminCommands()
{
    import core.time : MonoTime, seconds;
    import std.algorithm.comparison : clamp, min;
    import std.algorithm.searching : canFind, endsWith, findSplitBefore;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import std.string : capitalize, indexOf;
    import std.uni : sicmp, toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log : error, info, warning;
    import dmangos.script.api : EntityRef;
    import dmangos.world.commands : ChatColor, colored, dateTimeString, durationString,
        ctimeString, parseDuration, isIPv4Address, Nullable, Rest, secondsPerDay, secondsPerHour, secondsPerMinute;
    import dmangos.world.context : ShutdownTimer;
    import dmangos.world.database : LookupResult, LookupTable;
    import dmangos.world.gmadmin : msecsSince, numberAtStart;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : Position;
    import dmangos.world.names : normalizedName;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ServerPlaySound, ServerSummonRequest;
    import dmangos.world.player : DeathState;
    import dmangos.world.playercreate : NewCharacter;
    import dmangos.world.spells : SpellEffect;
    import dmangos.world.updatefields;

private:
    /// `.pet addspell <spell>`: the selected player's pet learns a spell.
    bool handleAddPetSpellCommand(uint spell)
    {
        return petSpellCommand(spell, true);
    }

    /// `.pet removespell <spell>`: the selected player's pet forgets a spell.
    bool handleRemovePetSpellCommand(uint spell)
    {
        return petSpellCommand(spell, false);
    }

    /// The selected player's pet learns (`teach`) or forgets a spell.
    bool petSpellCommand(uint spell, bool teach)
    {
        auto target = selectedCharacter(false);
        if (target is null)
            return false;
        if (target.ownPet is null)
        {
            redSystemMessage(format!"%s has no pet."(target.player.data.name));
            return true;
        }
        if (context.data.spells.spell(spell) is null)
        {
            redSystemMessage(format!"Unknown spell ID %s."(spell));
            return true;
        }
        target.petLearnsSpell(spell, teach);
        greenSystemMessage(format!"%s's pet %s spell %s."(target.player.data.name, teach ? "learned" : "forgot",
            spell));
        return true;
    }

    /// `.pet renamepet <name>`: the player's own pet is renamed.
    bool handleRenamePetCommand(Rest name = Rest.init)
    {
        if (ownPet is null)
        {
            redSystemMessage("You have no pet.");
            return true;
        }
        if (name.length < 1)
        {
            redSystemMessage("You must specify a name.");
            return true;
        }
        greenSystemMessage(format!"Renamed your pet to %s."(name.text));
        renamePetTo(name.text);
        return true;
    }

    /// `.modify level <level>`: the selected player's level.
    bool handleModifyLevelCommand(uint level = 0)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        if (level == 0 || level > context.config.maxPlayerLevel)
        {
            redSystemMessage("Enter a level within the server’s level range.");
            return true;
        }
        blueSystemMessage(format!"Setting the level of %s to %u."(target.player.data.name, level));
        target.greenSystemMessage(format!"%s set your level to %u."(player.data.name, level));
        gmLog(format!"used modify level on %s, level %u"(target.player.data.name, level));
        target.applyLevel(level);
        return true;
    }

    /// `.modify gender [0|1]`: the selected player's gender, and its model with it; toggled if none is given.
    bool handleGenderChangeCommand(Nullable!int requested)
    {
        auto found = context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET);
        if (found is null)
        {
            redSystemMessage("Select a player first.");
            return true;
        }
        auto target = sessionOf(found);
        auto character = target.player;
        const displayId = character.values.get!UNIT_FIELD_NATIVEDISPLAYID;
        const uint gender = requested.isNull ? (character.data.gender == 1 ? 0 : 1) : clamp(requested.get, 0, 1);
        character.data.gender = cast(ubyte) gender;
        character.values.setByte!UNIT_FIELD_BYTES_0(2, cast(ubyte) gender);
        character.values.setHalf!PLAYER_BYTES_3(0, cast(ushort) gender);
        // A race's female model id follows its male one.
        const display = gender == 0 ? displayId - 1 : displayId + 1;
        character.values.set!UNIT_FIELD_DISPLAYID(display);
        character.values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        target.flushPlayerChanges();
        greenSystemMessage(format!"Set %s's gender to %s(%u)."(character.data.name, gender ? "Female" : "Male",
            gender));
        return true;
    }

    /// `.scourge [status|start|stop]`: the Scourge Invasion's state, or it started or stopped.
    bool handleScourgeCommand(string action = "status")
    {
        import dmangos.world.scourge : InvasionHost, InvasionControl;

        switch (action)
        {
        case "status":
            systemMessage(format!"Scourge Invasion %s. Zones defended: %s."(
                context.invasion.running ? "active" : "inactive", context.invasion.victories));
            return true;
        case "start", "stop":
            context.services.call!(InvasionHost.control)(InvasionControl(action == "start"));
            return true;
        default:
            return false;
        }
    }

    /// `.worldport <map> <x> <y> <z>`: a teleport to coordinates inside the map grid.
    bool handleWorldPortCommand(uint mapId, float x, float y, float z)
    {
        import std.math : fabs;

        enum float gridEdge = 17_066.666f;
        if (fabs(x) >= gridEdge || fabs(y) >= gridEdge)
            return false;
        commandTeleport(mapId, Position(x, y, z, 0));
        return true;
    }

    /// `.levelup [levels]`: the selected player (or the GM) up some levels, at most to the server's cap.
    bool handleLevelUpCommand(int levels = 1)
    {
        if (levels <= 0)
            return false;
        auto target = selectedCharacter(true);
        if (target is null)
            target = this;
        gmLog(format!"used level up command on %s, with %u levels"(target.player.data.name, levels));
        const level = min(levels + target.player.data.level, context.config.maxPlayerLevel);
        target.applyLevel(level);
        target.greenSystemMessage(format!"You have been leveled up to Level %d"(level));
        return true;
    }

    /// A played time as "[d days, h hours, m minutes, s seconds]".
    static string playedText(uint seconds)
    {
        return format!"[%d days, %d hours, %d minutes, %d seconds]"(seconds / secondsPerDay, seconds / secondsPerHour % 24,
            seconds / secondsPerMinute % 60, seconds % 60);
    }

    /// `.playerinfo [name]`: what is known of the named player (on any node), or of the selected one.
    bool handlePlayerInfoCommand(Rest name = Rest.init)
    {
        if (name.length < 2) // a name has two letters at least
        {
            if (auto target = selectedCharacter(true))
                target.describeTo(gmSink);
            return true;
        }
        auto found = context.onlinePlayer(name);
        if (found !is null)
            sessionOf(found).describeTo(gmSink);
        else if (!gmElsewhere(name, GmRemoteOp.playerInfo))
            redSystemMessage(format!"Unable to locate player %s."(name));
        return true;
    }

    /// `.revive`: the selected player alive, with full health, mana and energy, and unrooted.
    bool handleReviveCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        target.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        if (target.player.deathState != DeathState.alive)
        {
            target.bringBack(1);
            target.spawnCorpseBones();
        }
        auto values = &target.player.values;
        values.set!UNIT_FIELD_HEALTH(values.get!UNIT_FIELD_MAXHEALTH);
        values.set!UNIT_FIELD_POWER1(values.get!UNIT_FIELD_MAXPOWER1);
        values.set!UNIT_FIELD_POWER4(values.get!UNIT_FIELD_MAXPOWER4);
        target.flushPlayerChanges();
        if (target !is this)
            gmLog("revived player " ~ target.player.data.name);
        return true;
    }

    /// The selected player, on this map, or null after "Invalid target.".
    Character selectedPlayerUnit()
    {
        auto target = cast(Character) map.find(player.values.get!UNIT_FIELD_TARGET);
        if (target is null)
            redSystemMessage("Invalid target.");
        return target;
    }

    /// `.paralyze`: the selected player rooted.
    bool handleParalyzeCommand()
    {
        return rootSelectedPlayer(true);
    }

    /// `.unparalyze`: the selected player free to move again.
    bool handleUnParalyzeCommand()
    {
        return rootSelectedPlayer(false);
    }

    /// The selected player rooted (`root`) or unrooted, and told by whom.
    bool rootSelectedPlayer(bool root)
    {
        auto target = selectedPlayerUnit();
        if (target is null)
            return true;
        const done = root ? "rooted" : "unrooted";
        blueSystemMessage(root ? "Rooting target." : "Unrooting target.");
        target.blueSystemMessage(format!"You have been %s by %s."(done, player.data.name));
        gmLog(format!"%s player %s"(done, target.player.data.name));
        if (root)
            target.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        else
            target.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        return true;
    }

    // -----------------------------------------------------------------------
    // Accounts
    // -----------------------------------------------------------------------

    /// The connection of the account named `name` (in the world or at the character screen), in any case, or
    /// null.
    WorldSession connectionOfAccountName(string name)
    {
        const found = context.accounts.findAccount(name);
        return found.isNull ? null : cast(WorldSession) context.sessionOfAccount(found.get.id);
    }

    /// ditto: its character, if it is in the world here.
    Character sessionOfAccountName(string name)
    {
        auto connection = connectionOfAccountName(name);
        return connection is null ? null : connection.inWorld;
    }

    /// `.account mute <account> <duration>`: the account cannot speak until then.
    bool handleAccountMuteCommand(string name, string duration)
    {
        const period = parseDuration(duration);
        if (period <= 0)
            return false;
        const until = context.unixTime + period;
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.database.setMuteTime(found.get.id, until);
        const text = dateTimeString(until);
        greenSystemMessage(format!"Account '%s' has been muted until %s. The change will be effective immediately."(
            name, text));
        gmLog(format!"muted account %s until %s"(name, text));
        if (auto session = sessionOfAccountName(name))
        {
            session.account.muteTime = until;
            session.systemMessage(format!("Your voice has been muted until %s by a GM. Until this time, you will not "
                ~ "be able to speak in any form.")(text));
        }
        return true;
    }

    /// `.account unmute <account>`.
    bool handleAccountUnmuteCommand(string name)
    {
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.database.setMuteTime(found.get.id, 0);
        greenSystemMessage(format!"Account '%s' has been unmuted."(name));
        gmLog("unmuted account " ~ name);
        if (auto session = sessionOfAccountName(name))
        {
            session.account.muteTime = 0;
            session.systemMessage("Your voice has restored. You may speak again.");
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Disconnecting
    // -----------------------------------------------------------------------

    /// Closes a session (an account at its character screen too), saying whose.
    void disconnect(WorldSession connection)
    {
        const name = connection.character is null ? "noplayer" : connection.character.data.name;
        gmSink.system(format!"Disconnecting user with account `%s` IP `%s` Player `%s`."(connection.account.username,
            connection.address, name));
        connection.kick(format!"disconnected by %s"(player.data.name));
    }

    /// Disconnects every session from `ip`.
    void disconnectUsersWithIP(string ip)
    {
        auto sessions = context.sessionsFrom(ip);
        foreach (session; sessions)
            if (auto connection = cast(WorldSession) session)
                disconnect(connection);
        if (sessions.length == 0)
            redSystemMessage(format!"There is nobody online with ip [%s]"(ip));
    }

    /// Disconnects the session of the account named `account`.
    void disconnectUsersWithAccount(string account)
    {
        if (auto connection = connectionOfAccountName(account))
            disconnect(connection);
        else
            redSystemMessage(format!"There is nobody online with account [%s]"(account));
    }

    /// `.kick byplayer <name>`: the named player's session closed, on any node.
    bool handleKillByPlayerCommand(Rest name = Rest.init)
    {
        if (name.length < 2)
        {
            redSystemMessage("A player's name is required.");
            return true;
        }
        if (auto found = context.onlinePlayer(name))
            disconnect(sessionOf(found).connection);
        else if (!gmElsewhere(name, GmRemoteOp.disconnect))
            redSystemMessage(format!"There is nobody online with the name [%s]"(name));
        gmLog("disconnected player " ~ name);
        return true;
    }

    /// `.kick byaccount <account>`: the account's session closed.
    bool handleKillBySessionCommand(Rest account = Rest.init)
    {
        if (account.length < 2)
        {
            redSystemMessage("A player's name is required.");
            return true;
        }
        disconnectUsersWithAccount(account);
        gmLog("disconnected player with account " ~ account);
        return true;
    }

    /// `.kick byip <address>`: every session from the address closed.
    bool handleKillByIpCommand(Rest ip = Rest.init)
    {
        if (ip.length < 2)
        {
            redSystemMessage("An IP is required.");
            return true;
        }
        disconnectUsersWithIP(ip);
        gmLog("disconnected players with IP " ~ ip);
        return true;
    }

    // -----------------------------------------------------------------------
    // Bans
    // -----------------------------------------------------------------------

    /// `ip` with its CIDR prefix length: "/32" (the one address) when it has none, which the GM is told.
    string withPrefixLength(string ip)
    {
        if (ip.canFind('/'))
            return ip;
        systemMessage("Lack of CIDR address assumes a 32bit match (if you don't understand, don't worry, it worked)");
        return ip ~ "/32";
    }

    /// `.ban ip <address[/bits]> <duration> [reason]`: the address banned, and its sessions closed.
    bool handleIpBanCommand(string ip, string duration, Rest reason = Rest.init)
    {
        const period = parseDuration(duration);
        if (period < 1)
            return false;
        if (!isIPv4Address(ip.findSplitBefore("/")[0]))
        {
            redSystemMessage(format!"Invalid IPv4 address [%s]"(ip));
            return true;
        }
        const expires = ctimeString(context.unixTime + period);
        const range = withPrefixLength(ip);
        greenSystemMessage(format!"Adding [%s] to IP ban table, expires %s.Reason is :%s"(range, expires, reason));
        const address = range[0 .. range.indexOf('/')];
        context.accounts.banIp(range.endsWith("/32") ? address : range, period, player.data.name, reason);
        disconnectUsersWithIP(address);
        gmLog(format!"banned ip address %s, expires %s"(range, expires));
        return true;
    }

    /// `.ban character <name> <duration> <reason>`: the character's account banned, announced to the world.
    bool handleBanCharacterCommand(string name, string duration, Rest reason)
    {
        const period = parseDuration(duration);
        if (period < 1)
            return false;

        auto online = context.onlinePlayer(name);
        const elsewhere = online is null ? context.remotePlayer(name) : null;
        uint accountId;
        if (online !is null)
        {
            accountId = sessionOf(online).account.id;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        else if (elsewhere !is null)
        {
            accountId = elsewhere.entry.account;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        else
        {
            const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
            if (owner.isNull)
            {
                redSystemMessage("Player not found.");
                return true;
            }
            accountId = owner.get.account;
            systemMessage(format!"Banning player '%s' in database for '%s'."(name, reason));
        }
        if (!outranksAccount(accountId))
        {
            redSystemMessage(format!"You cannot ban %s, as they are a staff member of your rank or higher."(name));
            return true;
        }
        context.accounts.banAccount(accountId, period, player.data.name, reason);
        systemMessage(format!"This ban is due to expire on %s."(dateTimeString(context.unixTime + period)));
        if (online !is null)
            sessionOf(online).bannedBy(gmSink, player.data.name);
        else if (elsewhere !is null)
            gmElsewhere(name, GmRemoteOp.banKick);
        const length = durationString(period);
        gmLog(format!"banned %s, reason %s, for %s"(name, reason, length));
        const message = format!"GM: %s has been banned by %s for %s. Reason: %s"(name, player.data.name, length,
            reason);
        sendWorldText(colored(ChatColor.red, message[0 .. min($, 187)]));
        return true;
    }

    /// Whether this GM may ban `accountId`: its staff rank is below theirs. A failed policy read never is.
    bool outranksAccount(uint accountId)
    {
        import dmangos.mysql : DatabaseException;

        try
            return context.database.gmAccessFor(accountId).rank() < security;
        catch (DatabaseException)
            return false;
    }

    /// `.ban account <account> <duration> [reason]`: banned (for ever with a zero duration), and disconnected.
    bool handleAccountBannedCommand(string name, string duration, Rest reason = Rest.init)
    {
        const period = parseDuration(duration);
        if (period < 0)
            return false;
        const found = context.accounts.findAccount(name);
        if (!found.isNull && !outranksAccount(found.get.id))
        {
            redSystemMessage(format!"You cannot ban %s, as they are a staff member of your rank or higher."(name));
            return true;
        }
        if (!found.isNull)
            context.accounts.banAccount(found.get.id, period, player.data.name, reason);
        const until = period ? dateTimeString(context.unixTime + period) : "";
        greenSystemMessage(format!("Account '%s' has been banned %s%s for reason : %s. The change will be effective "
            ~ "immediately.")(name, period ? "until " : "forever", until, reason));
        disconnectUsersWithAccount(name);
        gmLog(format!"banned account %s %s"(name, period ? "until " ~ until : "permanently"));
        return true;
    }

    /// `.unban ip <address[/bits]>`.
    bool handleIpUnbanCommand(string ip)
    {
        const range = withPrefixLength(ip);
        greenSystemMessage(format!"Deleting [%s] from ip ban table if it exists"(range));
        context.accounts.unbanIp(range.endsWith("/32") ? range[0 .. $ - 3] : range);
        gmLog("unbanned ip address " ~ range);
        return true;
    }

    /// `.unban character <name>`: the character's account unbanned.
    bool handleUnBanCharacterCommand(string name)
    {
        if (auto online = context.onlinePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(online.character.data.name));
        else if (const remote = context.remotePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(remote.entry.name));
        else
            systemMessage(format!"Player %s not found ingame."(name));
        const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
        if (!owner.isNull)
            context.accounts.unbanAccount(owner.get.account, player.data.name);
        greenSystemMessage(format!"Unbanned character %s in database."(name));
        gmLog("unbanned " ~ name);
        return true;
    }

    /// `.unban account <account>`.
    bool handleAccountUnbanCommand(string name)
    {
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.accounts.unbanAccount(found.get.id, player.data.name);
        greenSystemMessage(format!"Account '%s' has been unbanned. This change will be effective immediately."(name));
        gmLog("unbanned account " ~ name);
        return true;
    }

    // -----------------------------------------------------------------------
    // The server
    // -----------------------------------------------------------------------

    /// `.server setmotd <message>`: the message of the day.
    bool handleSetMotdCommand(Rest motd = Rest.init)
    {
        if (motd.length < 2)
        {
            redSystemMessage("You must specify a message.");
            return true;
        }
        greenSystemMessage("Motd has been set to: " ~ motd);
        context.config.motd = motd;
        gmLog("Set MOTD to " ~ motd);
        return true;
    }

    /// `.server rehash`: the configuration file read again.
    bool handleRehashCommand()
    {
        import dmangos.world.config : loadWorldConfig;

        const message = format!"%s is rehashing config file."(player.data.name);
        sendWorldWideScreenText(message);
        sendWorldText(message);
        if (context.configPath.length == 0)
            return true;
        try
        {
            // Settings read when the server starts (databases, port, ...) keep their values until a restart.
            context.config = loadWorldConfig(context.configPath);
            info!"configuration %s read again"(context.configPath);
        }
        catch (Exception e)
            error!"cannot read the configuration again: %s"(e.msg);
        return true;
    }

    /// `.server reloadtable <table>`: a table this server keeps in memory read again (the teleports).
    bool handleDbReloadCommand(string table)
    {
        import dmangos.world.worldcatalog : WorldCatalog, WorldCatalogKey;

        context.settleWrites(); // what the GM commands wrote (spawns, vendors, ...) is read back
        if (table.length < 3)
            return false;
        const started = MonoTime.currTime;
        sendWorldText(colored(ChatColor.softRed,
            format!"%s started reloading table %s. The server may lag briefly."(player.data.name, table)));
        const reloaded = sicmp(table, "areatrigger_teleport") == 0 || sicmp(table, "game_tele") == 0;
        if (reloaded)
        {
            context.data.setTeleports(context.database.loadAreaTriggerTeleports(), context.database.loadTeleports(),
                context.client);
            if (context.config.cluster.nodeId)
                context.database.markWorldCatalogReload(WorldCatalogKey(WorldCatalog.teleports, 0));
            sendWorldText(colored(ChatColor.sky, format!"Database reload completed in %u ms."(msecsSince(started))));
        }
        else
            sendWorldText(colored(ChatColor.softRed, "Database reload failed."));
        gmLog("reloaded table " ~ table);
        return true;
    }

    /// Announces a shutdown or restart `delay` seconds away and starts it; the world update counts it down.
    void startShutdown(uint delay, bool restart)
    {
        const what = restart ? "restart" : "shutdown";
        sendWorldText(colored(ChatColor.sky, format!"%s scheduled a server %s in %u seconds."(player.data.name, what,
            delay)));
        gmLog(format!"initiated server %s timer %u sec"(what, delay));
        ShutdownTimer timer;
        timer.at = context.clock() + delay.seconds;
        timer.restart = restart;
        context.shutdown = timer;
        warning!"'%s' ordered a %s in %s seconds"(player.data.name, what, delay);
    }

    /// `.server shutdown [seconds]`: by default in the 5 seconds its help promises.
    bool handleShutdownCommand(uint delay = 5)
    {
        startShutdown(delay, false);
        return true;
    }

    /// `.server restart [seconds]`.
    bool handleShutdownRestartCommand(uint delay = 5)
    {
        startShutdown(delay, true);
        return true;
    }

    /// `.server cancelshutdown`: the shutdown or restart under way called off.
    bool handleCancelShutdownCommand()
    {
        if (context.shutdown.isNull)
            return false;
        sendWorldText(colored(ChatColor.sky, format!"%s cancelled the server %s."(player.data.name,
            context.shutdown.get.restart ? "restart" : "shutdown")));
        context.shutdown.nullify();
        return true;
    }

    // -----------------------------------------------------------------------
    // The admin group
    // -----------------------------------------------------------------------

    /// A summon offered with `SMSG_SUMMON_REQUEST`, and when it lapses.
    struct SummonOffer
    {
        uint map;
        Position position;
        MonoTime expires;
    }

    Nullable!SummonOffer summonOffer;

    /// `.admin masssummon`: every player, on every node, offered a summon to the GM.
    bool handleMassSummonCommand()
    {
        uint count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).summonRequest(player.guid, player.data.zone, player.data.map, player.position);
            ++count;
        }
        // Every other node of a cluster asks its own.
        if (gmEverywhere(GmRemoteOp.massSummon, format!"%u"(player.data.zone)))
            count += cast(uint) context.remotePlayers.length;
        gmLog(format!"requested a mass summon of %u players."(count));
        return true;
    }

    /// Offers the player a summon; it has two minutes to accept.
    void summonRequest(ulong summoner, uint zone, uint mapId, Position at)
    {
        enum offerSeconds = 120;
        summonOffer = SummonOffer(mapId, at, context.clock() + offerSeconds.seconds);
        send(ServerSummonRequest(summoner, zone, offerSeconds * 1000));
    }

    /// The player answered a summon offer (`CMSG_SUMMON_RESPONSE`, `dmangos.world.rituals`): whether it was this one.
    bool acceptGmSummonOffer()
    {
        if (summonOffer.isNull || context.clock() > summonOffer.get.expires)
            return false;
        const offer = summonOffer.get;
        summonOffer.nullify();
        commandTeleport(offer.map, offer.position);
        return true;
    }

    /// `.admin playall <sound>`: a sound played for every player here.
    bool handleGlobalPlaySoundCommand(uint sound)
    {
        if (sound == 0)
            return false;
        toEveryone(Opcode.SMSG_PLAY_SOUND, packetBody(ServerPlaySound(sound)));
        blueSystemMessage(format!"Broadcasted sound %u to server."(sound));
        gmLog(format!"used play all command soundid %u"(sound));
        return true;
    }

    // -----------------------------------------------------------------------
    // Cheats
    // -----------------------------------------------------------------------

    /// `.clearcooldowns`: the cooldowns of the selected player's (or the GM's) class spells cleared.
    bool handleClearCooldownsCommand()
    {
        const guid = cast(uint) player.values.get!UNIT_FIELD_TARGET;
        auto target = selectedCharacter(true);
        if (target is null)
        {
            target = this;
            systemMessage("Targeting yourself.");
        }
        if (target !is this)
            gmLog("Cleared all cooldowns for player " ~ target.player.data.name);
        // Each class's three skill lines (those of its talent trees), and its name.
        static immutable uint[3][12] treeLines = [[0, 0, 0], [26, 256, 257], [594, 267, 184], [50, 51, 163],
            [253, 38, 39], [56, 78, 613], [0, 0, 0], [373, 374, 375], [6, 8, 237], [355, 354, 593], [0, 0, 0],
            [573, 574, 134]];
        static immutable string[12] classNames = ["", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "",
            "Shaman", "Mage", "Warlock", "", "Druid"];
        const classId = target.player.data.classId;
        if (classId >= classNames.length || classNames[classId].length == 0)
            return true;
        foreach (line; treeLines[classId])
            target.clearCooldownsOnLine(line, guid);
        blueSystemMessage(format!"Cleared all %s cooldowns."(classNames[classId]));
        return true;
    }

    /// `.removeauras`: every aura but the passive ones taken off the selected player.
    bool handleRemoveAurasCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return false;
        blueSystemMessage("Removing all auras...");
        foreach (aura; target.player.auras.list.dup)
            if (!aura.passive)
                target.removeAura(aura);
        if (target !is this)
            gmLog(format!"Removed all of %s's auras."(target.player.data.name));
        return true;
    }

    /// `.character resettalents`.
    bool handleResetTalentsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        target.resetTalents();
        greenSystemMessage(format!"Reset talents of %s."(target.player.data.name));
        target.blueSystemMessage(format!"%s reset all your talents."(player.data.name));
        gmLog("reset talents of " ~ target.player.data.name);
        return true;
    }

    /// `.admin dispelall [1]`: every player here loses its negative auras, and its positive ones too with a number
    /// other than 0.
    bool handleDispelAllCommand(Rest args = Rest.init)
    {
        const positive = numberAtStart(args);
        gmLog(format!"used dispelall command, pos %u"(positive));
        // The players of this node (those on another node of a cluster keep theirs).
        foreach (other; context.onlinePlayers)
            sessionOf(other).dispelAll(positive != 0);
        gmLog("used mass dispel");
        blueSystemMessage("Dispel action done.");
        return true;
    }

    /// `.character increaseweaponskill [times]`: the skill of the weapon in hand (unarmed with none) advanced.
    bool handleIncreaseWeaponSkillCommand(uint times = 1)
    {
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotRanged;

        auto target = selectedCharacter(true);
        if (target is null)
            target = this;
        auto weapon = target.player.inventory.equipped(equipmentSlotMainhand);
        if (weapon is null)
            weapon = target.player.inventory.equipped(equipmentSlotRanged);
        uint skill;
        if (weapon !is null && weapon.proto !is null)
        {
            // Weapon subclasses to skill lines, oddities included (exotic ones count as staves).
            static immutable uint[21] bySubClass = [44, 172, 45, 46, 54, 160, 229, 43, 55, 136, 136, 0, 473, 0, 0,
                173, 176, 227, 226, 228, 356];
            if (weapon.proto.subClass < bySubClass.length)
                skill = bySubClass[weapon.proto.subClass];
        }
        else
            skill = 162; // unarmed
        if (skill == 0)
        {
            redSystemMessage("Unknown skill ID.");
            return false;
        }
        blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, times));
        gmLog(format!"increased weapon skill (%u) of %s by %u"(skill, target.player.data.name, times));
        const current = target.player.skillValue(skill);
        if (current[1] == 0)
        {
            systemMessage("The player does not know this skill. Adding it now.");
            target.applySkill(skill, 1, 300);
        }
        else // up to the maximum
            target.applySkill(skill, cast(ushort) min(current[0] + times, current[1]), current[1]);
        return true;
    }

    /// What a new character of `character`'s race, class and gender starts with, as character creation gives it.
    package static bool startingAbilities(typeof(this) character, out NewCharacter fresh)
    {
        import dmangos.world.playercreate : CharacterBuilder, CreateRequest;

        auto builder = new CharacterBuilder(character.context.data, character.context.client,
            character.context.creationSettings, () => 0u);
        const data = &character.player.data;
        CreateRequest request = {name: data.name, race: data.race, classId: data.classId, gender: data.gender};
        return builder.create(0, 0, AccountLevel.player, request, true, fresh);
    }

    /// `.character resetspells`: the selected player back to the spells a new character of its race and class has.
    bool handleResetSpellsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        NewCharacter fresh;
        if (startingAbilities(target, fresh))
        {
            foreach (spell; target.player.spells.dup)
                if (!fresh.spells.canFind!(known => known.spell == spell))
                    target.unlearn(spell);
            foreach (known; fresh.spells)
                if (known.active && !known.disabled)
                    target.learn(known.spell);
        }
        greenSystemMessage(format!"Reset spells of %s to level 1."(target.player.data.name));
        target.blueSystemMessage(format!"%s reset all your spells to starting values."(player.data.name));
        gmLog(format!"reset spells of %s"(target.player.data.name));
        return true;
    }

    /// `.character resetskills`: the selected player back to a new character's skills, with its level's caps.
    bool handleResetSkillsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        NewCharacter fresh;
        if (!startingAbilities(target, fresh))
            return true;
        foreach (skill; target.player.skillList())
            if (!fresh.skills.canFind!(known => known.skill == skill[0]))
                target.applySkill(skill[0], 0, 0);
        foreach (known; fresh.skills)
            target.applySkill(known.skill, cast(ushort) known.value, cast(ushort) known.max);
        target.player.updateSkillsForLevel(context.client);
        foreach (skill; target.player.skillList())
            target.applySkill(skill[0], cast(ushort) skill[1], cast(ushort) skill[2]); // saved with the new caps
        blueSystemMessage("Reset skills to default.");
        gmLog(format!"reset skills of %s to default"(target.player.data.name));
        return true;
    }

    /// `.fixscale <scale>`: the selected creature's size, and its template's, kept.
    bool handleFixScaleCommand(float scale = 0)
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        if (scale < 0.1f)
            return false;
        creature.values.set!OBJECT_FIELD_SCALE_X(scale);
        map.flushObjectChanges(creature);
        const entry = creature.spawn.entry;
        if (auto edited = context.data.creatureTemplates.edit(entry))
            edited.scale = scale;
        context.database.updateCreatureScale(entry, scale);
        return true;
    }

    /// `.removesickness`: resurrection sickness taken off the selected player.
    bool handleRemoveResurrectionSicknessAuraCommand()
    {
        enum uint resurrectionSickness = 15007;
        auto target = selectedCharacter(true);
        if (target is null)
            return false;
        blueSystemMessage("Removed resurrection sickness.");
        if (auto aura = target.player.auras.find(resurrectionSickness))
            target.removeAura(aura);
        if (target !is this)
            gmLog(format!"Removed resurrection sickness from %s"(target.player.data.name));
        return true;
    }

    /// `.admin castall <spell>`: every player here casts the spell on itself, triggered (not one that teaches).
    bool handleCastAllCommand(Rest args = Rest.init)
    {
        if (args.length < 2)
        {
            redSystemMessage("No spellid specified.");
            return true;
        }
        const spellId = numberAtStart(args);
        const spell = context.data.spells.spell(spellId);
        if (spell is null)
        {
            redSystemMessage("Invalid spell specified.");
            return true;
        }
        if (spell.hasEffect(SpellEffect.learnSpell))
        {
            gmLog(format!"used wrong / learnall castall command, spellid %u"(spellId));
            redSystemMessage("Learn spell specified.");
            return true;
        }
        gmLog(format!"used castall command, spellid %u"(spellId));
        foreach (other; context.onlinePlayers)
        {
            auto target = sessionOf(other);
            if (target.player !is null && !target.transferring)
                target.castTriggeredAt(spellId, target.player.guid);
        }
        blueSystemMessage(format!"Casted spell %u on all players!"(spellId));
        return true;
    }

    /// `.npc respawn`: the selected corpse gone now, the creature back a second later.
    bool handleCreatureRespawnCommand()
    {
        auto corpse = selectedCreature(false);
        if (corpse is null || corpse.alive || corpse.spawn.guid == 0)
        {
            redSystemMessage("You must select a creature's corpse with a valid CreatureSpawn point.");
            return false;
        }
        const line = format!"Respawning a Creature: `%s` with entry: %u on map: %u sqlid: %u"(corpse.template_.name,
            corpse.spawn.entry, map.id, corpse.spawn.guid);
        blueSystemMessage(line);
        gmLog("Respawned" ~ line["Respawning".length .. $]);
        context.respawnSoon(corpse, map);
        return true;
    }

    // -----------------------------------------------------------------------
    // Whispers to a GM with the tag on
    // -----------------------------------------------------------------------

    /// `.gm whisperblock`: the GM tag without the <GM> flag; players' whispers get the automatic reply.
    bool handleWhisperBlockCommand()
    {
        if (player.gmTagOn)
            return false;
        player.gmTagOn = true;
        return true;
    }

    /// The guid and name of the player named `name`, on this node or another; false after "Player not found.".
    bool findPlayerAnywhere(string name, out ulong guid, out string found)
    {
        if (auto online = context.onlinePlayer(name))
        {
            guid = online.character.guid;
            found = online.character.data.name;
            return true;
        }
        if (const remote = context.remotePlayer(name))
        {
            guid = remote.entry.guid;
            found = remote.entry.name;
            return true;
        }
        redSystemMessage("Player not found.");
        return false;
    }

    /// `.gm allowwhispers <name>`: the player may whisper the GM while its tag is on.
    bool handleAllowWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (!findPlayerAnywhere(name, guid, found))
            return true;
        gmTargets[guid] = true;
        blueSystemMessage(format!"Now accepting whispers from %s."(found));
        return true;
    }

    /// `.gm blockwhispers <name>`: the player's whispers blocked again.
    bool handleBlockWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (!findPlayerAnywhere(name, guid, found))
            return true;
        gmTargets.remove(guid);
        blueSystemMessage(format!"Now blocking whispers from %s."(found));
        return true;
    }

    // -----------------------------------------------------------------------
    // The character group
    // -----------------------------------------------------------------------

    /// `.character removeitem <item> [count]`: copies of an item taken from the selected player.
    bool handleRemoveItemCommand(uint itemId, int count = 1)
    {
        if (count == 0)
            return false;
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        if (count > 0)
            target.takeItem(itemId, count);
        const item = itemId in context.data.items;
        if (item is null)
        {
            redSystemMessage(format!"Cannot remove non valid item id: %u ."(itemId));
            return true;
        }
        gmLog(format!"used remove item %s (id: %u) count %u from %s"(item.details.name, itemId, count,
            target.player.data.name));
        blueSystemMessage(format!"Removing %u copies of item %s (id: %u) from %s's inventory."(count, itemLink(itemId),
            itemId, target.player.data.name));
        target.blueSystemMessage(format!"%s removed %u copies of item %s from your inventory."(player.data.name,
            count, itemLink(itemId)));
        return true;
    }

    /// `.character additemset <set>`: every item of an item set given to the selected player.
    bool handleAddItemSetCommand(uint setId = 0)
    {
        if (setId == 0)
        {
            redSystemMessage("You must specify a setid.");
            return true;
        }
        auto target = selectedCharacter(true);
        if (target is null)
        {
            redSystemMessage("Unable to select character.");
            return true;
        }
        uint[] entries;
        foreach (entry, ref item; context.data.items)
            if (item.details.itemSet == setId)
                entries ~= entry;
        if (entries.length == 0)
        {
            redSystemMessage("Invalid item set.");
            return true;
        }
        entries.sort();
        blueSystemMessage(format!"Searching item set %u..."(setId));
        const started = MonoTime.currTime;
        gmLog(format!"used add item set command, set %u, target %s"(setId, target.player.data.name));
        foreach (entry; entries)
            if (target.giveItem(entry, 1) == 0)
            {
                sendNotification("No free slots left!");
                return true;
            }
        greenSystemMessage(format!"Added set to inventory complete. Time: %u ms"(msecsSince(started)));
        return true;
    }

    /// `.character advanceallskills <amount>`: each of the selected player's skills up, to at most its maximum.
    bool handleAdvanceAllSkillsCommand(uint amount = 0)
    {
        if (amount == 0)
        {
            redSystemMessage("An amount to increment is required.");
            return true;
        }
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        foreach (skill; target.player.skillList)
            target.applySkill(skill[0], cast(ushort) min(skill[1] + amount, skill[2]), cast(ushort) skill[2]);
        target.greenSystemMessage(format!"Advanced all your skill lines by %u points."(amount));
        gmLog(format!"advanced all skills by %u on %s"(amount, target.player.data.name));
        return true;
    }

    /// `.character showitems`: the selected player's items, each as a link with its count.
    bool handleShowItemsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        foreach (item; target.player.inventory.all())
            systemMessage(format!"Item %u %s Count %u Slot %u ContainerSlots %u"(item.entry, itemLink(item.entry),
                cast(ubyte) target.player.inventory.count(item.entry), item.slot, item.proto.containerSlots));
        gmLog(format!"used show items command on %s,"(target.player.data.name));
        return true;
    }

    /// `.character showskills`: the selected player's skills with their values.
    bool handleShowSkillsCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        foreach (skill; target.player.skillList)
            systemMessage(format!"Skill %u %s %u/%u"(skill[0], skillName(skill[0]), skill[1], skill[2]));
        gmLog(format!"used show skills command on %s,"(target.player.data.name));
        return true;
    }

    /// `.npc npcfollow`: the selected creature follows this player.
    bool handleNpcFollowCommand()
    {
        import std.math : PI;

        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        creature.ai.hostFollow(EntityRef(player.guid), 2.0f, PI / 2);
        gmLog(format!"used npc follow command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    /// `.npc nullfollow`: the selected creature follows nobody; it moves as before.
    bool handleNullFollowCommand()
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        creature.ai.hostFollow(EntityRef.init, 0, 0);
        gmLog(format!"cancelled npc follow command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    /**
     * `.character forcerename <name>`: the character must take a new name at its next login (the `at_login`
     * rename flag); its old name is reserved (in memory: the world database keeps `reserved_name`, which the
     * server does not write).
     */
    bool handleForceRenameCommand(string name)
    {
        import dmangos.world.characters : AtLoginFlags;
        import dmangos.world.worlddata : toLowerName;

        if (name.length > 100)
            return false;
        const guid = context.database.characterGuid(normalizedName(name));
        if (guid == 0)
        {
            redSystemMessage("Player with that name not found.");
            return true;
        }
        auto online = context.onlinePlayer(guid);
        const realName = online !is null ? online.character.data.name : normalizedName(name);
        if (online !is null)
        {
            auto target = sessionOf(online);
            target.player.data.atLogin |= AtLoginFlags.rename;
            target.savePlayer();
            target.blueSystemMessage(format!"%s forced your character to be renamed next logon."(player.data.name));
        }
        else
            context.database.addAtLoginFlags(guid, AtLoginFlags.rename);
        context.data.reservedNames[toLowerName(realName)] = true;
        greenSystemMessage(format!"Forcing %s to rename his character next logon."(name));
        gmLog(format!"forced %s to rename their character (%u)"(realName, guid));
        return true;
    }

    /// `.character rename <name> <new name>`: the character renamed now, wherever it is.
    bool handleRenameCommand(string oldName, string wanted)
    {
        import dmangos.world.names : checkPlayerName, CharNameResult;

        const config = context.config;
        if (checkPlayerName(wanted, config.minPlayerName, config.strictPlayerNames, config.realmZone)
            != CharNameResult.CHAR_NAME_SUCCESS)
        {
            redSystemMessage("Enter a valid character name.");
            return true;
        }
        const guid = context.database.characterGuid(normalizedName(oldName));
        if (guid == 0)
        {
            redSystemMessage("Player not found with this name.");
            return true;
        }
        const newName = normalizedName(wanted);
        if (context.database.nameTaken(newName))
        {
            redSystemMessage("Player found with this name in use already.");
            return true;
        }
        context.database.renameCharacter(guid, newName);
        if (auto online = context.onlinePlayer(oldName))
            sessionOf(online).renamedBy(gmSink, player.data.name, newName);
        else
            gmElsewhere(oldName, GmRemoteOp.rename, newName);
        greenSystemMessage(format!"Changed name of '%s' to '%s'."(oldName, wanted));
        gmLog(format!"renamed character %s (GUID: %u) to %s"(oldName, guid, wanted));
        return true;
    }

    // -----------------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------------

    /// "Creature 42: Name" with the part searched for in light red.
    void sendHighlightedName(string prefix, string fullName, string search, uint id)
    {
        const offset = fullName.toLower.indexOf(search);
        string name = colored(ChatColor.white, fullName);
        if (offset >= 0 && offset + search.length <= fullName.length)
        {
            const end = offset + search.length;
            name = colored(ChatColor.white, fullName[0 .. offset]) ~ colored(ChatColor.softRed, fullName[offset .. end])
                ~ colored(ChatColor.white, fullName[end .. $]);
        }
        systemMessage(format!"%s %u: %s"(prefix, id, name));
    }

    /// The lookups that need four letters, and stop at 25 results: started and completed in blue or green.
    bool lookupNamed(string search, string kind, bool blue, LookupResult[] delegate(string) find)
    {
        const text = search.toLower;
        if (text.length < 4)
        {
            redSystemMessage("Enter at least four characters to search.");
            return true;
        }
        void say(string message)
        {
            if (blue)
                blueSystemMessage(message);
            else
                greenSystemMessage(message);
        }

        say(format!"Starting search of %s `%s`..."(kind, text));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; find(text))
        {
            if (kind == "item")
            {
                const item = row.id in context.data.items;
                systemMessage(format!"Item %u %s ContainerSlots %u"(row.id, itemLink(row.id), item.containerSlots));
            }
            else
                sendHighlightedName(kind.capitalize, row.name, text, row.id);
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        say(format!"Search completed in %u ms."(msecsSince(started)));
        return true;
    }

    /// `.npc spawn <entry>`: a creature spawned at the GM's position, and saved.
    bool handleCreatureSpawnCommand(uint entry = 0)
    {
        if (entry == 0)
            return false;
        const creatureTemplate = entry in context.data.creatureTemplates;
        if (creatureTemplate is null)
        {
            redSystemMessage("Invalid entry id.");
            return true;
        }
        const at = player.position;
        if (context.spawnCreatureAt(map, entry, at) is null)
        {
            redSystemMessage("Could not spawn the creature.");
            return true;
        }
        blueSystemMessage(format!"Spawned a creature `%s` with entry %u at %f %f %f on map %u"(creatureTemplate.name,
            entry, at.x, at.y, at.z, player.data.map));
        gmLog(format!"spawned a %s at %u %f %f %f"(creatureTemplate.name, player.data.map, at.x, at.y, at.z));
        return true;
    }

    /// `.character getstanding <faction>`: the selected player's base and current standing with a faction.
    bool handleGetStandingCommand(uint faction = 0)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        const factionEntry = context.client.factions.lookup(faction);
        const reputation = target.player.reputation;
        const standing = reputation is null ? 0 : reputation.standingWith(faction);
        const base = reputation is null || factionEntry is null ? 0 : reputation.baseOf(factionEntry);
        greenSystemMessage(format!"Reputation for faction %u:"(faction));
        systemMessage(format!"Base Standing: %d"(base));
        blueSystemMessage(format!"Standing: %d"(standing));
        return true;
    }

    /// `.character setstanding <faction> <standing>`: to that value, its neighbouring factions untouched.
    bool handleSetStandingCommand(uint faction, int standing)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        blueSystemMessage(format!"Setting standing of %u to %d on %s."(faction, standing, target.player.data.name));
        if (target.player.reputation !is null)
            target.modifyReputation(faction, standing - target.player.reputation.standingWith(faction), true);
        target.flushPlayerChanges();
        target.greenSystemMessage(format!"%s set your standing of faction %u to %d."(player.data.name, faction,
            standing));
        gmLog(format!"set standing of faction %u to %u for %s"(faction, standing, target.player.data.name));
        return true;
    }

    /// `.lookup faction <text>`.
    bool handleLookupFactionCommand(Rest search)
    {
        return lookupNamed(search, "faction", false, (text) {
            LookupResult[] found;
            foreach (id; 0 .. context.client.factions.idLimit)
                if (const faction = context.client.factions.lookup(id))
                    if (faction.name[0].toLower.canFind(text))
                        found ~= LookupResult(faction.id, faction.name[0]);
            return found;
        });
    }

    /// `.lookup item <text>`.
    bool handleLookupItemCommand(Rest search)
    {
        return lookupNamed(search, "item", true, (text) {
            LookupResult[] found;
            foreach (entry, ref item; context.data.items)
                if (item.details.name.toLower.canFind(text))
                    found ~= LookupResult(entry, item.details.name);
            found.sort!((a, b) => a.id < b.id);
            return found;
        });
    }

    /// `.lookup creature <text>`.
    bool handleLookupCreatureCommand(Rest search)
    {
        return lookupNamed(search, "creature", false, text => context.database.lookup(LookupTable.creature, text, 25));
    }

    /// `.lookup spell <text>`.
    bool handleLookupSpellCommand(Rest search)
    {
        return lookupNamed(search, "spell", false, text => context.database.lookup(LookupTable.spell, text, 25));
    }

    /// `.lookup skill <text>`.
    bool handleLookupSkillCommand(Rest search)
    {
        return lookupNamed(search, "skill", false, (text) {
            LookupResult[] found;
            foreach (ref skill; context.client.skillLines.rows)
                if (skill.name[0].toLower.canFind(text))
                    found ~= LookupResult(skill.id, skill.name[0]);
            return found;
        });
    }

    /// `.lookup object <text>`: the game objects whose name matches, at most 50.
    bool handleLookupObjectCommand(Rest search)
    {
        const text = search.toLower;
        greenSystemMessage(format!"Starting search of object `%s`..."(text));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.gameObject, text, 50))
        {
            systemMessage(colored(ChatColor.gold, format!"Object %u"(row.id)) ~ " · " ~ row.name);
            if (++count >= 50)
            {
                redSystemMessage("Showing the first 50 matches.");
                break;
            }
        }
        if (count == 0)
            blueSystemMessage("No matches found.");
        blueSystemMessage(format!"Search completed in %u ms."(msecsSince(started)));
        return true;
    }

    /// `.lookup quest <text>`: the quests whose name matches, at most 25.
    bool handleQuestLookupCommand(Rest search)
    {
        const text = search.toLower;
        if (text.length < 4)
        {
            redSystemMessage("Enter at least four characters to search.");
            return true;
        }
        blueSystemMessage(format!"Starting search of quests `%s`..."(text));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.quest, text, 25))
        {
            blueSystemMessage(format!"%u · %s"(row.id, row.name));
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        if (count == 0)
            blueSystemMessage("No matches found.");
        blueSystemMessage(format!"Search completed in %u ms."(msecsSince(started)));
        return true;
    }

    // -----------------------------------------------------------------------
    // Creatures
    // -----------------------------------------------------------------------

    /// `.npc info`: the selected creature's fields.
    bool handleNpcInfoCommand()
    {
        import dmangos.world.objects : counterOf;

        auto creature = selectedCreature(true);
        if (creature is null)
            return false;
        const values = &creature.values;
        blueSystemMessage("Showing creature info for " ~ creature.template_.name);
        systemMessage(format!"GUID: %d"(cast(uint) creature.guid));
        systemMessage(format!"Faction: %d"(values.get!UNIT_FIELD_FACTIONTEMPLATE));
        systemMessage(format!"NPCFlags: %d"(values.get!UNIT_NPC_FLAGS));
        systemMessage(format!"DisplayID: %d"(values.get!UNIT_FIELD_DISPLAYID));
        systemMessage(format!"Health (cur/max): %d/%d"(values.get!UNIT_FIELD_HEALTH, values.get!UNIT_FIELD_MAXHEALTH));
        systemMessage(format!"Mana (cur/max): %d/%d"(values.get!UNIT_FIELD_POWER1, values.get!UNIT_FIELD_MAXPOWER1));
        systemMessage("Armor/Holy/Fire/Nature/Frost/Shadow/Arcane");
        systemMessage(format!"%d/%d/%d/%d/%d/%d/%d"(values.get!UNIT_FIELD_RESISTANCES(0),
            values.get!UNIT_FIELD_RESISTANCES(1), values.get!UNIT_FIELD_RESISTANCES(2),
            values.get!UNIT_FIELD_RESISTANCES(3), values.get!UNIT_FIELD_RESISTANCES(4),
            values.get!UNIT_FIELD_RESISTANCES(5), values.get!UNIT_FIELD_RESISTANCES(6)));
        systemMessage(format!"Damage (min/max): %f/%f"(values.get!UNIT_FIELD_MINDAMAGE,
            values.get!UNIT_FIELD_MAXDAMAGE));
        colorSystemMessage(ChatColor.red, format!"Entry ID: %d"(values.get!OBJECT_FIELD_ENTRY));
        colorSystemMessage(ChatColor.red, format!"SQL Entry ID: %d"(counterOf(creature.guid)));
        const bytes = values.get!UNIT_FIELD_BYTES_0;
        systemMessage(format!"UNIT_FIELD_BYTES_0 are %s %s %s %s"(bytes & 0xFF, bytes >> 8 & 0xFF, bytes >> 16 & 0xFF,
            bytes >> 24));
        return true;
    }
}

/// `.setstanding` and `.getstanding` on the selected player, and `.resetreputation`.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionFormat;
    import dmangos.world.commands : ChatColor;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto row = new uint[factionFormat.length];
    row[0] = 72;
    row[1] = 3;
    context.client.factions = typeof(context.client.factions).parse(buildDbc(factionFormat, [row]), "Faction.dbc");
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(anduin.session.character.guid));
    const me = cast(Player) anduin.session.character;

    gm.say(".character setstanding 72 1000");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Setting standing of 72 to 1000 on Anduin.|r"]);
    assert(me.reputation.standingWith(72) == 1000);
    assert(systemMessages(anduin.read()).canFind(ChatColor.green ~ "Varian set your standing of faction 72 to 1000.|r"));
    gm.say(".character getstanding 72");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Reputation for faction 72:|r", "Base Standing: 0",
        ChatColor.sky ~ "Standing: 1000|r"]);
    gm.say(".character resetreputation");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Done. Relog for changes to take effect.|r"]);
    assert(me.reputation.standingWith(72) == 0);
}

/// `.admin castall` casts a spell on every player (but not a learning one); `.removesickness` takes resurrection sickness off.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.commands : ChatColor;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewCharacter;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint blessing = 95900, teach = 95901, sickness = 15007;
    context.data.spells.spells[blessing] = testSpell(blessing, 6, 1, 5);
    context.data.spells.spells.edit(blessing).casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells[teach] = testSpell(teach, 36, 1, 0);
    context.data.spells.spells[sickness] = testSpell(sickness, 6, 1, -75);
    context.data.spells.spells.edit(sickness).casting.applyAuraName[0] = AuraType.modStat;
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    auto victim = cast(Player) anduin.session.character;

    gm.say(".admin castall 7");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "No spellid specified.|r"], "one figure is too short");
    gm.say(".admin castall 95999");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Invalid spell specified.|r"]);
    gm.say(".admin castall 95901");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Learn spell specified.|r"]);
    gm.say(".admin castall 95900");
    assert(systemMessages(gm.read()).canFind(ChatColor.sky ~ "Casted spell 95900 on all players!|r"));
    assert(victim.auras.find(blessing) !is null && (cast(Player) gm.session.character).auras.find(blessing) !is null);

    // No weapon: unarmed (162), from 1 a step.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    const unarmed = victim.skillValue(162);
    gm.say(".character increaseweaponskill 2");
    assert(systemMessages(gm.read())[0] == ChatColor.sky ~ "Modifying skill line 162. Advancing 2 times.|r");
    assert(unarmed[1] == 0 ? victim.skillValue(162)[0] == 1
        : victim.skillValue(162)[0] == (unarmed[0] + 2 < unarmed[1] ? unarmed[0] + 2 : unarmed[1]));

    // `.character resetspells` and `resetskills`: what was learned since creation goes.
    {
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
        gm.say(".character learn 95900");
        gm.say(".character learnskill 164 1 75"); // blacksmithing
        gm.read();
        anduin.read();
        assert(victim.knowsSpell(blessing) && victim.skillValue(164)[1] == 75);
        gm.say(".character resetspells");
        assert(systemMessages(gm.read()) == [ChatColor.green ~ "Reset spells of Anduin to level 1.|r"]);
        assert(systemMessages(anduin.read()).canFind(ChatColor.sky ~ "Varian reset all your spells to starting values.|r"));
        assert(!victim.knowsSpell(blessing));
        {
            NewCharacter fresh;
            assert(anduin.session.inWorld.startingAbilities(anduin.session.inWorld, fresh) && fresh.spells.length);
            foreach (s; fresh.spells)
                if (s.active && !s.disabled)
                    assert(victim.knowsSpell(s.spell), "a new character's spells");
        }
        gm.say(".character resetskills");
        assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Reset skills to default.|r"]);
        assert(victim.skillValue(164)[1] == 0 && victim.skillList().length > 0);
    }

    // `.fixscale` on the innkeeper.
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
        gm.say(".fixscale 0.05");
        assert(systemMessages(gm.read()).length > 0, "too small: the help");
        gm.say(".fixscale 2");
        gm.read();
        assert(keeper.values.get!OBJECT_FIELD_SCALE_X == 2.0f && db.creatureScales[creatureInnkeeper] == 2.0f);
        assert(context.data.creatureTemplates[creatureInnkeeper].scale == 2.0f);
    }

    anduin.session.inWorld.addAura(makeAura((sickness in context.data.spells.spells), victim.guid, 1, 600_000, false, [-75, 0, 0]));
    assert(victim.auras.find(sickness) !is null);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".removesickness");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Removed resurrection sickness.|r"]);
    assert(victim.auras.find(sickness) is null);
}

// `.guild create`, `members` and `disband` on the GM itself (nothing selected), in ArcEmu's words.
unittest
{
    import dmangos.world.commands : ChatColor;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    gm.read();
    gm.say(".guild create Kirin Tor");
    assert(systemMessages(gm.read()).canFind(ChatColor.green ~ "Guild created|r"));
    auto g = context.guilds.named("Kirin Tor");
    assert(g !is null && g.leader == 7);
    gm.say(".guild create Kirin Tor");
    assert(systemMessages(gm.read()).canFind!(m => m.canFind("is already in a guild.")));
    gm.say(".guild rename Kirin Tor");
    {
        const told = systemMessages(gm.read());
        assert(told[$ - 1] == ChatColor.softRed ~ "Guild name Kirin Tor is already taken.|r"
            && !told.canFind!(m => m.canFind(".guild rename")), "a taken name gets its own message, not the usage too");
    }
    gm.say(".guild members");
    const members = systemMessages(gm.read());
    assert(members.canFind(ChatColor.green ~ "Now showing guild members for Kirin Tor|r"));
    assert(members.canFind!(m => m.canFind("Jaina (Rank: ")));
    gm.say(".guild disband");
    assert(systemMessages(gm.read()).canFind(ChatColor.green ~ "Disbanded Guild: Kirin Tor|r"));
    assert(context.guilds.named("Kirin Tor") is null);
    gm.say(".guild create Dal4ran");
    assert(systemMessages(gm.read()).canFind!(m => m.canFind("Error, name can only contain chars A-Z and a-z.")));
}

/// Support cannot ban or unban characters; nobody bans an account of their own staff rank or higher.
unittest
{
    import dmangos.auth.accounts : BanState;
    import dmangos.world.commands : ChatColor;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto support = loggedIn(context, db, 6, "Tirion", Position(0, 0, 0), AccountLevel.moderator);
    auto gm = loggedIn(context, db, 7, "Jaina", Position(0, 0, 0), AccountLevel.gameMaster);
    auto admin = loggedIn(context, db, 8, "Varian", Position(0, 0, 0), AccountLevel.administrator);
    auto peer = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.gameMaster);
    auto player = loggedIn(context, db, 10, "Anduin", Position(0, 0, 0));
    foreach (c; [&support, &gm, &admin, &peer, &player])
        c.read();
    BanState banOf(string account) { return context.accounts.findAccount(account).get.ban; }
    support.say(".ban character Anduin 1d spam");
    assert(systemMessages(support.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);
    support.say(".unban character Anduin");
    assert(systemMessages(support.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);
    assert(banOf("ANDUIN") == BanState.none);

    foreach (target; ["Varian", "Thrall"])
    {
        gm.say(".ban character " ~ target ~ " 1d spam");
        assert(systemMessages(gm.read()).canFind!(m => m.canFind("You cannot ban " ~ target
            ~ ", as they are a staff member of your rank or higher.")));
    }
    gm.say(".ban account VARIAN 1d spam");
    assert(systemMessages(gm.read()).canFind!(m => m.canFind(
        "You cannot ban VARIAN, as they are a staff member of your rank or higher.")));
    assert(banOf("VARIAN") == BanState.none && banOf("THRALL") == BanState.none);

    gm.say(".ban character Anduin 1d spam");
    gm.read();
    assert(banOf("ANDUIN") == BanState.suspended);
    gm.say(".unban character Anduin");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);
    admin.say(".unban character Anduin");
    admin.read();
    assert(banOf("ANDUIN") == BanState.none);
}
