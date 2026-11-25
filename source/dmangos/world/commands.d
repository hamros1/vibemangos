/**
 * Dispatches in-game staff commands. The command table defines syntax and named capability
 * groups, aliases and abbreviations. Roles can grant individual command paths.
 */
module dmangos.world.commands;

public import std.typecons : Nullable; // handler parameters may be `Nullable`

import dmangos.world.commandtable;

public import dmangos.world.chatstyle : ChatColor, colored;

/// Whether `typed` is the start of `name`, in any case.
bool hasStringAbbr(const(char)[] name, const(char)[] typed) pure nothrow @safe @nogc
{
    import std.ascii : toLower;

    foreach (i, c; typed)
        if (i >= name.length || toLower(name[i]) != toLower(c))
            return false;
    return true;
}

unittest
{
    assert(hasStringAbbr("gmannounce", "gma") && hasStringAbbr("gm", "GM") && hasStringAbbr("gm", ""));
    assert(!hasStringAbbr("gm", "gmon"));
}

/// Distinct method names for the compile-time dispatch switch.
package string[] commandMethods(immutable(ChatCommand)[] table) pure @safe
{
    import std.algorithm.searching : canFind;

    string[] methods;
    foreach (ref row; table)
    {
        if (row.handler.length && !methods.canFind(row.handler))
            methods ~= row.handler;
        foreach (method; commandMethods(row.children))
            if (!methods.canFind(method))
                methods ~= method;
    }
    return methods;
}

/// The permission path of the row `name` under `parent`.
package string childPath(string parent, string name) pure @safe
{
    return parent.length ? parent ~ " " ~ name : name;
}

/// Whether `word` is `name`, in any case.
package bool exactWord(string name, string word) pure nothrow @safe @nogc
{
    return name.length == word.length && hasStringAbbr(name, word);
}

/// Whether `word` is the row's name or its preferred spelling.
package bool named(ref const ChatCommand row, string word) pure nothrow @safe @nogc
{
    return exactWord(row.name, word) || exactWord(row.alternate, word);
}

/// The row of `rows` named `word`, or (with `abbreviations`) the first it abbreviates; null if none.
private const(ChatCommand)* catalogWord(immutable(ChatCommand)[] rows, string word, bool abbreviations) pure @safe
{
    if (!word.length)
        return null;
    const(ChatCommand)* prefix;
    foreach (i, ref row; rows)
    {
        if (named(row, word))
            return &rows[i];
        if (abbreviations && prefix is null && hasStringAbbr(row.name, word))
            prefix = &rows[i];
    }
    return prefix;
}

/// Looks up a catalog link by its stable permission path.
package const(ChatCommand)* declaredCommand(string path) pure @safe
{
    immutable(ChatCommand)[] table = commandTable;
    while (const word = nextWord(path))
    {
        const found = catalogWord(table, word, false);
        if (found is null || trimSpaces(path).length == 0)
            return found;
        table = found.children;
    }
    return null;
}

unittest
{
    static void validate(immutable(ChatCommand)[] rows)
    {
        foreach (i, ref row; rows)
        {
            foreach (ref other; rows[0 .. i])
                assert(!named(other, row.name) && !named(other, row.label), row.name);
            if (row.target.length)
            {
                const target = declaredCommand(row.target);
                assert(target !is null && !target.target.length && !target.children.length, row.target);
            }
            validate(row.children);
        }
    }

    validate(commandTable);
}

/**
 * A handler parameter that takes the rest of the command's text, as many words as there are: an
 * announcement, a ban reason, a player's name (which may contain spaces). It converts to
 * `string`. With no default value it is required, like any other parameter.
 */
struct Rest
{
    string text;
    alias text this;
}

/// A handler parameter for "on" or "off", which `std.conv.to` reads by name.
enum OnOff
{
    off,
    on,
}

/// The first space-separated word of `text`, which then holds what follows it; null when there is none.
string nextWord(ref string text) pure nothrow @nogc @safe
{
    import std.algorithm.searching : countUntil;
    import std.utf : byCodeUnit;

    // Code units, not characters: chat text is not checked to be valid UTF-8.
    const start = text.byCodeUnit.countUntil!(c => c != ' ');
    if (start < 0)
    {
        text = null;
        return null;
    }
    text = text[start .. $];
    const end = text.byCodeUnit.countUntil(' ');
    const word = end < 0 ? text : text[0 .. end];
    text = text[word.length .. $];
    return word;
}

/// `text` without the spaces around it.
string trimSpaces(string text) pure nothrow @nogc @safe
{
    import std.algorithm.mutation : strip;
    import std.utf : byCodeUnit;

    return text.byCodeUnit.strip(' ').source;
}

unittest
{
    string text = "  Anduin  for spamming ";
    assert(nextWord(text) == "Anduin" && trimSpaces(text) == "for spamming");
    assert(nextWord(text) == "for" && nextWord(text) == "spamming" && nextWord(text) is null && text is null);
    string invalid = "\xFF\xFE x";
    assert(nextWord(invalid) == "\xFF\xFE", "bytes that are not UTF-8 are only bytes");
}

/// Whether `text` is a dotted IPv4 address: four numbers from 0 to 255.
bool isIPv4Address(string text) pure @safe
{
    import std.algorithm.iteration : splitter;
    import std.conv : ConvException, to;
    import std.utf : byCodeUnit;

    size_t parts;
    foreach (part; text.byCodeUnit.splitter('.'))
    {
        try
            cast(void) part.source.to!ubyte;
        catch (ConvException)
            return false;
        ++parts;
    }
    return parts == 4;
}

unittest
{
    assert(isIPv4Address("127.0.0.1") && !isIPv4Address("127.0.0.256") && !isIPv4Address("1.2.3"));
    assert(!isIPv4Address("1.2.3.4.5") && !isIPv4Address("a.b.c.d") && !isIPv4Address(""));
}

/// Lengths of time in seconds, as commands count them: a month is 30 days, a year 12 months.
enum : uint
{
    secondsPerMinute = 60,
    secondsPerHour = secondsPerMinute * 60,
    secondsPerDay = secondsPerHour * 24,
    secondsPerMonth = secondsPerDay * 30,
    secondsPerYear = secondsPerMonth * 12,
}

/**
 * A time period typed in a command: numbers each followed by `y`, `m` (months), `d`
 * or `h`, added up, in seconds. Reading stops at anything that is not a digit, and a number
 * without a letter is ignored, so "perm" is 0. -1 for an unknown letter.
 */
int parseDuration(const(char)[] text) pure nothrow @safe @nogc
{
    import std.ascii : isDigit, toLower;

    uint total;
    size_t i;
    while (i < text.length && text[i].isDigit)
    {
        uint number;
        while (i < text.length && text[i].isDigit)
            number = number * 10 + (text[i++] - '0');
        if (i == text.length)
            break;
        uint multiplier;
        switch (toLower(text[i]))
        {
        case 'y': multiplier = secondsPerYear; break;
        case 'm': multiplier = secondsPerMonth; break;
        case 'd': multiplier = secondsPerDay; break;
        case 'h': multiplier = secondsPerHour; break;
        default: return -1;
        }
        ++i;
        total += multiplier * number;
    }
    return cast(int) total;
}

/// A number of seconds in words: "1 days, 2 hours, " and so on.
string durationString(uint timestamp) pure @safe
{
    import std.format : format;

    const seconds = timestamp % 60;
    const minutes = timestamp / secondsPerMinute % 60;
    const hours = timestamp / secondsPerHour % 24;
    const days = timestamp / secondsPerDay % 30;
    const months = timestamp / secondsPerMonth % 12;
    const years = timestamp / secondsPerYear;
    string result;
    if (years)
        result ~= format!"%s years, "(years);
    if (months)
        result ~= format!"%s months, "(months);
    if (days)
        result ~= format!"%s days, "(days);
    if (hours)
        result ~= format!"%s hours, "(hours);
    if (minutes)
        result ~= format!"%s minutes, "(minutes);
    if (seconds)
        result ~= format!"%s seconds"(seconds);
    return result;
}

/// A Unix time as a date: "Monday, 05 January 2026, 09:04:01", in local time.
string dateTimeString(long timestamp) @safe
{
    import std.datetime.systime : SysTime;
    import std.format : format;

    static immutable string[7] days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    static immutable string[12] months = ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"];
    const time = SysTime.fromUnixTime(timestamp);
    return format!"%s, %02d %s %d, %02d:%02d:%02d"(days[time.dayOfWeek], time.day, months[time.month - 1], time.year,
        time.hour, time.minute, time.second);
}

/// C's `ctime`: "Wed Jun 30 21:49:08 1993\n", in local time, as the IP ban message prints it.
string ctimeString(long timestamp) @safe
{
    import std.datetime.systime : SysTime;
    import std.format : format;

    static immutable string[7] days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable string[12] months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
        "Dec"];
    const time = SysTime.fromUnixTime(timestamp);
    return format!"%s %s %2d %02d:%02d:%02d %d\n"(days[time.dayOfWeek], months[time.month - 1], time.day, time.hour,
        time.minute, time.second, time.year);
}

unittest
{
    assert(parseDuration("1d2h") == 93_600 && parseDuration("perm") == 0);
    assert(parseDuration("5") == 0 && parseDuration("3x") == -1);
    assert(parseDuration("1m") == 2_592_000);
    assert(durationString(93_605) == "1 days, 2 hours, 5 seconds");
    assert(durationString(secondsPerYear + secondsPerMonth + 61) == "1 years, 1 months, 1 minutes, 1 seconds");
}

/// Commands typed in chat: matched against the catalog, checked against the player's access, run; and the
/// system messages, selections and `.modify` field rows the handlers share.
mixin template ChatCommands()
{
    import std.format : format;
    import dmangos.log : trace;
    import dmangos.world.chatstyle : systemChatText;
    import dmangos.world.commands;
    import dmangos.world.commandtable : ChatCommand, commandTable;
    import dmangos.world.creature : Creature;
    import dmangos.world.objects : HighGuid, highGuidOf;
    import dmangos.world.opcodes : ChatType, Language;
    import dmangos.world.packets : ServerMessageChat;
    import dmangos.world.queries : chatMessage;
    import dmangos.world.updatefields : UNIT_END, UNIT_FIELD_MINDAMAGE, UNIT_FIELD_STAT1, UNIT_FIELD_TARGET;

private:
    enum methods = commandMethods(commandTable);

    /// A catalog row the typed words named, with its permission path and its preferred spelling.
    struct CommandMatch
    {
        const(ChatCommand)* row;
        string path;
        string label;
    }

    /// Whether this player may run `row` (at `path`): a group if any of its actions.
    bool canRunCommand(ref const ChatCommand row, string path) const
    {
        import std.uni : toLower;

        if (row.target.length)
            return canRunCommand(*declaredCommand(row.target), row.target);
        const permission = row.permission;
        if (row.children.length)
        {
            foreach (ref child; row.children)
                if (canRunCommand(child, childPath(path, child.name)))
                    return true;
            return false;
        }
        if (permission.alsoRequires.length && !gmAccess.allows(permission.alsoRequires))
            return false;
        return !permission.capability.length || gmAccess.allows(permission.capability)
            || (permission.delegable && gmAccess.allows("command." ~ toLower(path)));
    }

    /// The row of `table` named `word` (or abbreviated by it) that this player may run; null if none.
    const(ChatCommand)* matchCommand(immutable(ChatCommand)[] table, string parent, string word,
        bool abbreviations) const
    {
        const(ChatCommand)* prefix;
        foreach (ref row; table)
        {
            if (named(row, word))
                return canRunCommand(row, childPath(parent, row.name)) ? &row : null;
            if (abbreviations && prefix is null && hasStringAbbr(row.name, word)
                && canRunCommand(row, childPath(parent, row.name)))
                prefix = &row;
        }
        return prefix;
    }

    /// The command the words of `text` name, which then holds the arguments; no row if none.
    CommandMatch readCommand(ref string text, bool abbreviations = true) const
    {
        CommandMatch match;
        immutable(ChatCommand)[] table = commandTable;
        while (const word = nextWord(text))
        {
            const row = matchCommand(table, match.path, word, abbreviations);
            if (row is null)
                return CommandMatch.init;
            match = CommandMatch(row, childPath(match.path, row.name), childPath(match.label, row.label));
            if (row.children.length == 0)
                return match;
            table = row.children;
        }
        return match;
    }

    /// True if this message was handled as a command.
    bool parseCommands(string text)
    {
        if (!text.length || (text[0] != '!' && text[0] != '.') || (text.length > 1 && text[1] == '.'))
            return false;
        refreshGmAccess();
        const canOpen = gmAccess.grants.length != 0;
        if (!canOpen && !context.config.allowPlayerCommands)
            return false;
        trace!"%s: '%s' (%s) typed %s"(remoteAddress, player.data.name, account.username, text);

        string args = text[1 .. $];
        const match = readCommand(args);
        if (match.row is null)
            unknownCommand();
        else if (match.row.children.length)
            showCommandList(match);
        else
        {
            const row = actionFor(*match.row);
            if (row.unavailableReason.length)
                redSystemMessage(row.unavailableReason);
            else if (!runCommand(*row, args))
                showCommandHelp(match);
        }
        return true;
    }

    /// The action a row runs: its own, or a shortcut's target.
    const(ChatCommand)* actionFor(ref const ChatCommand row) const
    {
        return row.target.length ? declaredCommand(row.target) : &row;
    }

    /// Runs the action `row` with `args`; false if they do not fit it.
    bool runCommand(ref const ChatCommand row, string args)
    {
        if (row.field >= 0)
            return row.decimal ? setFieldCommand!float(row, args) : setFieldCommand!uint(row, args);
        switch (row.handler)
        {
            static foreach (method; methods)
            {
        case method:
                return invoke!method(args);
            }
        default:
            assert(0, "A command action must declare a handler or field.");
        }
    }

    /// The answer to a command that does not exist or this player may not use.
    void unknownCommand()
    {
        redSystemMessage("Command unavailable. Try .commands.");
    }

    /// `.label` and the row's arguments.
    string commandUsage(string label, ref const ChatCommand row) const
    {
        return "." ~ label ~ (row.arguments.length ? " " ~ row.arguments : "");
    }

    /// The matched action's usage and description, or why it is unavailable.
    void showCommandHelp(const ref CommandMatch match)
    {
        const row = actionFor(*match.row);
        blueSystemMessage(commandUsage(match.label, *row));
        if (row.unavailableReason.length)
            redSystemMessage(row.unavailableReason);
        else if (row.description.length)
            systemMessage(row.description);
    }

    /// The actions of the matched group (or the top-level commands, those starting with `filter`) this player
    /// may use.
    void showCommandList(CommandMatch match, string filter = null)
    {
        import std.algorithm.sorting : sort;
        import std.array : join;
        import std.range : chunks;

        const rows = match.row is null ? commandTable : match.row.children;
        string[] lines;
        foreach (ref row; rows)
        {
            if (filter.length && !hasStringAbbr(row.name, filter) && !hasStringAbbr(row.label, filter))
                continue;
            const action = actionFor(row);
            if (action.unavailableReason.length || !canRunCommand(row, childPath(match.path, row.name)))
                continue;
            if (match.row !is null)
                lines ~= colored(ChatColor.sky, commandUsage(childPath(match.label, row.label), *action)) ~ "  "
                    ~ action.description;
            else if (!row.children.length || rowsHaveActions(row.children, row.name))
                lines ~= colored(ChatColor.sky, "." ~ row.label);
        }
        if (!lines.length)
        {
            redSystemMessage("No matching commands are available.");
            return;
        }
        lines.sort();
        if (match.row !is null)
        {
            greenSystemMessage("." ~ match.label ~ " commands");
            foreach (line; lines)
                systemMessage(line);
        }
        else
        {
            greenSystemMessage("Commands  ·  .help <command> for syntax");
            foreach (chunk; lines.chunks(5))
                systemMessage(chunk.join("  "));
        }
    }

    /// Whether any of `rows` (under `parent`) is an action this player may use.
    bool rowsHaveActions(immutable(ChatCommand)[] rows, string parent) const
    {
        foreach (ref row; rows)
            if (!actionFor(row).unavailableReason.length && canRunCommand(row, childPath(parent, row.name)))
                return true;
        return false;
    }

    /**
     * Calls the handler method `member` with `text` read into its parameters: one word each, converted
     * with `std.conv.to`, and a `Rest` takes what is left. A missing word takes the parameter's default
     * value; a `Nullable` parameter is optional, and null when its word is missing. False (the command's
     * help is shown) when a required word is missing or a word does not convert; words left over are
     * ignored.
     */
    bool invoke(string member)(string text)
    {
        import std.conv : ConvException, to;
        import std.traits : ParameterDefaults, Parameters;

        alias method = __traits(getMember, typeof(this), member);
        Parameters!method values;
        static foreach (i, T; Parameters!method)
        {{
            static if (is(T == Rest))
            {
                const rest = trimSpaces(text);
                text = null;
            }
            else
                const rest = nextWord(text);
            if (rest.length == 0)
            {
                static if (!is(ParameterDefaults!method[i] == void))
                    values[i] = ParameterDefaults!method[i];
                else static if (!is(T : Nullable!U, U))
                    return false;
            }
            else static if (is(T == Rest))
                values[i] = Rest(rest);
            else static if (is(T == string))
                values[i] = rest;
            else
            {
                static if (is(T : Nullable!U, U))
                    alias Target = U;
                else
                    alias Target = T;
                try
                    values[i] = rest.to!Target;
                catch (ConvException)
                    return false;
            }
        }}
        return __traits(getMember, this, member)(values);
    }

    // -----------------------------------------------------------------------
    // System messages
    // -----------------------------------------------------------------------

    /// A system message to this player, cut at 1023 bytes.
    void systemMessage(string text)
    {
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            systemChatText(text))));
    }

    /// A system message in the colour `color`.
    void colorSystemMessage(ChatColor color, string text)
    {
        systemMessage(systemChatText(text, color));
    }

    /// A system message in light red.
    void redSystemMessage(string text)
    {
        colorSystemMessage(ChatColor.softRed, text);
    }

    /// A system message in green.
    void greenSystemMessage(string text)
    {
        colorSystemMessage(ChatColor.green, text);
    }

    /// A system message in light blue.
    void blueSystemMessage(string text)
    {
        colorSystemMessage(ChatColor.sky, text);
    }

    /// One system message per line of `text`.
    void sendMultilineMessage(string text)
    {
        import std.array : split;

        auto lines = text.split('\n');
        if (lines.length && lines[$ - 1].length == 0) // no message for the text after a final newline
            lines = lines[0 .. $ - 1];
        foreach (line; lines)
            systemMessage(line);
    }

    /// A line in the GM command log, if there is one.
    void gmLog(string text)
    {
        context.writeGmLog(format!"Account %s [%s], IP %s, Player %s :: %s"(account.id, account.username,
            remoteAddress, player is null ? "" : player.data.name, text));
    }

    // -----------------------------------------------------------------------
    // Selections
    // -----------------------------------------------------------------------

    /// The selected player on this map, oneself if nothing is selected; null (with an error message if
    /// `showError`) if the selection is not a player here.
    Character selectedCharacter(bool showError)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            if (showError)
                greenSystemMessage("Targeting yourself.");
            return this;
        }
        auto found = cast(Character) map.find(guid);
        if (found is null && showError)
            redSystemMessage("Select a player first.");
        return found;
    }

    /// The selected creature, or null (with an error message if `showError`).
    Creature selectedCreature(bool showError)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Creature creature;
        if (highGuidOf(guid) == HighGuid.unit)
            creature = cast(Creature) map.findObject(guid);
        if (creature is null && showError)
            redSystemMessage("Select a creature first.");
        return creature;
    }

    // -----------------------------------------------------------------------
    // .modify's field rows
    // -----------------------------------------------------------------------

    /// A `.modify` field row: the selected player's (or creature's) field set, and its maximum, which defaults to
    /// the value.
    bool setFieldCommand(T)(ref const ChatCommand row, string args)
    {
        import std.conv : ConvException, to;
        import std.math : isFinite;

        const hasMax = row.maximum >= 0;
        const valueWord = nextWord(args);
        const maximumArg = hasMax ? nextWord(args) : null;
        if (valueWord is null || (row.field == UNIT_FIELD_MINDAMAGE && maximumArg is null) || trimSpaces(args).length)
            return false;
        const maximumWord = !hasMax ? "0" : maximumArg.length ? maximumArg : valueWord;
        T value, maximum;
        try
        {
            value = valueWord.to!T;
            maximum = maximumWord.to!T;
        }
        catch (ConvException)
            return false;
        static if (is(T == float))
            const invalidValue = !value.isFinite || !maximum.isFinite || value <= 0;
        else
            const invalidValue = value == 0 && maximum > 0;
        if (invalidValue || hasMax && (maximum < value || maximum <= 0))
        {
            redSystemMessage("Enter a valid value. A maximum must be positive and at least as large as the value.");
            return true;
        }

        enum valueFormat = is(T == float) ? "%.1f" : "%d";
        enum logFormat = is(T == float) ? "%f" : "%s";
        const shown = hasMax ? format!(valueFormat ~ "/" ~ valueFormat)(value, maximum) : format!valueFormat(value);
        static uint raw(T number)
        {
            import dmangos.bytes : floatBits;

            static if (is(T == float))
                return floatBits(number);
            else
                return number;
        }

        const slot = cast(size_t) row.field;
        const maxSlot = hasMax ? cast(size_t) row.maximum : 0;
        const fieldName = row.label;
        static if (is(T == uint))
            const stored = slot == UNIT_FIELD_STAT1 ? value / 2 : value; // the agility row stores half the value
        else
            const stored = value;
        if (auto target = selectedCharacter(false))
        {
            const name = target.player.data.name;
            gmLog(format!("used modify field value: %s, " ~ logFormat ~ " on %s")(fieldName, value, name));
            greenSystemMessage(format!"You set the %s of %s to %s."(fieldName, name, shown));
            target.greenSystemMessage(format!"%s set your %s to %s."(player.data.name, fieldName, shown));
            target.player.values.setSlot(slot, raw(stored));
            if (hasMax)
                target.player.values.setSlot(maxSlot, raw(maximum));
            target.flushPlayerChanges();
        }
        else if (auto creature = selectedCreature(false))
        {
            if (!(slot < UNIT_END && maxSlot < UNIT_END))
                return false;
            const name = creature.template_.name;
            greenSystemMessage(format!"Setting %s of %s to %s."(fieldName, name, shown));
            gmLog(format!("used modify field value: [creature]%s, " ~ logFormat ~ " on %s")(fieldName, value, name));
            creature.values.setSlot(slot, raw(stored));
            if (hasMax)
                creature.values.setSlot(maxSlot, raw(maximum));
            map.flushObjectChanges(creature);
        }
        else
            redSystemMessage("Select a player or creature first.");
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;
}

/// Who may use commands, how words are matched, and what a refusal or a sub-table looks like.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto player = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto mod = loggedIn(context, db, 8, "Varian", Position(-8945, -132, 83.5f), AccountLevel.moderator);
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.gameMaster);
    player.read();
    mod.read();

    // Without permissions, a command is said aloud (`allow_player_commands` is off).
    player.say(".gm on");
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT] && !player.session.character.gmTagOn);
    player.read();
    mod.read();

    // The moderator's letters ("bcghiltuv") have no `m`: `.modify` is not there for it.
    mod.say(".modify hp 5");
    assert(systemMessages(mod.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);

    // A group name lists the allowed actions with their preferred spelling and syntax.
    mod.say(".gm");
    const menu = systemMessages(mod.read());
    assert(menu.length == 7 && menu[0] == ChatColor.green ~ ".gm commands|r");
    assert(menu[1] == ChatColor.sky ~ ".gm allow <name>|r  Allow whispers from a player while in GM mode.");
    assert(menu.canFind(ChatColor.sky ~ ".gm off|r  Turn off the GM tag and whisper blocking."));

    // Support keeps `.gm quiet` but cannot save game object placements to the world database, ban addresses,
    // run the server, or summon helpers.
    foreach (edit; [".gobject move", ".gobject rotate x 90", ".ban ip 10.0.0.1 1d", ".server motd Hi",
        ".modperiod 1000", ".pet helper 1"])
    {
        mod.say(edit);
        assert(systemMessages(mod.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);
    }
    mod.say(".gm quiet");
    mod.read();
    assert(mod.session.character.gmTagOn);

    // The first row in table order wins: `.k` is `.kill`, which needs a selection.
    gm.say(".k");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Select a unit first.|r"]);

    // A command whose system does not exist yet says so.
    gm.say(".cheat fly");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Player flight is unavailable in this client.|r"]);

    // `.invisible`, both ways, in ArcEmu's words (its double space included).
    gm.say(".invisible");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Invisibility and Invincibility are now  ON. You may have "
        ~ "to leave and re-enter this zone for changes to take effect.|r"]);
    assert(gm.session.character.gmInvisible && gm.session.inWorld.untouchable);
    gm.say(".invisible");
    assert(systemMessages(gm.read())[0].canFind("now  OFF."));
    assert(!gm.session.character.gmInvisible && !gm.session.inWorld.untouchable);

    // A handler refusing its arguments shows the row's help.
    gm.say(".levelup -2");
    assert(systemMessages(gm.read())[0] == ChatColor.sky ~ ".levelup [levels]|r");

    // Levels raise the caps of the skills that go with the level, not their values.
    {
        import dmangos.world.player : Player;

        auto me = cast(Player) gm.session.character;
        const swordsBefore = me.skillValue(skillSwords);
        gm.say(".levelup 4");
        gm.read();
        assert(me.skillValue(skillSwords) == [swordsBefore[0], 25], "5 a level at level 5");
    }

    // `.help`, with abbreviations.
    gm.say(".help gm of");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ ".gm off|r", "Turn off the GM tag and whisper blocking."]);
    gm.say("!he nosuch");
    assert(systemMessages(gm.read()) == [ChatColor.softRed
        ~ "Command unavailable. Try .commands.|r"]);

    // `..` is never a command.
    gm.say("..what");
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT] && systemMessages(gm.read()).length == 0);
}

/// A scoped role can use the canonical command and its alias. Removing it closes access on the next command.
unittest
{
    import dmangos.world.gmaccess : GmAccess;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.administrator);
    const id = db.accounts["JAINA"].id;
    db.gmAccessRows[id] = GmAccess(["spell-tester"], ["command.character learn", "command.access grant"]);
    gm.read();

    gm.say(".learn 99999999");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Targeting yourself.|r",
        ChatColor.softRed ~ "Unknown spell ID 99999999.|r"]);
    assert(!gm.session.inWorld.isStaff && gm.session.inWorld.security == AccountLevel.player);
    gm.say(".character learn 99999999");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Targeting yourself.|r",
        ChatColor.softRed ~ "Unknown spell ID 99999999.|r"]);
    gm.say(".travel coords 0 0 0 0");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);
    gm.say(".access grant JAINA administrator");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Command unavailable. Try .commands.|r"]);

    db.gmAccessRows[id] = GmAccess.init;
    gm.say(".learn 99999999");
    assert(systemMessages(gm.read()).length == 0);
    assert(!gm.session.inWorld.allowsStaff("staff.game_master") && !gm.session.inWorld.staffRoles.length);
}

/// `.gm on` and `.gm off`, the GM tag in chat, and whispers to a GM with the tag on.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto player = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto gm = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0), AccountLevel.gameMaster);
    player.read();
    gm.read();

    gm.say(".gm on");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "GM mode on. Your GM tag is visible.|r"]);
    const jaina = gm.session.character;
    assert(jaina.gmTagOn && jaina.hasFlag(PlayerFlags.gm));
    player.read();
    gm.say(".gm on");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "GM mode is already on.|r"]);

    // Her words carry the GM tag.
    gm.say("hello");
    assert(player.read()[0].body_[$ - 1] == ChatTag.CHAT_TAG_GM);
    gm.read();

    // A player's whisper gets the automatic reply, until she allows it.
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "help me", "Jaina"));
    const reply = player.read();
    assert(reply.length == 1 && (cast(const(char)[]) reply[0].body_).canFind("does not currently have an open ticket"));
    assert(gm.read().length == 0);
    gm.say(".gm allowwhispers anduin");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Now accepting whispers from Anduin.|r"]);
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "help me", "Jaina"));
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT]);
    player.read();

    gm.say(".gm off");
    assert(!jaina.gmTagOn && !jaina.hasFlag(PlayerFlags.gm));
    gm.read();
    // `.gm list`: staff names and role names.
    player.read();
    gm.say(".gm list");
    assert(systemMessages(gm.read()) == [colored(ChatColor.green, "Active GMs"), " - Jaina [game-master]"]);
}

/// `.modify` field rows, overrides, the GM log, kicks and mutes.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    auto admin = loggedIn(context, db, 8, "Varian", Position(5, 0, 0), AccountLevel.administrator);
    auto player = loggedIn(context, db, 9, "Jaina", Position(6, 0, 0));
    gm.read();
    admin.read();

    // `.modify hp value max` sets both fields of oneself (nothing selected), and tells the player.
    gm.say(".modify hp 400 500");
    const me = gm.session.character;
    assert(me.values[UNIT_FIELD_HEALTH] == 400 && me.values[UNIT_FIELD_MAXHEALTH] == 500);
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "You set the hp of Anduin to 400/500.|r",
        ChatColor.green ~ "Anduin set your hp to 400/500.|r"]);
    gm.say(".modify hp 600 500");
    assert(systemMessages(gm.read())[0].canFind("Enter a valid value"));
    gm.say(".modify scale 2.5");
    assert(me.values.get!OBJECT_FIELD_SCALE_X == 2.5f);
    gm.read();
    assert(context.gmLogLines[0].canFind("Player Anduin :: used modify field value: hp, 400 on Anduin"));

    gm.say(".modify hp 300");
    assert(me.values[UNIT_FIELD_HEALTH] == 300 && me.values[UNIT_FIELD_MAXHEALTH] == 300);
    gm.read();

    gm.say(".where");
    assert(systemMessages(gm.read())[0].canFind("Position"));

    // Game masters cannot kick administrators.
    gm.say(".kickplayer varian spamming");
    assert(systemMessages(gm.read())[$ - 1] == ChatColor.softRed
        ~ "You cannot kick Varian, as they are a higher level gm than you.|r");

    // `.account mute`: the player is told, and cannot speak.
    gm.say(".account mute JAINA 2h");
    gm.read();
    assert(systemMessages(player.read())[$ - 1].canFind("Your voice has been muted until"));
    player.say("hi");
    assert(systemMessages(player.read()) == ["Your voice is currently muted by a moderator."]);
    gm.say(".account unmute JAINA");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Account 'JAINA' has been unmuted.|r"]);
    assert(systemMessages(player.read()) == ["Your voice has restored. You may speak again."]);
    player.say("hi");
    assert(opcodesOf(player.read()) == [Opcode.SMSG_MESSAGECHAT]);
}

/// Arguments: words converted to the handler's parameter types, defaults, `Rest`, `Nullable` and `OnOff`.
unittest
{
    import std.algorithm.searching : count;
    import dmangos.world.movement : MoveType;
    import dmangos.world.testdata : itemJerky;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    auto player = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0));
    gm.read();
    player.read();

    // A word that does not convert, or a missing one, shows the command's help.
    gm.say(".modify speed fast");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ ".modify speed <speed>|r", "Set movement speed."]);
    gm.say(".modify speed");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ ".modify speed <speed>|r", "Set movement speed."]);
    gm.say(".modify speed 14");
    assert(gm.session.character.speeds[MoveType.run] == 14);
    gm.read();

    // Optional words take their defaults: one item, no random property.
    gm.say(".character additem 117");
    assert(gm.session.character.inventory.count(itemJerky) == 1);
    gm.say(".character additem 117 x");
    assert(systemMessages(gm.read())[$ - 1] == "Give items to the selected player.");
    assert(gm.session.character.inventory.count(itemJerky) == 1);

    // `Rest` takes the rest of the line; a missing `Rest` with a default takes the default.
    gm.say(".kickplayer jaina was rude to the guards");
    assert(systemMessages(gm.read())[0] == ChatColor.sky
        ~ "Attempting to kick Jaina from the server for \"was rude to the guards\".|r");
    auto again = loggedIn(context, db, 9, "Varian", Position(5, 0, 0));
    gm.read();
    gm.say(".kickplayer varian");
    assert(systemMessages(gm.read())[0].canFind("for \"No reason\""));

    // `OnOff` reads "on" and "off" only; an optional `Nullable!OnOff` toggles when it is missing.
    gm.say(".cheat explore maybe");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ ".cheat explore <on|off>|r",
        "Reveal or clear map exploration."]);
    enum activated = ChatColor.sky ~ "Skip area requirements: on for Anduin.|r";
    enum deactivated = ChatColor.sky ~ "Skip area requirements: off for Anduin.|r";
    gm.say(".cheat triggerpass");
    assert(systemMessages(gm.read()).canFind(activated));
    gm.say(".cheat triggerpass");
    assert(systemMessages(gm.read()).canFind(deactivated));
    gm.say(".cheat triggerpass on");
    gm.say(".cheat triggerpass on");
    assert(systemMessages(gm.read()).count(activated) == 2);
}

/// Pet commands report a missing pet or an unavailable action.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.gameMaster);
    gm.read();
    gm.say(".pet renamepet Fluffy");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "You have no pet.|r"]);
    gm.say(".pet addspell 133");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Jaina has no pet.|r"]);
    gm.say(".pet createpet 299");
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.softRed,
        "Choose a tameable creature entry and a living hunter with no callable pet.")));
}

/// GM tickets: a player asks for help; the GM channel's `.gmTicket` commands list and remove tickets, as ArcEmu's.
unittest
{
    import dmangos.bytes : ByteWriter;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.gameMaster);
    anduin.read();
    gm.read();

    // Without a GM channel the commands show their help.
    gm.say(".gmTicket list");
    const help = systemMessages(gm.read());
    assert(help.length && !help.canFind(ChatColor.softRed ~ "Player flight is unavailable in this client.|r"));

    // A ticket: made, then read back.
    ByteWriter w;
    w.put(ubyte(1));
    w.put(0u);
    w.put(-8949.95f);
    w.put(-132.49f);
    w.put(83.53f);
    w.putCString("I am stuck");
    w.putCString("");
    anduin.write(Opcode.CMSG_GMTICKET_CREATE, w.data);
    auto made = anduin.read();
    assert(made.length == 1 && made[0].opcode == Opcode.SMSG_GMTICKET_CREATE && made[0].body_[0] == 2);
    anduin.write(Opcode.CMSG_GMTICKET_GETTICKET, null);
    auto got = anduin.read();
    assert(got[0].opcode == Opcode.SMSG_GMTICKET_GETTICKET && got[0].body_[0] == 6
        && got[0].body_.canFind(cast(const(ubyte)[]) "I am stuck"));

    // With the GM channel: the list, then the ticket removed and its author told.
    context.config.gmClientChannel = "gmsync";
    gm.say(".gmTicket list");
    auto listed = gm.read();
    bool says(const(ServerPacketRead)[] packets, string text)
    {
        return packets.canFind!(p => p.opcode == Opcode.SMSG_MESSAGECHAT
            && p.body_.canFind(cast(const(ubyte)[]) text));
    }
    assert(says(listed, "GmTicket:2") && says(listed, "GmTicket:3:1:1:1::Anduin:"), "the list");
    gm.say(".gmTicket get 1");
    assert(says(gm.read(), "GmTicket:4:1:I am stuck"));
    gm.say(".gmTicket remove 1");
    gm.read();
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_GMTICKET_DELETETICKET), "its author told");
    gm.say(".gmTicket get 1");
    assert(says(gm.read(), "GmTicket:0:Ticket not found."));
    // Toggling needs `z` (an administrator): the client then hears the system is off.
    auto admin = loggedIn(context, db, 10, "Varian", Position(-8940, -130, 83.5f), AccountLevel.administrator);
    admin.read();
    admin.say(".gmTicket toggle");
    assert(systemMessages(admin.read()) == [ChatColor.green ~ "TicketSystem disabled.|r"]);
    anduin.read();
    anduin.write(Opcode.CMSG_GMTICKET_SYSTEMSTATUS, null);
    auto status = anduin.read();
    assert(status.length == 1 && status[0].opcode == Opcode.SMSG_GMTICKET_SYSTEMSTATUS && status[0].body_[0] == 0);
}
