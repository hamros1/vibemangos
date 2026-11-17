/**
 * A character in the world (docs/DESIGN.md, "Where the player's gameplay lives", step 3): the
 * player's simulation, apart from the connection its client talks through.
 *
 * A `Character` exists from login (or arriving from another node) until logout (or leaving for
 * another node). It holds the `Player` and everything the player does in the world: every gameplay
 * mixin (movement, combat, spells, quests, items, groups, the GM commands, ...) and their state.
 * Its `connection` (`dmangos.world.session.WorldSession`) holds the socket, the encryption, the
 * account and the protocol state, authenticates, serves the character screen, and hands the packets
 * of a player in the world to its character (`handlePacket`).
 *
 * The gameplay code reaches what belongs to the connection (the account, the protocol state, the
 * client's address, sending a packet) through properties of the same names that forward to it.
 */
module dmangos.world.character;

import dmangos.world.honor : HonorHandlers;
import dmangos.world.pvp : PvPHandlers;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes;
import dmangos.timer : IntervalTimer;
import dmangos.log;
import dmangos.net.dispatch : DispatchResult, HandlesFor = Handles, PacketDispatch;
import dmangos.world.channelhandlers : ChannelHandlers;
import dmangos.world.charscreen : CharacterLogin;
import dmangos.world.commands : ChatCommands;
import dmangos.world.gmactions : GmActions;
import dmangos.world.gmtargets : GmTargets;
import dmangos.world.combathandlers : CombatHandlers;
import dmangos.world.death : DeathHandlers;
import dmangos.world.loothandlers : LootHandlers;
import dmangos.world.spellhandlers : SpellHandlers;
import dmangos.world.aurahandlers : AuraHandlers;
import dmangos.world.tradehandlers : TradeHandlers;
import dmangos.world.duelhandlers : DuelHandlers;
import dmangos.world.questhandlers : QuestHandlers;
import dmangos.world.talenthandlers : TalentHandlers;
import dmangos.world.mailhandlers : MailHandlers;
import dmangos.world.reputationhandlers : ReputationHandlers;
import dmangos.world.gameobjecthandlers : GameObjectHandlers;
import dmangos.world.auctionhandlers : AuctionHandlers;
import dmangos.world.taxihandlers : TaxiHandlers;
import dmangos.world.unit : Blow, UnitRef;
import dmangos.world.auras : Aura, makeAura;
import dmangos.world.spells : SpellInfo;
import dmangos.world.creature : Creature;
import dmangos.world.loot : Looter;
import dmangos.world.combat : Fighter, MeleeDamage;
import dmangos.world.relations : Relating;
import dmangos.world.gmdebug : DebugCommands;
import dmangos.world.gmlevel0 : Level0Commands;
import dmangos.world.gmlevel1 : Level1Commands;
import dmangos.world.gmlevel2 : Level2Commands;
import dmangos.world.gminstance : InstanceCommands;
import dmangos.world.sessionscripting : SessionScripting;
import dmangos.world.social : FriendInfo, SocialHandlers;
import dmangos.world.guildhandlers : GuildHandlers;
import dmangos.world.pethandlers : PetHandlers;
import dmangos.script.api : MenuOption, QuestProgress;
import dmangos.world.gmquest : QuestCommands;
import dmangos.world.gmlevel3 : Level3Commands;
import dmangos.world.grouphandlers : GroupHandlers;
import dmangos.world.exploration : Exploration;
import dmangos.world.inworld : InWorldHandlers;
import dmangos.world.itemhandlers : ItemHandlers;
import dmangos.world.npchandlers : NpcHandlers;
import dmangos.world.teleport : Teleport, TeleportHandlers;
import dmangos.world.context : Kickable, WorldContext;
import dmangos.world.database : WorldAccount;
import dmangos.world.objects : UpdateData, UpdatePacket;
import dmangos.world.map : deliverUpdate, Inhabitant, Map;
import dmangos.world.movement : Position;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.player : DeathState, Player, PlayerFlags, Viewer;
import dmangos.world.queries : chatMessage;
import dmangos.world.opcodes;
import dmangos.world.packets;

import dmangos.world.session : WorldSession, WorldState;

private alias Handles = HandlesFor!(Opcode, WorldState);

/// See the module documentation.
final class Character : OnlinePlayer, Looter
{
    /// The connection its client talks through (here, or relaying to its home node).
    WorldSession connection;

    mixin PacketDispatch!Handles;

    package
    {
        WorldContext context;
        MonoTime migratedAt;     // when the player last moved between nodes
        Player player;           // while in the world
        MonoTime enteredWorld;

        // Teleports (`Player::m_teleport_dest`, the teleport semaphores) and the order counter of
        // MSG_MOVE_TELEPORT_ACK.
        Teleport teleporting;
        uint moveOrderCounter;
        bool triggerpassCheat;    // `.cheat triggerpass` (Player::TriggerpassCheat)
        bool cooldownCheat;       // `.cheat cooldown`: no cooldowns (Player::CooldownCheat)
        bool castTimeCheat;       // `.cheat casttime`: every cast instant
        bool godModeCheat;        // `.cheat god`: no damage taken
        bool powerCheat;          // `.cheat power`: spells cost nothing
        bool[ulong] gmTargets;    // `.gm allowwhispers`: players who may whisper while the GM tag is on
        uint floodLines;          // flood protection (WorldSession::floodLines, floodTime)
        long floodTime;

        // The update tick: the 20-second logout, regeneration, rest, saving.
        bool loggingOut;
        MonoTime logoutRequestedAt;
        IntervalTimer regenTimer = IntervalTimer(2.seconds);  // REGEN_TIME_FULL
        IntervalTimer restTimer = IntervalTimer(1.seconds);
        IntervalTimer saveTimer;

        // Zones: the once-a-second check (Player::m_zoneUpdateTimer), a zone the client announced
        // (SetDelayedZoneUpdate), and the 100 ms position checks (m_positionStatusUpdateTimer).
        IntervalTimer zoneTimer = IntervalTimer(1.seconds);
        bool zoneUpdatePending;
        uint pendingZone;
        uint lastPositionCheck; // server time

        // The movement check: where the player was, and when.
        Position checkpoint;
        MonoTime checkpointTime;
        Position groupPositionAt; // where group members out of sight last heard the player was
    }

    ///
    this(WorldSession connection, WorldContext context)
    in (connection !is null && context !is null)
    {
        this.connection = connection;
        this.context = context;
    }

    /// One of the player's packets (the connection's protocol state `state`): handled here, or not one of its.
    DispatchResult handlePacket(Opcode opcode, WorldState state, ref ByteReader reader)
    {
        return dispatchPacket(opcode, state, reader);
    }

    /// The player leaves the world (`WorldSession::LogoutPlayer`), the connection still open or not.
    void leave(string why, bool loggingOut)
    {
        leaveWorld(why, loggingOut);
    }

    // -----------------------------------------------------------------------
    // The connection's, as the gameplay code knows them
    // -----------------------------------------------------------------------

    private
    {
        @property ref inout(WorldAccount) account() inout { return connection.account; }
        @property string remoteAddress() const { return connection.remoteAddress; }
        @property ref inout(uint) build() inout { return connection.build; }
        @property ref WorldState state_() { return connection.state_; }
        @property ref ushort homeNode() { return connection.homeNode; }
        @property ref ushort ownerNode() { return connection.ownerNode; }
        @property ref bool releaseWhenBack() { return connection.releaseWhenBack; }
        @property ref bool tutorialRowMissing() { return connection.tutorialRowMissing; }
        @property ref string carriedAddress() { return connection.carriedAddress; }

        void send(T)(auto ref const T packet)
        {
            connection.send(packet);
        }

        void finish()
        {
            connection.finish();
        }

        void disconnect()
        {
            connection.disconnect();
        }
    }

    /// Frames a packet for this player's client (`Inhabitant.deliver`).
    void deliver(Opcode opcode, const(ubyte)[] body_)
    {
        connection.deliver(opcode, body_);
    }

    /// Closes its connection (`Kickable.kick`): the player leaves the world.
    void kick(string reason)
    {
        connection.kick(reason);
    }

    /// The client's address.
    @property string address() const
    {
        return connection.address;
    }

    /// The round-trip time the client last reported, in milliseconds.
    @property uint latencyMs() const
    {
        return connection.latencyMs;
    }

    /// The connection's protocol state.
    @property WorldState state() const
    {
        return connection.state;
    }

    /// Whether the connection is closing.
    @property bool wantsClose() const
    {
        return connection.wantsClose;
    }

    /// The node holding its client, if another (phase 4b); 0 if here.
    @property ushort home() const
    {
        return connection.home;
    }

    /// The character being played, if any.
    @property const(Player) character() const
    {
        return player;
    }

    /// The create block a player who just came into sight gets: group mates see real health.
    UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
    {
        return player.createForOthers(serverTime, appearanceKind(viewer) == 1);
    }

    /// 1 for a member of this player's group (who sees its group fields), 0 for anyone else.
    uint appearanceKind(const Inhabitant viewer) const
    {
        return context.groups.sameGroup(player.guid, viewer.character.guid) ? 1 : 0;
    }

    /// One tick of the world update; see `InWorldHandlers.updateInWorld`.
    void update(Duration elapsed)
    {
        if (player !is null)
            updateInWorld(elapsed);
    }

    // -----------------------------------------------------------------------
    // The player as a unit (`dmangos.world.unit`): what creatures and the rules of units see of it
    // -----------------------------------------------------------------------

    /// See `UnitRef`.
    @property ulong combatGuid() const
    {
        return player is null ? 0 : player.guid;
    }

    /// See `UnitRef`: nobody to fight once it has left the world.
    Fighter fighter() const
    {
        if (player is null)
        {
            Fighter gone;
            gone.alive = false;
            return gone;
        }
        return player.fighter;
    }

    /// See `UnitRef`.
    Relating relating()
    {
        return relatingNow();
    }

    /// The map the player is on (null when not in the world).
    @property Map currentMap()
    {
        return player is null ? null : map;
    }

    /// The player as a unit on its map.
    @property UnitRef unit()
    {
        return UnitRef.of(this);
    }

    /// See `dmangos.world.unit.dealDamage`: damage the player suffers.
    void sufferDamage(UnitRef attacker, uint damage, const Blow blow)
    {
        takeBlow(attacker, damage, blow);
    }

    /// See `dealDamage`: a creature this player (or its pet) damaged is tapped for it.
    void tapCreature(Creature creature)
    {
        tap(creature);
    }

    /// See `dealDamage`: a creature this player (or its pet) killed: its rewards.
    void killedCreature(Creature creature)
    {
        creatureKilled(creature);
    }

    /// See `UnitRef`. The player's pet joins in (`OwnerAttackedBy`).
    void threatAdded(ulong creature)
    {
        addThreatener(creature);
        petAssistAgainst(creature);
    }

    /// ditto
    void threatRemoved(ulong creature)
    {
        removeThreatener(creature);
    }

    /// See `UnitRef`.
    void auraTick(Creature target, Aura aura, size_t effect)
    {
        creatureAuraTick(target, aura, effect);
    }

    /// See `UnitRef`.
    uint healthPercent()
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        if (player is null || player.values.get!UNIT_FIELD_MAXHEALTH == 0)
            return 0;
        return cast(uint)(ulong(player.values.get!UNIT_FIELD_HEALTH) * 100 / player.values.get!UNIT_FIELD_MAXHEALTH);
    }

    /// See `UnitRef`.
    void auraFrom(ulong caster, const(SpellInfo)* spell, uint casterLevel, int durationMs, const int[3] values)
    {
        if (player is null || player.deathState != DeathState.alive)
            return;
        addAura(makeAura(spell, caster, casterLevel, durationMs, false, values));
    }

    /// See `UnitRef`.
    bool hasAuraOf(uint spell)
    {
        return player !is null && player.auras.find(spell) !is null;
    }

    /// See `UnitRef`.
    void tell(Opcode opcode, const(ubyte)[] body_)
    {
        deliver(opcode, body_);
    }

    /// See `UnitRef`.
    @property bool untouchable()
    {
        return invincible;
    }

    /// See `UnitRef`.
    void questEventHappened(uint quest)
    {
        if (player !is null)
            areaExploredOrEventHappens(quest);
    }

    /// See `UnitRef`.
    void questFailedBy(uint quest)
    {
        if (player !is null)
            failQuest(quest);
    }

    /// See `UnitRef`.
    void showGossip(ulong npc, uint menu)
    {
        if (player is null)
            return;
        auto creature = context.npcFor(map.findObject(npc));
        if (creature is null)
            return;
        prepareGossipMenu(creature, menu);
        questMenu = null;
        sendPreparedGossip(creature);
    }

    /// A player came online or went offline (`SocialHandlers.friendChanged`), for another node's news.
    void friendNews(ulong guid, bool online, const FriendInfo info)
    {
        friendChanged(guid, online, info);
    }

    /// The guild fields from its guild now (`GuildHandlers.updateGuildFields`), for the context.
    void refreshGuildFields()
    {
        updateGuildFields();
    }

    /// The guild its `PLAYER_GUILDID` names (what it was in, until told otherwise).
    @property uint guildOfField()
    {
        import dmangos.world.updatefields : PLAYER_GUILDID;

        return player is null ? 0 : player.values.get!PLAYER_GUILDID;
    }

    /// An invitation from another node (`GuildHandlers.guildInvitedBy`).
    void guildInvite(uint guild, ulong inviter, string inviterName, string guildName)
    {
        guildInvitedBy(guild, inviter, inviterName, guildName);
    }

    /// See `OnlinePlayer.ignores`.
    bool ignores(ulong guid) const
    {
        return ignoresGuid(guid);
    }

    /// This player's pet died.
    void ownPetDied()
    {
        petDiedHere();
    }

    /// The weekly honor maintenance ran: the honor columns and rows again from the database.
    void honorReckoned()
    {
        if (player !is null)
            loadHonor();
    }

    /// The corpse of this player's pet went.
    void petCorpseGone(Creature pet)
    {
        petCorpseGoneHere(pet);
    }

    /// See `UnitRef`.
    QuestProgress questStatusOf(uint quest)
    {
        return questStatusFor(quest);
    }

    /// See `UnitRef`.
    void showScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests)
    {
        if (player !is null)
            sendScriptGossip(npc, textId, options, withQuests);
    }

    /// See `UnitRef`.
    void closeGossip()
    {
        if (player !is null)
            deliver(Opcode.SMSG_GOSSIP_COMPLETE, null);
    }

    /// See `UnitRef`.
    void killCreditFrom(uint entry, ulong creature)
    {
        if (player !is null)
            scriptKillCredit(entry, creature);
    }

    /// See `UnitRef`.
    @property bool castingSpell()
    {
        return generic.active;
    }

    /// See `UnitRef`.
    void auraRemovedBy(uint spell)
    {
        if (player !is null)
            if (auto aura = player.auras.find(spell))
                removeAura(aura);
    }

    /// See `UnitRef`.
    void castInterruptedBy(ulong creature)
    {
        import dmangos.world.spellcast : SpellCastResult;

        interruptCast(SpellCastResult.interrupted);
    }

    // -----------------------------------------------------------------------
    // `Looter`: what loot sees of the player (`dmangos.world.loot`, `loothandlers.d`)
    // -----------------------------------------------------------------------

    /// See `Looter`.
    @property ulong looterGuid() const
    {
        return player is null ? 0 : player.guid;
    }

    /// See `Looter`.
    uint storeLoot(uint item, uint count, int randomPropertyId, bool sendError)
    {
        return lootStore(item, count, randomPropertyId, sendError);
    }

    /// See `Looter`.
    void receiveMoney(uint copper)
    {
        lootMoney(copper);
    }

    /// See `Looter`.
    bool canUseItem(uint item)
    {
        return lootCanUse(item);
    }

    /// See `Looter`.
    void lootWindow(ulong target, bool open)
    {
        setLootWindow(target, open);
    }

    /// The account's level.
    @property AccountLevel security() const
    {
        return account.level;
    }

    /// ArcEmu's permission letters (`WorldSession::permissions`), from the account's `gmlevel`.
    @property string permissions() const
    {
        return context.config.gmPermissions.forLevel(account.level);
    }

    /// `WorldSession::CanUseCommand`
    bool canUseCommand(char group) const
    {
        import dmangos.world.commands : canUse = canUseCommand;

        return canUse(permissions, group);
    }

    /// `WorldSession::GetPermissionCount() > 0`
    @property bool hasPermissions() const
    {
        return permissions.length > 0;
    }

    /// `WorldSession::HasGMPermissions`
    @property bool hasGMPermissions() const
    {
        import dmangos.world.commands : hasGM = hasGMPermissions;

        return hasGM(permissions);
    }

    /// Between `SMSG_NEW_WORLD` and the client's `MSG_MOVE_WORLDPORT_ACK`.
    @property bool transferring() const
    {
        return teleporting == Teleport.far;
    }

    package uint instanceId_; // the dungeon instance it is in (0: none)
    package uint entryMap = uint.max; // where it was before going into an instance (uint.max: unknown)
    package MonoTime dungeonEntryAsked; // a dungeon's host was asked whether it may go in, then
    package ulong selectedGo;         // ArcEmu's `m_GM_SelectedGO`: the game object `.gobject select` chose
    package Position entryPoint;      // ditto

    /// See `OnlinePlayer.instanceId`.
    @property uint instanceId() const
    {
        return instanceId_;
    }

    /// The group changed: the leader flag, and the health the players around see and are seen with.
    void groupChanged()
    {
        if (player is null)
            return;
        updateLeaderFlag();
        if (transferring)
            return;
        foreach (watcher; map.watchers(this))
        {
            const mates = context.groups.sameGroup(player.guid, watcher.character.guid);
            const view = mates ? Viewer.groupMate : Viewer.stranger;
            deliverUpdate(watcher, player.groupView(view));
            deliverUpdate(this, watcher.character.groupView(view));
        }
    }


private:

    void sendUpdate(const ref UpdateData update)
    {
        const packet = update.build();
        if (packet.compressed)
            send(ServerCompressedUpdateObject(cast(ubyte[]) packet.body_));
        else
            send(ServerUpdateObject(cast(ubyte[]) packet.body_));
    }

    /// `Player::UpdateGroupLeaderFlag`
    void updateLeaderFlag()
    {
        auto group = context.groups.of(player.guid);
        player.setFlag(PlayerFlags.groupLeader, group !is null && group.isLeader(player.guid));
        flushPlayerChanges();
    }

    /**
     * Sends the player's changed fields to itself (unless `toSelf` is false: they were sent already),
     * and to each player who sees it the fields it may see: group mates and strangers see different
     * health values.
     */
    void flushPlayerChanges(bool toSelf = true)
    {
        UpdateData forSelf;
        if (toSelf && player.addChanges(forSelf, Viewer.self))
            sendUpdate(forSelf);
        // Built once for each kind of viewer (a group mate, a stranger), the same bytes to each of them.
        UpdatePacket[Viewer.max + 1] built;
        bool[Viewer.max + 1] isBuilt;
        if (!transferring)
            map.forEachWatcher(this, (Inhabitant watcher) {
            const view = context.groups.sameGroup(player.guid, watcher.character.guid) ? Viewer.groupMate
                : Viewer.stranger;
            if (!isBuilt[view])
            {
                UpdateData update;
                built[view] = player.addChanges(update, view) ? update.build() : UpdatePacket.init;
                isBuilt[view] = true;
            }
            const packet = built[view];
            if (packet.body_.length)
                watcher.deliver(packet.compressed ? Opcode.SMSG_COMPRESSED_UPDATE_OBJECT : Opcode.SMSG_UPDATE_OBJECT,
                    packet.body_);
        });
        if (!transferring)
            map.playerChanged(this); // nodes holding a replica of this player (phase 3b)
        player.clearChanges();
    }

    /// The map the player is on.
    @property Map map()
    in (player !is null)
    {
        return context.map(player.data.map, instanceId_);
    }

    /// Milliseconds on the server's clock, as movement packets carry them.
    uint serverTime()
    {
        return context.serverTime();
    }

    /// Seconds since the character entered the world.
    uint secondsInWorld()
    {
        return cast(uint)(context.clock() - enteredWorld).total!"seconds";
    }

    void sendSystemMessage(string text)
    {
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text)));
    }

    /// `WorldSession::SendNotification`: a message in the middle of the screen.
    void sendNotification(string text)
    {
        send(ServerNotification(text));
    }


    // -----------------------------------------------------------------------
    // The handler groups
    // -----------------------------------------------------------------------

    mixin CharacterLogin;
    mixin InWorldHandlers;
    mixin TeleportHandlers;
    mixin GroupHandlers;
    mixin ChannelHandlers;
    mixin NpcHandlers;
    mixin ItemHandlers;
    mixin Exploration;
    mixin ChatCommands;
    mixin GmActions;
    mixin GmTargets;
    mixin SocialHandlers;
    mixin GuildHandlers;
    mixin PetHandlers;
    mixin CombatHandlers;
    mixin DeathHandlers;
    mixin LootHandlers;
    mixin SpellHandlers;
    mixin AuraHandlers;
    mixin TradeHandlers;
    mixin DuelHandlers;
    mixin QuestHandlers;
    mixin TalentHandlers;
    mixin MailHandlers;
    mixin ReputationHandlers;
    mixin GameObjectHandlers;
    mixin AuctionHandlers;
    mixin TaxiHandlers;
    mixin PvPHandlers;
    mixin HonorHandlers;
    mixin Level0Commands;
    mixin Level1Commands;
    mixin Level2Commands;
    mixin InstanceCommands;
    mixin SessionScripting;
    mixin QuestCommands;
    mixin Level3Commands;
    mixin DebugCommands;
}

version (unittest)
{
    import core.time : MonoTime, msecs;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.relations : PlayerFlagsPvP;
    import dmangos.world.updatefields;

    private bool pvpFlagged(TestClient c)
    {
        return (c.session.inWorld.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
    }
}

// The PvP flag (`dmangos.world.pvp`). `/pvp`: on at once; off five minutes after it is turned off, not before.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = anduin.session.inWorld;
    anduin.write(Opcode.CMSG_TOGGLE_PVP, null);
    assert(pvpFlagged(anduin) && me.hasPlayerFlag(PlayerFlagsPvP.desired));
    anduin.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
    assert(!me.hasPlayerFlag(PlayerFlagsPvP.desired) && pvpFlagged(anduin), "still flagged, for now");
    me.updatePvPTimers(299_000);
    assert(pvpFlagged(anduin));
    me.updatePvPTimers(1000);
    assert(!pvpFlagged(anduin), "five minutes on: off");
    // While wanted, the timer stands still.
    anduin.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
    me.updatePvPTimers(600_000);
    assert(pvpFlagged(anduin));
}

// An enemy capital flags a visitor on any realm; his own never does. The free-for-all arena.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.config.gameType = 0; // a normal realm
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(10, 0, 0));
    thrall.session.inWorld.updateZone(zoneStormwind, zoneStormwind);
    assert(pvpFlagged(thrall), "an orc in Stormwind");
    anduin.session.inWorld.updateZone(zoneStormwind, zoneStormwind);
    assert(!pvpFlagged(anduin), "a human at home");
    thrall.session.inWorld.updateZone(zoneElwynn, zoneElwynn);
    thrall.session.inWorld.updatePvPTimers(300_000);
    assert(!pvpFlagged(thrall), "Alliance land on a normal realm: off after five minutes");

    auto me = anduin.session.inWorld;
    me.updateZone(zoneStranglethorn, areaGurubashiArena);
    assert(me.isFreeForAll);
    me.updateArea(zoneStranglethorn);
    assert(!me.isFreeForAll, "out of the arena");
}

// A hit between players: the attacker of a flagged player is flagged and contested; an unflagged one
// cannot be attacked at all.
unittest
{
    import dmangos.world.relations : canAttack;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(2, 0, 0));
    auto orc = thrall.session.inWorld, human = anduin.session.inWorld;
    assert(!canAttack(orc.relatingNow(), human.relatingNow(), context.client), "not flagged: not a target");
    anduin.write(Opcode.CMSG_TOGGLE_PVP, null);
    assert(canAttack(orc.relatingNow(), human.relatingNow(), context.client), "flagged: a target");
    assert(!pvpFlagged(thrall));
    human.pvpHitBy(orc, orc.isPvP);
    assert(pvpFlagged(thrall) && orc.isPvPContested, "the attacker: flagged and contested");
    orc.updatePvPTimers(29_000);
    assert(orc.isPvPContested, "while in PvP combat it stays");
    orc.pvpLeftCombat();
    orc.updatePvPTimers(30_000);
    assert(!orc.isPvPContested && pvpFlagged(thrall), "30 s out of combat: not contested; flagged 5 minutes");
}

// Honor (`dmangos.world.honor`): a kill of an enemy player, its credit and the fields; kept over a save.
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import dmangos.bytes : ByteReader;
    import dmangos.world.honor : HonorType;
    import dmangos.world.pvp : spellHonorlessTarget;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc, 0, 20);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(2, 0, 0), AccountLevel.player, raceHuman, 0, 20);
    auto orc = thrall.session.inWorld, human = anduin.session.inWorld;
    thrall.read();

    // Level 20 on level 20, no ranks: (10 * 0.25) * (20 + 1) * 1.05 = 55.
    orc.playerKilledByMe(human);
    auto credit = thrall.read().filter!(p => p.opcode == Opcode.SMSG_PVP_CREDIT).array;
    assert(credit.length == 1);
    auto r = ByteReader(credit[0].body_);
    assert(r.read!uint == 55 && r.read!ulong == human.player.guid);
    const v = &orc.player.values;
    assert((v.get!PLAYER_FIELD_SESSION_KILLS & 0xFFFF) == 1 && v.get!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS == 1);
    assert(v.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 55 && v.get!PLAYER_FIELD_THIS_WEEK_KILLS == 1);

    // The second kill of the same victim the same day is worth a little less.
    orc.playerKilledByMe(human);
    r = ByteReader(thrall.read().filter!(p => p.opcode == Opcode.SMSG_PVP_CREDIT).array[0].body_);
    assert(r.read!uint == 49, "(9 * 0.25) * 21 * 1.05 = 49.6");

    // None for an Honorless Target, one of one's own side, or one grey to the killer.
    if (const spell = context.data.spells.spell(spellHonorlessTarget))
    {
        human.castSpell(spell, SpellTargets(TargetFlags.self, 0), true, 0);
        orc.playerKilledByMe(human);
        assert(!thrall.read().canFind!(p => p.opcode == Opcode.SMSG_PVP_CREDIT), "honorless");
    }
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(4, 0, 0), AccountLevel.player, raceHuman, 0, 20);
    anduin.read();
    human.playerKilledByMe(jaina.session.inWorld);
    assert(!anduin.read().canFind!(p => p.opcode == Opcode.SMSG_PVP_CREDIT), "one's own side");

    // Saved and loaded again: the same.
    orc.saveHonor();
    context.settleWrites();
    assert(db.honorRows[9].points.length == 2 && db.honorRows[9].points[0].type == HonorType.honorable);
    orc.loadHonor();
    assert(orc.player.values.get!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS == 2);
    assert(orc.player.values.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 104);
}

// What ranks bring (`dmangos.world.honor`): the rank from rank points, the highest kept, a vendor's
// discount, the halls.
unittest
{
    import dmangos.world.teleport : AreaLockStatus;
    import dmangos.world.worlddata : AreaTriggerTeleport;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = anduin.session.inWorld;
    me.honorStored.storedRating = 5000; // rank 7: Sergeant, visual rank 3
    me.updateHonor();
    assert(me.honorRank.rank == 7 && me.honorRank.visualRank == 3);
    assert(me.player.values.getByte!PLAYER_BYTES_3(3) == 7 && me.player.highestHonorRank == 7);
    me.honorStored.storedRating = 1000; // down to Private: the highest stays
    me.updateHonor();
    assert(me.honorRank.rank == 5 && me.player.highestHonorRank == 7);

    // Sergeant (visual 3): 10% off at a vendor friendly to the Alliance (template 11, Stormwind).
    {
        import dmangos.dbc : buildDbc;
        import dmangos.world.clientdata : factionTemplateFormat;

        enum uint players = 1, alliance = 2, monsters = 8;
        const humans = me.player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[humans, 1, 0, players | alliance, alliance, monsters, 0, 0, 0, 0, 0, 0, 0, 0],
            [11u, 11, 0, alliance, alliance, monsters, 0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    }
    me.honorStored.storedRating = 5000;
    me.updateHonor();
    assert(me.buyPriceDiscount(11) < 0.95f);
    me.honorStored.storedRating = 1000; // Private: no rank discount
    me.updateHonor();
    assert(me.buyPriceDiscount(11) > 0.95f);

    // The Hall of Champions takes a visual rank of 6.
    AreaTriggerTeleport hall;
    hall.id = 2532;
    hall.targetMap = 0;
    uint requirement;
    const mapEntry = context.client.maps.lookup(0);
    assert(me.lockStatus(hall, mapEntry, requirement) == AreaLockStatus.pvpRank);
    me.honorStored.storedRating = 25_000; // rank 11: visual 7
    me.updateHonor();
    assert(me.lockStatus(hall, mapEntry, requirement) == AreaLockStatus.ok);
}
