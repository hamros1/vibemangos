/// Test the event with the installed world database and the client's actual gossip/menu packets.
module dmangos.world.realscourge;

version(unittest):
import core.time : msecs;
import std.format : format;
import dmangos.world.realspelltests : RealWorld, haveRealData;
import dmangos.world.scourge;
import dmangos.world.testclient;
import dmangos.world.creature : Creature;
import dmangos.world.unit : Blow, dealDamage;
import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

unittest
{
    if (!haveRealData()) return;
    auto w = RealWorld.make(20261122, true);
    auto who = w.character(23, "Defender", 1, 60, []);
    auto me = who.session.inWorld;
    me.godModeCheat = true;
    w.context.services.call!(InvasionHost.control)(InvasionControl(true));
    assert(w.context.gameEvents.isActive(93));
    const layout = w.context.invasionLayout;
    assert(layout.ships.length == 14 && layout.camps.length == 42);
    ubyte[3][6] counts;
    foreach (ref site; layout.camps) ++counts[site.zone][site.ship];
    foreach (i, zone; invasionZones)
        foreach (j; 0 .. zone.ships) assert(counts[i][j] == 3);
    auto map = me.currentMap;
    void step(uint ms)
    {
        for (uint elapsed; elapsed < ms; elapsed += 200)
        {
            w.now += 200.msecs;
            w.context.update(w.now);
            who.read();
        }
    }
    void move(Position p)
    {
        me.teleportTo(0, p, null, 0, true);
        who.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
    }
    Creature near(Position p, uint entry, float range = 8)
    {
        foreach (c; map.creaturesNear(p, range))
            if (c.template_.entry == entry && c.alive) return c;
        return null;
    }
    void kill(Creature c)
    {
        dealDamage(me.unit, map.unitOf(c), c.values.get!UNIT_FIELD_HEALTH + 1, Blow.spell());
    }
    ubyte[] castResult;
    bool offered;
    void gossip(Creature npc)
    {
        who.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(npc.guid));
        auto menu = bodyOf(who.read(), Opcode.SMSG_GOSSIP_MESSAGE);
        offered = menu.length >= 16 && menu[12] != 0;
        if (!offered) return;
        who.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(npc.guid, 0));
        castResult = bodyOf(who.read(), Opcode.SMSG_CAST_RESULT).dup;
    }
    foreach (site; layout.camps)
    {
        if (site.zone != 3) continue;
        move(site.position);
        step(1200);
        auto shard = near(site.position,16136);
        assert(shard !is null, format!"camp %s has no intact shard"(site.spawn));
        const initial = shard.values.get!UNIT_FIELD_HEALTH;
        uint slain;
        // The shard loses health through the undead's own EventAI death cast.
        for (uint t; !near(site.position,16172) && t < 2600000; t += 1000)
        {
            step(1000);
            foreach (c; map.creaturesNear(site.position, 60))
                if (c.alive && (c.template_.entry == 16141 || c.template_.entry == 16298 ||
                    c.template_.entry == 16299 || c.template_.entry == 14697 ||
                    c.template_.entry == 16379 || c.template_.entry == 16380))
                {
                    kill(c);
                    ++slain;
                    if (!shard.alive) break;
                }
        }
        auto broken = near(site.position,16172);
        assert(slain && broken !is null, format!"camp %s killed %s undead; shard %s/%s"(site.spawn,slain,shard.values.get!UNIT_FIELD_HEALTH,initial));
        step(1000);
        uint bosses;
        foreach (_; 0 .. 4)
        {
            auto cultist = near(site.position,16230);
            assert(cultist !is null);
            move(cultist.position);
            assert(me.giveItem(22484,7,true,false));
            gossip(cultist);
            assert(me.player.inventory.count(22484) == 7 && cultist.alive);
            assert(me.giveItem(22484,1,true,false));
            gossip(cultist);
            step(400);
            auto boss = near(site.position,16143, 25);
            assert(!me.player.inventory.count(22484) && boss !is null && !cultist.alive,
                format!"site %s boss %s, runes %s, summoned %s, engineer alive %s, option %s, cast result %s, player alive %s, fighting %s"(site.spawn,bosses,me.player.inventory.count(22484),boss !is null,cultist.alive,offered,castResult,me.player.alive,me.player.inCombat));
            gossip(cultist);
            kill(boss);
            ++bosses;
            step(400);
            assert(bosses == 4 || broken.alive);
        }
        assert(!broken.alive && w.context.invasion.cleared(site.stamp(w.context.invasion)));
    }
    assert(!w.context.invasion.remaining(3) && w.context.invasion.victories == 1);
    assert(w.context.invasion.remaining(4) == 2 && w.context.gameEvents.isActive(94));
    InvasionHost restored;
    restored.restore(w.db.worldState(invasionSaveId));
    assert(restored.state == w.context.invasion && !restored.unreadableSave);
}
