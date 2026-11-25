/**
 * Fixed-membership elections with renewable majority leases. Each successful round is bounded
 * by the candidate's send time. Each voter promises its vote from its own later receipt time,
 * with the cluster's lease margin. Restarted voters wait out any promise they might have made.
 */
module dmangos.cluster.quorum;

import core.time : Duration, MonoTime;
import dmangos.cluster.ownership : leaseMargin;
import dmangos.cluster.protocol : QuorumVote, SimulationOwner;
import std.algorithm.comparison : max;
import std.exception : enforce;

private struct Vote
{
    ulong term;
    SimulationOwner candidate;
}

final class QuorumElection
{
    private
    {
        SimulationOwner self;
        size_t majority;
        Duration lease, heartbeat, delay;
        Vote vote;
        MonoTime promiseUntil, nextCampaign;
        VoteFile store;
        ulong observedTerm;

        ulong campaign, round;
        MonoTime started, nextSend, deadline;
        bool[ushort] votes;
        bool wonRound, elected, failed;
    }

    this(SimulationOwner self, size_t voters, size_t rank, Duration lease, Duration heartbeat,
        MonoTime now, string path, ulong roster)
    {
        this.self = self;
        majority = voters / 2 + 1;
        this.lease = lease;
        this.heartbeat = heartbeat;
        delay = heartbeat * (cast(long) rank + 1);
        store = new VoteFile(path, roster, self.node);
        vote = store.load();
        promiseUntil = now + lease + leaseMargin;
        nextCampaign = promiseUntil + delay;
    }

    /// This voter's process started again as `self` (`ClusterNode.reincarnate`); its promises to others stand.
    void rebind(SimulationOwner self)
    {
        this.self = self;
        campaign = 0;
        elected = false;
        wonRound = false;
        votes = null;
    }

    ulong term(MonoTime now) const
    {
        return !failed && elected && vote.term == campaign && now < deadline ? campaign : 0;
    }

    MonoTime validUntil(MonoTime now) const
    {
        return term(now) ? deadline : MonoTime.init;
    }

    void follow(ulong term, MonoTime until)
    {
        observedTerm = max(observedTerm, term);
        if (!elected)
            campaign = 0;
        nextCampaign = max(nextCampaign, until + delay);
    }

    /// A round request to send to the other configured voters, or an empty request.
    QuorumVote tick(MonoTime now)
    {
        if (failed)
            return QuorumVote.init;
        if (campaign && (vote.term != campaign || (elected ? now >= deadline : now >= started + lease)))
        {
            campaign = 0;
            elected = false;
            nextCampaign = max(now, promiseUntil) + delay;
        }
        if (!campaign)
        {
            if (now < promiseUntil || now < nextCampaign)
                return QuorumVote.init;
            const latest = max(vote.term, observedTerm);
            enforce(latest < ulong.max, "cluster election terms exhausted");
            campaign = latest + 1;
            beginRound(now);
        }
        if (now < nextSend)
            return QuorumVote.init;
        if (wonRound)
            beginRound(now);
        nextSend = now + heartbeat;
        return QuorumVote(campaign, round);
    }

    /// A request from a configured voter. A rejection reports this voter's highest durable term.
    QuorumVote request(SimulationOwner candidate, const ref QuorumVote request, MonoTime now)
    {
        if (!request.term || !request.round || !promise(candidate, request.term, request.round, now))
            return QuorumVote(request.term, request.round, vote.term, true, false);
        return QuorumVote(request.term, request.round, vote.term, true, true);
    }

    void reply(ushort voter, const ref QuorumVote reply, MonoTime now)
    {
        observedTerm = max(observedTerm, reply.seenTerm);
        if (!campaign || reply.term != campaign || reply.round != round || !reply.granted || wonRound
            || vote.term != campaign || now >= started + lease || (elected && now >= deadline))
            return;
        votes[voter] = true;
        if (votes.length >= majority)
        {
            deadline = started + lease;
            wonRound = true;
            elected = true;
        }
    }

    private ulong promisedRound;

    private bool promise(SimulationOwner candidate, ulong term, ulong requestedRound, MonoTime now)
    {
        if (failed || term < vote.term || (term == vote.term && candidate != vote.candidate)
            || (term > vote.term && now < promiseUntil))
            return false;
        if (term > vote.term)
        {
            const next = Vote(term, candidate);
            scope (failure) failed = true;
            store.save(next);
            vote = next;
            promisedRound = 0;
            // A vote first accepted by this process starts its own promise below.
        }
        if (requestedRound < promisedRound)
            return false;
        if (requestedRound > promisedRound)
        {
            promisedRound = requestedRound;
            promiseUntil = now + lease + leaseMargin;
        }
        return now < promiseUntil;
    }

    private void beginRound(MonoTime now)
    {
        ++round;
        started = now;
        nextSend = now;
        wonRound = false;
        votes = null;
        enforce(promise(self, campaign, round, now), "cluster election could not count its own vote");
        votes[self.node] = true;
    }
}

/// Atomic replacement plus a directory sync makes a vote durable before its acknowledgement.
private final class VoteFile
{
    import std.stdio : File;

    private string path;
    private ulong roster;
    private ushort node;
    private File lock;

    this(string path, ulong roster, ushort node)
    {
        this.path = path;
        this.roster = roster;
        this.node = node;
        version (linux)
        {
            import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB;

            lock = File(path ~ ".lock", "a");
            enforce(flock(lock.fileno, LOCK_EX | LOCK_NB) == 0, "cluster vote file is already in use: " ~ path);
        }
        else
            throw new Exception("quorum voting requires Linux");
    }

    Vote load()
    {
        import std.file : exists, readText;
        import std.format : formattedRead;
        import std.string : strip;

        if (!exists(path))
            return Vote.init;
        auto input = readText(path).strip;
        Vote state;
        ulong storedRoster;
        ushort storedNode;
        const n = formattedRead!"dmangos-vote-1 %s %s %s %s %s"(input, storedRoster, storedNode,
            state.term, state.candidate.node, state.candidate.incarnation);
        enforce(n == 5 && !input.length && storedRoster == roster && storedNode == node
            && state.term && state.candidate.node && state.candidate.incarnation,
            "invalid or mismatched cluster vote file: " ~ path);
        return state;
    }

    void save(Vote state)
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : close, fsync;
        import std.file : rename;
        import std.path : dirName;
        import std.string : toStringz;

        const temporary = path ~ ".tmp";
        auto file = File(temporary, "w");
        file.writefln!"dmangos-vote-1 %s %s %s %s %s"(
            roster, node, state.term, state.candidate.node, state.candidate.incarnation);
        file.flush();
        enforce(fsync(file.fileno) == 0, "could not sync cluster vote: " ~ path);
        file.close();
        rename(temporary, path);
        const directory = open(dirName(path).toStringz, O_RDONLY);
        enforce(directory >= 0, "could not open cluster vote directory: " ~ path);
        scope (exit) close(directory);
        enforce(fsync(directory) == 0, "could not sync cluster vote directory: " ~ path);
    }
}

version (linux) unittest
{
    import core.time : msecs, seconds;
    import std.conv : to;
    import std.file : mkdir, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const dir = buildPath(tempDir(), "dmangos-vote-" ~ randomUUID().to!string);
    mkdir(dir);
    scope (exit) rmdirRecurse(dir);
    const path = buildPath(dir, "vote");
    auto now = MonoTime.currTime;
    auto first = new QuorumElection(SimulationOwner(1, 10), 3, 0, 5.seconds, 500.msecs, now, path, 8);
    now += 6.seconds;
    const request = QuorumVote(7, 1);
    assert(first.request(SimulationOwner(2, 20), request, now).granted);
    first.store.lock.close();

    now += 400.msecs;
    auto restarted = new QuorumElection(SimulationOwner(1, 11), 3, 0, 5.seconds, 500.msecs, now, path, 8);
    assert(!restarted.request(SimulationOwner(2, 21), request, now + 6.seconds).granted,
        "a new incarnation of the same candidate cannot take over its durable vote");
    const higher = QuorumVote(8, 1);
    const denied = restarted.request(SimulationOwner(3, 30), higher, now + 5.seconds);
    assert(!denied.granted && denied.seenTerm == 7, "a restart preserves the vote and waits out the old promise");
    assert(restarted.request(SimulationOwner(3, 30), higher, now + 6.seconds).granted);
}
