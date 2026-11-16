/// State shared by every session on a world server.
module dmangos.world.context;

import core.time : MonoTime;

import dmangos.world.characterdb : DeleteOptions, GuidCounters;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.database : WorldDatabase;
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
final class WorldContext
{
    WorldConfig config;
    WorldDatabase database;
    WorldData data;
    ClientData client;

    /// Next free character, item and mail ids.
    GuidCounters next;

    /// Authenticated sessions by account id; one per account.
    private Kickable[uint] sessions;

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
