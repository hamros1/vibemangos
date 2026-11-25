/// Color and hyperlink formatting shared by the in-game chat surfaces.
module dmangos.world.chatstyle;

import std.format : format;

/// The client’s chat color escape sequences.
enum ChatColor : string
{
    plain = "",
    softRed = "|cffff6060",
    sky = "|cff00ccff",
    blue = "|cff0000ff",
    green = "|cff00ff00",
    red = "|cffff0000",
    gold = "|cffffcc00",
    grey = "|cff888888",
    white = "|cffffffff",
    silver = "|cffbbbbbb",
    magenta = "|cffff00ff",
    yellow = "|cffffff00",
    cyan = "|cff00ffff",
    poorItem = "|cff9d9d9d",
    uncommonItem = "|cff1eff00",
    rareItem = "|cff0070dd",
    epicItem = "|cffa335ee",
    legendaryItem = "|cffff8000",
    artifactItem = "|cffe6cc80",
}

private enum reset = "|r";

string colored(ChatColor color, string text) pure @safe
{
    return color == ChatColor.plain ? text : color ~ text ~ reset;
}

/// Fits one system-chat packet while keeping the color reset intact.
string systemChatText(string text, ChatColor color = ChatColor.plain) pure @safe
{
    const limit = color == ChatColor.plain ? 1023 : 1023 - color.length - reset.length;
    return colored(color, text.length > limit ? text[0 .. limit] : text);
}

/// Converts existing numbered settings at the configuration boundary.
ChatColor announcementTint(uint index) pure nothrow @safe @nogc
{
    static immutable palette = [ChatColor.plain, ChatColor.softRed, ChatColor.sky, ChatColor.blue, ChatColor.green,
        ChatColor.red, ChatColor.gold, ChatColor.grey, ChatColor.white, ChatColor.magenta, ChatColor.yellow];
    return index < palette.length ? palette[index] : ChatColor.plain;
}

private string hyperlink(string key, string label)
{
    return "|H" ~ key ~ "|h[" ~ label ~ "]|h";
}

string playerChatLink(string name)
{
    return hyperlink("player:" ~ name, name);
}

string itemChatLink(uint entry, string name, uint quality)
{
    // Item rarity colors are fixed by the client and are separate from message colors.
    static immutable palette = [ChatColor.poorItem, ChatColor.white, ChatColor.uncommonItem,
        ChatColor.rareItem, ChatColor.epicItem, ChatColor.legendaryItem, ChatColor.artifactItem];
    const color = quality < palette.length ? palette[quality] : ChatColor.white;
    return colored(color, hyperlink(format!"item:%s:0:0:0"(entry), name));
}

unittest
{
    assert(announcementTint(1) == ChatColor.softRed && announcementTint(10) == ChatColor.yellow);
    assert(announcementTint(0) == ChatColor.plain && announcementTint(11) == ChatColor.plain);
    assert(colored(ChatColor.green, "Ready") == "|cff00ff00Ready|r");
    import std.array : replicate;
    const longLine = systemChatText("a".replicate(1100), ChatColor.green);
    assert(longLine.length == 1023 && longLine[$ - 2 .. $] == reset);
    assert(playerChatLink("Jaina") == "|Hplayer:Jaina|h[Jaina]|h");
    assert(itemChatLink(117, "Tough Jerky", 0) == "|cff9d9d9d|Hitem:117:0:0:0|h[Tough Jerky]|h|r");
    assert(itemChatLink(117, "Tough Jerky", uint.max) == "|cffffffff|Hitem:117:0:0:0|h[Tough Jerky]|h|r");
}
