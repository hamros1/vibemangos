/**
 * Loot: the loot tables, what a corpse drops, who may take what, and
 * the group's rolls.
 *
 * `LootStore`s hold the `*_loot_template` tables: per loot id, entries rolled each on their own
 * chance (references among them: another table's template, processed `maxcount` times), and groups
 * of which at most one entry drops. `Loot` is one corpse's drop: its money and items, the players who
 * may loot it (`owners`, by the group's loot method), and for each item who may still take it.
 * Packets go out through the `Looter`s it finds by guid, so this module knows no session or map.
 *
 * The loot methods: free for all, round robin (the current looter first; once it releases,
 * anyone), master loot (the master hands out what is over the threshold), group loot and need before
 * greed (items over the threshold are rolled for, a minute to choose). Quest drops are never shown
 * (there are no quests yet); random properties and suffixes are not generated
 * (`item_enchantment_template` is not loaded).
 */
module dmangos.world.loot;

import dmangos.world.enchantments : RandomEnchantment;
import dmangos.frozen : StaticMap;
import std.random : Random, uniform, uniform01;
import dmangos.bytes : ByteReader, ByteWriter, PacketException;
import dmangos.cluster.protocol : GroupLootRoll, QuestLootCheck;
import dmangos.serialization : LengthPrefix;
import dmangos.world.opcodes : Opcode;
import dmangos.world.worlddata : ItemTemplate;

// ---------------------------------------------------------------------------
// The tables
// ---------------------------------------------------------------------------

/// A `*_loot_template` row (`LootStoreItem`).
struct LootStoreItem
{
    uint item;
    float chance = 100;        /// `ChanceOrQuestChance`, made positive
    bool needsQuest;           /// it was negative: a quest drop
    ubyte group;               /// `groupid`: 0 rolls on its own
    int mincountOrRef = 1;     /// negative: a reference to `reference_loot_template`
    ubyte maxCount = 1;        /// `maxcount`; for a reference, how many times it is processed
    uint condition;            /// `condition_id`

    /// Whether the entry drops this time, on its own chance (drop rates of 1).
    bool roll(ref Random random) const
    {
        if (chance >= 100)
            return true;
        return uniform01(random) * 100 < chance;
    }
}

/// One loot id's rows (`LootTemplate`): the entries rolled on their own, and the groups.
final class LootTemplate
{
    LootStoreItem[] entries;
    LootGroup[] groups;

    /// Adds a row: an entry of its own (group 0), or one of a group, chanced or of equal chance.
    void add(const LootStoreItem item)
    {
        if (item.group == 0)
        {
            entries ~= item;
            return;
        }
        if (groups.length < item.group)
            groups.length = item.group;
        auto group = &groups[item.group - 1];
        if (item.chance != 0)
            group.explicitlyChanced ~= item;
        else
            group.equalChanced ~= item;
    }
}

/// The quest drops of a template, its groups' included.
const(uint)[] questItems(const LootTemplate t)
{
    uint[] items;
    foreach (ref e; t.entries)
        if (e.needsQuest && e.mincountOrRef > 0)
            items ~= e.item;
    foreach (ref g; t.groups)
        foreach (list; [g.explicitlyChanced, g.equalChanced])
            foreach (ref e; list)
                if (e.needsQuest && e.mincountOrRef > 0)
                    items ~= e.item;
    return items;
}

/// A loot group: at most one of its entries drops.
struct LootGroup
{
    LootStoreItem[] explicitlyChanced; /// tried in random order against one roll
    LootStoreItem[] equalChanced;      /// when none of those: one of these
}

/// A loot table, by loot id (`LootStore`).
final class LootStore
{
    string table;
    LootTemplate[uint] templates;

    ///
    this(string table)
    {
        this.table = table;
    }

    /// The template of `id`; null if it has no rows.
    inout(LootTemplate) opIndex(uint id) inout
    {
        if (auto found = id in templates)
            return *found;
        return null;
    }

    /// Adds a row.
    void add(uint id, const LootStoreItem item)
    {
        templates.require(id, new LootTemplate).add(item);
    }
}

/// The loot tables this server uses.
struct LootStores
{
    LootStore creature;   /// `creature_loot_template`
    LootStore reference;  /// `reference_loot_template`
    LootStore gameObject; /// `gameobject_loot_template`
    LootStore item;       /// `item_loot_template`: what an item opened holds
    LootStore fishing;    /// `fishing_loot_template`: by area (or zone)
    LootStore skinning;   /// `skinning_loot_template`: a creature's skin (by `SkinningLootId`)
    LootStore pickpocketing; /// `pickpocketing_loot_template`: a creature's pockets (by `PickpocketLootId`)
    LootStore mail;       /// `mail_loot_template`: what a templated letter holds (by its template)
    LootStore disenchant; /// `disenchant_loot_template`: what an item disenchants into (by its `DisenchantID`)

    /// Every store, empty (each named after its table: `creature_loot_template`, ...).
    static LootStores create()
    {
        LootStores stores;
        static foreach (member; __traits(allMembers, LootStores))
            static if (is(typeof(__traits(getMember, stores, member)) == LootStore))
                __traits(getMember, stores, member) = new LootStore(tableOf(member));
        return stores;
    }

    private static string tableOf(string member)
    {
        import std.uni : toLower;

        return toLower(member) ~ "_loot_template"; // `gameObject`: `gameobject_loot_template`
    }
    /// `item_enchantment_template`: the random properties an item of a `RandomProperty` may drop with.
    const(RandomEnchantment[])[uint] randomProperties;
}

/// The columns every `*_loot_template` query selects, in `LootStoreItem` order after the id.
enum lootColumns = "entry, item, ChanceOrQuestChance, groupid, mincountOrRef, maxcount, condition_id";

/// A row from those columns.
LootStoreItem lootRow(uint item, float chanceOrQuestChance, uint group, int mincountOrRef, uint maxCount,
    uint condition) pure nothrow @nogc @safe
{
    LootStoreItem row;
    row.item = item;
    row.needsQuest = chanceOrQuestChance < 0;
    row.chance = chanceOrQuestChance < 0 ? -chanceOrQuestChance : chanceOrQuestChance;
    row.group = cast(ubyte) group;
    row.mincountOrRef = mincountOrRef;
    row.maxCount = cast(ubyte)(maxCount == 0 ? 1 : maxCount);
    row.condition = condition;
    return row;
}

// ---------------------------------------------------------------------------
// One drop
// ---------------------------------------------------------------------------

/// `LootMethod` as a corpse's loot applies it; `notGroup` is a single player's.
enum LootRule : ubyte
{
    freeForAll = 0,
    roundRobin = 1,
    masterLoot = 2,
    groupLoot = 3,
    needBeforeGreed = 4,
    notGroup = 5,
}

/// `LootSlotType`: what a looter may do with an item it is shown; `none`: it is not shown.
enum LootSlotType : ubyte
{
    normal = 0,
    view = 1,
    master = 2,
    reqs = 3,
    none = 4,
}

/// `ClientLootType`
enum ClientLootType : ubyte
{
    corpse = 1,
    pickpocketing = 2,
    fishing = 3,
    disenchanting = 4,
}

/// `LootError`
enum LootError : ubyte
{
    didntKill = 0,
    tooFar = 4,
    badFacing = 5,
    locked = 6,
    notStanding = 8,
    stunned = 9,
    playerNotFound = 10,
    masterInvFull = 12,
    masterUniqueItem = 13,
    masterOther = 14,
}

/// `SMSG_LOOT_RESPONSE` with an error.
const(ubyte)[] lootErrorPacket(ulong target, LootError error)
{
    ByteWriter w;
    w.put(target);
    w.put(ubyte(0));
    w.put(cast(ubyte) error);
    return w.data;
}

/// `RollVote`
enum RollVote : ubyte
{
    pass = 0,
    need = 1,
    greed = 2,
    disenchant = 3,
    notEmittedYet = 4,
    notValid = 5,
}

/// A group roll's time: a minute to choose.
enum lootRollSeconds = 60;

/// The most items one loot holds.
enum maxLootItems = 16;

/// The item flag (`item_template.Flags`) by which every looter gets one.
enum uint itemFlagMultiDrop = 0x800;

/// What a looter is to the loot: a player whose client is shown it, and who takes items and money.
interface Looter
{
    /// Its guid.
    @property ulong looterGuid() const;

    /// Sends it a packet.
    void deliver(Opcode opcode, const(ubyte)[] body_);

    /**
     * Stores `count` of `item` in its bags with the push result, or (with `sendError`) shows why not;
     * returns the `InventoryResult`, 0 if stored.
     */
    uint storeLoot(uint item, uint count, int randomPropertyId, bool sendError);

    /// Money it took or was given its share of.
    void receiveMoney(uint copper);

    /// Whether it could use the item (need before greed offers need only then).
    bool canUseItem(uint item);

    /// It looks into this loot now (`UNIT_FLAG_LOOTING`), or no longer.
    void lootWindow(ulong target, bool open);
}

/// A player's guid -> the looter, or null if it is not here.
alias FindLooter = Looter delegate(ulong guid);

/// `LootItem`: an item in a drop.
final class LootItem
{
    uint itemId;
    uint count;
    uint displayId;
    int randomPropertyId;
    ubyte slot;               /// `lootSlot`: its place in the window
    uint quality;
    uint condition;
    bool quest;               /// a quest drop
    bool freeForAll;          /// multi-drop: every looter takes one
    bool underThreshold;
    bool blocked;             /// being rolled for, or waiting for the master
    bool released;            /// the current looter let it go: anyone may take it
    bool currentLooterPass;   /// the current looter may not take it, so others may
    ulong winner;             /// an awarded item that only its winner may claim
    ulong remoteAward;        /// an outstanding award, locked until the receiver answers
    ulong remoteMasterTarget; /// selected recipient of an outstanding master award
    bool[ulong] allowed;      /// who may still take it

    /// How `player` sees this item in the loot window, by the loot method: may take, may only view, or not at all.
    LootSlotType slotTypeFor(ulong player, const Loot loot) const
    {
        if (player !in allowed || (quest && player in loot.pendingQuestLoot))
            return LootSlotType.none;
        if (winner)
            return blocked ? LootSlotType.view : LootSlotType.normal;
        if (freeForAll)
            return LootSlotType.normal;
        if (loot.turnUntil && usesTurn(loot.rule))
            return LootSlotType.none;
        if (condition && !quest)
        {
            final switch (loot.rule)
            {
            case LootRule.notGroup:
            case LootRule.freeForAll:
                return LootSlotType.normal;
            case LootRule.roundRobin:
            case LootRule.groupLoot:
            case LootRule.needBeforeGreed:
            case LootRule.masterLoot:
                if (!underThreshold && loot.rule == LootRule.masterLoot)
                    break;
                if (blocked)
                    return LootSlotType.view;
                return released || currentLooterPass || loot.currentLooter == player ? LootSlotType.normal
                    : LootSlotType.none;
            }
        }
        final switch (loot.rule)
        {
        case LootRule.freeForAll:
        case LootRule.notGroup:
            return LootSlotType.normal;
        case LootRule.groupLoot:
        case LootRule.needBeforeGreed:
            if (blocked)
                return LootSlotType.view;
            return released || currentLooterPass || loot.currentLooter == player ? LootSlotType.normal
                : LootSlotType.none;
        case LootRule.masterLoot:
            if (underThreshold)
                return released || currentLooterPass || loot.currentLooter == player ? LootSlotType.normal
                    : LootSlotType.none;
            if (player == loot.masterLooter)
                return LootSlotType.master;
            return blocked ? LootSlotType.view : LootSlotType.none;
        case LootRule.roundRobin:
            return released || currentLooterPass || loot.currentLooter == player ? LootSlotType.normal
                : LootSlotType.none;
        }
    }

    bool usesTurn(LootRule rule) const
    {
        return !freeForAll && (rule == LootRule.roundRobin
            || (underThreshold && (rule == LootRule.groupLoot || rule == LootRule.needBeforeGreed)));
    }
}

/// `LootStatus`
enum LootStatus : uint
{
    notFullyLooted = 0x01,
    containGold = 0x02,
    containFreeForAll = 0x04,
    containReleasedItems = 0x08,
}

/// See the module documentation.
final class Loot
{
    immutable ulong target;      /// the corpse
    ClientLootType clientType = ClientLootType.corpse;
    uint gold;
    LootItem[] items;
    LootRule rule = LootRule.notGroup;
    ubyte threshold = 2;         /// uncommon (green)
    ulong currentLooter;         /// round robin's (and below the threshold) turn
    bool remoteTurns;            /// remote members can claim ordinary shared items
    private long turnUntil;      /// while the authoritative turn is outstanding
    ulong masterLooter;
    bool masterStartsRemote;     /// the eligible master was on another node when the loot was made
    ulong remoteTapper;         /// the solo owner was on another node when the loot was made
    bool[ulong] owners;          /// members with local loot rights, including a master who may move here
    bool[ulong] looking;         /// whose window is open
    bool fake;                   /// an empty window, shown once
    bool[ulong] opened;          /// who has opened it
    bool haveItemOverThreshold;
    LootRoll[ubyte] rolls;
    ushort[ulong] remoteMembers;  /// nearby party members simulated on other nodes
    bool hasRemoteQuestDrops;
    private bool[ulong] pendingQuestLoot;
    private ulong questCheckSequence;
    private long questCheckUntil;
    uint rollMap;
    ulong delegate() nextRoll;
    bool delegate(ushort, const ref GroupLootRoll) sendRemoteRoll;
    void delegate(ushort, ulong, Opcode, const(ubyte)[]) tellRemoteRoller;
    ushort delegate(ulong) coinNode; /// where a remote member can receive a share now
    bool delegate(ushort, ulong, uint) payRemoteCoins;
    private bool checked;        // the rolls are started

    /// The players by guid, for packets and items.
    FindLooter find;
    /// Told when what some viewer sees of the corpse (lootable or not) may have changed.
    void delegate() changed;
    /// Told when nobody has anything left to take.
    void delegate() lootedForAll;
    /// Told first when a looter releases it (a disenchanted item's loot: what is left goes into the bags).
    void delegate(Looter) beforeRelease;

    ///
    this(ulong target, FindLooter find)
    {
        this.target = target;
        this.find = find;
    }

    // The rolled contents and rights are independent of the window open on a particular session.
    private struct HandoffItem
    {
        uint itemId;
        uint count;
        uint displayId;
        int randomPropertyId;
        ubyte slot;
        uint quality;
        uint condition;
        bool quest;
        bool freeForAll;
        bool underThreshold;
        bool blocked;
        bool released;
        bool currentLooterPass;
        ulong winner;
        ulong remoteAward;
        ulong remoteMasterTarget;
        @LengthPrefix!ubyte ulong[] allowed;
    }

    private struct HandoffMember
    {
        ulong guid;
        ushort node;
    }

    private struct HandoffVote
    {
        ulong guid;
        RollVote vote;
        ubyte number;
    }

    private struct HandoffRoll
    {
        ubyte slot;
        long endTime;
        bool started;
        ulong serial;
        @LengthPrefix!ubyte HandoffVote[] votes;
    }

    private struct HandoffState
    {
        ClientLootType clientType;
        uint gold;
        LootRule rule;
        ubyte threshold;
        ulong currentLooter;
        bool remoteTurns;
        long turnUntil;
        ulong masterLooter;
        bool masterStartsRemote;
        ulong remoteTapper;
        bool fake;
        bool haveItemOverThreshold;
        bool hasRemoteQuestDrops;
        ulong questCheckSequence;
        long questCheckUntil;
        uint rollMap;
        bool checked;
        @LengthPrefix!ubyte ulong[] owners;
        @LengthPrefix!ubyte ulong[] opened;
        @LengthPrefix!ubyte ulong[] pendingQuestLoot;
        @LengthPrefix!ubyte HandoffMember[] remoteMembers;
        @LengthPrefix!ubyte HandoffItem[] items;
        @LengthPrefix!ubyte HandoffRoll[] rolls;
    }

    package void saveHandoff(ref ByteWriter writer) const
    {
        import dmangos.serialization : serialize;

        HandoffState state = {
            clientType: clientType, gold: gold, rule: rule, threshold: threshold, currentLooter: currentLooter,
            remoteTurns: remoteTurns, turnUntil: turnUntil, masterLooter: masterLooter,
            masterStartsRemote: masterStartsRemote, remoteTapper: remoteTapper, fake: fake,
            haveItemOverThreshold: haveItemOverThreshold, hasRemoteQuestDrops: hasRemoteQuestDrops,
            questCheckSequence: questCheckSequence, questCheckUntil: questCheckUntil, rollMap: rollMap, checked: checked,
            owners: owners.keys, opened: opened.keys, pendingQuestLoot: pendingQuestLoot.keys,
        };
        foreach (guid, node; remoteMembers)
            state.remoteMembers ~= HandoffMember(guid, node);
        foreach (item; items)
        {
            HandoffItem saved = {
                itemId: item.itemId, count: item.count, displayId: item.displayId, randomPropertyId: item.randomPropertyId,
                slot: item.slot, quality: item.quality, condition: item.condition, quest: item.quest,
                freeForAll: item.freeForAll, underThreshold: item.underThreshold, blocked: item.blocked,
                released: item.released, currentLooterPass: item.currentLooterPass, winner: item.winner,
                remoteAward: item.remoteAward, remoteMasterTarget: item.remoteMasterTarget, allowed: item.allowed.keys,
            };
            state.items ~= saved;
        }
        foreach (slot, roll; rolls)
        {
            HandoffRoll saved = {slot: slot, endTime: roll.endTime, started: roll.started, serial: roll.serial};
            foreach (guid, vote; roll.votes)
                saved.votes ~= HandoffVote(guid, vote.vote, vote.number);
            state.rolls ~= saved;
        }
        serialize(writer, state);
    }

    package static Loot loadHandoff(ulong target, ref ByteReader reader)
    {
        import dmangos.serialization : deserialize;

        const state = deserialize!HandoffState(reader);
        if (state.items.length > maxLootItems || state.rolls.length > maxLootItems)
            throw new PacketException("too many loot items in a handoff");
        auto result = new Loot(target, null);
        result.clientType = state.clientType;
        result.gold = state.gold;
        result.rule = state.rule;
        result.threshold = state.threshold;
        result.currentLooter = state.currentLooter;
        result.remoteTurns = state.remoteTurns;
        result.turnUntil = state.turnUntil;
        result.masterLooter = state.masterLooter;
        result.masterStartsRemote = state.masterStartsRemote;
        result.remoteTapper = state.remoteTapper;
        result.fake = state.fake;
        result.haveItemOverThreshold = state.haveItemOverThreshold;
        result.hasRemoteQuestDrops = state.hasRemoteQuestDrops;
        result.questCheckSequence = state.questCheckSequence;
        result.questCheckUntil = state.questCheckUntil;
        result.rollMap = state.rollMap;
        result.checked = state.checked;
        foreach (guid; state.owners)
            result.owners[guid] = true;
        foreach (guid; state.opened)
            result.opened[guid] = true;
        foreach (guid; state.pendingQuestLoot)
            result.pendingQuestLoot[guid] = true;
        foreach (ref member; state.remoteMembers)
            result.remoteMembers[member.guid] = member.node;
        foreach (ref saved; state.items)
        {
            if (saved.slot >= maxLootItems || result.itemInSlot(saved.slot) !is null)
                throw new PacketException("invalid item slot in a loot handoff");
            auto item = new LootItem;
            item.itemId = saved.itemId;
            item.count = saved.count;
            item.displayId = saved.displayId;
            item.randomPropertyId = saved.randomPropertyId;
            item.slot = saved.slot;
            item.quality = saved.quality;
            item.condition = saved.condition;
            item.quest = saved.quest;
            item.freeForAll = saved.freeForAll;
            item.underThreshold = saved.underThreshold;
            item.blocked = saved.blocked;
            item.released = saved.released;
            item.currentLooterPass = saved.currentLooterPass;
            item.winner = saved.winner;
            item.remoteAward = saved.remoteAward;
            item.remoteMasterTarget = saved.remoteMasterTarget;
            foreach (guid; saved.allowed)
                item.allowed[guid] = true;
            result.items ~= item;
        }
        foreach (ref saved; state.rolls)
        {
            auto item = result.itemInSlot(saved.slot);
            if (item is null || saved.slot in result.rolls)
                throw new PacketException("invalid roll slot in a loot handoff");
            auto roll = new LootRoll(result, item);
            roll.endTime = saved.endTime;
            roll.started = saved.started;
            roll.serial = saved.serial;
            foreach (ref vote; saved.votes)
                roll.votes[vote.guid] = LootRoll.Vote(vote.vote, vote.number);
            result.rolls[saved.slot] = roll;
        }
        return result;
    }

    // -------------------------------------------------------------------
    // Filling
    // -------------------------------------------------------------------

    /**
     * Rolls the template's entries and groups into items; `allowedFor` says whether
     * an owner may have an item, `meets` whether the owner or its
     * group meets a condition while rolling.
     */
    void fill(const LootTemplate template_, const LootStores stores, const ref StaticMap!(uint, ItemTemplate) protos,
        ref Random random, bool delegate(uint condition) meets, bool delegate(ulong player, const LootItem) allowedFor)
    {
        process(template_, stores, protos, random, meets);
        foreach (owner, _; owners)
            foreach (item; items)
            {
                if (allowedFor is null || allowedFor(owner, item))
                    item.allowed[owner] = true;
            }
        // Which items wait for a roll or the master.
        foreach (item; items)
        {
            if (item.freeForAll || item.quest || item.quality < threshold)
                item.underThreshold = true;
            else if (rule == LootRule.masterLoot)
            {
                if (masterStartsRemote)
                    item.allowed[masterLooter] = true; // check any condition once the master arrives
                if (masterLooter == 0 || masterLooter !in item.allowed)
                    item.blocked = true;
            }
            else if (rule == LootRule.groupLoot || rule == LootRule.needBeforeGreed)
                item.blocked = true;
            if (remoteTurns && item.usesTurn(rule) && !item.quest && !item.condition)
                foreach (guid, _; remoteMembers)
                    item.allowed[guid] = true;
            item.currentLooterPass = currentLooter != 0 && currentLooter !in item.allowed;
        }
    }

    /// Check the rights reserved for a master who started on another node.
    void checkMasterConditions(scope bool delegate(uint) meets)
    {
        bool removed;
        foreach (item; items)
            if (item.condition && item.slotTypeFor(masterLooter, this) == LootSlotType.master && !meets(item.condition))
            {
                item.allowed.remove(masterLooter);
                item.blocked = true;
                removed = true;
            }
        if (removed && changed !is null)
            changed();
    }

    /// Seed provisional rights before sending any checks. A check can only remove a right.
    void beginQuestLootChecks(uint map, ulong delegate() nextSequence,
        bool delegate(ushort, const ref QuestLootCheck) send)
    {
        if (!remoteMembers.length || send is null)
            return;
        uint[maxLootItems] entries;
        foreach (item; items)
            if (item.quest)
            {
                entries[item.slot] = item.itemId;
                hasRemoteQuestDrops = true;
                foreach (guid, _; remoteMembers)
                    item.allowed[guid] = true;
                item.currentLooterPass = currentLooter !in item.allowed;
            }
        if (!hasRemoteQuestDrops)
            return;
        questCheckSequence = nextSequence();
        questCheckUntil = nowSeconds() + 5;
        foreach (guid, _; remoteMembers)
            pendingQuestLoot[guid] = true;
        foreach (guid, peer; remoteMembers)
        {
            const message = QuestLootCheck(map, target, guid, questCheckSequence, false, 0, entries[]);
            if (!send(peer, message))
                recheckQuestLooter(guid, (const LootItem) => false);
        }
    }

    /// Validate rights against a player's current quest log without restoring a consumed slot.
    bool recheckQuestLooter(ulong guid, scope bool delegate(const LootItem) needs)
    {
        bool changed = pendingQuestLoot.remove(guid);
        foreach (item; items)
            if (item.quest && guid in item.allowed && !needs(item))
            {
                item.allowed.remove(guid);
                if (currentLooter == guid)
                    item.currentLooterPass = true;
                changed = true;
            }
        return changed;
    }

    void acceptQuestLootCheck(ushort peer, const ref QuestLootCheck reply)
    {
        if (reply.sequence != questCheckSequence || reply.player !in pendingQuestLoot
            || remoteMembers.get(reply.player, 0) != peer)
            return;
        const eligible = reply.eligible;
        if (recheckQuestLooter(reply.player, (const LootItem item) => (eligible & (1u << item.slot)) != 0))
            refreshQuestLoot();
    }

    private void refreshQuestLoot()
    {
        if (lootedForEveryone())
        {
            sendReleaseForAll();
            if (lootedForAll !is null)
                lootedForAll();
        }
        else
            refreshOpenWindows();
        if (changed !is null)
            changed();
    }

    /// Ordinary slots stay locked while the coordinator picks their looter.
    void waitForTurn(ulong fallback)
    {
        import dmangos.cluster.services : ServiceHost;

        currentLooter = fallback;
        turnUntil = nowSeconds() + ServiceHost.giveUpAfter.total!"seconds";
    }

    void finishTurn(ulong selected)
    {
        if (!turnUntil)
            return; // a stale answer cannot change who may take an already visible item
        turnUntil = 0;
        if (selected)
            currentLooter = selected;
        foreach (item; items)
            item.currentLooterPass = currentLooter !in item.allowed;
        refreshOpenWindows();
        if (changed !is null)
            changed();
    }

    private void refreshOpenWindows()
    {
        foreach (guid; looking.keys)
            if (auto looter = find(guid))
            {
                if (canLoot(guid))
                    looter.deliver(Opcode.SMSG_LOOT_RESPONSE, contentFor(guid));
                else
                    sendReleaseFor(looter);
            }
    }

    /// Rolls a template's entries and groups, following references `maxcount` times.
    private void process(const LootTemplate template_, const LootStores stores, const ref StaticMap!(uint, ItemTemplate) protos,
        ref Random random, bool delegate(uint) meets)
    {
        foreach (ref entry; template_.entries)
        {
            if (entry.condition && meets !is null && !meets(entry.condition))
                continue;
            if (!entry.roll(random))
                continue;
            if (entry.mincountOrRef < 0)
            {
                if (auto referenced = stores.reference is null ? null : stores.reference[-entry.mincountOrRef])
                    foreach (_; 0 .. entry.maxCount)
                        process(referenced, stores, protos, random, meets);
            }
            else
                add(entry, protos, random, stores.randomProperties);
        }
        foreach (ref group; template_.groups)
        {
            const chosen = rollGroup(group, random, meets);
            if (chosen is null)
                continue;
            if (chosen.mincountOrRef > 0)
                add(*chosen, protos, random);
            else if (auto referenced = stores.reference is null ? null : stores.reference[-chosen.mincountOrRef])
                foreach (_; 0 .. chosen.maxCount)
                    process(referenced, stores, protos, random, meets);
        }
    }

    /// Rolls a group: one of its entries, or none.
    private const(LootStoreItem)* rollGroup(return scope ref const LootGroup group, ref Random random,
        bool delegate(uint) meets)
    {
        import std.random : randomShuffle;

        if (group.explicitlyChanced.length)
        {
            auto order = new const(LootStoreItem)*[group.explicitlyChanced.length];
            foreach (i, ref entry; group.explicitlyChanced)
                order[i] = &entry;
            randomShuffle(order, random);
            float chance = uniform01(random) * 100;
            foreach (entry; order)
            {
                if (entry.condition && meets !is null && !meets(entry.condition))
                    continue;
                if (entry.chance >= 100)
                    return entry;
                chance -= entry.chance;
                if (chance < 0)
                    return entry;
            }
        }
        if (group.equalChanced.length)
        {
            auto order = new const(LootStoreItem)*[group.equalChanced.length];
            foreach (i, ref entry; group.equalChanced)
                order[i] = &entry;
            randomShuffle(order, random);
            foreach (entry; order)
            {
                if (has(entry.item) && uniform(0, 2, random)) // already dropped: half a chance to pick another
                    continue;
                if (entry.condition && meets !is null && !meets(entry.condition))
                    continue;
                return entry;
            }
        }
        return null;
    }

    /// One more item, `mincount` to `maxcount` of it.
    private void add(const ref LootStoreItem entry, const ref StaticMap!(uint, ItemTemplate) protos, ref Random random,
        const(RandomEnchantment[][uint]) properties = null)
    {
        import dmangos.world.enchantments : chooseRandomProperty;

        if (items.length >= maxLootItems)
            return;
        auto item = new LootItem;
        item.itemId = entry.item;
        item.slot = cast(ubyte) items.length;
        item.count = entry.maxCount > entry.mincountOrRef ? uniform!"[]"(entry.mincountOrRef, entry.maxCount, random)
            : entry.mincountOrRef;
        item.quest = entry.needsQuest;
        item.condition = entry.condition;
        if (const proto = entry.item in protos)
        {
            item.displayId = proto.displayId;
            item.quality = proto.details.quality;
            item.freeForAll = (proto.flags & itemFlagMultiDrop) != 0;
            item.underThreshold = item.quality < threshold;
            // It drops with its random property, so the window shows it.
            if (proto.randomProperty)
                item.randomPropertyId = chooseRandomProperty(properties.get(proto.randomProperty, null), random);
        }
        if (!item.underThreshold)
            haveItemOverThreshold = true;
        items ~= item;
    }

    /// Whether an item of `itemId` is in the loot.
    bool has(uint itemId) const
    {
        foreach (item; items)
            if (item.itemId == itemId)
                return true;
        return false;
    }

    /// The money, between `minAmount` and `maxAmount`.
    void generateMoney(uint minAmount, uint maxAmount, ref Random random)
    {
        if (maxAmount == 0)
            return;
        if (maxAmount <= minAmount)
            gold = maxAmount;
        else if (maxAmount - minAmount < 32_700)
            gold = uniform!"[]"(minAmount, maxAmount, random);
        else
            gold = uniform!"[]"(minAmount >> 8, maxAmount >> 8, random) << 8;
    }

    // -------------------------------------------------------------------
    // Rights
    // -------------------------------------------------------------------

    /// The `LootStatus` flags for `player`: money left, items it may still take, and of what kind.
    uint statusFor(ulong player) const
    {
        uint status;
        if (fake && opened.length == 0)
            return LootStatus.notFullyLooted; // a fake loot: shown once, empty
        if (gold && player in owners)
            status |= LootStatus.containGold;
        foreach (item; items)
        {
            if (item.slotTypeFor(player, this) == LootSlotType.none)
                continue;
            status |= LootStatus.notFullyLooted;
            if (item.freeForAll)
                status |= LootStatus.containFreeForAll;
            if (item.released)
                status |= LootStatus.containReleasedItems;
        }
        return status;
    }

    /// Whether nothing is left for `player`.
    bool lootedFor(ulong player) const
    {
        return statusFor(player) == 0;
    }

    /// Whether nothing is left for any of the owners still here.
    bool lootedForEveryone()
    {
        if ((masterStartsRemote && canLoot(masterLooter)) || (remoteTapper && canLoot(remoteTapper)))
            return false;
        foreach (item; items)
        {
            if (item.quest && hasRemoteQuestDrops)
                foreach (guid, _; remoteMembers)
                    if (guid in item.allowed)
                        return false;
            if (item.remoteMasterTarget)
                return false;
            if (item.winner && item.winner in item.allowed)
                return false;
            if (item.usesTurn(rule))
            {
                if (turnUntil && item.allowed.length)
                    return false;
                if (remoteTurns)
                    foreach (guid, _; remoteMembers)
                        if (item.slotTypeFor(guid, this) == LootSlotType.normal)
                            return false;
            }
        }
        foreach (owner, _; owners)
            if (find(owner) !is null && !lootedFor(owner))
                return false;
        return true;
    }

    /// Whether `player` may open it now (the corpse sparkles for it).
    bool canLoot(ulong player) const
    {
        foreach (item; items)
        {
            if (item.winner == player && !item.blocked && player in item.allowed)
                return true;
            if (item.quest && item.slotTypeFor(player, this) == LootSlotType.normal)
                return true;
        }
        if (player !in owners && !(remoteTurns && player in remoteMembers))
            return false;
        const status = statusFor(player);
        if (status == 0)
            return false;
        if (status & (LootStatus.containGold | LootStatus.containFreeForAll))
            return true;
        if (rule == LootRule.notGroup || rule == LootRule.freeForAll)
            return true;
        if (haveItemOverThreshold)
        {
            if (rule == LootRule.masterLoot && player == masterLooter)
                return true;
            if (rule != LootRule.masterLoot && rule != LootRule.roundRobin)
                return true;
        }
        return (status & LootStatus.containReleasedItems) || player == currentLooter;
    }

    /// Whether the corpse can have personalized loot visibility on replicas.
    bool replicatesLootView() const
    {
        return hasRemoteQuestDrops || masterStartsRemote || remoteTapper != 0;
    }

    /// Who sees a loot cursor on a replica before moving to the corpse's node.
    ulong[] replicaLooters() const
    {
        ulong[] eligible;
        const includeMaster = masterStartsRemote && canLoot(masterLooter);
        if (includeMaster)
            eligible ~= masterLooter;
        const includeTapper = remoteTapper != 0 && canLoot(remoteTapper);
        if (includeTapper)
            eligible ~= remoteTapper;
        if (hasRemoteQuestDrops)
            foreach (guid, _; remoteMembers)
            {
                if ((includeMaster && guid == masterLooter) || (includeTapper && guid == remoteTapper))
                    continue;
                foreach (item; items)
                    if (item.quest && item.slotTypeFor(guid, this) == LootSlotType.normal)
                    {
                        eligible ~= guid;
                        break;
                    }
            }
        return eligible;
    }

    /// The item in window slot `slot`; null if none.
    LootItem itemInSlot(uint slot)
    {
        foreach (item; items)
            if (item.slot == slot)
                return item;
        return null;
    }

    // -------------------------------------------------------------------
    // Looting
    // -------------------------------------------------------------------

    /// Opens the window for `looter`, or closes it if it may not loot.
    void showContentTo(Looter looter)
    {
        const guid = looter.looterGuid;
        if (items.length && !canLoot(guid))
            return sendReleaseFor(looter);
        opened[guid] = true;
        if (rule == LootRule.masterLoot)
        {
            if (guid == masterLooter)
                sendMasterList(looter);
        }
        else if (rule != LootRule.notGroup && !checked)
            groupCheck();
        looking[guid] = true;
        looter.lootWindow(target, true);
        looter.deliver(Opcode.SMSG_LOOT_RESPONSE, contentFor(guid));
    }

    /// `SMSG_LOOT_RESPONSE`'s body for `player`.
    ubyte[] contentFor(ulong player) const
    {
        ByteWriter w;
        w.put(target);
        w.put(cast(ubyte) clientType);
        w.put(player in owners ? gold : 0u);
        ubyte shown;
        ByteWriter list;
        foreach (item; items)
        {
            const type = item.slotTypeFor(player, this);
            if (type == LootSlotType.none)
                continue;
            list.put(item.slot);
            list.put(item.itemId);
            list.put(item.count);
            list.put(item.displayId);
            list.put(0u); // random suffix
            list.put(item.randomPropertyId);
            list.put(cast(ubyte) type);
            ++shown;
        }
        w.put(shown);
        w.putBytes(list.data);
        return w.data.dup;
    }

    /// Closes `looter`'s window.
    void sendReleaseFor(Looter looter)
    {
        ByteWriter w;
        w.put(target);
        w.put(ubyte(1));
        looter.deliver(Opcode.SMSG_LOOT_RELEASE_RESPONSE, w.data);
        looking.remove(looter.looterGuid);
        looter.lootWindow(target, false);
    }

    /// Closes every window open on the loot.
    void sendReleaseForAll()
    {
        foreach (guid; looking.keys)
            if (auto looter = find(guid))
                sendReleaseFor(looter);
            else
                looking.remove(guid);
    }

    /// The slot empties in the windows open on it (only `looter`'s for a free-for-all item).
    private void notifyItemRemoved(const LootItem item, Looter looter)
    {
        const body_ = [item.slot];
        if (item.freeForAll)
            return looter.deliver(Opcode.SMSG_LOOT_REMOVED, body_);
        foreach (guid; looking.keys)
            if (auto other = find(guid))
                other.deliver(Opcode.SMSG_LOOT_REMOVED, body_);
            else
                looking.remove(guid);
    }

    /**
     * Puts `item` into `looter`'s bags; the windows lose it. If it does not fit, it is
     * that looter's to take later. Returns the `InventoryResult`.
     */
    uint sendItem(Looter looter, LootItem item, bool sendError = true)
    {
        const guid = looter.looterGuid;
        const result = looter.storeLoot(item.itemId, item.count, item.randomPropertyId, sendError);
        if (result != 0)
        {
            item.blocked = false;
            if (!item.winner)
                currentLooter = guid;
            item.released = false;
            return result;
        }
        notifyItemRemoved(item, looter);
        if (item.freeForAll)
            item.allowed.remove(guid);
        else
            item.allowed = null;
        if (lootedForEveryone())
        {
            sendReleaseForAll();
            if (lootedForAll !is null)
                lootedForAll();
        }
        else if (lootedFor(guid))
            sendReleaseFor(looter);
        if (changed !is null)
            changed();
        return 0;
    }

    /// Give a master loot slot to an eligible member whose inventory is on another node.
    bool sendRemoteMasterAward(ulong recipient, LootItem item)
    {
        const node = remoteMembers.get(recipient, 0);
        if (!node || sendRemoteRoll is null)
            return false;
        const message = GroupLootRoll(GroupLootRoll.Action.masterAward, rollMap, target, recipient,
            nextRoll(), item.slot, item.itemId, item.count, item.randomPropertyId, item.condition);
        item.remoteAward = message.roll;
        item.remoteMasterTarget = recipient;
        item.blocked = true;
        if (sendRemoteRoll(node, message))
            return true;
        item.remoteAward = 0;
        item.remoteMasterTarget = 0;
        item.blocked = false;
        return false;
    }

    /// Show the master why an assignment was rejected.
    void notifyMasterAwardError(uint result)
    {
        import dmangos.world.inventory : InventoryResult;

        if (result)
            if (auto master = find(masterLooter))
            {
                const error = result == InventoryResult.inventoryFull ? LootError.masterInvFull
                    : result == InventoryResult.cantCarryMoreOfThis ? LootError.masterUniqueItem : LootError.masterOther;
                master.deliver(Opcode.SMSG_LOOT_RESPONSE, lootErrorPacket(target, error));
            }
    }

    /// The receiving node confirms storage or unlocks the item following a definitive failure.
    void remoteAwardResult(ushort peer, const ref GroupLootRoll message)
    {
        auto item = itemInSlot(message.slot);
        if (item is null || !item.remoteAward || item.remoteAward != message.roll
            || remoteMembers.get(message.player, 0) != peer)
            return;
        const masterAward = item.remoteMasterTarget != 0;
        if (message.player != (masterAward ? item.remoteMasterTarget : item.winner))
            return;
        item.remoteAward = 0;
        item.remoteMasterTarget = 0;
        item.blocked = false;
        if (message.stored)
        {
            item.allowed = null;
            notifyItemRemoved(item, null); // a remote award is never free-for-all
            if (lootedForEveryone())
            {
                sendReleaseForAll();
                if (lootedForAll !is null)
                    lootedForAll();
            }
        }
        else if (masterAward)
            notifyMasterAwardError(message.inventoryError);
        if (changed !is null)
            changed();
    }

    /**
     * Hands out the money, shared among the owners in a group "as evenly as possible" (WoWWiki "Loot", 2006): the
     * copper left over a copper each, the looter's first, then by guid (docs/FORMULAS.md "Group loot").
     */
    void sendGold(Looter looter)
    {
        import std.algorithm.sorting : sort;

        if (gold == 0 || looter.looterGuid !in owners)
            return;
        const copper = gold;
        gold = 0; // consume the drop before calling either local or remote recipients
        foreach (guid; looking.keys)
            if (auto other = find(guid))
                other.deliver(Opcode.SMSG_LOOT_CLEAR_MONEY, null);
        if (rule != LootRule.notGroup || coinNode !is null)
        {
            const self = looter.looterGuid;
            struct Recipient
            {
                ulong guid;
                Looter local;
                ushort node;
            }
            Recipient[] recipients = [Recipient(self, looter)];
            auto eligible = owners.keys;
            if (coinNode !is null)
                foreach (guid, _; remoteMembers)
                    if (guid !in owners)
                        eligible ~= guid;
            foreach (guid; eligible)
                if (guid != self)
                {
                    if (auto local = find(guid))
                        recipients ~= Recipient(guid, local);
                    else if (coinNode !is null)
                        if (const node = coinNode(guid))
                            recipients ~= Recipient(guid, null, node);
                }
            recipients[1 .. $].sort!((a, b) => a.guid < b.guid);
            const base = cast(uint)(copper / recipients.length);
            const extra = copper % recipients.length;
            uint looterShare = base + uint(extra != 0);
            foreach (i, ref recipient; recipients[1 .. $])
            {
                const share = base + uint(i + 1 < extra);
                if (recipient.local !is null)
                    grantLootCoinShare(recipient.local, share);
                else if (share && !payRemoteCoins(recipient.node, recipient.guid, share))
                {
                    // Nothing was queued on that link. The looter gets the undeliverable share.
                    looterShare += share;
                }
            }
            grantLootCoinShare(looter, looterShare);
        }
        else
            looter.receiveMoney(copper);
        if (lootedFor(looter.looterGuid))
            release(looter);
        else if (changed !is null)
            changed();
    }

    /// `looter` releases a corpse's loot: the window closes; the current looter lets its items go to the others.
    void release(Looter looter)
    {
        if (beforeRelease !is null)
            beforeRelease(looter);
        const guid = looter.looterGuid;
        if (guid == currentLooter)
            foreach (item; items)
                if (!item.blocked && !item.released && !item.winner && !(turnUntil && item.usesTurn(rule)))
                    item.released = true;
        if (guid in looking)
            sendReleaseFor(looter);
        else
            looter.lootWindow(target, false);
        if (fake || lootedForEveryone())
        {
            sendReleaseForAll();
            if (lootedForAll !is null)
                lootedForAll();
        }
        if (changed !is null)
            changed();
    }

    // -------------------------------------------------------------------
    // Rolls and the master
    // -------------------------------------------------------------------

    /// The rolls for the blocked items start on the first open.
    void groupCheck()
    {
        checked = true;
        foreach (guid, _; owners)
        {
            if (find(guid) is null)
                continue;
            foreach (item; items)
            {
                if (!item.blocked || item.slot in rolls || guid !in item.allowed)
                    continue;
                auto roll = new LootRoll(this, item);
                rolls[item.slot] = roll;
                if (!roll.tryToStart(nowSeconds()))
                    rolls.remove(item.slot);
            }
        }
    }

    /// The master can arrive after another member opened the loot, or reopen it after a handoff.
    private void sendMasterList(Looter master)
    {
        ulong[] present;
        foreach (guid, _; owners)
            if (find(guid) !is null)
                present ~= guid;
        if (sendRemoteRoll !is null)
            foreach (guid, _; remoteMembers)
                if (guid !in owners || find(guid) is null)
                    present ~= guid;
        ByteWriter w;
        w.put(cast(ubyte) present.length);
        foreach (guid; present)
            w.put(guid);
        master.deliver(Opcode.SMSG_LOOT_MASTER_LIST, w.data);
    }

    /// The clock rolls time out by (Unix seconds); replaceable for tests.
    long delegate() clock;

    private long nowSeconds()
    {
        import std.datetime.systime : Clock;

        return clock !is null ? clock() : Clock.currTime.toUnixTime;
    }

    /// Rolls whose time is up, or that everyone voted on, end.
    void update()
    {
        const now = nowSeconds();
        if (turnUntil && now >= turnUntil)
            finishTurn(0);
        if (pendingQuestLoot.length && now >= questCheckUntil)
        {
            foreach (guid; pendingQuestLoot.keys)
                recheckQuestLooter(guid, (const LootItem) => false);
            refreshQuestLoot();
        }
        foreach (slot; rolls.keys)
            if (rolls[slot].update(now))
                rolls.remove(slot);
    }

    /// `player` chose for the item in `slot`.
    void vote(Looter player, uint slot, RollVote choice)
    {
        if (slot > ubyte.max)
            return;
        auto roll = cast(ubyte) slot in rolls;
        if (roll is null)
            return;
        if ((*roll).vote(player.looterGuid, choice) && (*roll).update(nowSeconds()))
            rolls.remove(cast(ubyte) slot);
    }

    void remoteVote(ushort peer, const ref GroupLootRoll message)
    {
        if (remoteMembers.get(message.player, 0) != peer
            || (message.choice > RollVote.greed && message.choice != RollVote.notValid))
            return;
        auto roll = message.slot in rolls;
        if (roll is null || (*roll).serial != message.roll || !message.roll)
            return;
        if ((*roll).vote(message.player, cast(RollVote) message.choice) && (*roll).update(nowSeconds()))
            rolls.remove(message.slot);
    }
}

/// A group roll: the owners who may take an item over the threshold roll need, greed or pass for it.
final class LootRoll
{
    private Loot loot;
    private LootItem item;
    private struct Vote
    {
        RollVote vote;
        ubyte number;
    }

    private Vote[ulong] votes;
    private long endTime;
    private bool started;
    private ulong serial;

    ///
    this(Loot loot, LootItem item)
    {
        this.loot = loot;
        this.item = item;
    }

    /// Starts the roll if more than one owner may take it; otherwise it is no longer held.
    bool tryToStart(long now)
    {
        if (item.quest)
            return false;
        item.blocked = true;
        uint players;
        foreach (guid, _; loot.owners)
        {
            if (loot.find(guid) is null || guid !in item.allowed)
            {
                votes[guid] = Vote(RollVote.notValid);
                continue;
            }
            votes[guid] = Vote(RollVote.notEmittedYet);
            ++players;
        }
        if (!item.freeForAll && loot.sendRemoteRoll !is null && loot.remoteMembers.length)
        {
            serial = loot.nextRoll();
            foreach (guid, _; loot.remoteMembers)
                if (guid !in votes)
                {
                    votes[guid] = Vote(RollVote.notEmittedYet);
                    ++players;
                }
        }
        if (players > 1)
        {
            // Need before greed: "'Pass' is automatically selected for party members who can't use an item"
            // (WoWWiki "Loot", 2006-10): they get no roll window, only their pass (docs/FORMULAS.md "Group loot").
            ulong[] autoPassed;
            if (loot.rule == LootRule.needBeforeGreed)
                foreach (guid, ref v; votes)
                    if (v.vote == RollVote.notEmittedYet)
                        if (auto local = loot.find(guid))
                            if (!local.canUseItem(item.itemId))
                            {
                                v.vote = RollVote.pass;
                                autoPassed ~= guid;
                            }
            endTime = now + lootRollSeconds;
            started = true;
            sendStartRoll();
            foreach (guid; autoPassed)
                sendRoll(guid, 128, 128, true);
            return true;
        }
        item.underThreshold = true;
        item.blocked = false;
        return false;
    }

    private void head(ref ByteWriter w)
    {
        w.put(loot.target);
        w.put(uint(item.slot));
    }

    private void itemPart(ref ByteWriter w)
    {
        w.put(item.itemId);
        w.put(0u); // random suffix
        w.put(item.randomPropertyId);
    }

    private void toVoters(Opcode opcode, const(ubyte)[] body_)
    {
        foreach (guid, v; votes)
            if (v.vote != RollVote.notValid)
            {
                if (auto looter = loot.find(guid))
                    looter.deliver(opcode, body_);
                else if (loot.tellRemoteRoller !is null)
                    if (const node = guid in loot.remoteMembers)
                        loot.tellRemoteRoller(*node, guid, opcode, body_);
            }
    }

    /// `SMSG_LOOT_START_ROLL`, to those who choose (not those passed for them: need before greed).
    private void sendStartRoll()
    {
        foreach (guid, v; votes)
        {
            if (v.vote != RollVote.notEmittedYet)
                continue;
            if (auto looter = loot.find(guid))
                looter.deliver(Opcode.SMSG_LOOT_START_ROLL, startRollPacket(loot.target, item.slot, item.itemId,
                    item.randomPropertyId));
            else if (const node = guid in loot.remoteMembers)
            {
                const message = remoteMessage(GroupLootRoll.Action.offer, guid);
                if (!loot.sendRemoteRoll(*node, message))
                    votes[guid].vote = RollVote.pass;
            }
        }
    }

    private GroupLootRoll remoteMessage(GroupLootRoll.Action action, ulong guid) const
    {
        return GroupLootRoll(action, loot.rollMap, loot.target, guid, serial, item.slot, item.itemId, item.count,
            item.randomPropertyId, item.condition, loot.rule == LootRule.needBeforeGreed);
    }

    /// `SMSG_LOOT_ROLL`: what one player chose (and rolled), or was passed for (`autoPass`).
    private void sendRoll(ulong player, uint number, uint type, bool autoPass = false)
    {
        ByteWriter w;
        head(w);
        w.put(player);
        itemPart(w);
        w.put(cast(ubyte) number);
        w.put(cast(ubyte) type);
        w.put(ubyte(autoPass)); // auto pass
        toVoters(Opcode.SMSG_LOOT_ROLL, w.data);
    }

    /// `player` chose need, greed or pass; the group sees it. False if it may not vote.
    bool vote(ulong player, RollVote choice)
    {
        auto v = player in votes;
        if (!started || v is null || v.vote != RollVote.notEmittedYet)
            return false;
        if (choice == RollVote.notValid)
        {
            v.vote = choice; // the remote owner checked the item's condition
            return true;
        }
        if (loot.rule == LootRule.needBeforeGreed && choice != RollVote.pass)
            if (auto looter = loot.find(player))
                if (!looter.canUseItem(item.itemId))
                    return false; // passed for it
        v.vote = choice;
        if (choice != RollVote.pass)
            v.number = cast(ubyte) uniform!"[]"(1, 100);
        switch (choice)
        {
        case RollVote.pass:
            sendRoll(player, 128, 128);
            break;
        case RollVote.need:
            sendRoll(player, 0, 0);
            break;
        case RollVote.greed:
            sendRoll(player, 128, 2);
            break;
        default:
            return false;
        }
        return true;
    }

    /// True when the roll is over (everyone chose, or the time is up).
    bool update(long now)
    {
        ulong winner;
        bool any;
        if (started && (allVoted(winner, any) || now >= endTime))
        {
            finish(winner, any);
            return true;
        }
        return false;
    }

    /// Whether everyone voted, and who won: need beats greed, then the higher number.
    private bool allVoted(out ulong winner, out bool any)
    {
        uint notVoted;
        bool someoneNeeds;
        ubyte best;
        foreach (guid, v; votes)
            switch (v.vote)
            {
            case RollVote.need:
                if (!someoneNeeds || !any || v.number > best)
                {
                    someoneNeeds = true;
                    winner = guid;
                    best = v.number;
                    any = true;
                }
                break;
            case RollVote.greed:
            case RollVote.disenchant:
                if (!someoneNeeds && (!any || v.number > best))
                {
                    winner = guid;
                    best = v.number;
                    any = true;
                }
                break;
            case RollVote.notEmittedYet:
                ++notVoted;
                break;
            default:
                break;
            }
        return notVoted == 0;
    }

    /// The roll ends: the winner gets it; if nobody wanted it, anyone may take it.
    private void finish(ulong winner, bool any)
    {
        item.blocked = false;
        if (!any)
        {
            ByteWriter w;
            head(w);
            itemPart(w);
            toVoters(Opcode.SMSG_LOOT_ALL_PASSED, w.data);
            item.released = true;
        }
        else
        {
            const won = votes[winner];
            foreach (guid, v; votes)
                switch (v.vote)
                {
                case RollVote.pass:
                    break;
                case RollVote.notEmittedYet:
                case RollVote.notValid:
                    sendRoll(guid, 128, 128);
                    break;
                case RollVote.greed:
                    if (won.vote == RollVote.need)
                        break;
                    goto default;
                default:
                    sendRoll(guid, v.number, v.vote);
                    break;
                }
            ByteWriter w;
            head(w);
            itemPart(w);
            w.put(winner);
            w.put(won.number);
            w.put(cast(ubyte) won.vote);
            toVoters(Opcode.SMSG_LOOT_ROLL_WON, w.data);
            item.winner = winner;
            item.allowed = null;
            item.allowed[winner] = true;
            if (auto looter = loot.find(winner))
                loot.sendItem(looter, item);
            else if (const node = winner in loot.remoteMembers)
            {
                if (serial && loot.sendRemoteRoll !is null)
                {
                    item.blocked = true;
                    item.remoteAward = serial;
                    const message = remoteMessage(GroupLootRoll.Action.award, winner);
                    if (!loot.sendRemoteRoll(*node, message))
                    {
                        item.blocked = false;
                        item.remoteAward = 0;
                    }
                }
            }
        }
        started = false;
        if (loot.changed !is null)
            loot.changed();
    }
}

/// The same roll prompt is sent to local and remote clients.
ubyte[] startRollPacket(ulong target, ubyte slot, uint item, int randomProperty)
{
    ByteWriter w;
    w.put(target);
    w.put(uint(slot));
    w.put(item);
    w.put(0u); // random suffix
    w.put(randomProperty);
    w.put(uint(lootRollSeconds * 1000));
    w.put(ubyte(0x0F));
    return w.data.dup;
}

/// Group recipients see the same coin notification whether they are local or remote.
void grantLootCoinShare(Looter looter, uint copper)
{
    if (copper)
        looter.receiveMoney(copper);
    ByteWriter w;
    w.put(copper);
    looter.deliver(Opcode.SMSG_LOOT_MONEY_NOTIFY, w.data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// A looter that keeps what it is sent.
    final class TestLooter : Looter
    {
        ulong guid;
        Opcode[] got;
        const(ubyte)[][] bodies;
        uint[] stored;
        uint money;
        bool full;
        bool windowOpen;
        bool cannotUse;  /// `canUseItem` says no

        this(ulong guid)
        {
            this.guid = guid;
        }

        @property ulong looterGuid() const
        {
            return guid;
        }

        void deliver(Opcode opcode, const(ubyte)[] body_)
        {
            got ~= opcode;
            bodies ~= body_.dup;
        }

        uint storeLoot(uint item, uint count, int randomPropertyId, bool sendError)
        {
            if (full)
                return 50; // EQUIP_ERR_INVENTORY_FULL
            stored ~= item;
            return 0;
        }

        void receiveMoney(uint copper)
        {
            money += copper;
        }

        bool canUseItem(uint item)
        {
            return !cannotUse;
        }

        void lootWindow(ulong target, bool open)
        {
            windowOpen = open;
        }
    }
}

/// Entries roll on their own chance, a group gives at most one, references are followed.
unittest
{
    auto stores = LootStores.create();
    stores.creature.add(1, lootRow(100, 100, 0, 1, 1, 0));    // always
    stores.creature.add(1, lootRow(101, 0.0001f, 0, 1, 1, 0)); // never, in practice
    stores.creature.add(1, lootRow(102, 50, 1, 1, 1, 0));     // group 1: one of these two
    stores.creature.add(1, lootRow(103, 50, 1, 1, 1, 0));
    stores.creature.add(1, lootRow(0, 100, 0, -7, 2, 0));     // reference 7, twice
    stores.reference.add(7, lootRow(200, 100, 0, 3, 3, 0));   // three of it
    stores.creature.add(1, lootRow(300, -100, 0, 1, 1, 0));   // a quest drop
    StaticMap!(uint, ItemTemplate) protos;
    foreach (id; [100u, 101, 102, 103, 200, 300])
    {
        ItemTemplate t;
        t.entry = id;
        t.displayId = id + 1000;
        protos[id] = t;
    }
    auto random = Random(42);
    foreach (_; 0 .. 50)
    {
        auto loot = new Loot(1, (ulong guid) => cast(Looter) null);
        loot.owners[7] = true;
        loot.fill(stores.creature[1], stores, protos, random, null,
            (ulong player, const LootItem item) => !item.quest);
        uint[uint] count;
        foreach (item; loot.items)
            ++count[item.itemId];
        assert(count.get(100, 0) == 1 && 101 !in count);
        assert(count.get(102, 0) + count.get(103, 0) == 1, "one of the group");
        assert(count.get(200, 0) == 2 && loot.items[0].count == 1);
        foreach (item; loot.items)
            if (item.itemId == 200)
                assert(item.count == 3);
        // The quest drop is there but nobody may see it.
        foreach (item; loot.items)
            if (item.itemId == 300)
                assert(item.slotTypeFor(7, loot) == LootSlotType.none);
    }
}

/// A single player's loot: shown, the money and items taken, and then it is looted.
unittest
{
    auto looter = new TestLooter(7);
    auto loot = new Loot(1, (ulong guid) => guid == 7 ? cast(Looter) looter : null);
    loot.owners[7] = true;
    loot.currentLooter = 7;
    auto item = new LootItem;
    item.itemId = 100;
    item.count = 1;
    item.allowed[7] = true;
    loot.items ~= item;
    loot.gold = 25;
    bool done;
    loot.lootedForAll = () { done = true; };
    assert(loot.canLoot(7) && !loot.canLoot(8));

    loot.showContentTo(looter);
    assert(looter.got == [Opcode.SMSG_LOOT_RESPONSE] && looter.windowOpen);
    const response = looter.bodies[0];
    assert(response[8] == ClientLootType.corpse && response[9] == 25 && response[13] == 1, "25 copper, one item");
    loot.sendGold(looter);
    assert(looter.money == 25 && loot.gold == 0 && !done);
    loot.sendItem(looter, item);
    assert(looter.stored == [100] && done && !looter.windowOpen && loot.lootedFor(7));
}

/// Round robin: the current looter first; once it releases, the others.
unittest
{
    auto a = new TestLooter(1), b = new TestLooter(2);
    auto loot = new Loot(9, (ulong guid) => guid == 1 ? cast(Looter) a : guid == 2 ? b : null);
    loot.rule = LootRule.roundRobin;
    loot.owners[1] = true;
    loot.owners[2] = true;
    loot.currentLooter = 1;
    auto item = new LootItem;
    item.itemId = 100;
    item.underThreshold = true;
    item.allowed[1] = true;
    item.allowed[2] = true;
    loot.items ~= item;
    assert(loot.canLoot(1) && !loot.canLoot(2));
    loot.showContentTo(a);
    loot.release(a);
    assert(loot.canLoot(2) && item.slotTypeFor(2, loot) == LootSlotType.normal);
}

/// Group loot: an item over the threshold is rolled for; need beats greed.
unittest
{
    auto a = new TestLooter(1), b = new TestLooter(2);
    auto loot = new Loot(9, (ulong guid) => guid == 1 ? cast(Looter) a : guid == 2 ? b : null);
    long now = 1000;
    loot.clock = () => now;
    loot.rule = LootRule.groupLoot;
    loot.owners[1] = true;
    loot.owners[2] = true;
    loot.currentLooter = 1;
    auto item = new LootItem;
    item.itemId = 100;
    item.quality = 2;
    item.blocked = true;
    item.allowed[1] = true;
    item.allowed[2] = true;
    loot.items ~= item;
    loot.haveItemOverThreshold = true;
    assert(loot.canLoot(2), "anyone may open it to see what is rolled for");
    loot.showContentTo(b);
    assert(a.got == [Opcode.SMSG_LOOT_START_ROLL] && item.slotTypeFor(2, loot) == LootSlotType.view);
    loot.vote(a, 0, RollVote.greed);
    loot.vote(b, 0, RollVote.need);
    assert(b.stored == [100] && a.stored.length == 0, "need wins");
    import std.algorithm.searching : canFind;

    assert(a.got.canFind(Opcode.SMSG_LOOT_ROLL_WON) && loot.rolls.length == 0);

    // Nobody answers: after a minute, it is anyone's.
    auto other = new LootItem;
    other.itemId = 101;
    other.quality = 3;
    other.slot = 1;
    other.blocked = true;
    other.allowed[1] = true;
    other.allowed[2] = true;
    loot.items ~= other;
    auto roll = new LootRoll(loot, other);
    assert(roll.tryToStart(now));
    loot.rolls[1] = roll;
    now += 61;
    loot.update();
    assert(loot.rolls.length == 0 && other.released && !other.blocked);
}

/// A group's money "as evenly as possible": 10 copper among three, 4 to the looter and 3 to each of the others; none
/// lost (it was 3 each, a copper gone).
unittest
{
    auto a = new TestLooter(1), b = new TestLooter(2), c = new TestLooter(3);
    auto loot = new Loot(9, (ulong guid) => guid == 1 ? cast(Looter) a : guid == 2 ? b : guid == 3 ? c : null);
    loot.rule = LootRule.groupLoot;
    foreach (guid; [1UL, 2, 3])
        loot.owners[guid] = true;
    loot.currentLooter = 2;
    loot.gold = 10;
    loot.sendGold(b);
    assert(b.money == 4 && a.money == 3 && c.money == 3);
    loot.gold = 11;
    loot.sendGold(c);
    assert(c.money == 3 + 4 && a.money == 3 + 4 && b.money == 4 + 3, "the looter, then by guid");
}

/// Need before greed: those who cannot use the item are passed for it, with no roll window, and may not roll; the
/// others roll.
unittest
{
    import std.algorithm.searching : canFind;

    auto a = new TestLooter(1), b = new TestLooter(2);
    b.cannotUse = true;
    auto loot = new Loot(9, (ulong guid) => guid == 1 ? cast(Looter) a : guid == 2 ? b : null);
    long now = 1000;
    loot.clock = () => now;
    loot.rule = LootRule.needBeforeGreed;
    loot.owners[1] = true;
    loot.owners[2] = true;
    loot.currentLooter = 1;
    auto item = new LootItem;
    item.itemId = 100;
    item.quality = 2;
    item.blocked = true;
    item.allowed[1] = true;
    item.allowed[2] = true;
    loot.items ~= item;
    auto roll = new LootRoll(loot, item);
    assert(roll.tryToStart(now));
    loot.rolls[0] = roll;
    assert(a.got == [Opcode.SMSG_LOOT_START_ROLL, Opcode.SMSG_LOOT_ROLL], "a's window, and b's pass");
    assert(!b.got.canFind(Opcode.SMSG_LOOT_START_ROLL) && b.got == [Opcode.SMSG_LOOT_ROLL]);
    assert(b.bodies[0][$ - 1] == 1, "an automatic pass");
    loot.vote(b, 0, RollVote.greed);
    assert(loot.rolls.length == 1, "b's greed refused");
    loot.vote(a, 0, RollVote.greed);
    assert(a.stored == [100] && b.stored.length == 0 && loot.rolls.length == 0, "a's alone");
}

/// A handoff keeps the first vote and the original roll deadline, with one award to its winner.
unittest
{
    auto a = new TestLooter(1), b = new TestLooter(2);
    Looter find(ulong guid) { return guid == a.guid ? a : guid == b.guid ? b : null; }
    auto loot = new Loot(9, &find);
    long now = 1000;
    loot.clock = () => now;
    loot.rule = LootRule.groupLoot;
    loot.owners[1] = loot.owners[2] = true;
    auto item = new LootItem;
    item.itemId = 100;
    item.count = 1;
    item.quality = 2;
    item.allowed[1] = item.allowed[2] = true;
    loot.items ~= item;
    auto roll = new LootRoll(loot, item);
    assert(roll.tryToStart(now));
    loot.rolls[0] = roll;
    loot.vote(a, 0, RollVote.need);
    assert(a.stored.length == 0 && b.stored.length == 0);

    ByteWriter writer;
    loot.saveHandoff(writer);
    auto reader = ByteReader(writer.data);
    auto restored = Loot.loadHandoff(loot.target, reader);
    restored.find = &find;
    restored.clock = () => now;
    assert(!reader.remaining && restored.itemInSlot(0).blocked);
    assert(restored.rolls[0].votes[a.guid].vote == RollVote.need);
    restored.vote(a, 0, RollVote.pass); // a duplicate vote cannot reverse the original need
    now += lootRollSeconds - 1;
    restored.update();
    assert(a.stored.length == 0 && b.stored.length == 0 && restored.rolls.length == 1);
    ++now;
    restored.update();
    restored.vote(b, 0, RollVote.need);
    assert(a.stored == [100] && b.stored.length == 0 && !restored.rolls.length);
    assert(restored.itemInSlot(0).allowed.length == 0);
}
