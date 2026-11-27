/**
 * The character screen's handlers:
 * the character list, creation, deletion, and entering the world.
 *
 * `CharacterScreenHandlers` is mixed into `dmangos.world.character.Character`.
 * Its handlers are members of the session: they use its state (`account`,
 * `context`, `player`) and helpers (`send`, `sendUpdate`) directly, and resolve
 * `Handles` and `WorldState` where they are mixed in.
 *
 * Character creation checks the request (name, looks, limits, factions),
 * then `dmangos.world.playercreate` builds the character. Deletion checks
 * ownership and guild leadership, then removes the character's rows.
 * Logging in loads the character
 * (`dmangos.world.player`), the client is told the map and position, gets its
 * spellbook, action bars and other settings, and then the update packet that
 * creates its items and its player.
 */
module dmangos.world.charscreen;

/// See the module documentation.
mixin template CharacterScreenHandlers()
{
    import core.time : seconds;
    import dmangos.cluster.ownership : IdKind;
    import dmangos.world.player : CharacterData;
    import dmangos.timer : IntervalTimer;
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.characters : buildCharacterEntry;
    import dmangos.world.charscreen : gameTimeBits, motdLines;
    import dmangos.world.clientdata : Team;
    import dmangos.world.names;
    import dmangos.world.objects : lowGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : HomeBind, Player;
    import dmangos.world.playercreate : CharacterBuilder, CreateRequest, KnownAbilities, NewCharacter,
        validateAppearance;
    import dmangos.world.worlddata : toLowerName;

private:
    @Handles(Opcode.CMSG_CHAR_ENUM, WorldState.characterScreen)
    void handleCharEnum()
    {
        if (!admitted)
        {
            characterListWaiting = true;
            return;
        }
        ServerCharEnum list;
        foreach (ref record; context.database.characters(account.id))
        {
            if (list.characters.length == maxCharactersPerRealm)
            {
                error!"account %s has more than %s characters; only the first %s are listed"(account.id,
                    maxCharactersPerRealm, maxCharactersPerRealm);
                break;
            }
            auto entry = buildCharacterEntry(record, context.data);
            if (entry.isNull)
            {
                error!"character %s ('%s') has an invalid race/class pair (%s/%s); not listed"(record.guid,
                    record.name, record.race, record.classId);
                continue;
            }
            entry.get.guid = context.playerGuid(record.guid);
            list.characters ~= entry.get;
        }
        send(list);
    }

    @Handles(Opcode.CMSG_CHAR_CREATE, WorldState.characterScreen)
    void handleCharCreate(const ClientCharCreate request)
    {
        const result = createCharacter(request);
        send(ServerCharCreate(result));
    }

    private AccountLevel accountRankForCharacterScreen()
    {
        import dmangos.world.gmaccess : readGmAccess;

        return readGmAccess(context.database, account.id).rank();
    }

    /// Creates a character as the client asked; returns the result code for `SMSG_CHAR_CREATE`.
    ubyte createCharacter(const ref ClientCharCreate request)
    {
        alias R = CharacterResponse;
        const config = context.config;
        if (!admitted) // in a cluster, the account may still be in the world on another node
            return R.CHAR_CREATE_ERROR;
        const rank = accountRankForCharacterScreen();
        const isPlayer = rank == AccountLevel.player;

        if (isPlayer && config.charactersCreatingDisabled)
        {
            const team = context.client.teamForRace(request.race);
            if ((team == Team.alliance && (config.charactersCreatingDisabled & 1))
                || (team == Team.horde && (config.charactersCreatingDisabled & 2)))
                return R.CHAR_CREATE_DISABLED;
        }
        if (context.client.classes.lookup(request.classId) is null || context.client.races.lookup(request.race) is null)
        {
            error!"account %s tried to create a character of invalid class %s or race %s"(account.id, request.classId,
                request.race);
            return R.CHAR_CREATE_FAILED;
        }
        if (!validateAppearance(context.client, request.race, request.gender, request.hairStyle, request.hairColor,
            request.face, request.facialHair, request.skin))
        {
            error!"account %s tried to create a character with an invalid appearance"(account.id);
            return R.CHAR_CREATE_FAILED;
        }

        string name = request.name;
        if (!normalizePlayerName(name))
            return CharNameResult.CHAR_NAME_NO_NAME;
        const nameResult = checkPlayerName(name, config.minPlayerName, config.strictPlayerNames, config.realmZone);
        if (nameResult != CharNameResult.CHAR_NAME_SUCCESS)
            return nameResult;
        if (isPlayer && (toLowerName(name) in context.data.reservedNames) !is null)
            return CharNameResult.CHAR_NAME_RESERVED;
        if (context.database.nameTaken(name))
            return R.CHAR_CREATE_NAME_IN_USE;
        if (context.database.accountCharacterTotal(account.id) >= config.charactersPerAccount)
            return R.CHAR_CREATE_ACCOUNT_LIMIT;
        const realmCount = context.database.realmCharacterCount(account.id);
        if (realmCount >= config.charactersPerRealm)
            return R.CHAR_CREATE_SERVER_LIMIT;

        // GameType 1 (PvP), 8 (RP-PvP) and 16 (FFA PvP) are PvP realms.
        const pvpRealm = config.gameType == 1 || config.gameType == 8 || config.gameType == 16;
        const allowTwoSide = !pvpRealm || config.allowTwoSideAccounts || !isPlayer;
        bool haveSameRace;
        if (!allowTwoSide || config.skipCinematics == 1)
        {
            const races = context.database.characterRaces(account.id);
            if (races.length)
            {
                if (!allowTwoSide && (races[0] == 0
                    || context.client.teamForRace(races[0]) != context.client.teamForRace(request.race)))
                    return R.CHAR_CREATE_PVP_TEAMS_VIOLATION;
                // The first row is only used for the faction check above.
                haveSameRace = config.skipCinematics == 1 && races[1 .. $].canFind(request.race);
            }
        }

        const create = CreateRequest(name, request.race, request.classId, request.gender, request.skin, request.face,
            request.hairStyle, request.hairColor, request.facialHair, request.outfitId);
        const skipCinematic = (haveSameRace && config.skipCinematics == 1) || config.skipCinematics == 2;
        auto builder = new CharacterBuilder(context.data, context.client, context.creationSettings,
            &context.nextItemGuid);
        NewCharacter character;
        uint characterGuid;
        if (!context.takeId(IdKind.character, characterGuid))
            return R.CHAR_CREATE_ERROR; // a cluster member whose block of ids has not come
        if (!builder.create(characterGuid, account.id, rank, create, skipCinematic, character))
            return R.CHAR_CREATE_ERROR;

        context.database.saveNewCharacter(character, tutorialRowMissing);
        tutorialRowMissing = false;
        context.database.setRealmCharacterCount(account.id, context.config.realmId, realmCount + 1);
        info!"%s: account %s created character '%s' (guid %s, %s items, %s skills, %s spells)"(remoteAddress,
            account.id, name, character.guid, character.items.length, character.skills.length,
            character.spells.length);
        return R.CHAR_CREATE_SUCCESS;
    }

    /**
     * The client renames a character it was asked to rename at login (its `at_login` rename flag): a
     * valid, free name is taken (`SMSG_CHAR_RENAME`: the result, then the guid and the name); else the
     * reason it is not.
     */
    @Handles(Opcode.CMSG_CHAR_RENAME, WorldState.characterScreen)
    void handleCharRename(ref ByteReader reader)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.characters : AtLoginFlags;

        const fullGuid = reader.read!ulong;
        string name = reader.readCString();
        void answer(ubyte result)
        {
            ByteWriter w;
            w.put(result);
            if (result == CharNameResult.CHAR_NAME_SUCCESS)
            {
                w.put(fullGuid);
                w.putCString(name);
            }
            deliver(Opcode.SMSG_CHAR_RENAME, w.data);
        }
        const guid = lowGuid(fullGuid);
        if (fullGuid != context.playerGuid(guid))
            return answer(cast(ubyte) CharacterResponse.CHAR_CREATE_ERROR);
        const owner = context.database.characterOwner(guid);
        if (!admitted || owner.isNull || owner.get.account != account.id)
            return answer(CharNameResult.CHAR_NAME_FAILURE);
        const config = context.config;
        if (!normalizePlayerName(name))
            return answer(CharNameResult.CHAR_NAME_NO_NAME);
        const nameResult = checkPlayerName(name, config.minPlayerName, config.strictPlayerNames, config.realmZone);
        if (nameResult != CharNameResult.CHAR_NAME_SUCCESS)
            return answer(nameResult);
        if (accountRankForCharacterScreen() == AccountLevel.player && (toLowerName(name) in context.data.reservedNames) !is null)
            return answer(CharNameResult.CHAR_NAME_RESERVED);
        if (context.database.nameTaken(name))
            return answer(cast(ubyte) CharacterResponse.CHAR_CREATE_NAME_IN_USE);
        info!"%s: account %s renamed character '%s' (guid %s) to '%s'"(remoteAddress, account.id, owner.get.name, guid,
            name);
        context.database.renameCharacter(guid, name);
        answer(CharNameResult.CHAR_NAME_SUCCESS);
    }

    @Handles(Opcode.CMSG_CHAR_DELETE, WorldState.characterScreen)
    void handleCharDelete(const ClientCharDelete request)
    {
        const guid = lowGuid(request.guid);
        if (request.guid != context.playerGuid(guid))
            return send(ServerCharDelete(CharacterResponse.CHAR_DELETE_FAILED));
        if (!admitted) // in a cluster, the character may be in the world on another node
            return send(ServerCharDelete(CharacterResponse.CHAR_DELETE_FAILED));
        if (context.database.isGuildLeader(guid))
            return send(ServerCharDelete(CharacterResponse.CHAR_DELETE_FAILED_GUILD_LEADER));

        const owner = context.database.characterOwner(guid);
        if (owner.isNull || owner.get.account != account.id)
        {
            warning!"%s: account %s tried to delete character %s, which is not theirs"(remoteAddress, account.id, guid);
            return; // no reply
        }

        info!"%s: account %s deleted character '%s' (guid %s)"(remoteAddress, account.id, owner.get.name, guid);
        context.database.deleteCharacter(guid, account.id, context.deleteOptions, &context.nextMailId);
        context.database.setRealmCharacterCount(account.id, context.config.realmId,
            context.database.realmCharacterCount(account.id));
        send(ServerCharDelete(CharacterResponse.CHAR_DELETE_SUCCESS));
    }

    @Handles(Opcode.CMSG_PLAYER_LOGIN, WorldState.characterScreen)
    void handlePlayerLogin(const ClientPlayerLogin request)
    {
        // In a cluster the account may still be in the world on another node: wait until it is ours.
        if (!admitted)
        {
            pendingLogin = request;
            loginWaiting = true;
            return;
        }
        if (context.databaseStalled)
        {
            warning!"%s: account %s's login refused: this server's database takes none of its writes"(remoteAddress,
                account.id);
            return send(ServerCharacterLoginFailed(CharacterLoginFailure.CHAR_LOGIN_FAILED));
        }
        const guid = lowGuid(request.guid);
        auto loaded = context.database.loadCharacter(guid);
        if (loaded.isNull || loaded.get.account != account.id)
        {
            warning!"%s: account %s tried to log in character %s, which is not theirs"(remoteAddress, account.id, guid);
            return send(ServerCharacterLoginFailed(CharacterLoginFailure.CHAR_LOGIN_NO_CHARACTER));
        }
        auto character = loaded.get;
        const createInfo = context.data.createInfo(character.race, character.classId);
        if (createInfo is null)
        {
            error!"character %s has an invalid race/class pair (%s/%s); not logged in"(guid, character.race,
                character.classId);
            return send(ServerCharacterLoginFailed(CharacterLoginFailure.CHAR_LOGIN_NO_CHARACTER));
        }

        // A character without a home is bound where its race starts.
        if (!character.hasHomeBind)
        {
            character.homeBind = HomeBind(createInfo.map, createInfo.zone, createInfo.x, createInfo.y, createInfo.z);
            character.hasHomeBind = true;
            context.database.insertHomeBind(guid, character.homeBind);
        }
        // A position that is not a real number would hang the client's loading screen.
        if (!character.position.isFinite)
        {
            warning!"character %s has an invalid position; moved home"(guid);
            character.map = character.homeBind.map;
            character.position.x = character.homeBind.x;
            character.position.y = character.homeBind.y;
            character.position.z = character.homeBind.z;
        }

        // The character's own simulation (docs/DESIGN.md, step 3): it is in the world from here on.
        auto entering = new Character(this, context);
        entering.enterWorldAtLogin(character); // it becomes `playing` as it enters the world
    }

}

/**
 * The character's side of logging in (after the login request's checks), mixed
 * into `dmangos.world.character.Character`: the player made from its saved state, the login
 * packets, and the world entered.
 */
mixin template CharacterLogin()
{
    import core.time : seconds;
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.format : format;
    import dmangos.log;
    import dmangos.timer : IntervalTimer;
    import dmangos.world.charscreen : gameTimeBits, motdLines;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : CharacterData, Player;
    import dmangos.world.playercreate : CharacterBuilder, KnownAbilities;
    import dmangos.world.session : GatewayRecoveryCheckpoints;

    /// Enters the world as `character`, which the connection loaded and checked.
    /**
     * The ships and zeppelins of the player's map, each in a packet marked as a transport's, before the
     * player's own create block: the order and the mark the 1.12 client is sent them in by other servers
     * (shown after the player, unmarked, a zeppelin crashed it a few seconds later). `Map.add` is then told
     * they were shown.
     */
    package void showShipsHere()
    {
        // The map the player is about to be added to (made now if it is not yet: `enterWorld` would make it).
        if (auto here = context.mapOf(this))
            foreach (ship; here.everywhere)
            {
                const shown = ship.appearance(serverTime());
                sendUpdate(shown);
            }
    }

    package void enterWorldAtLogin(CharacterData character, scope const(GatewayRecoveryCheckpoints)* checkpoints = null)
    {
        const recovered = checkpoints !is null;
        const guid = character.guid;
        refreshGmAccess();
        player = makePlayer(character, !recovered);
        restoreGmSession(checkpoints); // before the player is shown: the GM flag and `.invisible` are seen
        readSaved(() => loadCooldowns()); // before the spellbook is sent: it shows them
        readSaved(() => talents.loadTalentReset());
        readSaved(() => contacts.loadSocial());
        saveTimer = IntervalTimer(sessionSaveInterval());
        regenTimer.reset();
        enteredWorld = context.clock();
        state_ = WorldState.inWorld;
        connection.playing = this; // in the world from here on
        instanceId_ = context.dungeons.instanceFor(player.guid, player.data.map); // a dungeon: its group's copy, or its own
        readSaved(() => loadBattleground()); // the initial map packets need the copy's current world states
        sendLoginPackets(recovered);
        context.enterWorld(this, true); // after the player's own create block: now others see it, and it sees them
        context.database.setOnline(guid, account.id, true, context.config.realmId);
        resetMovementCheck();
        startFallAt(player.position.z);

        // The group, which the character may have been in while offline.
        if (auto group = context.groups.of(player.guid))
        {
            group.sendUpdateTo(player.guid);
            group.updatePlayerOnlineStatus(this, true);
        }
        updateLeaderFlag(); // as saved, or not
        deathOnLogin();
        readSaved(() => loadAuras(recovered));
        readSaved(() => loadHonor());
        readSaved(() => enchanting.loadEnchantmentTimers());
        // Timed items that run in real time lose the time logged out.
        readSaved(() => loadItemDurations(player.data.logoutTime > 0 ? context.unixTime - player.data.logoutTime : 0));
        talents.applyPassiveSpells();
        petsOnArrival(); // the saved current pet comes back
        taxi.resumeSavedFlight(); // logged out in flight: it flies on
        openPartySummonCheckpoint(checkpoints);
        openSummonCheckpoint(checkpoints);
        info!"%s: '%s' entered the world as '%s' (guid %s, map %s at %.1f %.1f %.1f)"(remoteAddress,
            account.username, character.name, guid, character.map, character.position.x, character.position.y,
            character.position.z);
        if (savedUnread)
            return leaveIfUnread(); // back to the character screen, its records as saved
        if (!player.gmInvisible) // restored `.invisible`: its friends keep seeing it offline
            contacts.announceToFriends(true);
        guildLogin();
        // An interrupted battleground can send the character straight to another node.
        battlegroundOnLogin();
        if (player is null)
            return;
        // Group coins credited while the character was offline: nothing else pays them on a node that does
        // not poll for credits.
        context.groupRelay.redeemLootCoinShare(guid);
        if (recovered && !transferring)
            refreshBattlegroundQueue();
        // Another node's ground (a dungeon it hosts, say): there at once, not after the first look.
        if (const target = migrationTarget())
            migrateTo(target);
    }

    private auto sessionSaveInterval()
    {
        import std.algorithm.comparison : min;

        const configured = context.config.playerSaveInterval;
        return (connection.gatewayHome.node ? min(configured, 15u) : configured).seconds;
    }

    /**
     * The player of a loaded character: its spells and skills, and its rested
     * XP, with what the time offline earned if `offlineRest` (not for a player arriving from another
     * node, which was never offline).
     */
    Player makePlayer(ref CharacterData character, bool offlineRest)
    {
        KnownAbilities abilities;
        auto builder = new CharacterBuilder(context.data, context.client, context.creationSettings,
            &context.nextItemGuid);
        builder.loadAbilities(character.race, character.classId, character.level, security, character.skills,
            character.spells, abilities);
        auto made = new Player(character, abilities, context.data, context.client, &context.nextItemGuid,
            context.playerGuid(character.guid));
        if (allowsStaff("staff.support"))
            made.learnGmLanguages();
        const offline = offlineRest && character.logoutTime > 0 ? context.unixTime - character.logoutTime : 0;
        const rate = character.logoutResting ? context.config.rateRestOfflineInTavernOrCity
            : context.config.rateRestOfflineInWilderness / 4;
        made.setRestBonus(character.restBonus + (offline > 0 ? made.computeRest(offline, rate) : 0),
            context.config.maxPlayerLevel);
        made.setDrunkAfter(character.drunk, character.logoutTime > 0 ? context.unixTime - character.logoutTime : 0);
        made.loadQuestLog(context.data.quests);
        made.reputation = reputations.loadedReputation(character.guid, character.race, character.classId);
        made.clearChanges();
        return made;
    }

    /// The login packets, from `SMSG_LOGIN_VERIFY_WORLD` to the player's create packet.
    void sendLoginPackets(bool recovered = false)
    {
        const c = &player.data;
        if (!recovered)
        {
            send(ServerLoginVerifyWorld(c.map, player.movement.position.x, player.movement.position.y,
                player.movement.position.z, player.movement.position.orientation));
            send(ServerAccountDataTimes());
            send(ServerExpectedSpamRecords());
            foreach (line; motdLines(context.config.motd))
                sendSystemMessage(line);
        }
        // GMs, and with `send_stats_on_join` everyone, are told the population (a GM system message).
        if (context.config.sendStatsOnJoin || allowsStaff("staff.game_master"))
        {
            import dmangos.world.chatstyle : ChatColor, colored;
            import std.conv : to;

            systemMessage(format!"Online Players: %s  ·  Peak: %s  ·  Accepted Connections: %s"(
                colored(ChatColor.white, context.sessionCount.to!string),
                colored(ChatColor.white, context.peakSessions.to!string),
                colored(ChatColor.white, context.acceptedSessions.to!string)));
        }

        sendInitialPacketsBeforeAddToMap();
        send(ServerSetProficiency(2, player.proficiency[0])); // ITEM_CLASS_WEAPON
        send(ServerSetProficiency(4, player.proficiency[1])); // ITEM_CLASS_ARMOR

        // The race's intro, the first time; not for GMs (as the GM system requires).
        if (!recovered && c.cinematic == 0)
        {
            player.data.cinematic = 1;
            if (!allowsStaff("staff.game_master"))
                if (const race = context.client.races.lookup(c.race))
                    if (race.cinematicSequence)
                        send(ServerTriggerCinematic(race.cinematicSequence));
        }

        // The map's ships and zeppelins first, then into the map: the client creates its items and itself, and
        // the loading screen ends.
        showShipsHere();
        const update = player.createForSelf(serverTime());
        sendUpdate(update);
        player.inventory.markAllSent();
        sendInitialPacketsAfterAddToMap();
    }

    /// The packets sent before the player is added to a map, at login and after a far teleport.
    void sendInitialPacketsBeforeAddToMap()
    {
        const c = &player.data;
        send(ServerSetRestStart());
        send(ServerBindPointUpdate(c.homeBind.x, c.homeBind.y, c.homeBind.z, c.homeBind.map, c.homeBind.zone));
        send(ServerTutorialFlags(c.tutorials));
        ServerInitialSpells spells;
        spells.spells = player.spells.map!(id => InitialSpell(cast(ushort) id)).array;
        spells.cooldowns = initialCooldowns();
        send(spells);
        sendAllSpellMods(); // the talents' modifiers, as the client adds them to its spells
        send(ServerActionButtons(player.actionButtons));
        deliver(Opcode.SMSG_INITIALIZE_FACTIONS, reputations.initialReputations());
        send(ServerLoginSetTimeSpeed(gameTimeBits()));
    }

    /// The packets sent once the player is on the map: zone, social lists, world states, weather.
    void sendInitialPacketsAfterAddToMap()
    {
        setZoneOnArrival();
        contacts.sendSocialLists();
        sendInitWorldStates(player.data.zone);
        deliver(Opcode.SMSG_WEATHER, context.weather.packetFor(player.data.zone));
    }
}

/// The message of the day's lines, split at '@'.
string[] motdLines(string motd) pure @safe
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : array;

    return motd.splitter('@').filter!(line => line.length > 0).array;
}

/// `secsToTimeBitFields` for the local time, as `SMSG_LOGIN_SETTIMESPEED` carries the game time.
uint gameTimeBits()
{
    import std.datetime.systime : Clock;

    const now = Clock.currTime;
    return (now.year - 2000) << 24 | (now.month - 1) << 20 | (now.day - 1) << 14 | now.dayOfWeek << 11
        | now.hour << 6 | now.minute;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.character : Character;
    import dmangos.world.session : WorldSession, WorldState;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
}

unittest
{
    assert(motdLines("Hello@@world@") == ["Hello", "world"]);
}

/// Creating a character stores it, shows it in the list and counts it in realmcharacters.
unittest
{
    auto db = newDatabase();
    db.characterLists.remove(4);
    auto context = newCreationContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    assert(createCharacter(client, "aNDUIN", raceHuman, classWarrior) == CharacterResponse.CHAR_CREATE_SUCCESS);
    assert(db.saved.length == 1 && db.realmCounts[4] == 1 && db.tutorialRows.length == 1);
    const saved = db.saved.values[0];
    assert(saved.name == "Anduin" && saved.account == 4 && saved.items.length == 4);

    client.write(Opcode.CMSG_CHAR_ENUM, null);
    auto reader = ByteReader(client.read()[0].body_);
    const list = deserialize!ServerCharEnum(reader);
    assert(list.characters.length == 1 && list.characters[0].name == "Anduin");
    assert(list.characters[0].firstLogin == 1 && list.characters[0].level == 0);
    assert(list.characters[0].equipment[15].displayId == 1542); // main hand

    // A second character: names are unique, the tutorial row is written only once.
    assert(createCharacter(client, "anduin", raceHuman, classMage) == CharacterResponse.CHAR_CREATE_NAME_IN_USE);
    assert(createCharacter(client, "Jaina", raceHuman, classMage) == CharacterResponse.CHAR_CREATE_SUCCESS);
    assert(db.realmCounts[4] == 2 && db.tutorialRows.length == 1);
}

/// Names, looks, limits and factions are checked.
unittest
{
    auto db = newDatabase();
    db.characterLists.remove(4);
    auto context = newCreationContext(db, (ref WorldConfig c) { c.charactersPerRealm = 2; });
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    with (CharNameResult)
    {
        assert(createCharacter(client, "", raceHuman, classWarrior) == CHAR_NAME_NO_NAME);
        assert(createCharacter(client, "X", raceHuman, classWarrior) == CHAR_NAME_TOO_SHORT);
        assert(createCharacter(client, "R2d2", raceHuman, classWarrior) == CHAR_NAME_MIXED_LANGUAGES);
        assert(createCharacter(client, "thrall", raceHuman, classWarrior) == CHAR_NAME_RESERVED);
    }
    assert(createCharacter(client, "Anduin", raceHuman, classWarrior, 7) == CharacterResponse.CHAR_CREATE_FAILED,
        "hair style 7 does not exist");
    assert(createCharacter(client, "Anduin", 9, classWarrior) == CharacterResponse.CHAR_CREATE_FAILED, "no such race");

    assert(createCharacter(client, "Anduin", raceHuman, classWarrior) == CharacterResponse.CHAR_CREATE_SUCCESS);
    // The default realm type is PvP: an Alliance account cannot add a Horde character.
    assert(createCharacter(client, "Garrosh", raceOrc, classHunter)
        == CharacterResponse.CHAR_CREATE_PVP_TEAMS_VIOLATION);
    assert(createCharacter(client, "Jaina", raceHuman, classMage) == CharacterResponse.CHAR_CREATE_SUCCESS);
    assert(createCharacter(client, "Varian", raceHuman, classWarrior) == CharacterResponse.CHAR_CREATE_SERVER_LIMIT);
    assert(db.saved.length == 2);
}

/// Deleting: only your own characters, never a guild leader.
unittest
{
    auto db = newDatabase(); // account 4 owns "Thrall", guid 1
    CharacterRecord other;
    other.guid = 50;
    other.name = "Stranger";
    db.characterLists[9] = [other];
    auto context = newCreationContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);

    assert(deleteCharacter(client, 50) is null, "someone else's character: no reply, nothing deleted");
    assert(db.deleted.length == 0);

    db.guildLeaders[1] = true;
    assert(deleteCharacter(client, 1) == [ubyte(CharacterResponse.CHAR_DELETE_FAILED_GUILD_LEADER)]);
    db.guildLeaders.remove(1);

    assert(deleteCharacter(client, 1) == [ubyte(CharacterResponse.CHAR_DELETE_SUCCESS)]);
    assert(db.deleted == [1] && db.characterLists[4].length == 0 && db.realmCounts[4] == 0);
}


/// Renaming a character at the character screen: a free name is taken; one in use is refused.
unittest
{
    auto db = newDatabase();
    db.characterLists.remove(4);
    auto context = newCreationContext(db);
    auto client = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(client);
    assert(createCharacter(client, "Anduin", raceHuman, classWarrior) == CharacterResponse.CHAR_CREATE_SUCCESS);
    assert(createCharacter(client, "Jaina", raceHuman, classMage) == CharacterResponse.CHAR_CREATE_SUCCESS);
    ulong anduin;
    foreach (guid, c; db.saved)
        if (c.name == "Anduin")
            anduin = guid;

    void rename(string name)
    {
        import dmangos.bytes : ByteWriter;

        ByteWriter w;
        w.put(anduin);
        w.putCString(name);
        client.write(Opcode.CMSG_CHAR_RENAME, w.data);
    }
    rename("jaina");
    assert(client.read()[0].body_[0] == CharacterResponse.CHAR_CREATE_NAME_IN_USE, "taken");
    rename("varian");
    const answer = client.read()[0];
    assert(answer.opcode == Opcode.SMSG_CHAR_RENAME && answer.body_[0] == CharNameResult.CHAR_NAME_SUCCESS);
    assert(context.database.nameTaken("Varian") && !context.database.nameTaken("Anduin"), "renamed");
}
