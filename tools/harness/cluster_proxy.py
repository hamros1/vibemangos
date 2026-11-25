"""A loopback TCP relay that can partition fixture-owned cluster links, or drop or delay frames on them."""

import asyncio
import struct


class ClusterProxy:
    # The proxy takes the advertised port on a separate loopback address. The
    # worldserver still listens on its usual port on 127.0.0.1.
    ADDRESS = "127.0.0.2"
    DESTINATION = "127.0.0.1"

    def __init__(self, ports, observe=None):
        self.ports = ports
        self.observe = observe
        self.blocked = set()
        self.dropping = {}
        self.dropped = {}
        self.delays = {}
        self.links = {}
        self.tasks = set()
        self.listeners = []

    async def __aenter__(self):
        try:
            for node, port in self.ports.items():
                def accept(reader, writer, target=node):
                    self.links[writer] = (None, None)
                    task = asyncio.create_task(self.relay(target, reader, writer))
                    self.tasks.add(task)
                    task.add_done_callback(self.tasks.discard)

                server = await asyncio.start_server(accept, self.ADDRESS, port)
                self.listeners.append(server)
        except BaseException:
            await self.close()
            raise
        return self

    async def __aexit__(self, *_):
        await self.close()

    async def close(self):
        for server in self.listeners:
            server.close()
        for writer in self.links:
            writer.transport.abort()
        tasks = tuple(self.tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(server.wait_closed() for server in self.listeners))

    async def partition(self, blocked):
        self.blocked = set(blocked)
        for writer, (link, peer) in self.links.items():
            if link in self.blocked:
                writer.transport.abort()
                if peer is not None:
                    peer.transport.abort()

    async def drop(self, kinds):
        """Discard frames of the given message kinds, by (source, target) direction, until called again."""
        self.dropping = {direction: frozenset(types) for direction, types in kinds.items()}

    async def delay(self, delays):
        """Hold every frame of the given (source, target) directions for so many seconds, in order, until called again."""
        self.delays = dict(delays)

    async def dropped_frames(self, direction):
        return self.dropped.get(direction, 0)

    async def live_links(self):
        return {link for writer, (link, peer) in self.links.items()
                if peer is not None and not writer.is_closing() and not peer.is_closing()}

    async def relay(self, target, reader, writer):
        peer = None
        pumps = []
        try:
            # protocol.d defines the 16-byte frame and the first payload, Hello.
            # Only its node ID is needed. Forward all frames unmodified.
            header = await asyncio.wait_for(reader.readexactly(16), timeout=3)
            length, kind, flags, sequence = struct.unpack("<IHHQ", header)
            if kind != 1 or flags or sequence or not 5 <= length <= 1024:
                raise RuntimeError("expected an unsequenced cluster Hello frame")
            hello = await asyncio.wait_for(reader.readexactly(length), timeout=3)
            node_offset = 3 + hello[2]  # protocol version, cluster name length, cluster name
            if node_offset + 2 > length:
                raise RuntimeError("truncated node ID in cluster Hello")
            source, = struct.unpack_from("<H", hello, node_offset)
            if source not in self.ports or source == target:
                raise RuntimeError(f"unexpected cluster link {source} -> {target}")
            link = frozenset((source, target))
            if link in self.blocked:
                return
            self.links[writer] = (link, None)
            peer_reader, peer = await asyncio.open_connection(self.DESTINATION, self.ports[target])
            if link in self.blocked or writer.is_closing():
                return
            self.links[writer] = (link, peer)
            peer.write(header + hello)
            pumps = [asyncio.create_task(self.copy(reader, peer, (source, target))),
                     asyncio.create_task(self.copy(peer_reader, writer, (target, source)))]
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, EOFError, asyncio.TimeoutError):
            # Startup and deliberate cuts can close either side of a link.
            pass
        finally:
            self.links.pop(writer, None)
            writer.transport.abort()
            if peer is not None:
                peer.transport.abort()
            for pump in pumps:
                pump.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)

    async def copy(self, reader, writer, direction):
        # Whole frames, so that a dropped one leaves the stream intact. Only unsequenced
        # messages (heartbeats, quorum votes and leases) can be dropped without a resend or a gap.
        # A delayed frame goes on once its delay has passed since it came, after those that came before it.
        loop = asyncio.get_running_loop()
        waiting = asyncio.Queue()

        async def deliver():
            while True:
                due, frame = await waiting.get()
                if due > loop.time():
                    await asyncio.sleep(due - loop.time())
                writer.write(frame)
                await writer.drain()

        delivery = asyncio.create_task(deliver())
        try:
            while True:
                header = await reader.readexactly(16)
                length, kind = struct.unpack_from("<IH", header)
                payload = await reader.readexactly(length)
                if self.observe is not None:
                    self.observe(direction, kind, payload)
                if kind in self.dropping.get(direction, ()):
                    self.dropped[direction] = self.dropped.get(direction, 0) + 1
                    continue
                if delivery.done():
                    delivery.result()  # the peer's side failed: raises why
                waiting.put_nowait((loop.time() + self.delays.get(direction, 0), header + payload))
        finally:
            delivery.cancel()
            await asyncio.gather(delivery, return_exceptions=True)
