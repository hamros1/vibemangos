/**
 * A player's reputations (CMaNGOS `Reputation/ReputationMgr.cpp`): its standing with each faction
 * of the reputation list (`Faction.dbc`'s `reputationListID`), kept as the difference from the
 * base its race and class start with, and each one's flags: shown in the list, at war, inactive.
 *
 * A change in standing makes the faction visible; falling to hostile puts the player at war with
 * it, rising back to neutral ends the war. `reputation_spillover_template` passes a share of each
 * change on to related factions. What changed is noted for the session to send and save.
 */
module dmangos.world.reputation;

import dmangos.world.clientdata : ClientData, FactionEntry;
import dmangos.world.relations : ReputationRank, reputationToRank;

/// `FactionFlags`
enum FactionFlag : uint
{
    visible = 0x01,         /// shown in the reputation list
    atWar = 0x02,           /// the player fights it
    hidden = 0x04,          /// never shown
    invisibleForced = 0x08, /// ditto, by the server
    peaceForced = 0x10,     /// war may not be declared
    inactive = 0x20,        /// moved to the list's inactive part
}

/// `Reputation_Cap`, `Reputation_Bottom`
enum int reputationCap = 42_999, reputationBottom = -42_000;

/// `MAX_REPUTATION_LIST` of 1.12's `SMSG_INITIALIZE_FACTIONS`.
enum reputationListSize = 64;

/// `FactionState`: one faction of the list.
struct FactionState
{
    uint faction;        /// its `Faction.dbc` id
    int standing;        /// above (or below) the base
    uint flags;          /// `FactionFlag`
    bool needSend;       /// changed since the client was told
    bool needSave;       /// changed since `character_reputation` was written
    bool exists;         /// the list has this entry
}

/// A `reputation_spillover_template` row: who else gains, at what rate, up to which rank.
struct Spillover
{
    uint[4] faction;
    float[4] rate = 0;
    uint[4] rank;
}

/// A `character_reputation` row.
struct ReputationRecord
{
    uint faction;
    int standing;
    uint flags;
}

/// See the module documentation.
final class Reputation
{
    FactionState[reputationListSize] states; /// by reputation list id
    uint[] made;                            /// list ids that became visible (`SMSG_SET_FACTION_VISIBLE`)
    private const ClientData client;
    private uint raceMask, classMask;

    ///
    this(const ClientData client, uint raceMask, uint classMask)
    {
        this.client = client;
        this.raceMask = raceMask;
        this.classMask = classMask;
        initialize();
    }

    /// `ReputationMgr::Initialize`: every faction with a reputation, at its base, with its starting flags.
    void initialize()
    {
        states = FactionState.init;
        foreach (id; 1 .. client.factions.idLimit)
            if (const f = client.factions.lookup(id))
                if (f.hasReputation && f.reputationListId < reputationListSize)
                    states[f.reputationListId] = FactionState(f.id, 0, defaultFlags(f), true, true, true);
    }

    /// `GetDefaultStateFlags`
    uint defaultFlags(const(FactionEntry)* f) const
    {
        const i = f.indexFitTo(raceMask, classMask);
        return i >= 0 ? f.reputationFlags[i] : 0;
    }

    /// `GetBaseReputation`
    int baseOf(const(FactionEntry)* f) const
    {
        if (f is null)
            return 0;
        const i = f.indexFitTo(raceMask, classMask);
        return i >= 0 ? f.baseRepValue[i] : 0;
    }

    /// The state of a faction; null if it has no reputation.
    inout(FactionState)* stateOf(const(FactionEntry)* f) inout
    {
        if (f is null || !f.hasReputation || f.reputationListId >= reputationListSize)
            return null;
        auto s = &states[f.reputationListId];
        return s.exists ? s : null;
    }

    /// `GetReputation`: the standing, base included.
    int standingWith(const(FactionEntry)* f) const
    {
        if (auto s = stateOf(f))
            return baseOf(f) + s.standing;
        return 0;
    }

    /// ditto, by faction id
    int standingWith(uint faction) const
    {
        return standingWith(client.factions.lookup(faction));
    }

    /// `GetRank`
    ReputationRank rankWith(const(FactionEntry)* f) const
    {
        return reputationToRank(standingWith(f));
    }

    /// ditto, by faction id
    ReputationRank rankWith(uint faction) const
    {
        return rankWith(client.factions.lookup(faction));
    }

    /// `IsAtWar`
    bool atWarWith(const(FactionEntry)* f) const
    {
        if (auto s = stateOf(f))
            return (s.flags & FactionFlag.atWar) != 0;
        return false;
    }

    /**
     * `SetReputation`/`ModifyReputation`: `standing` more (`incremental`) or exactly; the related
     * factions of `spillovers` get their share first unless `noSpillover`. True if a rank was gained.
     */
    bool change(const(FactionEntry)* f, int standing, bool incremental, const(Spillover)[uint] spillovers,
        bool noSpillover = false)
    {
        if (f is null)
            return false;
        if (!noSpillover)
            if (const s = f.id in spillovers)
                foreach (i; 0 .. 4)
                    if (s.faction[i] && rankWith(s.faction[i]) <= s.rank[i])
                        changeOne(client.factions.lookup(s.faction[i]), cast(int)(standing * s.rate[i]), incremental);
        auto state = stateOf(f);
        if (state is null)
            return false;
        const gained = changeOne(f, standing, incremental);
        state.needSend = true; // `SendState` names it even if its own standing shows nowhere
        return gained;
    }

    /// `SetOneFactionReputation`
    private bool changeOne(const(FactionEntry)* f, int standing, bool incremental)
    {
        auto state = stateOf(f);
        if (state is null)
            return false;
        const base = baseOf(f);
        if (incremental)
            standing += state.standing + base;
        if (standing > reputationCap)
            standing = reputationCap;
        else if (standing < reputationBottom)
            standing = reputationBottom;
        const oldRank = reputationToRank(state.standing + base), newRank = reputationToRank(standing);
        state.standing = standing - base;
        state.needSend = state.needSave = true;
        makeVisible(*state);
        if (newRank != oldRank)
        {
            // Falling to hostile is war (forced, and locked); rising to neutral is peace.
            if (newRank < ReputationRank.unfriendly && newRank < oldRank && oldRank > ReputationRank.hostile)
                setAtWar(*state, true);
            else if (newRank > ReputationRank.unfriendly && newRank > oldRank && oldRank < ReputationRank.neutral)
                setAtWarById(f.reputationListId, false);
        }
        return newRank > oldRank;
    }

    /// `SetVisible`: shown in the list, unless it may never be.
    void makeVisible(ref FactionState s)
    {
        if (s.flags & (FactionFlag.invisibleForced | FactionFlag.hidden) || s.flags & FactionFlag.visible)
            return;
        s.flags |= FactionFlag.visible;
        s.needSend = s.needSave = true;
        foreach (i, ref other; states)
            if (&other is &s)
                made ~= cast(uint) i;
    }

    /// `SetVisible(FactionTemplateEntry)`: the faction of a template met (a quest giver's, ...).
    void makeVisible(uint faction)
    {
        if (auto s = stateOf(client.factions.lookup(faction)))
            makeVisible(*s);
    }

    /// `SetAtWar(RepListID, bool)`: the client's checkbox; not for factions never shown.
    void setAtWarById(int listId, bool on)
    {
        if (listId < 0 || listId >= reputationListSize || !states[listId].exists)
            return;
        auto s = &states[listId];
        if (s.flags & (FactionFlag.invisibleForced | FactionFlag.hidden))
            return;
        setAtWar(*s, on);
    }

    /// `SetAtWar(FactionState*, bool)`: no war on a peace-forced faction above hated.
    void setAtWar(ref FactionState s, bool on)
    {
        if (on && (s.flags & FactionFlag.peaceForced) && reputationToRank(s.standing) > ReputationRank.hated)
            return;
        if ((s.flags & FactionFlag.atWar) && on)
            return;
        if (on)
            s.flags |= FactionFlag.atWar;
        else
            s.flags &= ~FactionFlag.atWar;
        s.needSend = s.needSave = true;
    }

    /// `SetInactive`: only a visible faction may be moved to the inactive part of the list.
    void setInactive(int listId, bool on)
    {
        if (listId < 0 || listId >= reputationListSize || !states[listId].exists)
            return;
        auto s = &states[listId];
        if (on && ((s.flags & (FactionFlag.invisibleForced | FactionFlag.hidden)) || !(s.flags & FactionFlag.visible)))
            return;
        if (((s.flags & FactionFlag.inactive) != 0) == on)
            return;
        if (on)
            s.flags |= FactionFlag.inactive;
        else
            s.flags &= ~FactionFlag.inactive;
        s.needSend = s.needSave = true;
    }

    /// `LoadFromDB`: the saved standings and flags over the starting ones.
    void load(const(ReputationRecord)[] rows)
    {
        initialize();
        foreach (ref row; rows)
        {
            const f = client.factions.lookup(row.faction);
            auto s = stateOf(f);
            if (s is null)
                continue;
            s.standing = row.standing;
            if (row.flags & FactionFlag.visible)
                makeVisible(*s);
            if (row.flags & FactionFlag.inactive)
                setInactive(f.reputationListId, true);
            if (row.flags & FactionFlag.atWar)
                setAtWar(*s, true);
            else if (s.flags & FactionFlag.visible)
                setAtWar(*s, false);
            if (rankWith(f) <= ReputationRank.hostile)
                setAtWar(*s, true);
            if (s.flags == row.flags)
                s.needSend = s.needSave = false;
        }
        made = null; // `SendVisible` is not sent while loading
    }

    /// The rows to write (`SaveToDB`), each faction changed since; they count as saved after.
    ReputationRecord[] takeChanged()
    {
        ReputationRecord[] rows;
        foreach (ref s; states)
            if (s.exists && s.needSave)
            {
                rows ~= ReputationRecord(s.faction, s.standing, s.flags);
                s.needSave = false;
            }
        return rows;
    }
}

unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionFormat;

    // Stormwind (list 0, starts friendly: 3000 above neutral) and a faction starting hostile at war (list 1).
    // Faction: id, list id, 4 race masks, 4 class masks, 4 base values, 4 flags, team, 8 names, 10 skipped.
    uint[] faction(uint id, uint list, int base, uint flags)
    {
        auto row = new uint[factionFormat.length];
        row[0] = id;
        row[1] = list;
        row[2] = 1; // humans
        row[10] = cast(uint) base;
        row[14] = flags;
        return row;
    }

    auto client = new ClientData;
    client.factions = typeof(client.factions).parse(buildDbc(factionFormat, [faction(72, 0, 3000, 0x10),
        faction(87, 1, -6000, 0x2)]), "Faction.dbc");
    auto rep = new Reputation(client, 1, 1);
    const stormwind = client.factions.lookup(72), pirates = client.factions.lookup(87);
    assert(rep.standingWith(stormwind) == 3000 && rep.rankWith(stormwind) == ReputationRank.friendly);
    assert(rep.atWarWith(pirates) && !rep.atWarWith(stormwind));

    // Gains: a rank, visibility.
    Spillover[uint] none;
    assert(!rep.change(stormwind, 3000, true, none), "6000: still friendly");
    assert(rep.change(stormwind, 3000, true, none), "9000: honored");
    assert(rep.rankWith(stormwind) == ReputationRank.honored && rep.states[0].standing == 6000);
    assert(rep.made == [0], "now in the list");
    // Peace forced (0x10) keeps Stormwind out of war; the cap holds.
    rep.setAtWarById(0, true);
    assert(!rep.atWarWith(stormwind));
    rep.change(stormwind, 100_000, true, none);
    assert(rep.standingWith(stormwind) == reputationCap);

    // Rising to neutral ends the war; falling to hostile starts it again.
    rep.change(pirates, 6000, true, none);
    assert(rep.rankWith(pirates) == ReputationRank.neutral && !rep.atWarWith(pirates));
    rep.change(pirates, -3001, true, none); // -3001: hostile
    assert(rep.atWarWith(pirates));

    // Saved and loaded.
    const rows = rep.takeChanged();
    assert(rows.length == 2 && rep.takeChanged().length == 0);
    auto again = new Reputation(client, 1, 1);
    again.load(rows);
    assert(again.standingWith(stormwind) == reputationCap && again.atWarWith(pirates));
}
