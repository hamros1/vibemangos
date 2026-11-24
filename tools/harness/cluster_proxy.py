"""A loopback TCP relay that can partition fixture-owned cluster links."""

import asyncio
import struct


class ClusterProxy:
    # The proxy takes the advertised port on a separate loopback address. The
    # worldserver still listens on its usual port on 127.0.0.1.
    ADDRESS = "127.0.0.2"
    DESTINATION = "127.0.0.1"

    def __init__(self, ports):
        self.ports = ports
        self.blocked = set()
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
            pumps = [asyncio.create_task(self.copy(reader, peer)),
                     asyncio.create_task(self.copy(peer_reader, writer))]
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

    @staticmethod
    async def copy(reader, writer):
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
