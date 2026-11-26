/**
 * Staff presence, announcements, and player support tools.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmstaff;

import dmangos.world.character : Character;

import std.algorithm.comparison : max, min;
import std.algorithm.searching : canFind;
import std.format : format;
import std.math : floor;
import dmangos.world.chatstyle : announcementTint, itemChatLink, playerChatLink;
import dmangos.world.commands : ChatColor, colored, Rest;
import dmangos.world.gmtargets : GmRemoteOp;
import dmangos.world.movement : Position;
import dmangos.world.names : normalizedName;
import dmangos.world.player : PlayerFlags;
import dmangos.world.updatefields : PLAYER_FIELD_COINAGE, UNIT_FIELD_TARGET, UNIT_NPC_EMOTESTATE;

/// A chat link to an item, in 1.12's link format.
string itemLink(Character gm, uint entry)
{
    const item = entry in gm.context.data.items;
    return item is null ? format!"Item %s"(entry) : itemChatLink(entry, item.details.name, item.details.quality);
}

/// `message` as the configured announcement: tag, staff badge and author, in their colours.
string announcement(Character gm, string message, bool onScreen)
{
    const config = gm.context.config;
    string text = colored(announcementTint(config.announceTagColor), "[" ~ config.announceTag ~ "]");
    if (config.announceGmAdminTag)
    {
        const badge = gm.allowsStaff("staff.admin") ? "<Admin>" : gm.allowsStaff("staff.access") ? "<GM>" : "";
        if (badge.length)
            text ~= colored(announcementTint(config.announceGmTagColor), badge);
    }
    if (onScreen ? config.nameInWAnnounce : config.nameInAnnounce)
    {
        const name = gm.player.data.name;
        const author = onScreen ? "[" ~ name ~ "]" : playerChatLink(name);
        text ~= colored(announcementTint(config.announceNameColor), author);
    }
    return text ~ ": " ~ colored(announcementTint(config.announceMessageColor), message);
}

/// `.announce <message>`: a chat announcement to the realm.
bool handleAnnounceCommand(Character gm, Rest message = Rest.init)
{
    if (message.length < 4 || message.canFind('%'))
    {
        gm.redSystemMessage("Announcements require at least four characters and cannot contain a percent sign.");
        return true;
    }
    gm.sendWorldText(gm.announcement(message, false));
    gm.gmLog(format!"announced to the realm [%s]"(message));
    return true;
}

/// `.gmannounce <message>`: a message to the staff online.
bool handleGmAnnounceCommand(Character gm, Rest message)
{
    const author = colored(ChatColor.green, playerChatLink(gm.player.data.name));
    gm.sendGmWorldText(colored(ChatColor.red, "[Team]") ~ " " ~ author ~ ": " ~ colored(ChatColor.yellow, message));
    gm.gmLog(format!"announced to staff [%s]"(message));
    return true;
}

/// `.wannounce <message>`: an on-screen announcement to the realm.
bool handleScreenAnnounceCommand(Character gm, Rest message)
{
    gm.sendWorldWideScreenText(gm.announcement(message, true));
    gm.gmLog(format!"announced on screen [%s]"(message));
    return true;
}

/// `.gm on`.
bool handleGmOnCommand(Character gm)
{
    return gm.setGmMode(true);
}

/// `.gm off`.
bool handleGmOffCommand(Character gm)
{
    return gm.setGmMode(false);
}

/// The GM tag and flag on or off, and the player shown or hidden accordingly.
bool setGmMode(Character gm, bool enabled)
{
    if (gm.player.gmTagOn == enabled && gm.player.hasFlag(PlayerFlags.gm) == enabled)
    {
        gm.blueSystemMessage(enabled ? "GM mode is already on." : "GM mode is already off.");
        return true;
    }
    gm.player.gmTagOn = enabled;
    gm.player.setFlag(PlayerFlags.gm, enabled);
    gm.flushPlayerChanges();
    gm.map.refreshVisibility(gm);
    gm.greenSystemMessage(enabled ? "GM mode on. Your GM tag is visible." : "GM mode off. Your GM tag is hidden.");
    return true;
}

/// `.gps`: the position of the selected player or creature, or one's own.
bool handleGpsCommand(Character gm)
{
    const guid = gm.player.values.get!UNIT_FIELD_TARGET;
    const mapId = gm.player.data.map;
    Position at = gm.player.position;
    uint zone = gm.player.data.zone;
    if (guid != 0)
    {
        if (auto other = gm.map.find(guid))
        {
            at = other.character.position;
            zone = other.character.data.zone;
        }
        else if (auto object = gm.map.findObject(guid))
            at = object.position; // creatures have no area without map data: the GM's zone, close by
        else
        {
            gm.redSystemMessage("Select a player or creature first.");
            return true;
        }
    }
    gm.systemMessage(format!"%s  ·  Map %s  ·  Zone %s  ·  %.3f, %.3f, %.3f  ·  Facing %.3f"
        (colored(ChatColor.green, "Position"), mapId, zone, at.x, at.y, at.z, at.orientation));
    return true;
}

/// `.kickplayer <name> [reason]`: the player disconnected, here or on its node.
bool handleKickCommand(Character gm, string name, Rest reason = Rest("No reason"))
{
    if (auto found = gm.context.onlinePlayer(name))
    {
        auto target = gm.sessionOf(found);
        gm.gmLog(format!"Kicked player %s from the server for %s"(target.player.data.name, reason));
        target.kickedBy(gm.gmSink, gm.player.data.name, gm.allowsStaff("staff.admin"), reason);
        return true;
    }
    const remote = gm.context.remotePlayer(name);
    if (remote !is null && gm.gmElsewhere(name, GmRemoteOp.kick, reason))
        gm.gmLog(format!"Kicked player %s from the server for %s"(remote.entry.name, reason));
    else
        gm.redSystemMessage("Player is not online at the moment.");
    return true;
}

/// `.character additem <item> [count] [random-property]`: items given to the selected player (or oneself).
bool handleAddInvItemCommand(Character gm, uint itemId, uint count = 1, int randomProperty = 0)
{
    auto target = gm.selectedCharacter(false);
    if (target is null)
        target = gm;
    const item = itemId in gm.context.data.items;
    if (item is null)
    {
        gm.redSystemMessage(format!"Item %d is not a valid item!"(itemId));
        return true;
    }
    gm.gmLog(format!"used add item command, item id %u [%s] to %s"(itemId, item.details.name,
        target.player.data.name));
    // Gives `count`, in as many stacks as it takes, not one stack capped at the item's maximum.
    if (target.giveItem(itemId, count == 0 ? 1 : count) == 0)
    {
        gm.sendNotification("No free slots were found in your inventory!");
        return true;
    }
    gm.greenSystemMessage(format!"Adding item %s (id: %d) to %s's inventory."(gm.itemLink(itemId), itemId,
        target.player.data.name));
    target.systemMessage(format!"%s added item %s to your inventory."(gm.player.data.name, gm.itemLink(itemId)));
    return true;
}

/// `.summon <name>`: the player brought here, from this node or another; offline, moved in the database.
bool handleSummonCommand(Character gm, Rest name)
{
    const at = gm.player.position;
    gm.gmLog(format!"summoned %s on map %u, %f %f %f"(name, gm.player.data.map, at.x, at.y, at.z));
    if (auto found = gm.context.onlinePlayer(name))
    {
        gm.sessionOf(found).summonedBy(gm.gmSink, gm.player.data.name, gm.player.data.map, at, gm.instanceId_);
        return true;
    }
    if (gm.gmElsewhere(name, GmRemoteOp.summon))
        return true;
    const guid = gm.context.database.characterGuid(normalizedName(name));
    if (guid == 0)
    {
        gm.redSystemMessage(format!"Player (%s) does not exist."(name));
        return true;
    }
    gm.context.database.moveOfflineCharacter(guid, gm.player.data.map, at.x, at.y, at.z, gm.player.data.zone);
    const info = gm.context.database.nameInfo(guid);
    gm.greenSystemMessage(format!"(Offline) %s has been summoned."(info.isNull ? name : info.get.name));
    return true;
}

/// `.appear <name>`: the GM teleported to the player, on this node or another.
bool handleAppearCommand(Character gm, Rest name)
{
    auto found = gm.context.onlinePlayer(name);
    if (found is null)
    {
        if (!gm.gmElsewhere(name, GmRemoteOp.appear))
            gm.redSystemMessage(format!"Player (%s) does not exist or is not logged in."(name));
        return true;
    }
    gm.sessionOf(found).appearedToBy(gm.gmSink, gm.player.data.name,
        (uint map, Position at, uint instance) { gm.commandTeleport(map, at, instance); });
    return true;
}

/// `.modify speed <speed>`: the selected player's movement speed.
bool handleModifySpeedCommand(Character gm, float speed)
{
    if (speed > 255 || speed < 1)
    {
        gm.redSystemMessage("Incorrect value. Range is 1..255");
        return true;
    }
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return true;
    if (target !is gm)
        gm.gmLog(format!"modified speed of %s to %2.2f."(target.player.data.name, speed));
    gm.greenSystemMessage(format!"You set the speed of %s to %2.2f."(target.player.data.name, speed));
    target.systemMessage(format!"%s set your speed to %2.2f."(gm.player.data.name, speed));
    target.applySpeed(speed);
    return true;
}

/// `.character learnskill <skill> <value> [max]`: a skill line taught to the selected player; its cap at
/// least its value.
bool handleLearnSkillCommand(Character gm, uint skill, uint value, uint maximum = 1)
{
    gm.blueSystemMessage(format!"Adding skill line %d"(skill));
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return false;
    gm.gmLog(format!"used add skill of %u %u %u on %s"(skill, value, maximum, target.player.data.name));
    const cap = max(maximum, value);
    target.applySkill(skill, cast(ushort) min(value, ushort.max), cast(ushort) min(cap, ushort.max));
    return true;
}

/// `.character advanceskill <skill> [points]`: a skill raised up to its cap; an unknown one learned.
bool handleModifySkillCommand(Character gm, uint skill, uint points = 1)
{
    gm.blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, points));
    auto target = gm.selectedCharacter(true);
    if (target is null)
        target = gm;
    gm.gmLog(format!"used modify skill of %u %u on %s"(skill, points, target.player.data.name));
    const current = target.player.skillValue(skill);
    if (current[1] == 0)
    {
        gm.systemMessage("The player does not know this skill. Adding it now.");
        target.applySkill(skill, 1, 300);
    }
    else
        target.applySkill(skill, cast(ushort) min(current[0] + points, current[1]), current[1]);
    return true;
}

/// The name of a skill (from SkillLine.dbc), or null.
string skillName(Character gm, uint skill)
{
    const line = gm.context.client.skillLines.lookup(skill);
    return line is null ? null : line.name[0];
}

/// `.character getskillinfo`: the selected player's skills with their values, caps and what auras add.
bool handleGetSkillsInfoCommand(Character gm)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return false;
    gm.blueSystemMessage(format!"Player: %s has skills"(target.player.data.name));
    foreach (skill; target.player.skillList)
    {
        if (gm.context.client.skillLines.lookup(skill[0]) is null)
            gm.redSystemMessage(format!"Invalid skill: %u"(skill[0]));
        else
            gm.blueSystemMessage(format!"  %s: Value: %u, MaxValue: %u. (+ %d bonus)"(gm.skillName(skill[0]), skill[1],
                skill[2], cast(int) target.player.skillWithBonus(skill[0]) - cast(int) skill[1]));
    }
    return true;
}

/// `.character removeskill <skill>`: a skill line the selected player has, removed.
bool handleRemoveSkillCommand(Character gm, uint skill)
{
    gm.blueSystemMessage(format!"Removing skill line %d"(skill));
    auto target = gm.selectedCharacter(true);
    if (target is null || target.player.skillValue(skill)[1] == 0)
    {
        gm.redSystemMessage(format!"Player doesn't have skill line %d"(skill));
        return true;
    }
    target.applySkill(skill, 0, 0);
    gm.gmLog(format!"used remove skill of %u on %s"(skill, target.player.data.name));
    target.systemMessage(format!"%s removed skill line %d from you. "(gm.player.data.name, skill));
    return true;
}

/// `.npc emote [emote]`: the selected creature's emote state.
bool handleEmoteCommand(Character gm, uint emote = 0)
{
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return false;
    creature.values.set!UNIT_NPC_EMOTESTATE(emote);
    gm.map.flushObjectChanges(creature);
    return true;
}

/// `.modify gold <copper>`: money added to or taken from the selected player, down to none.
bool handleModifyGoldCommand(Character gm, int total)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return true;
    const magnitude = total < 0 ? -long(total) : long(total);
    const gold = cast(uint) floor(magnitude / 10_000.0f);
    const silver = cast(uint) floor(magnitude / 100.0f) % 100;
    const copper = cast(uint)(magnitude % 100);
    const name = target.player.data.name;
    gm.gmLog(format!"used modify gold on %s, gold: %d"(name, total));
    long newGold = long(target.player.values.get!PLAYER_FIELD_COINAGE) + total;
    if (newGold < 0)
    {
        gm.greenSystemMessage(format!"Taking all gold from %s's backpack..."(name));
        target.greenSystemMessage(format!"%s took the all gold from your backpack."(gm.player.data.name));
        newGold = 0;
    }
    else if (total >= 0)
    {
        gm.greenSystemMessage(format!"Adding %u gold, %u silver, %u copper to %s's backpack..."(gold, silver,
            copper, name));
        target.greenSystemMessage(format!"%s added %u gold, %u silver, %u copper to your backpack."(
            gm.player.data.name, gold, silver, copper));
    }
    else
    {
        gm.greenSystemMessage(format!"Taking %u gold, %u silver, %u copper from %s's backpack..."(gold, silver,
            copper, name));
        target.greenSystemMessage(format!"%s took %u gold, %u silver, %u copper from your backpack."(
            gm.player.data.name, gold, silver, copper));
    }
    target.player.values.set!PLAYER_FIELD_COINAGE(cast(uint) min(newGold, uint.max));
    target.flushPlayerChanges();
    return true;
}

/// `.gotrig <trigger> [instance]`: the GM teleported to an area trigger (the instance is not used).
bool handleTriggerCommand(Character gm, uint triggerId, int instanceId = 0)
{
    const entry = triggerId == 0 ? null : gm.context.client.areaTriggers.lookup(triggerId);
    if (entry is null)
    {
        gm.redSystemMessage(format!"Could not find trigger %s"(triggerId));
        return true;
    }
    gm.commandTeleport(entry.mapId, Position(entry.x, entry.y, entry.z, 0));
    gm.greenSystemMessage(format!"Teleported to trigger %u on [%u][%.2f][%.2f][%.2f]"(entry.id, entry.mapId,
        entry.x, entry.y, entry.z));
    return true;
}

/// `.character unlearn <spell>`: a spell the selected player knows, removed.
bool handleUnlearnCommand(Character gm, uint spellId = 0)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return true;
    if (spellId == 0)
    {
        gm.redSystemMessage("You must specify a spell id.");
        return true;
    }
    gm.gmLog(format!"removed spell %u from %s"(spellId, target.player.data.name));
    if (!target.player.knowsSpell(spellId))
    {
        gm.redSystemMessage(format!"The player does not know spell %u."(spellId));
        return true;
    }
    target.greenSystemMessage(format!"Removed spell %u."(spellId));
    gm.greenSystemMessage(format!"Removed spell %u from %s."(spellId, target.player.data.name));
    target.unlearn(spellId);
    return true;
}

