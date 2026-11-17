/**
 * A single-threaded TCP server built on `select`, shared by the login and
 * world servers.
 *
 * The server only moves bytes. Protocol logic lives in `NetSession`
 * implementations, which never touch a socket and so can be tested without
 * a network. One thread serves every client and nothing needs a lock. If
 * load ever requires it, the loop can switch to epoll/kqueue without
 * touching the sessions.
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

/// A tick slower than this is logged, as Ember's watchdog reports a stalled map loop.
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
        MonoTime lastActivity;
        Duration idleTimeout;
        bool connecting; // an outgoing connection not yet established
        bool broken;

        this(Socket socket, NetSession session, MonoTime now, Duration idleTimeout)
        {
            reuses = cast(ReusesOutput) session;
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

    /// All the loop's busy time since the start; unlike `busy`, never reset (cluster balancing, phase 6).
    Duration busyTotal;

    private ServerOptions options;
    private Maintenance maintenance;
    private Listener[] listeners;
    private Dial[] dials;
    private Connection[] connections;

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
    void run()
    {
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

        auto readable = new SocketSet;
        auto writable = new SocketSet;
        auto lastMaintenance = MonoTime.currTime;

        while (!atomicLoad(shutdownRequested) || (mayStop !is null && !mayStop()))
        {
            startDials(MonoTime.currTime);
            readable.reset();
            writable.reset();
            foreach (ref listener; listeners)
                readable.add(listener.socket);
            foreach (connection; connections)
            {
                readable.add(connection.socket);
                if (connection.pending.length > 0 || connection.connecting)
                    writable.add(connection.socket);
            }

            // Returns -1 when a signal interrupts the wait; the loop condition then sees the shutdown flag.
            immutable wait = options.tickInterval - (MonoTime.currTime - lastMaintenance);
            immutable ready = Socket.select(readable, writable, null, wait > Duration.zero ? wait : Duration.zero);
            immutable now = MonoTime.currTime;
            if (ready > 0)
            {
                foreach (connection; connections)
                {
                    if (connection.connecting)
                    {
                        if (writable.isSet(connection.socket) || readable.isSet(connection.socket))
                            established(connection, now);
                        continue;
                    }
                    if (readable.isSet(connection.socket))
                        receiveFrom(connection, now);
                    if (!connection.broken && writable.isSet(connection.socket))
                        flush(connection);
                }
                // Accept last, so new sockets are never tested against sets they were not added to.
                foreach (ref listener; listeners)
                    if (readable.isSet(listener.socket))
                        accept(listener, now);
            }

            immutable received = MonoTime.currTime;
            if (maintenance !is null && now - lastMaintenance >= options.tickInterval)
            {
                lastMaintenance = now;
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
                }
            reap(now);
            immutable finished = MonoTime.currTime;
            busy.record(finished - now);
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
            collectOutput(connection);
            connections ~= connection;
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
        ubyte[4096] buffer = void;
        immutable received = connection.socket.receive(buffer[]);
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
            close(connection);
            connections[i] = connections[$ - 1];
            connections.length -= 1;
            connections.assumeSafeAppend(); // reuse the array's memory for future connections
        }
    }

    void closeAll()
    {
        foreach (connection; connections)
            close(connection);
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
