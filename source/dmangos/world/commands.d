/**
 * Chat commands: messages that start with `.` (or `!`), as CMaNGOS's
 * `ChatHandler::ParseCommands` reads them from `Chat/Level*.cpp`.
 *
 * A command is a `WorldSession` method marked with `@Command`; the table
 * that `runCommand` searches is collected from those attributes at compile
 * time, so a new command is one method:
 * ---
 * @Command("gm chat", AccountLevel.moderator, "[on|off]", "Shows or hides the GM badge in chat.")
 * bool commandGmChat(string args) { ... }
 * ---
 * Every word of a command may be shortened (`.te Stormwind`, `.g x 1 2 3`
 * does not exist but `.go x 1 2 3` does), and a two-word command is tried
 * before a one-word one. A method returns false when its arguments are
 * wrong; the player is then shown the syntax. A player typing something
 * that is not a command, or not one for its level, simply says it, as in
 * CMaNGOS.
 */
module dmangos.world.commands;

import std.algorithm.iteration : splitter;
import std.uni : sicmp;

import dmangos.auth.accounts : AccountLevel;

/// Marks a chat command. `name` has one or two words; `syntax` describes the arguments.
struct Command
{
    string name;
    AccountLevel level;
    string syntax;
    string help;
}

/// `hasStringAbbr`: whether `word` is a non-empty prefix of `full`, in any case.
bool abbreviates(const(char)[] word, const(char)[] full) pure @safe
{
    return word.length > 0 && word.length <= full.length && sicmp(word, full[0 .. word.length]) == 0;
}

unittest
{
    assert(abbreviates("te", "tele") && abbreviates("TELE", "tele") && !abbreviates("teles", "tele"));
    assert(!abbreviates("", "gm"));
}

/// See the module documentation.
mixin template ChatCommands()
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : startsWith;
    import std.algorithm.sorting : sort;
    import std.array : array, replace, split;
    import std.typecons : Nullable;
    import std.uni : sicmp;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.string : strip;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands : abbreviates, Command;
    import dmangos.world.movement : Position;
    import dmangos.world.online : OnlinePlayer;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.queries : chatMessage;
    import dmangos.world.updatefields : UNIT_FIELD_TARGET;

private:
    struct CommandEntry
    {
        Command command;
        string member;
        string[] words;
    }

    /// Every `@Command` method, two-word commands first.
    static CommandEntry[] collectCommands()
    {
        CommandEntry[] entries;
        static foreach (member; __traits(allMembers, typeof(this)))
            static if (member.startsWith("command") && member.length > "command".length)
                static foreach (attribute; __traits(getAttributes, __traits(getMember, typeof(this), member)))
                    static if (is(typeof(attribute) == Command))
                        entries ~= CommandEntry(attribute, member, attribute.name.split(" "));
        entries.sort!((a, b) => a.words.length > b.words.length);
        return entries;
    }

    enum CommandEntry[] chatCommands = collectCommands();
    static assert(chatCommands.length > 0);

    /**
     * `ChatHandler::ParseCommands`: true if `text` was taken as a command (run or refused), false
     * if it is a message to say.
     */
    bool runCommand(string text)
    {
        if (text.length < 2 || (text[0] != '.' && text[0] != '!') || text[1] == '.' || text[1] == '!' || text[1] == ' ')
            return false;
        string[] words;
        foreach (word; text[1 .. $].splitter(' '))
            if (word.length)
                words ~= word;

        foreach (ref entry; chatCommands)
        {
            if (entry.words.length > words.length || entry.command.level > account.level)
                continue;
            bool matches = true;
            foreach (i, word; entry.words)
                matches = matches && abbreviates(words[i], word);
            if (!matches)
                continue;
            const args = argumentsAfter(text[1 .. $], entry.words.length);
            info!"%s: '%s' ran .%s %s"(remoteAddress, player.data.name, entry.command.name, args);
            if (!call(entry.member, args))
                sendSystemMessage(format!"Syntax: .%s %s"(entry.command.name, entry.command.syntax));
            return true;
        }
        if (account.level == AccountLevel.player)
            return false; // said aloud
        sendSystemMessage("There is no such command");
        return true;
    }

    /// The text after the first `count` words.
    static string argumentsAfter(string text, size_t count)
    {
        size_t i;
        foreach (_; 0 .. count)
        {
            while (i < text.length && text[i] == ' ')
                ++i;
            while (i < text.length && text[i] != ' ')
                ++i;
        }
        return text[i .. $].strip;
    }

    /// Calls the command method called `member`.
    bool call(string member, string args)
    {
        switch (member)
        {
            static foreach (entry; chatCommands)
            {
        case entry.member:
                return __traits(getMember, this, entry.member)(args);
            }
        default:
            assert(0, "chatCommands only lists command methods");
        }
    }

    /// `ExtractPlayerTarget`: the player named in `args`, or the selected player.
    OnlinePlayer targetPlayer(string args)
    {
        if (args.length)
            return context.onlinePlayer(args.split[0]);
        return context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET);
    }

    /// `ExtractOnOff`: true for "on", false for "off", null otherwise.
    static Nullable!bool onOff(string args)
    {
        if (sicmp(args, "on") == 0)
            return Nullable!bool(true);
        if (sicmp(args, "off") == 0)
            return Nullable!bool(false);
        return Nullable!bool.init;
    }

    // -----------------------------------------------------------------------
    // The commands
    // -----------------------------------------------------------------------

    @Command("help", AccountLevel.player, "[command]", "Shows the commands you can use, or how to use one.")
    bool commandHelp(string args)
    {
        if (args.length == 0)
            return commandCommands(args);
        foreach (ref entry; chatCommands)
            if (entry.command.level <= account.level && sicmp(entry.command.name, args) == 0)
            {
                sendSystemMessage(format!"Syntax: .%s %s"(entry.command.name, entry.command.syntax));
                sendSystemMessage(entry.command.help);
                return true;
            }
        sendSystemMessage("There is no such command");
        return true;
    }

    @Command("commands", AccountLevel.player, "", "Lists the commands you can use.")
    bool commandCommands(string)
    {
        import std.algorithm.iteration : filter, map;
        import std.array : join;

        auto names = chatCommands.filter!(e => e.command.level <= account.level).map!(e => e.command.name).array;
        names.sort();
        sendSystemMessage("Commands available to you:");
        sendSystemMessage(names.join(", "));
        return true;
    }

    @Command("gps", AccountLevel.moderator, "", "Shows where you are.")
    bool commandGps(string)
    {
        const map_ = context.client.maps.lookup(player.data.map);
        const p = player.position;
        sendSystemMessage(format!"Map: %s (%s) Zone: %s (%s)"(player.data.map, map_ is null ? "?" : map_.name[0],
            player.data.zone, context.client.areaName(player.data.zone)));
        sendSystemMessage(format!"X: %f Y: %f Z: %f Orientation: %f"(p.x, p.y, p.z, p.orientation));
        return true;
    }

    @Command("go xyz", AccountLevel.moderator, "x y z [map]", "Teleports you to a position, on this map or another.")
    bool commandGoXyz(string args)
    {
        auto parts = args.replace(",", " ").split;
        if (parts.length < 3)
            return false;
        float x, y, z;
        uint mapId = player.data.map;
        try
        {
            x = parts[0].to!float;
            y = parts[1].to!float;
            z = parts[2].to!float;
            if (parts.length > 3)
                mapId = parts[3].to!uint;
        }
        catch (ConvException)
            return false;
        const entry = context.client.maps.lookup(mapId);
        if (entry is null || entry.isBattleground)
        {
            sendSystemMessage(format!"Map %s is battleground or arena. Not allowed through XYZ command."(mapId));
            return true;
        }
        if (!context.client.isValidMapCoord(mapId, x, y, z))
        {
            sendSystemMessage(format!"Invalid target coordinates (X: %s Y: %s) on map %s."(x, y, mapId));
            return true;
        }
        commandTeleport(mapId, Position(x, y, z, player.position.orientation));
        return true;
    }

    @Command("tele", AccountLevel.moderator, "name", "Teleports you to a place of the game_tele table.")
    bool commandTele(string args)
    {
        if (args.length == 0)
            return false;
        const tele = context.data.findTeleport(args);
        if (tele is null)
        {
            sendSystemMessage("Teleport location not found!");
            return true;
        }
        commandTeleport(tele.map, Position(tele.x, tele.y, tele.z, tele.orientation));
        return true;
    }

    @Command("appear", AccountLevel.moderator, "[name]", "Teleports you to a player, or to the one you have selected.")
    bool commandAppear(string args)
    {
        auto target = targetPlayer(args);
        if (target is null || target is this)
        {
            sendSystemMessage(target is null ? "No character selected." : "You can't teleport self to self!");
            return true;
        }
        if (sessionOf(target).transferring)
        {
            sendSystemMessage(format!"%s is already being teleported."(target.character.data.name));
            return true;
        }
        if (commandTeleport(target.character.data.map, target.character.position))
        {
            sendSystemMessage(format!"Appearing at %s's location."(target.character.data.name));
            sessionOf(target).sendSystemMessage(format!"%s is appearing to your location."(player.data.name));
        }
        return true;
    }

    @Command("summon", AccountLevel.moderator, "[name]", "Teleports a player, or the one you have selected, to you.")
    bool commandSummon(string args)
    {
        auto target = targetPlayer(args);
        if (target is null || target is this)
        {
            sendSystemMessage(target is null ? "No character selected." : "You can't teleport self to self!");
            return true;
        }
        auto other = sessionOf(target);
        if (other.commandTeleport(player.data.map, player.position))
        {
            sendSystemMessage(format!"You are summoning %s."(target.character.data.name));
            other.sendSystemMessage(format!"You are being teleported by %s."(player.data.name));
        }
        return true;
    }

    @Command("recall", AccountLevel.moderator, "", "Teleports you back to where you were before your last teleport command.")
    bool commandRecall(string)
    {
        commandTeleport(recallMap, recallPosition);
        return true;
    }

    @Command("gm", AccountLevel.moderator, "[on|off]", "Turns game master mode on or off: the <GM> tag, no entry requirements, no movement checks.")
    bool commandGm(string args)
    {
        if (args.length)
        {
            const value = onOff(args);
            if (value.isNull)
                return false;
            gameMaster = value.get;
            player.setFlag(PlayerFlags.gm, gameMaster);
            flushPlayerChanges();
            resetMovementCheck();
        }
        sendNotification(gameMaster ? "GM mode is ON" : "GM mode is OFF");
        return true;
    }

    @Command("gm chat", AccountLevel.moderator, "[on|off]", "Shows or hides the GM badge in chat.")
    bool commandGmChat(string args)
    {
        if (args.length)
        {
            const value = onOff(args);
            if (value.isNull)
                return false;
            player.gmChat = value.get;
        }
        sendNotification(player.gmChat ? "GM Chat Badge is ON" : "GM Chat Badge is OFF");
        return true;
    }

    @Command("save", AccountLevel.player, "", "Saves your character.")
    bool commandSave(string)
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        sendSystemMessage("Player saved.");
        return true;
    }

    @Command("server info", AccountLevel.player, "", "Shows how many players are online.")
    bool commandServerInfo(string)
    {
        sendSystemMessage(format!"dmangos. Players online: %s (maximum since start-up: %s)."(context.worldPopulation,
            context.peakSessions));
        return true;
    }

    @Command("announce", AccountLevel.moderator, "text", "Sends a system message to everyone online.")
    bool commandAnnounce(string args)
    {
        if (args.length == 0)
            return false;
        const message = chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            "|cffff0000[System Message]:|r" ~ args);
        foreach (other; context.onlinePlayers)
            other.deliver(Opcode.SMSG_MESSAGECHAT, message);
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testclient;
}

/// Commands by level: a player's unknown command is said aloud; a game master is told.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto player = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto gm = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.gameMaster);
    player.read();

    // `.gps` is a moderator's: Anduin just says it, and Jaina hears it.
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".gps"));
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT]);
    player.read();
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".gps"));
    const where = gm.read();
    assert(where.length == 2 && where[0].body_[0] == ChatType.CHAT_MSG_SYSTEM && player.read().length == 0);

    // Abbreviated, unknown, and wrongly used commands.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".nonsense"));
    assert((cast(const(char)[]) gm.read()[0].body_).canFind("There is no such command"));
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".go xyz 1"));
    const syntax = gm.read();
    assert(syntax.length == 1 && (cast(const(char)[]) syntax[0].body_).canFind("Syntax: .go xyz x y z [map]"));

    // `.gm on`: the GM flag; `.save`, a player's command, works for everyone.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".gm on"));
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_NOTIFICATION));
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".save"));
    assert(db.progressSaves.length == 1);

    // `.summon` brings Anduin over; `.appear` takes Jaina to him.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".summon anduin"));
    assert(opcodesOf(player.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK));
    assert(player.session.character.position.x == -8940);
}

/// Away and busy: the flag, the reply to whispers, and the chat tag.
unittest
{
    import dmangos.world.player : PlayerFlags;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0));
    anduin.read();
    jaina.read();

    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_AFK, "lunch"));
    assert(anduin.session.character.hasFlag(PlayerFlags.afk));
    anduin.read();
    jaina.read();

    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "hey", "Anduin"));
    const replies = jaina.read();
    assert(opcodesOf(replies) == [Opcode.SMSG_MESSAGECHAT, Opcode.SMSG_MESSAGECHAT]);
    assert(replies[1].body_[0] == ChatType.CHAT_MSG_AFK && replies[1].body_[$ - 7 .. $ - 1] == "lunch\0");
    anduin.read();

    // Anduin's own words carry the AFK tag; /dnd replaces /afk; /dnd again clears it.
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, "brb"));
    assert(jaina.read()[0].body_[$ - 1] == ChatTag.CHAT_TAG_AFK);
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_DND, ""));
    assert(anduin.session.character.hasFlag(PlayerFlags.dnd) && !anduin.session.character.hasFlag(PlayerFlags.afk));
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_DND, ""));
    assert(!anduin.session.character.hasFlag(PlayerFlags.dnd));
}
