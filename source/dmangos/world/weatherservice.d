/// Realm-wide weather, shared by every worker simulating a piece of a zone.
module dmangos.world.weatherservice;

import core.time : Duration;
import std.random : Random, unpredictableSeed;
import dmangos.cluster.services : Call, Service, ServiceKind;
import dmangos.world.context : WorldContext;
import dmangos.world.servicecheckpoint : RealmServiceCheckpoint;
import dmangos.world.weather : Weather, WeatherType, seasonOf, weatherChangeInterval;

struct WeatherWatch
{
    uint zone;
}

struct WeatherNotice
{
    uint zone;
    WeatherType type;
    float grade = 0;

    ubyte[] packet() const
    {
        Weather weather;
        weather.type = type;
        weather.grade = grade;
        return weather.packet();
    }
}

@Service(ServiceKind.weather)
struct WeatherHost
{
    private enum keepUnobserved = weatherChangeInterval + 30_000;

    private struct ActiveZone
    {
        Weather weather;
        int observedFor = keepUnobserved;

        WeatherNotice notice(uint zone) const
        {
            return WeatherNotice(zone, weather.type, weather.grade);
        }
    }

    private struct SavedZone
    {
        WeatherNotice notice;
        int changeIn, observedFor;
    }

    private WorldContext context;
    private RealmServiceCheckpoint durable;
    private ActiveZone[uint] active;
    private Random random;

    this(WorldContext context, const(ubyte)[] state)
    {
        import dmangos.log : warning;
        import dmangos.plaindata : decode;

        this.context = context;
        random = Random(unpredictableSeed);
        durable = RealmServiceCheckpoint(context, ServiceKind.weather);
        ushort previous;
        Duration age;
        const saved = durable.load(!state.length, previous, age);
        if (!state.length)
            state = saved;
        if (!state.length)
            return;
        try
        {
            SavedZone[] entries;
            decode(state, entries);
            const elapsed = cast(int) age.total!"msecs";
            foreach (ref entry; entries)
                if (entry.observedFor > elapsed)
                    if (const chances = entry.notice.zone in context.data.weatherChances)
                    {
                        Weather weather;
                        weather.chances = *chances;
                        weather.type = entry.notice.type;
                        weather.grade = entry.notice.grade;
                        weather.timer = entry.changeIn - elapsed;
                        active[entry.notice.zone] = ActiveZone(weather, entry.observedFor - elapsed);
                    }
        }
        catch (Exception error)
            warning!"weather: could not restore the saved service state: %s"(error.msg);
    }

    @Call WeatherNotice watch(const ref WeatherWatch request)
    {
        const zone = request.zone;
        if (auto current = zone in active)
        {
            current.observedFor = keepUnobserved;
            return current.notice(zone);
        }
        if (const chances = zone in context.data.weatherChances)
        {
            Weather weather;
            weather.chances = *chances;
            weather.regenerate(random, seasonOf(context.unixTime));
            weather.normalize();
            active[zone] = ActiveZone(weather);
            durable.save(true, &saveState);
            return active[zone].notice(zone);
        }
        return WeatherNotice(zone);
    }

    void tick(Duration elapsed)
    {
        if (!active.length)
            return;
        const diff = cast(int) elapsed.total!"msecs";
        bool changed;
        uint[] expired;
        foreach (zone, ref current; active)
        {
            current.observedFor -= diff;
            if (current.observedFor <= 0)
            {
                expired ~= zone;
                continue;
            }
            auto weather = &current.weather;
            weather.timer -= diff;
            if (weather.timer > 0)
                continue;
            weather.timer = weatherChangeInterval;
            if (weather.regenerate(random, seasonOf(context.unixTime)))
            {
                weather.normalize();
                context.services.announce!WeatherHost(current.notice(zone));
                changed = true;
            }
        }
        foreach (zone; expired)
            active.remove(zone);
        durable.save(changed || expired.length != 0, &saveState);
    }

    ubyte[] saveState()
    {
        import dmangos.plaindata : encode;

        SavedZone[] entries;
        foreach (zone, ref current; active)
            entries ~= SavedZone(current.notice(zone), current.weather.timer, current.observedFor);
        ubyte[] bytes;
        encode(bytes, entries);
        return bytes;
    }

    version (unittest)
    package Weather* weatherOf(uint zone)
    {
        if (auto current = zone in active)
            return &current.weather;
        return null;
    }
}

/// Workers share a zone's weather, and a clean service handoff preserves its next change.
/**
 * The realm's weather as one node knows it: the last state heard for each zone. The weather service
 * (`WeatherHost`, on one node of the cluster) decides the weather; a node hosting it asks it directly, any other
 * asks at most every 30 seconds per zone and is told of changes, and tells its players in the zone. A zone without
 * a `game_weather` row is always fine.
 */
struct ZoneWeather
{
    import core.time : MonoTime, seconds;
    import dmangos.world.context : WorldContext;

    private WorldContext world;
    private WeatherNotice[uint] heardOf;      // by zone
    private MonoTime[uint] nextRequest;       // by zone: not asked again before
    private MonoTime nextPoll;
    private ushort lastHost;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// `SMSG_WEATHER`'s body for a player entering `zone`. Asks the service if this node has not heard yet.
    ubyte[] packetFor(uint zone)
    {
        import dmangos.world.weather : fineWeatherPacket;

        if (zone !in world.data.weatherChances)
            return fineWeatherPacket();
        if (auto host = world.services.local!WeatherHost())
        {
            const request = WeatherWatch(zone);
            const current = host.watch(request);
            heardOf[zone] = current;
            return current.packet();
        }
        watch(zone, world.clock());
        if (const current = zone in heardOf)
            return current.packet();
        return fineWeatherPacket();
    }

    /// Each tick: the zones this node's players are in are asked about, every five seconds; a new host node is asked
    /// at once.
    void poll(MonoTime now)
    {
        const host = hostNode();
        if (lastHost != host)
        {
            lastHost = host;
            nextRequest = null;
            nextPoll = MonoTime.init;
        }
        if (now < nextPoll || !world.data.weatherChances.length)
            return;
        nextPoll = now + 5.seconds;
        foreach (player; world.online)
            if (player.character !is null && player.character.data.zone in world.data.weatherChances)
                watch(player.character.data.zone, now);
    }

    /// The service told of a zone's weather: kept, and if it changed the players in the zone are told.
    void heard(const ref WeatherNotice current)
    {
        import dmangos.world.opcodes : Opcode;

        if (current.zone !in world.data.weatherChances || heardOf.get(current.zone, WeatherNotice.init) == current)
            return;
        heardOf[current.zone] = current;
        const body_ = current.packet();
        foreach (player; world.online.values)
            if (player.character !is null && player.character.data.zone == current.zone)
                player.deliver(Opcode.SMSG_WEATHER, body_);
    }

    private void watch(uint zone, MonoTime now)
    {
        if (now < nextRequest.get(zone, MonoTime.init))
            return;
        nextRequest[zone] = now + 30.seconds;
        const host = hostNode();
        const before = heardOf.get(zone, WeatherNotice.init);
        world.services.call!(WeatherHost.watch)(WeatherWatch(zone), (WeatherNotice current) {
            if (host == hostNode() && before == heardOf.get(zone, WeatherNotice.init))
                heard(current);
        });
    }

    private ushort hostNode()
    {
        import dmangos.cluster.services : ServiceKind;

        return world.services.placement is null ? 0 : world.services.placement(ServiceKind.weather);
    }
}

unittest
{
    import core.time : msecs;
    import dmangos.cluster.protocol : ServiceCall, ServiceNews, ServiceReply;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient : loggedIn, newCreationContext, newDatabase;
    import dmangos.world.weather : SeasonChances, ZoneChances, fineWeatherPacket;

    auto db = newDatabase();
    auto holder = newCreationContext(db), follower = newCreationContext(db);
    auto next = newCreationContext(db);
    auto west = loggedIn(holder, db, 7, "Mira", Position(-8949.95f, -132.49f, 83.53f));
    auto east = loggedIn(follower, db, 8, "Tessa", Position(-8949.95f, -132.49f, 83.53f));
    const zone = west.session.character.data.zone;
    assert(east.session.character.data.zone == zone);
    west.read();
    east.read();
    ZoneChances rain;
    rain[] = SeasonChances(100, 0, 0);
    holder.data.weatherChances[zone] = rain;
    follower.data.weatherChances[zone] = rain;
    next.data.weatherChances[zone] = rain;
    follower.services.stop(ServiceKind.weather);
    next.services.stop(ServiceKind.weather);

    ushort owner = 1;
    follower.services.self = 2;
    follower.services.placement = (ServiceKind kind) => kind == ServiceKind.weather ? owner : ushort(0);
    ServiceCall[] requests;
    follower.services.sendCall = (ushort to, const ref ServiceCall call) {
        assert(to == owner);
        requests ~= ServiceCall(call.kind, call.call, call.origin, call.sequence, call.request.dup);
        return true;
    };
    foreach (server; [holder, next])
    {
        server.services.sendReply = (ushort to, const ref ServiceReply reply) {
            assert(to == 2);
            follower.services.receiveReply(owner, reply);
            return true;
        };
        server.services.sendNews = (const ref ServiceNews message) {
            assert(message.kind == ServiceKind.weather);
            follower.services.receiveNews(owner, message);
        };
    }

    holder.weather.packetFor(zone);
    auto local = holder.services.local!WeatherHost();
    auto opening = local.weatherOf(zone);
    opening.type = WeatherType.rain;
    opening.grade = 0.65f;
    const initial = holder.weather.packetFor(zone);
    assert(follower.weather.packetFor(zone) == fineWeatherPacket() && requests.length == 1);
    follower.weather.packetFor(zone);
    assert(requests.length == 1, "two arrivals share one weather query");
    holder.services.receiveCall(2, requests[0]);
    const received = east.read();
    assert(received.length == 1 && received[0].opcode == Opcode.SMSG_WEATHER && received[0].body_ == initial);
    assert(follower.weather.packetFor(zone) == initial);

    local.weatherOf(zone).timer = 1250;
    const handoff = holder.services.stop(ServiceKind.weather);
    owner = 3;
    assert(next.services.start(ServiceKind.weather, handoff));
    local = next.services.local!WeatherHost();
    local.random = Random(7);
    assert(local.weatherOf(zone).timer == 1250 && next.weather.packetFor(zone) == initial);
    next.services.tick(250.msecs);
    assert(local.weatherOf(zone).timer == 1000 && !east.read().length);

    // The old host is now a watcher. Both clients receive the same next change.
    next.services.sendNews = (const ref ServiceNews message) {
        follower.services.receiveNews(owner, message);
        holder.services.receiveNews(owner, message);
    };
    bool changed;
    foreach (_; 0 .. 40)
    {
        local.weatherOf(zone).timer = 0;
        next.services.tick(1.msecs);
        const left = west.read(), right = east.read();
        if (left.length)
        {
            assert(left.length == 1 && right.length == 1 && left[0].opcode == Opcode.SMSG_WEATHER);
            assert(left[0].body_ == right[0].body_ && left[0].body_ == next.weather.packetFor(zone));
            changed = true;
            break;
        }
        assert(!right.length);
    }
    assert(changed);
}

/// A replacement host can resume the saved forecast even when the old worker cannot send its state.
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : zoneElwynn;
    import dmangos.world.weather : SeasonChances, ZoneChances;

    auto db = newDatabase();
    auto old = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 1; });
    auto next = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 2; });
    ZoneChances rain;
    rain[] = SeasonChances(100, 0, 0);
    foreach (worker; [old, next])
    {
        worker.services.stop(ServiceKind.weather);
        worker.regionOwnerAround = (uint, Position, float) => ushort(1);
        worker.data.weatherChances[zoneElwynn] = rain;
    }
    auto now = MonoTime.currTime, nextClock = now;
    old.clock = () => now;
    next.clock = () => nextClock;
    assert(old.services.start(ServiceKind.weather));
    const original = old.weather.packetFor(zoneElwynn);
    old.services.local!WeatherHost().weatherOf(zoneElwynn).timer = 12_500;
    now += 11.seconds;
    old.services.tick(0.msecs);
    assert(db.loadServiceCheckpoint(ServiceKind.weather, old.config.realmId).revision == 2);
    nextClock += (old.unixTime + 2 - next.unixTime).seconds;
    assert(next.services.start(ServiceKind.weather));
    auto restored = next.services.local!WeatherHost().weatherOf(zoneElwynn);
    assert(restored !is null && restored.timer == 10_500 && restored.packet() == original);
}
