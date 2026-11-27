/**
 * Flight masters: the client's taxi requests, starting a flight, and the flight itself.
 *
 * A flight master's node becomes known the first time the player talks to it; afterwards it shows
 * the known nodes. A flight to one of them (directly, or over several legs) costs its price (10%
 * less at honored with the master's faction): the player mounts its node's flying mount and flies
 * the path at 32 yards a second, as `SMSG_MONSTER_MOVE` shows everyone, while the server follows
 * it to keep its place on the map; at the end it lands at the destination node.
 *
 * A flight is saved as it goes (`characters.taxi_path`, CMaNGOS's format: the path point ahead and the path):
 * logged out in flight, or after a crash, the character comes back at that point of the path and flies the
 * rest of the leg it was on, unpaid, landing at that leg's end (`resumeSavedFlight`).
 */
module dmangos.world.taxihandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
final class Taxi
{
    import dmangos.world.character : Character, Handles;
    import dmangos.world.session : WorldState;
    import dmangos.world.spellcast : SpellCastResult;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import dmangos.world.money : Copper;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info, warning;
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

    package MoveSpline taxiSpline; // the flight under way
    TaxiFlight taxiFlight;       // what it flies: its points come after the spline's first (where it began)
    uint taxiDestination;        // its last node; 0: not flying
    int taxiRelocate;            // until the map hears of the position again
    int taxiSavedPoint = -1;     // the spline point `player.data.taxiPath` was last written for

    /// Whether the player is on a flight.
    package @property bool flying() const
    {
        return taxiDestination != 0;
    }

    /// The node a flight master stands at, for this player's team; 0 if none.
    uint taxiNodeOf(const Npc npc)
    {
        return nearestTaxiNode(me.context.client, npc.position, me.map.id, me.context.client.teamForRace(me.player.data.race));
    }

    /// The client asks whether the master's node is known (for the flight master's icon).
    @Handles(Opcode.CMSG_TAXINODE_STATUS_QUERY, WorldState.inWorld)
    void handleTaxiNodeStatusQuery(const ClientGuid request)
    {
        auto npc = me.context.npcFor(me.map.findObject(request.guid));
        if (npc is null)
            return;
        const node = taxiNodeOf(npc);
        if (node == 0)
            return;
        ByteWriter w;
        w.put(request.guid);
        w.put(cast(ubyte)(knowsNode(me.player.data.taxiMask, node) ? 1 : 0));
        me.deliver(Opcode.SMSG_TAXINODE_STATUS, w.data);
    }

    /// The player talks to a flight master: a new node learned, or the map of the known ones.
    @Handles(Opcode.CMSG_TAXIQUERYAVAILABLENODES, WorldState.inWorld)
    void handleTaxiQueryAvailableNodes(const ClientGuid request)
    {
        auto npc = me.interactableNpc(request.guid, NpcFlag.flightMaster);
        if (npc is null)
            return;
        const node = taxiNodeOf(npc);
        if (node == 0)
            return;
        // A node not known yet: learned, and the client told.
        if (learnNode(me.player.data.taxiMask, node))
        {
            me.deliver(Opcode.SMSG_NEW_TAXI_PATH, null);
            ByteWriter w;
            w.put(request.guid);
            w.put(ubyte(1));
            me.deliver(Opcode.SMSG_TAXINODE_STATUS, w.data);
            info!"%s: '%s' learned flight node %s"(me.remoteAddress, me.player.data.name, node);
            return;
        }
        // The map of the known nodes.
        ByteWriter w;
        w.put(1u);
        w.put(request.guid);
        w.put(node);
        foreach (value; me.player.data.taxiMask)
            w.put(value);
        me.deliver(Opcode.SMSG_SHOWTAXINODES, w.data);
    }

    /// Tells the client whether its flight starts, or why not (`SMSG_ACTIVATETAXIREPLY`).
    void sendTaxiReply(TaxiReply reply)
    {
        ByteWriter w;
        w.put(cast(uint) reply);
        me.deliver(Opcode.SMSG_ACTIVATETAXIREPLY, w.data);
    }

    /// The client asks for a flight to a node.
    @Handles(Opcode.CMSG_ACTIVATETAXI, WorldState.inWorld)
    void handleActivateTaxi(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        const uint[2] nodes = [reader.read!uint, reader.read!uint];
        auto npc = me.interactableNpc(guid, NpcFlag.flightMaster);
        if (npc is null)
            return;
        if (!knowsNode(me.player.data.taxiMask, nodes[0]) || !knowsNode(me.player.data.taxiMask, nodes[1]))
            return sendTaxiReply(TaxiReply.notVisited);
        activateTaxiPathTo(nodes[], npc);
    }

    /// The client asks for a flight over several nodes.
    @Handles(Opcode.CMSG_ACTIVATETAXIEXPRESS, WorldState.inWorld)
    void handleActivateTaxiExpress(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        reader.read!uint; // the client's total cost
        const count = reader.read!uint;
        auto npc = me.interactableNpc(guid, NpcFlag.flightMaster);
        if (npc is null || count > 64)
            return;
        uint[] nodes;
        foreach (_; 0 .. count)
        {
            const node = reader.read!uint;
            if (!knowsNode(me.player.data.taxiMask, node))
                return sendTaxiReply(TaxiReply.notVisited);
            nodes ~= node;
        }
        activateTaxiPathTo(nodes, npc);
    }

    /// The client's word that the flight's spline ended; the server follows its own.
    @Handles(Opcode.CMSG_MOVE_SPLINE_DONE, WorldState.inWorld)
    void handleMoveSplineDone(ref ByteReader reader)
    {
    }

    /// Starts a flight along `nodes` from a flight master: checks, payment, and take-off.
    void activateTaxiPathTo(const(uint)[] nodes, Npc npc)
    {
        enum float interactionDistance = 5;
        if (nodes.length < 2 || flying)
            return;
        if (me.loggingOut || me.inCombat)
            return sendTaxiReply(TaxiReply.playerBusy);
        if (me.player.values.get!UNIT_FIELD_MOUNTDISPLAYID)
            return sendTaxiReply(TaxiReply.alreadyMounted);
        // No flying in a shapeshift form, except the warrior's stances, Shadowform and Stealth.
        enum ubyte battleStance = 17, defensiveStance = 18, berserkerStance = 19, shadow = 28, stealth = 30;
        const form = me.player.values.getByte!UNIT_FIELD_BYTES_1(2);
        if (form && form != battleStance && form != defensiveStance && form != berserkerStance && form != shadow
            && form != stealth)
            return sendTaxiReply(TaxiReply.shapeshifted);
        if (me.generic.active)
            return sendTaxiReply(TaxiReply.playerBusy);
        const start = me.context.client.taxiNodes.lookup(nodes[0]);
        if (start is null)
            return sendTaxiReply(TaxiReply.noSuchPath);
        // The first node is the flight master's own: within 10 yards of it (every flight master in the world
        // database stands within 7.1 yards of its node). The player is within reach of the flight master already.
        const at = npc.position;
        if (start.mapId != me.map.id || (start.x - at.x) ^^ 2 + (start.y - at.y) ^^ 2 + (start.z - at.z) ^^ 2
            > (2 * interactionDistance) ^^ 2)
            return sendTaxiReply(TaxiReply.tooFarAway);
        TaxiFlight flight;
        if (!planFlight(me.context.client, nodes, me.reputationPriceDiscount(npc.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE),
                flight))
            return sendTaxiReply(TaxiReply.unspecified);
        // The mount: the first node's, for the player's team.
        const mountCreature = taxiMountCreature(start, me.context.client.teamForRace(me.player.data.race));
        const mountTemplate = mountCreature in me.context.data.creatureTemplates;
        const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, me.map.random);
        if (!display)
            return sendTaxiReply(TaxiReply.unspecified);
        if (!me.player.canAfford(Copper(flight.cost)))
            return sendTaxiReply(TaxiReply.notEnoughMoney);

        me.stopAttack(false);
        me.cancelTrade(true);
        me.player.pay(Copper(flight.cost));
        sendTaxiReply(TaxiReply.ok);
        takeOff(flight, display);
        info!"%s: '%s' flies from node %s to %s (%s copper, %s ms)"(me.remoteAddress, me.player.data.name, flight.from,
            flight.to, flight.cost, taxiSpline.duration);
    }

    /**
     * A spell's flight (`SPELL_EFFECT_SEND_TAXI`, CMaNGOS's `ActivateTaxiPathTo(pathId, spellId)`): along taxi path
     * `pathId`, free, on its first node's mount for the player's team (none if it has none). The player is near its
     * first node, if that node has a place (CMaNGOS's bound: a squared distance of 1000, about 31.6 yards); the mount
     * and a shapeshift it may not fly in come off, its cast and its fight stop.
     */
    package bool flyTaxiPath(uint pathId)
    {
        import dmangos.world.auras : AuraType;

        const entry = me.context.client.taxiPaths.lookup(pathId);
        if (entry is null || flying || me.player is null)
            return false;
        if (me.loggingOut || me.inCombat)
        {
            sendTaxiReply(TaxiReply.playerBusy);
            return false;
        }
        const start = me.context.client.taxiNodes.lookup(entry.from);
        if (start is null)
        {
            sendTaxiReply(TaxiReply.noSuchPath);
            return false;
        }
        const at = me.player.position;
        if ((start.x != 0 || start.y != 0 || start.z != 0) && (start.mapId != me.map.id
                || (start.x - at.x) ^^ 2 + (start.y - at.y) ^^ 2 + (start.z - at.z) ^^ 2 > 1000))
        {
            sendTaxiReply(TaxiReply.tooFarAway);
            return false;
        }
        TaxiFlight flight;
        if (!planFlight(me.context.client, [entry.from, entry.to], 0, flight))
        {
            sendTaxiReply(TaxiReply.unspecified);
            return false;
        }
        enum ubyte battleStance = 17, defensiveStance = 18, berserkerStance = 19, shadow = 28, stealth = 30;
        const form = me.player.values.getByte!UNIT_FIELD_BYTES_1(2);
        const keepsForm = !form || form == battleStance || form == defensiveStance || form == berserkerStance
            || form == shadow || form == stealth;
        foreach (aura; me.player.auras.list.dup)
            if (aura.has(AuraType.mounted) || (!keepsForm && aura.has(AuraType.modShapeshift)))
                me.removeAura(aura);
        if (me.player is null)
            return false;
        me.interruptCast(SpellCastResult.interrupted);
        const mountCreature = taxiMountCreature(start, me.context.client.teamForRace(me.player.data.race));
        const mountTemplate = mountCreature in me.context.data.creatureTemplates;
        const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, me.map.random);
        me.stopAttack(false);
        me.cancelTrade(true);
        sendTaxiReply(TaxiReply.ok);
        takeOff(flight, display);
        info!"%s: '%s' flies by a spell along path %s from node %s to %s (%s ms)"(me.remoteAddress, me.player.data.name,
            pathId, flight.from, flight.to, taxiSpline.duration);
        return true;
    }

    /// Mounted on `display`, flagged, along `flight` from where the player is.
    private void takeOff(ref TaxiFlight flight, uint display)
    {
        import dmangos.world.pet : PetSlot;

        // The pet stays behind until the landing (`Player::Mount` without an aura: `UnsummonPetTemporaryIfAny`).
        if (me.ownPet !is null)
            me.unsummonPet(PetSlot.current);
        const at = me.player.position;
        me.player.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
        me.player.values.set!UNIT_FIELD_FLAGS(me.player.values.get!UNIT_FIELD_FLAGS | UnitFlags.taxiFlight);
        me.flushPlayerChanges();
        Vector3[] path = [Vector3(at.x, at.y, at.z)] ~ flight.points;
        taxiSpline = MoveSpline(path, SplineFlags.flying, flightSpeed, ++taxiSplineId);
        taxiFlight = flight;
        taxiDestination = flight.to;
        taxiRelocate = 0;
        taxiSavedPoint = -1;
        noteFlightPoint();
        me.map.sendToWatchers(me, Opcode.SMSG_MONSTER_MOVE, monsterMove(me.player.guid, taxiSpline), true);
    }

    // `player.data.taxiPath`, what a save writes, follows the flight: the path point ahead of the player.
    private void noteFlightPoint()
    {
        const segment = taxiSpline.currentPathIndex; // spline point `segment` is `taxiFlight.points[segment - 1]`
        if (segment == taxiSavedPoint)
            return;
        taxiSavedPoint = segment;
        me.player.data.taxiPath = taxiPathText(resumePoint(me.context.client, taxiFlight, segment));
    }

    /**
     * At login: a flight saved under way (`characters.taxi_path`) goes on from where it was saved, along the
     * rest of its leg, mounted as from the leg's first node. The character was put at that point when it was
     * saved; an older format's single node puts it there instead, and anything unreadable home.
     */
    void resumeSavedFlight()
    {
        PathPoint at;
        uint node;
        const text = me.player.data.taxiPath;
        const saved = readTaxiPath(text, at, node);
        me.player.data.taxiPath = null;
        final switch (saved)
        {
        case SavedFlight.none:
            return;
        case SavedFlight.node:
            if (const n = me.context.client.taxiNodes.lookup(node))
            {
                me.teleportTo(n.mapId, Position(n.x, n.y, n.z, me.player.position.orientation));
                return;
            }
            goto case SavedFlight.invalid;
        case SavedFlight.invalid:
            warning!"'%s': flight '%s' not understood; sent home"(me.player.data.name, text);
            return teleportHome();
        case SavedFlight.flight:
            TaxiFlight flight;
            const path = me.context.client.taxiPaths.lookup(at.path);
            if (!resumeFlight(me.context.client, at, flight) || flight.mapId != me.map.id)
            {
                warning!"'%s': flight on path %s from point %s cannot go on; sent home"(me.player.data.name, at.path,
                    at.index);
                return teleportHome();
            }
            const mountCreature = taxiMountCreature(me.context.client.taxiNodes.lookup(path.from),
                me.context.client.teamForRace(me.player.data.race));
            const mountTemplate = mountCreature in me.context.data.creatureTemplates;
            const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, me.map.random);
            if (!display)
                return teleportHome();
            // From the saved point itself (where the character is), not from a step before it.
            const start = flight.points[0];
            me.player.movement.position = Position(start.x, start.y, start.z, me.player.position.orientation);
            flight.points = flight.points[1 .. $];
            flight.pathPoints = flight.pathPoints[1 .. $];
            takeOff(flight, display);
            info!"%s: '%s' flies on along path %s from point %s to node %s (%s ms)"(me.remoteAddress, me.player.data.name,
                at.path, at.index, flight.to, taxiSpline.duration);
        }
    }

    // Home: the hearthstone's place.
    private void teleportHome()
    {
        const home = me.player.data.homeBind;
        me.teleportTo(home.map, Position(home.x, home.y, home.z, me.player.position.orientation));
    }

    private uint taxiSplineId;

    /// The flight goes on: the server follows the spline; at its end the player lands.
    void updateTaxi(int ms)
    {
        if (!flying)
            return;
        taxiSpline.update(ms);
        me.player.movement.position = taxiSpline.position();
        noteFlightPoint();
        taxiRelocate -= ms;
        if (taxiRelocate <= 0)
        {
            taxiRelocate = 1000;
            me.map.relocated(me);
        }
        if (taxiSpline.finalized)
            landTaxi();
    }

    /// The flight ends: unmounted, unflagged, at the destination node.
    void landTaxi()
    {
        const destination = me.context.client.taxiNodes.lookup(taxiDestination);
        taxiDestination = 0;
        me.player.data.taxiPath = null;
        me.player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        me.player.values.set!UNIT_FIELD_FLAGS(me.player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.taxiFlight);
        me.flushPlayerChanges();
        me.pvpArrived();
        if (destination !is null)
            me.teleportTo(me.map.id, Position(destination.x, destination.y, destination.z, me.player.position.orientation));
        me.petsOnArrival(); // the pet comes back (`Player::Unmount`: `ResummonPetTemporaryUnSummonedIfAny`)
    }

    /**
     * Leaving the world in flight: saved at the path point ahead with `taxi_path` (CMaNGOS puts the character
     * there when it loads it), unmounted; the next login flies on (`resumeSavedFlight`).
     */
    package void taxiOnLeave()
    {
        if (!flying)
            return;
        PathPoint at;
        uint node;
        if (readTaxiPath(me.player.data.taxiPath, at, node) == SavedFlight.flight)
            foreach (point; me.context.client.taxiPathPoints.get(at.path, null))
                if (point.index == at.index)
                    me.player.movement.position = Position(point.x, point.y, point.z, me.player.position.orientation);
        taxiDestination = 0;
        me.player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        me.player.values.set!UNIT_FIELD_FLAGS(me.player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.taxiFlight);
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
    import dmangos.bytes : bits = floatBits;
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
    // Node 6, 20 yards from the flight master: another's.
    context.client.taxiNodes = typeof(context.client.taxiNodes).parse(buildDbc(taxiNodesFormat,
        [node(2, -8949, -132, 83.5f), node(5, -8629, -132, 83.5f), node(6, -8929, -132, 83.5f)]), "TaxiNodes.dbc");
    context.client.taxiPaths = typeof(context.client.taxiPaths).parse(buildDbc(taxiPathFormat,
        [[10u, 2, 5, 120], [11u, 6, 5, 100]]), "TaxiPath.dbc");
    context.client.taxiPathNodes = typeof(context.client.taxiPathNodes).parse(buildDbc(taxiPathNodeFormat,
        [[1u, 10, 0, 0, bits(-8949), bits(-132), bits(100), 0, 0], [2u, 10, 1, 0, bits(-8629), bits(-132), bits(100), 0, 0],
         [3u, 11, 0, 0, bits(-8929), bits(-132), bits(100), 0, 0], [4u, 11, 1, 0, bits(-8629), bits(-132), bits(100), 0, 0]]),
        "TaxiPathNode.dbc");
    context.client.buildIndexes();

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    me.receive(Copper(500));
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
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ACTIVATETAXIREPLY] && !anduin.session.inWorld.taxi.flying);
    learnNode(me.data.taxiMask, 5);
    // Not from node 6: it is not this flight master's (20 yards off).
    learnNode(me.data.taxiMask, 6);
    {
        ByteWriter w;
        w.put(master.guid);
        w.put(6u);
        w.put(5u);
        anduin.write(Opcode.CMSG_ACTIVATETAXI, w.data.dup);
        assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ACTIVATETAXIREPLY] && !anduin.session.inWorld.taxi.flying,
            "another flight master's node");
    }
    anduin.write(Opcode.CMSG_ACTIVATETAXI, flyTo(5));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MONSTER_MOVE) && anduin.session.inWorld.taxi.flying);
    assert(me.money == Copper(500 - 120) && me.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0);
    assert(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight);
    // 320 yards at 32 a second: about 10 s; half way it is in the air, half way along.
    anduin.session.update(5000.msecs);
    assert(me.position.x > -8820 && me.position.x < -8790 && me.position.z > 90, "the climb, then 140 yards east");
    anduin.session.update(6000.msecs);
    assert(!anduin.session.inWorld.taxi.flying && me.values.get!UNIT_FIELD_MOUNTDISPLAYID == 0, "landed");
    assert(!(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight));
}

/**
 * Logged out in flight: saved at the path point ahead with `taxi_path`; logged in again, the character flies on
 * from there along the rest of the leg, without paying, and lands at its end.
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
    import dmangos.world.player : CharacterData, Player;
    import dmangos.world.taxi : learnNode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
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
    // Node 2 by the trainer, node 5 320 yards east; the path has a point half way.
    context.client.taxiNodes = typeof(context.client.taxiNodes).parse(buildDbc(taxiNodesFormat,
        [node(2, -8949, -132, 83.5f), node(5, -8629, -132, 83.5f)]), "TaxiNodes.dbc");
    context.client.taxiPaths = typeof(context.client.taxiPaths).parse(buildDbc(taxiPathFormat, [[10u, 2, 5, 120]]),
        "TaxiPath.dbc");
    context.client.taxiPathNodes = typeof(context.client.taxiPathNodes).parse(buildDbc(taxiPathNodeFormat,
        [[1u, 10, 0, 0, bits(-8949), bits(-132), bits(100), 0, 0],
         [2u, 10, 1, 0, bits(-8789), bits(-132), bits(100), 0, 0],
         [3u, 10, 2, 0, bits(-8629), bits(-132), bits(100), 0, 0]]), "TaxiPathNode.dbc");
    context.client.buildIndexes();

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto me = cast(Player) anduin.session.character;
    me.receive(Copper(500));
    learnNode(me.data.taxiMask, 2);
    learnNode(me.data.taxiMask, 5);
    auto master = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    master.values.set!UNIT_NPC_FLAGS(master.values.get!UNIT_NPC_FLAGS | NpcFlag.flightMaster);
    anduin.read();
    ByteWriter w;
    w.put(master.guid);
    w.put(2u);
    w.put(5u);
    anduin.write(Opcode.CMSG_ACTIVATETAXI, w.data);
    anduin.read();
    assert(anduin.session.inWorld.taxi.flying && me.money == Copper(380));
    anduin.session.update(3000.msecs); // short of the middle point
    assert(me.data.taxiPath == "1#10", me.data.taxiPath);

    // Out, in flight: saved at the point ahead, unmounted, the flight kept.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const saved = db.progressSaves[$ - 1];
    assert(saved.taxiPath == "1#10");
    assert(saved.position.x == -8789 && saved.position.z == 100, "at the point it flies on from");

    // In again: flying on from there, mounted, for nothing.
    auto again = loggedIn(context, db, 7, "Anduin", saved.position, AccountLevel.gameMaster, raceHuman, 0, 1,
        (ref CharacterData c) { c.taxiPath = saved.taxiPath; c.money = 380; });
    auto back = cast(Player) again.session.character;
    assert(again.session.inWorld.taxi.flying && back.money == Copper(380));
    assert(back.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0 && (back.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight));
    const spline = again.session.inWorld.taxi.taxiSpline; // sent as login ends (the login packets were read)
    assert(spline.path[0].x == -8789 && spline.duration > 4500 && spline.duration < 5500, "the second half");
    again.session.update(6000.msecs); // 160 yards: 5 s
    assert(!again.session.inWorld.taxi.flying && back.position.x > -8640, "landed at node 5");
    assert(back.data.taxiPath is null);
}
