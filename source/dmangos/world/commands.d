/**
 * Chat commands: messages that start with `.` (or `!`), as CMaNGOS's
 * `ChatHandler::ParseCommands` reads them, with the command set of ArcEmu
 * and Ascent (`Chat.cpp`, `Level0.cpp` .. `Level3.cpp`).
 *
 * A command is a `WorldSession` method marked with `@Command`; the table
 * that `runCommand` searches is collected from those attributes at compile
 * time, from every handler group, so a new command is one method:
 * ---
 * @Command("gm chat", AccountLevel.moderator, "[on|off]", "Shows or hides the GM badge in chat.")
 * bool commandGmChat(string args) { ... }
 * ---
 * Commands are grouped as ArcEmu groups them (`.modify hp`, `.ban account`,
 * `.lookup item`, ...); a group name alone lists its commands. Ascent's flat
 * names for the same commands (`.gmon`, `.kickplayer`, `.additem`) are
 * aliases. Every word may be shortened (`.te Stormwind`), and longer names
 * are tried first. A method returns false when its arguments are wrong; the
 * player is then shown the syntax. A player typing something that is not a
 * command, or not one for its level, simply says it, as in CMaNGOS.
 *
 * The commands themselves are in `gmtravel`, `gmcharacter`, `gmadmin` and
 * `gmdebug`; the general ones are here.
 */
module dmangos.world.commands;

import std.typecons : Nullable;
import std.uni : sicmp;

import dmangos.auth.accounts : AccountLevel;

/// Marks a chat command. `name` has one or two words; `syntax` describes the arguments.
struct Command
{
    string name;
    AccountLevel level;
    string syntax;
    string help;
    string[] aliases; /// other names, such as Ascent's flat ones
}

/// `hasStringAbbr`: whether `word` is a non-empty prefix of `full`, in any case.
bool abbreviates(const(char)[] word, const(char)[] full) pure @safe
{
    return word.length > 0 && word.length <= full.length && sicmp(word, full[0 .. word.length]) == 0;
}

/**
 * Reads the words of `text` into `values`, converting each to its type; a last `string` takes the
 * rest of the text. The first `required` must be there; the others keep their values when missing.
 * False if a word does not convert, or too few are given.
 */
bool readArguments(size_t required, Args...)(string text, ref Args values)
{
    import std.conv : ConvException, to;
    import std.string : strip;

    static assert(required <= Args.length);
    string rest = text.strip;
    static foreach (i, T; Args)
    {{
        if (rest.length == 0)
            return i >= required;
        static if (is(T == string) && i == Args.length - 1)
        {
            values[i] = rest;
            rest = null;
        }
        else
        {
            size_t end;
            while (end < rest.length && rest[end] != ' ')
                ++end;
            try
                values[i] = rest[0 .. end].to!T;
            catch (ConvException)
                return false;
            rest = rest[end .. $].strip;
        }
    }}
    return true;
}

unittest
{
    uint a;
    float b = 7;
    string c;
    assert(readArguments!1("5", a, b, c) && a == 5 && b == 7 && c is null);
    assert(readArguments!3("1 2.5 the rest of it", a, b, c) && b == 2.5f && c == "the rest of it");
    assert(!readArguments!2("1", a, b) && !readArguments!1("x", a));
}

/// Durations as GM commands take them: "1d2h30m10s", or a number of seconds. Null if the text is not one.
Nullable!uint parseDuration(string text) pure @safe
{
    import std.ascii : isDigit;

    if (text.length == 0)
        return Nullable!uint.init;
    ulong total, number;
    bool digits;
    foreach (c; text)
    {
        if (c.isDigit)
        {
            number = number * 10 + (c - '0');
            digits = true;
            if (number > uint.max)
                return Nullable!uint.init;
            continue;
        }
        if (!digits)
            return Nullable!uint.init;
        switch (c)
        {
        case 'd': total += number * 86_400; break;
        case 'h': total += number * 3600; break;
        case 'm': total += number * 60; break;
        case 's': total += number; break;
        default: return Nullable!uint.init;
        }
        number = 0;
        digits = false;
    }
    total += number;
    return total > uint.max ? Nullable!uint.init : Nullable!uint(cast(uint) total);
}

unittest
{
    assert(parseDuration("90").get == 90 && parseDuration("1d2h").get == 93_600 && parseDuration("10m5s").get == 605);
    assert(parseDuration("").isNull && parseDuration("h").isNull && parseDuration("5x").isNull);
}

/// An account level given by number (0-3) or name.
Nullable!AccountLevel parseAccountLevel(string text) pure @safe
{
    import std.uni : toLower;

    switch (text.toLower)
    {
    case "0", "player": return Nullable!AccountLevel(AccountLevel.player);
    case "1", "moderator", "mod": return Nullable!AccountLevel(AccountLevel.moderator);
    case "2", "gamemaster", "gm": return Nullable!AccountLevel(AccountLevel.gameMaster);
    case "3", "administrator", "admin": return Nullable!AccountLevel(AccountLevel.administrator);
    default: return Nullable!AccountLevel.init;
    }
}

unittest
{
    assert(abbreviates("te", "tele") && abbreviates("TELE", "tele") && !abbreviates("teles", "tele"));
    assert(!abbreviates("", "gm"));
    assert(parseAccountLevel("GM").get == AccountLevel.gameMaster && parseAccountLevel("7").isNull);
}

/// See the module documentation.
mixin template ChatCommands()
{
    import std.algorithm.iteration : filter, map, splitter, uniq;
    import std.algorithm.searching : canFind, startsWith;
    import std.algorithm.sorting : sort;
    import std.array : array, join, split;
    import std.format : format;
    import std.string : strip;
    import std.typecons : Nullable;
    import std.uni : sicmp, toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands : abbreviates, Command, readArguments;
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
    }

    /// One way to type a command: its name or an alias, split into words.
    struct CommandSpelling
    {
        string[] words;
        size_t entry; /// index into `chatCommands`
    }

    /// Every `@Command` method of every handler group.
    static CommandEntry[] collectCommands()
    {
        CommandEntry[] entries;
        static foreach (member; __traits(allMembers, typeof(this)))
            static if (member.startsWith("command") && member.length > "command".length)
                static foreach (attribute; __traits(getAttributes, __traits(getMember, typeof(this), member)))
                    static if (is(typeof(attribute) == Command))
                        entries ~= CommandEntry(attribute, member);
        return entries;
    }

    /// Every spelling, longest first, so `.gm chat on` is not taken for `.gm`.
    static CommandSpelling[] collectSpellings(const CommandEntry[] entries)
    {
        CommandSpelling[] spellings;
        foreach (i, ref entry; entries)
        {
            spellings ~= CommandSpelling(entry.command.name.split(" "), i);
            foreach (name; entry.command.aliases)
                spellings ~= CommandSpelling(name.split(" "), i);
        }
        spellings.sort!((a, b) => a.words.length > b.words.length);
        return spellings;
    }

    enum CommandEntry[] chatCommands = collectCommands();
    enum CommandSpelling[] chatCommandSpellings = collectSpellings(chatCommands);
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

        // Whole words first, so `.recall port` is not taken for `.recall portplayer`; then abbreviations.
        foreach (exact; [true, false])
        foreach (ref spelling; chatCommandSpellings)
        {
            const entry = chatCommands[spelling.entry];
            if (spelling.words.length > words.length || entry.command.level > account.level)
                continue;
            bool matches = true;
            foreach (i, word; spelling.words)
                matches = matches && (exact ? sicmp(words[i], word) == 0 : abbreviates(words[i], word));
            if (!matches)
                continue;
            const args = argumentsAfter(text[1 .. $], spelling.words.length);
            info!"%s: '%s' (%s) ran .%s %s"(remoteAddress, player.data.name, account.username, entry.command.name, args);
            if (!call(entry.member, args))
                sendSystemMessage(format!"Syntax: .%s %s"(entry.command.name, entry.command.syntax));
            return true;
        }

        // A group name alone (`.modify`): its commands.
        auto group = subCommands(words[0]);
        if (group.length)
        {
            sendSystemMessage(format!"Command %s has subcommands:"(words[0].toLower));
            sendSystemMessage(group.join(", "));
            return true;
        }
        if (account.level == AccountLevel.player)
            return false; // said aloud
        sendSystemMessage("There is no such command");
        return true;
    }

    /// The commands of the group `word` names that the player may use, as "group sub".
    string[] subCommands(string word)
    {
        string[] names;
        foreach (ref entry; chatCommands)
        {
            const parts = entry.command.name.split(" ");
            if (parts.length == 2 && entry.command.level <= account.level && abbreviates(word, parts[0]))
                names ~= entry.command.name;
        }
        names.sort();
        return names;
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

    // -----------------------------------------------------------------------
    // What commands share
    // -----------------------------------------------------------------------

    /// `ExtractPlayerTarget`: the player named in `args`, or the selected player.
    OnlinePlayer targetPlayer(string args)
    {
        if (args.length)
            return context.onlinePlayer(args.split[0]);
        return context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET);
    }

    /// ArcEmu's `getSelectedChar`: the selected player, or oneself if no player is selected.
    WorldSession selectedOrSelf()
    {
        if (auto selected = context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET))
            return sessionOf(selected);
        return this;
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

    /// A message to the player and, if `target` is someone else, one to the target.
    void tellBoth(WorldSession target, string toSelf, string toTarget)
    {
        sendSystemMessage(toSelf);
        if (target !is this && toTarget.length)
            target.sendSystemMessage(toTarget);
    }

    // -----------------------------------------------------------------------
    // General commands (Level0.cpp, and the gm group)
    // -----------------------------------------------------------------------

    @Command("help", AccountLevel.player, "[command]", "Shows the commands you can use, or how to use one.")
    bool commandHelp(string args)
    {
        if (args.length == 0)
            return commandCommands(args);
        foreach (ref entry; chatCommands)
            if (entry.command.level <= account.level
                && (sicmp(entry.command.name, args) == 0 || entry.command.aliases.canFind!(a => sicmp(a, args) == 0)))
            {
                sendSystemMessage(format!"Syntax: .%s %s"(entry.command.name, entry.command.syntax));
                sendSystemMessage(entry.command.help);
                if (entry.command.aliases.length)
                    sendSystemMessage("Also: ." ~ entry.command.aliases.join(", ."));
                return true;
            }
        if (auto group = subCommands(args))
        {
            sendSystemMessage(format!"Command %s has subcommands:"(args.toLower));
            sendSystemMessage(group.join(", "));
            return true;
        }
        sendSystemMessage("There is no such command");
        return true;
    }

    @Command("commands", AccountLevel.player, "", "Lists the commands you can use.")
    bool commandCommands(string)
    {
        // A group once, by its first word.
        auto names = chatCommands.filter!(e => e.command.level <= account.level)
            .map!(e => e.command.name.split(" ")[0]).array;
        names.sort();
        sendSystemMessage("Commands available to you:");
        sendSystemMessage(names.uniq.join(", "));
        return true;
    }

    @Command("gps", AccountLevel.moderator, "", "Shows where you, or the selected player, are.", ["getpos"])
    bool commandGps(string)
    {
        auto target = selectedOrSelf();
        const p = target.player;
        const map_ = context.client.maps.lookup(p.data.map);
        const at = p.position;
        sendSystemMessage(format!"%s: map %s (%s), zone %s (%s)"(p.data.name, p.data.map,
            map_ is null ? "?" : map_.name[0], p.data.zone, context.client.areaName(p.data.zone)));
        sendSystemMessage(format!"X: %f Y: %f Z: %f Orientation: %f"(at.x, at.y, at.z, at.orientation));
        return true;
    }

    @Command("gm on", AccountLevel.moderator, "", "Game master mode: the <GM> tag, no entry requirements, no movement checks.",
        ["gmon"])
    bool commandGmOn(string)
    {
        return setGameMaster(true);
    }

    @Command("gm off", AccountLevel.moderator, "", "Leaves game master mode.", ["gmoff"])
    bool commandGmOff(string)
    {
        return setGameMaster(false);
    }

    @Command("gm", AccountLevel.moderator, "[on|off]", "Shows game master mode, or turns it on or off.")
    bool commandGm(string args)
    {
        if (args.length == 0)
        {
            sendNotification(gameMaster ? "GM mode is ON" : "GM mode is OFF");
            return true;
        }
        const value = onOff(args);
        return !value.isNull && setGameMaster(value.get);
    }

    bool setGameMaster(bool on)
    {
        gameMaster = on;
        player.setFlag(PlayerFlags.gm, on);
        flushPlayerChanges();
        resetMovementCheck();
        sendNotification(on ? "GM mode is ON" : "GM mode is OFF");
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

    @Command("gm list", AccountLevel.player, "", "Shows the game masters online.")
    bool commandGmList(string)
    {
        string[] names;
        foreach (other; context.onlinePlayers)
            if (other.security > AccountLevel.player)
                names ~= other.character.data.name;
        names.sort();
        sendSystemMessage(names.length ? "Game masters online: " ~ names.join(", ") : "There are no game masters online.");
        return true;
    }

    @Command("save", AccountLevel.player, "", "Saves your character.")
    bool commandSave(string)
    {
        savePlayer();
        sendSystemMessage("Player saved.");
        return true;
    }

    /// `Player::SaveToDB`, as far as this server saves.
    void savePlayer()
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        saveTimer.reset();
    }

    @Command("server info", AccountLevel.player, "", "Shows how many players are online.", ["info"])
    bool commandServerInfo(string)
    {
        size_t gms;
        foreach (other; context.onlinePlayers)
            if (other.security > AccountLevel.player)
                ++gms;
        sendSystemMessage(format!"dmangos. Players online: %s (%s game masters), at most %s since start-up."(
            context.worldPopulation, gms, context.peakSessions));
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.player : PlayerFlags;
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

    // Unknown, wrongly used, and grouped commands.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".nonsense"));
    assert((cast(const(char)[]) gm.read()[0].body_).canFind("There is no such command"));
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".go xyz 1"));
    const syntax = gm.read();
    assert(syntax.length == 1 && (cast(const(char)[]) syntax[0].body_).canFind("Syntax: .go xyz x y z [map]"));
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".modify"));
    const group = gm.read();
    assert(group.length == 2 && (cast(const(char)[]) group[1].body_).canFind("modify hp"));

    // `.gmon`, Ascent's spelling, is `.gm on`; `.save`, a player's command, works for everyone.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".gmon"));
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_NOTIFICATION) && gm.session.character.hasFlag(PlayerFlags.gm));
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".save"));
    assert(db.progressSaves.length == 1);

    // `.summon` brings Anduin over.
    gm.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_SAY, ".summon anduin"));
    assert(opcodesOf(player.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK));
    assert(player.session.character.position.x == -8940);
}

/// Away and busy: the flag, the reply to whispers, and the chat tag.
unittest
{
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
