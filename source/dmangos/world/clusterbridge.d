/**
 * The world server's side of replication (docs/CLUSTER.md, phase 3): replicas of this node's
 * objects go out through the cluster's links, replication messages from other nodes go to the map
 * they are about, and every tick each map's interest changes go to every linked node.
 */
module dmangos.world.clusterbridge;

import dmangos.cluster.node : ClusterNode, ReplicationHandler;
import dmangos.cluster.protocol : InterestUpdate, ReplicaCreate, ReplicaMove, ReplicaRemove, ReplicaValues;
import dmangos.world.context : WorldContext;
import dmangos.world.replication : Replicator;

/// See the module documentation.
final class ClusterBridge : Replicator, ReplicationHandler
{
    private ClusterNode node;
    private WorldContext context;

    ///
    this(ClusterNode node, WorldContext context)
    {
        this.node = node;
        this.context = context;
    }

    /// Sends what each map's players became near and left since the last tick.
    void tick()
    {
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
