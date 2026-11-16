/**
 * Handlers for a character in the world: logging out (`MiscHandler.cpp`),
 * movement (`MovementHandler.cpp`), queries (`QueryHandler.cpp`,
 * `ItemHandler.cpp`), the character's own settings, and chat
 * (`ChatHandler.cpp`).
 *
 * `InWorldHandlers` is mixed into `dmangos.world.session.WorldSession`, like
 * `dmangos.world.charscreen.CharacterScreenHandlers`.
 *
 * There is no map yet, so nobody else is in the world: movement is remembered
 * and saved but not shown to others, and chat comes back only to the speaker.
 */
module dmangos.world.inworld;

/// See the module documentation.
mixin template InWorldHandlers()
{
    import std.datetime.systime : Clock;
    import dmangos.log;
    import dmangos.world.defines : maxActionButtons;
    import dmangos.world.movement : MovementFlags, MovementInfo;
    import dmangos.world.objects : lowGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.queries : chatMessage, ClientChat, itemQueryResponse;
    import dmangos.world.updatefields : PLAYER_FIELD_BYTES;
    import dmangos.world.worlddata : CreateAction;

private:
    /// `WorldSession::LogoutPlayer`: saves the character and leaves the world.
    void leaveWorld(string why)
    {
        const progress = player.progress(secondsInWorld());
        context.database.saveProgress(progress);
        context.database.setOnline(player.data.guid, account.id, false, context.config.realmId);
        info!"%s: '%s' left the world (%s); '%s' saved at map %s %.1f %.1f %.1f"(remoteAddress, account.username,
            why, player.data.name, progress.map, progress.position.x, progress.position.y, progress.position.z);
        player = null;
        state_ = WorldState.characterScreen;
    }

    @Handles(Opcode.CMSG_LOGOUT_REQUEST, WorldState.inWorld)
    void handleLogoutRequest()
    {
        // CMaNGOS makes players wait 20 seconds unless they are resting. This server has no
        // timers yet, so everyone logs out at once.
        send(ServerLogoutResponse(0, 1));
        leaveWorld("logged out");
        send(ServerLogoutComplete());
    }

    @Handles(Opcode.CMSG_LOGOUT_CANCEL, WorldState.inWorld)
    void handleLogoutCancel()
    {
        send(ServerLogoutCancelAck());
    }

    // -----------------------------------------------------------------------
    // Movement (MovementHandler.cpp): remembered, not yet checked or shared.
    // -----------------------------------------------------------------------

    @Handles(movementOpcodes, WorldState.inWorld)
    void handleMovement(const MovementInfo movement)
    {
        if (!movement.position.isFinite)
        {
            warning!"%s: '%s' sent an invalid position; disconnecting"(remoteAddress, player.data.name);
            return disconnect();
        }
        // On a transport the position is relative to it; without transports, keep the last world position.
        if (movement.has(MovementFlags.onTransport))
            return;
        player.movement = movement;
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_NAME_QUERY, WorldState.inWorld)
    void handleNameQuery(const ClientNameQuery request)
    {
        if (request.guid == player.guid)
            return send(ServerNameQueryResponse(player.guid, player.data.name, "", player.data.race,
                player.data.gender, player.data.classId));
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

    @Handles(Opcode.CMSG_QUERY_TIME, WorldState.inWorld)
    void handleQueryTime()
    {
        send(ServerQueryTimeResponse(cast(uint) Clock.currTime.toUnixTime));
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

    @Handles(Opcode.CMSG_ZONEUPDATE, WorldState.inWorld)
    void handleZoneUpdate(const ClientZoneUpdate request)
    {
        if (request.zone == player.data.zone)
            return;
        player.data.zone = request.zone;
        send(ServerInitWorldStates(player.data.map, request.zone));
    }

    // -----------------------------------------------------------------------
    // Chat (ChatHandler.cpp): nobody else is around, so only the speaker hears it.
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_MESSAGECHAT, WorldState.inWorld)
    void handleMessageChat(const ClientChat chat)
    {
        if (chat.language == Language.LANG_ADDON || chat.text.length == 0)
            return;
        switch (chat.type)
        {
        case ChatType.CHAT_MSG_SAY:
        case ChatType.CHAT_MSG_YELL:
            send(ServerMessageChat(chatMessage(chat.type, chat.language, player.guid, chat.text)));
            break;
        case ChatType.CHAT_MSG_EMOTE:
            send(ServerMessageChat(chatMessage(chat.type, Language.LANG_UNIVERSAL, player.guid, chat.text)));
            break;
        case ChatType.CHAT_MSG_WHISPER:
            sendSystemMessage("Whispers are not supported yet.");
            break;
        default:
            trace!"%s: chat type %s is not supported yet"(remoteAddress, chat.type);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.bytes;
    import dmangos.serialization : deserialize;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.session : WorldSession, WorldState;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
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
    step.position = Position(1, 2, 3, 0.5f);
    ByteWriter moveBody;
    step.write(moveBody);
    client.write(Opcode.MSG_MOVE_HEARTBEAT, moveBody.data);
    assert(client.session.currentPlayer.movement.position == Position(1, 2, 3, 0.5f));

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
    assert(db.progressSaves.length == 1 && db.progressSaves[0].position == Position(1, 2, 3, 0.5f));
    assert(db.progressSaves[0].cinematic == 1, "the intro is not shown again");

    // Disconnecting from the world saves too.
    client.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    client.read();
    client.session.disconnected();
    assert(db.progressSaves.length == 2 && (7 in db.online) is null);
    assert(client.session.state == WorldState.closed && context.sessionCount == 0);
}
