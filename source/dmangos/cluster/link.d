/**
 * A connection between two nodes (docs/CLUSTER.md, phase 1), as a `NetSession` on the server's
 * event loop: no thread, no lock.
 *
 * The dialer speaks first with its `Hello`; the other side checks it, through its `LinkOwner`, and
 * answers with its own or with a `Reject`. Once open, every frame carries a sequence number from the
 * sender's `PeerSequences`, which outlive the link: after a reconnect to the same incarnation of a
 * peer the numbers continue, so a frame received twice is recognized and dropped. Heartbeats go out
 * every `heartbeat` and measure the round trip; a link that hears nothing for `failureTimeout` closes.
 *
 * Messages are written straight into the output buffer, which the server takes over (one
 * allocation per batch of messages, not per message), and input is parsed in place.
 */
module dmangos.cluster.link;

import core.time : Duration, MonoTime, usecs;

import dmangos.bytes : ByteWriter;
import dmangos.cluster.protocol;
import dmangos.net.server : NetSession;

/// Sequence numbers between this node and one peer node, kept across that peer's links.
final class PeerSequences
{
    ulong incarnation;   /// the peer incarnation `lastReceived` counts from
    ulong nextSend = 1;
    ulong lastReceived;
    ulong duplicates;    /// frames dropped because they had been received already

    /// A new incarnation of the peer numbers its frames from 1 again.
    void meet(ulong peerIncarnation) pure nothrow @nogc @safe
    {
        if (peerIncarnation != incarnation)
        {
            incarnation = peerIncarnation;
            lastReceived = 0;
        }
    }
}

/// The load a node reports in its heartbeats.
struct LoadReport
{
    uint tickAverageUs;
    uint players;
    uint objects;
}

/// What a link needs from the node it belongs to.
interface LinkOwner
{
    /**
     * The peer's hello (cluster and protocol already checked): `RejectReason.none` and the
     * sequences to use with that peer, or why it is refused.
     */
    RejectReason admit(Link link, const ref Hello hello, out PeerSequences sequences);

    /// The handshake is done.
    void opened(Link link);

    /// A message other than the handshake and heartbeats.
    void received(Link link, MessageType type, const(ubyte)[] payload);

    /// The link is closed, whatever the reason; called once.
    void closed(Link link);
}

/// See the module documentation.
final class Link : NetSession
{
    enum State
    {
        handshaking,
        open,
        closed,
    }

    private
    {
        LinkOwner owner;
        MonoTime delegate() clock;
        const Hello own;
        immutable bool dialed_;
        string address_;
        Duration heartbeat, failureTimeout;

        State state_;
        Hello peer_;
        PeerSequences sequences;

        ubyte[] inbox;          // received bytes not yet a whole frame
        ByteWriter outbox;
        bool closing;
        string closeReason_;

        MonoTime lastReceived, lastHeartbeat;
        MonoTime confirmedAt_;   // the latest heartbeat of ours the peer echoed, on our clock
        LoadReport peerLoad_;    // what the peer's last heartbeat said of its load
        ulong peerSentAt;        // the last heartbeat's `sentAt`, to echo
        MonoTime peerSentSeenAt; // when it arrived
        Duration roundTrip_ = Duration.max;
    }

    /**
     * A link that dialed `address` (it sends `own` at once), or that was accepted from it (it waits
     * for the peer's hello).
     */
    this(LinkOwner owner, MonoTime delegate() clock, const Hello own, bool dialed, string address,
        Duration heartbeat, Duration failureTimeout)
    {
        this.owner = owner;
        this.clock = clock;
        this.own = own;
        this.dialed_ = dialed;
        this.address_ = address;
        this.heartbeat = heartbeat;
        this.failureTimeout = failureTimeout;
        lastReceived = lastHeartbeat = clock();
        if (dialed)
            write(own, 0);
    }

    /// Where the link goes or comes from.
    @property string address() const
    {
        return address_;
    }

    /// Whether this side dialed.
    @property bool dialed() const pure nothrow @nogc @safe
    {
        return dialed_;
    }

    ///
    @property State state() const pure nothrow @nogc @safe
    {
        return state_;
    }

    /// The peer's hello, once open.
    @property ref const(Hello) peer() const pure nothrow @nogc @safe
    {
        return peer_;
    }

    /// The last measured round trip; `Duration.max` before the first.
    @property Duration roundTrip() const pure nothrow @nogc @safe
    {
        return roundTrip_;
    }

    /**
     * When this side sent the latest heartbeat the peer has echoed: the peer was alive and linked
     * to this node after then (what a region lease runs from). `MonoTime.init` before the first.
     */
    @property MonoTime confirmedAt() const pure nothrow @nogc @safe
    {
        return confirmedAt_;
    }

    /// The peer's load, as its last heartbeat reported it.
    @property LoadReport peerLoad() const pure nothrow @nogc @safe
    {
        return peerLoad_;
    }

    /// When the last message arrived.
    @property MonoTime lastHeard() const pure nothrow @nogc @safe
    {
        return lastReceived;
    }

    /// Why the link closed (or is closing); empty if it is not.
    @property string closeReason() const pure nothrow @nogc @safe
    {
        return closeReason_;
    }

    /// Frames from this peer dropped as already received.
    @property ulong duplicates() const pure nothrow @nogc @safe
    {
        return sequences is null ? 0 : sequences.duplicates;
    }

    /// Sends a message on the open link.
    void send(M)(auto ref const M message)
    in (state_ == State.open, "messages wait for the handshake")
    {
        if (!closing)
            write(message, sequences.nextSend++);
    }

    /// Closes the link once what was written has gone out.
    void close(string reason)
    {
        if (closing)
            return;
        closing = true;
        closeReason_ = reason;
    }

    /// Heartbeats and the failure timeout; called every tick.
    void tick(MonoTime now, LoadReport load)
    {
        if (closing || state_ == State.closed)
            return;
        if (now - lastReceived > failureTimeout)
        {
            close(state_ == State.handshaking ? "handshake timed out" : "heartbeats stopped");
            return;
        }
        if (state_ == State.open && now - lastHeartbeat >= heartbeat)
        {
            lastHeartbeat = now;
            const held = peerSentAt ? (now - peerSentSeenAt).total!"usecs" : 0;
            send(Heartbeat(micros(now), peerSentAt, cast(uint) held, load.tickAverageUs, load.players,
                load.objects));
        }
    }

    // NetSession

    void receive(scope const(ubyte)[] data)
    {
        if (closing || state_ == State.closed)
            return;
        inbox ~= data;
        const(ubyte)[] input = inbox;
        FrameHeader header;
        const(ubyte)[] payload;
        try
        {
            while (!closing && takeFrame(input, header, payload))
                handle(header, payload);
        }
        catch (Exception e)
            close("protocol error: " ~ e.msg);
        // Keep the incomplete frame at the front of the same memory.
        const rest = input.length;
        if (rest && input.ptr !is inbox.ptr)
            foreach (i; 0 .. rest)
                inbox[i] = input[i];
        inbox.length = rest;
        () @trusted { inbox.assumeSafeAppend(); }();
    }

    ubyte[] takeOutput()
    {
        // Handed over (the server may keep the array); the next message starts a new buffer.
        return outbox.release();
    }

    @property bool wantsClose() const
    {
        return closing || state_ == State.closed;
    }

    void disconnected()
    {
        if (state_ == State.closed)
            return;
        state_ = State.closed;
        if (closeReason_.length == 0)
            closeReason_ = "connection lost";
        owner.closed(this);
    }

private:
    void write(M)(auto ref const M message, ulong sequence)
    {
        putMessage(outbox, sequence, message);
    }

    void handle(const ref FrameHeader header, const(ubyte)[] payload)
    {
        lastReceived = clock();
        if (state_ == State.handshaking)
            return handshake(header, payload);

        if (header.sequence <= sequences.lastReceived)
        {
            ++sequences.duplicates;
            return;
        }
        sequences.lastReceived = header.sequence;
        switch (header.type)
        {
        case MessageType.heartbeat:
            const beat = decode!Heartbeat(payload);
            const now = clock();
            peerSentAt = beat.sentAt;
            peerSentSeenAt = now;
            peerLoad_ = LoadReport(beat.tickAverageUs, beat.players, beat.objects);
            if (beat.echo)
            {
                const sent = MonoTime.init + usecs(cast(long) beat.echo);
                if (sent > confirmedAt_)
                    confirmedAt_ = sent;
                const rtt = cast(long)(micros(now) - beat.echo) - beat.echoHeld;
                roundTrip_ = usecs(rtt > 0 ? rtt : 0);
            }
            break;
        case MessageType.hello, MessageType.reject:
            close("handshake message on an open link");
            break;
        default:
            owner.received(this, header.type, payload);
        }
    }

    void handshake(const ref FrameHeader header, const(ubyte)[] payload)
    {
        import std.conv : to;

        if (header.type == MessageType.reject)
            return close("refused: " ~ decode!Reject(payload).reason.to!string);
        if (header.type != MessageType.hello)
            return close("expected a hello");
        const hello = decode!Hello(payload);

        RejectReason reason;
        if (hello.cluster != own.cluster)
            reason = RejectReason.wrongCluster;
        else if (hello.protocol != protocolVersion)
            reason = RejectReason.wrongProtocol;
        else if (dialed_ && (own.expected ? hello.nodeId != own.expected : !hello.coordinator))
            reason = RejectReason.unexpectedNode;
        else
            reason = owner.admit(this, hello, sequences);
        if (reason != RejectReason.none)
        {
            if (!dialed_)
                write(Reject(reason), 0);
            return close("refused " ~ hello.address ~ ": " ~ reason.to!string);
        }
        peer_ = hello;
        sequences.meet(hello.incarnation);
        if (!dialed_)
            write(own, 0);
        state_ = State.open;
        owner.opened(this);
    }

    static ulong micros(MonoTime t) pure nothrow @nogc @safe
    {
        return cast(ulong)(t - MonoTime.init).total!"usecs";
    }
}
