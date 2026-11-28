/**
 * A server packet as game code hands it to a sink: its opcode and its body, built by a function of
 * `dmangos.protocol` (docs/PROTOCOL.md). Game code names neither the opcode nor the bytes.
 */
module dmangos.protocol.packet;

import dmangos.world.opcodes : Opcode;

/// One server packet: what a sink (`deliver`, `sendToObservers`, ...) sends.
struct Packet
{
    Opcode opcode;
    const(ubyte)[] body_;
}
