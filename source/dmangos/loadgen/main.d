/**
 * Load generator: many headless clients against a world server, to measure it under load
 * (docs/CLUSTER.md; docs/BENCHMARKS.md).
 *
 * ---
 * loadgen --world 127.0.0.1:8085 --login-db ... --character-db ... --world-db ... --bots 200 --scenario crowd
 * ---
 *
 * Setup, through the databases: accounts `<prefix>1` .. `<prefix>N` are created if missing (with a
 * password nobody uses) and given a fresh session key, as the login server would after a login; the
 * world server then accepts the bots without the login server, which stays out of the measurement.
 * Bots without a character create one (a human warrior) through the world server, and the
 * characters are then placed for the scenario.
 *
 * Scenarios:
 * - `crowd`: everyone within `--radius` of one point (Goldshire by default), running about.
 * - `spread`: each at a random creature spawn of the two continents, running about.
 * - `travel`: each at a random creature spawn, running `--radius` yards out and back, so cells
 *   load and players and creatures come into and out of sight all the time.
 * - `idle`: as `spread`, standing still.
 *
 * During the run it samples the server's CPU time and memory from `/proc` (`--server-pid`), and
 * at the end it reads the server's own `metrics:` lines (`--server-log`) for the run's window. The
 * report goes to standard output and, with `--report`, is appended to a file.
 *
 * This writes to the databases it is given: use it on a test copy, not on a live realm.
 */
module dmangos.loadgen.main;

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : count, filter, map, max, maxElement, sort, sum;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.string : strip;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException;
import std.random : Random, uniform, uniform01, unpredictableSeed;
import std.socket;
import std.stdio : stderr, writeln, File;

import dmangos.auth.accounts : AccountLevel, ClientDetails;
import dmangos.auth.mysqldb : MySqlLoginDatabase;
import dmangos.cluster.config : splitAddress;
import dmangos.crypto.srp6 : sessionKeyLength;
import dmangos.loadgen.bot;
import dmangos.log;
import dmangos.mysql : ConnectionInfo, MySqlConnection;

private struct Options
{
    string world = "127.0.0.1:8085";
    string loginDb = "127.0.0.1;3306;mangos;mangos;classicrealmd";
    string characterDb = "127.0.0.1;3306;mangos;mangos;classiccharacters";
    string worldDb = "127.0.0.1;3306;mangos;mangos;classicmangos";
    string mysqlLibrary;
    uint bots = 100;
    string prefix = "LOADBOT";
    string scenario = "crowd";
    string center = "0:-9464:64:56.4";
    float radius = 30;
    uint duration = 60;     // seconds of measurement, after everyone is in
    uint ramp = 50;         // logins started per second
    uint chatSeconds = 60;  // mean seconds between says per bot; 0: none
    uint warmup = 10;       // seconds after the last login before measuring
    uint seed;              // placement and behaviour: the same seed, the same run (0: a new one each time)
    int serverPid;
    string serverLog;
    string report;
    string commands;        // said by every bot, one after another, ';' between (their accounts are made GMs)
    uint commandSeconds = 3;
    bool trace;             // print every packet the bots receive
}

int main(string[] args)
{
    Options o;
    try
    {
        auto help = getopt(args,
            "world", "world server host:port", &o.world,
            "login-db", "login database (host;port;user;password;database)", &o.loginDb,
            "character-db", "characters database", &o.characterDb,
            "world-db", "world database", &o.worldDb,
            "mysql-library", "MySQL/MariaDB client library", &o.mysqlLibrary,
            "bots", "number of clients", &o.bots,
            "prefix", "account name prefix", &o.prefix,
            "scenario", "crowd, spread, travel or idle", &o.scenario,
            "commands", "chat commands each bot says in turn, separated by ';' (the accounts become administrators)",
                &o.commands,
            "command-seconds", "seconds between those commands", &o.commandSeconds,
            "trace", "print every packet the bots receive (with --bots 1, to see what a client is sent)", &o.trace,
            "center", "crowd: map:x:y:z", &o.center,
            "radius", "crowd: spread around the centre; wander: distance; travel: length", &o.radius,
            "duration", "seconds measured", &o.duration,
            "ramp", "logins started per second", &o.ramp,
            "chat", "mean seconds between says per bot (0: none)", &o.chatSeconds,
            "warmup", "seconds between the last login and the measurement", &o.warmup,
            "seed", "random seed, for runs that place the bots the same (0: random)", &o.seed,
            "server-pid", "world server process, for CPU and memory", &o.serverPid,
            "server-log", "world server log, for its metrics lines", &o.serverLog,
            "report", "file to append the report to", &o.report);
        if (help.helpWanted)
        {
            defaultGetoptPrinter("dmangos load generator", help.options);
            return 0;
        }
    }
    catch (GetOptException e)
    {
        stderr.writeln(e.msg);
        return 2;
    }
    setLogLevel(LogLevel.info);
    try
        return run(o);
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

private int run(const Options o)
{
    import std.algorithm.searching : canFind;
    import std.exception : enforce;

    enforce(["crowd", "spread", "travel", "idle"].canFind(o.scenario), "unknown scenario " ~ o.scenario);
    enforce(o.bots > 0 && o.prefix.length > 0 && o.prefix.length <= 24, "bad bot count or prefix");
    auto rng = Random(o.seed ? o.seed : unpredictableSeed);

    // Accounts and session keys.
    auto loginDb = new MySqlConnection(ConnectionInfo.parse(o.loginDb), o.mysqlLibrary);
    scope (exit)
        loginDb.close();
    auto accounts = new MySqlLoginDatabase(loginDb);
    Bot[] bots;
    uint[] accountIds;
    foreach (i; 1 .. o.bots + 1)
    {
        const name = format!"%s%s"(o.prefix, i);
        auto found = accounts.findAccount(name);
        const id = found.isNull ? accounts.createAccount(name, "x" ~ uniform!uint(rng).to!string, AccountLevel.player).id
            : found.get.id;
        ubyte[sessionKeyLength] key;
        foreach (ref b; key)
            b = uniform!ubyte(rng);
        if (o.commands.length)
            accounts.setLevel(name, AccountLevel.administrator);
        accounts.recordLogin(id, key, "127.0.0.1", ClientDetails("enUS", "Win", "x86"));
        accountIds ~= id;
        bots ~= new Bot(i - 1, name, characterName(o.prefix, i), key, BotPlan.init, uniform!uint(rng));
    }
    info!"%s accounts ready"(bots.length);

    // Characters: those missing are created through the world server.
    auto characterDb = new MySqlConnection(ConnectionInfo.parse(o.characterDb), o.mysqlLibrary);
    scope (exit)
        characterDb.close();
    ulong[uint] characterOf;
    foreach (row; characterDb.query!"SELECT account, guid FROM characters"())
        characterOf[row.get!uint(0)] = row.get!uint(1);
    Bot[] creators;
    foreach (i, bot; bots)
        if (accountIds[i] !in characterOf)
            creators ~= new Bot(bot.index, bot.account, bot.characterName, bot.key, BotPlan(true), uniform!uint(rng));
    if (creators.length)
    {
        info!"creating %s characters"(creators.length);
        drive(o, creators, Duration.zero, null);
        const failed = creators.count!(b => b.stats.failure.length > 0);
        enforce(failed == 0, format!"%s characters could not be created: %s"(failed,
            creators.filter!(b => b.stats.failure.length).front.stats.failure));
        foreach (row; characterDb.query!"SELECT account, guid FROM characters"())
            characterOf[row.get!uint(0)] = row.get!uint(1);
    }

    // Placement.
    auto places = placements(o, rng);
    foreach (i, id; accountIds)
    {
        const p = places[i % places.length];
        characterDb.execute!("UPDATE characters SET map = ?, position_x = ?, position_y = ?, position_z = ?, "
            ~ "orientation = 0, online = 0 WHERE guid = ?")(p.map, p.x, p.y, p.z, characterOf[id]);
    }

    // The run.
    BotPlan plan;
    plan.behaviour = o.scenario == "travel" ? Behaviour.travel : o.scenario == "idle" ? Behaviour.idle : Behaviour.wander;
    plan.radius = o.scenario == "crowd" ? 15 : o.radius;
    plan.chatEvery = o.chatSeconds.seconds;
    plan.commands = o.commands.length ? o.commands.splitter(';').map!(c => c.strip.idup).array : null;
    plan.commandEvery = o.commandSeconds.seconds;
    plan.trace = o.trace;
    foreach (ref bot; bots)
        bot = new Bot(bot.index, bot.account, bot.characterName, bot.key, plan, uniform!uint(rng));

    auto sampler = ServerSampler(o.serverPid);
    Window window;
    drive(o, bots, (o.warmup + o.duration).seconds, (MonoTime now, bool everyoneIn, MonoTime lastLogin) {
        if (window.start == MonoTime.init && everyoneIn && now - lastLogin >= o.warmup.seconds)
        {
            window.start = now;
            window.startClock = clockTime();
            sampler.begin(now);
            info!"measuring for %s s"(o.duration);
        }
        if (window.start != MonoTime.init)
        {
            sampler.sample(now);
            if (now - window.start >= o.duration.seconds)
            {
                window.end = now;
                window.endClock = clockTime();
                return false;
            }
        }
        return true;
    });

    const text = summarize(o, bots, sampler, window);
    writeln(text);
    if (o.report.length)
        File(o.report, "a").write(text, "\n");
    return 0;
}

private struct Place
{
    uint map;
    float x, y, z;
}

/// Where the scenario puts characters.
private Place[] placements(const Options o, ref Random rng)
{
    import std.math : cos, sin, sqrt;

    if (o.scenario == "crowd" || o.commands.length) // a probe (`--commands`) starts at `--center` too
    {
        const parts = o.center.splitter(':').map!(to!float).array;
        Place[] places;
        foreach (_; 0 .. o.bots)
        {
            const angle = uniform01(rng) * 2 * 3.14159265f, r = sqrt(uniform01(rng)) * o.radius;
            places ~= o.scenario == "crowd" ? Place(cast(uint) parts[0], parts[1] + r * cos(angle), parts[2] + r * sin(angle),
                parts[3]) : Place(cast(uint) parts[0], parts[1], parts[2], parts[3]);
        }
        return places;
    }
    // A creature's spawn point is somewhere a character can stand.
    auto worldDb = new MySqlConnection(ConnectionInfo.parse(o.worldDb), o.mysqlLibrary);
    scope (exit)
        worldDb.close();
    Place[] places;
    foreach (row; worldDb.query!("SELECT map, position_x, position_y, position_z FROM creature WHERE map IN (0, 1) "
        ~ "ORDER BY RAND() LIMIT ?")(o.bots))
        places ~= Place(row.get!uint(0), row.get!float(1), row.get!float(2), row.get!float(3));
    return places;
}

private import std.algorithm.iteration : splitter;

/// When the measurement ran, on the monotonic clock and as log time stamps.
private struct Window
{
    MonoTime start, end;
    string startClock, endClock;
}

private string clockTime()
{
    import std.datetime.systime : Clock;

    const t = Clock.currTime;
    return format!"%04d-%02d-%02dT%02d:%02d:%02d"(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/**
 * Connects the bots (`ramp` a second), moves their bytes and updates them every 50 ms until they
 * are all done, `limit` has passed since the last login started (if not zero), or `check` returns
 * false.
 */
private void drive(const Options o, Bot[] bots, Duration limit,
    bool delegate(MonoTime now, bool everyoneIn, MonoTime lastLogin) check)
{
    import core.sys.posix.poll : poll, pollfd, POLLIN, POLLOUT, POLLERR, POLLHUP;

    string host;
    ushort port;
    splitAddress(o.world, host, port);
    auto address = getAddress(host, port)[0];

    auto sockets = new Socket[bots.length];
    auto pending = new ubyte[][bots.length];
    auto fds = new pollfd[bots.length];
    size_t started;
    const begin = MonoTime.currTime;
    MonoTime lastLogin = begin;
    ubyte[65_536] buffer;

    void stop(size_t i, string why)
    {
        if (why.length)
            bots[i].fail(why);
        if (sockets[i] !is null)
        {
            sockets[i].close();
            sockets[i] = null;
        }
    }

    while (true)
    {
        const now = MonoTime.currTime;
        // Ramp: start the logins that are due.
        const due = o.ramp ? cast(size_t)((now - begin).total!"msecs" * o.ramp / 1000) + 1 : bots.length;
        while (started < bots.length && started < due)
        {
            auto s = new TcpSocket(address.addressFamily);
            s.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
            try
                s.connect(address);
            catch (Exception e)
            {
                bots[started].fail("cannot connect: " ~ e.msg);
                s.close();
                ++started;
                continue;
            }
            s.blocking = false;
            sockets[started] = s;
            bots[started].connected(now);
            lastLogin = now;
            ++started;
        }

        foreach (i, s; sockets)
        {
            fds[i].fd = s is null ? -1 : s.handle;
            fds[i].events = cast(short)(POLLIN | (pending[i].length ? POLLOUT : 0));
            fds[i].revents = 0;
        }
        poll(fds.ptr, fds.length, 50);
        const after = MonoTime.currTime;

        foreach (i, ref fd; fds)
        {
            auto s = sockets[i];
            if (s is null)
                continue;
            if (fd.revents & (POLLIN | POLLERR | POLLHUP))
            {
                while (true)
                {
                    const got = s.receive(buffer[]);
                    if (got == 0)
                    {
                        stop(i, bots[i].state == Bot.State.done ? null : "closed by the server");
                        break;
                    }
                    if (got == Socket.ERROR)
                    {
                        if (!wouldHaveBlocked())
                            stop(i, "connection error");
                        break;
                    }
                    bots[i].receive(buffer[0 .. got], after);
                }
            }
        }

        size_t inWorld, finished;
        foreach (i, bot; bots[0 .. started])
        {
            if (sockets[i] is null)
            {
                ++finished;
                continue;
            }
            bot.update(after);
            pending[i] ~= bot.output();
            if (pending[i].length)
            {
                const sent = sockets[i].send(pending[i]);
                if (sent == Socket.ERROR)
                {
                    if (!wouldHaveBlocked())
                        stop(i, "send failed");
                }
                else
                    pending[i] = pending[i][sent .. $];
            }
            if (bot.state == Bot.State.done && pending[i].length == 0)
                stop(i, null);
            else if (bot.state == Bot.State.inWorld)
                ++inWorld;
        }

        const everyoneIn = started == bots.length && inWorld + finished == bots.length;
        if (started == bots.length && finished == bots.length)
            break;
        if (limit > Duration.zero && check is null && started == bots.length && after - lastLogin > limit)
            break;
        if (check !is null && !check(after, everyoneIn, lastLogin))
            break;
        if (check !is null && after - lastLogin > limit + 120.seconds)
        {
            warning!"not everyone got into the world; measuring stopped"();
            break;
        }
    }
    foreach (i; 0 .. bots.length)
        stop(i, null);
}

/// The server's CPU time and memory, from `/proc`.
private struct ServerSampler
{
    int pid;
    MonoTime startedAt, lastAt;
    long startTicks, lastTicks;
    double maxCpu = 0;
    size_t maxRssKb, lastRssKb;
    bool active;

    this(int pid)
    {
        this.pid = pid;
    }

    void begin(MonoTime now)
    {
        if (pid <= 0)
            return;
        active = true;
        startedAt = lastAt = now;
        startTicks = lastTicks = cpuTicks();
    }

    void sample(MonoTime now)
    {
        if (!active || now - lastAt < 1.seconds)
            return;
        const ticks = cpuTicks();
        const cpu = (ticks - lastTicks) / ticksPerSecond / ((now - lastAt).total!"msecs" / 1000.0) * 100;
        if (cpu > maxCpu)
            maxCpu = cpu;
        lastTicks = ticks;
        lastAt = now;
        lastRssKb = rssKb();
        if (lastRssKb > maxRssKb)
            maxRssKb = lastRssKb;
    }

    double averageCpu() const
    {
        const seconds = (lastAt - startedAt).total!"msecs" / 1000.0;
        return seconds > 0 ? (lastTicks - startTicks) / ticksPerSecond / seconds * 100 : 0;
    }

    static double ticksPerSecond()
    {
        import core.sys.posix.unistd : sysconf, _SC_CLK_TCK;

        return cast(double) sysconf(_SC_CLK_TCK);
    }

    long cpuTicks()
    {
        import std.file : readText;
        import std.string : lastIndexOf, split;

        try
        {
            const stat = readText(format!"/proc/%s/stat"(pid));
            const fields = stat[stat.lastIndexOf(')') + 2 .. $].split(' ');
            return fields[11].to!long + fields[12].to!long; // utime, stime
        }
        catch (Exception)
            return lastTicks;
    }

    size_t rssKb()
    {
        import std.file : readText;
        import std.string : lineSplitter, split, startsWith;

        try
            foreach (line; readText(format!"/proc/%s/status"(pid)).lineSplitter)
                if (line.startsWith("VmRSS:"))
                    return line.split[1].to!size_t;
        catch (Exception)
        {
        }
        return 0;
    }
}

/// The report: what the bots saw, what the server measured, and its CPU and memory.
private string summarize(const Options o, Bot[] bots, const ServerSampler sampler, Window window)
{
    auto text = format!"## %s: %s bots, %s s\n\n"(o.scenario, bots.length, o.duration);
    const inWorld = bots.count!(b => b.state == Bot.State.inWorld);
    const failed = bots.filter!(b => b.stats.failure.length).array;
    text ~= format!"* bots in the world at the end: %s; failed: %s%s\n"(inWorld, failed.length,
        failed.length ? " (first: " ~ failed[0].stats.failure ~ ")" : "");

    auto logins = bots.filter!(b => b.stats.loginTime > Duration.zero).map!(b => b.stats.loginTime.total!"usecs" / 1000.0).array.sort.release;
    if (logins.length)
        text ~= format!"* login (connect to world): median %.1f ms, max %.1f ms\n"(logins[$ / 2], logins[$ - 1]);
    auto pings = bots.map!(b => b.stats.pings).array;
    double[] rtts;
    foreach (p; pings)
        foreach (d; p)
            rtts ~= d.total!"usecs" / 1000.0;
    rtts.sort();
    if (rtts.length)
        text ~= format!"* ping round trip: %s samples, median %.2f ms, p99 %.2f ms, max %.2f ms\n"(rtts.length,
            rtts[$ / 2], rtts[cast(size_t)(rtts.length * 0.99) < rtts.length ? cast(size_t)(rtts.length * 0.99) : $ - 1],
            rtts[$ - 1]);
    if (window.end != MonoTime.init)
    {
        const seconds = (window.end - window.start).total!"msecs" / 1000.0;
        const bytesIn = bots.map!(b => b.stats.bytesIn).sum, packetsIn = bots.map!(b => b.stats.packetsIn).sum;
        const bytesOut = bots.map!(b => b.stats.bytesOut).sum, packetsOut = bots.map!(b => b.stats.packetsOut).sum;
        text ~= format!("* traffic over the whole run: server to bots %.0f KiB in %s packets, bots to server %.0f KiB in "
            ~ "%s packets (about %.1f KiB/s out of the server during measurement)\n")(bytesIn / 1024.0, packetsIn,
            bytesOut / 1024.0, packetsOut, bytesIn / 1024.0 / (seconds + o.warmup + bots.length / max(1.0, o.ramp)));
    }
    if (sampler.active)
        text ~= format!"* server process: CPU %.1f%% average, %.1f%% max (one core = 100%%); memory %.1f MiB (max %.1f MiB)\n"(
            sampler.averageCpu, sampler.maxCpu, sampler.lastRssKb / 1024.0, sampler.maxRssKb / 1024.0);
    if (o.serverLog.length && window.end != MonoTime.init)
        text ~= serverMetrics(o.serverLog, window);
    return text;
}

/// The server's `metrics:` lines inside the window, and their totals.
private string serverMetrics(string path, Window window)
{
    import std.file : readText;
    import std.regex : matchFirst, regex;
    import std.string : lineSplitter;

    auto pattern = regex(`^(\S+) INFO +metrics: (\d+) ticks, avg ([\d.]+) ms, p99 ([\d.]+) ms, max ([\d.]+) ms; `
        ~ `gc: (\d+) collections, max pause ([\d.]+) ms \(since start\), pauses ([\d.]+) ms, (\d+) KiB allocated`);
    auto worldPattern = regex(`; world: (\d+) players, (\d+) objects(?:, (\d+) ticking)?`);
    ulong maxPlayers, maxObjects, lastTicking;
    bool sawTicking;
    auto loopPattern = regex(`; loop: (\d+) iterations, busy avg ([\d.]+) ms, p99 ([\d.]+) ms, max ([\d.]+) ms`);
    ulong ticks, collections, allocated, iterations;
    double weighted = 0, p99 = 0, worst = 0, pauses = 0, maxPause = 0;
    double busy = 0, loopP99 = 0, loopMax = 0;
    size_t lines;
    foreach (line; readText(path).lineSplitter)
    {
        auto m = matchFirst(line, pattern);
        // A line reports the interval before it, so the first line after the start is the first inside.
        if (m.empty || m[1] <= window.startClock || m[1] > window.endClock)
            continue;
        ++lines;
        const n = m[2].to!ulong;
        ticks += n;
        weighted += m[3].to!double * n;
        p99 = max(p99, m[4].to!double);
        worst = max(worst, m[5].to!double);
        collections += m[6].to!ulong;
        maxPause = max(maxPause, m[7].to!double);
        pauses += m[8].to!double;
        allocated += m[9].to!ulong;
        auto w = matchFirst(line, worldPattern);
        if (!w.empty)
        {
            maxPlayers = max(maxPlayers, w[1].to!ulong);
            maxObjects = max(maxObjects, w[2].to!ulong);
            if (w[3].length)
            {
                lastTicking = w[3].to!ulong;
                sawTicking = true;
            }
        }
        auto l = matchFirst(line, loopPattern);
        if (!l.empty)
        {
            const n2 = l[1].to!ulong;
            iterations += n2;
            busy += l[2].to!double * n2;
            loopP99 = max(loopP99, l[3].to!double);
            loopMax = max(loopMax, l[4].to!double);
        }
    }
    if (lines == 0)
        return "* server metrics: no metrics lines in the window (is metrics_interval_seconds short enough?)\n";
    const measured = (window.end - window.start).total!"msecs";
    const loopText = iterations == 0 ? "" : format!("* server event loop (packets, tick and sending; %s iterations): "
        ~ "busy %.1f%% of the time, avg %.3f ms, worst interval p99 %.2f ms, max %.2f ms\n")(iterations,
        busy / measured * 100, busy / iterations, loopP99, loopMax);
    const worldText = maxObjects == 0 ? "" : format!"* server world: %s players, %s creatures and game objects loaded%s\n"(
        maxPlayers, maxObjects, sawTicking ? format!" (%s ticking at the end)"(lastTicking) : "");
    return worldText ~ loopText ~ format!("* server tick (%s intervals, %s ticks): avg %.3f ms, worst interval p99 %.2f ms, max %.2f ms\n"
        ~ "* server GC: %s collections, %.2f ms paused in total, longest pause since start %.2f ms, "
        ~ "%s KiB allocated (%.0f B/tick)\n")(lines, ticks, weighted / ticks, p99, worst, collections, pauses, maxPause,
        allocated, allocated * 1024.0 / ticks);
}
