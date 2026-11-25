/// Account administration, server operations, and shared character management.
module dmangos.world.gmadmin;

/// See the module documentation.
mixin template AdminCommands()
{
    import core.time : MonoTime, seconds;
    import dmangos.world.database : TicketRecord;
    import std.algorithm.comparison : clamp, min;
    import std.algorithm.searching : canFind, endsWith, findSplitBefore;
    import std.algorithm.sorting : sort;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.string : indexOf;
    import std.uni : sicmp, toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands;
    import dmangos.world.context : ShutdownTimer;
    import dmangos.world.database : LookupResult, LookupTable;
    import dmangos.world.defines : exploredZonesSize, PlayerClass;
    import dmangos.world.gmadmin;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : Position;
    import dmangos.world.player : DeathState;
    import dmangos.world.names : normalizedName;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.spells : SpellEffect;
    import dmangos.world.updatefields;

private:
    bool handleAddPetSpellCommand(uint spell)
    {
        return petSpellCommand(spell, true);
    }

    bool handleRemovePetSpellCommand(uint spell)
    {
        return petSpellCommand(spell, false);
    }

    private bool petSpellCommand(uint spell, bool teach)
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
            return false;
        if (plr.ownPet is null)
        {
            redSystemMessage(format!"%s has no pet."(plr.player.data.name));
            return true;
        }
        if (context.data.spells.spell(spell) is null)
        {
            redSystemMessage(format!"Unknown spell ID %s."(spell));
            return true;
        }
        plr.petLearnsSpell(spell, teach);
        greenSystemMessage(format!"%s's pet %s spell %s."(plr.player.data.name, teach ? "learned" : "forgot", spell));
        return true;
    }

    /// `.pet renamepet <name>`: the player's own pet is renamed.
    bool handleRenamePetCommand(Rest args = Rest.init)
    {
        if (ownPet is null)
        {
            redSystemMessage("You have no pet.");
            return true;
        }
        if (args.length < 1)
        {
            redSystemMessage("You must specify a name.");
            return true;
        }
        greenSystemMessage(format!"Renamed your pet to %s."(args.text));
        renamePetTo(args.text);
        return true;
    }

    bool handleModifyLevelCommand(uint level = 0)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        if (level == 0 || level > context.config.maxPlayerLevel)
        {
            redSystemMessage("Enter a level within the server’s level range.");
            return true;
        }
        blueSystemMessage(format!"Setting the level of %s to %u."(plr.player.data.name, level));
        plr.greenSystemMessage(format!"%s set your level to %u."(player.data.name, level));
        gmLog(format!"used modify level on %s, level %u"(plr.player.data.name, level));
        plr.applyLevel(level);
        return true;
    }

    bool handleGenderChanger(Nullable!int requested)
    {
        auto found = context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET);
        if (found is null)
        {
            systemMessage("Select a player first.");
            return true;
        }
        auto target = sessionOf(found);
        auto p = target.player;
        const displayId = p.values.get!UNIT_FIELD_NATIVEDISPLAYID;
        const uint gender = requested.isNull ? p.data.gender == 1 ? 0 : 1 : clamp(requested.get, 0, 1);
        p.data.gender = cast(ubyte) gender;
        p.values.setByte!UNIT_FIELD_BYTES_0(2, cast(ubyte) gender);
        p.values.setHalf!PLAYER_BYTES_3(0, cast(ushort) gender);
        // A race's female model id follows its male one.
        const display = gender == 0 ? displayId - 1 : displayId + 1;
        p.values.set!UNIT_FIELD_DISPLAYID(display);
        p.values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        target.flushPlayerChanges();
        systemMessage(format!"Set %s's gender to %s(%u)."(p.data.name, gender ? "Female" : "Male", gender));
        return true;
    }

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
        default: return false;
        }
    }

    bool handleWorldPortCommand(uint mapId, float x, float y, float z)
    {
        enum float maxCoord = 17_066.666f; // _maxX, _maxY; _minX, _minY are their negatives
        if (x >= maxCoord || x <= -maxCoord || y <= -maxCoord || y >= maxCoord)
            return false;
        commandTeleport(mapId, Position(x, y, z, 0));
        return true;
    }

    bool handleLevelUpCommand(int levels = 1)
    {
        if (levels <= 0)
            return false;
        auto plr = getSelectedChar(true);
        if (plr is null)
            plr = this;
        gmLog(format!"used level up command on %s, with %u levels"(plr.player.data.name, levels));
        levels += plr.player.data.level;
        if (levels > context.config.maxPlayerLevel)
            levels = context.config.maxPlayerLevel;
        plr.applyLevel(levels);
        plr.systemMessage(format!"You have been leveled up to Level %d"(levels));
        return true;
    }

    /// "[d days, h hours, m minutes, s seconds]", as `HandlePlayerInfo` writes played time.
    static string playedText(uint seconds)
    {
        return format!"[%d days, %d hours, %d minutes, %d seconds]"(seconds / TIME_DAY, seconds / TIME_HOUR % 24,
            seconds / TIME_MINUTE % 60, seconds % 60);
    }

    bool handlePlayerInfo(Rest name = Rest.init)
    {
        Character plr;
        if (name.length >= 2) // char name can be 2 letters
        {
            auto found = context.onlinePlayer(name);
            if (found is null)
            {
                if (!gmElsewhere(name, GmRemoteOp.playerInfo))
                    redSystemMessage(format!"Unable to locate player %s."(name));
                return true;
            }
            plr = sessionOf(found);
        }
        else
            plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.describeTo(gmSink);
        return true;
    }

    bool handleReviveCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        // Resurrected: alive, its corpse gone to bones.
        if (plr.player.deathState != DeathState.alive)
        {
            plr.bringBack(1);
            plr.spawnCorpseBones();
        }
        auto values = &plr.player.values;
        values.set!UNIT_FIELD_HEALTH(values.get!UNIT_FIELD_MAXHEALTH);
        values.set!UNIT_FIELD_POWER1(values.get!UNIT_FIELD_MAXPOWER1);
        values.set!UNIT_FIELD_POWER4(values.get!UNIT_FIELD_MAXPOWER4);
        plr.flushPlayerChanges();
        if (plr !is this)
            gmLog("revived player " ~ plr.player.data.name);
        return true;
    }

    /// The selected player, on this map, or null after "Invalid target.".
    Character selectedPlayerUnit()
    {
        auto plr = cast(Character) map.find(player.values.get!UNIT_FIELD_TARGET);
        if (plr is null)
            redSystemMessage("Invalid target.");
        return plr;
    }

    bool handleParalyzeCommand()
    {
        auto plr = selectedPlayerUnit();
        if (plr is null)
            return true;
        blueSystemMessage("Rooting target.");
        plr.blueSystemMessage(format!"You have been rooted by %s."(player.data.name));
        gmLog("rooted player " ~ plr.player.data.name);
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        return true;
    }

    bool handleUnParalyzeCommand()
    {
        auto plr = selectedPlayerUnit();
        if (plr is null)
            return true;
        blueSystemMessage("Unrooting target.");
        plr.blueSystemMessage(format!"You have been unrooted by %s."(player.data.name));
        gmLog("unrooted player " ~ plr.player.data.name);
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        return true;
    }

    // -----------------------------------------------------------------------
    // Accounts (sLogonCommHandler.Account_*)
    // -----------------------------------------------------------------------

    /// The connection of the account named `name` (in the world or at the
    /// character screen), in any case, or null.
    WorldSession connectionOfAccountName(string name)
    {
        import dmangos.world.session : WorldSession;

        const found = context.accounts.findAccount(name);
        return found.isNull ? null : cast(WorldSession) context.sessionOfAccount(found.get.id);
    }

    /// ditto: its character, if it is in the world here.
    Character sessionOfAccountName(string name)
    {
        auto connection = connectionOfAccountName(name);
        return connection is null ? null : connection.inWorld;
    }

    /// The `account.gmlevel` a GM permission string stands for: a level number as is, otherwise
    /// the level whose `gm_permissions` string has the same letters. -1 if none has.
    int levelForPermissions(string flags)
    {
        if (flags.length == 1 && flags[0] >= '0' && flags[0] <= '3')
            return flags[0] - '0';
        const letters = loadSecurity(flags);
        foreach (level; 0 .. 4)
            if (context.config.gmPermissions.forLevel(level) == letters)
                return level;
        return -1;
    }

    bool handleAccountLevelCommand(string account, string gmlevel)
    {
        const level = levelForPermissions(gmlevel);
        if (level < 0)
        {
            redSystemMessage(format!"No account level has the permissions '%s' (see gm_permissions)."(gmlevel));
            return true;
        }
        if (!context.accounts.findAccount(account).isNull)
        {
            context.accounts.setLevel(account, cast(AccountLevel) level);
            if (auto session = sessionOfAccountName(account))
                session.account.level = cast(AccountLevel) level;
        }
        greenSystemMessage(format!("Account '%s' level has been updated to '%s'. The change will be effective "
            ~ "immediately.")(account, gmlevel));
        gmLog(format!"set account %s flags to %s"(account, gmlevel));
        return true;
    }

    bool handleAccountMuteCommand(string name, string duration)
    {
        const period = getTimePeriodFromString(duration);
        if (period <= 0)
            return false;
        const until = context.unixTime + period;
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.database.setMuteTime(found.get.id, until);
        const text = convertTimeStampToDataTime(until);
        greenSystemMessage(format!"Account '%s' has been muted until %s. The change will be effective immediately."(
            name, text));
        gmLog(format!"mutex account %s until %s"(name, text));
        if (auto session = sessionOfAccountName(name))
        {
            session.account.muteTime = until;
            session.systemMessage(format!("Your voice has been muted until %s by a GM. Until this time, you will not "
                ~ "be able to speak in any form.")(text));
        }
        return true;
    }

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

    /// The message sent for each session a disconnect command closes, then the close.
    void disconnect(imported!"dmangos.world.session".WorldSession connection)
    {
        // "Disconnecting user with ...": an account at its character screen too.
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
            if (auto connection = cast(imported!"dmangos.world.session".WorldSession) session)
                disconnect(connection);
        if (sessions.length == 0)
            systemMessage(format!"There is nobody online with ip [%s]"(ip));
    }

    /// Disconnects the session of the account named `account`.
    void disconnectUsersWithAccount(string account)
    {
        if (auto connection = connectionOfAccountName(account))
            disconnect(connection);
        else
            systemMessage(format!"There is nobody online with account [%s]"(account));
    }

    bool handleKillByPlayerCommand(Rest name = Rest.init)
    {
        if (name.length < 2)
        {
            redSystemMessage("A player's name is required.");
            return true;
        }
        // Disconnects the player's session. "There is no body online" is said only when nobody was found.
        if (auto found = context.onlinePlayer(name))
            disconnect(sessionOf(found).connection);
        else if (gmElsewhere(name, GmRemoteOp.disconnect))
        {
        }
        else
            systemMessage(format!"There is no body online with the name [%s]"(name));
        gmLog("disconnected player " ~ name);
        return true;
    }

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

    bool handleKillByIPCommand(Rest ip = Rest.init)
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

    bool handleIPBanCommand(string ip, string duration, Rest reason = Rest.init)
    {
        const period = getTimePeriodFromString(duration);
        if (period < 1)
            return false;
        if (!isIPv4Address(ip.findSplitBefore("/")[0]))
        {
            redSystemMessage(format!"Invalid IPv4 address [%s]"(ip));
            return true;
        }
        const expireTime = context.unixTime + period;
        if (!ip.canFind('/'))
        {
            redSystemMessage("Lack of CIDR address assumes a 32bit match (if you don't understand, dont worry, it "
                ~ "worked)");
            ip ~= "/32";
        }
        systemMessage(format!"Adding [%s] to IP ban table, expires %s.Reason is :%s"(ip, ctimeString(expireTime),
            reason));
        const address = ip[0 .. ip.indexOf('/')];
        context.accounts.banIp(ip.endsWith("/32") ? address : ip, period, player.data.name, reason);
        disconnectUsersWithIP(address);
        gmLog(format!"banned ip address %s, expires %s"(ip, ctimeString(expireTime)));
        return true;
    }

    bool handleBanCharacterCommand(string name, string duration, Rest reason)
    {
        const banTime = getTimePeriodFromString(duration);
        if (banTime < 1)
            return false;

        auto online = context.onlinePlayer(name);
        const elsewhere = online is null ? context.remotePlayer(name) : null;
        uint accountId;
        if (elsewhere !is null)
        {
            accountId = elsewhere.entry.account;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        else if (online is null)
        {
            const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
            if (owner.isNull)
            {
                systemMessage("Player not found.");
                return true;
            }
            accountId = owner.get.account;
            systemMessage(format!"Banning player '%s' in database for '%s'."(name, reason));
        }
        else
        {
            accountId = sessionOf(online).account.id;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        // Bans apply to accounts: the character's account is banned.
        context.accounts.banAccount(accountId, banTime, player.data.name, reason);
        systemMessage(format!"This ban is due to expire %s%s."("on ",
            convertTimeStampToDataTime(context.unixTime + banTime)));
        if (online !is null)
            sessionOf(online).bannedBy(gmSink, player.data.name);
        else if (elsewhere !is null)
            gmElsewhere(name, GmRemoteOp.banKick);
        gmLog(format!"banned %s, reason %s, for %s"(name, reason, convertTimeStampToString(banTime)));
        const message = format!"%sGM: %s has been banned by %s for %s. Reason: %s"(MSG_COLOR_RED, name,
            player.data.name, convertTimeStampToString(banTime), reason);
        sendWorldText(message.length > 199 ? message[0 .. 199] : message);
        return true;
    }

    bool handleAccountBannedCommand(string name, string duration, Rest reason = Rest.init)
    {
        const period = getTimePeriodFromString(duration);
        if (period < 0)
            return false;
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.accounts.banAccount(found.get.id, period, player.data.name, reason); // 0: for ever
        const until = period ? convertTimeStampToDataTime(context.unixTime + period) : "";
        greenSystemMessage(format!("Account '%s' has been banned %s%s for reason : %s. The change will be effective "
            ~ "immediately.")(name, period ? "until " : "forever", until, reason));
        disconnectUsersWithAccount(name);
        gmLog(format!"banned account %s until %s"(name, period ? until : "permanant"));
        return true;
    }

    bool handleIPUnBanCommand(string ip)
    {
        if (!ip.canFind('/'))
        {
            redSystemMessage("Lack of CIDR address assumes a 32bit match (if you don't understand, dont worry, it "
                ~ "worked)");
            ip ~= "/32";
        }
        systemMessage(format!"Deleting [%s] from ip ban table if it exists"(ip));
        context.accounts.unbanIp(ip.endsWith("/32") ? ip[0 .. $ - 3] : ip);
        gmLog("unbanned ip address " ~ ip);
        return true;
    }

    bool handleUnBanCharacterCommand(string name)
    {
        if (auto online = context.onlinePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(online.character.data.name));
        else if (const remote = context.remotePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(remote.entry.name));
        else
            greenSystemMessage(format!"Player %s not found ingame."(name));
        const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
        if (!owner.isNull)
            context.accounts.unbanAccount(owner.get.account, player.data.name);
        systemMessage(format!"Unbanned character %s in database."(name));
        gmLog("unbanned " ~ name);
        return true;
    }

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

    bool handleRehashCommand()
    {
        import dmangos.world.config : loadWorldConfig;

        const message = format!"%s is rehashing config file."(player.data.name);
        sendWorldWideScreenText(message);
        sendWorldText(message);
        if (context.configPath.length)
        {
            try
            {
                // Settings read when the server starts (databases, port, ...) keep their values until a restart.
                context.config = loadWorldConfig(context.configPath);
                context.loadCommandOverrides();
                info!"configuration %s read again"(context.configPath);
            }
            catch (Exception e)
                error!"cannot read the configuration again: %s"(e.msg);
        }
        return true;
    }

    bool handleDBReloadCommand(string table)
    {
        import dmangos.world.worldcatalog : WorldCatalog, WorldCatalogKey;

        context.settleWrites(); // what the GM commands wrote (spawns, vendors, ...) is read back
        if (table.length < 3)
            return false;
        const started = MonoTime.currTime;
        sendWorldText(format!("%s%s initiated server-side reload of table `%s`. The server may experience some lag "
            ~ "while this occurs.")(MSG_COLOR_LIGHTRED, player.data.name, table));
        bool reloaded;
        // The tables this server keeps in memory and can read again.
        if (sicmp(table, "areatrigger_teleport") == 0 || sicmp(table, "game_tele") == 0)
        {
            context.data.setTeleports(context.database.loadAreaTriggerTeleports(), context.database.loadTeleports(),
                context.client);
            if (context.config.cluster.nodeId)
            {
                const key = WorldCatalogKey(WorldCatalog.teleports, 0);
                context.database.markWorldCatalogReload(key);
            }
            reloaded = true;
        }
        if (!reloaded)
            sendWorldText(MSG_COLOR_LIGHTRED ~ "Database reload failed.");
        else
            sendWorldText(format!"%sDatabase reload completed in %u ms."(MSG_COLOR_LIGHTBLUE,
                (MonoTime.currTime - started).total!"msecs"));
        gmLog("reloaded table " ~ table);
        return true;
    }

    /// Starts a shutdown or restart `delay` seconds away; the world update announces it as it counts down.
    void startShutdown(uint delay, bool restart)
    {
        ShutdownTimer timer;
        timer.at = context.clock() + delay.seconds;
        timer.restart = restart;
        context.shutdown = timer;
        warning!"'%s' ordered a %s in %s seconds"(player.data.name, restart ? "restart" : "shutdown", delay);
    }

    bool handleShutdownCommand(uint delay = 5)
    {
        // A bare `.server shutdown` waits the 5 seconds its help promises.
        sendWorldText(format!"%sServer shutdown initiated by %s, shutting down in %u seconds."(MSG_COLOR_LIGHTBLUE,
            player.data.name, delay));
        gmLog(format!"initiated server shutdown timer %u sec"(delay));
        startShutdown(delay, false);
        return true;
    }

    bool handleShutdownRestartCommand(uint delay = 5)
    {
        sendWorldText(format!"%sServer restart initiated by %s, shutting down in %u seconds."(MSG_COLOR_LIGHTBLUE,
            player.data.name, delay));
        gmLog(format!"initiated server restart timer %u sec"(delay));
        startShutdown(delay, true);
        return true;
    }

    bool handleCancelShutdownCommand()
    {
        if (context.shutdown.isNull)
            return false;
        sendWorldText(format!"%sServer %s cancelled by %s."(MSG_COLOR_LIGHTBLUE,
            context.shutdown.get.restart ? "Restart" : "Shutdown", player.data.name));
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

    SummonOffer summonOffer;
    bool hasSummonOffer;

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
        summonOffer = SummonOffer(mapId, at, context.clock() + 120.seconds);
        hasSummonOffer = true;
        send(ServerSummonRequest(summoner, zone, 120_000));
    }

    /// The player answered a summon offer (`CMSG_SUMMON_RESPONSE`, `dmangos.world.rituals`): whether it was this one.
    bool acceptGmSummonOffer()
    {
        if (!hasSummonOffer || context.clock() > summonOffer.expires)
            return false;
        hasSummonOffer = false;
        commandTeleport(summonOffer.map, summonOffer.position);
        return true;
    }

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

    bool handleClearCooldownsCommand()
    {
        const guid = cast(uint) player.values.get!UNIT_FIELD_TARGET;
        auto plr = getSelectedChar(true);
        if (plr is null)
        {
            plr = this;
            systemMessage("Targeting yourself.");
        }
        if (plr !is this)
            gmLog("Cleared all cooldowns for player " ~ plr.player.data.name);
        // The class's three skill lines (the skill lines of its talent trees), and its name.
        static immutable uint[3][12] lines = [[0, 0, 0], [26, 256, 257], [594, 267, 184], [50, 51, 163],
            [253, 38, 39], [56, 78, 613], [0, 0, 0], [373, 374, 375], [6, 8, 237], [355, 354, 593], [0, 0, 0],
            [573, 574, 134]];
        static immutable string[12] names = ["", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "", "Shaman",
            "Mage", "Warlock", "", "Druid"];
        const classId = plr.player.data.classId;
        if (classId >= names.length || names[classId].length == 0)
            return true;
        foreach (line; lines[classId])
            plr.clearCooldownsOnLine(line, guid);
        blueSystemMessage(format!"Cleared all %s cooldowns."(names[classId]));
        return true;
    }

    bool handleRemoveAurasCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        blueSystemMessage("Removing all auras...");
        // The removable slots: every aura but the passive ones.
        foreach (aura; plr.player.auras.list.dup)
            if (!aura.passive)
                plr.removeAura(aura);
        if (plr !is this)
            gmLog(format!"Removed all of %s's auras."(plr.player.data.name));
        return true;
    }

    bool handleResetTalentsCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.resetTalents();
        systemMessage(format!"Reset talents of %s."(plr.player.data.name));
        plr.blueSystemMessage(format!"%s reset all your talents."(player.data.name));
        gmLog("reset talents of " ~ plr.player.data.name);
        return true;
    }

    bool handleDispelAllCommand(Rest args = Rest.init)
    {
        import std.ascii : isDigit;

        // `atoi`: any number but 0 also takes the positive auras.
        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        const pos = n ? args[0 .. n].to!uint : 0;
        gmLog(format!"used dispelall command, pos %u"(pos));
        // The players of this node (those on another node of a cluster keep theirs).
        foreach (other; context.onlinePlayers)
            sessionOf(other).dispelAll(pos != 0);
        gmLog("used mass dispel");
        blueSystemMessage("Dispel action done.");
        return true;
    }

    import dmangos.world.playercreate : NewCharacter;

    bool handleIncreaseWeaponSkill(uint cnt = 1)
    {
        import std.algorithm.comparison : min;
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotRanged;

        auto pr = getSelectedChar(true);
        if (pr is null)
            pr = this;
        auto it = pr.player.inventory.equipped(equipmentSlotMainhand);
        if (it is null)
            it = pr.player.inventory.equipped(equipmentSlotRanged);
        uint skill;
        if (it !is null && it.proto !is null)
        {
            // Weapon subclasses to skill lines, oddities included (exotic ones count as staves).
            static immutable uint[21] bySubClass = [44, 172, 45, 46, 54, 160, 229, 43, 55, 136, 136, 0, 473, 0, 0,
                173, 176, 227, 226, 228, 356];
            if (it.proto.subClass < bySubClass.length)
                skill = bySubClass[it.proto.subClass];
        }
        else
            skill = 162; // unarmed
        if (skill == 0)
        {
            redSystemMessage("Unknown skill ID.");
            return false;
        }
        blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, cnt));
        gmLog(format!"increased weapon skill (%u) of %s by %u"(skill, pr.player.data.name, cnt));
        const now = pr.player.skillValue(skill);
        if (now[1] == 0)
        {
            systemMessage("The player does not know this skill. Adding it now.");
            pr.applySkill(skill, 1, 300);
        }
        else // `_AdvanceSkillLine`: up to the maximum
            pr.applySkill(skill, cast(ushort) min(now[0] + cnt, now[1]), now[1]);
        return true;
    }

    /// What a new character of `plr`'s race, class and gender starts with, as character creation gives it.
    package static bool startingAbilities(typeof(this) plr, out NewCharacter fresh)
    {
        import dmangos.auth.accounts : AccountLevel;
        import dmangos.world.playercreate : CharacterBuilder, CreateRequest;

        auto builder = new CharacterBuilder(plr.context.data, plr.context.client, plr.context.creationSettings,
            () => 0u);
        CreateRequest request = {name: plr.player.data.name, race: plr.player.data.race,
            classId: plr.player.data.classId, gender: plr.player.data.gender};
        return builder.create(0, 0, AccountLevel.player, request, true, fresh);
    }

    bool handleResetSpellsCommand()
    {
        import std.algorithm.searching : canFind;

        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        // Back to the spells a new character of its race and class has.
        NewCharacter fresh;
        if (startingAbilities(plr, fresh))
        {
            foreach (spell; plr.player.spells.dup)
                if (!fresh.spells.canFind!(s => s.spell == spell))
                    plr.unlearn(spell);
            foreach (s; fresh.spells)
                if (s.active && !s.disabled)
                    plr.learn(s.spell);
        }
        systemMessage(format!"Reset spells of %s to level 1."(plr.player.data.name));
        plr.blueSystemMessage(format!"%s reset all your spells to starting values."(player.data.name));
        gmLog(format!"reset spells of %s"(plr.player.data.name));
        return true;
    }

    bool handleResetSkillsCommand()
    {
        import std.algorithm.searching : canFind;

        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        NewCharacter fresh;
        if (!startingAbilities(plr, fresh))
            return true;
        // `_RemoveAllSkills`, then the create info's skills and the languages, the level's caps.
        foreach (skill; plr.player.skillList())
            if (!fresh.skills.canFind!(s => s.skill == skill[0]))
                plr.applySkill(skill[0], 0, 0);
        foreach (s; fresh.skills)
            plr.applySkill(s.skill, cast(ushort) s.value, cast(ushort) s.max);
        plr.player.updateSkillsForLevel(context.client);
        foreach (skill; plr.player.skillList())
            plr.applySkill(skill[0], cast(ushort) skill[1], cast(ushort) skill[2]); // saved with the new caps
        blueSystemMessage("Reset skills to default.");
        gmLog(format!"reset skills of %s to default"(plr.player.data.name));
        return true;
    }

    /// `.fixscale <scale>`: the selected creature's size, and its template's, kept.
    bool handleFixScaleCommand(float sc = 0)
    {
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        auto creature = getSelectedCreature(true);
        if (creature is null)
            return true;
        if (sc < 0.1f)
            return false;
        creature.values.set!OBJECT_FIELD_SCALE_X(sc);
        map.flushObjectChanges(creature);
        const entry = creature.spawn.entry;
        if (auto t = context.data.creatureTemplates.edit(entry))
            t.scale = sc;
        context.database.updateCreatureScale(entry, sc);
        return true;
    }

    bool handleRemoveRessurectionSickessAuraCommand()
    {
        enum uint resurrectionSickness = 15007;
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        blueSystemMessage("Removed resurrection sickness.");
        if (auto aura = plr.player.auras.find(resurrectionSickness))
            plr.removeAura(aura);
        if (plr !is this)
            gmLog(format!"Removed resurrection sickness from %s"(plr.player.data.name));
        return true;
    }

    bool handleCastAllCommand(Rest args = Rest.init)
    {
        import std.ascii : isDigit;

        if (args.length < 2)
        {
            redSystemMessage("No spellid specified.");
            return true;
        }
        // `atol`
        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        const spellId = n ? args[0 .. n].to!uint : 0;
        const spell = context.data.spells.spell(spellId);
        if (spell is null)
        {
            redSystemMessage("Invalid spell specified.");
            return true;
        }
        enum uint learnSpell = 36; // SPELL_EFFECT_LEARN_SPELL: not on everybody
        foreach (i; 0 .. 3)
            if (spell.effect[i] == learnSpell)
            {
                gmLog(format!"used wrong / learnall castall command, spellid %u"(spellId));
                redSystemMessage("Learn spell specified.");
                return true;
            }
        gmLog(format!"used castall command, spellid %u"(spellId));
        // The players of this node in the world, each casting it on itself, triggered.
        foreach (other; context.onlinePlayers)
        {
            auto who = sessionOf(other);
            if (who.player !is null && !who.transferring)
                who.castTriggeredAt(spellId, who.player.guid);
        }
        blueSystemMessage(format!"Casted spell %u on all players!"(spellId));
        return true;
    }

    bool handleCreatureRespawnCommand()
    {
        auto corpse = getSelectedCreature(false);
        if (corpse !is null && !corpse.alive && corpse.spawn.guid != 0)
        {
            const line = format!"Respawning a Creature: `%s` with entry: %u on map: %u sqlid: %u"(corpse.template_.name,
                corpse.spawn.entry, map.id, corpse.spawn.guid);
            blueSystemMessage(line);
            gmLog("Respawned" ~ line[10 .. $]);
            // The corpse goes now, the creature comes back a second later.
            context.respawnSoon(corpse, map);
            return true;
        }
        redSystemMessage("You must select a creature's corpse with a valid CreatureSpawn point.");
        return false;
    }

    // -----------------------------------------------------------------------
    // Whispers to a GM with the tag on
    // -----------------------------------------------------------------------

    bool handleWhisperBlockCommand()
    {
        // The GM tag without the <GM> flag: players' whispers get the automatic reply.
        if (player.gmTagOn)
            return false;
        player.gmTagOn = true;
        return true;
    }

    bool handleAllowWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (auto plr = context.onlinePlayer(name))
        {
            guid = plr.character.guid;
            found = plr.character.data.name;
        }
        else if (const remote = context.remotePlayer(name)) // another node's player
        {
            guid = remote.entry.guid;
            found = remote.entry.name;
        }
        else
        {
            redSystemMessage("Player not found.");
            return true;
        }
        gmTargets[guid] = true;
        blueSystemMessage(format!"Now accepting whispers from %s."(found));
        return true;
    }

    bool handleBlockWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (auto plr = context.onlinePlayer(name))
        {
            guid = plr.character.guid;
            found = plr.character.data.name;
        }
        else if (const remote = context.remotePlayer(name)) // another node's player
        {
            guid = remote.entry.guid;
            found = remote.entry.name;
        }
        else
        {
            redSystemMessage("Player not found.");
            return true;
        }
        gmTargets.remove(guid);
        blueSystemMessage(format!"Now blocking whispers from %s."(found));
        return true;
    }

    // -----------------------------------------------------------------------
    // The character group
    // -----------------------------------------------------------------------

    bool handleRemoveItemCommand(uint itemId, int count = 1)
    {
        if (count == 0)
            return false;
        const ocount = count;
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        if (count > 0)
            plr.takeItem(itemId, count);
        if (const item = itemId in context.data.items)
        {
            gmLog(format!"used remove item %s (id: %u) count %u from %s"(item.details.name, itemId, ocount,
                plr.player.data.name));
            blueSystemMessage(format!"Removing %u copies of item %s (id: %u) from %s's inventory."(ocount,
                itemLink(itemId), itemId, plr.player.data.name));
            plr.blueSystemMessage(format!"%s removed %u copies of item %s from your inventory."(player.data.name,
                ocount, itemLink(itemId)));
        }
        else
            redSystemMessage(format!"Cannot remove non valid item id: %u ."(itemId));
        return true;
    }

    bool handleAddItemSetCommand(uint setId = 0)
    {
        if (setId == 0)
        {
            redSystemMessage("You must specify a setid.");
            return true;
        }
        auto chr = getSelectedChar(true);
        if (chr is null)
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
        gmLog(format!"used add item set command, set %u, target %s"(setId, chr.player.data.name));
        foreach (entry; entries)
            if (chr.giveItem(entry, 1) == 0)
            {
                sendNotification("No free slots left!");
                return true;
            }
        greenSystemMessage(format!"Added set to inventory complete. Time: %u ms"((MonoTime.currTime - started)
            .total!"msecs"));
        return true;
    }

    bool handleAdvanceAllSkillsCommand(uint amount = 0)
    {
        if (amount == 0)
        {
            redSystemMessage("An amount to increment is required.");
            return true;
        }
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (skill; plr.player.skillList) // `_AdvanceAllSkills`: each up to its maximum
            plr.applySkill(skill[0], cast(ushort) min(skill[1] + amount, skill[2]), cast(ushort) skill[2]);
        plr.greenSystemMessage(format!"Advanced all your skill lines by %u points."(amount));
        gmLog(format!"advanced all skills by %u on %s"(amount, plr.player.data.name));
        return true;
    }

    bool handleShowItems()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (item; plr.player.inventory.all()) // each item as a link, with its count
            systemMessage(format!"Item %u %s Count %u Slot %u ContainerSlots %u"(item.entry, itemLink(item.entry),
                cast(ubyte) plr.player.inventory.count(item.entry), item.slot, item.proto.containerSlots));
        gmLog(format!"used show items command on %s,"(plr.player.data.name));
        return true;
    }

    bool handleShowSkills()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (skill; plr.player.skillList)
            systemMessage(format!"Skill %u %s %u/%u"(skill[0], skillName(skill[0]), skill[1], skill[2]));
        gmLog(format!"used show skills command on %s,"(plr.player.data.name));
        return true;
    }

    /// `.npc npcfollow`: the selected creature follows this player.
    bool handleNpcFollowCommand()
    {
        import dmangos.script.api : EntityRef;
        import std.math : PI;

        auto creature = getSelectedCreature(true);
        if (creature is null)
            return true;
        creature.ai.hostFollow(EntityRef(player.guid), 2.0f, PI / 2);
        gmLog(format!"used npc follow command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    /// `.npc nullfollow`: the selected creature follows nobody; it moves as before.
    bool handleNullFollowCommand()
    {
        import dmangos.script.api : EntityRef;

        auto creature = getSelectedCreature(true);
        if (creature is null)
            return true;
        creature.ai.hostFollow(EntityRef.init, 0, 0);
        gmLog(format!"cancelled npc follow command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    /**
     * `.character forcerename <name>`: the character must take a new name at its next login (CMaNGOS's `at_login`
     * rename flag, ArcEmu's `forced_rename_pending`); its old name is reserved (in memory: the world database
     * keeps `reserved_name`, which the server does not write).
     */
    bool handleForceRenameCommand(string name)
    {
        import dmangos.world.characters : AtLoginFlags;

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
            auto other = sessionOf(online);
            other.player.data.atLogin |= AtLoginFlags.rename;
            other.savePlayer();
            other.blueSystemMessage(format!"%s forced your character to be renamed next logon."(player.data.name));
        }
        else
            context.database.addAtLoginFlags(guid, AtLoginFlags.rename);
        import dmangos.world.worlddata : toLowerName;

        context.data.reservedNames[toLowerName(realName)] = true;
        greenSystemMessage(format!"Forcing %s to rename his character next logon."(name));
        gmLog(format!"forced %s to rename his charater (%u)"(realName, guid));
        return true;
    }

    bool handleRenameCommand(string name1, string name2)
    {
        import dmangos.world.names : checkPlayerName, CharNameResult;

        const config = context.config;
        if (checkPlayerName(name2, config.minPlayerName, config.strictPlayerNames, config.realmZone)
            != CharNameResult.CHAR_NAME_SUCCESS)
        {
            redSystemMessage("Enter a valid character name.");
            return true;
        }
        const guid = context.database.characterGuid(normalizedName(name1));
        if (guid == 0)
        {
            redSystemMessage("Player not found with this name.");
            return true;
        }
        const newName = normalizedName(name2);
        if (context.database.nameTaken(newName))
        {
            redSystemMessage("Player found with this name in use already.");
            return true;
        }
        context.database.renameCharacter(guid, newName);
        if (auto online = context.onlinePlayer(name1))
            sessionOf(online).renamedBy(gmSink, player.data.name, newName);
        else
            gmElsewhere(name1, GmRemoteOp.rename, newName);
        greenSystemMessage(format!"Changed name of '%s' to '%s'."(name1, name2));
        gmLog(format!"renamed character %s (GUID: %u) to %s"(name1, guid, name2));
        return true;
    }

    // -----------------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------------

    /// "Creature 42: Name" with the part searched for in light red.
    void sendHighlightedName(string prefix, string fullName, string search, uint id)
    {
        const offset = fullName.toLower.indexOf(search);
        string text = format!"%s %u: %s"(prefix, id, MSG_COLOR_WHITE);
        if (offset < 0)
            text ~= fullName;
        else
            text ~= fullName[0 .. offset] ~ MSG_COLOR_LIGHTRED ~ fullName[offset .. offset + search.length]
                ~ MSG_COLOR_WHITE ~ fullName[offset + search.length .. $];
        systemMessage(text);
    }

    /// The lookups that need four letters, and stop at 25 results.
    bool lookupNamed(string search, string kind, bool blue, LookupResult[] delegate(string) find)
    {
        const x = search.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        void say(string text)
        {
            if (blue)
                blueSystemMessage(text);
            else
                greenSystemMessage(text);
        }

        say(format!"Starting search of %s `%s`..."(kind, x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; find(x))
        {
            if (kind == "item")
            {
                const item = row.id in context.data.items;
                systemMessage(format!"Item %u %s ContainerSlots %u"(row.id, itemLink(row.id), item.containerSlots));
            }
            else
                sendHighlightedName(kind == "creature" ? "Creature" : kind == "spell" ? "Spell" : "Skill", row.name, x,
                    row.id);
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        say(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    bool handleCreatureSpawnCommand(uint entry = 0)
    {
        if (entry == 0)
            return false;
        const t = entry in context.data.creatureTemplates;
        if (t is null)
        {
            redSystemMessage("Invalid entry id.");
            return true;
        }
        const at = player.position;
        auto creature = context.spawnCreatureAt(map, entry, at);
        if (creature is null)
        {
            redSystemMessage("Could not spawn the creature.");
            return true;
        }
        blueSystemMessage(format!"Spawned a creature `%s` with entry %u at %f %f %f on map %u"(t.name, entry, at.x, at.y,
            at.z, player.data.map));
        gmLog(format!"spawned a %s at %u %f %f %f"(t.name, player.data.map, at.x, at.y, at.z));
        return true;
    }

    bool handleGetStandingCommand(uint faction = 0)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        const entry = context.client.factions.lookup(faction);
        const rep = plr.player.reputation;
        const standing = rep is null ? 0 : rep.standingWith(faction);
        const base = rep is null || entry is null ? 0 : rep.baseOf(entry);
        greenSystemMessage(format!"Reputation for faction %u:"(faction));
        systemMessage(format!"Base Standing: %d"(base));
        blueSystemMessage(format!"Standing: %d"(standing));
        return true;
    }

    bool handleSetStandingCommand(uint faction, int standing)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        blueSystemMessage(format!"Setting standing of %u to %d on %s."(faction, standing, plr.player.data.name));
        if (plr.player.reputation !is null) // to that value, its neighbouring factions untouched
            plr.modifyReputation(faction, standing - plr.player.reputation.standingWith(faction), true);
        plr.flushPlayerChanges();
        plr.greenSystemMessage(format!"%s set your standing of faction %u to %d."(player.data.name, faction, standing));
        gmLog(format!"set standing of faction %u to %u for %s"(faction, standing, plr.player.data.name));
        return true;
    }

    bool handleLookupFactionCommand(Rest search)
    {
        const x = search.text.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        greenSystemMessage(format!"Starting search of faction `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (id; 0 .. context.client.factions.idLimit)
            if (const f = context.client.factions.lookup(id))
                if (f.name[0].toLower.canFind(x))
                {
                    sendHighlightedName("Faction", f.name[0], x, f.id);
                    if (++count == 25)
                    {
                        redSystemMessage("More than 25 results returned. aborting.");
                        break;
                    }
                }
        greenSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    bool handleLookupItemCommand(Rest search)
    {
        return lookupNamed(search, "item", true, (x) {
            LookupResult[] found;
            foreach (entry, ref item; context.data.items)
                if (item.details.name.toLower.canFind(x))
                    found ~= LookupResult(entry, item.details.name);
            found.sort!((a, b) => a.id < b.id);
            return found;
        });
    }

    bool handleLookupCreatureCommand(Rest search)
    {
        return lookupNamed(search, "creature", false, x => context.database.lookup(LookupTable.creature, x, 25));
    }

    bool handleLookupSpellCommand(Rest search)
    {
        return lookupNamed(search, "spell", false, x => context.database.lookup(LookupTable.spell, x, 25));
    }

    bool handleLookupSkillCommand(Rest search)
    {
        return lookupNamed(search, "skill", false, (x) {
            LookupResult[] found;
            foreach (ref skill; context.client.skillLines.rows)
                if (skill.name[0].toLower.canFind(x))
                    found ~= LookupResult(skill.id, skill.name[0]);
            return found;
        });
    }

    bool handleLookupObjectCommand(Rest search)
    {
        const x = search.toLower;
        greenSystemMessage(format!"Starting search of object `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.gameObject, x, 50))
        {
            sendMultilineMessage(format!"|cfffff000Object %u|cffFFFFFF: %s"(row.id, row.name));
            if (++count >= 50)
            {
                redSystemMessage("More than 50 results returned. aborting.");
                break;
            }
        }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.");
        blueSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    /// `.lookup quest`: the quests whose name matches the search text, at most 25.
    bool handleQuestLookupCommand(Rest search)
    {
        const x = search.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        blueSystemMessage(format!"Starting search of quests `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.quest, x, 25))
        {
            sendMultilineMessage(format!"|cff00ccff%u: %s\n"(row.id, row.name));
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.\n\n");
        blueSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    // -----------------------------------------------------------------------
    // Creatures
    // -----------------------------------------------------------------------

    bool handleNpcInfoCommand()
    {
        import dmangos.world.objects : counterOf;

        auto crt = getSelectedCreature(true);
        if (crt is null)
            return false;
        auto v = &crt.values;
        blueSystemMessage("Showing creature info for " ~ crt.template_.name);
        systemMessage(format!"GUID: %d"(cast(uint) crt.guid));
        systemMessage(format!"Faction: %d"(v.get!UNIT_FIELD_FACTIONTEMPLATE));
        systemMessage(format!"NPCFlags: %d"(v.get!UNIT_NPC_FLAGS));
        systemMessage(format!"DisplayID: %d"(v.get!UNIT_FIELD_DISPLAYID));
        systemMessage(format!"Health (cur/max): %d/%d"(v.get!UNIT_FIELD_HEALTH, v.get!UNIT_FIELD_MAXHEALTH));
        systemMessage(format!"Mana (cur/max): %d/%d"(v.get!UNIT_FIELD_POWER1, v.get!UNIT_FIELD_MAXPOWER1));
        systemMessage("Armor/Holy/Fire/Nature/Frost/Shadow/Arcane");
        systemMessage(format!"%d/%d/%d/%d/%d/%d/%d"(v.get!UNIT_FIELD_RESISTANCES(0), v.get!UNIT_FIELD_RESISTANCES(1),
            v.get!UNIT_FIELD_RESISTANCES(2), v.get!UNIT_FIELD_RESISTANCES(3), v.get!UNIT_FIELD_RESISTANCES(4),
            v.get!UNIT_FIELD_RESISTANCES(5), v.get!UNIT_FIELD_RESISTANCES(6)));
        systemMessage(format!"Damage (min/max): %f/%f"(v.get!UNIT_FIELD_MINDAMAGE, v.get!UNIT_FIELD_MAXDAMAGE));
        colorSystemMessage(MSG_COLOR_RED, format!"Entry ID: %d"(v.get!OBJECT_FIELD_ENTRY));
        colorSystemMessage(MSG_COLOR_RED, format!"SQL Entry ID: %d"(counterOf(crt.guid)));
        const bytes = v.get!UNIT_FIELD_BYTES_0;
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
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE;
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
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Setting standing of 72 to 1000 on Anduin.|r"]);
    assert(me.reputation.standingWith(72) == 1000);
    assert(systemMessages(anduin.read()).canFind(MSG_COLOR_GREEN ~ "Varian set your standing of faction 72 to 1000.|r"));
    gm.say(".character getstanding 72");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Reputation for faction 72:|r", "Base Standing: 0",
        MSG_COLOR_LIGHTBLUE ~ "Standing: 1000|r"]);
    gm.say(".character resetreputation");
    assert(systemMessages(gm.read()) == ["Done. Relog for changes to take effect."]);
    assert(me.reputation.standingWith(72) == 0);
}

/// `.admin castall` casts a spell on every player (but not a learning one); `.removesickness` takes resurrection sickness off.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.commands : MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
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
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "No spellid specified.|r"], "one figure is too short");
    gm.say(".admin castall 95999");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Invalid spell specified.|r"]);
    gm.say(".admin castall 95901");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Learn spell specified.|r"]);
    gm.say(".admin castall 95900");
    assert(systemMessages(gm.read()).canFind(MSG_COLOR_LIGHTBLUE ~ "Casted spell 95900 on all players!|r"));
    assert(victim.auras.find(blessing) !is null && (cast(Player) gm.session.character).auras.find(blessing) !is null);

    // No weapon: unarmed (162), from 1 a step.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    const unarmed = victim.skillValue(162);
    gm.say(".character increaseweaponskill 2");
    assert(systemMessages(gm.read())[0] == MSG_COLOR_LIGHTBLUE ~ "Modifying skill line 162. Advancing 2 times.|r");
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
        assert(systemMessages(gm.read()) == ["Reset spells of Anduin to level 1."]);
        assert(systemMessages(anduin.read()).canFind(MSG_COLOR_LIGHTBLUE ~ "Varian reset all your spells to starting values.|r"));
        assert(!victim.knowsSpell(blessing));
        {
            NewCharacter fresh;
            assert(anduin.session.inWorld.startingAbilities(anduin.session.inWorld, fresh) && fresh.spells.length);
            foreach (s; fresh.spells)
                if (s.active && !s.disabled)
                    assert(victim.knowsSpell(s.spell), "a new character's spells");
        }
        gm.say(".character resetskills");
        assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Reset skills to default.|r"]);
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
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Removed resurrection sickness.|r"]);
    assert(victim.auras.find(sickness) is null);
}

// `.guild create`, `members` and `disband` on the GM itself (nothing selected), in ArcEmu's words.
unittest
{
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    gm.read();
    gm.say(".guild create Kirin Tor");
    assert(systemMessages(gm.read()).canFind(MSG_COLOR_GREEN ~ "Guild created|r"));
    auto g = context.guilds.named("Kirin Tor");
    assert(g !is null && g.leader == 7);
    gm.say(".guild create Kirin Tor");
    assert(systemMessages(gm.read()).canFind!(m => m.canFind("is already in a guild.")));
    gm.say(".guild members");
    const members = systemMessages(gm.read());
    assert(members.canFind(MSG_COLOR_GREEN ~ "Now showing guild members for Kirin Tor|r"));
    assert(members.canFind!(m => m.canFind("Jaina (Rank: ")));
    gm.say(".guild disband");
    assert(systemMessages(gm.read()).canFind(MSG_COLOR_GREEN ~ "Disbanded Guild: Kirin Tor|r"));
    assert(context.guilds.named("Kirin Tor") is null);
    gm.say(".guild create Dal4ran");
    assert(systemMessages(gm.read()).canFind!(m => m.canFind("Error, name can only contain chars A-Z and a-z.")));
}
