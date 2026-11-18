/**
 * Who may attack whom: how units react to each other, whether one may attack another at all, and
 * whether it may now. The rules are the client's own, so server and client agree.
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

/// How one unit stands to another, or a player to a faction: hated to exalted.
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
    uint playerFlags;                       /// `PLAYER_FLAGS` of the player it is or that controls it (FFA, contested)
    bool playerOwned;                       /// a player's pet, totem or guardian: it has a controlling player

    /// Whether a player is in control: a player, or a unit one controls.
    @property bool hasControllingPlayer() const pure nothrow @nogc @safe
    {
        return player || playerOwned;
    }

    /// In a free-for-all area (`PLAYER_FLAGS_FFA_PVP` of its controlling player).
    @property bool freeForAll() const pure nothrow @nogc @safe
    {
        return hasControllingPlayer && (playerFlags & PlayerFlagsPvP.freeForAll) != 0;
    }

    /// Contested: attacked a flagged player of late (`PLAYER_FLAGS_CONTESTED_PVP`).
    @property bool contested() const pure nothrow @nogc @safe
    {
        return hasControllingPlayer && (playerFlags & PlayerFlagsPvP.contested) != 0;
    }

    bool hasFlag(uint flag) const pure nothrow @nogc @safe
    {
        return (unitFlags & flag) != 0;
    }

    @property bool playerControlled() const pure nothrow @nogc @safe
    {
        return hasFlag(UnitFlags.playerControlled);
    }
}

/// The `PLAYER_FLAGS` the relations read.
enum PlayerFlagsPvP : uint
{
    freeForAll = 0x80,   /// `PLAYER_FLAGS_FFA_PVP`
    contested = 0x100,   /// `PLAYER_FLAGS_CONTESTED_PVP`: contested guards attack it
    desired = 0x200,     /// `PLAYER_FLAGS_PVP_DESIRED`: the player turned PvP on
}

/// `FACTION_TEMPLATE_FLAG_ATTACK_PVP_ACTIVE_PLAYERS`: a contested zone's guards, who attack contested players.
enum uint factionTemplateContestedGuard = 0x1000;

/// `FACTION_TEMPLATE_FLAG_ASSIST_PLAYERS`: a faction whose creatures carry the PvP flag.
enum uint factionTemplateAssistPlayers = 0x800;

/// `FACTION_FLAG_AT_WAR` of `Faction.dbc`'s reputation flags.
private enum uint factionFlagAtWar = 0x02;

/// The rank a reputation standing falls in.
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

/// A player's base standing with a faction (by race and class), and whether it starts at war.
private int baseReputation(const Relating player, const(FactionEntry)* faction, out bool atWar) pure nothrow @nogc
{
    const index = faction.indexFitTo(player.raceMask, player.classMask);
    if (index < 0)
        return 0;
    atWar = (faction.reputationFlags[index] & factionFlagAtWar) != 0;
    return faction.baseRepValue[index];
}

/// How one faction template reacts to another: by their enemy and friend groups and factions.
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

/// A faction template's reaction to a unit.
ReputationRank factionReaction(const(FactionTemplateEntry)* self, const Relating unit, const ClientData client)
{
    if (self is null || unit.template_ is null)
        return ReputationRank.neutral;
    if (unit.contested && (self.flags & factionTemplateContestedGuard))
        return ReputationRank.hostile;
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
 * How `self` stands to `unit`. `sameGroup` says whether two players are in
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
            if (self.freeForAll && unit.freeForAll)
                return ReputationRank.hostile;
        }
        if (self.player && unit.template_ !is null)
        {
            // A contested player and a contested zone's guards: enemies.
            if (self.contested && (unit.template_.flags & factionTemplateContestedGuard))
                return ReputationRank.hostile;
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

/// Whether `self` is hostile to `unit` (below unfriendly).
bool isEnemy(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    return reactionTo(self, unit, client, sameGroup) < ReputationRank.unfriendly;
}

/// Whether `self` is friendly to `unit` (above neutral).
bool isFriend(const Relating self, const Relating unit, const ClientData client, bool sameGroup = false)
{
    return reactionTo(self, unit, client, sameGroup) > ReputationRank.neutral;
}

/// Whether `self` may attack `unit` at all (duelists each other; no free-for-all yet).
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
            if (!self.hasControllingPlayer || !unit.hasControllingPlayer)
                return true;
            // The target's PvP flag decides (a pet carries its owner's), or both in a free-for-all.
            return unit.hasFlag(UnitFlags.pvp) || (self.freeForAll && unit.freeForAll);
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

/// Whether `self` may attack `unit` now: both alive (being mounted is not checked: there are no mounts yet).
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
