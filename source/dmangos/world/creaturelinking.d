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

