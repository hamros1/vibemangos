/**
 * Cluster services (docs/SERVICES.md): logical responsibilities with an identity, placed on nodes and
 * called by what they are, wherever they run.
 *
 * A service is a struct marked `@Service(kind)`. Its methods marked `@Call` are what it can be asked:
 * each takes one plain-data request (`dmangos.plaindata`) and returns a plain-data reply, or nothing.
 * It may also have `tick(Duration)` (its host's world tick), `start()` and `stop()`.
 *
 * ---
 * @Service(ServiceKind.example)
 * struct Counter
 * {
 *     uint total;
 *     @Call uint add(const ref Add request) { return total += request.amount; }
 * }
 * host.host(Counter());
 * host.call!(Counter.add)(Add(5), (uint total) { ... });
 * ---
 *
 * Everything about a service's calls is worked out at compile time (`static foreach` over its
 * `@Call` methods): each call's id, a fingerprint of its name and its request's and reply's layout
 * (`callId`), and the dispatcher that runs a call from bytes (`Hosted.dispatch`). A call to a service
 * on this node is a direct method call with the request struct: nothing is encoded. A call to one on
 * another node goes as bytes over the cluster's links (stage 3); its reply comes back the same way.
 * Either way the caller's continuation gets the reply, so callers do not care where the service is.
 */
module dmangos.cluster.services;

import core.time : Duration;
import std.meta : AliasSeq;
import std.traits : getUDAs, hasUDA, Parameters, ReturnType, Unqual;

import dmangos.plaindata : decode, encode, isPlainData, layout;

/// The kinds of service there are.
enum ServiceKind : ushort
{
    none = 0,
    channels = 1,           /// chat channels (`dmangos.world.channelservice`)
    battlegroundQueue = 2,  /// the battleground queues
    example = 0xFFFF,       /// for tests
}

/// Marks a struct as a service of `kind`.
struct Service
{
    ServiceKind kind;
}

/// Marks a service's method as a call it answers.
struct Call
{
}

/// The kind of service `S` is.
template kindOf(S)
{
    static assert(hasUDA!(S, Service), S.stringof ~ " is not marked @Service");
    enum kindOf = getUDAs!(S, Service)[0].kind;
}

/// The names of `S`'s `@Call` methods.
template callNames(S)
{
    alias callNames = AliasSeq!();
    static foreach (name; __traits(allMembers, S))
        static if (__traits(compiles, __traits(getMember, S, name)))
            static foreach (overload; __traits(getOverloads, S, name))
                static if (hasUDA!(overload, Call))
                    callNames = AliasSeq!(callNames, name);
}

/// Checks a call's shape: one plain-data request, a plain-data reply or none.
private template checkCall(alias method)
{
    alias P = Parameters!method;
    static assert(P.length == 1, __traits(identifier, method) ~ ": a call takes one request");
    static assert(isPlainData!(P[0]), __traits(identifier, method) ~ ": its request must be plain data");
    static assert(is(ReturnType!method == void) || isPlainData!(ReturnType!method),
        __traits(identifier, method) ~ ": its reply must be plain data or nothing");
    enum checkCall = true;
}

/**
 * A call's id: the FNV-1a hash of its service kind, its name and the layouts of its request and reply.
 * Two builds that disagree on any of them disagree on the id, and a call between them is refused
 * rather than misread.
 */
template callId(alias method)
{
    static assert(checkCall!method);
    enum callId = () {
        alias S = __traits(parent, method);
        string text = kindOf!S.stringof ~ "." ~ __traits(identifier, method) ~ "(" ~ layout!(Parameters!method[0]) ~ ")";
        static if (!is(ReturnType!method == void))
            text ~= layout!(ReturnType!method);
        ulong hash = 0xcbf29ce484222325;
        foreach (c; text)
        {
            hash ^= c;
            hash *= 0x100000001b3;
        }
        return hash;
    }();
}

/// A service as its host runs it.
interface HostedService
{
    /// Its kind.
    @property ServiceKind kind() const;

    /// Its host's world tick.
    void tick(Duration elapsed);

    /// It is released (moved, or the node stops).
    void stop();

    /**
     * Runs the call `id` from its request's bytes, and writes its reply's (none for a call without
     * one). False if the service has no such call (another build's).
     */
    bool dispatch(ulong id, const(ubyte)[] request, ref ubyte[] reply);
}

/// The host's box around a service of type `S`.
final class Hosted(S) : HostedService
{
    /// The service.
    S service;

    ///
    this(S service)
    {
        this.service = service;
        static if (__traits(hasMember, S, "start"))
            this.service.start();
    }

    @property ServiceKind kind() const
    {
        return kindOf!S;
    }

    void tick(Duration elapsed)
    {
        static if (__traits(hasMember, S, "tick"))
            service.tick(elapsed);
    }

    void stop()
    {
        static if (__traits(hasMember, S, "stop"))
            service.stop();
    }

    bool dispatch(ulong id, const(ubyte)[] request, ref ubyte[] reply)
    {
        static foreach (name; callNames!S)
        {{
            alias method = __traits(getMember, S, name);
            if (id == callId!method)
            {
                Unqual!(Parameters!method[0]) req;
                decode(request, req);
                static if (is(ReturnType!method == void))
                    __traits(getMember, service, name)(req);
                else
                {
                    auto result = __traits(getMember, service, name)(req);
                    encode(reply, result);
                }
                return true;
            }
        }}
        return false;
    }
}

/**
 * The services of a node: those it hosts, and where the others are (`docs/SERVICES.md`). A
 * standalone server hosts every service; in a cluster the coordinator's service table places them.
 */
final class ServiceHost
{
    private HostedService[ServiceKind] hosted;

    /// Hosts `service` here, from now on; calls to its kind run here.
    void host(S)(S service)
    {
        enum kind = kindOf!S;
        if (auto old = kind in hosted)
            old.stop();
        hosted[kind] = new Hosted!S(service);
    }

    /// Stops hosting the service of `kind` (it moved, or the node stops).
    void release(ServiceKind kind)
    {
        if (auto old = kind in hosted)
        {
            old.stop();
            hosted.remove(kind);
        }
    }

    /// Whether the service of `kind` runs on this node.
    bool hosts(ServiceKind kind) const
    {
        return (kind in hosted) !is null;
    }

    /// The service of type `S` if it runs on this node; null otherwise.
    S* local(S)()
    {
        if (auto h = kindOf!S in hosted)
            return &(cast(Hosted!S) *h).service;
        return null;
    }

    /**
     * Calls `method` of its service with `request`; `then` gets the reply. On this node, at once and
     * directly. Returns false if the service is nowhere to be reached now (it will be: stage 2).
     */
    bool call(alias method, Request, Reply)(auto ref Request request, scope void delegate(Reply) then)
        if (!is(ReturnType!method == void))
    {
        static assert(checkCall!method && is(Reply == ReturnType!method));
        alias S = __traits(parent, method);
        if (auto service = local!S())
        {
            auto reply = __traits(getMember, *service, __traits(identifier, method))(request);
            if (then !is null)
                then(reply);
            return true;
        }
        return false;
    }

    /// ditto, for a call without a reply.
    bool call(alias method, Request)(auto ref Request request)
        if (is(ReturnType!method == void))
    {
        static assert(checkCall!method);
        alias S = __traits(parent, method);
        if (auto service = local!S())
        {
            __traits(getMember, *service, __traits(identifier, method))(request);
            return true;
        }
        return false;
    }

    /// Runs the call `id` of the service of `kind` from bytes (a remote caller's); see `HostedService.dispatch`.
    bool dispatch(ServiceKind kind, ulong id, const(ubyte)[] request, ref ubyte[] reply)
    {
        if (auto h = kind in hosted)
            return h.dispatch(id, request, reply);
        return false;
    }

    /// Each hosted service's tick.
    void tick(Duration elapsed)
    {
        foreach (service; hosted)
            service.tick(elapsed);
    }

    /// Stops every service (the node stops).
    void stopAll()
    {
        foreach (service; hosted)
            service.stop();
        hosted = null;
    }
}

version (unittest)
{
    private struct Add
    {
        uint amount;
        string note;
    }

    private struct Total
    {
        uint total;
        string[] notes;
    }

    @Service(ServiceKind.example)
    private struct Counter
    {
        uint total;
        string[] notes;
        uint ticks;
        bool stopped;

        @Call Total add(const ref Add request)
        {
            total += request.amount;
            notes ~= request.note;
            return Total(total, notes.dup);
        }

        @Call void reset(const ref Add)
        {
            total = 0;
        }

        void tick(Duration)
        {
            ++ticks;
        }

        void stop()
        {
            stopped = true;
        }
    }
}

// Local calls: direct, the reply to the continuation; nowhere hosted, refused.
unittest
{
    import core.time : msecs;

    auto host = new ServiceHost;
    assert(!host.call!(Counter.add)(Add(1, "a"), (Total t) {}), "not hosted anywhere yet");
    host.host(Counter());
    Total seen;
    assert(host.call!(Counter.add)(Add(5, "five"), (Total t) { seen = t; }));
    assert(seen.total == 5 && seen.notes == ["five"]);
    assert(host.call!(Counter.reset)(Add.init) && host.local!Counter().total == 0);
    host.tick(50.msecs);
    assert(host.local!Counter().ticks == 1);
    auto counter = host.local!Counter();
    host.release(ServiceKind.example);
    assert(counter.stopped && !host.hosts(ServiceKind.example));
}

// A call as bytes (what a remote caller sends): the same call, its reply as bytes.
unittest
{
    auto host = new ServiceHost;
    host.host(Counter(10));
    ubyte[] request, reply;
    const add = Add(7, "seven");
    encode(request, add);
    assert(host.dispatch(ServiceKind.example, callId!(Counter.add), request, reply));
    const(ubyte)[] r = reply;
    Total t;
    decode(r, t);
    assert(t.total == 17 && t.notes == ["seven"]);
    assert(!host.dispatch(ServiceKind.example, 12345, request, reply), "an unknown call (another build's)");
    static assert(callId!(Counter.add) != callId!(Counter.reset));
}
