/**
 * Linked creatures: packs and their leaders (`creature_linking` by spawn, `creature_linking_template`
 * by entry within a range of the leader's spawn point on a map).
 *
 * A link ties a creature (the slave) to its master, with flags for what passes between them:
 *
 * $(UL
 *   $(LI the master attacked: the slave joins in (`aggroOnAggro`); the slave attacked: the master does
 *        (`toAggroOnAggro`);)
 *   $(LI the master evades: the slave does too (`evadeOnEvade`), goes (`despawnOnEvade`), or comes back
 *        if dead (`respawnOnEvade`); a slave evading brings its dead master back (`toRespawnOnEvade`);)
 *   $(LI the master dies: the slave dies with it (`selfKillOnDeath`) or goes (`despawnOnDeath`), and a
 *        dead slave comes back (`respawnOnDeath`);)
 *   $(LI the master respawns: its dead slaves come back with it (`respawnOnRespawn`), or its living ones go
 *        (`despawnOnRespawn`);)
 *   $(LI out of combat the slave follows its master, keeping their spawns' distance and angle
 *        (`follow`);)
 *   $(LI the master is made to go (despawned): the slave goes with it (`despawnOnDespawn`);)
 *   $(LI in a dungeon copy, the slave does not come back once its master is dead (`cantSpawnIfBossDead`), or
 *        does not come while its master lives (`cantSpawnIfBossAlive`).)
 * )
 * A dead creature brought back has its respawn made due at once (its corpse goes); in a dungeon copy it
 * is made again at once and is no longer counted dead there (a boss's wipe brings its adds back). Links
 * between creatures simulated on different nodes of a cluster do nothing (the two are rarely far apart).
 */
module dmangos.world.creaturelinking;

import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.movement : Position;
import dmangos.world.creatureai : LinkEvent;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart, UpdateValues;
import dmangos.world.unit : UnitKind, UnitRef;
import dmangos.world.map : Map;
import dmangos.world.context : WorldContext;

/// `creature_linking.flag`
enum LinkFlag : uint
{
    aggroOnAggro = 0x0001,
    toAggroOnAggro = 0x0002,
    respawnOnEvade = 0x0004,
    toRespawnOnEvade = 0x0008,
    despawnOnDeath = 0x0010,
    selfKillOnDeath = 0x0020,
    respawnOnDeath = 0x0040,
    respawnOnRespawn = 0x0080,
    despawnOnRespawn = 0x0100,
    follow = 0x0200,
    cantSpawnIfBossDead = 0x0400,
    cantSpawnIfBossAlive = 0x0800,
    despawnOnEvade = 0x1000,
    despawnOnDespawn = 0x2000,
    evadeOnEvade = 0x4000,
}

/// A slave's link to its master: by the master's spawn, or (template) by its entry within `range`.
struct CreatureLink
{
    uint masterGuid;  /// the master's spawn (0 for a template link)
    uint masterEntry; /// a template link's master entry
    uint flags;
    uint range;       /// a template link's search range from the master's spawn point (0: any)
    bool hasOffset;   /// a GM-authored formation supplies its own offset
    float distance = 0;
    float angle = 0;
}

/// The links, by slave and by master.
final class CreatureLinks
{
    CreatureLink[uint] bySlaveGuid;          /// `creature_linking`, by the slave's spawn
    CreatureLink[uint][uint] bySlaveEntry;   /// `creature_linking_template`, by the slave's entry, then map
    uint[][uint] slavesOfGuid;               /// a master's spawn -> its slaves' spawns
    uint[][uint] slaveEntriesOf;             /// a master's entry -> the entries linked to it by template

    /// Adds a `creature_linking` row.
    void addGuid(uint slave, uint master, uint flags)
    {
        setGuid(slave, CreatureLink(master, 0, flags, 0));
    }

    void setGuid(uint slave, CreatureLink link)
    {
        import std.algorithm.mutation : remove;

        if (const previous = slave in bySlaveGuid)
        {
            const leader = previous.masterGuid;
            auto remaining = slavesOfGuid[leader].remove!(guid => guid == slave);
            if (remaining.length)
                slavesOfGuid[leader] = remaining;
            else
                slavesOfGuid.remove(leader);
            bySlaveGuid.remove(slave);
        }
        if (link.masterGuid)
        {
            bySlaveGuid[slave] = link;
            slavesOfGuid[link.masterGuid] ~= slave;
        }
    }

    /// Adds a `creature_linking_template` row.
    void addTemplate(uint slaveEntry, uint map, uint masterEntry, uint flags, uint range)
    {
        bySlaveEntry[slaveEntry][map] = CreatureLink(0, masterEntry, flags, range);
        slaveEntriesOf[masterEntry] ~= slaveEntry;
    }

    /// Slave `guid` (of `entry`, on `map`)'s link, if any.
    const(CreatureLink)* linkOf(uint guid, uint entry, uint map) const
    {
        if (auto l = guid in bySlaveGuid)
            return l;
        if (auto byMap = entry in bySlaveEntry)
            if (auto l = map in *byMap)
                return l;
        return null;
    }

    /// Whether anything is linked to or from a creature (a quick check before the work).
    bool involves(uint guid, uint entry) const
    {
        return (guid in bySlaveGuid) !is null || (guid in slavesOfGuid) !is null || (entry in bySlaveEntry) !is null
            || (entry in slaveEntriesOf) !is null;
    }
}

/// Whether a slave whose spawn point is (`sx`, `sy`) is within `range` of a master spawned at (`mx`, `my`).
bool inLinkRange(float sx, float sy, float mx, float my, uint range) pure nothrow @nogc @safe
{
    return range == 0 || (sx - mx) ^^ 2 + (sy - my) ^^ 2 < float(range) * range;
}

/**
 * What the links of this node's creatures do (`WorldContext.links`): a master's aggro, evading, death and respawn
 * passed to its slaves as their flags say, followers set to follow as they are spawned, and formations kept in shape.
 */
final class Linking
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// The creatures on `m` linked to `master`, and their links.
    package Creature[] slavesOf(Map m, Creature master, out const(CreatureLink)*[] links)
    {
        Creature[] found;
        const links_ = world.data.creatureLinks;
        foreach (guid; links_.slavesOfGuid.get(master.spawnId, null))
            if (const spawn = world.creatureSpawnOf(guid))
                if (auto c = cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid)))
                {
                    found ~= c;
                    links ~= guid in links_.bySlaveGuid;
                }
        const entries = links_.slaveEntriesOf.get(master.template_.entry, null);
        if (entries.length)
        {
            const ms = master.spawn;
            foreach (c; m.creaturesNear(Position(ms.x, ms.y, ms.z), 120))
                foreach (entry; entries)
                    if (c.template_.entry == entry && c !is master)
                        if (auto l = links_.linkOf(c.spawnId, entry, m.id))
                            if (l.masterEntry == master.template_.entry && inLinkRange(c.spawn.x, c.spawn.y, ms.x, ms.y, l.range))
                            {
                                found ~= c;
                                links ~= l;
                            }
        }
        return found;
    }

    /// The master of `slave` on `m`, if it is here, and the link.
    package Creature masterOf(Map m, Creature slave, out const(CreatureLink)* link)
    {
        link = world.data.creatureLinks.linkOf(slave.spawnId, slave.template_.entry, m.id);
        if (link is null)
            return null;
        if (link.masterGuid)
        {
            if (const spawn = world.creatureSpawnOf(link.masterGuid))
                return cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, link.masterGuid));
            return null;
        }
        const ss = slave.spawn;
        foreach (c; m.creaturesNear(Position(ss.x, ss.y, ss.z), link.range ? link.range : 120))
            if (c.template_.entry == link.masterEntry && inLinkRange(ss.x, ss.y, c.spawn.x, c.spawn.y, link.range))
                return c;
        return null;
    }

    /// `source` was attacked by `enemy` or evades: its linked creatures follow (see the module).
    package void linkedEvent(Map m, Creature source, LinkEvent event, ulong enemy)
    {
        if (!world.data.creatureLinks.involves(source.spawnId, source.template_.entry))
            return;
        const(CreatureLink)*[] links;
        auto slaves = slavesOf(m, source, links);
        foreach (i, slave; slaves)
        {
            if (event == LinkEvent.evade && !slave.alive && (links[i].flags & LinkFlag.respawnOnEvade))
                respawnLinked(m, slave);
            if (!slave.alive || slave.ai is null)
                continue;
            final switch (event)
            {
            case LinkEvent.aggro:
                if (links[i].flags & LinkFlag.aggroOnAggro)
                    joinFight(m, slave, enemy);
                break;
            case LinkEvent.despawn:
                if (links[i].flags & LinkFlag.despawnOnDespawn)
                    slave.ai.despawnFor(m, 0);
                break;
            case LinkEvent.evade:
                if (links[i].flags & LinkFlag.despawnOnEvade)
                    slave.ai.despawnFor(m, 0);
                else if (links[i].flags & LinkFlag.evadeOnEvade)
                    slave.ai.evadeWithLinked(m);
                break;
            }
        }
        if (event == LinkEvent.evade)
            respawnLinkedSpawns(m, source, LinkFlag.respawnOnEvade);
        // The other way: a slave attacked brings its master in; a slave evading brings its dead master back.
        const(CreatureLink)* link;
        if (auto master = masterOf(m, source, link))
        {
            if (event == LinkEvent.aggro && (link.flags & LinkFlag.toAggroOnAggro) && master.alive && master.ai !is null)
                joinFight(m, master, enemy);
            if (event == LinkEvent.evade && (link.flags & LinkFlag.toRespawnOnEvade) && !master.alive)
                respawnLinked(m, master);
        }
    }

    /**
     * A dead creature of a pack comes back now: its corpse goes and its respawn is due at once (the next
     * second's respawns bring it). Summons and dungeon creatures are left alone.
     */
    package void respawnLinked(Map m, Creature c)
    {
        if (c.alive || c.summon.type != TempSpawnType.none || c.petOwner)
            return;
        if (c.instanceId)
            return world.respawnInCopy(m, &c.spawn, c);
        if (m.findObject(c.guid) is c)
            m.corpseExpired(c);
        world.respawnSpawnNow(c.spawn.guid);
    }

    /// The slaves (by spawn) of `master` linked with `flag` whose corpses are already gone come back too.
    package void respawnLinkedSpawns(Map m, Creature master, LinkFlag flag)
    {
        foreach (guid; world.data.creatureLinks.slavesOfGuid.get(master.spawnId, null))
            if (const l = guid in world.data.creatureLinks.bySlaveGuid)
                if (l.flags & flag)
                    if (const spawn = world.creatureSpawnOf(guid))
                        if (m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid)) is null)
                        {
                            if (master.instanceId)
                            {
                                // In a copy only the dead come back (one not loaded yet is not dead).
                                if (auto state = master.instanceId in world.dungeons.instances)
                                    if (guid in state.dead)
                                        world.respawnInCopy(m, spawn, null);
                            }
                            else
                                world.respawnSpawnNow(guid);
                        }
    }

    /// `master` has respawned: its dead slaves linked so come back with it, and those linked so go.
    package void linkedRespawn(Map m, Creature master)
    {
        if (!world.data.creatureLinks.involves(master.spawnId, master.template_.entry))
            return;
        const(CreatureLink)*[] links;
        foreach (i, slave; slavesOf(m, master, links))
        {
            if (!slave.alive && (links[i].flags & LinkFlag.respawnOnRespawn))
                respawnLinked(m, slave);
            else if (slave.alive && (links[i].flags & LinkFlag.despawnOnRespawn) && slave.ai !is null)
                slave.ai.despawnFor(m, 0);
        }
        respawnLinkedSpawns(m, master, LinkFlag.respawnOnRespawn);
    }

    /// `c` fights `enemy` too: attacking it, or (fighting already) counting it as a threat.
    package void joinFight(Map m, Creature c, ulong enemy)
    {
        auto who = m.unit(enemy);
        if (who.kind == UnitKind.none)
            return;
        c.ai.joinLinkedFight(who, m);
    }

    /// `master` dies: its slaves that die or go with it do.
    package void linkedDeath(Map m, Creature master)
    {
        if (!world.data.creatureLinks.involves(master.spawnId, master.template_.entry))
            return;
        const(CreatureLink)*[] links;
        foreach (i, slave; slavesOf(m, master, links))
        {
            if (!slave.alive)
            {
                if (links[i].flags & LinkFlag.respawnOnDeath)
                    respawnLinked(m, slave);
                continue;
            }
            if (links[i].flags & LinkFlag.selfKillOnDeath)
            {
                import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

                slave.values.set!UNIT_FIELD_HEALTH(0u);
                m.creatureDeath(slave);
            }
            else if ((links[i].flags & LinkFlag.despawnOnDeath) && slave.ai !is null)
                slave.ai.despawnFor(m, 0);
        }
    }

    /// A spawned creature of a pack waits to be linked (once its cell holds it).
    package void queueLinked(uint mapId, uint instance, Creature c)
    {
        if (!world.data.creatureLinks.involves(c.spawnId, c.template_.entry) && c.spawnId !in world.data.formationSlots)
            return;
        linkSpawned ~= c;
        linkSpawnedOn ~= instance ? world.map(mapId, instance) : world.map(mapId);
    }

    /// Creatures just spawned that may follow or be followed: worked out once their cell holds them.
    package Creature[] linkSpawned;

    package Map[] linkSpawnedOn;

    /// Each spawned creature of a pack follows its master (`follow`), and a master's followers follow it.
    package void linkFollowers()
    {
        if (linkSpawned.length == 0)
            return;
        auto spawned = linkSpawned, maps_ = linkSpawnedOn;
        linkSpawned = null;
        linkSpawnedOn = null;
        foreach (i, c; spawned)
        {
            auto m = maps_[i];
            if (!c.alive || m.findObject(c.guid) !is c)
                continue;
            if (const slot = c.spawnId in world.data.formationSlots)
            {
                arrangeFormation(m, (*slot)[0]);
                continue;
            }
            const(CreatureLink)* link;
            if (auto master = masterOf(m, c, link))
                if (link.flags & LinkFlag.follow)
                    follow(m, c, master);
            const(CreatureLink)*[] links;
            foreach (j, slave; slavesOf(m, c, links))
                if (links[j].flags & LinkFlag.follow)
                    follow(m, slave, c);
        }
    }

    package uint[][uint] formationMembers; // group -> member spawns, by slot


    /**
     * Formation `group`'s members on `m`: its leader (slot 0) walks the formation's path; the others take
     * their places around it in slot order (`formationPlace`), and follow it.
     */
    package void arrangeFormation(Map m, uint group)
    {
        import std.algorithm.sorting : sort;
        import dmangos.world.creaturelinking : formationPlace;
        import dmangos.world.motion : FollowMovement, WaypointMovement;

        if (formationMembers is null)
        {
            uint[2][][uint] bySlot;
            foreach (guid, gs; world.data.formationSlots)
                bySlot[gs[0]] ~= [gs[1], guid];
            foreach (g, list; bySlot)
            {
                list.sort!((a, b) => a[0] < b[0]);
                foreach (e; list)
                    formationMembers[g] ~= e[1];
            }
        }
        const f = group in world.data.formations;
        if (f is null)
            return;
        Creature find(uint guid)
        {
            if (const spawn = world.creatureSpawnOf(guid))
                return cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid));
            return null;
        }
        const members = formationMembers.get(group, null);
        if (members.length == 0)
            return;
        auto leader = find(members[0]);
        if (leader is null || !leader.alive)
            return;
        if (f.pathId && cast(WaypointMovement) leader.generator is null && (leader.ai is null || !leader.ai.inCombat))
            if (const path = world.data.waypoints.path(f.pathId))
            {
                leader.generator = new WaypointMovement(path, f.movementType == 4, f.pathId, true);
                m.wake(leader.guid);
            }
        uint index;
        foreach (guid; members[1 .. $])
        {
            auto c = find(guid);
            if (c is null || !c.alive)
                continue;
            ++index;
            if (c.ai !is null && c.ai.inCombat)
                continue;
            float distance, angle;
            formationPlace(*f, index, cast(uint) members.length, distance, angle);
            if (auto following = cast(FollowMovement) c.generator)
                if (following.leader == leader.guid && following.distance == distance && following.angle == angle)
                    continue;
            c.generator = new FollowMovement(leader.guid, distance, angle);
            m.wake(c.guid);
        }
    }

    /// `slave` follows `master` (not while fighting), at their spawns' distance and angle.
    package void follow(Map m, Creature slave, Creature master)
    {
        import std.math : atan2, sqrt;
        import dmangos.world.motion : FollowMovement;

        if (!slave.alive || !master.alive || (slave.ai !is null && slave.ai.inCombat))
            return;
        if (auto f = cast(FollowMovement) slave.generator)
            if (f.leader == master.guid)
                return;
        if (const link = slave.spawnId in world.data.creatureLinks.bySlaveGuid)
            if (link.hasOffset && link.masterGuid == master.spawnId)
            {
                slave.generator = new FollowMovement(master.guid, link.distance, link.angle);
                m.wake(slave.guid);
                return;
            }
        const s = slave.spawn, ms = master.spawn;
        const dx = s.x - ms.x, dy = s.y - ms.y;
        const distance = sqrt(dx * dx + dy * dy);
        slave.generator = new FollowMovement(master.guid, distance, atan2(dy, dx) - ms.orientation);
        m.wake(slave.guid);
    }
}

unittest
{
    auto links = new CreatureLinks;
    links.addGuid(10, 1, LinkFlag.aggroOnAggro | LinkFlag.follow);
    links.addTemplate(500, 36, 600, LinkFlag.toAggroOnAggro, 30);
    assert(links.linkOf(10, 7, 0).masterGuid == 1 && links.slavesOfGuid[1] == [10]);
    assert(links.linkOf(11, 500, 36).masterEntry == 600 && links.linkOf(11, 500, 0) is null);
    assert(links.involves(1, 0) && links.involves(0, 600) && !links.involves(2, 2));
    assert(inLinkRange(0, 0, 10, 10, 30) && !inLinkRange(0, 0, 40, 0, 30) && inLinkRange(0, 0, 1000, 0, 0));
}

/**
 * A formation (`spawn_group_formation`): a spawn group whose slot 0 leads, walking its path, and whose
 * other members keep their places around it. `type`: 1 single file, 2 side by side, 3 like geese, 4 fanned
 * out behind, 5 fanned out in front, 6 around the leader (0, random, is laid out side by side here).
 */
struct Formation
{
    uint type;
    float spread = 0;  /// yards between places
    uint pathId;       /// the leader's `waypoint_path`
    uint movementType; /// 2 round its path, 4 there and back
}

/**
 * Where the `index`-th member after the leader (from 1) of `total` members stands: its distance from the
 * leader, and the angle from the leader's facing (pi: behind).
 */
void formationPlace(const ref Formation f, uint index, uint total, out float distance, out float angle)
    pure nothrow @nogc @safe
{
    import std.math : PI;

    const d = f.spread > 0 ? f.spread : 2;
    const n = total > 1 ? total - 1 : 1; // the leader's followers
    switch (f.type)
    {
    case 1: // single file
        angle = PI;
        distance = d * index;
        break;
    case 3: // like geese
        angle = (index & 1) == 0 ? PI + PI / 4 : PI - PI / 4;
        distance = d * ((index - 1) / 2 + 1);
        break;
    case 4: // fanned out behind
        angle = PI / 2 + (PI / n) * (index - 1);
        distance = d;
        break;
    case 5: // fanned out in front
        angle = PI + PI / 2 + (PI / n) * (index - 1);
        if (angle > 2 * PI)
            angle -= 2 * PI;
        distance = d;
        break;
    case 6: // around the leader
        angle = (2 * PI / n) * (index - 1);
        distance = d;
        break;
    default: // side by side (and random)
        angle = (index & 1) == 0 ? PI / 2 + PI : PI / 2;
        distance = d * ((index - 1) / 2 + 1);
        break;
    }
}

unittest
{
    import std.math : isClose, PI;

    auto file = Formation(1, 3);
    float d, a;
    formationPlace(file, 2, 4, d, a);
    assert(isClose(a, PI) && isClose(d, 6), "single file: two places behind");
    auto side = Formation(2, 2);
    formationPlace(side, 1, 3, d, a);
    assert(isClose(a, PI / 2) && isClose(d, 2));
    formationPlace(side, 2, 3, d, a);
    assert(isClose(a, PI * 1.5) && isClose(d, 2), "the other side");
}

