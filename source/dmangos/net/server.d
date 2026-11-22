/**
 * A single-threaded TCP server, shared by the login and world servers. It waits on epoll on Linux
 * (the cost of a wait follows the sockets that are ready, not all of them) and on `select`
 * elsewhere (`Poller`).
 *
 * The server only moves bytes. Protocol logic lives in `NetSession`
 * implementations, which never touch a socket and so can be tested without
 * a network. One thread serves every client and nothing needs a lock.
 */
module dmangos.net.server;

import core.atomic : atomicLoad, atomicStore;
import core.time : Duration, MonoTime, msecs, seconds;
import std.socket;

import dmangos.log;
import dmangos.metrics : TickStats;

/**
 * A session that takes back the arrays its `takeOutput` handed over, once the server has sent them
 * (docs/DESIGN.md, step 5): it writes its next output into one, instead of growing a new array each
 * time. The server gives an array back only when nothing of it is still waiting to be sent.
 */
interface ReusesOutput
{
    /// `buffer` (one `takeOutput` returned) is free again.
    void returnOutput(ubyte[] buffer);
}

/**
 * A session whose unsent output is bounded: a client that does not read (or reads too slowly) is
 * disconnected once this much waits to be sent, rather than holding ever more memory.
 */
interface BoundedOutput
{
    /// The most bytes that may wait to be sent; 0 for no bound.
    @property size_t outputLimit() const;
}

/** A session that combines traffic for many clients and needs larger reads per poll. */
interface BulkInput
{
}

/// One client's protocol state, driven by the server.
interface NetSession
{
    /// Bytes received from the client.
    void receive(scope const(ubyte)[] data);

    /**
     * Bytes to send to the client. The array is handed over: the server may keep it as its send
     * buffer, so the session must not write into it again.
     */
    ubyte[] takeOutput();

    /// True once the connection should close (after pending output is flushed).
    @property bool wantsClose() const;

    /// The client's address.
    @property string address() const;

    /// Called once, after the connection has been closed for whatever reason.
    void disconnected();
}

/// Where to listen and how many clients to serve.
struct ServerOptions
{
    string bindAddress = "0.0.0.0";
    ushort port;
    Duration idleTimeout = 60.seconds;
    uint maxConnections = 512;
    /// How often the maintenance callback runs: the world server's update tick.
    Duration tickInterval = 1.seconds;
}

/**
 * The most connections one server may be configured for: epoll has no limit of its own (the process's
 * open files are raised to their hard limit at start, `raiseFileLimit`); `select` cannot watch
 * descriptors past FD_SETSIZE (1024).
 */
version (linux)
    enum uint connectionLimit = 60_000;
else
    enum uint connectionLimit = 1000;

/**
 * Raises the process's limit of open files to its hard limit (a service is often started with a soft
 * limit of 1024), and warns if that is still under `wanted`.
 */
void raiseFileLimit(size_t wanted)
{
    version (Posix)
    {
        import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_NOFILE, setrlimit;

        rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) != 0)
            return;
        if (limit.rlim_cur < limit.rlim_max)
        {
            limit.rlim_cur = limit.rlim_max;
            setrlimit(RLIMIT_NOFILE, &limit);
            getrlimit(RLIMIT_NOFILE, &limit);
        }
        if (limit.rlim_cur < wanted)
            warning!"the process may open only %s files, fewer than max_connections (%s) and its other files need"(
                limit.rlim_cur, wanted);
    }
}

/// A tick slower than this is logged, as a sign of a stalled update loop.
private enum slowTick = 500.msecs;

private shared bool shutdownRequested;

/// Asks a running server to stop. Safe to call from a signal handler.
void requestShutdown() nothrow @nogc @safe
{
    atomicStore(shutdownRequested, true);
}

/// Makes SIGINT and SIGTERM stop the server, and stops a vanished client's SIGPIPE from killing the process.
void installShutdownHandlers()
{
    import core.stdc.signal : signal, SIGINT, SIGTERM;

    signal(SIGINT, &onTerminate);
    signal(SIGTERM, &onTerminate);
    version (Posix)
    {
        import core.stdc.signal : SIG_IGN;
        import core.sys.posix.signal : SIGPIPE;

        signal(SIGPIPE, SIG_IGN);
    }
}

private extern (C) void onTerminate(int) nothrow @nogc @system
{
    requestShutdown();
}

/// Accepts connections and runs a `NetSession` for each.
final class TcpServer
{
    /// Creates the session for a newly accepted client.
    alias SessionFactory = NetSession delegate(string remoteAddress);

    /// Called about once a second with the current time, for periodic work.
    alias Maintenance = void delegate(MonoTime now);

    /**
     * Once a stop is asked for, asked each loop iteration whether the server may stop now; the loop
     * goes on until it says so (a cluster node handing its work over first). Null: stop at once.
     */
    bool delegate() mayStop;

    private static final class Connection
    {
        Socket socket;
        NetSession session;
        ubyte[] pending; // output not yet accepted by the kernel
        ubyte[] adopted; // the session's array `pending` was taken from, to give back once sent
        ReusesOutput reuses; // the session, if it takes its arrays back
        BoundedOutput bounded; // the session, if its unsent output has a limit
        MonoTime lastActivity;
        Duration idleTimeout;
        bool bulkInput;
        bool connecting; // an outgoing connection not yet established
        bool broken;
        bool writeWatched; // the poller reports it writable

        this(Socket socket, NetSession session, MonoTime now, Duration idleTimeout)
        {
            reuses = cast(ReusesOutput) session;
            bounded = cast(BoundedOutput) session;
            bulkInput = cast(BulkInput) session !is null;
            this.socket = socket;
            this.session = session;
            this.lastActivity = now;
            this.idleTimeout = idleTimeout;
        }
    }

    /// A port connections are accepted on, and what serves them.
    private static struct Listener
    {
        string bindAddress;
        ushort port;
        SessionFactory createSession;
        Duration idleTimeout;
        Socket socket;
    }

    /// An outgoing connection asked for, opened at the top of the next loop.
    private static struct Dial
    {
        string host;
        ushort port;
        NetSession session;
        Duration idleTimeout;
    }

    /**
     * The time each loop iteration spent working (from the wait returning to the next wait):
     * packets, the maintenance tick and sending. Its worst case is the longest any client waited
     * on the server. Whoever reports it resets it.
     */
    TickStats busy;

    /// All the loop's busy time since the start; unlike `busy`, never reset (cluster balancing).
    Duration busyTotal;

    private ServerOptions options;
    private Maintenance maintenance;
    private Listener[] listeners;
    private Dial[] dials;
    private Connection[] connections;
    private Poller poller;

    // A poller key: a connection's address, or a listener's index with the top bit set (no user-space
    // address has it).
    private enum ulong listenerFlag = 1UL << 63;
    private static ulong listenerKey(size_t i) { return listenerFlag | i; }
    private static bool isListenerKey(ulong key) { return (key & listenerFlag) != 0; }
    private static ulong keyOf(Connection c) { return cast(ulong) cast(void*) c; }

    ///
    this(ServerOptions options, SessionFactory createSession, Maintenance maintenance = null)
    in (createSession !is null)
    in (options.maxConnections > 0)
    {
        this.options = options;
        this.maintenance = maintenance;
        if (options.port != 0) // port 0: no client port (a cluster member before it serves clients)
            listeners ~= Listener(options.bindAddress, options.port, createSession, options.idleTimeout);
    }

    /**
     * Also accepts connections on `bindAddress:port`, served by sessions from `createSession` (the
     * cluster port). Call before `run`.
     */
    void addListener(string bindAddress, ushort port, SessionFactory createSession, Duration idleTimeout)
    in (createSession !is null)
    {
        listeners ~= Listener(bindAddress, port, createSession, idleTimeout);
    }

    /**
     * Opens a connection to `host:port` for `session`, without blocking: it starts at the top of the
     * next loop, and the session's first output goes out once it is established. If it cannot be
     * made, or breaks later, the session gets `disconnected` as an accepted one would.
     */
    void connect(string host, ushort port, NetSession session, Duration idleTimeout)
    {
        dials ~= Dial(host, port, session, idleTimeout);
    }

    /// Number of open connections.
    @property size_t connectionCount() const
    {
        return connections.length;
    }

    /// Serves clients until `requestShutdown` is called.
    void run(void delegate() cooperate = null)
    {
        raiseFileLimit(options.maxConnections + 64); // and the listeners, the database, the map files
        foreach (ref listener; listeners)
        {
            auto address = getAddress(listener.bindAddress, listener.port)[0];
            listener.socket = new TcpSocket(address.addressFamily);
            listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
            listener.socket.bind(address);
            listener.socket.listen(128);
            listener.socket.blocking = false;
            info!"listening on %s"(address.toString);
        }
        scope (exit)
            foreach (ref listener; listeners)
                listener.socket.close();

        scope (exit)
            closeAll();

        poller = Poller(listeners.length);
        foreach (i, ref listener; listeners)
            poller.add(listener.socket.handle, listenerKey(i), false);
        auto lastMaintenance = MonoTime.currTime;

        while (!atomicLoad(shutdownRequested) || (mayStop !is null && !mayStop()))
        {
            startDials(MonoTime.currTime);

            // Returns nothing when a signal interrupts the wait; the loop condition then sees the shutdown flag.
            immutable wait = options.tickInterval - (MonoTime.currTime - lastMaintenance);
            auto ready = poller.wait(cooperate is null && wait > Duration.zero ? wait : Duration.zero);
            immutable now = MonoTime.currTime;
            foreach (event; ready)
            {
                if (isListenerKey(event.key))
                {
                    accept(listeners[cast(size_t)(event.key & ~listenerFlag)], now);
                    continue;
                }
                auto connection = cast(Connection) cast(void*) event.key;
                if (connection.broken)
                    continue;
                if (connection.connecting)
                {
                    established(connection, now);
                    continue;
                }
                if (event.readable)
                    receiveFrom(connection, now);
                if (!connection.broken && event.writable)
                    flush(connection);
            }

            immutable received = MonoTime.currTime;
            if (now - lastMaintenance >= options.tickInterval)
            {
                lastMaintenance = now;
                if (maintenance !is null)
                    try
                        maintenance(now);
                    catch (Exception e)
                        error!"periodic maintenance failed: %s"(e.msg);
            }
            immutable ticked = MonoTime.currTime;
            // A session may have been given packets by another one (a chat message, a move it sees) or by the
            // maintenance: send them now, not when its own client next sends something.
            foreach (connection; connections)
                if (!connection.broken)
                {
                    collectOutput(connection);
                    if (connection.pending.length && !connection.connecting)
                        flush(connection);
                    // Told when it can take more, while output waits (or a connection is being made).
                    const want = connection.pending.length > 0 || connection.connecting;
                    if (want != connection.writeWatched)
                    {
                        connection.writeWatched = want;
                        poller.watchWrite(connection.socket.handle, keyOf(connection), want);
                    }
                }
            reap(now);
            immutable finished = MonoTime.currTime;
            busy.record(finished - now);
            if (cooperate !is null) cooperate();
            busyTotal += finished - now;
            if (finished - now > slowTick)
                warning!"a loop iteration took %s ms: %s receiving, %s in the tick, %s sending (%s connections)"(
                    (finished - now).total!"msecs", (received - now).total!"msecs", (ticked - received).total!"msecs",
                    (finished - ticked).total!"msecs", connections.length);
        }
        info!"shutting down, closing %s connection(s)"(connections.length);
    }

private:
    /// The session's new output joins what is waiting to be sent; adopted, not copied, when nothing is.
    static void collectOutput(Connection connection)
    {
        auto output = connection.session.takeOutput();
        if (output.length == 0)
            return;
        if (connection.pending.length == 0)
        {
            connection.pending = output;
            connection.adopted = output;
        }
        else
        {
            connection.pending ~= output;
            if (connection.reuses !is null)
                connection.reuses.returnOutput(output); // copied: free at once
        }
        if (connection.bounded !is null)
        {
            const limit = connection.bounded.outputLimit;
            if (limit && connection.pending.length > limit && !connection.broken)
            {
                warning!"%s: %s KiB waiting to be sent (more than %s KiB): the client is not reading; disconnected"(
                    connection.session.address, connection.pending.length / 1024, limit / 1024);
                connection.broken = true;
            }
        }
    }

    void accept(ref Listener listener, MonoTime now)
    {
        Socket client;
        try
            client = listener.socket.accept();
        catch (SocketAcceptException e)
        {
            verbose!"accept failed: %s"(e.msg);
            return;
        }

        immutable remote = describe(client);
        if (connections.length >= options.maxConnections)
        {
            warning!"connection limit (%s) reached, refusing %s"(options.maxConnections, remote);
            client.close();
            return;
        }

        client.blocking = false;
        client.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
        verbose!"%s: connected"(remote);
        auto connection = new Connection(client, listener.createSession(remote), now, listener.idleTimeout);
        connections ~= connection;
        poller.add(client.handle, keyOf(connection), false);
        // Some protocols speak first (the world server's SMSG_AUTH_CHALLENGE).
        collectOutput(connection);
        flush(connection);
    }

    /// Starts the outgoing connections asked for since the last loop.
    void startDials(MonoTime now)
    {
        foreach (dial; dials)
        {
            Socket socket;
            try
            {
                auto address = getAddress(dial.host, dial.port)[0];
                socket = new TcpSocket(address.addressFamily);
                socket.blocking = false;
                socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, true);
                socket.connect(address); // returns at once; `established` sees how it went
            }
            catch (Exception e)
            {
                verbose!"connecting to %s:%s failed: %s"(dial.host, dial.port, e.msg);
                if (socket !is null)
                    socket.close();
                try
                    dial.session.disconnected();
                catch (Exception e2)
                    error!"%s: cleanup failed: %s"(dial.session.address, e2.msg);
                continue;
            }
            auto connection = new Connection(socket, dial.session, now, dial.idleTimeout);
            connection.connecting = true;
            connection.writeWatched = true; // writable once connected
            collectOutput(connection);
            connections ~= connection;
            poller.add(socket.handle, keyOf(connection), true);
        }
        dials.length = 0;
        dials.assumeSafeAppend();
    }

    /// An outgoing connection finished connecting, or failed to.
    void established(Connection connection, MonoTime now)
    {
        int error;
        connection.socket.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, error);
        if (error != 0)
        {
            verbose!"%s: connection failed (error %s)"(connection.session.address, error);
            connection.broken = true;
            return;
        }
        connection.connecting = false;
        connection.lastActivity = now;
        verbose!"%s: connected"(connection.session.address);
        flush(connection);
    }

    void receiveFrom(Connection connection, MonoTime now)
    {
        // The whole loop runs between reads. A cluster peer can carry hundreds of clients on
        // one socket, so give it a larger allowance while keeping one read per ready socket.
        ubyte[64 * 1024] buffer = void;
        const limit = connection.bulkInput ? buffer.length : 4096;
        immutable received = connection.socket.receive(buffer[0 .. limit]);
        if (received == 0)
        {
            connection.broken = true; // orderly shutdown by the peer
            return;
        }
        if (received == Socket.ERROR)
        {
            if (!wouldHaveBlocked())
                connection.broken = true;
            return;
        }

        connection.lastActivity = now;
        try
            connection.session.receive(buffer[0 .. cast(size_t) received]);
        catch (Exception e)
        {
            error!"%s: session failed: %s"(connection.session.address, e.msg);
            connection.broken = true;
            return;
        }
        collectOutput(connection);
        flush(connection);
    }

    void flush(Connection connection)
    {
        while (connection.pending.length > 0)
        {
            immutable sent = connection.socket.send(connection.pending);
            if (sent == Socket.ERROR)
            {
                if (!wouldHaveBlocked())
                    connection.broken = true;
                return;
            }
            connection.pending = connection.pending[cast(size_t) sent .. $];
        }
        connection.pending = null;
        if (connection.adopted !is null)
        {
            if (connection.reuses !is null)
                connection.reuses.returnOutput(connection.adopted);
            connection.adopted = null;
        }
    }

    /// Closes connections that broke, finished, or went idle.
    void reap(MonoTime now)
    {
        size_t i = 0;
        while (i < connections.length)
        {
            auto connection = connections[i];
            immutable finished = connection.session.wantsClose && connection.pending.length == 0;
            immutable idle = now - connection.lastActivity > connection.idleTimeout;
            if (!connection.broken && !finished && !idle)
            {
                ++i;
                continue;
            }

            verbose!"%s: disconnected%s"(connection.session.address, idle ? " (idle)" : "");
            poller.remove(connection.socket.handle);
            close(connection);
            connections[i] = connections[$ - 1];
            connections.length -= 1;
            connections.assumeSafeAppend(); // reuse the array's memory for future connections
        }
    }

    void closeAll()
    {
        foreach (connection; connections)
        {
            poller.remove(connection.socket.handle);
            close(connection);
        }
        connections = null;
    }

    static void close(Connection connection)
    {
        connection.socket.shutdown(SocketShutdown.BOTH);
        connection.socket.close();
        try
            connection.session.disconnected();
        catch (Exception e)
            error!"%s: cleanup failed: %s"(connection.session.address, e.msg);
    }

    static string describe(Socket socket)
    {
        string address = "unknown";
        try
            address = socket.remoteAddress.toAddrString;
        catch (Exception)
        {
        }
        return address;
    }
}

// The same ready event passes a larger batch to a peer and leaves the player read limit in place.
unittest
{
    static class Receiver : NetSession
    {
        size_t received;
        void receive(scope const(ubyte)[] data) { received += data.length; }
        ubyte[] takeOutput() { return null; }
        @property bool wantsClose() const { return false; }
        @property string address() const { return "test"; }
        void disconnected() {}
    }

    static final class Peer : Receiver, BulkInput {}

    auto server = new TcpServer(ServerOptions.init, (string) => null);
    foreach (i, session; [new Receiver, cast(Receiver) new Peer])
    {
        auto pair = socketPair();
        scope (exit)
            foreach (socket; pair)
                socket.close();
        ubyte[16 * 1024] input;
        assert(pair[1].send(input[]) == input.length);
        const now = MonoTime.currTime;
        auto connection = new TcpServer.Connection(pair[0], session, now, 60.seconds);
        server.receiveFrom(connection, now);
        assert(session.received == (i == 0 ? 4096 : input.length));
    }
}

/// A socket the poller reports, by the key it was added with.
struct Ready
{
    ulong key;
    bool readable; /// data, a connection to accept, the peer gone, or an error
    bool writable;
}

version (linux)
{
    /**
     * Waits for sockets with epoll (level-triggered): readiness for reading always, for writing while
     * asked (`watchWrite`). A closed socket leaves epoll by itself; `remove` takes it out first anyway.
     */
    struct Poller
    {
        import core.sys.linux.epoll : EPOLL_CLOEXEC, EPOLL_CTL_ADD, EPOLL_CTL_DEL, EPOLL_CTL_MOD, epoll_create1,
            epoll_ctl, epoll_event, epoll_wait, EPOLLERR, EPOLLHUP, EPOLLIN, EPOLLOUT;
        import core.sys.posix.unistd : closeFd = close;

        private int fd = -1;
        private epoll_event[] events;
        private Ready[] ready;

        this(size_t)
        {
            fd = epoll_create1(EPOLL_CLOEXEC);
            if (fd < 0)
                throw new SocketOSException("epoll_create1 failed");
            events = new epoll_event[256];
        }

        @disable this(this);

        ~this()
        {
            if (fd >= 0)
                closeFd(fd);
        }

        void add(socket_t socket, ulong key, bool write)
        {
            control(EPOLL_CTL_ADD, socket, key, write);
        }

        void watchWrite(socket_t socket, ulong key, bool write)
        {
            control(EPOLL_CTL_MOD, socket, key, write);
        }

        void remove(socket_t socket)
        {
            epoll_event none;
            epoll_ctl(fd, EPOLL_CTL_DEL, socket, &none); // already gone if closed: no matter
        }

        /// The sockets ready within `timeout` (none if a signal came first). Valid until the next call.
        Ready[] wait(Duration timeout)
        {
            // Rounded up to whole milliseconds, so a wait shorter than one does not spin.
            const ms = cast(int)((timeout.total!"usecs" + 999) / 1000);
            const n = epoll_wait(fd, events.ptr, cast(int) events.length, ms);
            ready.length = 0;
            ready.assumeSafeAppend();
            if (n <= 0)
                return ready;
            foreach (ref e; events[0 .. n])
                ready ~= Ready(e.data.u64, (e.events & (EPOLLIN | EPOLLERR | EPOLLHUP)) != 0,
                    (e.events & (EPOLLOUT | EPOLLERR | EPOLLHUP)) != 0);
            if (n == events.length)
                events.length *= 2; // more were ready than fit: room for them next time
            return ready;
        }

        private void control(int op, socket_t socket, ulong key, bool write)
        {
            epoll_event e;
            e.events = EPOLLIN | (write ? EPOLLOUT : 0);
            e.data.u64 = key;
            if (epoll_ctl(fd, op, socket, &e) != 0)
                throw new SocketOSException("epoll_ctl failed");
        }
    }
}
else
{
    /// Waits for sockets with `select`, where epoll is not there.
    struct Poller
    {
        private static struct Watched
        {
            socket_t socket;
            ulong key;
            bool write;
        }

        private Watched[] watched;
        private SocketSet readable, writable;
        private Ready[] ready;

        this(size_t)
        {
            readable = new SocketSet;
            writable = new SocketSet;
        }

        void add(socket_t socket, ulong key, bool write)
        {
            watched ~= Watched(socket, key, write);
        }

        void watchWrite(socket_t socket, ulong key, bool write)
        {
            foreach (ref w; watched)
                if (w.socket == socket)
                    w.write = write;
        }

        void remove(socket_t socket)
        {
            foreach (i, ref w; watched)
                if (w.socket == socket)
                {
                    watched[i] = watched[$ - 1];
                    watched.length -= 1;
                    return;
                }
        }

        Ready[] wait(Duration timeout)
        {
            readable.reset();
            writable.reset();
            foreach (ref w; watched)
            {
                readable.add(w.socket);
                if (w.write)
                    writable.add(w.socket);
            }
            ready.length = 0;
            ready.assumeSafeAppend();
            if (Socket.select(readable, writable, null, timeout) <= 0)
                return ready;
            foreach (ref w; watched)
            {
                const r = readable.isSet(w.socket) != 0, wr = w.write && writable.isSet(w.socket) != 0;
                if (r || wr)
                    ready ~= Ready(w.key, r, wr);
            }
            return ready;
        }
    }
}

// The poller reports a socket with data, and one that can be written to only while asked.
unittest
{
    auto pair = socketPair();
    scope (exit)
    {
        pair[0].close();
        pair[1].close();
    }
    auto poller = Poller(1);
    poller.add(pair[0].handle, 7, false);
    assert(poller.wait(Duration.zero).length == 0, "nothing to read, writability not asked");
    poller.watchWrite(pair[0].handle, 7, true);
    auto ready = poller.wait(Duration.zero);
    assert(ready.length == 1 && ready[0].key == 7 && ready[0].writable && !ready[0].readable);
    poller.watchWrite(pair[0].handle, 7, false);
    pair[1].send(cast(const(ubyte)[]) "x");
    ready = poller.wait(10.msecs);
    assert(ready.length == 1 && ready[0].readable && !ready[0].writable);
    poller.remove(pair[0].handle);
    assert(poller.wait(Duration.zero).length == 0);
}

// A client that does not read: its unsent output grows to its session's limit, and it is cut off.
unittest
{
    static final class Talkative : NetSession, BoundedOutput
    {
        void receive(scope const(ubyte)[]) {}
        ubyte[] takeOutput() { return new ubyte[1000]; }
        @property bool wantsClose() const { return false; }
        @property string address() const { return "test"; }
        void disconnected() {}
        @property size_t outputLimit() const { return 2500; }
    }

    auto connection = new TcpServer.Connection(null, new Talkative, MonoTime.currTime, 60.seconds);
    TcpServer.collectOutput(connection);
    TcpServer.collectOutput(connection);
    assert(!connection.broken && connection.pending.length == 2000);
    TcpServer.collectOutput(connection);
    assert(connection.broken, "over its limit: disconnected");
}
