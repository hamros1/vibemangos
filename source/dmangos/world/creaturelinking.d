/**
 * Linked creatures: packs and their leaders (`creature_linking` by spawn, `creature_linking_template`
 * by entry within a range of the leader's spawn point on a map).
 *
 * A link ties a creature (the slave) to its master, with flags for what passes between them:
 *
 * $(UL
 *   $(LI the master attacked: the slave joins in (`aggroOnAggro`); the slave attacked: the master does
 *        (`toAggroOnAggro`);)
 *   $(LI the master evades: the slave does too (`evadeOnEvade`);)
 *   $(LI the master dies: the slave dies with it (`selfKillOnDeath`) or goes (`despawnOnDeath`);)
 *   $(LI out of combat the slave follows its master, keeping their spawns' distance and angle
 *        (`follow`);)
 *   $(LI in a dungeon copy, the slave does not come back once its master is dead (`cantSpawnIfBossDead`).)
 * )
 * Links between creatures simulated on different nodes of a cluster do nothing (the two are rarely
 * far apart). Respawning slaves with their master is not done yet.
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
        bySlaveGuid[slave] = CreatureLink(master, 0, flags, 0);
        slavesOfGuid[master] ~= slave;
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
