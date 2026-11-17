/**
 * Who may attack whom: CMaNGOS's Relations API, tier 1 (`Entities/Relations.cpp`), which is the
 * client's own logic (`CGUnit_C::UnitReaction`, `CanAttack`, `CanAttackNow`).
 *
 * A unit is described by a `Relating`: its unit flags, its faction template, and for a player its
 * race and class (the base reputation of `Faction.dbc` decides how it stands to factions that have
 * reputation). Characters' saved reputations are not loaded yet, so a player stands at its base
 * reputation with every faction, and is at war with those `Faction.dbc` starts it at war with.
 * Duels, free-for-all PvP and reactions forced by auras come with their systems.
 */
module dmangos.world.relations;

import dmangos.world.clientdata : ClientData, FactionEntry, FactionTemplateEntry;
import dmangos.world.defines : UnitFlags;
import dmangos.world.reputation : Reputation;

/// `ReputationRank`
enum ReputationRank : ubyte
{
    hated,
    hostile,
    unfriendly,
    neutral,
    friendly,
    honored,
    revered,
    exalted,
}

/// What the relations need of a unit.
struct Relating
{
    uint unitFlags;                         /// `UNIT_FIELD_FLAGS`
    const(FactionTemplateEntry)* template_; /// null if its faction template is unknown
    bool player;                            /// a player (the only player-controlled units yet)
    uint raceMask, classMask;               /// a player's, for its base reputations
    bool alive = true;
    ulong duelArbiter;                      /// `PLAYER_DUEL_ARBITER`: the duel's flag
    uint duelTeam;                          /// `PLAYER_DUEL_TEAM`: 1 or 2 while the duel is on, else 0
    const(Reputation) reputation;           /// a player's standings; null: its race's and class's base ones

    bool hasFlag(uint flag) const pure nothrow @nogc @safe
    {
        return (unitFlags & flag) != 0;
    }

    @property bool playerControlled() const pure nothrow @nogc @safe
    {
        return hasFlag(UnitFlags.playerControlled);
    }
}

/// `FACTION_FLAG_AT_WAR` of `Faction.dbc`'s reputation flags.
private enum uint factionFlagAtWar = 0x02;

/// `ReputationMgr::ReputationToRank`
ReputationRank reputationToRank(int standing) pure nothrow @nogc @safe
{
    static immutable int[8] pointsInRank = [36_000, 3000, 3000, 3000, 6000, 12_000, 21_000, 1000];
    int limit = 42_999 + 1; // Reputation_Cap + 1
    foreach_reverse (rank, points; pointsInRank)
    {
        limit -= points;
        if (standing >= limit)
            return cast(ReputationRank) rank;
    }
    return ReputationRank.hated;
}

/// A player's base standing with a faction (`ReputationMgr::GetBaseReputation`), and whether it starts at war.
private int baseReputation(const Relating player, const(FactionEntry)* faction, out bool atWar) pure nothrow @nogc
{
    const index = faction.indexFitTo(player.raceMask, player.classMask);
    if (index < 0)
        return 0;
    atWar = (faction.reputationFlags[index] & factionFlagAtWar) != 0;
    return faction.baseRepValue[index];
}

/// `GetFactionReaction(FactionTemplateEntry, FactionTemplateEntry)`
ReputationRank factionReaction(const(FactionTemplateEntry)* self, const(FactionTemplateEntry)* other)
    pure nothrow @nogc
in (self !is null && other !is null)
{
    if (other.groupMask & self.enemyGroupMask)
        return ReputationRank.hostile;
    if (self.enemyFactions[0] && other.faction)
        foreach (f; self.enemyFactions)
            if (f == other.faction)
                return ReputationRank.hostile;
    if (other.groupMask & self.friendGroupMask)
        return ReputationRank.friendly;
    if (self.friendFactions[0] && other.faction)
        foreach (f; self.friendFactions)
            if (f == other.faction)
                return ReputationRank.friendly;
    if (self.groupMask & other.friendGroupMask)
        return ReputationRank.friendly;
    if (other.friendFactions[0] && self.faction)
        foreach (f; other.friendFactions)
            if (f == self.faction)
                return ReputationRank.friendly;
    return ReputationRank.neutral;
}

/// `GetFactionReaction(FactionTemplateEntry, Unit)`: a faction template's reaction to a unit.
ReputationRank factionReaction(const(FactionTemplateEntry)* self, const Relating unit, const ClientData client)
{
    if (self is null || unit.template_ is null)
        return ReputationRank.neutral;
    if (unit.playerControlled && unit.player)
    {
        const faction = client.factions.lookup(self.faction);
        if (faction !is null && faction.hasReputation)
        {
            if (unit.reputation !is null)
                return unit.reputation.rankWith(faction);
            bool atWar;
            return reputationToRank(baseReputation(unit, faction, atWar));
        }
    }
    return factionReaction(self, unit.template_);
}

/**
 * `Unit::GetReactionTo`: how `self` stands to `unit`. `sameGroup` says whether two players are in
 * one group (they are friends whatever their factions).
 */
ReputationRank reactionTo(const Relating self, const Relating unit, const ClientData client,
    bool sameGroup = false)
{
    if (self.playerControlled)
    {
        if (unit.playerControlled)
        {
            if (!self.player || !unit.player)
                return ReputationRank.neutral;
            // Duelists: enemies of each other while their duel lasts.
            if (self.duelTeam && unit.duelTeam && self.duelArbiter == unit.duelArbiter)
                return self.duelTeam != unit.duelTeam ? ReputationRank.hostile : ReputationRank.friendly;
            if (sameGroup)
                return ReputationRank.friendly;
        }
        if (self.player && unit.template_ !is null)
        {
            const faction = client.factions.lookup(unit.template_.faction);
            // A faction with a reputation: at war or not decides.
            if (faction !is null && faction.hasReputation)
            {
                if (self.reputation !is null)
                    return self.reputation.atWarWith(faction) ? ReputationRank.hostile : ReputationRank.friendly;
                bool atWar;
                baseReputation(self, faction, atWar);
                return atWar ? ReputationRank.hostile : ReputationRank.friendly;
            }
        }
    }
    return factionReaction(self.template_, unit, client);
}

/// `Unit::IsEnemy`
bool isEnemy(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    return reactionTo(self, unit, client, sameGroup) < ReputationRank.unfriendly;
}

/// `Unit::IsFriend`
bool isFriend(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    return reactionTo(self, unit, client, sameGroup) > ReputationRank.neutral;
}

/// `Unit::CanAttack`: whether `self` may attack `unit` at all (duelists each other; no free-for-all yet).
bool canAttack(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    enum uint mask = UnitFlags.spawning | UnitFlags.notAttackable1 | UnitFlags.untargetable | UnitFlags.taxiFlight
        | UnitFlags.uninteractible;
    if (unit.hasFlag(mask))
        return false;
    // Immunity and sanctuary, both ways.
    if (self.playerControlled ? unit.hasFlag(UnitFlags.immuneToPlayer) : unit.hasFlag(UnitFlags.immuneToNpc))
        return false;
    if (unit.playerControlled ? self.hasFlag(UnitFlags.immuneToPlayer) : self.hasFlag(UnitFlags.immuneToNpc))
        return false;
    if (self.playerControlled || unit.playerControlled)
    {
        if (self.playerControlled && unit.playerControlled)
        {
            if (self.duelTeam && unit.duelTeam && self.duelArbiter == unit.duelArbiter)
                return self.duelTeam != unit.duelTeam;
            if (isFriend(self, unit, client, sameGroup))
                return false;
            if (!self.player || !unit.player)
                return true;
            return unit.hasFlag(UnitFlags.pvp); // `Player::IsPvP`
        }
        // A creature may attack a player at war with its faction, friend or not.
        if (!self.playerControlled && unit.player && unit.reputation !is null && self.template_ !is null)
            if (const faction = client.factions.lookup(self.template_.faction))
                if (faction.hasReputation && unit.reputation.atWarWith(faction))
                    return true;
        return !isFriend(self, unit, client, sameGroup);
    }
    return isEnemy(self, unit, client) || isEnemy(unit, self, client);
}

/// `Unit::CanAttackNow`: an attack asked for now (not mounted: there are no mounts yet).
bool canAttackNow(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    return self.alive && unit.alive && canAttack(self, unit, client, sameGroup);
}

unittest
{
    import dmangos.world.testdata : testClientData;

    auto client = testClientData();
    // Templates: 1 Alliance players, 2 Horde players, 3 a hostile beast, 4 a neutral beast, 5 a Stormwind guard.
    enum uint alliance = 2, horde = 4, monsters = 8, players = 1;
    auto templates = [FactionTemplateEntry(1, 1, 0, players | alliance, alliance, monsters),
        FactionTemplateEntry(2, 2, 0, players | horde, horde, monsters),
        FactionTemplateEntry(3, 22, 0, monsters, 0, players), FactionTemplateEntry(4, 31, 0, 0, 0, 0),
        FactionTemplateEntry(5, 11, 0, alliance, alliance, monsters)];
    Relating unit(uint t, bool player = false, uint flags = 0)
    {
        return Relating(flags | (player ? UnitFlags.playerControlled : 0), &templates[t - 1], player, 1, 1);
    }
    auto human = unit(1, true), orc = unit(2, true), wolf = unit(3), deer = unit(4), guard = unit(5);

    assert(reactionTo(human, wolf, client) == ReputationRank.hostile && canAttack(human, wolf, client));
    assert(reactionTo(human, deer, client) == ReputationRank.neutral && canAttack(human, deer, client),
        "neutral creatures may be attacked");
    assert(reactionTo(human, guard, client) == ReputationRank.friendly && !canAttack(human, guard, client));
    assert(!canAttack(orc, human, client), "the other faction, not flagged for PvP");
    auto flagged = unit(1, true, UnitFlags.pvp);
    assert(canAttack(orc, flagged, client) && !canAttack(human, unit(2, true, UnitFlags.pvp), client, true),
        "flagged for PvP, unless in one group");
    assert(!canAttack(human, unit(3, false, UnitFlags.uninteractible), client));
    assert(!canAttack(human, unit(3, false, UnitFlags.immuneToPlayer), client));
    wolf.alive = false;
    assert(!canAttackNow(human, wolf, client) && canAttack(human, wolf, client));

    assert(reputationToRank(0) == ReputationRank.neutral && reputationToRank(-1) == ReputationRank.unfriendly);
    assert(reputationToRank(3000) == ReputationRank.friendly && reputationToRank(-42_000) == ReputationRank.hated);
    assert(reputationToRank(42_000) == ReputationRank.exalted);
}
