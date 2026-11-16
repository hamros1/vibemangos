/// State shared by every session on a world server.
module dmangos.world.context;

import core.time : MonoTime;

import dmangos.auth.accounts : AccountLevel;
import dmangos.world.channel : ChannelManagers, Channels, ChannelSettings;
import dmangos.world.characterdb : DeleteOptions, GuidCounters;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.database : WorldDatabase;
import dmangos.world.group : Groups;
import dmangos.world.map : Inhabitant, Map, MapSettings;
import dmangos.world.online : Directory, OnlinePlayer;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.worlddata : WorldData;

/// Implemented by sessions so the context can kick a duplicate login.
interface Kickable
{
    /// Closes the session.
    void kick(string reason);
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

    /// The most sessions that were online at once, for the `uptime` table.
    size_t peakSessions;

    /// The time source sessions use (ping pacing); tests replace it.
    MonoTime delegate() clock;

    ///
    this(WorldConfig config, WorldDatabase database, WorldData data, ClientData client)
    in (database !is null && data !is null && client !is null)
    {
        this.config = config;
        this.database = database;
        this.data = data;
        this.client = client;
        this.clock = () => MonoTime.currTime;
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

    /// Milliseconds on the server's clock, as movement and create blocks carry them.
    uint serverTime()
    {
        return cast(uint)(clock() - MonoTime.init).total!"msecs";
    }

    /// The map `id`, created when its first player arrives.
    Map map(uint id)
    {
        return maps.require(id, new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit),
            &serverTime));
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
