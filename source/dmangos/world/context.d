/// State shared by every session on a world server.
module dmangos.world.context;

import core.time : Duration, MonoTime;

import std.typecons : Nullable;

import dmangos.auth.accounts : AccountLevel;
import dmangos.auth.database : LoginDatabase, MemoryLoginDatabase;
import dmangos.world.channel : ChannelManagers, Channels, ChannelSettings;
import dmangos.world.characterdb : DeleteOptions, GuidCounters;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.database : WorldDatabase;
import dmangos.world.group : Groups;
import std.random : Random, unpredictableSeed;

import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings;
import dmangos.world.online : Directory, OnlinePlayer;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.worlddata : WorldData;

/// Implemented by sessions so the context can kick a duplicate login.
interface Kickable
{
    /// Closes the session.
    void kick(string reason);

    /// The client's address.
    @property string address() const;
}

/// A shutdown or restart counting down (`World::ShutdownServ`).
struct ShutdownTimer
{
    MonoTime at;        /// when the server stops
    bool restart;       /// stop with the restart exit code
    long lastAnnounced = long.max; /// seconds left at the last warning
}

/**
 * Configuration, databases, static data and the authenticated sessions.
 *
 * The server runs a single-threaded event loop, so none of this needs locking.
 */
final class WorldContext : Directory
{
    WorldConfig config;
    WorldDatabase database;
    WorldData data;
    ClientData client;

    /// Next free character, item and mail ids.
    GuidCounters next;

    /// Authenticated sessions by account id; one per account.
    private Kickable[uint] sessions;

    /// The maps that have players on them, by map id.
    private Map[uint] maps;

    /// Players in the world, by guid and by lower-cased name.
    private OnlinePlayer[ulong] online;
    private OnlinePlayer[dstring] onlineByName;

    /// Parties and raids, online or not (`ObjectMgr`'s groups).
    Groups groups;

    /// The chat channels of each team.
    ChannelManagers channels;

    /// Accounts and bans in the login database, as the login server manages them (GM commands).
    LoginDatabase accounts;

    /// A shutdown counting down, if any (`.server shutdown`).
    Nullable!ShutdownTimer shutdown;

    /// Set when the server stopped for a restart.
    bool restartRequested;

    /// When `update` last ran.
    private MonoTime lastUpdate;

    /// The most sessions that were online at once, for the `uptime` table.
    size_t peakSessions;

    /// The time source sessions use (ping pacing); tests replace it.
    MonoTime delegate() clock;

    ///
    this(WorldConfig config, WorldDatabase database, WorldData data, ClientData client,
        LoginDatabase accounts = null)
    in (database !is null && data !is null && client !is null)
    {
        this.accounts = accounts is null ? new MemoryLoginDatabase : accounts;
        this.config = config;
        this.database = database;
        this.data = data;
        this.client = client;
        this.clock = () => MonoTime.currTime;
        this.spawnRandom = Random(unpredictableSeed);
        {
            import std.datetime.systime : Clock;

            startUnixTime = Clock.currTime.toUnixTime;
            startClock = MonoTime.currTime;
        }
        this.next = database.highestGuids();
        this.groups = new Groups(database, this, next.group);
        groups.load(database.loadGroups());
        const channelSettings = ChannelSettings(config.allowTwoSideInteractionChannel,
            levelSetting(config.gmLevelChannelModeration), levelSetting(config.gmLevelChannelSilentJoin));
        channels.alliance = new Channels(this, client, channelSettings);
        channels.horde = config.allowTwoSideInteractionChannel ? channels.alliance
            : new Channels(this, client, channelSettings);
    }

    /// A `GM.*Level` setting: 0 means nobody, which `AccountLevel.player` stands for.
    private static AccountLevel levelSetting(uint level)
    {
        return level == 0 || level > AccountLevel.max ? AccountLevel.player : cast(AccountLevel) level;
    }

    /// Character creation settings from the configuration.
    @property CreationSettings creationSettings() const
    {
        return CreationSettings(config.startPlayerLevel, config.startGmLevel, config.startPlayerMoney,
            config.maxPrimaryTradeSkill, config.tradeSkillGmIgnoreMaxPrimary);
    }

    /// Character deletion settings from the configuration.
    @property DeleteOptions deleteOptions() const
    {
        return DeleteOptions(config.charDeleteMethod, config.charDeleteMinLevel, config.mailDeliveryDelay);
    }

    /// Unix time, moving with `clock` (so tests that replace the clock move it too).
    long unixTime()
    {
        return startUnixTime + (clock() - startClock).total!"seconds";
    }

    private long startUnixTime;
    private MonoTime startClock;

    /// Milliseconds on the server's clock, as movement and create blocks carry them.
    uint serverTime()
    {
        return cast(uint)(clock() - MonoTime.init).total!"msecs";
    }

    /// The map `id`, created when its first player arrives.
    Map map(uint id)
    {
        return maps.require(id, new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit),
            &serverTime, &spawnCell));
    }

    /// Chooses creatures' models and levels.
    private Random spawnRandom;

    /**
     * The creatures and game objects of one cell (`ObjectGridLoader`): each spawn's object, with a
     * level and model chosen, its addon, equipment and model data looked up.
     */
    MapObject[] spawnCell(uint mapId, ulong cell)
    {
        import dmangos.world.creature : chooseDisplay, chooseLevel, classStatsKey, Creature, CreatureParts, VirtualItem;
        import dmangos.world.gameobject : GameObject;

        MapObject[] spawned;
        if (auto cells = mapId in data.creatureCells)
            foreach (index; (*cells).get(cell, null))
            {
                const spawn = &data.creatureSpawns[index];
                const template_ = spawn.entry in data.creatureTemplates;
                const display = chooseDisplay(*template_, spawnRandom);
                if (display == 0)
                    continue;
                CreatureParts parts;
                const level = chooseLevel(*template_, spawnRandom);
                if (const stats = classStatsKey(level, template_.unitClass) in data.creatureClassStats)
                {
                    parts.classStats = *stats;
                    parts.hasClassStats = true;
                }
                parts.addon = spawn.guid in data.creatureAddons;
                if (parts.addon is null)
                    parts.addon = spawn.entry in data.creatureTemplateAddons;
                if (const model = display in data.models)
                {
                    parts.boundingRadius = model.boundingRadius;
                    parts.combatReach = model.combatReach;
                    parts.gender = model.gender;
                }
                if (const equipment = template_.equipmentTemplateId in data.creatureEquipment)
                    foreach (slot, entry; *equipment)
                        if (const item = entry in data.items)
                            parts.equipment[slot] = VirtualItem(item.displayId, cast(ubyte) item.itemClass,
                                cast(ubyte) item.subClass, cast(ubyte) item.details.material, item.inventoryType,
                                cast(ubyte) item.details.sheath);
                spawned ~= new Creature(*spawn, template_, display, level, parts, client);
            }
        if (auto cells = mapId in data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
            {
                const spawn = &data.gameObjectSpawns[index];
                spawned ~= new GameObject(*spawn, spawn.entry in data.gameObjectTemplates);
            }
        return spawned;
    }

    /// Puts a player in the world: on its map and in the lists of who is online.
    void enterWorld(OnlinePlayer who)
    in (who.character.guid !in online, "a character is in the world once")
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        map(who.character.data.map).add(who);
    }

    /// Takes a player out of the world.
    void leaveWorld(OnlinePlayer who)
    {
        import dmangos.world.worlddata : toLowerName;

        if (who.character.guid !in online)
            return;
        auto current = map(who.character.data.map);
        if (current.find(who.character.guid) !is null)
            current.remove(who);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
    }

    /// The player in the world with this guid, or null.
    OnlinePlayer onlinePlayer(ulong guid)
    {
        return online.get(guid, null);
    }

    /// The player in the world with this name (any case), or null.
    OnlinePlayer onlinePlayer(string name)
    {
        import dmangos.world.worlddata : toLowerName;

        return onlineByName.get(toLowerName(name), null);
    }

    /// Every player in the world.
    OnlinePlayer[] onlinePlayers()
    {
        return online.values;
    }

    /// `Directory.find`
    OnlinePlayer find(ulong guid)
    {
        return onlinePlayer(guid);
    }

    /// ditto
    OnlinePlayer find(string name)
    {
        return onlinePlayer(name);
    }

    /// `Directory.seeEachOther`: both on the same map, and in sight of each other.
    bool seeEachOther(ulong a, ulong b)
    {
        auto first = onlinePlayer(a), second = onlinePlayer(b);
        if (first is null || second is null || first.character.data.map != second.character.data.map)
            return false;
        if (auto onMap = first.character.data.map in maps)
            return onMap.seeEachOther(a, b);
        return false;
    }

    /// The channels of the player's team.
    Channels channelsFor(const OnlinePlayer who)
    {
        return channels.forTeam(client.teamForRace(who.character.data.race));
    }

    /// Number of players in the world.
    @property size_t worldPopulation() const
    {
        return online.length;
    }

    /// The sessions of the account, or those connected from the address (`.kick`).
    Kickable sessionOfAccount(uint accountId)
    {
        return sessions.get(accountId, null);
    }

    /// ditto
    Kickable[] sessionsFrom(string address)
    {
        Kickable[] found;
        foreach (session; sessions)
            if (session.address == address)
                found ~= session;
        return found;
    }

    /**
     * Called every second by the server loop: counts a shutdown down, warning everyone at the times
     * `World::ShutdownMsg` does. Returns true when the server should stop.
     */
    bool update(MonoTime now)
    {
        import std.format : format;
        import dmangos.world.packets : ServerMessageType, ServerServerMessage;
        import dmangos.world.map : packetBody;
        import dmangos.world.opcodes : Opcode;

        // World::Update: every player (a copy of the list: an update may log one out).
        const elapsed = lastUpdate == MonoTime.init || now < lastUpdate ? Duration.zero : now - lastUpdate;
        if (now > lastUpdate)
            lastUpdate = now;
        foreach (player; online.values)
            player.update(elapsed);
        foreach (map_; maps)
            map_.update(elapsed);

        if (shutdown.isNull)
            return false;
        auto timer = &shutdown.get();
        const left = (timer.at - now).total!"seconds";
        if (left <= 0)
        {
            restartRequested = timer.restart;
            return true;
        }
        // Every 5 minutes, then every minute under 15, every 15 s under 5 minutes, every second under 15 s:
        // a warning whenever the time left enters a new step, however late this call comes.
        static long step(long seconds)
        {
            return seconds < 15 ? seconds : seconds < 5 * 60 ? 1000 + seconds / 15 : seconds < 15 * 60
                ? 2000 + seconds / 60 : 3000 + seconds / (5 * 60);
        }
        if (timer.lastAnnounced == long.max || step(left) != step(timer.lastAnnounced))
        {
            timer.lastAnnounced = left;
            const body_ = packetBody(ServerServerMessage(timer.restart ? ServerMessageType.restartTime
                : ServerMessageType.shutdownTime, durationText(left)));
            foreach (player; online)
                player.deliver(Opcode.SMSG_SERVER_MESSAGE, body_);
        }
        return false;
    }

    /// `secsToTimeString`: "1h 2m 3s", as the shutdown message shows it.
    static string durationText(long seconds) pure @safe
    {
        import std.format : format;

        string text;
        if (seconds >= 3600)
            text ~= format!"%sh "(seconds / 3600);
        if (seconds >= 60)
            text ~= format!"%sm "(seconds / 60 % 60);
        text ~= format!"%ss"(seconds % 60);
        return text;
    }

    /// Allocates the next item guid.
    uint nextItemGuid()
    {
        return next.item++;
    }

    /// Allocates the next mail id.
    uint nextMailId()
    {
        return next.mail++;
    }

    /// Number of authenticated sessions.
    @property size_t sessionCount() const
    {
        return sessions.length;
    }

    /// Registers an authenticated session, kicking any earlier one of the same account.
    void addSession(uint accountId, Kickable session)
    {
        if (auto previous = accountId in sessions)
            if (*previous !is session)
                previous.kick("logged in again from elsewhere");
        sessions[accountId] = session;
        if (sessions.length > peakSessions)
            peakSessions = sessions.length;
    }

    /// Forgets a session, unless a newer one for the account has replaced it.
    void removeSession(uint accountId, Kickable session)
    {
        if (auto current = accountId in sessions)
            if (*current is session)
                sessions.remove(accountId);
    }
}
