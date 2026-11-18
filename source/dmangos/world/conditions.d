/**
 * The `conditions` table: requirements that gossip menus, gossip options, trainer spells and vendor
 * items name by id, and whether a player meets them.
 *
 * A condition checks a player (its items, skills, spells, quests, reputation, race, class, level,
 * zone, death, combat), or
 * combines other conditions with AND, OR and NOT. The ones that need systems this server does not
 * have yet (auras, PvP ranks, world states, instance and world scripts, encounters, waypoints,
 * game events) are never met: a menu option that needs one stays hidden, which errs
 * towards showing less. Each such type is logged once.
 */
module dmangos.world.conditions;

import dmangos.log;
import dmangos.world.clientdata : ClientData, Team;
import dmangos.world.player : Player;

/// What a condition checks: the `conditions.type` column's values.
enum ConditionType : int
{
    not = -3,
    or = -2,
    and = -1,
    none = 0,
    aura = 1,
    item = 2,
    itemEquipped = 3,
    areaId = 4,
    reputationRankMin = 5,
    team = 6,
    skill = 7,
    questRewarded = 8,
    questTaken = 9,
    adCommissionAura = 10,
    pvpRank = 11,
    activeGameEvent = 12,
    areaFlag = 13,
    raceClass = 14,
    level = 15,
    spell = 17,
    instanceScript = 18,
    questAvailable = 19,
    questNone = 22,
    itemWithBank = 23,
    activeHoliday = 26,
    learnableAbility = 28,
    skillBelow = 29,
    reputationRankMax = 30,
    completedEncounter = 31,
    lastWaypoint = 33,
    gender = 35,
    deadOrAway = 36,
    creatureInRange = 37,
    pvpScript = 38,
    spawnCount = 39,
    worldScript = 40,
    worldState = 42,
    isInCombat = 43,
}

/// A `conditions` row.
struct Condition
{
    uint entry;
    int type;
    uint value1;
    uint value2;
    uint value3;
    uint value4;
    uint flags;
}

/// The columns of `Condition`.
enum conditionQuery = "SELECT condition_entry, type, value1, value2, value3, value4, flags FROM conditions";

private enum : uint
{
    conditionFlagReverseResult = 0x1, // CONDITION_FLAG_REVERSE_RESULT
    conditionFlagSwapTargets = 0x2,   // CONDITION_FLAG_SWAP_TARGETS
}

/// Who a condition is checked for, and what is around the object that asks (a creature, for gossip).
struct ConditionSubject
{
    const(Player) player;

    /// Whether a living creature of this entry is within range yards of the source; null when there is no source.
    bool delegate(uint entry, float range) creatureInRange;
}

/// See the module documentation.
final class Conditions
{
    private Condition[uint] entries;
    private bool[int] reported; // unsupported types already logged

    ///
    this(const(Condition)[] rows)
    {
        foreach (row; rows)
            entries[row.entry] = row;
    }

    /// The rows loaded.
    @property size_t length() const
    {
        return entries.length;
    }

    /// Whether condition `id` holds; 0 always does, an unknown id never.
    bool satisfied(uint id, const ref ConditionSubject subject, const ClientData client)
    {
        return id == 0 || meets(id, subject, client, 0);
    }

private:
    bool meets(uint id, const ref ConditionSubject subject, const ClientData client, uint depth)
    {
        const condition = id in entries;
        if (condition is null || depth > 16) // a missing or circular reference: not met
            return false;
        if ((condition.flags & conditionFlagSwapTargets) && !isLogic(condition.type))
            return unsupported(condition.type, "with swapped targets");
        const result = evaluate(*condition, subject, client, depth);
        return (condition.flags & conditionFlagReverseResult) ? !result : result;
    }

    static bool isLogic(int type)
    {
        return type == ConditionType.not || type == ConditionType.or || type == ConditionType.and
            || type == ConditionType.none;
    }

    bool evaluate(const ref Condition c, const ref ConditionSubject subject, const ClientData client, uint depth)
    {
        bool sub(uint id)
        {
            return meets(id, subject, client, depth + 1);
        }

        const player = subject.player;
        with (ConditionType) switch (c.type)
        {
        case not:
            return !sub(c.value1);
        case or:
            return (c.value3 && sub(c.value3)) || (c.value4 && sub(c.value4)) || sub(c.value1) || sub(c.value2);
        case and:
            return (!c.value3 || sub(c.value3)) && (!c.value4 || sub(c.value4)) && sub(c.value1) && sub(c.value2);
        case none:
            return true;
        case item:
            return player.hasItem(c.value1, c.value2);
        case itemWithBank:
            return itemCountWithBank(player, c.value1) >= c.value2;
        case itemEquipped:
            return equipped(player, c.value1);
        case areaId:
            return (player.data.zone == c.value1 || player.area == c.value1) == (c.value2 == 0);
        case team:
            const playerTeam = client.teamForRace(player.data.race);
            return (playerTeam == Team.alliance ? 469 : playerTeam == Team.horde ? 67 : 0) == c.value1;
        case skill:
            const value = player.skillValue(c.value1);
            return value[1] != 0 && value[0] >= c.value2;
        case skillBelow:
            const value = player.skillValue(c.value1);
            if (c.value2 == 1)
                return value[1] == 0;
            return value[1] != 0 && value[0] < c.value2;
        case questRewarded:
            return (c.value1 in player.data.rewardedQuests) !is null;
        case questTaken:
            // The quest is in the log: 1 incomplete, 2 complete and not rewarded, else either.
            import dmangos.world.quests : QuestState;

            const q = c.value1 in player.questStatus;
            if (q is null)
                return false;
            const incomplete = q.status == QuestState.incomplete,
                complete = q.status == QuestState.complete && !q.rewarded;
            return c.value2 == 1 ? incomplete : c.value2 == 2 ? complete : incomplete || complete;
        case reputationRankMin, reputationRankMax:
            const faction = client.factions.lookup(c.value1);
            if (faction is null || player.reputation is null)
                return false;
            const rank = player.reputation.rankWith(faction);
            return c.type == reputationRankMin ? rank >= c.value2 : rank <= c.value2;
        case questNone:
            return (c.value1 in player.data.rewardedQuests) is null;
        case areaFlag:
            const area = client.areas.lookup(player.area);
            return area !is null && (!c.value1 || (area.flags & c.value1)) && (!c.value2 || !(area.flags & c.value2));
        case raceClass:
            return (!c.value1 || (1u << (player.data.race - 1)) & c.value1)
                && (!c.value2 || (1u << (player.data.classId - 1)) & c.value2);
        case pvpRank:
        {
            // `CONDITION_PVP_RANK`: the honor rank (internal, 0 to 18) within value1 and value2.
            import dmangos.world.updatefields : PLAYER_BYTES_3;

            const rank = player.values.getByte!PLAYER_BYTES_3(3);
            return rank >= c.value1 && rank <= c.value2;
        }
        case level:
            switch (c.value2)
            {
            case 0: return player.data.level == c.value1;
            case 1: return player.data.level >= c.value1;
            case 2: return player.data.level <= c.value1;
            default: return false;
            }
        case spell:
            return c.value2 == 0 ? player.knowsSpell(c.value1) : c.value2 == 1 && !player.knowsSpell(c.value1);
        case learnableAbility:
            return learnable(c, player, client);
        case gender:
            return player.data.gender == c.value1;
        case deadOrAway:
            // The player dead (its distance from the source is not part of the subject; groups not yet).
            import dmangos.world.player : DeathState;

            return c.value1 == 0 && player.deathState != DeathState.alive;
        case isInCombat:
            import dmangos.world.defines : UnitFlags;
            import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

            return ((player.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat) != 0) != (c.value1 != 0);
        case creatureInRange:
            return subject.creatureInRange !is null && subject.creatureInRange(c.value1, c.value2);
        case activeGameEvent, activeHoliday:
            return false; // no game event is running
        default:
            return unsupported(c.type, null);
        }
    }

    /// `CONDITION_LEARNABLE_ABILITY`
    static bool learnable(const ref Condition c, const Player player, const ClientData client)
    {
        if (player.knowsSpell(c.value1) || (c.value2 && itemCountWithBank(player, c.value2) >= 1))
            return false;
        foreach (ability; client.abilitiesForSpell(c.value1))
        {
            const value = player.skillValue(ability.skillId);
            if (value[1] == 0)
                return false;
            if (ability.classMask && !(ability.classMask & (1u << (player.data.classId - 1))))
                return false;
            if (ability.raceMask && !(ability.raceMask & (1u << (player.data.race - 1))))
                return false;
            return ability.reqSkillValue <= value[0];
        }
        return false;
    }

    static uint itemCountWithBank(const Player player, uint entry)
    {
        return player.inventory.count(entry, true);
    }

    static bool equipped(const Player player, uint entry)
    {
        return player.inventory.hasEquipped(entry, 1);
    }

    bool unsupported(int type, string how)
    {
        if (type !in reported)
        {
            reported[type] = true;
            warning!"conditions of type %s%s are not supported yet: they are never met"(type,
                how.length ? " " ~ how : "");
        }
        return false;
    }
}

unittest
{
    import dmangos.world.player : CharacterData;
    import dmangos.world.playercreate : KnownAbilities;
    import dmangos.world.testdata : raceHuman, testClientData, testItemGuids, testWorldData;

    auto client = testClientData();
    const rows = [
        Condition(1, ConditionType.level, 10, 1),       // level >= 10
        Condition(2, ConditionType.raceClass, 1, 0),    // human
        Condition(3, ConditionType.and, 1, 2),
        Condition(4, ConditionType.or, 1, 2),
        Condition(5, ConditionType.not, 1),
        Condition(6, ConditionType.level, 10, 1, 0, 0, conditionFlagReverseResult),
        Condition(7, ConditionType.aura, 1234),         // not supported: never met
        Condition(8, ConditionType.team, 469),
    ];
    auto conditions = new Conditions(rows);
    CharacterData c;
    c.guid = 1;
    c.race = raceHuman;
    c.classId = 1;
    c.level = 5;
    const KnownAbilities none;
    auto player = new Player(c, none, testWorldData(client), client, testItemGuids());
    const subject = ConditionSubject(player);
    assert(conditions.satisfied(0, subject, client) && !conditions.satisfied(99, subject, client));
    assert(!conditions.satisfied(1, subject, client) && conditions.satisfied(2, subject, client));
    assert(!conditions.satisfied(3, subject, client) && conditions.satisfied(4, subject, client));
    assert(conditions.satisfied(5, subject, client) && conditions.satisfied(6, subject, client));
    assert(!conditions.satisfied(7, subject, client) && conditions.satisfied(8, subject, client));
}
