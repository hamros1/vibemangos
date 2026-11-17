/**
 * What a cluster service call costs (docs/SERVICES.md, stage 7): a call answered on its own node (a
 * direct method call), and one through the remote path (the request encoded, dispatched from bytes on
 * the "other" node, the reply encoded and decoded), with an in-memory link between two hosts: the cost
 * of the call itself, without the network.
 *
 *   dmd -O -release -inline -Isource tools/servicebench.d source/dmangos/cluster/services.d \
 *       source/dmangos/cluster/protocol.d source/dmangos/cluster/regions.d source/dmangos/plaindata.d \
 *       source/dmangos/serialization.d source/dmangos/bytes.d source/dmangos/log.d && ./servicebench
 */
module servicebench;

import core.time : MonoTime;
import std.stdio : writefln;

import dmangos.cluster.protocol : ServiceCall, ServiceReply;
import dmangos.cluster.services;

/// A request the size of a channel command: a guid, a name, a channel, a line of chat.
struct Speak
{
    ulong guid;
    string name;
    ubyte race;
    string channel;
    string text;
    uint language;
}

struct Heard
{
    uint listeners;
}

@Service(ServiceKind.example)
struct Echo
{
    uint said;

    @Call Heard speak(const ref Speak s)
    {
        ++said;
        return Heard(cast(uint) s.text.length);
    }
}

void main()
{
    enum n = 1_000_000;
    const speak = Speak(0x1234, "Anduin", 1, "Stormwind", "Is anyone up for the Deadmines?", 7);

    auto here = new ServiceHost;
    here.host(Echo());
    uint heard;
    auto t0 = MonoTime.currTime;
    foreach (_; 0 .. n)
        here.call!(Echo.speak)(speak, (Heard h) { heard += h.listeners; });
    const local = (MonoTime.currTime - t0).total!"nsecs" / double(n);

    auto a = new ServiceHost, b = new ServiceHost;
    a.self = 1;
    b.self = 2;
    a.placement = (ServiceKind) => cast(ushort) 2;
    b.host(Echo());
    a.sendCall = (ushort, const ref ServiceCall c) { b.receiveCall(1, c); return true; };
    b.sendReply = (ushort, const ref ServiceReply r) { a.receiveReply(2, r); return true; };
    enum m = 200_000;
    t0 = MonoTime.currTime;
    foreach (_; 0 .. m)
        a.call!(Echo.speak)(speak, (Heard h) { heard += h.listeners; });
    const remote = (MonoTime.currTime - t0).total!"nsecs" / double(m);

    writefln("local call:  %.0f ns", local);
    writefln("remote call: %.0f ns (encode, dispatch from bytes, reply; no network)", remote);
    writefln("(%s heard)", heard);
}
