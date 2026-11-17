/**
 * Flight masters (CMaNGOS `Maps/TaxiHandler.cpp`, `Player::ActivateTaxiPathTo` and the taxi
 * movement), mixed into `dmangos.world.session.WorldSession`.
 *
 * A flight master's node becomes known the first time the player talks to it; afterwards it shows
 * the known nodes. A flight to one of them (directly, or over several legs) costs its price (10%
 * less at honored with the master's faction): the player mounts its node's flying mount and flies
 * the path at 32 yards a second, as `SMSG_MONSTER_MOVE` shows everyone, while the server follows
 * it to keep its place on the map; at the end it lands at the destination node. Logging out in
 * flight puts the character at the destination.
 */
module dmangos.world.taxihandlers;

/// See the module documentation.
mixin template TaxiHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.vmap.math : Vector3;
    import dmangos.world.creature : chooseDisplay, Npc;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.spline : MoveSpline, monsterMove, SplineFlags;
    import dmangos.world.taxi;
    import dmangos.world.updatefields;

    MoveSpline taxiSpline;       // the flight under way
    uint taxiDestination;        // its last node; 0: not flying
    int taxiRelocate;            // until the map hears of the position again

    /// Whether the player is on a flight.
    package @property bool flying() const
    {
        return taxiDestination != 0;
    }

    /// The node a flight master stands at, for this player's team; 0 if none.
    uint taxiNodeOf(const Npc npc)
    {
        return nearestTaxiNode(context.client, npc.position, map.id, context.client.teamForRace(player.data.race));
    }

    /// `HandleTaxiNodeStatusQueryOpcode`: whether the master's node is known (the flight master's icon).
    @Handles(Opcode.CMSG_TAXINODE_STATUS_QUERY, WorldState.inWorld)
    void handleTaxiNodeStatusQuery(const ClientGuid request)
    {
        auto npc = context.npcFor(map.findObject(request.guid));
        if (npc is null)
            return;
        const node = taxiNodeOf(npc);
        if (node == 0)
            return;
        ByteWriter w;
        w.put(request.guid);
        w.put(cast(ubyte)(knowsNode(player.data.taxiMask, node) ? 1 : 0));
        deliver(Opcode.SMSG_TAXINODE_STATUS, w.data);
    }

    /// `HandleTaxiQueryAvailableNodes`: a new node learned, or the map of the known ones.
    @Handles(Opcode.CMSG_TAXIQUERYAVAILABLENODES, WorldState.inWorld)
    void handleTaxiQueryAvailableNodes(const ClientGuid request)
    {
        auto npc = interactableNpc(request.guid, NpcFlag.flightMaster);
        if (npc is null)
            return;
        const node = taxiNodeOf(npc);
        if (node == 0)
            return;
        // `SendLearnNewTaxiNode`
        if (learnNode(player.data.taxiMask, node))
        {
            deliver(Opcode.SMSG_NEW_TAXI_PATH, null);
            ByteWriter w;
            w.put(request.guid);
            w.put(ubyte(1));
            deliver(Opcode.SMSG_TAXINODE_STATUS, w.data);
            info!"%s: '%s' learned flight node %s"(remoteAddress, player.data.name, node);
            return;
        }
        // `SendTaxiMenu`
        ByteWriter w;
        w.put(1u);
        w.put(request.guid);
        w.put(node);
        foreach (value; player.data.taxiMask)
            w.put(value);
        deliver(Opcode.SMSG_SHOWTAXINODES, w.data);
    }

    /// `SendActivateTaxiReply`
    void sendTaxiReply(TaxiReply reply)
    {
        ByteWriter w;
        w.put(cast(uint) reply);
        deliver(Opcode.SMSG_ACTIVATETAXIREPLY, w.data);
    }

    /// `HandleActivateTaxiOpcode`: a flight to a node.
    @Handles(Opcode.CMSG_ACTIVATETAXI, WorldState.inWorld)
    void handleActivateTaxi(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        const uint[2] nodes = [reader.read!uint, reader.read!uint];
        auto npc = interactableNpc(guid, NpcFlag.flightMaster);
        if (npc is null)
            return;
        if (!knowsNode(player.data.taxiMask, nodes[0]) || !knowsNode(player.data.taxiMask, nodes[1]))
            return sendTaxiReply(TaxiReply.notVisited);
        activateTaxiPathTo(nodes[], npc);
    }

    /// `HandleActivateTaxiExpressOpcode`: a flight over several nodes.
    @Handles(Opcode.CMSG_ACTIVATETAXIEXPRESS, WorldState.inWorld)
    void handleActivateTaxiExpress(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        reader.read!uint; // the client's total cost
        const count = reader.read!uint;
        auto npc = interactableNpc(guid, NpcFlag.flightMaster);
        if (npc is null || count > 64)
            return;
        uint[] nodes;
        foreach (_; 0 .. count)
        {
            const node = reader.read!uint;
            if (!knowsNode(player.data.taxiMask, node))
                return sendTaxiReply(TaxiReply.notVisited);
            nodes ~= node;
        }
        activateTaxiPathTo(nodes, npc);
    }

    /// `HandleMoveSplineDoneOpcode`: the client's word that the flight's spline ended; the server follows its own.
    @Handles(Opcode.CMSG_MOVE_SPLINE_DONE, WorldState.inWorld)
    void handleMoveSplineDone(ref ByteReader reader)
    {
    }

    /// `Player::ActivateTaxiPathTo` from a flight master.
    void activateTaxiPathTo(const(uint)[] nodes, Npc npc)
    {
        enum float interactionDistance = 5;
        if (nodes.length < 2 || flying)
            return;
        if (loggingOut || inCombat)
            return sendTaxiReply(TaxiReply.playerBusy);
        if (player.values.get!UNIT_FIELD_MOUNTDISPLAYID)
            return sendTaxiReply(TaxiReply.alreadyMounted);
        // `IsInDisallowedMountForm`: forms but the warrior's stances, Shadowform and Stealth.
        enum ubyte battleStance = 17, defensiveStance = 18, berserkerStance = 19, shadow = 28, stealth = 30;
        const form = player.values.getByte!UNIT_FIELD_BYTES_1(2);
        if (form && form != battleStance && form != defensiveStance && form != berserkerStance && form != shadow
            && form != stealth)
            return sendTaxiReply(TaxiReply.shapeshifted);
        if (generic.active)
            return sendTaxiReply(TaxiReply.playerBusy);
        const start = context.client.taxiNodes.lookup(nodes[0]);
        if (start is null)
            return sendTaxiReply(TaxiReply.noSuchPath);
        const at = player.position;
        if (start.mapId != map.id || (start.x - at.x) ^^ 2 + (start.y - at.y) ^^ 2 + (start.z - at.z) ^^ 2
            > (2 * interactionDistance) ^^ 3)
            return sendTaxiReply(TaxiReply.tooFarAway);
        TaxiFlight flight;
        if (!planFlight(context.client, nodes, reputationPriceDiscount(npc.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE),
                flight))
            return sendTaxiReply(TaxiReply.unspecified);
        // The mount: the first node's, for the player's team.
        const mountCreature = taxiMountCreature(start, context.client.teamForRace(player.data.race));
        const mountTemplate = mountCreature in context.data.creatureTemplates;
        const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, map.random);
        if (!display)
            return sendTaxiReply(TaxiReply.unspecified);
        if (player.money < flight.cost)
            return sendTaxiReply(TaxiReply.notEnoughMoney);

        stopAttack(false);
        cancelTrade(true);
        player.modifyMoney(-cast(long) flight.cost);
        sendTaxiReply(TaxiReply.ok);
        // `MoveTaxi`: mounted, flagged, along the path from where the player stands.
        player.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
        player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS | UnitFlags.taxiFlight);
        flushPlayerChanges();
        Vector3[] path = [Vector3(at.x, at.y, at.z)] ~ flight.points;
        taxiSpline = MoveSpline(path, SplineFlags.flying, flightSpeed, ++taxiSplineId);
        taxiDestination = flight.to;
        taxiRelocate = 0;
        map.sendToWatchers(this, Opcode.SMSG_MONSTER_MOVE, monsterMove(player.guid, taxiSpline), true);
        info!"%s: '%s' flies from node %s to %s (%s copper, %s ms)"(remoteAddress, player.data.name, flight.from,
            flight.to, flight.cost, taxiSpline.duration);
    }

    private uint taxiSplineId;

    /// The flight goes on: the server follows the spline; at its end the player lands.
    void updateTaxi(int ms)
    {
        if (!flying)
            return;
        taxiSpline.update(ms);
        player.movement.position = taxiSpline.position();
        taxiRelocate -= ms;
        if (taxiRelocate <= 0)
        {
            taxiRelocate = 1000;
            map.relocated(this);
        }
        if (taxiSpline.finalized)
            landTaxi();
    }

    /// `OnTaxiFlightSplineEnd` and `OnTaxiFlightEnd`: unmounted, unflagged, at the destination node.
    void landTaxi()
    {
        const destination = context.client.taxiNodes.lookup(taxiDestination);
        taxiDestination = 0;
        player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.taxiFlight);
        flushPlayerChanges();
        if (destination !is null)
            teleportTo(map.id, Position(destination.x, destination.y, destination.z, player.position.orientation));
    }

    /// Leaving the world in flight: the character is saved at the destination, on the ground.
    package void taxiOnLeave()
    {
        if (!flying)
            return;
        if (const destination = context.client.taxiNodes.lookup(taxiDestination))
            player.movement.position = Position(destination.x, destination.y, destination.z,
                player.position.orientation);
        taxiDestination = 0;
        player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.taxiFlight);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * The first talk with a flight master learns its node; then it shows the known ones. A flight to
 * a known node costs its price, mounts and flags the player, and moves it along the path, landing
 * it at the destination; an unknown node is refused.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : taxiNodesFormat, taxiPathFormat, taxiPathNodeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.taxi : knowsNode, learnNode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    // Node 2 by the trainer, node 5 320 yards east; the mount is the innkeeper's model.
    uint[] node(uint id, float x, float y, float z)
    {
        auto row = new uint[taxiNodesFormat.length];
        row[0] = id;
        row[2] = bits(x);
        row[3] = bits(y);
        row[4] = bits(z);
        row[14] = creatureInnkeeper;
        row[15] = creatureInnkeeper;
        return row;
    }
    context.client.taxiNodes = typeof(context.client.taxiNodes).parse(buildDbc(taxiNodesFormat,
        [node(2, -8949, -132, 83.5f), node(5, -8629, -132, 83.5f)]), "TaxiNodes.dbc");
    context.client.taxiPaths = typeof(context.client.taxiPaths).parse(buildDbc(taxiPathFormat, [[10u, 2, 5, 120]]),
        "TaxiPath.dbc");
    context.client.taxiPathNodes = typeof(context.client.taxiPathNodes).parse(buildDbc(taxiPathNodeFormat,
        [[1u, 10, 0, 0, bits(-8949), bits(-132), bits(100), 0, 0], [2u, 10, 1, 0, bits(-8629), bits(-132), bits(100), 0, 0]]),
        "TaxiPathNode.dbc");
    context.client.buildIndexes();

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    me.modifyMoney(500);
    auto master = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    master.values.set!UNIT_NPC_FLAGS(master.values.get!UNIT_NPC_FLAGS | NpcFlag.flightMaster);
    anduin.read();

    // First talk: node 2 learned.
    anduin.write(Opcode.CMSG_TAXIQUERYAVAILABLENODES, ClientGuid(master.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_NEW_TAXI_PATH) && knowsNode(me.data.taxiMask, 2));
    // Then the map of the known nodes.
    anduin.write(Opcode.CMSG_TAXIQUERYAVAILABLENODES, ClientGuid(master.guid));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_SHOWTAXINODES]);

    ubyte[] flyTo(uint to)
    {
        ByteWriter w;
        w.put(master.guid);
        w.put(2u);
        w.put(to);
        return w.data.dup;
    }
    // Node 5 is not known yet.
    anduin.write(Opcode.CMSG_ACTIVATETAXI, flyTo(5));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ACTIVATETAXIREPLY] && !anduin.session.flying);
    learnNode(me.data.taxiMask, 5);
    anduin.write(Opcode.CMSG_ACTIVATETAXI, flyTo(5));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MONSTER_MOVE) && anduin.session.flying);
    assert(me.money == 500 - 120 && me.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0);
    assert(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight);
    // 320 yards at 32 a second: about 10 s; half way it is in the air, half way along.
    anduin.session.update(5000.msecs);
    assert(me.position.x > -8820 && me.position.x < -8790 && me.position.z > 90, "the climb, then 140 yards east");
    anduin.session.update(6000.msecs);
    assert(!anduin.session.flying && me.values.get!UNIT_FIELD_MOUNTDISPLAYID == 0, "landed");
    assert(!(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight));
}
