/**
 * Handlers for a character in the world: logging out (`MiscHandler.cpp`),
 * movement (`MovementHandler.cpp`), queries (`QueryHandler.cpp`,
 * `ItemHandler.cpp`), the character's own settings, and chat
 * (`ChatHandler.cpp`).
 *
 * `InWorldHandlers` is mixed into `dmangos.world.session.WorldSession`, like
 * `dmangos.world.charscreen.CharacterScreenHandlers`.
 *
 * Movement is shown to those who see the player (`dmangos.world.map`) and
 * checked against the player's speed. Chat reaches those in range, the
 * group, a channel or one player, depending on its type; a message starting
 * with `.` may be a command (`dmangos.world.commands`).
 */
module dmangos.world.inworld;

/// See the module documentation.
mixin template InWorldHandlers()
{
    import std.datetime.systime : Clock;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteWriter;
    import dmangos.log;
    import dmangos.world.map : packetBody;
    import dmangos.world.defines : maxActionButtons;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.movement : baseMoveSpeed, MovementFlags, MovementInfo, MoveType, movingOrTurning, Position;
    import core.time : Duration;
    import dmangos.world.player : PlayerFlags, RestType;
    import dmangos.world.teleport : Teleport;
    import dmangos.world.objects : lowGuid, putPackedGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.queries : chatMessage, ClientChat, creatureQueryResponse, gameObjectQueryResponse,
        itemQueryResponse;
    import dmangos.world.updatefields : PLAYER_FIELD_BYTES, UNIT_FIELD_BYTES_1;

    enum ubyte standStateStand = 0;
    import dmangos.world.worlddata : CreateAction;

private:
    /**
     * `WorldSession::LogoutPlayer`: saves the character and leaves the world, its channels and
     * (logging out normally, from a party) its group. `loggingOut` is false for a lost connection.
     */
    void leaveWorld(string why, bool loggingOut)
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        context.database.setOnline(player.data.guid, account.id, false, context.config.realmId);
        info!"%s: '%s' left the world (%s); '%s' saved at map %s %.1f %.1f %.1f"(remoteAddress, account.username,
            why, player.data.name, progress.map, progress.position.x, progress.position.y, progress.position.z);
        leaveGroupsOnLogout(loggingOut);
        context.channelsFor(this).leaveAll(this);
        auto group = context.groups.of(player.guid);
        context.leaveWorld(this);
        if (group !is null)
            group.updatePlayerOnlineStatus(this, false); // the others see the player offline
        player = null;
        loggingOut = false;
        teleporting = Teleport.none;
        gameMaster = false;
        state_ = WorldState.characterScreen;
    }

    /**
     * `WorldSession::HandleLogoutRequestOpcode`: not while jumping or falling; at once when resting
     * or for accounts of `instant_logout`'s level; otherwise sitting, stunned, for 20 seconds.
     */
    @Handles(Opcode.CMSG_LOGOUT_REQUEST, WorldState.inWorld)
    void handleLogoutRequest()
    {
        const cantLogout = player.movement.has(MovementFlags.jumping) || player.movement.has(MovementFlags.fallingFar);
        const instant = player.hasFlag(PlayerFlags.resting) || account.level >= context.config.instantLogout;
        send(ServerLogoutResponse(cantLogout ? 1 : 0, instant && !cantLogout ? 1 : 0));
        if (cantLogout)
            return;
        if (instant)
            return completeLogout();
        logoutRequestedAt = context.clock();
        loggingOut = true;
        player.setLogoutStun(true);
        send(ServerMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)(player.guid, moveOrderCounter++));
        flushPlayerChanges();
    }

    @Handles(Opcode.CMSG_LOGOUT_CANCEL, WorldState.inWorld)
    void handleLogoutCancel()
    {
        send(ServerLogoutCancelAck());
        if (!loggingOut)
            return;
        loggingOut = false;
        player.setLogoutStun(false);
        send(ServerMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)(player.guid, moveOrderCounter++));
        flushPlayerChanges();
    }

    /// The end of a logout: saved, out of the world, and back on the character screen.
    void completeLogout()
    {
        loggingOut = false;
        leaveWorld("logged out", true);
        send(ServerLogoutComplete());
    }

    /**
     * One tick (`WorldSession::Update`, `Player::Update`): the logout countdown, regeneration every
     * two seconds, rest, and the periodic save.
     */
    void updateInWorld(Duration elapsed)
    {
        import core.time : seconds;
        import std.datetime.systime : Clock;

        if (loggingOut && context.clock() - logoutRequestedAt >= 20.seconds)
            return completeLogout();
        if (transferring)
            return;
        const config = context.config;

        if (regenTimer.update(elapsed))
        {
            const ms = cast(uint) regenTimer.takeAll().total!"msecs";
            if (player.regenerate(ms, config.rateHealth, config.rateMana, config.rateRageLoss, config.rateEnergy))
            {
                flushPlayerChanges();
                if (auto group = context.groups.of(player.guid))
                    group.updatePlayerOutOfRange(this, GroupUpdate.currentHealth | GroupUpdate.currentPower);
            }
        }

        if (restTimer.update(elapsed) && restTimer.consume())
        {
            const now = context.unixTime;
            // Player::Update: leaving the inn ends the rest.
            if (player.restType == RestType.tavern)
            {
                const inn = context.client.areaTriggers.lookup(player.innTrigger);
                const p = player.position;
                if (inn is null || !inn.contains(player.data.map, p.x, p.y, p.z, 0))
                {
                    player.setRestType(RestType.none, now);
                    flushPlayerChanges();
                }
            }
            // Rested XP, counted in steps of 10 seconds as CMaNGOS does.
            if (player.restType != RestType.none && now - player.restCountedAt >= 10)
            {
                player.setRestBonus(player.restBonus + player.computeRest(now - player.restCountedAt,
                    config.rateRestInGame), config.maxPlayerLevel);
                player.restCountedAt = now;
                flushPlayerChanges();
            }
        }

        // A save starts the interval again (SaveToDB resets m_nextSave): no catching up after a stall.
        if (saveTimer.update(elapsed))
            savePlayer();
    }

    /// `Player::UpdateZone`'s rest: a capital (AREA_FLAG_CAPITAL) rests; leaving it does not.
    void updateCityRest()
    {
        import std.datetime.systime : Clock;

        enum uint areaFlagCapital = 0x100;
        const zone = context.client.areas.lookup(player.data.zone);
        const now = context.unixTime;
        if (zone !is null && (zone.flags & areaFlagCapital))
        {
            if (player.restType != RestType.city)
                player.setRestType(RestType.city, now);
        }
        else if (player.restType == RestType.city)
            player.setRestType(RestType.none, now);
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Movement (MovementHandler.cpp)
    // -----------------------------------------------------------------------

    @Handles(movementOpcodes, WorldState.inWorld)
    void handleMovement(const MovementInfo movement, Opcode opcode)
    {
        // WorldSession::VerifyMovementInfo: a position the client cannot be at.
        const p = movement.position;
        if (!context.client.isValidMapCoord(player.data.map, p.x, p.y, p.z, p.orientation))
        {
            warning!"%s: '%s' sent an invalid position; disconnecting"(remoteAddress, player.data.name);
            return disconnect();
        }
        // Until the client confirms a teleport, its movement packets are from before it; a player
        // logging out is rooted.
        if (teleporting != Teleport.none || loggingOut)
            return;
        // On a transport the position is relative to it; without transports, keep the last world position.
        if (movement.has(MovementFlags.onTransport))
            return;
        if (!passesSpeedCheck(p))
            return;
        player.movement = movement;

        // HandleMovementOpcodes: moving stands the player up and ends a looping emote.
        if (movement.flags & movingOrTurning)
        {
            if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != standStateStand)
                player.setStandState(standStateStand);
            player.setEmoteState(0);
            flushPlayerChanges();
        }

        // Those who see the player see it move: the same opcode, with the mover's guid and the server's time.
        ByteWriter relay;
        putPackedGuid(relay, player.guid);
        MovementInfo relayed = movement;
        relayed.time = serverTime();
        relayed.write(relay);
        map.sendToWatchers(this, opcode, relay.data);
        map.relocated(this);

        // Group members who do not see the player follow it on their map.
        if (distance2d(groupPositionAt, p) >= context.config.visibilityRelocationLimit)
            if (auto group = context.groups.of(player.guid))
            {
                groupPositionAt = p;
                group.updatePlayerOutOfRange(this, GroupUpdate.position);
            }
    }

    /**
     * Whether the player can have got to `position` since the last checkpoint, running (the fastest
     * it can move without spells or mounts), give or take the configured tolerance. A player that
     * could not is put back at the checkpoint. The checkpoint moves on every two seconds.
     */
    bool passesSpeedCheck(Position position)
    {
        import core.time : seconds;
        import std.algorithm.comparison : max;

        if (!context.config.movementSpeedCheck || gameMaster || account.level > AccountLevel.player)
            return true;
        const now = context.clock();
        const elapsed = (now - checkpointTime).total!"msecs" / 1000.0;
        const fastest = max(baseMoveSpeed[MoveType.run], baseMoveSpeed[MoveType.swim]);
        const allowed = fastest * context.config.movementSpeedTolerance * elapsed + context.config.movementSpeedSlack;
        const moved = distance2d(checkpoint, position);
        if (moved > allowed)
        {
            warning!"%s: '%s' moved %.1f yards in %.1f seconds (at most %.1f allowed); put back"(remoteAddress,
                player.data.name, moved, elapsed, allowed);
            teleportTo(player.data.map, checkpoint);
            return false;
        }
        if (now - checkpointTime >= 2.seconds)
        {
            checkpoint = position;
            checkpointTime = now;
        }
        return true;
    }

    /// Starts the movement check afresh at the player's position: at login and after teleports.
    void resetMovementCheck()
    {
        checkpoint = player.position;
        checkpointTime = context.clock();
        groupPositionAt = player.position;
    }

    static float distance2d(Position a, Position b)
    {
        import std.math : sqrt;

        return sqrt((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2);
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_NAME_QUERY, WorldState.inWorld)
    void handleNameQuery(const ClientNameQuery request)
    {
        if (const other = context.onlinePlayer(request.guid))
        {
            const c = other.character;
            return send(ServerNameQueryResponse(c.guid, c.data.name, "", c.data.race, c.data.gender, c.data.classId));
        }
        if (request.guid >> 48 != 0) // only players have names
            return;
        const found = context.database.nameInfo(lowGuid(request.guid));
        if (!found.isNull)
            send(ServerNameQueryResponse(request.guid, found.get.name, "", found.get.race, found.get.gender,
                found.get.classId));
    }

    @Handles(Opcode.CMSG_ITEM_QUERY_SINGLE, WorldState.inWorld)
    void handleItemQuery(const ClientItemQuerySingle request)
    {
        send(ServerItemQueryResponse(itemQueryResponse(request.entry, request.entry in context.data.items,
            context.data.spells)));
    }

    @Handles(Opcode.CMSG_CREATURE_QUERY, WorldState.inWorld)
    void handleCreatureQuery(const ClientObjectQuery request)
    {
        send(ServerCreatureQueryResponse(creatureQueryResponse(request.entry,
            request.entry in context.data.creatureTemplates)));
    }

    @Handles(Opcode.CMSG_GAMEOBJECT_QUERY, WorldState.inWorld)
    void handleGameObjectQuery(const ClientObjectQuery request)
    {
        send(ServerGameObjectQueryResponse(gameObjectQueryResponse(request.entry,
            request.entry in context.data.gameObjectTemplates)));
    }

    @Handles(Opcode.CMSG_QUERY_TIME, WorldState.inWorld)
    void handleQueryTime()
    {
        send(ServerQueryTimeResponse(cast(uint) context.unixTime));
    }

    @Handles(Opcode.CMSG_PLAYED_TIME, WorldState.inWorld)
    void handlePlayedTime()
    {
        const progress = player.progress(secondsInWorld());
        send(ServerPlayedTime(progress.totalTime, progress.levelTime));
    }

    // -----------------------------------------------------------------------
    // The character's own state
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_STANDSTATECHANGE, WorldState.inWorld)
    void handleStandStateChange(const ClientStandStateChange request)
    {
        enum : uint { stand = 0, sit = 1, sleep = 3, kneel = 8 }
        if (request.state != stand && request.state != sit && request.state != sleep && request.state != kneel)
            return;
        player.setStandState(cast(ubyte) request.state);
        flushPlayerChanges();
        send(ServerStandStateUpdate(cast(ubyte) request.state));
    }

    @Handles(Opcode.CMSG_SET_ACTION_BUTTON, WorldState.inWorld)
    void handleSetActionButton(const ClientSetActionButton request)
    {
        if (request.button >= maxActionButtons)
            return;
        const action = request.packed & 0x00FF_FFFF;
        const type = cast(ubyte)(request.packed >> 24);
        if (request.packed != 0 && !context.data.isActionButtonDataValid(CreateAction(request.button, action, type)))
        {
            warning!"%s: '%s' tried to put invalid action %s (type %s) on button %s"(remoteAddress,
                player.data.name, action, type, request.button);
            return;
        }
        player.actionButtons[request.button] = request.packed;
        context.database.setActionButton(player.data.guid, request.button, action, type);
    }

    @Handles(Opcode.CMSG_SET_ACTIONBAR_TOGGLES, WorldState.inWorld)
    void handleSetActionBarToggles(const ClientSetActionBarToggles request)
    {
        player.values.setByte!PLAYER_FIELD_BYTES(2, request.toggles);
        player.values.clearChanges(); // the client already shows it
    }

    @Handles(Opcode.CMSG_TUTORIAL_FLAG, WorldState.inWorld)
    void handleTutorialFlag(const ClientTutorialFlag request)
    {
        if (request.flag >= 32 * player.data.tutorials.length)
            return;
        player.data.tutorials[request.flag / 32] |= 1u << (request.flag % 32);
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    /// Marks every tutorial as seen.
    @Handles(Opcode.CMSG_TUTORIAL_CLEAR, WorldState.inWorld)
    void handleTutorialClear()
    {
        player.data.tutorials[] = uint.max;
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    /// Shows every tutorial again.
    @Handles(Opcode.CMSG_TUTORIAL_RESET, WorldState.inWorld)
    void handleTutorialReset()
    {
        player.data.tutorials[] = 0;
        context.database.saveTutorials(account.id, player.data.tutorials);
    }

    @Handles(Opcode.CMSG_SET_SELECTION, WorldState.inWorld)
    void handleSetSelection(const ClientSetSelection request)
    {
        player.setTarget(request.guid); // others see whom the player has targeted
        flushPlayerChanges();
    }

    /// `Player::UpdateZone`: world states, zone channels, and the group's zone of the player.
    @Handles(Opcode.CMSG_ZONEUPDATE, WorldState.inWorld)
    void handleZoneUpdate(const ClientZoneUpdate request)
    {
        if (request.zone == player.data.zone)
            return;
        player.data.zone = request.zone;
        send(ServerInitWorldStates(player.data.map, request.zone));
        updateCityRest();
        context.channelsFor(this).zoneChanged(this, context.client.areaName(request.zone));
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.zone);
    }

    // -----------------------------------------------------------------------
    // Chat (ChatHandler.cpp)
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_MESSAGECHAT, WorldState.inWorld)
    void handleMessageChat(const ClientChat chat)
    {
        if (chat.language == Language.LANG_ADDON)
            return; // `AddonChannel` is off
        // Game masters, and with shared chat everyone, are understood by all (HandleMessagechatOpcode).
        Language language = chat.language;
        const config = context.config;
        if (gameMaster || config.allowTwoSideInteractionChat)
            language = Language.LANG_UNIVERSAL;
        else if (config.allowTwoSideInteractionGroup && (chat.type == ChatType.CHAT_MSG_PARTY
            || chat.type == ChatType.CHAT_MSG_RAID || chat.type == ChatType.CHAT_MSG_RAID_LEADER
            || chat.type == ChatType.CHAT_MSG_RAID_WARNING))
            language = Language.LANG_UNIVERSAL;

        if (chat.type == ChatType.CHAT_MSG_AFK || chat.type == ChatType.CHAT_MSG_DND)
            return setAway(chat.type, chat.text);
        if (chat.text.length == 0)
            return;
        // `.account mute` (WorldSession::m_muteTime): no chat until then, commands included.
        const now = context.unixTime;
        if (account.muteTime > now)
            return sendNotification(format!"Your chat is disabled for %s more seconds."(account.muteTime - now));
        switch (chat.type)
        {
        case ChatType.CHAT_MSG_SAY, ChatType.CHAT_MSG_YELL, ChatType.CHAT_MSG_EMOTE, ChatType.CHAT_MSG_WHISPER,
            ChatType.CHAT_MSG_PARTY, ChatType.CHAT_MSG_RAID, ChatType.CHAT_MSG_RAID_LEADER:
            if (runCommand(chat.text))
                return;
            break;
        default:
            break;
        }

        switch (chat.type)
        {
        case ChatType.CHAT_MSG_SAY:
            sayAround(chat.type, language, chat.text, config.listenRangeSay);
            break;
        case ChatType.CHAT_MSG_YELL:
            sayAround(chat.type, language, chat.text, config.listenRangeYell);
            break;
        case ChatType.CHAT_MSG_EMOTE:
            sayAround(chat.type, Language.LANG_UNIVERSAL, chat.text, config.listenRangeTextEmote);
            break;
        case ChatType.CHAT_MSG_WHISPER:
            whisper(chat.target, chat.text);
            break;
        case ChatType.CHAT_MSG_PARTY:
            if (auto group = context.groups.of(player.guid))
                group.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                    player.chatTag), group.subGroupOf(player.guid));
            break;
        case ChatType.CHAT_MSG_RAID:
        case ChatType.CHAT_MSG_RAID_LEADER:
            auto raid = context.groups.of(player.guid);
            if (raid is null || !raid.isRaid || chat.type == ChatType.CHAT_MSG_RAID_LEADER && !raid.isLeader(player.guid))
                break;
            raid.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                player.chatTag));
            break;
        case ChatType.CHAT_MSG_RAID_WARNING:
            auto group = context.groups.of(player.guid);
            if (group is null)
                break;
            if (group.isRaid ? !group.isLeader(player.guid) && !group.isAssistant(player.guid)
                : config.chatRestrictedRaidWarnings)
                break;
            group.broadcast(Opcode.SMSG_MESSAGECHAT, chatMessage(chat.type, language, player.guid, chat.text,
                player.chatTag));
            break;
        case ChatType.CHAT_MSG_CHANNEL:
            if (auto channel = context.channelsFor(this).find(chat.channel, this))
                channel.say(this, chat.text, language, player.chatTag);
            break;
        default:
            trace!"%s: chat type %s is not supported yet"(remoteAddress, chat.type);
            break;
        }
    }

    /// Everyone within `range` yards hears it, the speaker included (`Player::Say`, `Yell`, `TextEmote`).
    void sayAround(ChatType type, Language language, string text, float range)
    {
        if (teleporting == Teleport.far)
            return;
        map.sendInRange(player.position, range, Opcode.SMSG_MESSAGECHAT,
            chatMessage(type, language, player.guid, text, player.chatTag));
    }

    /**
     * `HandleMessagechatOpcode`'s whisper case and `Player::Whisper`: anyone online, of the same
     * faction unless one of the two is a game master; an away or busy player's message comes back.
     */
    void whisper(string to, string text)
    {
        auto target = context.onlinePlayer(to);
        // A game master blocking whispers looks offline to players (Player::isAcceptWhispers).
        if (target is null || target.security > AccountLevel.player && !sessionOf(target).acceptsWhisperFrom(this))
            return send(ServerChatPlayerNotFound(to));
        const receiver = target.character;
        const sameTeam = context.client.teamForRace(receiver.data.race) == context.client.teamForRace(player.data.race);
        if (!sameTeam && !context.config.allowTwoSideInteractionChat && account.level == AccountLevel.player
            && target.security == AccountLevel.player)
            return send(ServerChatWrongFaction());
        // Whispers are always readable (LANG_UNIVERSAL); the sender gets a copy addressed to the receiver.
        target.deliver(Opcode.SMSG_MESSAGECHAT,
            chatMessage(ChatType.CHAT_MSG_WHISPER, Language.LANG_UNIVERSAL, player.guid, text, player.chatTag));
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_WHISPER_INFORM, Language.LANG_UNIVERSAL, receiver.guid,
            text)));
        if (receiver.hasFlag(PlayerFlags.afk) || receiver.hasFlag(PlayerFlags.dnd))
            send(ServerMessageChat(chatMessage(receiver.hasFlag(PlayerFlags.afk) ? ChatType.CHAT_MSG_AFK
                : ChatType.CHAT_MSG_DND, Language.LANG_UNIVERSAL, receiver.guid, receiver.autoReply)));
    }

    /**
     * `/afk` and `/dnd` (`HandleMessagechatOpcode`, `ToggleAFK`, `ToggleDND`): set with a message, or
     * the default one; the same command without a message clears it; the two exclude each other.
     */
    void setAway(ChatType type, string message)
    {
        const flag = type == ChatType.CHAT_MSG_AFK ? PlayerFlags.afk : PlayerFlags.dnd;
        const other = flag == PlayerFlags.afk ? PlayerFlags.dnd : PlayerFlags.afk;
        const defaultMessage = flag == PlayerFlags.afk ? "Away from Keyboard" : "Do not Disturb";
        if (player.hasFlag(flag))
        {
            if (message.length == 0)
                player.setFlag(flag, false);
            else
                player.autoReply = message;
        }
        else
        {
            player.autoReply = message.length ? message : defaultMessage;
            player.setFlag(other, false);
            player.setFlag(flag, true);
        }
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.status);
    }

    /// `HandleTextEmoteOpcode`: the animation for those who see the player, the text for those in range.
    @Handles(Opcode.CMSG_TEXT_EMOTE, WorldState.inWorld)
    void handleTextEmote(const ClientTextEmote request)
    {
        if (teleporting == Teleport.far)
            return;
        enum : uint { oneshotNone = 0, stateSleep = 12, stateSit = 13, stateKneel = 68 }
        const textEntry = context.client.emotesText.lookup(request.textEmote);
        if (textEntry is null)
            return;

        // Unit::HandleEmote: a one-shot animation, or a state that lasts until the player moves.
        const emote = textEntry.emote;
        if (emote != oneshotNone && emote != stateSleep && emote != stateSit && emote != stateKneel)
            if (const entry = context.client.emotes.lookup(emote))
            {
                if (entry.emoteType)
                {
                    player.setEmoteState(emote);
                    flushPlayerChanges();
                }
                else
                    map.sendToWatchers(this, Opcode.SMSG_EMOTE, packetBody(ServerEmote(emote, player.guid)), true);
            }

        // EmoteChatBuilder: "<player> waves at <target>." for everyone within the text emote range.
        string targetName;
        if (const target = context.onlinePlayer(request.target))
            targetName = target.character.data.name;
        map.sendInRange(player.position, context.config.listenRangeTextEmote, Opcode.SMSG_TEXT_EMOTE,
            packetBody(ServerTextEmote(player.guid, request.textEmote, request.emoteNum,
            cast(uint) targetName.length + 1, targetName)));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime, seconds;
    import std.algorithm.searching : count;
    import std.typecons : tuple;
    import dmangos.world.testclient;
}

/// Entering the world, playing a little, logging out and disconnecting from the world.
unittest
{
    import std.zlib : uncompress;
    import dmangos.world.movement : MovementInfo, Position;
    import dmangos.world.objects : lowGuid;
    import dmangos.world.player : CharacterData, ItemRecord;
    import dmangos.world.playercreate : NewSkill, NewSpell;
    import dmangos.world.worlddata : CreateAction;

    auto db = newDatabase();
    CharacterData anduin;
    anduin.guid = 7;
    anduin.account = 4;
    anduin.name = "Anduin";
    anduin.race = raceHuman;
    anduin.classId = classWarrior;
    anduin.level = 1;
    anduin.position = Position(-8949.95f, -132.493f, 83.5312f, 0);
    anduin.zone = 12;
    anduin.items = [ItemRecord(0, 15, 100, itemSword, 0, 0, 1, 0, "", 0, "", 0, 20),
        ItemRecord(0, 3, 101, itemShirt, 0, 0, 1, 0, "", 0, "", 0, 0),
        ItemRecord(0, 23, 102, itemHearthstone, 0, 0, 1, 0, "", 0, "", 0, 0)];
    anduin.skills = [NewSkill(skillSwords, 1, 5)];
    anduin.spells = [NewSpell(spellOneHandedSwords, true, false), NewSpell(spellLanguageCommon, true, false)];
    anduin.actions = [CreateAction(0, spellOneHandedSwords, 0)];
    db.loadable[7] = anduin;
    CharacterData stranger = anduin;
    stranger.guid = 50;
    stranger.account = 9;
    db.loadable[50] = stranger;

    auto context = newCreationContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(50));
    assert(client.read()[0].body_ == [ubyte(CharacterLoginFailure.CHAR_LOGIN_NO_CHARACTER)], "not their character");

    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    const login = client.read();
    ushort[] opcodes;
    foreach (packet; login)
        opcodes ~= packet.opcode;
    // Then the creatures and objects around Northshire Abbey, after the login packets.
    assert(opcodes[$ - 1] == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT);
    opcodes = opcodes[0 .. $ - 1];
    with (Opcode)
        assert(opcodes == [SMSG_LOGIN_VERIFY_WORLD, SMSG_ACCOUNT_DATA_TIMES, SMSG_EXPECTED_SPAM_RECORDS,
            SMSG_MESSAGECHAT, SMSG_MESSAGECHAT, SMSG_SET_REST_START, SMSG_BINDPOINTUPDATE, SMSG_TUTORIAL_FLAGS,
            SMSG_INITIAL_SPELLS, SMSG_ACTION_BUTTONS, SMSG_INITIALIZE_FACTIONS, SMSG_LOGIN_SETTIMESPEED,
            SMSG_SET_PROFICIENCY, SMSG_SET_PROFICIENCY, SMSG_COMPRESSED_UPDATE_OBJECT, SMSG_FRIEND_LIST,
            SMSG_IGNORE_LIST, SMSG_INIT_WORLD_STATES]);
    assert(client.session.state == WorldState.inWorld && (7 in db.online) !is null);
    assert(db.homeBinds[7].zone == 12, "a character without a home gets its start position");

    auto verify = ByteReader(login[0].body_);
    assert(deserialize!ServerLoginVerifyWorld(verify).x == anduin.position.x);
    auto spellsReader = ByteReader(login[8].body_);
    const book = deserialize!ServerInitialSpells(spellsReader).spells;
    assert(book.canFind(InitialSpell(spellOneHandedSwords)) && book.canFind(InitialSpell(spellPassiveTrainer)),
        "saved spells and the re-learned default ones");
    // The update creates three items and the player.
    const update = cast(const(ubyte)[]) uncompress(login[14].body_[4 .. $]);
    assert(update.length == (login[14].body_[0] | login[14].body_[1] << 8) && update[0] == 4);

    // Movement is remembered.
    MovementInfo step;
    step.position = Position(-8950, -130, 83.5f, 0.5f);
    ByteWriter moveBody;
    step.write(moveBody);
    client.write(Opcode.MSG_MOVE_HEARTBEAT, moveBody.data);
    assert(client.session.character.movement.position == Position(-8950, -130, 83.5f, 0.5f));

    // Queries.
    client.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(7));
    auto nameReader = ByteReader(client.read()[0].body_);
    const name = deserialize!ServerNameQueryResponse(nameReader);
    assert(name.name == "Anduin" && name.race == raceHuman && name.classId == classWarrior);
    client.write(Opcode.CMSG_ITEM_QUERY_SINGLE, ClientItemQuerySingle(itemSword, 0));
    const item = client.read();
    assert(item[0].opcode == Opcode.SMSG_ITEM_QUERY_SINGLE_RESPONSE && item[0].body_[0 .. 4] == [25, 0, 0, 0]);
    client.write(Opcode.CMSG_ITEM_QUERY_SINGLE, ClientItemQuerySingle(424242, 0));
    assert(client.read()[0].body_.length == 4);

    // Chat comes back to the speaker; sitting down updates the player.
    ByteWriter say;
    say.put(uint(ChatType.CHAT_MSG_SAY));
    say.put(uint(Language.LANG_COMMON));
    say.putCString("hello");
    client.write(Opcode.CMSG_MESSAGECHAT, say.data);
    const heard = client.read();
    assert(heard.length == 1 && heard[0].opcode == Opcode.SMSG_MESSAGECHAT);
    assert(heard[0].body_[$ - 7 .. $] == ['h', 'e', 'l', 'l', 'o', 0, 0]);
    client.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    const sat = client.read();
    // A values block carries the whole 41-word field mask, so it is big enough to be compressed.
    assert(sat.length == 2 && sat[0].opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT && sat[1].body_ == [1]);

    // Settings are saved as they change.
    client.write(Opcode.CMSG_SET_ACTION_BUTTON, ClientSetActionButton(5, spellLanguageCommon));
    assert(db.actionButtonWrites == [[7, 5, spellLanguageCommon, 0]]);
    client.write(Opcode.CMSG_TUTORIAL_FLAG, ClientTutorialFlag(33));
    assert(db.tutorialSaves[4][1] == 2);

    // The character screen's opcodes are not handled in the world.
    client.write(Opcode.CMSG_CHAR_ENUM, null);
    assert(client.read().length == 0);

    // Logging out saves where the character is and returns to the character screen.
    client.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const logout = client.read();
    assert(logout.length == 2 && logout[0].body_ == [0, 0, 0, 0, 1] && logout[1].opcode == Opcode.SMSG_LOGOUT_COMPLETE);
    assert(client.session.state == WorldState.characterScreen && (7 in db.online) is null);
    assert(db.progressSaves.length == 1 && db.progressSaves[0].position == Position(-8950, -130, 83.5f, 0.5f));
    assert(db.progressSaves[0].cinematic == 1, "the intro is not shown again");

    // Disconnecting from the world saves too.
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();
    client.session.disconnected();
    assert(db.progressSaves.length == 2 && (7 in db.online) is null);
    assert(client.session.state == WorldState.closed && context.sessionCount == 0);
}

/// Two players on one map: they see each other, each other's moves, chat and emotes, and part again.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : emotesFormat, emotesTextFormat;
    import dmangos.world.database : WorldAccount;
    import dmangos.world.movement : MovementFlags, MovementInfo, Position;
    import dmangos.world.objects : readPackedGuid;
    import dmangos.world.player : CharacterData;

    auto db = newDatabase();
    WorldAccount second = db.accounts["PLAYER"];
    second.id = 5;
    second.username = "SECOND";
    db.accounts["SECOND"] = second;
    foreach (t; [tuple(7u, "Anduin", 4u, classWarrior, 0.0f), tuple(8u, "Jaina", 5u, classMage, 20.0f)])
    {
        const guid = t[0], name = t[1], account = t[2], classId = t[3], x = t[4];
        CharacterData c;
        c.guid = guid;
        c.account = account;
        c.name = name;
        c.race = raceHuman;
        c.classId = classId;
        c.level = 1;
        c.cinematic = 1;
        c.position = Position(x, 0, 0);
        db.loadable[guid] = c;
    }
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // /wave: text emote 101 plays the one-shot animation 3.
    auto waveText = new uint[emotesTextFormat.length];
    waveText[0] = 101;
    waveText[2] = 3;
    context.client.emotesText = typeof(context.client.emotesText).parse(buildDbc(emotesTextFormat, [waveText]), "");
    context.client.emotes = typeof(context.client.emotes).parse(buildDbc(emotesFormat, [[3u, 0, 0, 0, 0, 0, 0]]), "");

    auto anduin = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    auto jaina = TestClient(new WorldSession(context, "127.0.0.2"), testKey);
    authenticate(anduin);
    authenticate(jaina, "SECOND");

    static ushort[] opcodes(const(ServerPacketRead)[] packets)
    {
        ushort[] codes;
        foreach (p; packets)
            codes ~= p.opcode;
        return codes;
    }

    // Anduin enters alone; then Jaina, 20 yards away: each is created for the other.
    anduin.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    assert(opcodes(anduin.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 1, "only itself");
    jaina.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(8));
    assert(opcodes(jaina.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 2, "itself, then Anduin");
    assert(opcodes(anduin.read()) == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT], "Jaina appears");
    assert(context.map(0).seeEachOther(7, 8) && context.worldPopulation == 2);

    // Names of online players.
    anduin.write(Opcode.CMSG_NAME_QUERY, ClientNameQuery(8));
    auto nameReader = ByteReader(anduin.read()[0].body_);
    assert(deserialize!ServerNameQueryResponse(nameReader).name == "Jaina");

    // Jaina walks: Anduin sees the same opcode, with her guid in front.
    MovementInfo step;
    step.flags = MovementFlags.forward;
    step.position = Position(25, 0, 0);
    ByteWriter body_;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_START_FORWARD, body_.data);
    const moved = anduin.read();
    assert(moved.length == 1 && moved[0].opcode == Opcode.MSG_MOVE_START_FORWARD);
    auto moveReader = ByteReader(moved[0].body_);
    assert(readPackedGuid(moveReader) == 8 && MovementInfo.read(moveReader).position == Position(25, 0, 0));
    assert(jaina.read().length == 0, "the mover is not told about its own move");

    // Say reaches 25 yards (they are 25 apart), whispers reach anyone online.
    ByteWriter say;
    say.put(uint(ChatType.CHAT_MSG_SAY));
    say.put(uint(Language.LANG_COMMON));
    say.putCString("hello");
    jaina.write(Opcode.CMSG_MESSAGECHAT, say.data);
    assert(opcodes(anduin.read()) == [Opcode.SMSG_MESSAGECHAT] && opcodes(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
    ByteWriter whisper;
    whisper.put(uint(ChatType.CHAT_MSG_WHISPER));
    whisper.put(uint(Language.LANG_COMMON));
    whisper.putCString("anduin");
    whisper.putCString("psst");
    jaina.write(Opcode.CMSG_MESSAGECHAT, whisper.data);
    assert(anduin.read()[0].body_[0] == ChatType.CHAT_MSG_WHISPER && jaina.read()[0].body_[0] == ChatType.CHAT_MSG_WHISPER_INFORM);
    ByteWriter nobody;
    nobody.put(uint(ChatType.CHAT_MSG_WHISPER));
    nobody.put(uint(Language.LANG_COMMON));
    nobody.putCString("Nobody");
    nobody.putCString("hi");
    jaina.write(Opcode.CMSG_MESSAGECHAT, nobody.data);
    assert(opcodes(jaina.read()) == [Opcode.SMSG_CHAT_PLAYER_NOT_FOUND]);

    // /wave at Anduin: the animation and the text, for both.
    jaina.write(Opcode.CMSG_TEXT_EMOTE, ClientTextEmote(101, 0, 7));
    assert(opcodes(anduin.read()) == [Opcode.SMSG_EMOTE, Opcode.SMSG_TEXT_EMOTE]);
    const own = jaina.read();
    assert(opcodes(own) == [Opcode.SMSG_EMOTE, Opcode.SMSG_TEXT_EMOTE]);
    auto emoteReader = ByteReader(own[1].body_);
    assert(deserialize!ServerTextEmote(emoteReader).targetName == "Anduin");

    // Sitting down is a public field: Anduin gets a values block.
    jaina.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
    assert(opcodes(anduin.read()) == [Opcode.SMSG_COMPRESSED_UPDATE_OBJECT]);
    jaina.read();

    // Walking out of sight and back, taking the time it takes.
    now += 60.seconds;
    step.position = Position(500, 0, 0);
    body_ = ByteWriter.init;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_HEARTBEAT, body_.data);
    assert(!context.map(0).seeEachOther(7, 8));
    const lost = anduin.read();
    assert(opcodes(lost)[$ - 1] == Opcode.SMSG_UPDATE_OBJECT && lost[$ - 1].body_[5] == 4, "an out-of-range block");
    now += 60.seconds;
    step.position = Position(30, 0, 0);
    body_ = ByteWriter.init;
    step.write(body_);
    jaina.write(Opcode.MSG_MOVE_HEARTBEAT, body_.data);
    assert(context.map(0).seeEachOther(7, 8) && opcodes(anduin.read()).count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) == 1);
    jaina.read();

    // Logging out: Anduin destroys Jaina; disconnecting takes Anduin off the map too.
    jaina.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const gone = anduin.read();
    assert(opcodes(gone) == [Opcode.SMSG_DESTROY_OBJECT] && gone[0].body_ == [8, 0, 0, 0, 0, 0, 0, 0]);
    anduin.session.disconnected();
    assert(context.worldPopulation == 0 && context.map(0).population == 0);
}

/// The update tick: the 20-second logout, regeneration, inns and cities, the periodic save.
unittest
{
    import core.time : Duration, MonoTime, seconds;
    import dmangos.world.player : Player, PlayerFlags, RestType;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig c) { c.instantLogout = 1; c.playerSaveInterval = 60; });
    auto now = MonoTime.currTime;
    context.clock = () => now;
    void tick(Duration step)
    {
        now += step;
        context.update(now);
    }

    context.data.xpForNextLevel = [0, 400];
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = cast(Player) anduin.session.character; // the test changes the player directly
    tick(Duration.zero);

    // Health comes back, faster when sitting; rage drains.
    me.values.set!UNIT_FIELD_HEALTH(10u);
    me.values.set!UNIT_FIELD_POWER1(1, 100u);
    tick(2.seconds);
    const standing = me.values[UNIT_FIELD_HEALTH];
    assert(standing > 10 && me.values[UNIT_FIELD_POWER1 + 1] == 75, "2.5 rage per 2 s");
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT));

    // Logging out takes 20 seconds, sitting and rooted; cancelling stands up.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const asked = anduin.read();
    assert(asked[0].opcode == Opcode.SMSG_LOGOUT_RESPONSE && asked[0].body_ == [0, 0, 0, 0, 0]);
    assert(opcodesOf(asked).canFind(Opcode.SMSG_FORCE_MOVE_ROOT) && me.values.getByte!UNIT_FIELD_BYTES_1(0) == 1);
    anduin.write(Opcode.CMSG_LOGOUT_CANCEL, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_FORCE_MOVE_UNROOT) && me.values.getByte!UNIT_FIELD_BYTES_1(0) == 0);
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    tick(19.seconds);
    assert(anduin.session.state == WorldState.inWorld);
    tick(1.seconds);
    assert(anduin.session.state == WorldState.characterScreen);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOGOUT_COMPLETE));

    // An inn: resting, rested XP every 10 seconds, instant logout; walking out ends it.
    anduin = loggedIn(context, db, 7, "Anduin", Position(innPosition[0], innPosition[1], innPosition[2]));
    me = cast(Player) anduin.session.character;
    anduin.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerInn));
    assert(me.hasFlag(PlayerFlags.resting) && me.restType == RestType.tavern);
    tick(1.seconds);
    tick(3600.seconds); // 400 XP to the next level: 400 / 1152000 per second, 1.25 in an hour
    assert(me.restBonus > 1.2f && me.restBonus < 1.3f && me.values[PLAYER_REST_STATE_EXPERIENCE] == 1);
    me.movement.position.x += 50;
    tick(1.seconds);
    assert(!me.hasFlag(PlayerFlags.resting));

    // A capital rests too.
    anduin.write(Opcode.CMSG_ZONEUPDATE, ClientZoneUpdate(zoneStormwind));
    assert(me.restType == RestType.city);
    anduin.write(Opcode.CMSG_ZONEUPDATE, ClientZoneUpdate(zoneElwynn));
    assert(me.restType == RestType.none);

    // The periodic save, every player_save_interval (60 s here); the hour above made one due already.
    tick(1.seconds);
    const saves = db.progressSaves.length;
    foreach (_; 0 .. 60)
        tick(1.seconds);
    assert(db.progressSaves.length == saves + 1 && db.progressSaves[$ - 1].restBonus == me.restBonus);
}

/// Entering Northshire: the deputy and the mailbox appear, and the client can ask what they are.
unittest
{
    import dmangos.world.objects : HighGuid, makeGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    db.loadable[7] = () {
        import dmangos.world.player : CharacterData;

        CharacterData c;
        c.guid = 7;
        c.account = 4;
        c.name = "Anduin";
        c.race = raceHuman;
        c.classId = classWarrior;
        c.level = 1;
        c.cinematic = 1;
        c.position = Position(-8949.95f, -132.49f, 83.53f);
        return c;
    }();
    authenticate(anduin);
    anduin.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    const login = opcodesOf(anduin.read());
    assert(login.count(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT) + login.count(Opcode.SMSG_UPDATE_OBJECT) == 2,
        "the player, then what it sees");
    const deputy = makeGuid(HighGuid.unit, creatureWillem, 79942);
    assert(context.map(0).objectCount == 2 && context.map(0).seesObject(7, deputy));

    anduin.write(Opcode.CMSG_CREATURE_QUERY, ClientObjectQuery(creatureWillem, deputy));
    const reply = anduin.read();
    assert(reply[0].opcode == Opcode.SMSG_CREATURE_QUERY_RESPONSE && reply[0].body_[4 .. 18] == "Deputy Willem\0");
    anduin.write(Opcode.CMSG_GAMEOBJECT_QUERY, ClientObjectQuery(32349, 0));
    assert(anduin.read()[0].opcode == Opcode.SMSG_GAMEOBJECT_QUERY_RESPONSE);
    anduin.write(Opcode.CMSG_CREATURE_QUERY, ClientObjectQuery(424242, 0));
    assert(anduin.read()[0].body_ == [0x32, 0x79, 0x06, 0x80]);
}
