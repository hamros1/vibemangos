/**
 * A node's place in a cluster (docs/CLUSTER.md), the `cluster` object of `worldserver.json`. A
 * node id of 0, the default, means the server runs standalone and none of the cluster code runs.
 */
module dmangos.cluster.config;

import std.exception : enforce;
import std.format : format;

import dmangos.json : JsonName;

/// See the module documentation.
struct ClusterConfig
{
    /// This node's id, unique in the cluster; 0: no cluster.
    @JsonName("node_id") ushort nodeId;
    /// The cluster's name: nodes of another cluster are turned away.
    string name = "dmangos";
    /// Where to accept other nodes' connections.
    @JsonName("listen_address") string listenAddress = "0.0.0.0";
    @JsonName("listen_port") ushort listenPort = 9000; /// ditto
    /// The address other nodes reach this one at (the listen address, if that is not 0.0.0.0).
    @JsonName("advertise_address") string advertiseAddress = "127.0.0.1";
    /**
     * The "host:port" clients reach this node's world port at (phase 3b: the coordinator points the
     * realm list at the least busy node). Empty: 127.0.0.1 and the world port.
     */
    @JsonName("client_address") string clientAddress;
    /// The coordinator's "host:port". A node whose advertised address and port this is, is the coordinator.
    string coordinator = "127.0.0.1:9000";
    /// How often a heartbeat goes out on each link, in milliseconds.
    @JsonName("heartbeat_ms") uint heartbeatMs = 500;
    /// A link with nothing received for this long is considered dead, in milliseconds.
    @JsonName("failure_timeout_ms") uint failureTimeoutMs = 3000;
    /**
     * How long a node may go on simulating its regions without hearing from the coordinator, in
     * milliseconds; the coordinator waits this long (and a margin) before giving a lost node's
     * regions to another. Longer than the failure timeout, so a node is dropped before its lease ends.
     */
    @JsonName("lease_ms") uint leaseMs = 5000;
    /**
     * How finely the coordinator divides the world (docs/CLUSTER.md, phase 2): until no region
     * holds more than 1/`region_count` of all spawns. Each map is a region at least.
     */
    @JsonName("region_count") uint regionCount = 32;
    /// How many ids of a kind a member asks the coordinator for at a time.
    @JsonName("id_block") uint idBlock = 1000;

    /**
     * Load balancing by measured cost (docs/CLUSTER.md, phase 6): how often the coordinator looks, how
     * busy (µs of loop time a second) the busiest node must be before anything moves, and how long a
     * region that moved stays where it went.
     */
    @JsonName("balance_interval_seconds") uint balanceIntervalSeconds = 30;
    @JsonName("balance_min_load_us") uint balanceMinLoadUs = 20_000; /// ditto: 2% of one core
    @JsonName("region_cooldown_seconds") uint regionCooldownSeconds = 120; /// ditto

    /**
     * Phase 7: this member is the standby coordinator. It keeps what a coordinator needs, and takes
     * over when it has lost the coordinator (docs/CLUSTER.md).
     */
    @JsonName("standby") bool standby;
    /**
     * A gateway (docs/SERVICES.md, stage 6): it holds clients' connections and simulates nothing. The
     * coordinator gives it no regions and no services; its players are simulated where they are, and
     * new clients are sent to the gateways when there are any. Not the coordinator, not the standby.
     */
    @JsonName("gateway") bool gateway;

    /// Whether the server is part of a cluster.
    @property bool enabled() const pure nothrow @nogc @safe
    {
        return nodeId != 0;
    }

    /// This node's own "host:port", as others reach it.
    @property string advertised() const pure @safe
    {
        return format!"%s:%s"(advertiseAddress, listenPort);
    }

    /// Whether this node is the coordinator.
    @property bool isCoordinator() const pure @safe
    {
        return coordinator == advertised;
    }

    /// Throws if the settings cannot work together.
    void validate() const @safe
    {
        if (!enabled)
            return;
        enforce(name.length > 0 && name.length < 64, "cluster.name must have 1 to 63 characters");
        enforce(listenPort != 0, "cluster.listen_port must be set");
        enforce(advertiseAddress.length > 0 && advertiseAddress != "0.0.0.0",
            "cluster.advertise_address must be an address other nodes can reach");
        splitAddress(coordinator);
        enforce(heartbeatMs >= 10, "cluster.heartbeat_ms must be at least 10");
        enforce(failureTimeoutMs >= 3 * heartbeatMs, "cluster.failure_timeout_ms must be at least three heartbeats");
        enforce(leaseMs > failureTimeoutMs, "cluster.lease_ms must be longer than cluster.failure_timeout_ms");
        enforce(regionCount >= 1 && idBlock >= 1, "cluster.region_count and cluster.id_block must be at least 1");
    }
}

/// "host:port" as its parts; throws if it is not one.
void splitAddress(string address, out string host, out ushort port) @safe
{
    import std.conv : to;
    import std.string : lastIndexOf;

    const colon = address.lastIndexOf(':');
    enforce(colon > 0 && colon + 1 < address.length, format!"'%s' is not host:port"(address));
    host = address[0 .. colon];
    try
        port = address[colon + 1 .. $].to!ushort;
    catch (Exception)
        throw new Exception(format!"'%s' is not host:port"(address));
    enforce(port != 0, format!"'%s' has no port"(address));
}

/// ditto, only checking.
void splitAddress(string address) @safe
{
    string host;
    ushort port;
    splitAddress(address, host, port);
}

unittest
{
    import std.exception : assertThrown;

    ClusterConfig standalone;
    assert(!standalone.enabled);
    standalone.validate();

    ClusterConfig c;
    c.nodeId = 1;
    c.listenPort = 9000;
    c.validate();
    assert(c.isCoordinator && c.advertised == "127.0.0.1:9000");
    c.listenPort = 9001;
    assert(!c.isCoordinator);
    c.coordinator = "nonsense";
    assertThrown(c.validate());
    c.coordinator = "10.0.0.1:9000";
    c.failureTimeoutMs = 100;
    assertThrown(c.validate());
    c.failureTimeoutMs = 6000;
    assertThrown(c.validate(), "a lease shorter than the failure timeout");

    string host;
    ushort port;
    splitAddress("10.0.0.1:9000", host, port);
    assert(host == "10.0.0.1" && port == 9000);
}
