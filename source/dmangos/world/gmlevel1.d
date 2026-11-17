/**
 * ArcEmu's `Level1.cpp` handlers: announcements, `.gm on` and `.gm off`, `.gps`,
 * `.kickplayer`, `.character additem`, `.summon`, `.appear`, `.modify speed`
 * and `.modify gold`, the skill commands, `.npc emote`, `.gotrig` and
 * `.character unlearn`. Mixed into `dmangos.world.session.WorldSession`.
 */
module dmangos.world.gmlevel1;

import dmangos.world.commands;

/// ArcEmu's `World::AnnounceColorChooser`: the colour of an `announce_*_color` number.
string announceColor(uint number) pure nothrow @safe @nogc
{
    static immutable string[11] colors = ["", MSG_COLOR_LIGHTRED, MSG_COLOR_LIGHTBLUE, MSG_COLOR_BLUE, MSG_COLOR_GREEN,
        MSG_COLOR_RED, MSG_COLOR_GOLD, MSG_COLOR_GREY, MSG_COLOR_WHITE, MSG_COLOR_MAGENTA, MSG_COLOR_YELLOW];
    return number < colors.length ? colors[number] : "";
}

/// The client's colour for an item quality (ArcEmu's `GetItemLinkByProto`).
string itemQualityColor(uint quality) pure nothrow @safe @nogc
{
    static immutable string[7] colors = ["|cff9d9d9d", "|cffffffff", "|cff1eff00", "|cff0070dd", "|cffa335ee",
        "|cffff8000", "|cffe6cc80"];
    return quality < colors.length ? colors[quality] : colors[1];
}

unittest
{
    assert(announceColor(1) == "|cffff6060" && announceColor(10) == "|cffffff00");
    assert(announceColor(0) == "" && announceColor(11) == "");
}

/// See the module documentation.
mixin template Level1Commands()
{
    import std.algorithm.comparison : min;
    import std.format : format;
    import std.math : floor;
    import dmangos.world.commands;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.names : normalizedName;
    import dmangos.world.gmlevel1 : announceColor, itemQualityColor;
    import dmangos.world.movement : Position;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.updatefields;

private:
    /// A chat link to an item, as ArcEmu's `GetItemLinkByProto` makes one (in 1.12's link format).
    string itemLink(uint entry)
    {
        const item = entry in context.data.items;
        return format!"%s|Hitem:%u:0:0:0|h[%s]|h|r"(itemQualityColor(item.details.quality), entry, item.details.name);
    }

    /// The `[Staff]<GM>` start that `.announce` and `.wannounce` share.
    string announceStart()
    {
        const config = context.config;
        string text = announceColor(config.announceTagColor) ~ "[" ~ config.announceTag ~ "]"
            ~ announceColor(config.announceGmTagColor);
        if (config.announceGmAdminTag)
        {
            if (canUseCommand('z'))
                text ~= "<Admin>";
            else if (hasPermissions)
                text ~= "<GM>";
        }
        return text;
    }

    bool handleAnnounceCommand(Rest message = Rest.init)
    {
        import std.algorithm.searching : canFind;

        if (message.length < 4 || message.canFind('%'))
        {
            systemMessage("Announces cannot contain the % character and must be at least 4 characters.");
            return true;
        }
        const config = context.config;
        string text = announceStart();
        if (config.nameInAnnounce)
            text ~= "|r" ~ announceColor(config.announceNameColor) ~ "|Hplayer:" ~ player.data.name ~ "|h["
                ~ player.data.name ~ "]|h:|r " ~ announceColor(config.announceMessageColor);
        else
            text ~= ": " ~ announceColor(config.announceMessageColor);
        sendWorldText(text ~ message);
        gmLog(format!"used announce command, [%s]"(message));
        return true;
    }

    bool handleGMAnnounceCommand(Rest message)
    {
        sendGMWorldText(format!(MSG_COLOR_RED ~ "[Team]" ~ MSG_COLOR_GREEN ~ " |Hplayer:%s|h[%s]|h:" ~ MSG_COLOR_YELLOW
            ~ " %s")(player.data.name, player.data.name, message));
        gmLog(format!"used team announce command, [%s]"(message));
        return true;
    }

    bool handleWAnnounceCommand(Rest message)
    {
        const config = context.config;
        string text = announceStart();
        if (config.nameInWAnnounce)
            text ~= "|r" ~ announceColor(config.announceNameColor) ~ "[" ~ player.data.name ~ "]:|r "
                ~ announceColor(config.announceMessageColor);
        else
            text ~= ": " ~ announceColor(config.announceMessageColor);
        sendWorldWideScreenText(text ~ message);
        gmLog(format!"used wannounce command [%s]"(message));
        return true;
    }

    bool handleGMOnCommand()
    {
        greenSystemMessage("Setting GM Flag on yourself...");
        if (player.gmTagOn)
            redSystemMessage("GM Flag is already set on. Use !gm off to disable it.");
        else
        {
            player.gmTagOn = true;
            player.setFlag(PlayerFlags.gm, true); // <GM>
            flushPlayerChanges();
            blueSystemMessage("GM Flag Set. It will appear above your name and in chat messages until you use "
                ~ "!gm off.");
        }
        return true;
    }

    bool handleGMOffCommand()
    {
        greenSystemMessage("Unsetting GM Flag on yourself...");
        if (!player.gmTagOn)
            redSystemMessage("GM Flag not set. Use !gm on to enable it.");
        else
        {
            player.gmTagOn = false;
            player.setFlag(PlayerFlags.gm, false);
            flushPlayerChanges();
            blueSystemMessage("GM Flag Removed. <GM> Will no longer show in chat messages or above your name.");
        }
        return true;
    }

    bool handleGPSCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        Position at = player.position;
        uint mapId = player.data.map, zone = player.data.zone;
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
                systemMessage("You should select a character or a creature.");
                return true;
            }
        }
        systemMessage(format!("|cff00ff00Current Position: |cffffffffMap: |cff00ff00%d |cffffffffZone: |cff00ff00%u "
            ~ "|cffffffffX: |cff00ff00%f |cffffffffY: |cff00ff00%f |cffffffffZ: |cff00ff00%f |cffffffffOrientation: "
            ~ "|cff00ff00%f|r")(mapId, zone, at.x, at.y, at.z, at.orientation));
        return true;
    }

    bool handleKickCommand(string name, Rest kickReason = Rest("No reason"))
    {
        auto found = context.onlinePlayer(name);
        if (found is null)
        {
            if (const remote = context.remotePlayer(name))
                if (gmElsewhere(name, GmRemoteOp.kick, kickReason))
                {
                    gmLog(format!"Kicked player %s from the server for %s"(remote.entry.name, kickReason));
                    return true;
                }
            redSystemMessage("Player is not online at the moment.");
            return true;
        }
        auto chr = sessionOf(found);
        gmLog(format!"Kicked player %s from the server for %s"(chr.player.data.name, kickReason));
        chr.kickedBy(gmSink, player.data.name, canUseCommand('z'), kickReason);
        return true;
    }

    bool handleAddInvItemCommand(uint itemId, uint count = 1, int randomProperty = 0)
    {
        auto chr = getSelectedChar(false);
        if (chr is null)
            chr = this;
        const item = itemId in context.data.items;
        if (item is null)
        {
            redSystemMessage(format!"Item %d is not a valid item!"(itemId));
            return true;
        }
        gmLog(format!"used add item command, item id %u [%s] to %s"(itemId, item.details.name, chr.player.data.name));
        // ArcEmu makes one item of `min(count, MaxCount)`; this gives `count`, in as many stacks as it takes.
        if (chr.giveItem(itemId, count == 0 ? 1 : count) == 0)
        {
            sendNotification("No free slots were found in your inventory!");
            return true;
        }
        systemMessage(format!"Adding item %s (id: %d) to %s's inventory."(itemLink(itemId), itemId,
            chr.player.data.name));
        chr.systemMessage(format!"%s added item %s to your inventory."(player.data.name, itemLink(itemId)));
        return true;
    }

    bool handleSummonCommand(Rest name)
    {
        const p = player.position;
        gmLog(format!"summoned %s on map %u, %f %f %f"(name, player.data.map, p.x, p.y, p.z));
        if (auto found = context.onlinePlayer(name))
            sessionOf(found).summonedBy(gmSink, player.data.name, player.data.map, p, instanceId_);
        else if (gmElsewhere(name, GmRemoteOp.summon))
        {
        }
        else
        {
            const guid = context.database.characterGuid(normalizedName(name));
            if (guid == 0)
                systemMessage(format!"Player (%s) does not exist."(name));
            else
            {
                context.database.moveOfflineCharacter(guid, player.data.map, p.x, p.y, p.z, player.data.zone);
                const info = context.database.nameInfo(guid);
                systemMessage(format!"(Offline) %s has been summoned."(info.isNull ? name : info.get.name));
            }
        }
        return true;
    }

    bool handleAppearCommand(Rest name)
    {
        auto found = context.onlinePlayer(name);
        if (found is null)
        {
            if (!gmElsewhere(name, GmRemoteOp.appear))
                systemMessage(format!"Player (%s) does not exist or is not logged in."(name));
            return true;
        }
        sessionOf(found).appearedToBy(gmSink, player.data.name,
            (uint map, Position at, uint instance) { commandTeleport(map, at, instance); });
        return true;
    }

    bool handleModifySpeedCommand(float speed)
    {
        if (speed > 255 || speed < 1)
        {
            redSystemMessage("Incorrect value. Range is 1..255");
            return true;
        }
        auto chr = getSelectedChar(true);
        if (chr is null)
            return true;
        if (chr !is this)
            gmLog(format!"modified speed of %s to %2.2f."(chr.player.data.name, speed));
        blueSystemMessage(format!"You set the speed of %s to %2.2f."(chr.player.data.name, speed));
        chr.systemMessage(format!"%s set your speed to %2.2f."(player.data.name, speed));
        chr.applySpeed(speed);
        return true;
    }

    bool handleLearnSkillCommand(uint skill, uint min_, uint max_ = 1)
    {
        blueSystemMessage(format!"Adding skill line %d"(skill));
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        gmLog(format!"used add skill of %u %u %u on %s"(skill, min_, max_, plr.player.data.name));
        // `_AddSkillLine`: a maximum below the value is raised to it.
        if (max_ < min_)
            max_ = min_;
        plr.applySkill(skill, cast(ushort) min(min_, ushort.max), cast(ushort) min(max_, ushort.max));
        return true;
    }

    bool handleModifySkillCommand(uint skill, uint cnt = 1)
    {
        blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, cnt));
        auto plr = getSelectedChar(true);
        if (plr is null)
            plr = this;
        gmLog(format!"used modify skill of %u %u on %s"(skill, cnt, plr.player.data.name));
        const now = plr.player.skillValue(skill);
        if (now[1] == 0)
        {
            systemMessage("Does not have skill line, adding.");
            plr.applySkill(skill, 1, 300);
        }
        else // `_AdvanceSkillLine`: up to the maximum
            plr.applySkill(skill, cast(ushort) min(now[0] + cnt, now[1]), now[1]);
        return true;
    }

    /// The name of a skill (ArcEmu's `SkillNameMgr`, from SkillLine.dbc), or null.
    string skillName(uint skill)
    {
        const line = context.client.skillLines.lookup(skill);
        return line is null ? null : line.name[0];
    }

    bool handleGetSkillsInfoCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        blueSystemMessage(format!"Player: %s has skills"(plr.player.data.name));
        foreach (skill; plr.player.skillList)
        {
            const name = skillName(skill[0]);
            if (name is null)
            {
                redSystemMessage(format!"Invalid skill: %u"(skill[0]));
                continue;
            }
            blueSystemMessage(format!"  %s: Value: %u, MaxValue: %u. (+ %d bonus)"(name, skill[1], skill[2], 0));
        }
        return true;
    }

    bool handleRemoveSkillCommand(uint skill)
    {
        blueSystemMessage(format!"Removing skill line %d"(skill));
        auto plr = getSelectedChar(true);
        if (plr !is null && plr.player.skillValue(skill)[1] != 0)
        {
            plr.applySkill(skill, 0, 0);
            gmLog(format!"used remove skill of %u on %s"(skill, plr.player.data.name));
            plr.systemMessage(format!"%s removed skill line %d from you. "(player.data.name, skill));
        }
        else
            blueSystemMessage(format!"Player doesn't have skill line %d"(skill));
        return true;
    }

    bool handleEmoteCommand(uint emote = 0)
    {
        auto target = getSelectedCreature(true);
        if (target is null)
            return false;
        target.values.set!UNIT_NPC_EMOTESTATE(emote);
        map.flushObjectChanges(target);
        return true;
    }

    bool handleModifyGoldCommand(int total)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
            return true;
        const magnitude = total < 0 ? -long(total) : long(total);
        const gold = cast(uint) floor(magnitude / 10_000.0f);
        const silver = cast(uint) floor(magnitude / 100.0f) % 100;
        const copper = cast(uint)(magnitude % 100);
        gmLog(format!"used modify gold on %s, gold: %d"(chr.player.data.name, total));
        long newGold = long(chr.player.values.get!PLAYER_FIELD_COINAGE) + total;
        const name = chr.player.data.name;
        if (newGold < 0)
        {
            blueSystemMessage(format!"Taking all gold from %s's backpack..."(name));
            chr.greenSystemMessage(format!"%s took the all gold from your backpack."(player.data.name));
            newGold = 0;
        }
        else if (total >= 0)
        {
            blueSystemMessage(format!"Adding %u gold, %u silver, %u copper to %s's backpack..."(gold, silver, copper,
                name));
            chr.greenSystemMessage(format!"%s added %u gold, %u silver, %u copper to your backpack."(player.data.name,
                gold, silver, copper));
        }
        else
        {
            blueSystemMessage(format!"Taking %u gold, %u silver, %u copper from %s's backpack..."(gold, silver, copper,
                name));
            chr.greenSystemMessage(format!"%s took %u gold, %u silver, %u copper from your backpack."(player.data.name,
                gold, silver, copper));
        }
        chr.player.values.set!PLAYER_FIELD_COINAGE(cast(uint) min(newGold, uint.max));
        chr.flushPlayerChanges();
        return true;
    }

    bool handleTriggerCommand(uint triggerId, int instanceId = 0)
    {
        const entry = triggerId == 0 ? null : context.client.areaTriggers.lookup(triggerId);
        if (entry is null)
        {
            redSystemMessage(format!"Could not find trigger %s"(triggerId));
            return true;
        }
        commandTeleport(entry.mapId, Position(entry.x, entry.y, entry.z, 0));
        blueSystemMessage(format!"Teleported to trigger %u on [%u][%.2f][%.2f][%.2f]"(entry.id, entry.mapId, entry.x,
            entry.y, entry.z));
        return true;
    }

    bool handleUnlearnCommand(uint spellId = 0)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        if (spellId == 0)
        {
            redSystemMessage("You must specify a spell id.");
            return true;
        }
        gmLog(format!"removed spell %u from %s"(spellId, plr.player.data.name));
        if (plr.player.knowsSpell(spellId))
        {
            plr.greenSystemMessage(format!"Removed spell %u."(spellId));
            greenSystemMessage(format!"Removed spell %u from %s."(spellId, plr.player.data.name));
            plr.unlearn(spellId);
        }
        else
            redSystemMessage(format!"That player does not have spell %u learnt."(spellId));
        return true;
    }
}
