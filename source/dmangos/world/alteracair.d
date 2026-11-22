/// The six imprisoned wing commanders, their escape, supplies, beacons and air strikes.
module dmangos.world.alteracair;

import core.time : Duration, minutes, seconds;
import dmangos.frozen : StaticMap;
import dmangos.world.alteracassaults : ValleyChoice, ValleyOrder;
import dmangos.world.battleground : Battleground;
import dmangos.world.character : Character;
import dmangos.world.creature : Creature, CreatureSpawn, TempSpawnType;
import dmangos.world.gameobject : GameObject, GameObjectTemplate;
import dmangos.world.movement : Position;

struct Wing
{
    uint commander, quest, needed, item, plant, beacon, focus, flyer;
    Position prison, base, field;
}

/// Original AV spawn and route endpoints (VMaNGOS 34aeaa8, creature, script_waypoint, gameobject).
immutable Wing[6] wings = [
    Wing(13438,6942,120,17507,21729,178725,178728,14946, Position(-771.79,-367.04,68.42,1.09),Position(572.83,-41.36,37.61),Position(-283.8,-318.5,5.0)),
    Wing(13439,6941,60,17506,21730,178724,178727,14948, Position(-1221.27,-354.51,57.70,4.94),Position(570.11,-48.83,38.12),Position(-239.1,-258.0,4.6)),
    Wing(13437,6943,30,17505,21728,178726,178729,14947, Position(-1291.28,-266.67,91.66,3.30),Position(571.05,-52.57,38.23),Position(-204.1,-113.5,79.3)),
    Wing(13179,6825,120,17324,21355,178545,178546,14943, Position(210.88,-357.36,56.46,5.67),Position(-1333.54,-327.31,90.94),Position(-282.8,-318.6,4.8)),
    Wing(13180,6826,60,17325,21370,178547,178548,14944, Position(324.43,-497.17,71.16,5.06),Position(-1335.70,-327.70,90.77),Position(-235.9,-256.9,4.3)),
    Wing(13181,6827,30,17323,21371,178549,178550,14945, Position(691.61,-143.90,56.54,2.55),Position(-1338.87,-326.94,90.73),Position(-204.7,-112.4,78.5)),
];

/// ClassicDB z2815 places three prisoners in their post-rescue camp. Index the captives at their prisons.
void placePrisoner(ref CreatureSpawn spawn)
{
    if (spawn.map == 30)
        foreach (ref wing; wings)
            if (spawn.entry == wing.commander)
            {
                spawn.x = wing.prison.x; spawn.y = wing.prison.y; spawn.z = wing.prison.z;
                spawn.orientation = wing.prison.orientation;
                return;
            }
}

/// ClassicDB includes the common beacon model and four of its six templates.
void completeBeaconTemplates(ref StaticMap!(uint, GameObjectTemplate) templates)
{
    if (auto common = 178545 in templates)
    {
        GameObjectTemplate base = *common;
        foreach (ref wing; wings[4 .. 6])
            if (wing.beacon !in templates)
            {
                base.entry = wing.beacon;
                base.name = wing.commander == 13180 ? "Jeztor's Beacon" : "Mulverick's Beacon";
                templates[base.entry] = base;
            }
        // Lock 99 requires Attacking (8386), the interruptible battleground interaction.
        foreach (ref wing; wings)
            if (auto beacon = wing.beacon in templates)
            {
                GameObjectTemplate fixed = *beacon;
                fixed.data[0] = 99;
                templates[wing.beacon] = fixed;
            }
    }
}

mixin template ValleyAir()
{
    import dmangos.world.alteracair;
    import dmangos.world.alteracassaults : ValleyChoice, ValleyOrder;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.alterac : factions, generals;
    import dmangos.world.relations : canAttack, ReputationRank;
    import dmangos.script.api : Location;

    enum FlightState : ubyte { captive, escaping, ready, departed }
    private struct Rescue
    {
        FlightState state;
        ulong commander, beacon;
        uint supplies;
        Duration beaconLeft, nextBeacon;
    }
    Rescue[6] rescues;
    private struct Patrol
    {
        ulong guid;
        Position center;
        ubyte next;
        uint attacks;
        Duration fire, move;
    }
    private Patrol[] patrols;

    private void placeFocuses(Battleground copy)
    {
        auto map = copy.context.map(copy.mapId, copy.instance);
        foreach (ref wing; wings)
        {
            // A world database that supplies the spawn already makes it through the normal cell loader.
            bool present;
            foreach (ref spawn; copy.context.data.gameObjectSpawns)
                if (spawn.map == copy.mapId && spawn.entry == wing.focus)
                {
                    present = true;
                    break;
                }
            if (!present)
                copy.context.summonWildGameObject(map, wing.focus, wing.field, 0);
        }
    }

    bool airQuestAllowed(uint quest, ubyte side)
    {
        foreach (i, ref wing; wings)
            if (wing.quest == quest)
                return i / 3 == side && rescues[i].state == FlightState.ready;
        return true;
    }

    private void airTurnIn(uint quest, ubyte side)
    {
        foreach (i, ref wing; wings)
            if (wing.quest == quest && airQuestAllowed(quest, side))
                ++rescues[i].supplies;
    }

    private ValleyChoice[] airChoices(Character who, Creature npc, ubyte side)
    {
        foreach (i, ref wing; wings)
        {
            if (wing.commander != npc.template_.entry || i / 3 != side)
                continue;
            const r = &rescues[i];
            if (r.state == FlightState.captive)
                return [ValleyChoice(ValleyOrder.rescue, "Get out of here. I will cover you!")];
            if (r.commander != npc.guid || r.state != FlightState.ready || r.supplies < wing.needed || who.player.reputationRank(factions[side]) < ReputationRank.revered)
                return null;
            ValleyChoice[] choices;
            if (r.nextBeacon <= Duration.zero && !who.player.inventory.count(wing.item))
                choices ~= ValleyChoice(ValleyOrder.beacon, "Give me a beacon for your air support.");
            choices ~= ValleyChoice(ValleyOrder.sortie, "Launch an attack on the enemy base!");
            return choices;
        }
        return null;
    }

    private void wingOrder(Battleground copy, Character who, Creature npc, ValleyOrder order)
    {
        foreach (i, ref wing; wings)
        {
            if (wing.commander != npc.template_.entry)
                continue;
            auto r = &rescues[i];
            switch (order)
            {
            case ValleyOrder.rescue:
                npc.keepSpawnLoaded = true;
                r.commander = npc.guid;
                r.state = FlightState.escaping;
                const p = wing.base;
                npc.ai.hostMoveTo(Location(p.x,p.y,p.z,p.orientation), 0, true);
                who.currentMap.wake(npc.guid);
                break;
            case ValleyOrder.beacon:
                if (who.giveItem(wing.item, 1, true, false))
                    r.nextBeacon = 30.minutes;
                break;
            case ValleyOrder.sortie:
                const side = i / 3;
                // The commander flies from home toward the opposing defenses.
                Position objective;
                foreach (ref spawn; copy.context.data.creatureSpawns)
                    if (spawn.map == copy.mapId && spawn.entry == generals[1 - side])
                    {
                        objective = Position(spawn.x,spawn.y,spawn.z);
                        break;
                    }
                if (objective.x && launchPatrol(copy, wing.flyer, npc.position, objective))
                {
                    r.state = FlightState.departed;
                    npc.ai.despawnFor(who.currentMap, 0);
                }
                break;
            default: return;
            }
            return;
        }
    }

    private bool launchPatrol(Battleground copy, uint entry, Position from, Position center)
    {
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return false;
        from.z += 25;
        center.z += 25;
        auto c = copy.context.summonCreature(map, entry, from, TempSpawnType.dead, 0, 0);
        if (c is null)
            return false;
        c.ai.hostIn(map);
        c.ai.hostFlying(true);
        c.ai.hostCombatMovement(false);
        c.ai.hostMoveTo(Location(center.x,center.y,center.z,0), 0, true);
        patrols ~= Patrol(c.guid, center);
        map.wake(c.guid);
        return true;
    }

    bool plantBeacon(Battleground copy, Character who, uint spell)
    {
        foreach (i, ref wing; wings)
            if (spell == wing.plant)
            {
                auto member = who.player.guid in copy.members;
                auto r = &rescues[i];
                if (member is null || member.team != i / 3 || r.beacon || r.supplies < wing.needed)
                    return true;
                const p = who.character.position;
                if ((p.x-wing.field.x)^^2 + (p.y-wing.field.y)^^2 + (p.z-wing.field.z)^^2 > 225)
                    return true;
                if (auto made = copy.context.summonWildGameObject(who.currentMap, wing.beacon, p, 0))
                {
                    r.beacon = made.guid;
                    r.beaconLeft = 60.seconds;
                }
                return true;
            }
        return false;
    }

    bool beginBeaconUse(Battleground copy, Character who, GameObject go)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        foreach (i, ref wing; wings)
            if (go.template_.entry == wing.beacon)
            {
                auto member = who.player.guid in copy.members;
                if (member !is null && member.team != i / 3 && rescues[i].beacon == go.guid)
                    if (const spell = copy.context.data.spells.spell(8386))
                    {
                        SpellTargets targets;
                        targets.mask = TargetFlags.gameObject;
                        targets.gameObject = go.guid;
                        who.castSpell(spell, targets, false, 0);
                    }
                return true;
            }
        return false;
    }

    private bool disruptBeacon(Battleground copy, ulong who, GameObject go)
    {
        foreach (i, ref wing; wings)
            if (go.template_.entry == wing.beacon)
            {
                auto member = who in copy.members;
                if (member !is null && member.team != i / 3 && copy.memberAlive(who) && rescues[i].beacon == go.guid)
                {
                    rescues[i].beacon = 0;
                    copy.context.map(copy.mapId, copy.instance).removeObject(go.guid);
                }
                return true;
            }
        return false;
    }

    private void updateAir(Battleground copy, Duration elapsed)
    {
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return;
        foreach (i, ref r; rescues)
        {
            if (r.nextBeacon > Duration.zero)
                r.nextBeacon -= elapsed;
            if (r.state == FlightState.escaping || r.state == FlightState.ready)
            {
                auto npc = map.creatureAt(r.commander);
                if (npc is null || !npc.alive)
                    r.state = FlightState.captive;
                else if (r.state == FlightState.escaping)
                {
                    const p = npc.position, dest = wings[i].base;
                    if ((p.x-dest.x)^^2 + (p.y-dest.y)^^2 + (p.z-dest.z)^^2 <= 25 && !npc.ai.inCombat)
                        r.state = FlightState.ready;
                }
            }
            if (r.beacon && (r.beaconLeft -= elapsed) <= Duration.zero)
            {
                if (auto go = cast(GameObject) map.findObject(r.beacon))
                {
                    launchPatrol(copy, i / 3 == 0 ? 13161 : 13178, go.position, go.position);
                    map.removeObject(go.guid);
                }
                r.beacon = 0;
            }
        }
        for (size_t i; i < patrols.length;)
        {
            auto p = &patrols[i];
            auto flyer = map.creatureAt(p.guid);
            if (flyer is null || !flyer.alive)
            {
                patrols[i] = patrols[$-1];
                patrols.length--;
                continue;
            }
            ++i;
            if ((p.fire -= elapsed) <= Duration.zero)
            {
                p.fire = 3.seconds;
                foreach (target; map.playersNear(flyer.position, 55))
                    if (target.session !is null && target.alive && canAttack(flyer.ai.relatingOf, target.relating, copy.context.client))
                    {
                        static immutable uint[] spells = [22088, 15285, 21188];
                        flyer.ai.castFor(map, spells[p.attacks++ % spells.length], target.combatGuid, true);
                        break;
                    }
            }
            if (!flyer.ai.inCombat && flyer.spline.finalized && (p.move -= elapsed) <= Duration.zero)
            {
                p.move = 2.seconds;
                static immutable float[2][4] offsets = [[20,0],[0,20],[-20,0],[0,-20]];
                const offset = offsets[p.next++ % offsets.length];
                flyer.ai.hostMoveTo(Location(p.center.x + offset[0],p.center.y + offset[1],p.center.z,0),0,true);
            }
        }
    }
}
