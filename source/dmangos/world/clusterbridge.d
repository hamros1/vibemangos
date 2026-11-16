/**
 * The world server's side of replication (docs/CLUSTER.md, phase 3): replicas of this node's
 * objects go out through the cluster's links, replication messages from other nodes go to the map
 * they are about, and every tick each map's interest changes go to every linked node.
 */
module dmangos.world.clusterbridge;

import core.time : MonoTime, msecs;

import dmangos.cluster.node : ClusterNode, PlayerHandler, ReplicationHandler;
import dmangos.cluster.protocol : InterestUpdate, PlayerMessage, PlayerMessageKind, ReplicaCreate, ReplicaMove,
    ReplicaRemove, ReplicaValues;
import dmangos.log;
import dmangos.world.context : PlayerRelay, WorldContext;
import dmangos.world.replication : Replicator;
import dmangos.world.session : WorldSession, WorldState;

/// See the module documentation. Also relays players simulated away from their client (phase 4b).
final class ClusterBridge : Replicator, ReplicationHandler, PlayerRelay, PlayerHandler
{
    private ClusterNode node;
    private WorldContext context;
    private WorldSession[uint] remote;         // owner: sessions whose client is on another node, by account
    private MonoTime[WorldSession] releaseAt;  // home: sessions whose owner was lost, released after its lease
    private uint leaseMs;

    /// `leaseMs`: the cluster's lease, which a lost owner certainly stopped within.
    this(ClusterNode node, WorldContext context, uint leaseMs)
    {
        this(node, context);
        this.leaseMs = leaseMs;
    }

    ///
    this(ClusterNode node, WorldContext context)
    {
        this.node = node;
        this.context = context;
    }

    /// Sends what each map's players became near and left since the last tick.
    void tick()
    {
        if (releaseAt.length)
        {
            const now = MonoTime.currTime;
            WorldSession[] due;
            foreach (session, at; releaseAt)
                if (now >= at)
                    due ~= session;
            foreach (session; due)
            {
                releaseAt.remove(session);
                session.ownerLeft(false);
            }
        }
        foreach (map; context.allMaps)
        {
            ulong[] added, removed;
            map.takeInterest(added, removed);
            if (added.length || removed.length)
                node.broadcast(InterestUpdate(map.id, added, removed));
        }
    }

    // Replicator: this node's objects, to the nodes that want them.

    void create(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
    {
        node.sendTo(peer, ReplicaCreate(map, cell, guid, cast(ubyte[]) state));
    }

    void values(ushort peer, uint map, ulong guid, const(ubyte)[] slots)
    {
        node.sendTo(peer, ReplicaValues(map, guid, cast(ubyte[]) slots));
    }

    void move(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        node.sendTo(peer, ReplicaMove(map, guid, opcode, cast(ubyte[]) body_, cast(ubyte[]) motion));
    }

    void remove(ushort peer, uint map, ulong guid)
    {
        node.sendTo(peer, ReplicaRemove(map, guid));
    }

    // ReplicationHandler: other nodes' messages, to the maps.

    void peerLinked(ushort peer)
    {
        foreach (map; context.allMaps)
        {
            auto cells = map.interestCells;
            if (cells.length)
                node.sendTo(peer, InterestUpdate(map.id, cells, null));
        }
    }

    void peerLost(ushort peer)
    {
        foreach (map; context.allMaps)
            map.peerGone(peer);
        // Players it held the clients of: they leave the world here, saved (it cannot say they did).
        WorldSession[] orphans;
        foreach (account, session; remote)
            if (session.home == peer)
                orphans ~= session;
        foreach (session; orphans)
            session.clientGone();
        // Players it simulated: their clients are told to go; the accounts are free once its lease is surely over.
        foreach (k; context.allSessions)
            if (auto session = cast(WorldSession) k)
                if (session.state == WorldState.elsewhere && session.owner == peer)
                {
                    session.kick("the server simulating this character was lost");
                    releaseAt[session] = MonoTime.currTime + (leaseMs + 500).msecs;
                }
    }

    // PlayerRelay: this node's half of players simulated away from their clients.

    void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
    {
        node.sendTo(home, PlayerMessage(PlayerMessageKind.toHome, account, opcode, cast(ubyte[]) body_));
    }

    void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
    {
        node.sendTo(owner, PlayerMessage(PlayerMessageKind.toOwner, account, opcode, cast(ubyte[]) body_));
    }

    void disconnect(ushort owner, uint account)
    {
        node.sendTo(owner, PlayerMessage(PlayerMessageKind.disconnect, account, 0, null));
    }

    void migrate(ushort target, uint account, const(ubyte)[] state)
    {
        node.sendTo(target, PlayerMessage(PlayerMessageKind.migrate, account, 0, cast(ubyte[]) state));
    }

    void left(ushort home, uint account, bool toCharacterScreen)
    {
        node.sendTo(home, PlayerMessage(PlayerMessageKind.left, account, toCharacterScreen ? 1 : 0, null));
    }

    void remoteDone(uint account)
    {
        remote.remove(account);
    }

    // PlayerHandler: the other halves' messages.

    void player(ushort peer, PlayerMessageKind kind, uint account, ushort opcode, const(ubyte)[] data)
    {
        final switch (kind)
        {
        case PlayerMessageKind.migrate:
            // Back home, or arriving at a node that will simulate it for its home.
            if (auto home = cast(WorldSession) context.sessionOf(account))
                if (home.state == WorldState.elsewhere)
                {
                    if (!home.arrive(data))
                        home.kick("the character could not be loaded after moving between servers");
                    return;
                }
            auto session = new WorldSession(context, WorldSession.migrationAccount(data), peer);
            remote[account] = session;
            if (!session.arrive(data))
            {
                warning!"cluster: a player of account %s from node %s could not be loaded"(account, peer);
                remote.remove(account);
                left(peer, account, false);
            }
            return;
        case PlayerMessageKind.toOwner:
            if (auto session = account in remote)
                session.fromHome(opcode, data);
            return;
        case PlayerMessageKind.toHome:
            if (auto session = cast(WorldSession) context.sessionOf(account))
                session.fromOwner(opcode, data);
            return;
        case PlayerMessageKind.left:
            if (auto session = cast(WorldSession) context.sessionOf(account))
                if (session.owner == peer)
                    session.ownerLeft(opcode == 1);
            return;
        case PlayerMessageKind.disconnect:
            if (auto session = account in remote)
                session.clientGone();
            return;
        }
    }

    void interest(ushort peer, uint map, const(ulong)[] added, const(ulong)[] removed)
    {
        context.map(map).peerInterest(peer, added, removed);
    }

    void replicaCreate(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
    {
        context.map(map).replicaCreated(peer, cell, guid, state);
    }

    void replicaValues(ushort peer, uint map, ulong guid, const(ubyte)[] slots)
    {
        if (auto m = context.existingMap(map))
            m.replicaValues(peer, guid, slots);
    }

    void replicaMove(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        if (auto m = context.existingMap(map))
            m.replicaMoved(peer, guid, opcode, body_, motion);
    }

    void replicaRemove(ushort peer, uint map, ulong guid)
    {
        if (auto m = context.existingMap(map))
            m.replicaRemoved(peer, guid);
    }
}
