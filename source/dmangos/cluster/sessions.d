/**
 * One login per account across the cluster (docs/CLUSTER.md, phase 3b).
 *
 * Every node registers the sessions it accepts with the coordinator (`SessionClaim`). The coordinator's
 * `SessionDirectory` grants an account to one session at a time: a claim for an account another
 * session holds evicts that session (`SessionEvict`), and is granted (`SessionGrant`) only once the
 * holder has released it (`SessionReleased`), which a node sends when the session has ended and its
 * character is saved. A session enters the world only once granted, so two nodes never have the same
 * character in the world, and the second never loads it before the first has saved it.
 *
 * A node that is lost cannot release its sessions; its accounts are freed once its lease has run out
 * (from then on it cannot be acting on anything: docs/CLUSTER.md, phase 2).
 */
module dmangos.cluster.sessions;

import core.time : MonoTime;

/// A session: the node that has it and that node's number for it.
struct SessionRef
{
    ushort node;
    ulong serial;
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
        MonoTime[ushort] lostUntil;   // lost node -> when its sessions may be given away
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
            if (holder.node !in lostUntil)
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
    void lost(ushort node, MonoTime until)
    {
        lostUntil[node] = until;
    }

    /// Node `node` is back (a new link): its sessions are its own again; it claims them anew.
    void back(ushort node)
    {
        lostUntil.remove(node);
    }

    /// Releases the sessions of lost nodes whose lease has run out.
    SessionAction[] tick(MonoTime now)
    {
        SessionAction[] actions;
        ushort[] done;
        foreach (node, until; lostUntil)
            if (now >= until)
            {
                done ~= node;
                uint[] accounts;
                foreach (account, holder; holders)
                    if (holder.node == node)
                        accounts ~= account;
                foreach (account; accounts)
                    actions ~= released(account, holders[account]);
                uint[] stale;
                foreach (account, next; waiting)
                    if (next.node == node)
                        stale ~= account;
                foreach (account; stale)
                    waiting.remove(account);
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
