/**
 * Quests: the quest templates, who starts and who ends each, and a character's progress in them.
 *
 * `QuestData` is `quest_template` (the columns this server uses), `creature_questrelation` (the
 * starters) and `creature_involvedrelation` (the enders), with what loading works out (`link`): which
 * quests lead to which (`prevQuests`), the exclusive groups, and the special flags (an item to
 * deliver, a creature to kill). `QuestStatus` is one character's `character_queststatus` row.
 */
module dmangos.world.quests;

/// Quests a quest log holds.
enum uint maxQuestLogSize = 20;
/// A quest's objectives, reward choices, rewards and reputation rewards, at most.
enum uint questObjectives = 4, questRewardChoices = 6, questRewards = 4, questReputations = 5;

/// Where a character stands with a quest.
enum QuestState : ubyte
{
    none = 0,
    complete = 1,
    unavailable = 2,
    incomplete = 3,
    available = 4,
    failed = 5,
}

/// Bits in `quest_spawn_phase.visible_states`. One state describes the current quest attempt.
enum QuestPhaseState : ubyte
{
    inactive = 1,
    active = 2,
    complete = 4,
    rewarded = 8,
    failed = 16,
    all = 31,
}

struct QuestSpawnPhase
{
    uint quest;
    ubyte visibleStates;
    bool repeatable;

    bool allows(const(QuestStatus)* progress) const
    {
        auto state = QuestPhaseState.inactive;
        if (progress !is null)
        {
            if (progress.status == QuestState.incomplete)
                state = QuestPhaseState.active;
            else if (progress.status == QuestState.failed)
                state = QuestPhaseState.failed;
            else if (progress.status == QuestState.complete && (!progress.rewarded || repeatable))
                state = QuestPhaseState.complete;
            else if (progress.rewarded)
                state = QuestPhaseState.rewarded;
        }
        return (visibleStates & state) != 0;
    }
}

/// The mark over a quest giver's head.
enum DialogStatus : ubyte
{
    none = 0,
    unavailable = 1,
    chat = 2,
    incomplete = 3,
    rewardRep = 4,
    available = 5,
    rewardOld = 6,
    reward2 = 7,
}

/// Bits of the `QuestFlags` column.
enum uint questFlagStayAlive = 0x01, questFlagPartyAccept = 0x02, questFlagSharable = 0x08, questFlagHiddenRewards = 0x200,
    questFlagAutoRewarded = 0x400;

/// Bits of the `SpecialFlags` column (some worked out at load).
enum uint specialRepeatable = 0x01, specialExplorationOrEvent = 0x02, specialDeliver = 0x08,
    specialKillOrCast = 0x20, specialTimed = 0x40;

/// Why a quest may not be taken (`SMSG_QUESTGIVER_QUEST_INVALID`).
enum uint invalidDontHaveReq = 0, invalidLowLevel = 1, invalidWrongRace = 6, invalidAlreadyOn = 13;

/// A `quest_template` row.
struct Quest
{
    uint id;
    uint method;              /// `Method`: 0 completes itself
    int zoneOrSort;
    uint minLevel;
    uint maxLevel;            /// 0: any
    int questLevel;
    uint type;
    uint requiredClasses;
    uint requiredRaces;
    uint requiredSkill;
    uint requiredSkillValue;
    uint requiredCondition;
    uint repObjectiveFaction;
    uint repObjectiveValue;
    uint limitTime;
    uint questFlags;
    uint specialFlags;
    int prevQuestId;
    int nextQuestId;
    int exclusiveGroup;
    uint nextQuestInChain;
    uint srcItemId;
    uint srcItemCount;
    uint srcSpell;
    string title;
    string details;
    string objectives;
    string offerRewardText;
    string requestItemsText;
    string endText;
    string[questObjectives] objectiveText;
    uint[questObjectives] reqItemId;
    uint[questObjectives] reqItemCount;
    uint[questObjectives] reqSourceId;
    uint[questObjectives] reqSourceCount;
    int[questObjectives] reqCreatureOrGoId;   /// negative: a game object
    uint[questObjectives] reqCreatureOrGoCount;
    uint[questObjectives] reqSpellCast;
    uint[questRewardChoices] rewChoiceItemId;
    uint[questRewardChoices] rewChoiceItemCount;
    uint[questRewards] rewItemId;
    uint[questRewards] rewItemCount;
    int rewOrReqMoney;
    uint rewMoneyMaxLevel;
    uint rewSpell;
    uint rewSpellCast;
    uint pointMapId;
    float pointX = 0, pointY = 0;
    uint pointOpt;
    uint[4] detailsEmote;
    uint[4] detailsEmoteDelay;
    uint incompleteEmote;
    uint incompleteEmoteDelay;
    uint completeEmote;
    uint completeEmoteDelay;
    uint[questReputations] rewRepFaction;   /// reputation for completing it, with these factions
    int[questReputations] rewRepValue;      /// ditto, so much
    uint requiredMinRepFaction;             /// taken only at this standing or above with this faction
    int requiredMinRepValue;                /// ditto
    uint requiredMaxRepFaction;             /// ... and below this one with this faction
    int requiredMaxRepValue;                /// ditto
    uint[4] offerRewardEmote;
    uint[4] offerRewardEmoteDelay;
    uint startScript;         /// `dbscripts_on_quest_start` when it is taken
    uint completeScript;      /// `dbscripts_on_quest_end` when it is rewarded
    uint rewMailTemplateId;   /// a letter (`MailTemplate.dbc`, items from `mail_loot_template`) after it is rewarded ...
    uint rewMailDelaySecs;    /// ... this many seconds after

    // What loading works out (`QuestData.link`).
    int[] prevQuests;         /// quests that must be done first (negative: be on), from `PrevQuestId` and others' `NextQuestId`

    /// Whether it completes itself (`Method` 0).
    @property bool autoComplete() const pure nothrow @nogc @safe
    {
        return method == 0;
    }

    /// Whether it may be done again.
    @property bool repeatable() const pure nothrow @nogc @safe
    {
        return (specialFlags & specialRepeatable) != 0;
    }

    /// It asks for items.
    @property bool deliver() const pure nothrow @nogc @safe
    {
        return (specialFlags & specialDeliver) != 0;
    }

    /// It asks for creatures killed (or objects used).
    @property bool killOrCast() const pure nothrow @nogc @safe
    {
        return (specialFlags & specialKillOrCast) != 0;
    }

    /// How many reward items there are to choose from.
    uint rewChoiceCount() const pure nothrow @nogc @safe
    {
        uint count;
        foreach (item; rewChoiceItemId)
            if (item)
                ++count;
        return count;
    }

    /// How many reward items are given.
    uint rewItemsCount() const pure nothrow @nogc @safe
    {
        uint count;
        foreach (item; rewItemId)
            if (item)
                ++count;
        return count;
    }

    /// How many items it asks for.
    uint reqItemsCount() const pure nothrow @nogc @safe
    {
        uint count;
        foreach (item; reqItemId)
            if (item)
                ++count;
        return count;
    }

    /// The quest's level, or (if it has none) the player's.
    uint levelFor(uint playerLevel) const pure nothrow @nogc @safe
    {
        return questLevel > 0 ? questLevel : playerLevel;
    }
}

/**
 * The experience for turning the quest in at `playerLevel` (quest rate 1).
 *
 * A quest's full experience is its money at the highest level over 0.6: that money is 60% of the experience in
 * copper (`RewMoneyMaxLevel`, as 1.12's quest data has it; Wowpedia's pre-4.0 quest pages: Shipment to Stormwind,
 * 800 XP "or 4s 80c at max level"). Classic Era's QuestXP table holds the same values for most quests, but rounds a
 * fifth of them differently (Bounty on Garrick Padfoot: 340 in 1.12, 335 in the table): the 1.12 values win
 * (docs/FORMULAS.md, "Quest experience").
 *
 * Five levels above the quest the experience falls to 80%, 60%, 40%, 20%, and 10% from ten levels above, rounded to
 * fives (Wowpedia "Experience point", "Quest XP"). A quest of no level (-1 or 0) is of the player's.
 */
uint questXp(const ref Quest quest, uint playerLevel) pure nothrow @nogc @safe
{
    import std.math : round;

    if (quest.rewMoneyMaxLevel == 0)
        return 0;
    const full = round(quest.rewMoneyMaxLevel / 0.6);
    const qLevel = quest.levelFor(playerLevel);
    if (playerLevel <= qLevel + 5)
        return cast(uint) full;
    static immutable double[5] reduced = [0.8, 0.6, 0.4, 0.2, 0.1];
    const over = playerLevel - qLevel - 6;
    return cast(uint)(round(full * reduced[over < 4 ? over : 4] / 5) * 5);
}

/// A character's progress in a quest (a `character_queststatus` row).
struct QuestStatus
{
    uint quest;
    QuestState status;
    bool rewarded;
    bool explored;
    long timer;
    uint[questObjectives] mobCount;
    uint[questObjectives] itemCount;
    bool changed;             /// to be saved
}

/// A `questgiver_greeting` row: what heads a quest giver's list of quests, and its emote.
struct QuestGreeting
{
    string text;
    uint emote;
    uint emoteDelay;
}

/// The quests and their givers.
final class QuestData
{
    Quest[uint] quests;
    uint[][uint] creatureStarts;   /// creature entry -> quests it gives (`creature_questrelation`)
    uint[][uint] gameObjectStarts; /// game object entry -> quests it gives (`gameobject_questrelation`)
    uint[][uint] gameObjectEnds;   /// ... and takes back (`gameobject_involvedrelation`)
    uint[uint] triggerQuests;      /// area trigger -> the quest whose place it is (`areatrigger_involvedrelation`)
    QuestGreeting[ulong] greetings; /// `questgiver_greeting`: (type << 32 | entry) -> the quest list's text

    /// A quest giver's greeting, for a creature (`gameObject` false) or game object of `entry`; null if none.
    const(QuestGreeting)* greetingOf(uint entry, bool gameObject) const
    {
        return ((ulong(gameObject ? 1 : 0) << 32) | entry) in greetings;
    }
    uint[][uint] creatureEnds;     /// creature entry -> quests it takes back (`creature_involvedrelation`)
    uint[][int] exclusiveGroups;   /// `ExclusiveGroup` -> its quests

    /// The quest, or null.
    const(Quest)* quest(uint id) const
    {
        return id in quests;
    }

    /// Whether an objective of some quest is the game object `entry`.
    bool namesGameObject(uint entry) const
    {
        foreach (ref q; quests)
            foreach (target; q.reqCreatureOrGoId)
                if (target == -cast(int) entry)
                    return true;
        return false;
    }

    /// Loading's second pass: the special flags, the previous quests, the exclusive groups.
    void link()
    {
        foreach (ref q; quests)
        {
            foreach (i; 0 .. questObjectives)
            {
                if (q.reqItemId[i] && q.reqItemCount[i])
                    q.specialFlags |= specialDeliver;
                if (q.reqCreatureOrGoId[i] && q.reqCreatureOrGoCount[i])
                    q.specialFlags |= specialKillOrCast;
            }
            if (q.limitTime)
                q.specialFlags |= specialTimed;
        }
        foreach (id, ref q; quests)
        {
            if (q.prevQuestId && (q.prevQuestId < 0 ? -q.prevQuestId : q.prevQuestId) in quests)
                q.prevQuests ~= q.prevQuestId;
            if (q.nextQuestId)
                if (auto next = (q.nextQuestId < 0 ? -q.nextQuestId : q.nextQuestId) in quests)
                    next.prevQuests ~= q.nextQuestId < 0 ? -cast(int) id : cast(int) id;
            if (q.exclusiveGroup)
                exclusiveGroups[q.exclusiveGroup] ~= id;
        }
    }
}

/// The `quest_template` columns `QuestRow` holds, in its order.
enum questQuery = "SELECT entry, Method, ZoneOrSort, MinLevel, MaxLevel, QuestLevel, Type, RequiredClasses, "
    ~ "RequiredRaces, RequiredSkill, RequiredSkillValue, RequiredCondition, RepObjectiveFaction, RepObjectiveValue, "
    ~ "LimitTime, QuestFlags, SpecialFlags, PrevQuestId, NextQuestId, ExclusiveGroup, NextQuestInChain, SrcItemId, "
    ~ "SrcItemCount, SrcSpell, IFNULL(Title, ''), IFNULL(Details, ''), IFNULL(Objectives, ''), "
    ~ "IFNULL(OfferRewardText, ''), IFNULL(RequestItemsText, ''), IFNULL(EndText, ''), IFNULL(ObjectiveText1, ''), "
    ~ "IFNULL(ObjectiveText2, ''), IFNULL(ObjectiveText3, ''), IFNULL(ObjectiveText4, ''), ReqItemId1, ReqItemId2, "
    ~ "ReqItemId3, ReqItemId4, ReqItemCount1, ReqItemCount2, ReqItemCount3, ReqItemCount4, ReqSourceId1, "
    ~ "ReqSourceId2, ReqSourceId3, ReqSourceId4, ReqSourceCount1, ReqSourceCount2, ReqSourceCount3, ReqSourceCount4, "
    ~ "ReqCreatureOrGOId1, ReqCreatureOrGOId2, ReqCreatureOrGOId3, ReqCreatureOrGOId4, ReqCreatureOrGOCount1, "
    ~ "ReqCreatureOrGOCount2, ReqCreatureOrGOCount3, ReqCreatureOrGOCount4, ReqSpellCast1, ReqSpellCast2, "
    ~ "ReqSpellCast3, ReqSpellCast4, RewChoiceItemId1, RewChoiceItemId2, RewChoiceItemId3, RewChoiceItemId4, "
    ~ "RewChoiceItemId5, RewChoiceItemId6, RewChoiceItemCount1, RewChoiceItemCount2, RewChoiceItemCount3, "
    ~ "RewChoiceItemCount4, RewChoiceItemCount5, RewChoiceItemCount6, RewItemId1, RewItemId2, RewItemId3, RewItemId4, "
    ~ "RewItemCount1, RewItemCount2, RewItemCount3, RewItemCount4, RewOrReqMoney, RewMoneyMaxLevel, RewSpell, "
    ~ "RewSpellCast, PointMapId, PointX, PointY, PointOpt, DetailsEmote1, DetailsEmote2, DetailsEmote3, DetailsEmote4, "
    ~ "DetailsEmoteDelay1, DetailsEmoteDelay2, DetailsEmoteDelay3, DetailsEmoteDelay4, IncompleteEmote, "
    ~ "IncompleteEmoteDelay, CompleteEmote, CompleteEmoteDelay, OfferRewardEmote1, OfferRewardEmote2, "
    ~ "OfferRewardEmote3, OfferRewardEmote4, OfferRewardEmoteDelay1, OfferRewardEmoteDelay2, OfferRewardEmoteDelay3, "
    ~ "OfferRewardEmoteDelay4, RewRepFaction1, RewRepFaction2, RewRepFaction3, RewRepFaction4, RewRepFaction5, "
    ~ "RewRepValue1, RewRepValue2, RewRepValue3, RewRepValue4, RewRepValue5, RequiredMinRepFaction, "
    ~ "RequiredMinRepValue, RequiredMaxRepFaction, RequiredMaxRepValue, StartScript, CompleteScript, RewMailTemplateId, RewMailDelaySecs FROM quest_template";

/// One row of `questQuery`.
struct QuestRow
{
    uint id, method;
    int zoneOrSort;
    uint minLevel, maxLevel;
    int questLevel;
    uint type, requiredClasses, requiredRaces, requiredSkill, requiredSkillValue, requiredCondition,
        repObjectiveFaction, repObjectiveValue, limitTime, questFlags, specialFlags;
    int prevQuestId, nextQuestId, exclusiveGroup;
    uint nextQuestInChain, srcItemId, srcItemCount, srcSpell;
    string title, details, objectives, offerRewardText, requestItemsText, endText;
    string ot1, ot2, ot3, ot4;
    uint ri1, ri2, ri3, ri4, rc1, rc2, rc3, rc4, rs1, rs2, rs3, rs4, rsc1, rsc2, rsc3, rsc4;
    int cg1, cg2, cg3, cg4;
    uint cgc1, cgc2, cgc3, cgc4, sc1, sc2, sc3, sc4;
    uint ch1, ch2, ch3, ch4, ch5, ch6, chc1, chc2, chc3, chc4, chc5, chc6;
    uint rw1, rw2, rw3, rw4, rwc1, rwc2, rwc3, rwc4;
    int rewOrReqMoney;
    uint rewMoneyMaxLevel, rewSpell, rewSpellCast, pointMapId;
    float pointX, pointY;
    uint pointOpt;
    uint de1, de2, de3, de4, ded1, ded2, ded3, ded4, incompleteEmote, incompleteEmoteDelay, completeEmote,
        completeEmoteDelay, oe1, oe2, oe3, oe4, oed1, oed2, oed3, oed4;
    uint rrf1, rrf2, rrf3, rrf4, rrf5;
    int rrv1, rrv2, rrv3, rrv4, rrv5;
    uint requiredMinRepFaction;
    int requiredMinRepValue;
    uint requiredMaxRepFaction;
    int requiredMaxRepValue;
    uint startScript, completeScript;
    uint rewMailTemplateId, rewMailDelaySecs;

    Quest toQuest() const
    {
        Quest q;
        static foreach (f; ["id", "method", "zoneOrSort", "minLevel", "maxLevel", "questLevel", "type",
                "requiredClasses", "requiredRaces", "requiredSkill", "requiredSkillValue", "requiredCondition",
                "repObjectiveFaction", "repObjectiveValue", "limitTime", "questFlags", "specialFlags", "prevQuestId",
                "nextQuestId", "exclusiveGroup", "nextQuestInChain", "srcItemId", "srcItemCount", "srcSpell", "title",
                "details", "objectives", "offerRewardText", "requestItemsText", "endText", "rewOrReqMoney",
                "rewMoneyMaxLevel", "rewSpell", "rewSpellCast", "pointMapId", "pointX", "pointY", "pointOpt",
                "incompleteEmote", "incompleteEmoteDelay", "completeEmote", "completeEmoteDelay",
                "requiredMinRepFaction", "requiredMinRepValue", "requiredMaxRepFaction", "requiredMaxRepValue",
                "startScript", "completeScript", "rewMailTemplateId", "rewMailDelaySecs"])
            __traits(getMember, q, f) = __traits(getMember, this, f);
        q.objectiveText = [ot1, ot2, ot3, ot4];
        q.reqItemId = [ri1, ri2, ri3, ri4];
        q.reqItemCount = [rc1, rc2, rc3, rc4];
        q.reqSourceId = [rs1, rs2, rs3, rs4];
        q.reqSourceCount = [rsc1, rsc2, rsc3, rsc4];
        q.reqCreatureOrGoId = [cg1, cg2, cg3, cg4];
        q.reqCreatureOrGoCount = [cgc1, cgc2, cgc3, cgc4];
        q.reqSpellCast = [sc1, sc2, sc3, sc4];
        q.rewChoiceItemId = [ch1, ch2, ch3, ch4, ch5, ch6];
        q.rewChoiceItemCount = [chc1, chc2, chc3, chc4, chc5, chc6];
        q.rewItemId = [rw1, rw2, rw3, rw4];
        q.rewItemCount = [rwc1, rwc2, rwc3, rwc4];
        q.rewRepFaction = [rrf1, rrf2, rrf3, rrf4, rrf5];
        q.rewRepValue = [rrv1, rrv2, rrv3, rrv4, rrv5];
        q.detailsEmote = [de1, de2, de3, de4];
        q.detailsEmoteDelay = [ded1, ded2, ded3, ded4];
        q.offerRewardEmote = [oe1, oe2, oe3, oe4];
        q.offerRewardEmoteDelay = [oed1, oed2, oed3, oed4];
        if (q.maxLevel == 0)
            q.maxLevel = 255;
        return q;
    }
}

unittest
{
    Quest q;
    q.questLevel = 5;
    q.rewMoneyMaxLevel = 150;
    assert(questXp(q, 5) == 250 && questXp(q, 10) == 250, "full up to five levels above");
    assert(questXp(q, 11) == 200 && questXp(q, 14) == 50 && questXp(q, 15) == 25 && questXp(q, 30) == 25);
    q.rewMoneyMaxLevel = 204; // Bounty on Garrick Padfoot: 340 XP
    assert(questXp(q, 5) == 340 && questXp(q, 11) == 270 && questXp(q, 12) == 205, "80%, 60%, to fives");
    q.questLevel = -1;
    assert(questXp(q, 30) == 340, "of the player's level");

    auto data = new QuestData;
    Quest first, second;
    first.id = 1;
    first.nextQuestId = 2;
    first.reqItemId[0] = 117;
    first.reqItemCount[0] = 2;
    second.id = 2;
    second.reqCreatureOrGoId[0] = 6;
    second.reqCreatureOrGoCount[0] = 10;
    data.quests[1] = first;
    data.quests[2] = second;
    data.link();
    assert(data.quests[1].deliver && !data.quests[1].killOrCast && data.quests[2].killOrCast);
    assert(data.quests[2].prevQuests == [1], "the first leads to the second");
}
