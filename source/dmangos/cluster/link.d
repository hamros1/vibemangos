/**
 * A connection between two nodes (docs/CLUSTER.md), as a `NetSession` on the server's
 * event loop: no thread, no lock.
 *
 * The dialer speaks first with its `Hello`; the other side checks it, through its `LinkOwner`, and
 * answers with its own or with a `Reject`. Once open, every message carries a sequence number from the
 * sender's `PeerSequences`, which outlive the link: after a reconnect to the same incarnation of a
 * peer the numbers continue, so a message received twice is recognized and dropped.
 *
 * Delivery is reliable across reconnects. Each side keeps the messages it sent until the peer
 * acknowledges them: every heartbeat says the highest sequence number its sender has received (all
 * below it too). When a link to the same peer incarnation opens again, new messages wait until the
 * peer's first heartbeat says what it has; then everything after that is sent again, in order, before
 * them. A peer that restarted (a new incarnation) starts afresh. If more than `retainLimit` bytes wait
 * for an acknowledgement the oldest are given up and the gap is logged where it shows; a receiver that
 * sees a sequence number skip logs it too (`gaps`).
 *
 * Heartbeats themselves carry no sequence number (0): they go out every `heartbeat`, measure the round
 * trip and acknowledge; a link that hears nothing for `failureTimeout` closes.
 *
 * Messages are written straight into the output buffer, which the server takes over (one
 * allocation per batch of messages, not per message), and input is parsed in place.
 */
module dmangos.cluster.link;

import core.time : Duration, MonoTime, usecs;

import dmangos.bytes : ByteWriter;
import dmangos.cluster.protocol;
import dmangos.net.server : NetSession;

/// How many bytes of unacknowledged messages a node keeps for one peer before giving the oldest up.
enum size_t retainLimit = 64 * 1024 * 1024;

/**
 * Sequence numbers between this node and one peer node, kept across that peer's links, and the
 * messages sent to it that it has not acknowledged yet.
 */
final class PeerSequences
{
    ulong incarnation;   /// the peer incarnation `lastReceived` counts from
    ulong nextSend = 1;
    ulong lastReceived;
    ulong duplicates;    /// frames dropped because they had been received already
    ulong gaps;          /// times a sequence number skipped (messages lost for good)
    ulong resent;        /// messages sent again after a reconnect

    private
    {
        ubyte[] log;           // the unacknowledged frames, back to back, from `head`
        size_t head;
        ulong[] seqs;          // each frame's sequence number ...
        size_t[] ends;         // ... and where it ends in `log`, from `first`
        size_t first;
    }

    /**
     * A new incarnation of the peer numbers its frames from 1 again, and has none of what was sent
     * to the one before.
     */
    void meet(ulong peerIncarnation) pure nothrow @safe
    {
        if (peerIncarnation != incarnation)
        {
            incarnation = peerIncarnation;
            lastReceived = 0;
            forgetAll();
        }
    }

    /// Bytes waiting for an acknowledgement.
    @property size_t retained() const pure nothrow @nogc @safe
    {
        return log.length - head;
    }

    /// Messages waiting for an acknowledgement.
    @property size_t retainedCount() const pure nothrow @nogc @safe
    {
        return seqs.length - first;
    }

    /// A frame just sent, kept until acknowledged; past `retainLimit` the oldest are given up.
    void retain(ulong sequence, const(ubyte)[] frame) pure nothrow @safe
    {
        log ~= frame;
        seqs ~= sequence;
        ends ~= log.length;
        while (retained > retainLimit && first < seqs.length)
            dropFirst();
    }

    /// The peer has received everything up to `sequence`.
    void acknowledged(ulong sequence) pure nothrow @safe
    {
        while (first < seqs.length && seqs[first] <= sequence)
            dropFirst();
        if (first == seqs.length)
            forgetAll();
        else if (head > log.length / 2) // keep the memory in use about what is retained
        {
            const shift = head;
            log = log[head .. $].dup;
            head = 0;
            seqs = seqs[first .. $].dup;
            ends = ends[first .. $].dup;
            first = 0;
            foreach (ref e; ends)
                e -= shift;
        }
    }

    /**
     * The frames retained after `sequence`, back to back, and how many; `complete` is false if some sent
     * after it were given up (`retainLimit`).
     */
    const(ubyte)[] after(ulong sequence, out size_t count, out bool complete) const pure nothrow @nogc @safe
    {
        size_t i = first;
        while (i < seqs.length && seqs[i] <= sequence)
            ++i;
        count = seqs.length - i;
        if (i == seqs.length)
        {
            complete = nextSend <= sequence + 1;
            return null;
        }
        complete = seqs[i] == sequence + 1;
        const start = i == first ? head : ends[i - 1];
        return log[start .. $];
    }

    private void dropFirst() pure nothrow @nogc @safe
    {
        head = ends[first];
        ++first;
    }

    private void forgetAll() pure nothrow @safe
    {
        log.length = 0;
        head = 0;
        seqs.length = 0;
        ends.length = 0;
        first = 0;
        () @trusted { log.assumeSafeAppend(); seqs.assumeSafeAppend(); ends.assumeSafeAppend(); }();
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
        bool resyncing;          // reopened: new messages wait for the peer's first acknowledgement
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
    /// The peer has become the coordinator (the standby took over).
    void markCoordinator() pure nothrow @nogc @safe
    {
        peer_.coordinator = true;
    }

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

    /// Sends a message on the open link (kept until the peer acknowledges it).
    void send(M)(auto ref const M message)
    in (state_ == State.open, "messages wait for the handshake")
    {
        if (closing)
            return;
        const sequence = sequences.nextSend++;
        const start = outbox.length;
        write(message, sequence);
        sequences.retain(sequence, outbox.data[start .. $]);
        if (resyncing) // not yet: it goes out, in order, once the peer says what it has
            outbox.truncate(start);
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
            sendHeartbeat(now, load);
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

    /// A heartbeat: no sequence number, never resent; it acknowledges what has been received.
    void sendHeartbeat(MonoTime now, LoadReport load)
    {
        const held = peerSentAt ? (now - peerSentSeenAt).total!"usecs" : 0;
        write(Heartbeat(micros(now), peerSentAt, cast(uint) held, load.tickAverageUs, load.players, load.objects,
            sequences.lastReceived), 0);
    }

    /// The peer's acknowledgement: what it has is let go; reopened, the rest goes out again first.
    void acknowledge(ulong received)
    {
        import dmangos.log : error, info;

        if (resyncing)
        {
            resyncing = false;
            bool complete;
            size_t count;
            const again = sequences.after(received, count, complete);
            if (!complete)
                error!"cluster: link to %s: messages after %s were given up (over %s MiB unacknowledged); some are lost"(
                    address_, received, retainLimit / (1024 * 1024));
            if (again.length)
            {
                outbox.putBytes(again);
                sequences.resent += count;
                info!"cluster: link to %s reopened: %s message(s) the peer had not received sent (again)"(address_,
                    count);
            }
        }
        sequences.acknowledged(received);
    }

    void handle(const ref FrameHeader header, const(ubyte)[] payload)
    {
        lastReceived = clock();
        if (state_ == State.handshaking)
            return handshake(header, payload);

        if (header.type == MessageType.heartbeat && header.sequence == 0)
            return heartbeatReceived(decode!Heartbeat(payload));
        if (header.sequence <= sequences.lastReceived)
        {
            ++sequences.duplicates;
            return;
        }
        if (header.sequence != sequences.lastReceived + 1)
        {
            import dmangos.log : error;

            ++sequences.gaps;
            error!"cluster: link to %s: messages %s to %s never arrived"(address_, sequences.lastReceived + 1,
                header.sequence - 1);
        }
        sequences.lastReceived = header.sequence;
        switch (header.type)
        {
        case MessageType.heartbeat: // an older peer's sequenced heartbeat
            heartbeatReceived(decode!Heartbeat(payload));
            break;
        case MessageType.hello, MessageType.reject:
            close("handshake message on an open link");
            break;
        default:
            owner.received(this, header.type, payload);
        }
    }

    void heartbeatReceived(const Heartbeat beat)
    {
        {
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
            acknowledge(beat.received);
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
        // What the peer has of ours is not known yet: new messages wait for its acknowledgement, which
        // a heartbeat right away asks for (it answers with its own).
        resyncing = sequences.retainedCount > 0;
        sendHeartbeat(clock(), LoadReport.init);
        owner.opened(this);
    }

    static ulong micros(MonoTime t) pure nothrow @nogc @safe
    {
        return cast(ulong)(t - MonoTime.init).total!"usecs";
    }
}

// Messages lost with a connection arrive after the reconnect, once each and in order, before newer ones.
unittest
{
    import core.time : seconds;

    static final class Owner : LinkOwner
    {
        PeerSequences sequences;
        ulong[] got; // the `sequence` field of each ServiceCall received

        this() { sequences = new PeerSequences; }
        RejectReason admit(Link, const ref Hello, out PeerSequences s) { s = sequences; return RejectReason.none; }
        void opened(Link) {}
        void received(Link, MessageType type, const(ubyte)[] payload)
        {
            if (type == MessageType.serviceCall)
                got ~= decode!ServiceCall(payload).sequence;
        }
        void closed(Link) {}
    }

    auto now = MonoTime.currTime;
    auto clock = () => now;
    auto a = new Owner, b = new Owner;
    const helloA = Hello(protocolVersion, "test", 1, 11, "a:1", "", true, 0);
    const helloB = Hello(protocolVersion, "test", 2, 22, "b:2", "", false, 0);
    Link[2] connect()
    {
        auto dialer = new Link(b, clock, helloB, true, "a:1", 1.seconds, 10.seconds); // B dials the coordinator A
        auto accepted = new Link(a, clock, helloA, false, "b:2", 1.seconds, 10.seconds);
        return [accepted, dialer];
    }
    void pump(Link from, Link to)
    {
        to.receive(from.takeOutput());
    }
    void exchange(Link x, Link y)
    {
        foreach (_; 0 .. 3)
        {
            pump(y, x);
            pump(x, y);
        }
    }
    ServiceCall call(ulong n) { return ServiceCall(1, 1, 1, n, null); }

    auto first = connect();
    exchange(first[0], first[1]);
    assert(first[0].state == Link.State.open && first[1].state == Link.State.open);
    foreach (n; 1 .. 4)
        first[0].send(call(n));
    pump(first[0], first[1]);
    assert(b.got == [1, 2, 3]);
    // 4 and 5 are written, then the connection breaks before they go out.
    first[0].send(call(4));
    first[0].send(call(5));
    first[0].takeOutput(); // lost
    first[0].disconnected();
    first[1].disconnected();

    // Reconnected: 6 is sent before the peer has said what it has; it waits behind 4 and 5.
    auto second = connect();
    pump(second[1], second[0]); // B's hello
    second[0].send(call(6));
    exchange(second[0], second[1]);
    assert(b.got == [1, 2, 3, 4, 5, 6], "the lost ones again, in order, then the new");
    assert(a.sequences.resent == 3 && b.sequences.gaps == 0 && b.sequences.duplicates == 0,
        "4 and 5 again, and 6 that waited behind them");
    // B's heartbeats acknowledge everything: A keeps nothing.
    now += 2.seconds;
    second[1].tick(now, LoadReport.init);
    pump(second[1], second[0]);
    assert(a.sequences.retainedCount == 0);
}
