/**
 * GM commands that run the server and its accounts (ArcEmu `Level3.cpp`,
 * `Level2.cpp` and `Chat.cpp`: announcements, `.kick`, `.ban`/`.unban`,
 * `.account`, `.server`, `.gm` whisper blocking, `.admin playall`). Mixed
 * into `dmangos.world.session.WorldSession`.
 *
 * Accounts and bans go through the login server's `LoginDatabase`, so they
 * are written exactly as the login server writes them, into CMaNGOS's
 * `realmd` tables. Characters cannot be banned on their own in CMaNGOS's
 * schema: `.ban character` bans the character's account, as CMaNGOS's
 * `.ban character` does.
 */
module dmangos.world.gmadmin;

/// See the module documentation.
mixin template AdminCommands()
{
    import core.time : seconds;
    import std.array : join, split;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.typecons : Nullable;
    import std.uni : toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands : Command, parseAccountLevel, parseDuration, readArguments;
    import dmangos.world.context : ShutdownTimer;
    import dmangos.world.map : packetBody;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.queries : chatMessage;

private:
    // -----------------------------------------------------------------------
    // Announcements
    // -----------------------------------------------------------------------

    /// Sends a body to everyone online, or to the game masters only.
    void toEveryone(Opcode opcode, const(ubyte)[] body_, bool gmsOnly = false)
    {
        foreach (other; context.onlinePlayers)
            if (!gmsOnly || other.security > AccountLevel.player)
                other.deliver(opcode, body_);
    }

    @Command("announce", AccountLevel.moderator, "text", "Sends a message to everyone online, in the chat window.")
    bool commandAnnounce(string args)
    {
        if (args.length == 0)
            return false;
        toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            format!"|cffff6060<%s>|r %s: %s"(account.level == AccountLevel.administrator ? "Admin" : "GM",
            player.data.name, args)));
        return true;
    }

    @Command("wannounce", AccountLevel.moderator, "text", "Sends a message to everyone online, in the middle of the screen.")
    bool commandWideAnnounce(string args)
    {
        if (args.length == 0)
            return false;
        toEveryone(Opcode.SMSG_AREA_TRIGGER_MESSAGE, packetBody(ServerAreaTriggerMessage(
            format!"%s: %s"(player.data.name, args))));
        return true;
    }

    @Command("gmannounce", AccountLevel.moderator, "text", "Sends a message to the game masters online.")
    bool commandGmAnnounce(string args)
    {
        if (args.length == 0)
            return false;
        toEveryone(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            format!"|cff00ccff[GM] %s:|r %s"(player.data.name, args)), true);
        return true;
    }

    @Command("admin playall", AccountLevel.administrator, "sound", "Plays a sound (SoundEntries.dbc) to everyone online.",
        ["playall"])
    bool commandPlayAll(string args)
    {
        uint sound;
        if (!readArguments!1(args, sound))
            return false;
        toEveryone(Opcode.SMSG_PLAY_SOUND, packetBody(ServerPlaySound(sound)));
        return true;
    }

    @Command("logcomment", AccountLevel.moderator, "text", "Writes a comment to the server log, for the administrators.")
    bool commandLogComment(string args)
    {
        if (args.length == 0)
            return false;
        info!"GM comment from '%s' (%s): %s"(player.data.name, account.username, args);
        sendSystemMessage("Comment logged.");
        return true;
    }

    // -----------------------------------------------------------------------
    // Whisper blocking (the gm group)
    // -----------------------------------------------------------------------

    @Command("gm whisperblock", AccountLevel.moderator, "", "Blocks, or unblocks, whispers from players.")
    bool commandWhisperBlock(string)
    {
        acceptWhispers = !acceptWhispers;
        sendSystemMessage(acceptWhispers ? "Accepting whispers again." : "Whispers from players are blocked.");
        return true;
    }

    @Command("gm allowwhispers", AccountLevel.moderator, "name", "Lets a player whisper you while you block whispers.",
        ["allowwhispers"])
    bool commandAllowWhispers(string args)
    {
        auto target = context.onlinePlayer(args);
        if (target is null)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(args));
            return true;
        }
        whisperExceptions[target.character.guid] = true;
        sendSystemMessage(format!"%s may now whisper you."(target.character.data.name));
        return true;
    }

    @Command("gm blockwhispers", AccountLevel.moderator, "name", "Takes back `.gm allowwhispers`.", ["blockwhispers"])
    bool commandBlockWhispers(string args)
    {
        auto target = context.onlinePlayer(args);
        if (target is null)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(args));
            return true;
        }
        whisperExceptions.remove(target.character.guid);
        sendSystemMessage(format!"%s may no longer whisper you."(target.character.data.name));
        return true;
    }

    // -----------------------------------------------------------------------
    // Kicking
    // -----------------------------------------------------------------------

    @Command("kick byplayer", AccountLevel.gameMaster, "name [reason]", "Disconnects a player.",
        ["kickplayer", "killbyplayer"])
    bool commandKickPlayer(string args)
    {
        string name, reason = "no reason";
        if (!readArguments!1(args, name, reason))
            return false;
        auto target = context.onlinePlayer(name);
        if (target is null)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(name));
            return true;
        }
        if (target.security > account.level)
        {
            sendSystemMessage("You cannot kick a player of a higher level.");
            return true;
        }
        sendSystemMessage(format!"Kicked %s: %s"(target.character.data.name, reason));
        sessionOf(target).kick(format!"kicked by %s: %s"(player.data.name, reason));
        return true;
    }

    @Command("kick byaccount", AccountLevel.gameMaster, "account", "Disconnects the session of an account.",
        ["killbyaccount"])
    bool commandKickAccount(string args)
    {
        if (args.length == 0)
            return false;
        const found = context.accounts.findAccount(args);
        auto session = found.isNull ? null : context.sessionOfAccount(found.get.id);
        if (session is null)
        {
            sendSystemMessage(format!"Account %s is not online."(args));
            return true;
        }
        session.kick(format!"kicked by %s"(player.data.name));
        sendSystemMessage(format!"Kicked account %s."(args));
        return true;
    }

    @Command("kick byip", AccountLevel.gameMaster, "address", "Disconnects every session from an address.")
    bool commandKickIp(string args)
    {
        if (args.length == 0)
            return false;
        auto sessions = context.sessionsFrom(args);
        foreach (session; sessions)
            session.kick(format!"kicked by %s"(player.data.name));
        sendSystemMessage(format!"Kicked %s sessions from %s."(sessions.length, args));
        return true;
    }

    // -----------------------------------------------------------------------
    // Bans (World::BanAccount, RemoveBanAccount)
    // -----------------------------------------------------------------------

    /// "1d2h" or "perm": seconds, 0 for permanent; null if neither.
    static Nullable!uint banDuration(string text)
    {
        if (text == "perm" || text == "permanent" || text == "-1" || text == "0")
            return Nullable!uint(0);
        return parseDuration(text);
    }

    /// Bans an account and kicks its session.
    void banAccountId(uint accountId, string accountName, uint duration, string reason)
    {
        context.accounts.banAccount(accountId, duration, player.data.name, reason);
        if (auto session = context.sessionOfAccount(accountId))
            session.kick(format!"banned by %s: %s"(player.data.name, reason));
        sendSystemMessage(format!"Account %s is banned %s: %s"(accountName,
            duration ? format!"for %s seconds"(duration) : "permanently", reason));
    }

    @Command("ban account", AccountLevel.gameMaster, "account duration reason",
        "Bans an account; duration like 1d2h30m, or perm.", ["account ban"])
    bool commandBanAccount(string args)
    {
        string name, duration, reason;
        if (!readArguments!3(args, name, duration, reason) || banDuration(duration).isNull)
            return false;
        const found = context.accounts.findAccount(name);
        if (found.isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(name));
            return true;
        }
        if (found.get.level >= account.level && account.level < AccountLevel.administrator)
        {
            sendSystemMessage("You cannot ban an account of your level or higher.");
            return true;
        }
        banAccountId(found.get.id, found.get.username, banDuration(duration).get, reason);
        return true;
    }

    @Command("ban character", AccountLevel.gameMaster, "name duration reason",
        "Bans a character's account (CMaNGOS bans accounts, not characters).", ["banchar"])
    bool commandBanCharacter(string args)
    {
        string name, duration, reason;
        if (!readArguments!3(args, name, duration, reason) || banDuration(duration).isNull)
            return false;
        const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
        if (owner.isNull)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(name));
            return true;
        }
        banAccountId(owner.get.account, name, banDuration(duration).get, reason);
        return true;
    }

    @Command("ban ip", AccountLevel.gameMaster, "address duration reason", "Bans an address.", ["addipban"])
    bool commandBanIp(string args)
    {
        string ip, duration, reason;
        if (!readArguments!3(args, ip, duration, reason) || banDuration(duration).isNull)
            return false;
        context.accounts.banIp(ip, banDuration(duration).get, player.data.name, reason);
        foreach (session; context.sessionsFrom(ip))
            session.kick(format!"address banned by %s"(player.data.name));
        sendSystemMessage(format!"Address %s is banned: %s"(ip, reason));
        return true;
    }

    @Command("unban account", AccountLevel.gameMaster, "account", "Lifts an account's bans.", ["account unban"])
    bool commandUnbanAccount(string args)
    {
        const found = context.accounts.findAccount(args);
        if (found.isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(args));
            return true;
        }
        context.accounts.unbanAccount(found.get.id, player.data.name);
        sendSystemMessage(format!"Account %s is no longer banned."(found.get.username));
        return true;
    }

    @Command("unban character", AccountLevel.gameMaster, "name", "Lifts the bans of a character's account.", ["unbanchar"])
    bool commandUnbanCharacter(string args)
    {
        const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(args)));
        if (owner.isNull)
        {
            sendSystemMessage(format!"Player (%s) does not exist."(args));
            return true;
        }
        context.accounts.unbanAccount(owner.get.account, player.data.name);
        sendSystemMessage(format!"%s's account is no longer banned."(args));
        return true;
    }

    @Command("unban ip", AccountLevel.gameMaster, "address", "Lifts an address's ban.", ["delipban"])
    bool commandUnbanIp(string args)
    {
        if (args.length == 0)
            return false;
        context.accounts.unbanIp(args);
        sendSystemMessage(format!"Address %s is no longer banned."(args));
        return true;
    }

    // -----------------------------------------------------------------------
    // Accounts
    // -----------------------------------------------------------------------

    @Command("account create", AccountLevel.administrator, "name password", "Creates an account.", ["createaccount"])
    bool commandAccountCreate(string args)
    {
        string name, password;
        if (!readArguments!2(args, name, password) || password.split.length != 1)
            return false;
        if (!context.accounts.findAccount(name).isNull)
        {
            sendSystemMessage(format!"Account %s already exists."(name));
            return true;
        }
        try
        {
            const created = context.accounts.createAccount(name, password);
            sendSystemMessage(format!"Account %s created (id %s)."(created.username, created.id));
        }
        catch (Exception e)
            sendSystemMessage(format!"Account not created: %s"(e.msg));
        return true;
    }

    @Command("account password", AccountLevel.administrator, "name password", "Sets an account's password.",
        ["changepassword"])
    bool commandAccountPassword(string args)
    {
        string name, password;
        if (!readArguments!2(args, name, password) || password.split.length != 1)
            return false;
        if (context.accounts.findAccount(name).isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(name));
            return true;
        }
        try
        {
            context.accounts.setPassword(name, password);
            sendSystemMessage(format!"The password of %s is changed."(name));
        }
        catch (Exception e)
            sendSystemMessage(format!"Password not changed: %s"(e.msg));
        return true;
    }

    @Command("account level", AccountLevel.administrator, "name level",
        "Sets an account's level: 0 player, 1 moderator, 2 game master, 3 administrator.")
    bool commandAccountLevel(string args)
    {
        string name, levelText;
        if (!readArguments!2(args, name, levelText))
            return false;
        const level = parseAccountLevel(levelText);
        if (level.isNull)
            return false;
        if (context.accounts.findAccount(name).isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(name));
            return true;
        }
        context.accounts.setLevel(name, level.get);
        sendSystemMessage(format!"Account %s is now %s; it applies at the next login."(name, level.get));
        return true;
    }

    @Command("account mute", AccountLevel.gameMaster, "account duration", "Turns an account's chat off for a while.")
    bool commandAccountMute(string args)
    {
        string name, durationText;
        if (!readArguments!2(args, name, durationText))
            return false;
        const duration = parseDuration(durationText);
        const found = context.accounts.findAccount(name);
        if (duration.isNull || duration.get == 0)
            return false;
        if (found.isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(name));
            return true;
        }
        const until = context.unixTime + duration.get;
        context.database.setMuteTime(found.get.id, until);
        if (auto session = context.sessionOfAccount(found.get.id))
        {
            auto muted = cast(WorldSession) session;
            muted.account.muteTime = until;
            muted.sendSystemMessage(format!"Your chat is disabled for %s seconds."(duration.get));
        }
        sendSystemMessage(format!"Account %s is muted for %s seconds."(name, duration.get));
        return true;
    }

    @Command("account unmute", AccountLevel.gameMaster, "account", "Turns an account's chat on again.")
    bool commandAccountUnmute(string args)
    {
        const found = context.accounts.findAccount(args);
        if (found.isNull)
        {
            sendSystemMessage(format!"Account %s does not exist."(args));
            return true;
        }
        context.database.setMuteTime(found.get.id, 0);
        if (auto session = context.sessionOfAccount(found.get.id))
            (cast(WorldSession) session).account.muteTime = 0;
        sendSystemMessage(format!"Account %s is no longer muted."(args));
        return true;
    }

    // -----------------------------------------------------------------------
    // The server
    // -----------------------------------------------------------------------

    @Command("server shutdown", AccountLevel.administrator, "[seconds]", "Stops the server, counting down (5 seconds by default).",
        ["servershutdown"])
    bool commandShutdown(string args)
    {
        return startShutdown(args, false);
    }

    @Command("server restart", AccountLevel.administrator, "[seconds]",
        "Stops the server with exit code 2, for a script that starts it again.", ["serverrestart"])
    bool commandRestart(string args)
    {
        return startShutdown(args, true);
    }

    bool startShutdown(string args, bool restart)
    {
        uint delay = 5;
        if (!readArguments!0(args, delay))
            return false;
        ShutdownTimer timer;
        timer.at = context.clock() + delay.seconds;
        timer.restart = restart;
        context.shutdown = timer;
        warning!"'%s' ordered a %s in %s seconds"(player.data.name, restart ? "restart" : "shutdown", delay);
        sendSystemMessage(format!"Server %s in %s seconds."(restart ? "restart" : "shutdown", delay));
        return true;
    }

    @Command("server cancelshutdown", AccountLevel.administrator, "", "Cancels a shutdown or restart.")
    bool commandCancelShutdown(string)
    {
        if (context.shutdown.isNull)
        {
            sendSystemMessage("No shutdown is counting down.");
            return true;
        }
        const restart = context.shutdown.get.restart;
        context.shutdown.nullify();
        toEveryone(Opcode.SMSG_SERVER_MESSAGE, packetBody(ServerServerMessage(restart
            ? ServerMessageType.restartCancelled : ServerMessageType.shutdownCancelled, "")));
        sendSystemMessage("Shutdown cancelled.");
        return true;
    }

    @Command("server setmotd", AccountLevel.gameMaster, "text", "Sets the message of the day ('@' starts a new line), until a restart.",
        ["setmotd"])
    bool commandSetMotd(string args)
    {
        if (args.length == 0)
            return false;
        context.config.motd = args;
        sendSystemMessage("Message of the day set to: " ~ args);
        return true;
    }

    @Command("server saveall", AccountLevel.gameMaster, "", "Saves every character online.", ["saveall"])
    bool commandSaveAll(string)
    {
        size_t count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).savePlayer();
            ++count;
        }
        sendSystemMessage(format!"Saved %s characters."(count));
        return true;
    }

    @Command("server save", AccountLevel.gameMaster, "", "Saves the selected character, or yours.")
    bool commandServerSave(string)
    {
        auto target = selectedOrSelf();
        target.savePlayer();
        sendSystemMessage(format!"Saved %s."(target.player.data.name));
        return true;
    }

    @Command("server reloadtable", AccountLevel.administrator, "areatrigger_teleport|game_tele",
        "Reads a world table again.", ["reloadtable"])
    bool commandReloadTable(string args)
    {
        switch (args.toLower)
        {
        case "areatrigger_teleport", "game_tele":
            context.data.setTeleports(context.database.loadAreaTriggerTeleports(), context.database.loadTeleports(),
                context.client);
            sendSystemMessage(format!"Reloaded: %s area trigger teleports, %s teleport locations."(
                context.data.areaTriggers.length, context.data.teleports.length));
            return true;
        default:
            return false;
        }
    }

    @Command("server netstatus", AccountLevel.moderator, "", "Shows the connections and your latency.")
    bool commandNetStatus(string)
    {
        sendSystemMessage(format!"Sessions: %s (at most %s). Your latency: %s ms."(context.sessionCount,
            context.peakSessions, latencyMs));
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : seconds;
    import dmangos.auth.accounts : BanState;
    import dmangos.auth.database : MemoryLoginDatabase;
    import dmangos.world.testclient;
}

/// Accounts, bans, mutes and kicks, through the login database.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto accounts = cast(MemoryLoginDatabase) context.accounts;
    auto admin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.administrator);
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0));
    admin.read();
    jaina.read();

    admin.say(".account create Thrall lokTar");
    assert(!accounts.findAccount("THRALL").isNull);
    admin.say(".account level thrall gm");
    assert(accounts.findAccount("THRALL").get.level == AccountLevel.gameMaster);

    // A mute keeps Jaina quiet; unmuted, she can speak again.
    admin.say(".account mute jaina 1h");
    assert(db.muteTimes[accounts.findAccount("JAINA").get.id] > 0);
    jaina.read();
    jaina.say("hello?");
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_NOTIFICATION]);
    admin.say(".account unmute jaina");
    admin.read();
    jaina.say("hello!");
    assert(opcodesOf(admin.read()) == [Opcode.SMSG_MESSAGECHAT]);

    // Banning her account kicks her; the ban is there for the login server.
    admin.say(".ban character jaina 1d spamming");
    assert(jaina.session.wantsClose && accounts.findAccount("JAINA").get.ban != BanState.none);
    admin.say(".unban account jaina");
    assert(accounts.findAccount("JAINA").get.ban == BanState.none);
    admin.say(".ban ip 10.1.2.3 perm proxy");
    assert(accounts.isIpBanned("10.1.2.3"));
    admin.say(".ban account jaina sometime reason");
    assert(systemMessages(admin.read())[$ - 1].canFind("Syntax: .ban account"));
}

/// Shutdowns count down with warnings, and can be cancelled; announcements and whisper blocking.
unittest
{
    import core.time : MonoTime;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto admin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.administrator);
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5000, 0, 0));
    admin.read();
    jaina.read();

    admin.say(".announce The server is fine");
    assert(systemMessages(jaina.read())[0].canFind("The server is fine"));
    admin.say(".server shutdown 30");
    assert(!context.update(now + 1.seconds) && opcodesOf(jaina.read()) == [Opcode.SMSG_SERVER_MESSAGE]);
    assert(!context.update(now + 2.seconds) && jaina.read().length == 0, "no warning every second yet");
    admin.say(".server cancelshutdown");
    assert(context.shutdown.isNull && opcodesOf(jaina.read()) == [Opcode.SMSG_SERVER_MESSAGE]);
    admin.say(".server restart 0");
    assert(context.update(now + 1.seconds) && context.restartRequested);

    // A game master blocking whispers looks offline, except to those allowed.
    admin.say(".gm whisperblock");
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "help", "Anduin"));
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_CHAT_PLAYER_NOT_FOUND]);
    admin.say(".gm allowwhispers jaina");
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "help", "Anduin"));
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);

    admin.say(".kickplayer jaina bye");
    assert(jaina.session.wantsClose);
}
