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
import core.time : Duration, MonoTime, seconds;
import std.socket;

import dmangos.log;

/// One client's protocol state, driven by the server.
interface NetSession
{
    /// Bytes received from the client.
    void receive(scope const(ubyte)[] data);

    /// Bytes to send to the client; the session forgets them.
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
}

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

    private static final class Connection
    {
        Socket socket;
        NetSession session;
        ubyte[] pending; // output not yet accepted by the kernel
        MonoTime lastActivity;
        bool broken;

        this(Socket socket, NetSession session, MonoTime now)
        {
            this.socket = socket;
            this.session = session;
            this.lastActivity = now;
        }
    }

    private ServerOptions options;
    private SessionFactory createSession;
    private Maintenance maintenance;
    private Connection[] connections;

    ///
    this(ServerOptions options, SessionFactory createSession, Maintenance maintenance = null)
    in (createSession !is null)
    in (options.maxConnections > 0)
    {
        this.options = options;
        this.createSession = createSession;
        this.maintenance = maintenance;
    }

    /// Number of open connections.
    @property size_t connectionCount() const
    {
        return connections.length;
    }

    /// Serves clients until `requestShutdown` is called.
    void run()
    {
        auto address = getAddress(options.bindAddress, options.port)[0];
        auto listener = new TcpSocket(address.addressFamily);
        scope (exit)
            listener.close();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(address);
        listener.listen(128);
        listener.blocking = false;
        info!"listening on %s"(address.toString);

        scope (exit)
            closeAll();

        auto readable = new SocketSet;
        auto writable = new SocketSet;
        auto lastMaintenance = MonoTime.currTime;

        while (!atomicLoad(shutdownRequested))
        {
            readable.reset();
            writable.reset();
            readable.add(listener);
            foreach (connection; connections)
            {
                readable.add(connection.socket);
                if (connection.pending.length > 0)
                    writable.add(connection.socket);
            }

            // Returns -1 when a signal interrupts the wait; the loop condition then sees the shutdown flag.
            immutable ready = Socket.select(readable, writable, null, 1.seconds);
            immutable now = MonoTime.currTime;
            if (ready > 0)
            {
                foreach (connection; connections)
                {
                    if (readable.isSet(connection.socket))
                        receiveFrom(connection, now);
                    if (!connection.broken && writable.isSet(connection.socket))
                        flush(connection);
                }
                // Accept last, so new sockets are never tested against sets they were not added to.
                if (readable.isSet(listener))
                    accept(listener, now);
            }

            reap(now);
            if (maintenance !is null && now - lastMaintenance >= 1.seconds)
            {
                lastMaintenance = now;
                try
                    maintenance(now);
                catch (Exception e)
                    error!"periodic maintenance failed: %s"(e.msg);
            }
        }
        info!"shutting down, closing %s connection(s)"(connections.length);
    }

private:
    void accept(Socket listener, MonoTime now)
    {
        Socket client;
        try
            client = listener.accept();
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
        auto connection = new Connection(client, createSession(remote), now);
        connections ~= connection;
        // Some protocols speak first (the world server's SMSG_AUTH_CHALLENGE).
        connection.pending ~= connection.session.takeOutput();
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
        connection.pending ~= connection.session.takeOutput();
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
    }

    /// Closes connections that broke, finished, or went idle.
    void reap(MonoTime now)
    {
        size_t i = 0;
        while (i < connections.length)
        {
            auto connection = connections[i];
            immutable finished = connection.session.wantsClose && connection.pending.length == 0;
            immutable idle = now - connection.lastActivity > options.idleTimeout;
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
