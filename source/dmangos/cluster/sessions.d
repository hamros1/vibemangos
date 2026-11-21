/**
 * One login per account across the cluster (docs/CLUSTER.md).
 *
 * Every node registers the sessions it accepts with the coordinator (`SessionClaim`). The coordinator's
 * `SessionDirectory` grants an account to one session at a time: a claim for an account another
 * session holds evicts that session (`SessionEvict`), and is granted (`SessionGrant`) only once the
 * holder has released it (`SessionReleased`), which a node sends when the session has ended and its
 * character is saved. A session enters the world only once granted, so two nodes never have the same
 * character in the world, and the second never loads it before the first has saved it.
 *
 * A node that is lost cannot release its sessions; its accounts are freed once its lease has run out
 * (from then on it cannot be acting on anything: docs/CLUSTER.md).
 */
module dmangos.cluster.sessions;

import core.time : MonoTime;
import dmangos.cluster.protocol : GatewaySessionRoute, SessionRoute, SessionRouteKind,
    SessionRouteResult, SimulationOwner;

/// A session: the node that has it and that node's number for it.
struct SessionRef
{
    ushort node;
    ulong serial;
    ulong incarnation;

    @property SimulationOwner process() const
    {
        return SimulationOwner(node, incarnation);
    }
}

/// What the directory wants sent.
struct SessionAction
{
    enum Kind
    {
        grant,
        evict,
    }

    Kind kind;
    uint account;
    SessionRef session;
}

/// See the module documentation.
final class SessionDirectory
{
    private
    {
        SessionRef[uint] holders;     // account -> the session that has it
        SessionRef[uint] waiting;     // account -> the session that claimed it next
        MonoTime[SimulationOwner] lostUntil; // lost process -> when its sessions may be given away
        SessionRoute[uint] routes;    // account -> latest route of a gateway's session
        bool[uint] stoppedSimulations;
        bool[uint] endedRouteTerms;
        MonoTime[SimulationOwner] lostOwners;
        ulong[ushort] retiredOwners;  // these processes may no longer renew a lease
    }

    /// `session` asks for `account`.
    SessionAction[] claim(uint account, SessionRef session)
    {
        SessionAction[] actions;
        if (auto holder = account in holders)
        {
            if (*holder == session)
                return [SessionAction(SessionAction.Kind.grant, account, session)];
            if (auto earlier = account in waiting)
                if (*earlier != session)
                    actions ~= SessionAction(SessionAction.Kind.evict, account, *earlier);
            waiting[account] = session;
            if (holder.process !in lostUntil)
                actions ~= SessionAction(SessionAction.Kind.evict, account, *holder);
            return actions;
        }
        holders[account] = session;
        return [SessionAction(SessionAction.Kind.grant, account, session)];
    }

    /// `session` ended (or was never granted).
    SessionAction[] released(uint account, SessionRef session)
    {
        if (auto holder = account in holders)
            if (*holder == session)
            {
                holders.remove(account);
                routes.remove(account);
                stoppedSimulations.remove(account);
                endedRouteTerms.remove(account);
                if (auto next = account in waiting)
                {
                    const granted = *next;
                    waiting.remove(account);
                    holders[account] = granted;
                    return [SessionAction(SessionAction.Kind.grant, account, granted)];
                }
                return null;
            }
        if (auto next = account in waiting)
            if (*next == session)
                waiting.remove(account);
        return null;
    }

    /// Node `node` was lost: its sessions are released at `until` (its lease and margin).
    void lost(ushort node, MonoTime until, ulong incarnation = 0)
    {
        lostUntil[SimulationOwner(node, incarnation)] = until;
        if (incarnation)
            lostOwners[SimulationOwner(node, incarnation)] = until;
    }

    /// Node `node` is back (a new link): its sessions are its own again; it claims them anew.
    void back(ushort node, ulong incarnation = 0)
    {
        lostUntil.remove(SimulationOwner(node, incarnation));
        if (incarnation)
            lostOwners.remove(SimulationOwner(node, incarnation));
    }

    bool retired(SimulationOwner owner) const
    {
        return owner.incarnation && owner.incarnation <= retiredOwners.get(owner.node, 0);
    }

    /// A coordinator-link failure revokes a live gateway simulation's old process.
    bool mayAdmit(SimulationOwner owner) const
    {
        if (retired(owner))
            return false;
        if (owner in lostOwners)
            foreach (account, route; routes)
                if (route.next == owner && account !in stoppedSimulations)
                    return false;
        return true;
    }

    /// Restore a route from the gateway holding the original client before admitting competing logins.
    bool restoreGatewayRoute(SimulationOwner gateway, const ref GatewaySessionRoute saved, bool oldTerm = false)
    {
        if (!saved.account || !saved.serial || !saved.character || !saved.token || !saved.owner.node
            || !saved.owner.incarnation || saved.owner.node == gateway.node || saved.account in holders)
            return false;
        holders[saved.account] = SessionRef(gateway.node, saved.serial, gateway.incarnation);
        routes[saved.account] = SessionRoute(kind: SessionRouteKind.observe, account: saved.account,
            character: saved.character, serial: saved.serial, token: saved.token, previous: saved.owner,
            next: saved.owner);
        if (oldTerm)
            endedRouteTerms[saved.account] = true;
        return true;
    }

    /// Records an authorized move or replaces a crashed owner after the old process is fenced.
    SessionRouteResult route(SessionRef home, const ref SessionRoute request, MonoTime now, bool destinationLive = true)
    {
        alias Result = SessionRouteResult;
        const holder = request.account in holders;
        if (holder is null || *holder != home || !request.character || !request.token || !request.next.node
            || !request.next.incarnation || request.next.node == home.node || retired(request.next)
            || request.kind == SessionRouteKind.stopped)
            return Result.denied;
        if (auto current = request.account in routes)
        {
            if (current.token == request.token)
                return *current == request || (request.kind == SessionRouteKind.observe
                    && current.next == request.next && current.character == request.character)
                    ? Result.granted : Result.denied;
            if (current.token > request.token)
                return Result.denied;
            if (request.kind == SessionRouteKind.observe
                && (request.next != current.next || request.character != current.character))
                return Result.denied;
            if (request.kind != SessionRouteKind.observe && request.previous.node != home.node
                && (request.previous != current.next || request.character != current.character))
                return Result.denied;
        }
        else if (request.kind == SessionRouteKind.recover)
            return Result.retry;
        if (!destinationLive)
            return Result.retry;
        if (request.kind == SessionRouteKind.recover)
        {
            const oldTerm = request.account in endedRouteTerms;
            if ((!oldTerm && request.previous == request.next) || request.previous.node == home.node)
                return Result.denied;
            if (!oldTerm && !retired(request.previous))
            {
                const until = request.previous in lostOwners;
                if (until is null || now < *until)
                    return Result.retry;
                retire(request.previous);
            }
        }
        routes[request.account] = request;
        stoppedSimulations.remove(request.account);
        endedRouteTerms.remove(request.account);
        return Result.granted;
    }

    /// A surviving owner saved and stopped when the gateway disappeared.
    void stopped(uint account, uint character, ulong token, SimulationOwner owner)
    {
        if (const current = account in routes)
            if (current.character == character && current.next == owner && current.token == token)
                stoppedSimulations[account] = true;
    }

    private void retire(SimulationOwner owner)
    {
        import std.algorithm.comparison : max;

        retiredOwners[owner.node] = max(retiredOwners.get(owner.node, 0), owner.incarnation);
        lostOwners.remove(owner);
    }

    private bool stoppedOrFenced(uint account, MonoTime now)
    {
        if (account in stoppedSimulations || account in endedRouteTerms)
            return true;
        if (const current = account in routes)
        {
            const until = current.next in lostOwners;
            if (until !is null && now >= *until)
                retire(current.next);
            return retired(current.next);
        }
        return true;
    }

    /// Releases the sessions of lost nodes whose lease has run out.
    SessionAction[] tick(MonoTime now)
    {
        SessionAction[] actions;
        SimulationOwner[] done;
        foreach (owner, until; lostUntil)
            if (now >= until)
            {
                uint[] stale;
                foreach (account, next; waiting)
                    if (next.process == owner)
                        stale ~= account;
                foreach (account; stale)
                    waiting.remove(account);
                bool stillHeld;
                uint[] accounts;
                foreach (account, holder; holders)
                    if (holder.process == owner)
                    {
                        if (stoppedOrFenced(account, now))
                            accounts ~= account;
                        else
                            stillHeld = true;
                    }
                foreach (account; accounts)
                    actions ~= released(account, holders[account]);
                if (!stillHeld)
                    done ~= owner;
            }
        foreach (node; done)
            lostUntil.remove(node);
        return actions;
    }

    /// Accounts held.
    @property size_t length() const
    {
        return holders.length;
    }
}

unittest
{
    import core.time : seconds;

    alias Kind = SessionAction.Kind;
    auto directory = new SessionDirectory;
    const a = SessionRef(1, 10), b = SessionRef(2, 20), c = SessionRef(3, 30);

    // A free account is granted at once; claiming again is granted again.
    assert(directory.claim(7, a) == [SessionAction(Kind.grant, 7, a)]);
    assert(directory.claim(7, a) == [SessionAction(Kind.grant, 7, a)]);

    // A second session evicts the first and waits for it to release.
    assert(directory.claim(7, b) == [SessionAction(Kind.evict, 7, a)]);
    assert(directory.released(7, b).length == 0, "b only waited: its release grants nothing");
    assert(directory.claim(7, b) == [SessionAction(Kind.evict, 7, a)]);
    assert(directory.released(7, a) == [SessionAction(Kind.grant, 7, b)]);

    // A third while one waits: the waiting one is evicted too, and the newest wins.
    assert(directory.claim(7, c) == [SessionAction(Kind.evict, 7, b)]);
    assert(directory.claim(7, a) == [SessionAction(Kind.evict, 7, c), SessionAction(Kind.evict, 7, b)]);
    assert(directory.released(7, c).length == 0, "c was only waiting");
    assert(directory.released(7, b) == [SessionAction(Kind.grant, 7, a)]);

    // A lost node's sessions are released once its lease has run out.
    auto now = MonoTime.currTime;
    directory.lost(1, now + 5.seconds);
    assert(directory.claim(7, b).length == 0, "the holder is lost: no eviction can reach it; b waits");
    assert(directory.tick(now + 4.seconds).length == 0);
    assert(directory.tick(now + 6.seconds) == [SessionAction(Kind.grant, 7, b)]);
    assert(directory.length == 1);
}

/// A direct link failure cannot fence an owner. Recovery after a crash retires its exact incarnation.
unittest
{
    import core.time : seconds;

    auto directory = new SessionDirectory;
    const gateway = SessionRef(1, 10, 50), competing = SessionRef(4, 20, 60);
    const old = SimulationOwner(2, 100), replacement = SimulationOwner(3, 200);
    auto now = MonoTime.currTime;
    directory.claim(7, gateway);
    const first = SessionRoute(kind: SessionRouteKind.move, account: 7, character: 70, serial: 10, token: 1,
        previous: SimulationOwner(1, 50), next: old);
    assert(directory.route(gateway, first, now) == SessionRouteResult.granted);
    const recovery = SessionRoute(kind: SessionRouteKind.recover, account: 7, character: 70, serial: 10, token: 2,
        previous: old, next: replacement);
    assert(directory.route(gateway, recovery, now + 6.seconds) == SessionRouteResult.retry);
    directory.lost(old.node, now + 5.seconds, old.incarnation);
    assert(!directory.mayAdmit(old), "a lost simulation owner cannot renew under the old incarnation");
    assert(directory.route(gateway, recovery, now + 4.seconds) == SessionRouteResult.retry);
    directory.back(old.node, old.incarnation);
    assert(directory.route(gateway, recovery, now + 6.seconds) == SessionRouteResult.retry);
    directory.lost(old.node, now + 10.seconds, old.incarnation);
    assert(directory.route(gateway, recovery, now + 10.seconds) == SessionRouteResult.granted);
    assert(directory.route(gateway, recovery, now + 11.seconds, false) == SessionRouteResult.granted,
        "a lost acknowledgement can be repeated after the destination goes away");
    assert(directory.retired(old) && !directory.retired(SimulationOwner(old.node, old.incarnation + 1)));

    directory.lost(gateway.node, now + 15.seconds, 50);
    assert(directory.claim(7, competing).length == 0 && directory.tick(now + 16.seconds).length == 0);
    directory.stopped(7, 70, 1, replacement);
    assert(directory.tick(now + 16.seconds).length == 0, "an older route cannot release the recovered simulation");
    directory.stopped(7, 70, 2, replacement);
    assert(directory.tick(now + 16.seconds) == [SessionAction(SessionAction.Kind.grant, 7, competing)]);
}
