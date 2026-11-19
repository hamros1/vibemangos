/**
 * Chat commands: parsing a typed `.command`, checking the account's permission letters, finding
 * the command's row in `dmangos.world.commandtable` and running its handler. The commands, their
 * permission letters, the lookup and the replies match ArcEmu 2.4.3's exactly; that is a
 * requirement of the project.
 *
 * $(UL
 *   $(LI $(B Permissions.) Each account has a string of permission letters; a
 *        command's letter must be in it (`canUseCommand`), and `a` stands for
 *        every letter but `z`. The database's `account.gmlevel` is a number, so the
 *        `gm_permissions` setting gives each level its string; the default gives game masters
 *        (2) `a` and administrators (3) `az`. The string goes through
 *        `loadSecurity`, so "3" means `a` there too.)
 *   $(LI $(B Lookup.) A message starting with `.` or `!` is a command if the account has any
 *        permission (or `allow_player_commands` is set); otherwise it is said aloud. Each word
 *        is matched against `dmangos.world.commandtable`'s rows in order, and the first row the
 *        word abbreviates, and whose letter the account has, is taken
 *        (`executeCommandInTable`). A sub-table without a matching word lists its commands.
 *        A handler returning false shows the row's help, or "Incorrect syntax specified".)
 *   $(LI $(B Handlers.) Each row names its handler; the `Character` method of that name,
 *        with a lower-case first letter, runs it. Its parameters say what it takes: the command's
 *        words are converted to their types with `std.conv.to` (`invoke`); a `Rest` takes the rest
 *        of the line, `OnOff` reads "on" or "off", and a word that is missing or does not convert
 *        shows the command's help. The handlers are in `gmlevel0` .. `gmlevel3` and `gmdebug`, grouped
 *        by command level. Rows whose handler is not
 *        written yet (their systems do not exist yet) answer "Not yet implemented."
 *        (`handleNYICommand`). docs/COMMANDS.md lists both.)
 *   $(LI $(B GM log.) Commands that log what they do (`gmLog`) write to the file
 *        `gm_command_log` names, if any.)
 * )
 * The `command_overrides` table changes a command's letter.
 */
module dmangos.world.commands;

public import std.typecons : Nullable; // handler parameters may be `Nullable`

import dmangos.world.commandtable;
import dmangos.world.updatefields;

/// The colour codes of system messages.
enum : string
{
    MSG_COLOR_LIGHTRED = "|cffff6060",
    MSG_COLOR_LIGHTBLUE = "|cff00ccff",
    MSG_COLOR_BLUE = "|cff0000ff",
    MSG_COLOR_GREEN = "|cff00ff00",
    MSG_COLOR_RED = "|cffff0000",
    MSG_COLOR_GOLD = "|cffffcc00",
    MSG_COLOR_GREY = "|cff888888",
    MSG_COLOR_WHITE = "|cffffffff",
    MSG_COLOR_SUBWHITE = "|cffbbbbbb",
    MSG_COLOR_MAGENTA = "|cffff00ff",
    MSG_COLOR_YELLOW = "|cffffff00",
    MSG_COLOR_CYAN = "|cff00ffff",
}

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

/**
 * The permission letters of a security string, in lower case;
 * `3` and `4` stand for `a`; after `a` only `z` is kept; a leading `0` means none.
 */
string loadSecurity(string security) pure @safe
{
    import std.ascii : toLower;

    string letters;
    bool hasA;
    foreach (i, raw; security)
    {
        char c = toLower(raw);
        if (c == '4' || c == '3')
            c = 'a';
        if (c == 'a')
        {
            letters ~= 'a';
            hasA = true;
        }
        else if (!hasA && c == '0' && i == 0)
            break;
        else if (!hasA || c == 'z')
            letters ~= c;
    }
    return letters;
}

/// Whether `permissions` allow a command of the letter `group`: `a` allows all but `z`; group 0 needs any permission.
bool canUseCommand(string permissions, char group) pure nothrow @safe @nogc
{
    if (permissions.length == 0)
        return false;
    if (group == 0)
        return true;
    if (permissions[0] == 'a' && group != 'z')
        return true;
    foreach (c; permissions)
        if (c == group)
            return true;
    return false;
}

/// Whether the account is a game master: an `a` among the letters.
bool hasGMPermissions(string permissions) pure nothrow @safe @nogc
{
    foreach (c; permissions)
        if (c == 'a')
            return true;
    return false;
}

unittest
{
    assert(loadSecurity("AZ") == "az" && loadSecurity("3") == "a" && loadSecurity("abz") == "az");
    assert(loadSecurity("0bc") == "" && loadSecurity("bc0") == "bc0");
    assert(canUseCommand("az", 'z') && canUseCommand("a", 'm') && !canUseCommand("a", 'z'));
    assert(canUseCommand("bc", 'b') && !canUseCommand("bc", 'm') && !canUseCommand("bc", '0'));
    assert(!canUseCommand("", 'b') && hasGMPermissions("bca") && !hasGMPermissions("bc"));
}

/**
 * The rows a `command_overrides` row gives a new letter: the command `command` ("name" or "name sub",
 * each the start of a row's name; "name *" for every row of a sub-table). Returns the full paths of
 * the rows changed, which are empty if none matched.
 */
string[] overrideTargets(string command) pure @safe
{
    import std.string : indexOf;
    import std.uni : sicmp;

    const space = command.indexOf(' ');
    const name = space < 0 ? command : command[0 .. space];
    const sub = space < 0 ? null : command[space + 1 .. $];
    // The typed text starts the row's name, in any case.
    static bool starts(string row, string typed)
    {
        return typed.length <= row.length && sicmp(row[0 .. typed.length], typed) == 0;
    }

    foreach (ref row; commandTable)
    {
        if (!starts(row.name, name))
            continue;
        if (sub is null)
            return [row.name];
        string[] paths;
        foreach (ref child; row.children)
        {
            if (sub.length && sub[0] == '*')
                paths ~= row.name ~ " " ~ child.name;
            else if (starts(child.name, sub))
                return [row.name ~ " " ~ child.name];
        }
        return paths;
    }
    return null;
}

unittest
{
    assert(overrideTargets("gm on") == ["gm on"] && overrideTargets("modify h") == ["modify hp"]);
    assert(overrideTargets("gm *").length == 6 && overrideTargets("nosuch").length == 0);
}

/// The method that runs the handler `handler`: `HandleGMOnCommand` is `handleGMOnCommand`.
string handlerMethod(string handler) pure @safe
{
    import std.ascii : toLower;

    return toLower(handler[0]) ~ handler[1 .. $];
}

/// Every handler named in `table` and its sub-tables, once each.
string[] collectHandlers(immutable(ChatCommand)[] table) pure @safe
{
    import std.algorithm.searching : canFind;

    string[] found;
    foreach (ref row; table)
    {
        if (row.handler.length && !found.canFind(row.handler))
            found ~= row.handler;
        foreach (handler; collectHandlers(row.children))
            if (!found.canFind(handler))
                found ~= handler;
    }
    return found;
}

/// Every update field the `.modify` rows name.
string[] collectFields(immutable(ChatCommand)[] table) pure @safe
{
    import std.algorithm.searching : canFind;

    string[] found;
    foreach (ref row; table)
        foreach (field; [row.field, row.fieldMax])
            if (field.length && !found.canFind(field))
                found ~= field;
    return found;
}

private enum string[] modifyFields = collectFields(modifyCommandTable);

/// The slot of an update field as a `.modify` row names it ("UNIT_FIELD_RESISTANCES + 1").
size_t fieldSlot(string field) pure @safe
{
    switch (field)
    {
        static foreach (name; modifyFields)
        {
    case name:
            return mixin(name);
        }
    default:
        assert(0, "not a .modify field: " ~ field);
    }
}

unittest
{
    assert(fieldSlot("UNIT_FIELD_RESISTANCES + 1") == UNIT_FIELD_RESISTANCES + 1);
    assert(fieldSlot("UNIT_FIELD_HEALTH") == UNIT_FIELD_HEALTH);
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
    TIME_MINUTE = 60,
    TIME_HOUR = TIME_MINUTE * 60,
    TIME_DAY = TIME_HOUR * 24,
    TIME_MONTH = TIME_DAY * 30,
    TIME_YEAR = TIME_MONTH * 12,
}

/**
 * A time period typed in a command: numbers each followed by `y`, `m` (months), `d`
 * or `h`, added up, in seconds. Reading stops at anything that is not a digit, and a number
 * without a letter is ignored, so "perm" is 0. -1 for an unknown letter.
 */
int getTimePeriodFromString(const(char)[] text) pure nothrow @safe @nogc
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
        case 'y': multiplier = TIME_YEAR; break;
        case 'm': multiplier = TIME_MONTH; break;
        case 'd': multiplier = TIME_DAY; break;
        case 'h': multiplier = TIME_HOUR; break;
        default: return -1;
        }
        ++i;
        total += multiplier * number;
    }
    return cast(int) total;
}

/// A number of seconds in words: "1 days, 2 hours, " and so on.
string convertTimeStampToString(uint timestamp) pure @safe
{
    import std.conv : to;

    const seconds = timestamp % 60;
    const mins = timestamp / TIME_MINUTE % 60;
    const hours = timestamp / TIME_HOUR % 24;
    const days = timestamp / TIME_DAY % 30;
    const months = timestamp / TIME_MONTH % 12;
    const years = timestamp / TIME_YEAR;
    string result;
    if (years)
        result ~= years.to!string ~ " years, ";
    if (months)
        result ~= months.to!string ~ " months, ";
    if (days)
        result ~= days.to!string ~ " days, ";
    if (hours)
        result ~= hours.to!string ~ " hours, ";
    if (mins)
        result ~= mins.to!string ~ " minutes, ";
    if (seconds)
        result ~= seconds.to!string ~ " seconds";
    return result;
}

/// A Unix time as a date: "Monday, 05 January 2026, 09:04:01", in local time.
string convertTimeStampToDataTime(long timestamp) @safe
{
    import std.datetime.systime : SysTime;
    import std.format : format;

    static immutable string[7] days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    static immutable string[12] months = ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"];
    const t = SysTime.fromUnixTime(timestamp);
    return format!"%s, %02d %s %d, %02d:%02d:%02d"(days[t.dayOfWeek], t.day, months[t.month - 1], t.year, t.hour,
        t.minute, t.second);
}

/// C's `ctime`: "Wed Jun 30 21:49:08 1993\n", in local time, as the IP ban message prints it.
string ctimeString(long timestamp) @safe
{
    import std.datetime.systime : SysTime;
    import std.format : format;

    static immutable string[7] days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable string[12] months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
        "Dec"];
    const t = SysTime.fromUnixTime(timestamp);
    return format!"%s %s %2d %02d:%02d:%02d %d\n"(days[t.dayOfWeek], months[t.month - 1], t.day, t.hour, t.minute,
        t.second, t.year);
}

unittest
{
    assert(getTimePeriodFromString("1d2h") == 93_600 && getTimePeriodFromString("perm") == 0);
    assert(getTimePeriodFromString("5") == 0 && getTimePeriodFromString("3x") == -1);
    assert(getTimePeriodFromString("1m") == 2_592_000);
    assert(convertTimeStampToString(93_605) == "1 days, 2 hours, 5 seconds");
    assert(convertTimeStampToString(TIME_YEAR + TIME_MONTH + 61) == "1 years, 1 months, 1 minutes, 1 seconds");
}

/// See the module documentation.
mixin template ChatCommands()
{
    import std.format : format;
    import dmangos.log;
    import dmangos.world.commands;
    import dmangos.world.commandtable;
    import dmangos.world.creature : Creature;
    import dmangos.world.objects : HighGuid, highGuidOf;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.queries : chatMessage;
    import dmangos.world.updatefields;

private:
    /// Every handler the command tables name.
    enum string[] arcHandlers = collectHandlers(commandTable);

    /// `handle...Command` methods that no row names on purpose (the "Not yet implemented." answer itself).
    enum string[] unlistedHandlers = ["handleNYICommand"];

    // -----------------------------------------------------------------------
    // Permissions
    // -----------------------------------------------------------------------

    /// A row's letter, after `command_overrides`.
    char commandGroup(string path, ref immutable ChatCommand row) const
    {
        if (auto overridden = path in context.commandOverrides)
            return *overridden;
        return row.group;
    }

    // -----------------------------------------------------------------------
    // Parsing and running commands
    // -----------------------------------------------------------------------

    /// True if `text` was a command (run or refused), false if it is to be said.
    bool parseCommands(string text)
    {
        if (text.length == 0)
            return false;
        if (!hasPermissions && !context.config.allowPlayerCommands)
            return false;
        if (text[0] != '!' && text[0] != '.')
            return false;
        if (text.length > 1 && text[1] == '.') // skip '..'
            return false;
        trace!"%s: '%s' (%s) typed %s"(remoteAddress, player.data.name, account.username, text);
        if (!executeCommandInTable(commandTable, null, text[1 .. $]))
            systemMessage("There is no such command, or you do not have access to it.");
        return true;
    }

    /// Finds the row of `table` the first word of `text` abbreviates and runs it, or the sub-table's row
    /// for the next word; false if no row matches. `path` is the names of the tables above, for overrides.
    bool executeCommandInTable(immutable(ChatCommand)[] table, string path, string text)
    {
        size_t i;
        while (i < text.length && text[i] != ' ')
            ++i;
        const cmd = text[0 .. i];
        while (i < text.length && text[i] == ' ')
            ++i;
        const args = text[i .. $];
        if (cmd.length == 0)
            return false;

        foreach (ref row; table)
        {
            if (!hasStringAbbr(row.name, cmd))
                continue;
            const rowPath = path.length ? path ~ " " ~ row.name : row.name;
            const group = commandGroup(rowPath, row);
            if (group != '0' && !canUseCommand(group))
                continue;

            if (row.children.length)
            {
                if (!executeCommandInTable(row.children, rowPath, args))
                {
                    if (row.help.length)
                        sendMultilineMessage(row.help);
                    else
                    {
                        greenSystemMessage("Available Subcommands:");
                        foreach (ref child; row.children)
                        {
                            const childGroup = commandGroup(rowPath ~ " " ~ child.name, child);
                            if (childGroup == '0' || canUseCommand(childGroup))
                                blueSystemMessage(format!" %s - %s"(child.name,
                                    child.help.length ? child.help : "No Help Available"));
                        }
                    }
                }
                return true;
            }

            if (row.handler is null && (row.field.length || row.fieldMax.length))
            {
                if (args.length == 0)
                    redSystemMessage("No values specified.");
                const result = row.valueType == 2 ? cmdSetField!float(row.field, row.fieldMax, row.name, args)
                    : cmdSetField!uint(row.field, row.fieldMax, row.name, args);
                if (!result)
                    redSystemMessage("Must be in the form of (command) <value>, or, (command) <value> <maxvalue>");
            }
            else if (!callHandler(row.handler, args))
            {
                if (row.help.length)
                    sendMultilineMessage(row.help);
                else
                    redSystemMessage(format!"Incorrect syntax specified. Try .help %s for the correct syntax."(
                        row.name));
            }
            return true;
        }
        return false;
    }

    /// Runs the handler `handler` with the text after the command's words.
    bool callHandler(string handler, string args)
    {
        // Every `handle...Command` method is named by a row of the tables: one misspelled would never run,
        // and its command would answer "Not yet implemented." instead.
        static foreach (member; __traits(allMembers, typeof(this)))
            static if (member.length > "handleCommand".length && member[0 .. 6] == "handle"
                && member[$ - 7 .. $] == "Command" && !unlistedHandlers.canFind(member))
                static assert(arcHandlers.canFind!((name, m) => handlerMethod(name) == m)(member),
                    member ~ " is not named by any row of the command tables (dmangos.world.commandtable)");

        switch (handler)
        {
            static foreach (name; arcHandlers)
            {
                static if (__traits(hasMember, typeof(this), handlerMethod(name)))
                {
        case name:
                    return invoke!(handlerMethod(name))(args);
                }
            }
        default:
            return handleNYICommand();
        }
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

    /// What a command whose system does not exist yet answers.
    bool handleNYICommand()
    {
        redSystemMessage("Not yet implemented.");
        return true;
    }

    // -----------------------------------------------------------------------
    // System messages
    // -----------------------------------------------------------------------

    /// A system message to this player, cut at 1023 bytes.
    void systemMessage(string text)
    {
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0,
            text.length > 1023 ? text[0 .. 1023] : text)));
    }

    /// A system message in the colour `color`.
    void colorSystemMessage(string color, string text)
    {
        systemMessage(color ~ (text.length > 1023 ? text[0 .. 1023] : text) ~ "|r");
    }

    /// A system message in light red.
    void redSystemMessage(string text)
    {
        colorSystemMessage(MSG_COLOR_LIGHTRED, text);
    }

    /// A system message in green.
    void greenSystemMessage(string text)
    {
        colorSystemMessage(MSG_COLOR_GREEN, text);
    }

    /// A system message in light blue.
    void blueSystemMessage(string text)
    {
        colorSystemMessage(MSG_COLOR_LIGHTBLUE, text);
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

    /// The selected player on this map, oneself if nothing is selected.
    Character getSelectedChar(bool showError)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            if (showError)
                greenSystemMessage("Auto-targeting self.");
            return this;
        }
        auto found = cast(Character) map.find(guid);
        if (found is null && showError)
            redSystemMessage("This command requires that you select a player.");
        return found;
    }

    /// The selected creature, or null (with an error message if `showError`).
    Creature getSelectedCreature(bool showError)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Creature creature;
        if (highGuidOf(guid) == HighGuid.unit)
            creature = cast(Creature) map.findObject(guid);
        if (creature is null && showError)
            redSystemMessage("This command requires that you select a creature.");
        return creature;
    }

    // -----------------------------------------------------------------------
    // .modify's field rows
    // -----------------------------------------------------------------------

    /**
     * A `.modify` row that sets a field, as an integer (`T` is `uint`) or a `float`: the selected
     * player's, or creature's, field set to the first word of `args`, and `fieldMax` to the second.
     */
    bool cmdSetField(T)(string field, string fieldMax, string fieldName, string args)
    {
        import std.conv : ConvException, to;

        const hasMax = fieldMax.length > 0;
        const value = nextWord(args), maximum = hasMax ? nextWord(args) : "0";
        if (value is null || maximum is null)
            return false;
        T av, mv;
        try
        {
            av = value.to!T;
            mv = maximum.to!T;
        }
        catch (ConvException)
            return false;
        // Integer and float values are checked a little differently.
        static if (is(T == float))
            const invalidValue = av <= 0;
        else
            const invalidValue = av == 0 && mv > 0;
        if (invalidValue || hasMax && (mv < av || mv <= 0))
        {
            redSystemMessage("Values are invalid. Value must be < max (if max exists), and both must be > 0.");
            return true;
        }

        enum valueFormat = is(T == float) ? "%.1f" : "%d";
        enum logFormat = is(T == float) ? "%f" : "%s";
        const shown = hasMax ? format!(valueFormat ~ "/" ~ valueFormat)(av, mv) : format!valueFormat(av);
        static uint raw(T number) @trusted
        {
            return *cast(uint*) &number; // a float's bits, or the integer itself
        }

        const slot = fieldSlot(field);
        const maxSlot = hasMax ? fieldSlot(fieldMax) : 0;
        static if (is(T == uint))
            const stored = slot == UNIT_FIELD_STAT1 ? av / 2 : av; // the agility row stores half the value
        else
            const stored = av;
        if (auto plr = getSelectedChar(false))
        {
            const name = plr.player.data.name;
            gmLog(format!("used modify field value: %s, " ~ logFormat ~ " on %s")(fieldName, av, name));
            blueSystemMessage(format!"You set the %s of %s to %s."(fieldName, name, shown));
            plr.greenSystemMessage(format!"%s set your %s to %s."(player.data.name, fieldName, shown));
            plr.player.values.setSlot(slot, raw(stored));
            if (hasMax)
                plr.player.values.setSlot(maxSlot, raw(mv));
            plr.flushPlayerChanges();
        }
        else if (auto cr = getSelectedCreature(false))
        {
            if (!(slot < UNIT_END && maxSlot < UNIT_END))
                return false;
            const name = cr.template_.name;
            blueSystemMessage(format!"Setting %s of %s to %s."(fieldName, name, shown));
            gmLog(format!("used modify field value: [creature]%s, " ~ logFormat ~ " on %s")(fieldName, av, name));
            cr.values.setSlot(slot, raw(stored));
            if (hasMax)
                cr.values.setSlot(maxSlot, raw(mv));
            map.flushObjectChanges(cr);
        }
        else
            redSystemMessage("Invalid Selection.");
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
    assert(systemMessages(mod.read()) == ["There is no such command, or you do not have access to it."]);

    // A group name alone lists what the player may use in it: `.gm` for the moderator.
    mod.say(".gm");
    assert(systemMessages(mod.read()) == [MSG_COLOR_GREEN ~ "Available Subcommands:|r",
        MSG_COLOR_LIGHTBLUE ~ " list - Shows active GM's|r", MSG_COLOR_LIGHTBLUE ~ " off - Sets GM tag off|r",
        MSG_COLOR_LIGHTBLUE ~ " on - Sets GM tag on|r",
        MSG_COLOR_LIGHTBLUE ~ " whisperblock - Blocks like .gmon except without the <GM> tag|r",
        MSG_COLOR_LIGHTBLUE ~ " allowwhispers - Allows whispers from player <s> while in gmon mode.|r",
        MSG_COLOR_LIGHTBLUE ~ " blockwhispers - Blocks whispers from player <s> while in gmon mode.|r"]);

    // The first row in table order wins: `.k` is `.kill`, which needs a selection.
    gm.say(".k");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "A valid selection is required.|r"]);

    // A command whose system does not exist yet says so.
    gm.say(".cheat fly");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Not yet implemented.|r"]);

    // `.invisible`, both ways, in ArcEmu's words (its double space included).
    gm.say(".invisible");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Invisibility and Invincibility are now  ON. You may have "
        ~ "to leave and re-enter this zone for changes to take effect.|r"]);
    assert(gm.session.character.gmInvisible && gm.session.inWorld.untouchable);
    gm.say(".invisible");
    assert(systemMessages(gm.read())[0].canFind("now  OFF."));
    assert(!gm.session.character.gmInvisible && !gm.session.inWorld.untouchable);

    // A handler refusing its arguments shows the row's help.
    gm.say(".levelup -2");
    assert(systemMessages(gm.read()) == ["Levelup x lvls"]);

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
    assert(systemMessages(gm.read()) == ["Sets GM tag off"]);
    gm.say("!he nosuch");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED
        ~ "Sorry, no help was found for this command, or that command does not exist.|r"]);

    // `..` is never a command.
    gm.say("..what");
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT] && systemMessages(gm.read()).length == 0);
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
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Setting GM Flag on yourself...|r", MSG_COLOR_LIGHTBLUE
        ~ "GM Flag Set. It will appear above your name and in chat messages until you use !gm off.|r"]);
    const jaina = gm.session.character;
    assert(jaina.gmTagOn && jaina.hasFlag(PlayerFlags.gm));
    player.read();
    gm.say(".gm on");
    assert(systemMessages(gm.read())[1] == MSG_COLOR_LIGHTRED
        ~ "GM Flag is already set on. Use !gm off to disable it.|r");

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
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Now accepting whispers from Anduin.|r"]);
    player.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "help me", "Jaina"));
    assert(opcodesOf(gm.read()) == [Opcode.SMSG_MESSAGECHAT]);
    player.read();

    gm.say(".gm off");
    assert(!jaina.gmTagOn && !jaina.hasFlag(PlayerFlags.gm));
    gm.read();
    // `.gm list`: names and permissions.
    player.read();
    gm.say(".gm list");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "There are following active GMs on this server:|r",
        " - Jaina [a]"]);
}

/// `.modify` field rows, overrides, the GM log, kicks and mutes.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db, (ref c) {
        import dmangos.world.config : CommandOverride;

        c.commandOverrides = [CommandOverride("gps", "z")];
    });
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    auto admin = loggedIn(context, db, 8, "Varian", Position(5, 0, 0), AccountLevel.administrator);
    auto player = loggedIn(context, db, 9, "Jaina", Position(6, 0, 0));
    gm.read();
    admin.read();

    // `.modify hp value max` sets both fields of oneself (nothing selected), and tells the player.
    gm.say(".modify hp 400 500");
    const me = gm.session.character;
    assert(me.values[UNIT_FIELD_HEALTH] == 400 && me.values[UNIT_FIELD_MAXHEALTH] == 500);
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "You set the hp of Anduin to 400/500.|r",
        MSG_COLOR_GREEN ~ "Anduin set your hp to 400/500.|r"]);
    gm.say(".modify hp 600 500");
    assert(systemMessages(gm.read())[0].canFind("Values are invalid"));
    gm.say(".modify scale 2.5");
    assert(me.values.get!OBJECT_FIELD_SCALE_X == 2.5f);
    gm.read();
    assert(context.gmLogLines[0].canFind("Player Anduin :: used modify field value: hp, 400 on Anduin"));

    // command_overrides made `.gps` an administrator's command.
    gm.say(".gps");
    assert(systemMessages(gm.read()) == ["There is no such command, or you do not have access to it."]);
    admin.say(".gps");
    assert(systemMessages(admin.read())[0].canFind("Current Position"));

    // A `z` account cannot be kicked by an `a` one.
    gm.say(".kickplayer varian spamming");
    assert(systemMessages(gm.read())[$ - 1] == MSG_COLOR_LIGHTRED
        ~ "You cannot kick Varian, as they are a higher level gm than you.|r");

    // `.account mute`: the player is told, and cannot speak.
    gm.say(".account mute JAINA 2h");
    gm.read();
    assert(systemMessages(player.read())[$ - 1].canFind("Your voice has been muted until"));
    player.say("hi");
    assert(systemMessages(player.read()) == ["Your voice is currently muted by a moderator."]);
    gm.say(".account unmute JAINA");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Account 'JAINA' has been unmuted.|r"]);
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
    assert(systemMessages(gm.read()) == ["Modifies the movement speed of the selected target."]);
    gm.say(".modify speed");
    assert(systemMessages(gm.read()) == ["Modifies the movement speed of the selected target."]);
    gm.say(".modify speed 14");
    assert(gm.session.character.speeds[MoveType.run] == 14);
    gm.read();

    // Optional words take their defaults: one item, no random property.
    gm.say(".character additem 117");
    assert(gm.session.character.inventory.count(itemJerky) == 1);
    gm.say(".character additem 117 x");
    assert(systemMessages(gm.read())[$ - 1] == "Adds item x count y" && gm.session.character.inventory.count(itemJerky) == 1);

    // `Rest` takes the rest of the line; a missing `Rest` with a default takes the default.
    gm.say(".kickplayer jaina was rude to the guards");
    assert(systemMessages(gm.read())[0] == MSG_COLOR_LIGHTBLUE
        ~ "Attempting to kick Jaina from the server for \"was rude to the guards\".|r");
    auto again = loggedIn(context, db, 9, "Varian", Position(5, 0, 0));
    gm.read();
    gm.say(".kickplayer varian");
    assert(systemMessages(gm.read())[0].canFind("for \"No reason\""));

    // `OnOff` reads "on" and "off" only; an optional `Nullable!OnOff` toggles when it is missing.
    gm.say(".cheat explore maybe");
    assert(systemMessages(gm.read()) == ["Reveals the unexplored parts of the map."]);
    enum activated = MSG_COLOR_LIGHTBLUE ~ "activated the triggerpass cheat on Anduin.|r";
    enum deactivated = MSG_COLOR_LIGHTBLUE ~ "deactivated the triggerpass cheat on Anduin.|r";
    gm.say(".cheat triggerpass");
    assert(systemMessages(gm.read()).canFind(activated));
    gm.say(".cheat triggerpass");
    assert(systemMessages(gm.read()).canFind(deactivated));
    gm.say(".cheat triggerpass on");
    gm.say(".cheat triggerpass on");
    assert(systemMessages(gm.read()).count(activated) == 2);
}

/// `.pet`: without a pet, its commands say so as ArcEmu's do; `createpet` (disabled there) answers nothing.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 9, "Jaina", Position(-8940, -132, 83.5f), AccountLevel.gameMaster);
    gm.read();
    gm.say(".pet renamepet Fluffy");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "You have no pet.|r"]);
    gm.say(".pet addspell 133");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Jaina has no pet.|r"]);
    gm.say(".pet createpet 299");
    assert(systemMessages(gm.read()).length == 0);
}

/// GM tickets: a player asks for help; the GM channel's `.gmTicket` commands list and remove tickets, as ArcEmu's.
unittest
{
    import std.algorithm.searching : canFind;
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
    assert(help.length && !help.canFind(MSG_COLOR_LIGHTRED ~ "Not yet implemented.|r"));

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
        foreach (p; packets)
            if (p.opcode == Opcode.SMSG_MESSAGECHAT && p.body_.canFind(cast(const(ubyte)[]) text))
                return true;
        return false;
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
    assert(systemMessages(admin.read()) == [MSG_COLOR_GREEN ~ "TicketSystem disabled.|r"]);
    anduin.read();
    anduin.write(Opcode.CMSG_GMTICKET_SYSTEMSTATUS, null);
    auto status = anduin.read();
    assert(status.length == 1 && status[0].opcode == Opcode.SMSG_GMTICKET_SYSTEMSTATUS && status[0].body_[0] == 0);
}
