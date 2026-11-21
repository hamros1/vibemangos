/**
 * A gateway keeps the socket and routes its player's simulation. Every handoff goes through
 * the gateway so the coordinator can fence the exact process that owns the saved character.
 */
module dmangos.world.gatewaysessions;

package mixin template GatewaySessions()
{
    import core.time : MonoTime, seconds;
    import dmangos.cluster.protocol : PlayerMessage, PlayerMessageKind, SessionRoute, SessionRouteKind,
        SessionRouteResult, SimulationOwner;
    import dmangos.world.session : WorldSession, WorldState;

    private final class GatewayRoute
    {
        WorldSession client;
        uint character;
        ulong ownerToken;
        SimulationOwner owner, coordinator;
        SessionRoute pending;
        const(ubyte)[] state;
        MonoTime sendAt;
        bool granted, closing, disconnectSent;
    }

    private GatewayRoute[uint] gatewayRoutes;

    private SimulationOwner linkedOwner(ushort id, bool allowClosing = false)
    {
        if (id == node.id)
            return node.simulationOwner(id);
        if (auto link = node.linkTo(id))
            if (allowClosing || !link.wantsClose)
                return SimulationOwner(id, link.peer.incarnation);
        return SimulationOwner.init;
    }

    private void startGatewayMove(uint account, ushort target, const(ubyte)[] state, ushort previous)
    {
        auto route = gatewayRoutes.get(account, null);
        if (previous == node.id)
        {
            auto client = cast(WorldSession) context.sessionOf(account);
            if (route !is null || client is null || !client.gatewayCharacter)
                return;
            route = new GatewayRoute;
            route.client = client;
            route.character = client.gatewayCharacter;
            route.owner = node.simulationOwner(node.id);
            gatewayRoutes[account] = route;
        }
        if (route is null || route.owner != linkedOwner(previous, true) || route.pending.token)
            return;
        route.state = state.dup;
        setGatewayRoute(route, account, SessionRouteKind.move, node.simulationOwner(target));
    }

    private void setGatewayRoute(GatewayRoute route, uint account, SessionRouteKind kind, SimulationOwner target)
    {
        route.client.gatewayPaused = true;
        route.pending = SessionRoute(kind: kind, account: account, character: route.character,
            serial: context.sessionSerial(route.client), token: context.nextGameplaySequence(), previous: route.owner,
            next: target);
        route.sendAt = MonoTime.init;
        route.granted = false;
    }

    void sessionRouteResult(const ref SessionRoute result)
    {
        if (result.kind == SessionRouteKind.observe)
            return;
        auto route = gatewayRoutes.get(result.account, null);
        if (route is null || result.token != route.pending.token || result.serial != route.pending.serial
            || result.kind != route.pending.kind || result.previous != route.pending.previous
            || result.next != route.pending.next)
            return;
        if (result.result == SessionRouteResult.granted)
        {
            route.owner = result.next;
            route.ownerToken = result.token;
            route.coordinator = node.simulationOwner(node.coordinatorNode);
            route.client.ownerMoved(route.owner.node);
            route.granted = true;
            route.disconnectSent = false;
            deliverGatewayRoute(route, result.account);
        }
        else if (result.result == SessionRouteResult.denied && result.kind == SessionRouteKind.move)
        {
            // The source had finished its save and stopped before it requested this move.
            finishGatewayRoute(result.account, false);
        }
        else if (result.kind == SessionRouteKind.recover
            && node.simulationOwner(route.owner.node) == route.owner)
        {
            // The coordinator still recognizes the former process. Let it resume on the same route.
            route.pending = SessionRoute.init;
        }
        else if (node.simulationOwner(result.next.node) != result.next)
        {
            // The request did not take effect. A newly granted region owner may take the checkpoint.
            route.pending.next = SimulationOwner.init;
        }
    }

    private void deliverGatewayRoute(GatewayRoute route, uint account)
    {
        import dmangos.bytes : ByteWriter;

        if (linkedOwner(route.owner.node) != route.owner)
            return;
        ByteWriter payload;
        payload.put(route.ownerToken);
        PlayerMessageKind kind;
        if (route.state.length)
        {
            kind = PlayerMessageKind.gatewayArrival;
            payload.putBytes(route.state);
        }
        else
        {
            kind = PlayerMessageKind.gatewayRecover;
            const auth = route.client.account;
            payload.put(cast(uint) auth.username.length);
            payload.putBytes(cast(const(ubyte)[]) auth.username);
            payload.put(cast(ubyte) auth.level);
            payload.put(auth.muteTime);
            payload.put(route.client.build);
            payload.put(route.character);
        }
        if (!node.sendTo(route.owner.node, PlayerMessage(kind, account, 0, cast(ubyte[]) payload.data)))
            return;
        route.state = null;
        route.pending = SessionRoute.init;
        route.granted = false;
        route.client.gatewayPaused = false;
        if (route.closing)
            sendGatewayDisconnect(route, account);
    }

    private SimulationOwner checkpointOwner(GatewayRoute route, uint account)
    {
        import dmangos.world.grid : cellKeyAt;

        const loaded = context.database.loadCharacter(route.character);
        if (loaded.isNull || loaded.get.account != account || !loaded.get.position.isFinite)
            return SimulationOwner.init;
        const saved = loaded.get;
        return node.simulationOwner(node.regions.ownerAt(saved.map, cellKeyAt(saved.position.x, saved.position.y)));
    }

    private void gatewayTick(MonoTime now)
    {
        const coordinator = node.simulationOwner(node.coordinatorNode);
        if (!coordinator.node || !context.canWrite() || !node.version_)
            return;
        foreach (account, route; gatewayRoutes)
        {
            if (route.granted)
            {
                if (node.simulationOwner(route.owner.node) == route.owner)
                {
                    deliverGatewayRoute(route, account);
                    continue;
                }
                route.granted = false;
                route.state = null;
                route.pending = SessionRoute.init;
            }
            if (!route.pending.token)
            {
                if (node.simulationOwner(route.owner.node) == route.owner)
                {
                    if (route.coordinator != coordinator)
                    {
                        const report = SessionRoute(kind: SessionRouteKind.observe, account: account,
                            character: route.character, serial: context.sessionSerial(route.client),
                            token: route.ownerToken, previous: route.owner, next: route.owner);
                        if (node.requestSessionRoute(report))
                            route.coordinator = coordinator;
                    }
                    route.client.gatewayPaused = linkedOwner(route.owner.node) != route.owner;
                    if (route.client.gatewayPaused)
                        route.disconnectSent = false;
                    else if (route.closing)
                        sendGatewayDisconnect(route, account);
                    continue;
                }
                route.client.gatewayPaused = true;
                if (now < route.sendAt)
                    continue;
                const destination = checkpointOwner(route, account);
                if (!destination.node || destination == route.owner)
                {
                    route.sendAt = now + 1.seconds;
                    continue;
                }
                setGatewayRoute(route, account, SessionRouteKind.recover, destination);
            }
            if (now < route.sendAt)
                continue;
            route.sendAt = now + 1.seconds;
            if (!route.pending.next.node)
            {
                const destination = checkpointOwner(route, account);
                if (!destination.node || destination == route.owner)
                    continue;
                route.pending.token = context.nextGameplaySequence();
                route.pending.next = destination;
            }
            node.requestSessionRoute(route.pending);
        }

        // A live gateway may temporarily lose this direct link. Only the coordinator's view
        // establishes that the client is gone for good.
        WorldSession[] orphans;
        foreach (session; remote)
            if (session.gatewayHome.node && node.simulationOwner(session.home) != session.gatewayHome)
                orphans ~= session;
        foreach (session; orphans)
            session.clientGone();
    }

    private void sendGatewayDisconnect(GatewayRoute route, uint account)
    {
        if (!route.disconnectSent && linkedOwner(route.owner.node) == route.owner)
            route.disconnectSent = node.sendTo(route.owner.node,
                PlayerMessage(PlayerMessageKind.disconnect, account, 0, null));
    }

    private void finishGatewayRoute(uint account, bool toCharacterScreen)
    {
        if (auto route = gatewayRoutes.get(account, null))
        {
            gatewayRoutes.remove(account);
            route.client.gatewayPaused = false;
            route.client.ownerLeft(toCharacterScreen);
        }
    }
}
