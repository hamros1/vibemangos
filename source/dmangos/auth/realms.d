/**
 * The realm list: the realms the login server offers, and how each is shown.
 *
 * Realms come from the `realmlist` table and are re-read every
 * `realms_state_update_delay` seconds (0 = load once). A realm is shown
 * offline unless its `realmbuilds` column lists the client's build; the
 * world server normally fills that column in. Realms with an
 * `allowedSecurityLevel` above 0 are hidden from players, and shown offline
 * to staff whose level is too low.
 */
module dmangos.auth.realms;

import core.time : Duration, MonoTime, seconds;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.format : format;

import dmangos.log;
import dmangos.auth.accounts : AccountLevel, toAccountLevel;
import dmangos.auth.protocol : findBuild, RealmEntry, RealmFlags, RealmType, ServerRealmList;

/// One row of the `realmlist` table, in its column order.
struct RealmRecord
{
    uint id;
    string name;
    string address = "127.0.0.1";
    uint port = 8085;
    ubyte icon;
    ubyte realmflags;
    ubyte timezone;
    ubyte allowedSecurityLevel;
    float population = 0;
    string realmbuilds;
}

/// A realm ready to be listed.
struct Realm
{
    uint id;
    string name;
    string address; /// "host:port"
    uint icon;
    ubyte flags;
    ubyte timezone;
    AccountLevel allowedLevel;
    float population = 0;
    ushort[] builds; /// Sorted ascending.
}

/// Flags an administrator may set in `realmlist.realmflags`; anything else is masked out.
enum ubyte allowedRealmFlags = RealmFlags.offline | RealmFlags.newPlayers | RealmFlags.recommended
    | RealmFlags.specifyBuild;

/**
 * Category id for each realm zone (the `timezone` column) on a 1.x client.
 * These are the 1.x client's category ids by realm zone, built at
 * compile time.
 */
static immutable ubyte[38] classicRealmCategories = () {
    ubyte[38] categories = 1;
    categories[0] = 0;
    categories[3] = 5;
    categories[9] = 2;
    categories[10] = 3;
    categories[11] = 5;
    categories[19] = 2;
    categories[23] = 3;
    return categories;
}();

/// Realm zone used when the `timezone` column is out of range.
private enum ubyte developmentZone = 1;

/// Turns `realmlist` rows into listable realms: id 0 skipped, flags masked, builds parsed.
Realm[] prepareRealms(RealmRecord[] rows)
{
    import std.algorithm.iteration : splitter;
    import std.conv : ConvException, to;

    Realm[] realms;
    foreach (row; rows)
    {
        if (row.id == 0)
        {
            error!"realm '%s': realm id must be > 0"(row.name);
            continue;
        }
        if (row.realmflags & ~allowedRealmFlags)
            warning!"realm '%s' (id %s): only flags 0x02, 0x04, 0x20 and 0x40 may be set, ignoring 0x%02X"(
                row.name, row.id, row.realmflags & ~allowedRealmFlags);

        Realm realm;
        realm.id = row.id;
        realm.name = row.name;
        realm.address = format!"%s:%s"(row.address, row.port);
        realm.icon = row.icon;
        realm.flags = row.realmflags & allowedRealmFlags;
        realm.timezone = row.timezone;
        realm.allowedLevel = toAccountLevel(row.allowedSecurityLevel);
        realm.population = row.population;
        foreach (token; row.realmbuilds.splitter(' '))
        {
            if (token.length == 0)
                continue;
            try
                realm.builds ~= token.to!ushort;
            catch (ConvException)
                warning!"realm '%s': ignoring invalid build '%s' in realmbuilds"(row.name, token);
        }
        realm.builds.sort();
        realms ~= realm;
    }
    realms.sort!((a, b) => a.name < b.name); // the list is in name order
    return realms;
}

/// The realm list packet for a client of `build` logged in at `level`.
ServerRealmList buildRealmList(const(Realm)[] realms, ushort build, AccountLevel level,
    const ubyte[uint] characters)
{
    ServerRealmList list;
    foreach (ref realm; realms)
    {
        if (level == AccountLevel.player && realm.allowedLevel > AccountLevel.player)
            continue;

        const buildSupported = realm.builds.canFind(build);
        string name = realm.name;
        if (realm.flags & RealmFlags.specifyBuild)
        {
            // 1.x clients cannot show the build themselves, so it goes into the name.
            const shown = findBuild(buildSupported ? build : (realm.builds.length ? realm.builds[0] : 0));
            name ~= format!" (%s,%s,%s)"(shown.major, shown.minor, shown.patch);
        }

        ubyte flags = realm.flags;
        if (!buildSupported || realm.allowedLevel > level)
            flags |= RealmFlags.offline;

        const zone = realm.timezone < classicRealmCategories.length ? realm.timezone : developmentZone;
        list.realms ~= RealmEntry(cast(RealmType) realm.icon, flags, name, realm.address, realm.population,
            characters.get(realm.id, 0), classicRealmCategories[zone]);
    }
    return list;
}

/// The realm list, reloaded from the database at a fixed interval.
final class RealmCache
{
    private RealmRecord[] delegate() load;
    private Duration interval;
    private MonoTime nextRefresh;
    private Realm[] realms;

    /// `load` fetches the rows; `refreshSeconds` = 0 loads them only once.
    this(RealmRecord[] delegate() load, uint refreshSeconds)
    in (load !is null)
    {
        this.load = load;
        this.interval = refreshSeconds.seconds;
        refresh(MonoTime.currTime);
        if (realms.length == 0)
            warning!"the realmlist table has no usable realms"();
    }

    /// The current realms, reloading first if the interval has passed.
    const(Realm)[] current(MonoTime now)
    {
        if (interval > Duration.zero && now >= nextRefresh)
            refresh(now);
        return realms;
    }

    private void refresh(MonoTime now)
    {
        try
        {
            realms = prepareRealms(load());
            foreach (realm; realms)
                trace!"realm %s '%s' at %s, builds %s"(realm.id, realm.name, realm.address, realm.builds);
        }
        catch (Exception e)
            error!"could not load the realm list, keeping the previous one: %s"(e.msg);
        nextRefresh = now + interval;
    }
}

unittest
{
    setLogLevel(LogLevel.error);
    auto realms = prepareRealms([
        RealmRecord(2, "Zeta", "10.0.0.2", 8086, 1, 0x40, 1, 0, 1.5f, "6005 5875"),
        RealmRecord(1, "Alpha", "10.0.0.1", 8085, 0, 0x04 | 0x80, 3, 0, 0, "5875"),
        RealmRecord(3, "Staff", "10.0.0.3", 8087, 0, 0, 1, 2, 0, "5875"),
        RealmRecord(0, "Broken"),
    ]);
    assert(realms.length == 3);
    assert(realms[0].name == "Alpha" && realms[1].name == "Staff" && realms[2].name == "Zeta");
    assert(realms[0].flags == RealmFlags.specifyBuild, "0x80 is masked out");
    assert(realms[0].address == "10.0.0.1:8085");
    const ushort[] zetaBuilds = [5875, 6005];
    assert(realms[2].builds == zetaBuilds);

    const ubyte[uint] characters = [2: 4];
    const player = buildRealmList(realms, 5875, AccountLevel.player, characters);
    assert(player.realms.length == 2, "the staff realm is hidden from players");
    assert(player.realms[0].name == "Alpha (1,12,1)");
    assert(player.realms[0].timezone == 5, "zone 3 is category 5 on 1.x clients");
    assert(player.realms[1].characters == 4);
    assert(!(player.realms[1].flags & RealmFlags.offline));

    // A build the realm does not list shows it offline.
    const oldBuild = buildRealmList(realms, 6141, AccountLevel.player, null);
    assert(oldBuild.realms[1].flags & RealmFlags.offline);

    // Staff see the restricted realm, offline if their level is too low.
    const moderator = buildRealmList(realms, 5875, AccountLevel.moderator, null);
    assert(moderator.realms.length == 3 && (moderator.realms[1].flags & RealmFlags.offline));
    const gm = buildRealmList(realms, 5875, AccountLevel.gameMaster, null);
    assert(!(gm.realms[1].flags & RealmFlags.offline));
}
