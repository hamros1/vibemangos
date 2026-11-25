/// Staff presence, announcements, and player support tools.
module dmangos.world.gmstaff;

/// See the module documentation.
mixin template StaffCommands()
{
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

private:
    /// A chat link to an item, in 1.12's link format.
    string itemLink(uint entry)
    {
        const item = entry in context.data.items;
        return item is null ? format!"Item %s"(entry) : itemChatLink(entry, item.details.name, item.details.quality);
    }

    /// `message` as the configured announcement: tag, staff badge and author, in their colours.
    string announcement(string message, bool onScreen)
    {
        const config = context.config;
        string text = colored(announcementTint(config.announceTagColor), "[" ~ config.announceTag ~ "]");
        if (config.announceGmAdminTag)
        {
            const badge = allowsStaff("staff.admin") ? "<Admin>" : allowsStaff("staff.access") ? "<GM>" : "";
            if (badge.length)
                text ~= colored(announcementTint(config.announceGmTagColor), badge);
        }
        if (onScreen ? config.nameInWAnnounce : config.nameInAnnounce)
        {
            const name = player.data.name;
            const author = onScreen ? "[" ~ name ~ "]" : playerChatLink(name);
            text ~= colored(announcementTint(config.announceNameColor), author);
        }
        return text ~ ": " ~ colored(announcementTint(config.announceMessageColor), message);
    }

    /// `.announce <message>`: a chat announcement to the realm.
    bool handleAnnounceCommand(Rest message = Rest.init)
    {
        if (message.length < 4 || message.canFind('%'))
        {
            redSystemMessage("Announcements require at least four characters and cannot contain a percent sign.");
            return true;
        }
        sendWorldText(announcement(message, false));
        gmLog(format!"announced to the realm [%s]"(message));
        return true;
    }

    /// `.gmannounce <message>`: a message to the staff online.
    bool handleGmAnnounceCommand(Rest message)
    {
        const author = colored(ChatColor.green, playerChatLink(player.data.name));
        sendGmWorldText(colored(ChatColor.red, "[Team]") ~ " " ~ author ~ ": " ~ colored(ChatColor.yellow, message));
        gmLog(format!"announced to staff [%s]"(message));
        return true;
    }

    /// `.wannounce <message>`: an on-screen announcement to the realm.
    bool handleScreenAnnounceCommand(Rest message)
    {
        sendWorldWideScreenText(announcement(message, true));
        gmLog(format!"announced on screen [%s]"(message));
        return true;
    }

    /// `.gm on`.
    bool handleGmOnCommand()
    {
        return setGmMode(true);
    }

    /// `.gm off`.
    bool handleGmOffCommand()
    {
        return setGmMode(false);
    }

    /// The GM tag and flag on or off, and the player shown or hidden accordingly.
    bool setGmMode(bool enabled)
    {
        if (player.gmTagOn == enabled && player.hasFlag(PlayerFlags.gm) == enabled)
        {
            blueSystemMessage(enabled ? "GM mode is already on." : "GM mode is already off.");
            return true;
        }
        player.gmTagOn = enabled;
        player.setFlag(PlayerFlags.gm, enabled);
        flushPlayerChanges();
        map.refreshVisibility(this);
        greenSystemMessage(enabled ? "GM mode on. Your GM tag is visible." : "GM mode off. Your GM tag is hidden.");
        return true;
    }

    /// `.gps`: the position of the selected player or creature, or one's own.
    bool handleGpsCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        const mapId = player.data.map;
        Position at = player.position;
        uint zone = player.data.zone;
        if (guid != 0)
        {
            if (auto other = map.find(guid))
            {
                at = other.character.position;
                zone = other.character.data.zone;
            }
            else if (auto object = map.findObject(guid))
                at = object.position; // creatures have no area without map data: the GM's zone, close by
            else
            {
                redSystemMessage("Select a player or creature first.");
                return true;
            }
        }
        systemMessage(format!"%s  ·  Map %s  ·  Zone %s  ·  %.3f, %.3f, %.3f  ·  Facing %.3f"
            (colored(ChatColor.green, "Position"), mapId, zone, at.x, at.y, at.z, at.orientation));
        return true;
    }

    /// `.kickplayer <name> [reason]`: the player disconnected, here or on its node.
    bool handleKickCommand(string name, Rest reason = Rest("No reason"))
    {
        if (auto found = context.onlinePlayer(name))
        {
            auto target = sessionOf(found);
            gmLog(format!"Kicked player %s from the server for %s"(target.player.data.name, reason));
            target.kickedBy(gmSink, player.data.name, allowsStaff("staff.admin"), reason);
            return true;
        }
        const remote = context.remotePlayer(name);
        if (remote !is null && gmElsewhere(name, GmRemoteOp.kick, reason))
            gmLog(format!"Kicked player %s from the server for %s"(remote.entry.name, reason));
        else
            redSystemMessage("Player is not online at the moment.");
        return true;
    }

    /// `.character additem <item> [count] [random-property]`: items given to the selected player (or oneself).
    bool handleAddInvItemCommand(uint itemId, uint count = 1, int randomProperty = 0)
    {
        auto target = selectedCharacter(false);
        if (target is null)
            target = this;
        const item = itemId in context.data.items;
        if (item is null)
        {
            redSystemMessage(format!"Item %d is not a valid item!"(itemId));
            return true;
        }
        gmLog(format!"used add item command, item id %u [%s] to %s"(itemId, item.details.name,
            target.player.data.name));
        // Gives `count`, in as many stacks as it takes, not one stack capped at the item's maximum.
        if (target.giveItem(itemId, count == 0 ? 1 : count) == 0)
        {
            sendNotification("No free slots were found in your inventory!");
            return true;
        }
        greenSystemMessage(format!"Adding item %s (id: %d) to %s's inventory."(itemLink(itemId), itemId,
            target.player.data.name));
        target.systemMessage(format!"%s added item %s to your inventory."(player.data.name, itemLink(itemId)));
        return true;
    }

    /// `.summon <name>`: the player brought here, from this node or another; offline, moved in the database.
    bool handleSummonCommand(Rest name)
    {
        const at = player.position;
        gmLog(format!"summoned %s on map %u, %f %f %f"(name, player.data.map, at.x, at.y, at.z));
        if (auto found = context.onlinePlayer(name))
        {
            sessionOf(found).summonedBy(gmSink, player.data.name, player.data.map, at, instanceId_);
            return true;
        }
        if (gmElsewhere(name, GmRemoteOp.summon))
            return true;
        const guid = context.database.characterGuid(normalizedName(name));
        if (guid == 0)
        {
            redSystemMessage(format!"Player (%s) does not exist."(name));
            return true;
        }
        context.database.moveOfflineCharacter(guid, player.data.map, at.x, at.y, at.z, player.data.zone);
        const info = context.database.nameInfo(guid);
        greenSystemMessage(format!"(Offline) %s has been summoned."(info.isNull ? name : info.get.name));
        return true;
    }

    /// `.appear <name>`: the GM teleported to the player, on this node or another.
    bool handleAppearCommand(Rest name)
    {
        auto found = context.onlinePlayer(name);
        if (found is null)
        {
            if (!gmElsewhere(name, GmRemoteOp.appear))
                redSystemMessage(format!"Player (%s) does not exist or is not logged in."(name));
            return true;
        }
        sessionOf(found).appearedToBy(gmSink, player.data.name,
            (uint map, Position at, uint instance) { commandTeleport(map, at, instance); });
        return true;
    }

    /// `.modify speed <speed>`: the selected player's movement speed.
    bool handleModifySpeedCommand(float speed)
    {
        if (speed > 255 || speed < 1)
        {
            redSystemMessage("Incorrect value. Range is 1..255");
            return true;
        }
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        if (target !is this)
            gmLog(format!"modified speed of %s to %2.2f."(target.player.data.name, speed));
        greenSystemMessage(format!"You set the speed of %s to %2.2f."(target.player.data.name, speed));
        target.systemMessage(format!"%s set your speed to %2.2f."(player.data.name, speed));
        target.applySpeed(speed);
        return true;
    }

    /// `.character learnskill <skill> <value> [max]`: a skill line taught to the selected player; its cap at
    /// least its value.
    bool handleLearnSkillCommand(uint skill, uint value, uint maximum = 1)
    {
        blueSystemMessage(format!"Adding skill line %d"(skill));
        auto target = selectedCharacter(true);
        if (target is null)
            return false;
        gmLog(format!"used add skill of %u %u %u on %s"(skill, value, maximum, target.player.data.name));
        const cap = max(maximum, value);
        target.applySkill(skill, cast(ushort) min(value, ushort.max), cast(ushort) min(cap, ushort.max));
        return true;
    }

    /// `.character advanceskill <skill> [points]`: a skill raised up to its cap; an unknown one learned.
    bool handleModifySkillCommand(uint skill, uint points = 1)
    {
        blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, points));
        auto target = selectedCharacter(true);
        if (target is null)
            target = this;
        gmLog(format!"used modify skill of %u %u on %s"(skill, points, target.player.data.name));
        const current = target.player.skillValue(skill);
        if (current[1] == 0)
        {
            systemMessage("The player does not know this skill. Adding it now.");
            target.applySkill(skill, 1, 300);
        }
        else
            target.applySkill(skill, cast(ushort) min(current[0] + points, current[1]), current[1]);
        return true;
    }

    /// The name of a skill (from SkillLine.dbc), or null.
    string skillName(uint skill)
    {
        const line = context.client.skillLines.lookup(skill);
        return line is null ? null : line.name[0];
    }

    /// `.character getskillinfo`: the selected player's skills with their values and caps.
    bool handleGetSkillsInfoCommand()
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return false;
        blueSystemMessage(format!"Player: %s has skills"(target.player.data.name));
        foreach (skill; target.player.skillList)
        {
            const name = skillName(skill[0]);
            if (name is null)
                redSystemMessage(format!"Invalid skill: %u"(skill[0]));
            else
                blueSystemMessage(format!"  %s: Value: %u, MaxValue: %u. (+ %d bonus)"(name, skill[1], skill[2], 0));
        }
        return true;
    }

    /// `.character removeskill <skill>`: a skill line the selected player has, removed.
    bool handleRemoveSkillCommand(uint skill)
    {
        blueSystemMessage(format!"Removing skill line %d"(skill));
        auto target = selectedCharacter(true);
        if (target is null || target.player.skillValue(skill)[1] == 0)
        {
            redSystemMessage(format!"Player doesn't have skill line %d"(skill));
            return true;
        }
        target.applySkill(skill, 0, 0);
        gmLog(format!"used remove skill of %u on %s"(skill, target.player.data.name));
        target.systemMessage(format!"%s removed skill line %d from you. "(player.data.name, skill));
        return true;
    }

    /// `.npc emote [emote]`: the selected creature's emote state.
    bool handleEmoteCommand(uint emote = 0)
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return false;
        creature.values.set!UNIT_NPC_EMOTESTATE(emote);
        map.flushObjectChanges(creature);
        return true;
    }

    /// `.modify gold <copper>`: money added to or taken from the selected player, down to none.
    bool handleModifyGoldCommand(int total)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        const magnitude = total < 0 ? -long(total) : long(total);
        const gold = cast(uint) floor(magnitude / 10_000.0f);
        const silver = cast(uint) floor(magnitude / 100.0f) % 100;
        const copper = cast(uint)(magnitude % 100);
        const name = target.player.data.name;
        gmLog(format!"used modify gold on %s, gold: %d"(name, total));
        long newGold = long(target.player.values.get!PLAYER_FIELD_COINAGE) + total;
        if (newGold < 0)
        {
            greenSystemMessage(format!"Taking all gold from %s's backpack..."(name));
            target.greenSystemMessage(format!"%s took the all gold from your backpack."(player.data.name));
            newGold = 0;
        }
        else if (total >= 0)
        {
            greenSystemMessage(format!"Adding %u gold, %u silver, %u copper to %s's backpack..."(gold, silver,
                copper, name));
            target.greenSystemMessage(format!"%s added %u gold, %u silver, %u copper to your backpack."(
                player.data.name, gold, silver, copper));
        }
        else
        {
            greenSystemMessage(format!"Taking %u gold, %u silver, %u copper from %s's backpack..."(gold, silver,
                copper, name));
            target.greenSystemMessage(format!"%s took %u gold, %u silver, %u copper from your backpack."(
                player.data.name, gold, silver, copper));
        }
        target.player.values.set!PLAYER_FIELD_COINAGE(cast(uint) min(newGold, uint.max));
        target.flushPlayerChanges();
        return true;
    }

    /// `.gotrig <trigger> [instance]`: the GM teleported to an area trigger (the instance is not used).
    bool handleTriggerCommand(uint triggerId, int instanceId = 0)
    {
        const entry = triggerId == 0 ? null : context.client.areaTriggers.lookup(triggerId);
        if (entry is null)
        {
            redSystemMessage(format!"Could not find trigger %s"(triggerId));
            return true;
        }
        commandTeleport(entry.mapId, Position(entry.x, entry.y, entry.z, 0));
        greenSystemMessage(format!"Teleported to trigger %u on [%u][%.2f][%.2f][%.2f]"(entry.id, entry.mapId,
            entry.x, entry.y, entry.z));
        return true;
    }

    /// `.character unlearn <spell>`: a spell the selected player knows, removed.
    bool handleUnlearnCommand(uint spellId = 0)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        if (spellId == 0)
        {
            redSystemMessage("You must specify a spell id.");
            return true;
        }
        gmLog(format!"removed spell %u from %s"(spellId, target.player.data.name));
        if (!target.player.knowsSpell(spellId))
        {
            redSystemMessage(format!"The player does not know spell %u."(spellId));
            return true;
        }
        target.greenSystemMessage(format!"Removed spell %u."(spellId));
        greenSystemMessage(format!"Removed spell %u from %s."(spellId, target.player.data.name));
        target.unlearn(spellId);
        return true;
    }
}
