/** Original 1.11 Scourge Invasion. The cluster places one progression service per realm.
 * The database has three camps per necropolis. A victory is a complete zone defense.
 */
module dmangos.world.scourge;

import core.time : Duration, minutes, MonoTime, msecs, seconds;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.context : WorldContext;

import dmangos.cluster.services : Call, Service, ServiceKind;

enum uint invasionSaveId = 3; // character database world_state
enum long eventWindow = 21 * 86400;

struct InvasionZone
{
    uint zone, ships, marker, remaining;
}
immutable InvasionZone[6] invasionZones = [
    InvasionZone(618,3,2259,2284), InvasionZone(440,3,2263,2283), InvasionZone(16,2,2260,2279),
    InvasionZone(4,2,2261,2280), InvasionZone(139,2,2264,2282), InvasionZone(46,2,2262,2281),
];

/// Carries the original zone activation. Late messages from a cleared or previously scheduled invasion are harmless.
struct CampDefeated
{
    uint generation;
    ubyte zone, ship, camp;
    long campaign;
}
struct InvasionControl { bool start; }
struct InvasionQuery { ushort node; }

struct InvasionState
{
    long campaign;
    bool ended;
    uint victories, revision;
    struct Zone
    {
        uint generation;
        bool active;
        ushort cleared;
        long next;
    }
    Zone[6] zones;

    bool running() const { return campaign && !ended; }

    bool begin(long now)
    {
        if (running() || now <= 0)
            return false;
        const previous = campaign;
        this = InvasionState.init;
        campaign = now > previous ? now : previous + 1;
        foreach (ref z; zones)
        {
            z.generation = 1;
            z.active = true;
        }
        return true;
    }

    uint remaining(size_t i) const
    {
        if (!zones[i].active)
            return 0;
        uint ships;
        foreach (ship; 0 .. invasionZones[i].ships)
            if ((zones[i].cleared & (7 << (3 * ship))) != (7 << (3 * ship)))
                ++ships;
        return ships;
    }

    bool cleared(const CampDefeated c) const
    {
        if (!running() || c.campaign != campaign || c.zone >= zones.length || c.ship >= invasionZones[c.zone].ships || c.camp >= 3)
            return true;
        const z = &zones[c.zone];
        return !z.active || c.generation != z.generation || (z.cleared & (1 << (c.ship * 3 + c.camp))) != 0;
    }

    bool defeat(const CampDefeated c, long now, uint delay)
    {
        if (cleared(c)) return false;
        auto z = &zones[c.zone];
        z.cleared |= cast(ushort)(1 << (c.ship * 3 + c.camp));
        if (!remaining(c.zone))
        {
            z.active = false;
            z.next = now + delay;
            if (++victories >= 150)
                foreach (ref other; zones)
                    other.active = false;
        }
        return true;
    }

    bool advance(long now)
    {
        if (!running()) return false;
        if (now >= campaign + eventWindow)
        {
            ended = true;
            foreach (ref z; zones) z.active = false;
            return true;
        }
        if (victories >= 150) return false;
        uint active;
        foreach (ref z; zones) if (z.active) ++active;
        bool changed;
        while (active < 2)
        {
            size_t next = zones.length;
            foreach (i, ref z; zones)
                if (!z.active && z.next && now >= z.next && (next == zones.length || z.next < zones[next].next))
                    next = i;
            if (next == zones.length) break;
            auto z = &zones[next];
            z.active = true;
            ++z.generation;
            z.cleared = 0;
            z.next = 0;
            ++active;
            changed = true;
        }
        return changed;
    }

    bool eventOn(ushort id) const
    {
        if (!running()) return false;
        if (id == 89) return true;
        if (id == 17) return victories < 150;
        if (id >= 90 && id <= 95) return zones[id-90].active;
        if (id == 96) return victories >= 50 && victories < 100;
        if (id == 97) return victories >= 100 && victories < 150;
        return (id == 98 || id == 99) && victories >= 150;
    }

    uint[2][] worldStates() const
    {
        uint[2][] result;
        result ~= [2219u, running() ? victories : 0u];
        foreach (i, ref zone; invasionZones)
        {
            const count = remaining(i);
            result ~= [zone.marker, cast(uint)(count != 0)];
            result ~= [zone.remaining, count];
        }
        return result;
    }
}

@Service(ServiceKind.scourge)
struct InvasionHost
{
    InvasionState state;
    long delegate() clock;
    void delegate(string) save;
    void delegate(const ref InvasionState) announce;
    private Duration elapsed;
    bool unreadableSave;

    /// Records owned by an older or different implementation must survive an ordinary server start.
    void restore(string saved)
    {
        import std.base64 : Base64;
        import std.exception : enforce;
        import dmangos.plaindata : decode;
        if (!saved.length) return;
        try
        {
            enforce(saved.length > 2 && saved[0 .. 2] == "1 ");
            const(ubyte)[] bytes = Base64.decode(saved[2 .. $]);
            InvasionState loaded;
            decode(bytes, loaded);
            enforce(!bytes.length && loaded.campaign > 0 && loaded.victories <= 150);
            state = loaded;
        }
        catch (Exception e)
        {
            import dmangos.log : error;
            error!"Scourge Invasion suspended: unrecognized world_state row %s"(invasionSaveId);
            unreadableSave = true;
        }
    }


    @Call void control(const ref InvasionControl command)
    {
        if (unreadableSave) return;
        if (command.start)
        {
            if (state.begin(clock())) changed();
        }
        else if (state.running())
        {
            state.ended = true;
            foreach (ref z; state.zones) z.active = false;
            changed();
        }
    }
    @Call void defeated(const ref CampDefeated camp)
    {
        import std.random : uniform;
        if (state.defeat(camp, clock(), uniform(2700u,3601u))) changed();
    }
    @Call InvasionState current(const ref InvasionQuery q) { return state; }
    void start() { if (announce !is null) announce(state); }
    void tick(Duration delta)
    {
        if (state.advance(clock()))
            changed();
        else if ((elapsed += delta) >= 60.seconds)
        {
            elapsed = Duration.zero;
            start();
        }
    }
    ubyte[] saveState()
    {
        import dmangos.plaindata : encode;
        ubyte[] data;
        encode(data, state);
        return data;
    }
    private void changed()
    {
        import std.base64 : Base64;
        ++state.revision;
        if (save !is null) save("1 " ~ Base64.encode(saveState()).idup);
        start();
    }
}

/// Three camps per ship, multiple ships per zone, stale deliveries after restarts and successive defenses.
/**
 * The Scourge invasion as this node follows it (`WorldContext.invasionHere`): its service made where the cluster
 * places it, the state it last told, and the layout of its camps here.
 */
final class InvasionFollower
{
    import dmangos.world.scourgelayout : InvasionLayout;

    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    InvasionLayout invasionLayout;

    InvasionState invasion;

    package InvasionHost newInvasionHost(const(ubyte)[] moved)
    {
        import dmangos.plaindata : decode;
        import dmangos.world.scourge : invasionSaveId;
        InvasionHost host;
        if (moved.length)
            decode(moved, host.state);
        if (!host.state.campaign)
            host.restore(world.database.worldState(invasionSaveId));
        host.clock = () => world.unixTime;
        host.save = (string text) { world.database.saveWorldState(invasionSaveId, text); };
        host.announce = (const ref InvasionState s) { world.services.announce!InvasionHost(s); };
        return host;
    }

    void askInvasion()
    {
        import dmangos.world.scourge : InvasionQuery;
        world.services.call!(InvasionHost.current)(InvasionQuery(world.nodeId), (InvasionState s) { invasionHeard(s); });
    }

    void invasionHeard(const ref InvasionState state)
    {
        import dmangos.world.map : packetBody;
        import dmangos.world.packets : ServerUpdateWorldState;
        if (state.campaign < invasion.campaign ||
            (state.campaign == invasion.campaign && state.revision <= invasion.revision))
            return;
        if (state.running && invasionLayout is null) invasionLayout = new InvasionLayout(world.data);
        const before = invasion;
        invasion = state;
        bool changed;
        foreach (ushort id; 17 .. 100)
            if ((id == 17 || id >= 89) && world.calendar.gameEvents.started(id) != state.eventOn(id))
            {
                world.calendar.gameEvents.start(id, state.eventOn(id));
                changed = true;
            }
        if (changed)
            world.calendar.updateGameEvents(world.clock(), true);
        if (invasionLayout !is null && !changed) world.calendar.gameEventSpawnsChanged();
        const previous = before.worldStates();
        foreach (i, field; state.worldStates())
            if (field[1] != previous[i][1])
                foreach (player; world.online.values)
                    if (player.character !is null)
                        player.deliver(Opcode.SMSG_UPDATE_WORLD_STATE,
                            packetBody(ServerUpdateWorldState(field[0], field[1])));
    }
}

unittest
{
    import dmangos.plaindata : decode, encode;
    InvasionState s;
    assert(s.begin(1234));
    CampDefeated c = CampDefeated(1,0,0,0,1234);
    assert(s.defeat(c,1250,2700) && !s.defeat(c,1251,2700));
    assert(s.remaining(0) == 3 && !s.victories);
    foreach (ubyte zone; 0 .. 6)
        foreach (ubyte ship; 0 .. cast(ubyte) invasionZones[zone].ships)
            foreach (ubyte camp; 0 .. 3)
                s.defeat(CampDefeated(1,zone,ship,camp,1234),1250,2700);
    assert(s.victories == 6 && !s.advance(3949) && s.advance(3950));
    assert(s.zones[0].active && s.zones[1].active && !s.zones[2].active);
    ubyte[] saved;
    encode(saved,s);
    const(ubyte)[] bytes = saved;
    InvasionState after;
    decode(bytes,after);
    assert(after == s && !after.defeat(c,4000,2700));
    after.victories = 149;
    foreach (ubyte ship; 0 .. 3)
        foreach (ubyte camp; 0 .. 3)
            after.defeat(CampDefeated(2,0,ship,camp,1234),4000,2700);
    assert(after.victories == 150 && after.eventOn(89) && after.eventOn(98) && after.eventOn(99));
    assert(!after.eventOn(17) && !after.eventOn(91));
    assert(after.advance(1234 + eventWindow) && !after.eventOn(99));
}

/// A remote node reports the same camp across a service move and an independent realm starts with the same IDs.
unittest
{
    import dmangos.cluster.protocol : ServiceCall, ServiceNews, ServiceReply;
    import dmangos.world.testclient : newContext, newDatabase;
    auto db = newDatabase();
    auto a = newContext(db), b = newContext(db), realmTwo = newContext(newDatabase());
    b.services.stopAll();
    a.services.self = 1;
    b.services.self = 2;
    ushort owner = 1;
    a.services.placement = b.services.placement = (ServiceKind) => owner;
    b.services.sendCall = (ushort node, const ref ServiceCall c) { a.services.receiveCall(2, c); return true; };
    a.services.sendCall = (ushort node, const ref ServiceCall c) { b.services.receiveCall(1, c); return true; };
    a.services.sendReply = (ushort node, const ref ServiceReply r) { b.services.receiveReply(1, r); return true; };
    b.services.sendReply = (ushort node, const ref ServiceReply r) { a.services.receiveReply(2, r); return true; };
    a.services.sendNews = (const ref ServiceNews n) { b.services.receiveNews(1, n); };
    b.services.sendNews = (const ref ServiceNews n) { a.services.receiveNews(2, n); };
    b.services.call!(InvasionHost.control)(InvasionControl(true));
    assert(a.invasionHere.invasion.running && a.invasionHere.invasion == b.invasionHere.invasion && !realmTwo.invasionHere.invasion.running);
    const original = a.invasionHere.invasion;
    auto camp = CampDefeated(1,0,0,0,original.campaign);
    b.services.call!(InvasionHost.defeated)(camp);
    assert(a.invasionHere.invasion == b.invasionHere.invasion && a.invasionHere.invasion.cleared(camp));
    const moved = a.services.stop(ServiceKind.scourge);
    owner = 2;
    b.services.start(ServiceKind.scourge,moved);
    a.services.call!(InvasionHost.defeated)(camp);
    a.invasionHere.askInvasion();
    a.invasionHere.invasionHeard(original);
    assert(a.invasionHere.invasion == b.invasionHere.invasion && a.invasionHere.invasion.revision == original.revision + 1);
    auto restarted = newContext(db);
    assert(restarted.invasionHere.invasion == a.invasionHere.invasion);
    b.services.call!(InvasionHost.control)(InvasionControl(false));
    b.services.call!(InvasionHost.control)(InvasionControl(true));
    assert(b.invasionHere.invasion.campaign > camp.campaign && !b.invasionHere.invasion.zones[0].cleared);
    b.services.call!(InvasionHost.defeated)(camp);
    assert(!b.invasionHere.invasion.zones[0].cleared);
    InvasionHost corrupt;
    corrupt.restore("1 invalid");
    assert(corrupt.unreadableSave);
    const start = InvasionControl(true);
    corrupt.control(start);
    assert(!corrupt.state.running);
}
