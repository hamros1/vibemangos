/**
 * A character's items: the item objects and bags, where they are, and every rule for moving them.
 *
 * `Inventory` holds the character's slots with the functions that check and change them: storing,
 * banking, equipping, unequipping and using items, removing, destroying, splitting and swapping them,
 * the buyback slots and repairs. Character creation and players in the world
 * both use it; what it needs to know about its owner (level, skills, spells, ...) it asks through
 * `InventoryOwner`.
 *
 * Positions are a `ushort` holding the bag in the high byte (`inventorySlotBag0` for the
 * character's own slots, else the slot of an equipped bag) and the slot in the low byte.
 *
 * Changes are kept for the two who need them: the client (items to create, items whose fields
 * changed, items to forget: `writeUpdates`) and the database (each item's save state and the
 * save queue: `takeChanges`). The owner's own fields (the slot guids, the visible
 * items, the buyback prices) are written into the `UpdateValues` given to the constructor.
 *
 * Not handled yet, because the systems do not exist: loot held in items, item enchantments and
 * their durations, item sets, item spells and cooldowns, random properties, reputation (every
 * faction counts as neutral) and honor ranks (none), and mailing an item that has no room.
 */
module dmangos.world.inventory;

import std.algorithm.comparison : min;
import std.algorithm.mutation : remove;
import std.algorithm.searching : canFind, countUntil;
import std.conv : ConvException, to;

import dmangos.log;
import dmangos.world.clientdata : ClientData;
import dmangos.world.defines;
import dmangos.world.objects : HighGuid, makeGuid, UpdateData, UpdateValues;
import dmangos.world.updatefields;
import dmangos.world.worlddata : ItemTemplate, WorldData;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Item sub-classes, bag families, bindings and flags the inventory rules read.
enum : uint
{
    itemSubclassFood = 5,
    itemSubclassContainer = 0, itemSubclassSoulContainer = 1, itemSubclassHerbContainer = 2,
    itemSubclassEnchantingContainer = 3, itemSubclassEngineeringContainer = 4,
    itemSubclassQuiver = 2, itemSubclassAmmoPouch = 3,
    itemSubclassWeaponFist = 13,
    itemSubclassArmorMisc = 0, itemSubclassArmorLibram = 7, itemSubclassArmorIdol = 8, itemSubclassArmorTotem = 9,
    bagFamilyArrows = 1, bagFamilyBullets = 2, bagFamilySoulShards = 3, bagFamilyHerbs = 6,
    bagFamilyEnchantingSupp = 7, bagFamilyEngineeringSupp = 8, bagFamilyKeys = 9,
    bindWhenPickedUp = 1, bindWhenEquipped = 2, bindQuestItem = 4,
    itemFlagNoUserDestroy = 0x00000020,
    itemFlagNoCreator = 0x00020000,
    itemFlagUniqueEquippable = 0x00080000,
    itemDynFlagBound = 0x1,    /// `ITEM_DYNFLAG_BINDED`
    itemDynFlagUnlocked = 0x4, /// `ITEM_DYNFLAG_UNLOCKED`: a lockbox picked
    itemDynFlagWrapped = 0x8,  /// `ITEM_DYNFLAG_WRAPPED`
    skillFistWeapons = 473,
}

/// Keyring slots by (level - 1) / 10: Blizzard's 1.11 announcement (WoWWiki "Keyring", 2006-11): "Level 1-40 = 4 slots,
/// Level 41-50 = 8 slots, Level 51-60 = 12 slots" (it went by level / 10: 8 at 40, 12 at 50).
private immutable uint[7] keyringSizeByLevel = [4, 4, 4, 4, 8, 12, 12];

/// The client's equip errors (`SMSG_INVENTORY_CHANGE_FAILURE`); values are on the wire.
enum InventoryResult : ubyte
{
    ok,
    cantEquipLevel,
    cantEquipSkill,
    itemDoesntGoToSlot,
    bagFull,
    nonEmptyBagOverOtherBag,
    cantTradeEquipBags,
    onlyAmmoCanGoHere,
    noRequiredProficiency,
    noEquipmentSlotAvailable,
    youCanNeverUseThatItem,
    youCanNeverUseThatItem2,
    noEquipmentSlotAvailable2,
    cantEquipWithTwoHanded,
    cantDualWield,
    itemDoesntGoIntoBag,
    itemDoesntGoIntoBag2,
    cantCarryMoreOfThis,
    noEquipmentSlotAvailable3,
    itemCantStack,
    itemCantBeEquipped,
    itemsCantBeSwapped,
    slotIsEmpty,
    itemNotFound,
    cantDropSoulbound,
    outOfRange,
    triedToSplitMoreThanCount,
    couldntSplitItems,
    missingReagent,
    notEnoughMoney,
    notABag,
    canOnlyDoWithEmptyBags,
    dontOwnThatItem,
    canEquipOnlyOneQuiver,
    mustPurchaseThatBagSlot,
    tooFarAwayFromBank,
    itemLocked,
    youAreStunned,
    youAreDead,
    cantDoRightNow,
    intBagError,
    canEquipOnlyOneBolt,
    canEquipOnlyOneAmmoPouch,
    stackableCantBeWrapped,
    equippedCantBeWrapped,
    wrappedCantBeWrapped,
    boundCantBeWrapped,
    uniqueCantBeWrapped,
    bagsCantBeWrapped,
    alreadyLooted,
    inventoryFull,
    bankFull,
    itemIsCurrentlySoldOut,
    bagFull3,
    itemNotFound2,
    itemCantStack2,
    bagFull4,
    itemSoldOut,
    objectIsBusy,
    none,               /// sent to say "nothing happened" (`EQUIP_ERR_NONE`)
    notInCombat,
    notWhileDisarmed,
    bagFull6,
    cantEquipRank,
    cantEquipReputation,
    tooManySpecialBags,
    lootCantLootThatNow,
}

static assert(InventoryResult.inventoryFull == 50 && InventoryResult.none == 59
    && InventoryResult.lootCantLootThatNow == 66, "EQUIP_ERR_* values");

/// Why a purchase failed (`SMSG_BUY_FAILED`).
enum BuyResult : ubyte
{
    cantFindItem = 0,
    itemAlreadySold = 1,
    notEnoughMoney = 2,
    sellerDoesntLikeYou = 4,
    distanceTooFar = 5,
    silentError = 6,
    itemSoldOut = 7,
    cantCarryMore = 8,
    rankRequired = 11,
    reputationRequired = 12,
}

/// Why a sale failed (`SMSG_SELL_ITEM`).
enum SellResult : ubyte
{
    cantFindItem = 1,
    cantSellItem = 2,
    cantFindVendor = 3,
    youDontOwnThatItem = 4,
    none = 5,
    onlyEmptyBag = 6,
}

// ---------------------------------------------------------------------------
// Positions
// ---------------------------------------------------------------------------

/// A position from a bag and a slot.
ushort itemPos(ubyte bag, ubyte slot) pure nothrow @nogc @safe
{
    return cast(ushort)(bag << 8 | slot);
}

/// The backpack, the equipped bags, the keyring, or "anywhere carried".
bool isInventoryPos(ubyte bag, ubyte slot) pure nothrow @nogc @safe
{
    if (bag == inventorySlotBag0)
        return slot == nullSlot || (slot >= inventorySlotItemStart && slot < inventorySlotItemEnd)
            || (slot >= keyringSlotStart && slot < keyringSlotEnd);
    return bag >= inventorySlotBagStart && bag < inventorySlotBagEnd;
}

/// ditto
bool isInventoryPos(ushort pos) pure nothrow @nogc @safe
{
    return isInventoryPos(pos >> 8, pos & 0xFF);
}

/// Worn, or an equipped bag's slot.
bool isEquipmentPos(ubyte bag, ubyte slot) pure nothrow @nogc @safe
{
    return bag == inventorySlotBag0 && (slot < equipmentSlotEnd
        || (slot >= inventorySlotBagStart && slot < inventorySlotBagEnd));
}

/// ditto
bool isEquipmentPos(ushort pos) pure nothrow @nogc @safe
{
    return isEquipmentPos(pos >> 8, pos & 0xFF);
}

/// The bank's slots, its bag slots, or a bank bag.
bool isBankPos(ubyte bag, ubyte slot) pure nothrow @nogc @safe
{
    if (bag == inventorySlotBag0)
        return (slot >= bankSlotItemStart && slot < bankSlotItemEnd) || (slot >= bankBagSlotStart && slot < bankBagSlotEnd);
    return bag >= bankBagSlotStart && bag < bankBagSlotEnd;
}

/// ditto
bool isBankPos(ushort pos) pure nothrow @nogc @safe
{
    return isBankPos(pos >> 8, pos & 0xFF);
}

/// A slot that holds a bag, carried or in the bank.
bool isBagPos(ushort pos) pure nothrow @nogc @safe
{
    const bag = pos >> 8, slot = pos & 0xFF;
    return bag == inventorySlotBag0 && ((slot >= inventorySlotBagStart && slot < inventorySlotBagEnd)
        || (slot >= bankBagSlotStart && slot < bankBagSlotEnd));
}

/// Whether the kind of bag `bag` takes the item `proto`.
bool itemCanGoIntoBag(const(ItemTemplate)* proto, const(ItemTemplate)* bag) pure nothrow @nogc @safe
{
    if (bag.itemClass == ItemClass.container)
    {
        switch (bag.subClass)
        {
        case itemSubclassContainer: return true;
        case itemSubclassSoulContainer: return proto.bagFamily == bagFamilySoulShards;
        case itemSubclassHerbContainer: return proto.bagFamily == bagFamilyHerbs;
        case itemSubclassEnchantingContainer: return proto.bagFamily == bagFamilyEnchantingSupp;
        case itemSubclassEngineeringContainer: return proto.bagFamily == bagFamilyEngineeringSupp;
        default: return false;
        }
    }
    if (bag.itemClass == ItemClass.quiver)
    {
        if (bag.subClass == itemSubclassQuiver)
            return proto.bagFamily == bagFamilyArrows;
        if (bag.subClass == itemSubclassAmmoPouch)
            return proto.bagFamily == bagFamilyBullets;
    }
    return false;
}

/// Whether the item may be put on or taken off in combat: weapons, ammo, shields, relics and held items.
bool canChangeEquipStateInCombat(const(ItemTemplate)* proto) pure nothrow @nogc @safe
{
    switch (proto.inventoryType)
    {
    case InventoryType.relic, InventoryType.shield, InventoryType.holdable:
        return true;
    default:
        return proto.itemClass == ItemClass.weapon || proto.itemClass == ItemClass.projectile;
    }
}

/// The weapon or armor skill an item needs.
uint itemSkill(const(ItemTemplate)* proto) pure nothrow @nogc @safe
{
    static immutable uint[21] weaponSkills = [44, 172, 45, 46, 54, 160, 229, 43, 55, 0, 136, 0, 0, 162, 0, 173,
        176, 253, 226, 228, 356];
    static immutable uint[10] armorSkills = [0, 415, 414, 413, 293, 0, 433, 0, 0, 0];
    if (proto.itemClass == ItemClass.weapon)
        return proto.subClass < weaponSkills.length ? weaponSkills[proto.subClass] : 0;
    if (proto.itemClass == ItemClass.armor)
        return proto.subClass < armorSkills.length ? armorSkills[proto.subClass] : 0;
    return 0;
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

/// One `character_inventory` row joined with its `item_instance`.
struct ItemRecord
{
    uint bag;          /// the low guid of the bag it is in; 0 for the character's own slots
    ubyte slot;
    uint guid;
    uint entry;
    uint creator;
    uint giftCreator;
    uint count;
    uint duration;
    string charges;      /// five numbers
    uint flags;
    string enchantments; /// 21 numbers
    int randomPropertyId;
    uint durability;
    uint textId;
}

/// What the next save does with an item.
enum ItemState
{
    unchanged,
    changed,  /// update its rows
    new_,     /// insert its rows
    removed,  /// delete its rows
}

/// An item's rows to write or delete.
struct ItemChange
{
    ItemState state;
    ItemRecord record;
}

/// An item, and a bag when it has `contents`.
final class Item
{
    const uint guid;                /// the low guid
    const(ItemTemplate)* proto;
    UpdateValues values;
    Item container;                 /// the bag it is in; null in the owner's own slots
    ubyte slot = nullSlot;          /// in the owner's slots or in `container`
    Item[] contents;                /// a bag's slots, `ContainerSlots` long
    ItemState state = ItemState.new_;
    private bool queued;            /// in the inventory's save queue
    private bool sent;              /// the client has its create block

    /**
     * Its random property: the property's id in `ITEM_FIELD_RANDOM_PROPERTIES_ID` (the client names the
     * item by it) and the property's enchantments in slots 3 to 5.
     */
    void setRandomProperty(uint property, const WorldData world)
    {
        import dmangos.world.enchantments : EnchantmentSlot, fieldsPerSlot;

        values.set!ITEM_FIELD_RANDOM_PROPERTIES_ID(property);
        if (const enchantments = property in world.propertyEnchantments)
            foreach (i, enchantment; *enchantments)
                values.set!ITEM_FIELD_ENCHANTMENT((EnchantmentSlot.property0 + i) * fieldsPerSlot, enchantment);
    }

    /// The enchantments in its slots (0 where there is none).
    uint enchantment(size_t slot) const
    {
        import dmangos.world.enchantments : fieldsPerSlot;

        return values.get!ITEM_FIELD_ENCHANTMENT(slot * fieldsPerSlot);
    }

    /// It becomes an item of `proto` (wrapped in paper, or unwrapped), the rest of it as it was.
    void changeEntry(const(ItemTemplate)* to)
    in (to !is null)
    {
        proto = to;
        values.set!OBJECT_FIELD_ENTRY(to.entry);
    }

    /// A new item (or bag) of `proto` for `owner`, one in the stack.
    this(uint guid, const(ItemTemplate)* proto, ulong owner)
    in (proto !is null)
    {
        this.guid = guid;
        this.proto = proto;
        const bag = proto.inventoryType == InventoryType.bag && proto.containerSlots > 0;
        values = UpdateValues(bag ? TypeId.container : TypeId.item);
        values.set!OBJECT_FIELD_GUID(fullGuid);
        values.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.item | (bag ? TypeMask.container : 0));
        values.set!OBJECT_FIELD_ENTRY(proto.entry);
        values.set!OBJECT_FIELD_SCALE_X(1.0f);
        values.set!ITEM_FIELD_OWNER(owner);
        values.set!ITEM_FIELD_CONTAINED(owner);
        values.set!ITEM_FIELD_STACK_COUNT(1u);
        values.set!ITEM_FIELD_MAXDURABILITY(proto.maxDurability);
        values.set!ITEM_FIELD_DURABILITY(proto.maxDurability);
        foreach (i, charges; proto.spellCharges)
            values.set!ITEM_FIELD_SPELL_CHARGES(i, charges);
        values.set!ITEM_FIELD_DURATION(proto.duration);
        if (bag)
        {
            const size = cast(uint) min(proto.containerSlots, maxBagSize);
            values.set!CONTAINER_FIELD_NUM_SLOTS(size);
            contents = new Item[size];
        }
    }

    /// The item a saved row describes.
    static Item load(const ref ItemRecord record, const(ItemTemplate)* proto, ulong owner)
    {
        import dmangos.world.battlegroup : realmPlayerGuid;

        auto item = new Item(record.guid, proto, owner);
        ref v = item.values;
        if (record.creator)
            v.set!ITEM_FIELD_CREATOR(realmPlayerGuid(cast(uint)(owner >> 32), record.creator));
        if (record.giftCreator)
            v.set!ITEM_FIELD_GIFTCREATOR(realmPlayerGuid(cast(uint)(owner >> 32), record.giftCreator));
        v.set!ITEM_FIELD_STACK_COUNT(record.count);
        // A duration the template no longer has, or newly has, follows the template.
        v.set!ITEM_FIELD_DURATION((proto.duration == 0) != (record.duration == 0) ? proto.duration : record.duration);
        foreach (i, n; parseNumbers(record.charges, 5))
            v.set!ITEM_FIELD_SPELL_CHARGES(i, n);
        v.set!ITEM_FIELD_FLAGS(record.flags);
        foreach (i, n; parseNumbers(record.enchantments, 21))
            v.set!ITEM_FIELD_ENCHANTMENT(i, n);
        v.set!ITEM_FIELD_RANDOM_PROPERTIES_ID(record.randomPropertyId);
        v.set!ITEM_FIELD_ITEM_TEXT_ID(record.textId);
        v.set!ITEM_FIELD_DURABILITY(min(record.durability, proto.maxDurability));
        item.state = ItemState.unchanged;
        return item;
    }

    /// The full guid.
    @property ulong fullGuid() const pure nothrow @nogc @safe
    {
        return makeGuid(HighGuid.item, guid);
    }

    ///
    @property uint entry() const pure nothrow @nogc @safe
    {
        return proto.entry;
    }

    /// The stack size.
    @property uint count() const
    {
        return values[ITEM_FIELD_STACK_COUNT];
    }

    /// ditto
    @property void count(uint value)
    {
        values.set!ITEM_FIELD_STACK_COUNT(value);
    }

    ///
    @property uint durability() const
    {
        return values[ITEM_FIELD_DURABILITY];
    }

    ///
    @property uint maxDurability() const
    {
        return values[ITEM_FIELD_MAXDURABILITY];
    }

    ///
    @property ulong owner() const
    {
        return values.get!ITEM_FIELD_OWNER;
    }

    /// A bag.
    @property bool isBag() const pure nothrow @safe
    {
        return contents.length > 0;
    }

    /// Whether the bag holds nothing.
    @property bool isEmpty() const
    {
        return !contents.canFind!(content => content !is null);
    }

    /// Bound to its owner.
    @property bool bound() const
    {
        return (values[ITEM_FIELD_FLAGS] & itemDynFlagBound) != 0;
    }

    /// Binds the item to its owner.
    void bind()
    {
        values.set!ITEM_FIELD_FLAGS(values[ITEM_FIELD_FLAGS] | itemDynFlagBound);
    }

    /// The slot of the bag it is in, or `inventorySlotBag0`.
    @property ubyte bagSlot() const pure nothrow @nogc @safe
    {
        return container is null ? inventorySlotBag0 : container.slot;
    }

    /// Its position.
    @property ushort pos() const pure nothrow @nogc @safe
    {
        return itemPos(bagSlot, slot);
    }

    /// Worn: in one of the owner's equipment slots.
    @property bool isEquipped() const pure nothrow @nogc @safe
    {
        return container is null && slot < equipmentSlotEnd;
    }

    /// Bound to someone else.
    bool isBoundNotWith(ulong player) const
    {
        return owner != player && bound;
    }

    /// Whether some of a stack of `other` fits onto this one.
    InventoryResult canBeMergedPartlyWith(const(ItemTemplate)* other) const
    {
        if (entry != other.entry || count >= other.stackable)
            return InventoryResult.itemCantStack;
        return InventoryResult.ok;
    }

    /// What a vendor pays for it, less the cost of repairing it, but at least 1 if it is worth anything.
    uint sellPrice(uint baseRepairCost) const
    {
        int price = proto.details.sellPrice;
        if (price == 0)
            return 0;
        // An item destroyed when its charges run out is worth its charges left.
        const baseCharges = proto.spellCharges[0];
        if (baseCharges < -1)
            price = cast(int) values[ITEM_FIELD_SPELL_CHARGES] * price / baseCharges;
        if (cast(int) baseRepairCost >= price)
            return 1;
        return price - baseRepairCost;
    }

    /// Puts `item` into the bag's slot `bagSlot`.
    void storeInBag(ubyte bagSlot, Item item)
    in (isBag && bagSlot < contents.length)
    {
        contents[bagSlot] = item;
        values.set!CONTAINER_FIELD_SLOT_1(bagSlot, item.fullGuid);
        item.values.set!ITEM_FIELD_CONTAINED(fullGuid);
        item.values.set!ITEM_FIELD_OWNER(owner);
        item.container = this;
        item.slot = bagSlot;
    }

    /// Empties the bag's slot `bagSlot`.
    void removeFromBag(ubyte bagSlot)
    in (isBag && bagSlot < contents.length)
    {
        if (auto item = contents[bagSlot])
            item.container = null;
        contents[bagSlot] = null;
        values.set!CONTAINER_FIELD_SLOT_1(bagSlot, 0UL);
    }

    /// Its row in the item table.
    ItemRecord record() const
    {
        import std.array : appender;

        ItemRecord r;
        r.bag = container is null ? 0 : container.guid;
        r.slot = slot;
        r.guid = guid;
        r.entry = entry;
        r.creator = cast(uint) values.get!ITEM_FIELD_CREATOR;
        r.giftCreator = cast(uint) values.get!ITEM_FIELD_GIFTCREATOR;
        r.count = count;
        r.duration = values[ITEM_FIELD_DURATION];
        auto charges = appender!string;
        foreach (i; 0 .. 5)
            charges ~= (cast(int) values.get!ITEM_FIELD_SPELL_CHARGES(i)).to!string ~ " ";
        r.charges = charges[];
        r.flags = values[ITEM_FIELD_FLAGS];
        auto enchantments = appender!string;
        foreach (i; 0 .. 21)
            enchantments ~= values.get!ITEM_FIELD_ENCHANTMENT(i).to!string ~ " ";
        r.enchantments = enchantments[];
        r.randomPropertyId = cast(int) values[ITEM_FIELD_RANDOM_PROPERTIES_ID];
        r.durability = durability;
        r.textId = values[ITEM_FIELD_ITEM_TEXT_ID];
        return r;
    }
}

/// `count` space-separated numbers from a text column; missing or malformed ones are 0.
int[] parseNumbers(string text, size_t count) pure @safe
out (numbers; numbers.length == count)
{
    import std.array : split;

    auto numbers = new int[count];
    foreach (i, token; text.split)
    {
        if (i == count)
            break;
        try
            numbers[i] = cast(int) token.to!long;
        catch (ConvException)
            numbers[i] = 0;
    }
    return numbers;
}

/// What repairing the item fully costs, before discounts.
uint baseRepairCost(const Item item, const ClientData client)
{
    if (item.values[ITEM_FIELD_FLAGS] & itemDynFlagWrapped)
        return 0;
    const maxDurability = item.maxDurability, current = item.durability;
    if (!maxDurability || current >= maxDurability)
        return 0;
    // Only weapons, and armor up to the last armor column, cost anything.
    const proto = item.proto;
    const isWeapon = proto.itemClass == ItemClass.weapon && proto.subClass <= 21;
    if (!isWeapon && !(proto.itemClass == ItemClass.armor && proto.subClass <= 7))
        return 0;
    const costs = client.durabilityCosts.lookup(proto.details.itemLevel);
    const quality = client.durabilityQualities.lookup((proto.details.quality + 1) * 2);
    if (costs is null || quality is null)
        return 0;
    // The durability cost column for the item's class and subclass.
    const multiplier = costs.multiplier[isWeapon ? proto.subClass : proto.subClass + 21];
    // This order of operations and this rounding (half away from zero, at least 1) decide the prices shown.
    const cost = double(maxDurability - current) * double(quality.qualityMod) * double(multiplier);
    const rounded = cast(uint)(cost + 0.5);
    return rounded ? rounded : 1;
}

/// The discounted repair price, rounded as a float to the nearest, ties to even.
uint repairCost(const Item item, const ClientData client, float discount)
{
    import std.math : lrint;

    return cast(uint) lrint(float(baseRepairCost(item, client)) * discount);
}

/// Where some of a stack goes.
struct ItemPosCount
{
    ushort pos;
    uint count;
}

/// An `SMSG_INVENTORY_CHANGE_FAILURE` to send. `ok` sends nothing.
struct EquipError
{
    InventoryResult result;
    const(Item) item;   /// the client stops what it does with it and unlocks it
    const(Item) other;  /// the client unlocks it
    ubyte bagSlot;      /// the bag whose kind refused the item
    uint itemId;        /// for `cantEquipLevel` when there is no item

    ///
    bool opCast(T : bool)() const
    {
        return result != InventoryResult.ok;
    }
}

/// What the inventory's rules ask about the character who owns it.
interface InventoryOwner
{
    /// The character's full guid.
    @property ulong ownerGuid() const;
    ///
    @property uint ownerLevel() const;
    ///
    @property ubyte ownerClass() const;
    ///
    @property ubyte ownerRace() const;
    /// A skill's value; 0 if the character does not have it.
    ushort skillRank(uint skill) const;
    /// The highest honor rank it reached (internal, 0 to 18), which items' `RequiredHonorRank` counts.
    @property ubyte highestHonorRank() const;
    /// Whether the character knows `spell`.
    bool hasSpell(uint spell) const;
    /// Its reputation rank with `faction` (Faction.dbc id; `ReputationRank`, hated 0 to exalted 7), which
    /// items' `RequiredReputationFaction`/`RequiredReputationRank` ask for.
    ubyte reputationRank(uint faction) const;
    /// Whether the character can wield a weapon in each hand.
    @property bool dualWields() const;
    ///
    @property bool alive() const;
    ///
    @property bool inCombat() const;
}

// ---------------------------------------------------------------------------
// The inventory
// ---------------------------------------------------------------------------

/// See the module documentation.
final class Inventory
{
    private
    {
        Item[playerSlots] slots;
        const WorldData world;
        InventoryOwner owner;
        UpdateValues* fields;      // the owner's: slot guids, visible items, buyback slots
        uint delegate() nextGuid;
        Item[] queue;              // items to save, in order
        Item[] toCreate;           // not yet sent to the client
        ulong[] toForget;          // sent, now gone
        ubyte currentBuybackSlot = buybackSlotStart;
    }

    /// Whether worn items changed, so the owner's stats must be worked out again.
    bool equipmentChanged;
    /// Items put on (`equip`) since the owner last looked: their on-use spells' equip cooldown starts.
    Item[] justEquipped;
    /// Items with a duration (`ITEM_FIELD_DURATION`) that came into the inventory since the owner last looked.
    Item[] newlyTimed;
    /// Whether an item with no room left may go by mail (`toMail`): a character in the world; not one being made.
    bool canMail;
    /// Items out of the inventory, their rows deleted, that the owner mails to itself once its changes are saved
    /// (the off hand with no room next to a two-hander): their rows as they were.
    ItemRecord[] toMail;

    /// `nextGuid` numbers new items; `fields` are the owner's.
    this(const WorldData world, InventoryOwner owner, UpdateValues* fields, uint delegate() nextGuid)
    in (world !is null && owner !is null && fields !is null && nextGuid !is null)
    {
        this.world = world;
        this.owner = owner;
        this.fields = fields;
        this.nextGuid = nextGuid;
    }

    // -----------------------------------------------------------------------
    // Looking things up
    // -----------------------------------------------------------------------

    /// The item at a position, or null.
    inout(Item) opIndex(ubyte bag, ubyte slot) inout
    {
        if (bag == inventorySlotBag0)
            return slot < bankBagSlotEnd || (slot >= keyringSlotStart && slot < keyringSlotEnd) ? slots[slot] : null;
        if ((bag >= inventorySlotBagStart && bag < inventorySlotBagEnd) || (bag >= bankBagSlotStart && bag < bankBagSlotEnd))
            if (auto container = slots[bag])
                return slot < container.contents.length ? container.contents[slot] : null;
        return null;
    }

    /// ditto
    inout(Item) opIndex(ushort pos) inout
    {
        return this[pos >> 8, pos & 0xFF];
    }

    /// The item worn in `slot`, or null.
    inout(Item) equipped(ubyte slot) inout
    in (slot < equipmentSlotEnd)
    {
        return slots[slot];
    }

    /// Every item the owner has: in its own slots (buyback ones too), then in each bag.
    inout(Item)[] all() inout
    {
        inout(Item)[] found;
        foreach (item; slots)
            if (item !is null)
                found ~= item;
        foreach (item; slots)
            if (item !is null)
                foreach (content; item.contents)
                    if (content !is null)
                        found ~= content;
        return found;
    }

    /// The item with `guid`: carried, worn or banked; not in the buyback slots.
    inout(Item) byGuid(ulong guid) inout
    {
        foreach (item; all())
            if (item.fullGuid == guid && !(item.container is null && item.slot >= buybackSlotStart
                && item.slot < buybackSlotEnd))
                return item;
        return null;
    }

    /// How many of `entry` there are: in the backpack, worn, in bags and the keyring; with the bank, if asked.
    uint count(uint entry, bool inBank = false, const Item skip = null) const
    {
        uint n;
        void add(const Item item)
        {
            if (item !is null && item !is skip && item.entry == entry)
                n += item.count;
        }

        void addBag(const Item bag)
        {
            if (bag !is null)
                foreach (content; bag.contents)
                    add(content);
        }

        foreach (ubyte i; 0 .. inventorySlotItemEnd)
            add(slots[i]);
        foreach (ubyte i; keyringSlotStart .. keyringSlotEnd)
            add(slots[i]);
        foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            addBag(slots[i]);
        if (inBank)
        {
            foreach (ubyte i; bankSlotItemStart .. bankBagSlotEnd)
                add(slots[i]);
            foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
                addBag(slots[i]);
        }
        return n;
    }

    /// Whether `count` of `entry` are worn, not counting `exceptSlot`.
    bool hasEquipped(uint entry, uint count, ubyte exceptSlot = nullSlot) const
    {
        uint n;
        foreach (ubyte i; 0 .. equipmentSlotEnd)
            if (i != exceptSlot)
                if (const item = slots[i])
                    if (item.entry == entry && (n += item.count) >= count)
                        return true;
        return false;
    }

    /// Whether a two-handed weapon is in the main hand.
    bool twoHandUsed() const
    {
        const main = slots[equipmentSlotMainhand];
        return main !is null && main.proto.inventoryType == InventoryType.twoHandWeapon;
    }

    /// Bank bag slots bought.
    @property ubyte bankBagSlots() const
    {
        return fields.getByte!PLAYER_BYTES_2(2);
    }

    /// ditto
    @property void bankBagSlots(ubyte count)
    {
        fields.setByte!PLAYER_BYTES_2(2, count);
    }

    /// Keyring slots the client shows at the owner's level.
    @property uint keyringSize() const
    {
        const level = owner.ownerLevel;
        return level <= 60 ? keyringSizeByLevel[level > 0 ? (level - 1) / 10 : 0] : keyringSlotEnd - keyringSlotStart;
    }

    /// Whether the position can exist; without `explicitPos`, "anywhere" may be meant.
    bool isValidPos(ubyte bag, ubyte slot, bool explicitPos) const
    {
        if (bag == nullBag && !explicitPos)
            return true;
        if (bag == inventorySlotBag0)
        {
            if (slot == nullSlot && !explicitPos)
                return true;
            return slot < equipmentSlotEnd || (slot >= inventorySlotBagStart && slot < inventorySlotBagEnd)
                || (slot >= inventorySlotItemStart && slot < inventorySlotItemEnd)
                || (slot >= keyringSlotStart && slot < keyringSlotEnd)
                || (slot >= bankSlotItemStart && slot < bankSlotItemEnd)
                || (slot >= bankBagSlotStart && slot < bankBagSlotEnd);
        }
        if ((bag >= inventorySlotBagStart && bag < inventorySlotBagEnd) || (bag >= bankBagSlotStart && bag < bankBagSlotEnd))
        {
            const container = slots[bag];
            if (container is null)
                return false;
            if (slot == nullSlot && !explicitPos)
                return true;
            return slot < container.contents.length;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Creating and loading
    // -----------------------------------------------------------------------

    /// A new item, its stack cut to what stacks; null for no count or no template.
    Item create(uint entry, uint count, uint randomProperty = 0)
    {
        import std.random : rndGen;
        import dmangos.world.enchantments : chooseRandomProperty;

        const proto = entry in world.items;
        if (proto is null || count < 1)
            return null;
        auto item = new Item(nextGuid(), proto, owner.ownerGuid);
        item.count = min(count, proto.stackable ? proto.stackable : 1);
        // A random property: the one it dropped with, else one chosen now.
        if (proto.randomProperty && randomProperty == 0)
            randomProperty = chooseRandomProperty(world.randomProperties.get(proto.randomProperty, null), rndGen);
        if (randomProperty)
            item.setRandomProperty(randomProperty, world);
        return item;
    }

    /**
     * Loads one saved row, character slots before bags: puts the saved item where it
     * was. Returns why it could not, or null.
     */
    string load(const ref ItemRecord record)
    {
        const proto = record.entry in world.items;
        if (proto is null)
            return "no such item template";
        Item bag;
        if (record.bag != 0)
        {
            foreach (ubyte i; 0 .. bankBagSlotEnd)
                if (slots[i] !is null && slots[i].guid == record.bag)
                    bag = slots[i];
            if (bag is null || !bag.isBag || !isBagPos(bag.pos))
                return "the bag is not equipped";
            if (record.slot >= bag.contents.length)
                return "the bag has no such slot";
            if (bag.contents[record.slot] !is null)
                return "the slot is taken";
        }
        else
        {
            if (record.slot >= playerSlots || (record.slot >= buybackSlotStart && record.slot < buybackSlotEnd))
                return "no such inventory slot";
            if (slots[record.slot] !is null)
                return "the slot is taken";
        }
        auto item = Item.load(record, proto, owner.ownerGuid);
        if (bag !is null)
            bag.storeInBag(record.slot, item);
        else
            place(record.slot, item);
        return null;
    }

    // -----------------------------------------------------------------------
    // Checks
    // -----------------------------------------------------------------------

    /// Whether the character may use items of `proto`: class, race, skill, spell, honor rank and level.
    InventoryResult canUse(const(ItemTemplate)* proto, bool directAction = true) const
    {
        if (proto is null)
            return InventoryResult.itemNotFound;
        if ((proto.allowableClass & (1u << (owner.ownerClass - 1))) == 0
            || (proto.allowableRace & (1u << (owner.ownerRace - 1))) == 0)
            return InventoryResult.youCanNeverUseThatItem;
        if (proto.requiredSkill != 0)
        {
            const rank = owner.skillRank(proto.requiredSkill);
            if (rank == 0)
                return InventoryResult.noRequiredProficiency;
            if (rank < proto.requiredSkillRank)
                return InventoryResult.cantEquipSkill;
        }
        if (proto.requiredSpell != 0 && !owner.hasSpell(proto.requiredSpell))
            return InventoryResult.noRequiredProficiency;
        if (directAction && owner.highestHonorRank < proto.requiredHonorRank)
            return InventoryResult.cantEquipRank;
        if (owner.ownerLevel < proto.requiredLevel)
            return InventoryResult.cantEquipLevel;
        return InventoryResult.ok;
    }

    /// Whether the character may use `item`: alive, owning it, the template's checks, its weapon or
    /// armor skill and reputation.
    InventoryResult canUse(const Item item, bool directAction = true) const
    {
        if (item is null)
            return InventoryResult.itemNotFound;
        if (!owner.alive && directAction)
            return InventoryResult.youAreDead;
        if (item.isBoundNotWith(owner.ownerGuid))
            return InventoryResult.dontOwnThatItem;
        if (const result = canUse(item.proto, directAction))
            return result;
        if (uint skill = itemSkill(item.proto))
        {
            if (item.proto.subClass == itemSubclassWeaponFist)
                skill = skillFistWeapons;
            if (!owner.skillRank(skill))
                return InventoryResult.noRequiredProficiency;
        }
        // CMaNGOS Player::CanUseItem(Item*): only here, not for a bare template (need-before-greed).
        if (item.proto.requiredReputationFaction
            && owner.reputationRank(item.proto.requiredReputationFaction) < item.proto.requiredReputationRank)
            return InventoryResult.cantEquipReputation;
        return InventoryResult.ok;
    }

    /// Whether the character may use the ammo `entry`.
    InventoryResult canUseAmmo(uint entry) const
    {
        if (!owner.alive)
            return InventoryResult.youAreDead;
        const proto = entry in world.items;
        if (proto is null)
            return InventoryResult.itemNotFound;
        if (proto.inventoryType != InventoryType.ammo)
            return InventoryResult.onlyAmmoCanGoHere;
        return canUse(proto);
    }

    /// Where an item may be worn; false if nowhere.
    bool viableEquipSlots(const(ItemTemplate)* proto, ref ubyte[4] viable) const
    {
        viable[] = nullSlot;
        if (canUse(proto) != InventoryResult.ok)
            return false;
        with (InventoryType) switch (proto.inventoryType)
        {
        case head: viable[0] = equipmentSlotHead; break;
        case neck: viable[0] = equipmentSlotNeck; break;
        case shoulders: viable[0] = equipmentSlotShoulders; break;
        case body: viable[0] = equipmentSlotBody; break;
        case chest, robe: viable[0] = equipmentSlotChest; break;
        case waist: viable[0] = equipmentSlotWaist; break;
        case legs: viable[0] = equipmentSlotLegs; break;
        case feet: viable[0] = equipmentSlotFeet; break;
        case wrists: viable[0] = equipmentSlotWrists; break;
        case hands: viable[0] = equipmentSlotHands; break;
        case finger: viable[0] = equipmentSlotFinger1; viable[1] = equipmentSlotFinger2; break;
        case trinket: viable[0] = equipmentSlotTrinket1; viable[1] = equipmentSlotTrinket2; break;
        case cloak: viable[0] = equipmentSlotBack; break;
        case weapon, twoHandWeapon:
            viable[0] = equipmentSlotMainhand;
            if (owner.dualWields)
                viable[1] = equipmentSlotOffhand;
            break;
        case shield, weaponOffhand, holdable: viable[0] = equipmentSlotOffhand; break;
        case ranged, thrown, rangedRight: viable[0] = equipmentSlotRanged; break;
        case tabard: viable[0] = equipmentSlotTabard; break;
        case weaponMainhand: viable[0] = equipmentSlotMainhand; break;
        case bag:
            foreach (ubyte i; 0 .. 4)
                viable[i] = cast(ubyte)(inventorySlotBagStart + i);
            break;
        case relic:
            const relicClass = proto.subClass == itemSubclassArmorLibram ? PlayerClass.paladin
                : proto.subClass == itemSubclassArmorIdol ? PlayerClass.druid
                : proto.subClass == itemSubclassArmorTotem ? PlayerClass.shaman
                : proto.subClass == itemSubclassArmorMisc ? PlayerClass.warlock : 0;
            if (relicClass && relicClass == owner.ownerClass)
                viable[0] = equipmentSlotRanged;
            break;
        default:
            break;
        }
        return viable[0] != nullSlot;
    }

    /// The slot to wear the item in: `slot` if viable (and free, unless swapping), else a free viable
    /// one, else with `swap` the first viable; `nullSlot` if none.
    ubyte findEquipSlot(const(ItemTemplate)* proto, ubyte slot, bool swap) const
    {
        ubyte[4] viable;
        if (!viableEquipSlots(proto, viable))
            return nullSlot;
        if (slot != nullSlot)
        {
            if (swap || slots[slot] is null)
                foreach (candidate; viable)
                    if (candidate == slot)
                        return slot;
            return nullSlot;
        }
        foreach (candidate; viable)
        {
            if (candidate == nullSlot || slots[candidate] !is null)
                continue;
            // Not free: a one-hander into the off hand while wielding a two-hander, or a two-hander there.
            if (candidate == equipmentSlotOffhand
                && (twoHandUsed() || proto.inventoryType == InventoryType.twoHandWeapon))
                continue;
            return candidate;
        }
        foreach (candidate; viable)
            if (candidate != nullSlot && swap)
                return candidate;
        return nullSlot;
    }

    /// The item's limit per character. `noSpace` gets what does not fit.
    InventoryResult canTakeMoreSimilar(uint entry, uint count, const Item skip, uint* noSpace = null) const
    {
        const proto = entry in world.items;
        if (proto is null)
        {
            if (noSpace)
                *noSpace = count;
            return InventoryResult.cantCarryMoreOfThis;
        }
        if (proto.maxCount > 0)
        {
            const current = this.count(entry, true, skip);
            if (current + count > cast(uint) proto.maxCount)
            {
                if (noSpace)
                    *noSpace = count + current - proto.maxCount;
                return InventoryResult.cantCarryMoreOfThis;
            }
        }
        return InventoryResult.ok;
    }

    /// Where `count` new items of `entry` would go.
    InventoryResult canStoreNew(ubyte bag, ubyte slot, ref ItemPosCount[] dest, uint entry, uint count,
        uint* noSpace = null) const
    {
        ubyte bagSlot;
        return canStore(bag, slot, dest, entry, count, null, false, bagSlot, noSpace);
    }

    /// Where the item would go, carried.
    InventoryResult canStore(ubyte bag, ubyte slot, ref ItemPosCount[] dest, const Item item, bool swap,
        ref ubyte bagSlot) const
    {
        if (item is null)
            return InventoryResult.itemNotFound;
        return canStore(bag, slot, dest, item.entry, item.count, item, swap, bagSlot, null);
    }

    /**
     * Where `count` of `entry` (the item `source`, if it exists) would go,
     * carried: in `bag` and `slot` if given, else onto stacks first, then special bags, then anywhere.
     */
    InventoryResult canStore(ubyte bag, ubyte slot, ref ItemPosCount[] dest, uint entry, uint count,
        const Item source, bool swap, ref ubyte bagSlot, uint* noSpace) const
    {
        const proto = entry in world.items;
        InventoryResult fail(InventoryResult result, uint left)
        {
            if (noSpace)
                *noSpace = left;
            return result;
        }

        if (proto is null)
            return fail(swap ? InventoryResult.itemsCantBeSwapped : InventoryResult.itemNotFound, count);
        if (source !is null && source.isBoundNotWith(owner.ownerGuid))
            return fail(InventoryResult.dontOwnThatItem, count);

        uint noSimilar;
        if (const result = canTakeMoreSimilar(entry, count, source, &noSimilar))
        {
            if (count == noSimilar)
                return fail(result, noSimilar);
            count -= noSimilar;
        }

        // After each step: everything placed is done, a step that failed fails it all.
        bool finished(InventoryResult result, out InventoryResult outcome)
        {
            if (result != InventoryResult.ok)
            {
                outcome = fail(result, count + noSimilar);
                return true;
            }
            if (count != 0)
                return false;
            outcome = noSimilar == 0 ? InventoryResult.ok
                : fail(InventoryResult.cantCarryMoreOfThis, count + noSimilar);
            return true;
        }

        InventoryResult outcome;
        // A bag step that cannot hold the item is skipped; only a full placement ends the search.
        bool filledBag(InventoryResult result, out InventoryResult done)
        {
            return result == InventoryResult.ok && count == 0 && finished(result, done);
        }

        const keyringEnd = cast(ubyte)(keyringSlotStart + keyringSize);

        if (bag != nullBag && slot != nullSlot)
            if (finished(storeInSpecificSlot(bag, slot, dest, proto, count, swap, source, bagSlot), outcome))
                return outcome;

        if (bag != nullBag)
        {
            if (proto.stackable > 1)
            {
                if (bag == inventorySlotBag0)
                {
                    if (finished(storeInSlots(keyringSlotStart, keyringSlotEnd, dest, proto, count, true, source,
                        bag, slot), outcome))
                        return outcome;
                    if (finished(storeInSlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, true,
                        source, bag, slot), outcome))
                        return outcome;
                }
                else
                {
                    auto result = storeInBag(bag, dest, proto, count, true, false, source, nullBag, slot, bagSlot);
                    if (result != InventoryResult.ok)
                        result = storeInBag(bag, dest, proto, count, true, true, source, nullBag, slot, bagSlot);
                    if (finished(result, outcome))
                        return outcome;
                }
            }
            if (bag == inventorySlotBag0)
            {
                if (proto.bagFamily == bagFamilyKeys)
                    if (finished(storeInSlots(keyringSlotStart, keyringEnd, dest, proto, count, false, source, bag,
                        slot), outcome))
                        return outcome;
                if (finished(storeInSlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, false,
                    source, bag, slot), outcome))
                    return outcome;
            }
            else
            {
                auto result = storeInBag(bag, dest, proto, count, false, false, source, nullBag, slot, bagSlot);
                if (result != InventoryResult.ok)
                    result = storeInBag(bag, dest, proto, count, false, true, source, nullBag, slot, bagSlot);
                if (finished(result, outcome))
                    return outcome;
            }
        }

        if (proto.stackable > 1)
        {
            if (finished(storeInSlots(keyringSlotStart, keyringSlotEnd, dest, proto, count, true, source, bag, slot),
                outcome))
                return outcome;
            if (finished(storeInSlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, true, source,
                bag, slot), outcome))
                return outcome;
            if (proto.bagFamily)
                foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                    if (filledBag(storeInBag(i, dest, proto, count, true, false, source, bag, slot, bagSlot), outcome))
                        return outcome;
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                if (filledBag(storeInBag(i, dest, proto, count, true, true, source, bag, slot, bagSlot), outcome))
                    return outcome;
        }

        if (proto.bagFamily)
        {
            if (proto.bagFamily == bagFamilyKeys)
                if (finished(storeInSlots(keyringSlotStart, keyringEnd, dest, proto, count, false, source, bag, slot),
                    outcome))
                    return outcome;
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                if (filledBag(storeInBag(i, dest, proto, count, false, false, source, bag, slot, bagSlot), outcome))
                    return outcome;
        }

        if (source !is null && source.isBag && !source.isEmpty)
            return InventoryResult.nonEmptyBagOverOtherBag;

        if (finished(storeInSlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, false, source,
            bag, slot), outcome))
            return outcome;
        foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            if (filledBag(storeInBag(i, dest, proto, count, false, true, source, bag, slot, bagSlot), outcome))
                return outcome;
        return fail(InventoryResult.inventoryFull, count + noSimilar);
    }

    /// Where the item would go in the bank.
    InventoryResult canBank(ubyte bag, ubyte slot, ref ItemPosCount[] dest, const Item item, bool swap,
        ref ubyte bagSlot, bool notLoading = true) const
    {
        if (item is null)
            return swap ? InventoryResult.itemsCantBeSwapped : InventoryResult.itemNotFound;
        uint count = item.count;
        const proto = item.proto;
        if (item.isBoundNotWith(owner.ownerGuid))
            return InventoryResult.dontOwnThatItem;
        if (const result = canTakeMoreSimilar(item.entry, item.count, item))
            return result;

        bool done(InventoryResult result, out InventoryResult outcome)
        {
            outcome = result;
            return result != InventoryResult.ok || count == 0;
        }

        bool filledBag(InventoryResult result)
        {
            return result == InventoryResult.ok && count == 0;
        }

        InventoryResult outcome;
        if (bag != nullBag && slot != nullSlot)
        {
            if (slot >= bankBagSlotStart && slot < bankBagSlotEnd)
            {
                if (!item.isBag)
                    return InventoryResult.itemDoesntGoToSlot;
                if (slot - bankBagSlotStart >= bankBagSlots)
                    return InventoryResult.mustPurchaseThatBagSlot;
                if (const result = canUse(item, notLoading))
                    return result;
            }
            if (done(storeInSpecificSlot(bag, slot, dest, proto, count, swap, item, bagSlot), outcome))
                return outcome;
        }

        if (bag != nullBag)
        {
            if (proto.inventoryType == InventoryType.bag && item.isBag && !item.isEmpty)
                return InventoryResult.nonEmptyBagOverOtherBag;
            if (proto.stackable > 1)
            {
                if (bag == inventorySlotBag0)
                {
                    if (done(storeInSlots(bankSlotItemStart, bankSlotItemEnd, dest, proto, count, true, item, bag,
                        slot), outcome))
                        return outcome;
                }
                else
                {
                    auto result = storeInBag(bag, dest, proto, count, true, false, item, nullBag, slot, bagSlot);
                    if (result != InventoryResult.ok)
                        result = storeInBag(bag, dest, proto, count, true, true, item, nullBag, slot, bagSlot);
                    if (done(result, outcome))
                        return outcome;
                }
            }
            if (bag == inventorySlotBag0)
            {
                if (done(storeInSlots(bankSlotItemStart, bankSlotItemEnd, dest, proto, count, false, item, bag, slot),
                    outcome))
                    return outcome;
            }
            else
            {
                auto result = storeInBag(bag, dest, proto, count, false, false, item, nullBag, slot, bagSlot);
                if (result != InventoryResult.ok)
                    result = storeInBag(bag, dest, proto, count, false, true, item, nullBag, slot, bagSlot);
                if (done(result, outcome))
                    return outcome;
            }
        }

        if (proto.stackable > 1)
        {
            if (done(storeInSlots(bankSlotItemStart, bankSlotItemEnd, dest, proto, count, true, item, bag, slot),
                outcome))
                return outcome;
            if (proto.bagFamily)
                foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
                    if (filledBag(storeInBag(i, dest, proto, count, true, false, item, bag, slot, bagSlot)))
                        return InventoryResult.ok;
            foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
                if (filledBag(storeInBag(i, dest, proto, count, true, true, item, bag, slot, bagSlot)))
                    return InventoryResult.ok;
        }

        if (proto.bagFamily)
            foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
                if (filledBag(storeInBag(i, dest, proto, count, false, false, item, bag, slot, bagSlot)))
                    return InventoryResult.ok;

        if (done(storeInSlots(bankSlotItemStart, bankSlotItemEnd, dest, proto, count, false, item, bag, slot),
            outcome))
            return outcome;
        foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
            if (filledBag(storeInBag(i, dest, proto, count, false, true, item, bag, slot, bagSlot)))
                return InventoryResult.ok;
        return InventoryResult.bankFull;
    }

    /// `canEquip` for a new item of `entry`, checked with a throw-away item (which takes a guid).
    InventoryResult canEquipNew(ubyte slot, out ushort dest, uint entry, bool swap)
    {
        auto probe = create(entry, 1);
        if (probe is null)
            return InventoryResult.itemNotFound;
        return canEquip(slot, dest, probe, swap);
    }

    /// Where the item would be worn. `directAction`: the player does it.
    InventoryResult canEquip(ubyte slot, out ushort dest, const Item item, bool swap, bool directAction = true) const
    {
        if (item is null)
            return swap ? InventoryResult.itemsCantBeSwapped : InventoryResult.itemNotFound;
        const proto = item.proto;
        if (item.isBoundNotWith(owner.ownerGuid))
            return InventoryResult.dontOwnThatItem;
        if (const result = canTakeMoreSimilar(item.entry, item.count, item))
            return result;
        if (directAction && !canChangeEquipStateInCombat(proto) && owner.inCombat)
            return InventoryResult.notInCombat;

        const eslot = findEquipSlot(proto, slot, swap);
        if (eslot == nullSlot)
            return InventoryResult.itemCantBeEquipped;
        if (const result = canUse(item, directAction))
            return result;
        if (!swap && slots[eslot] !is null)
            return InventoryResult.noEquipmentSlotAvailable;
        // A unique-equipped item may be worn once.
        if ((proto.flags & itemFlagUniqueEquippable) && hasEquipped(proto.entry, 1, swap ? eslot : nullSlot))
            return InventoryResult.itemCantBeEquipped;

        if (proto.itemClass == ItemClass.quiver)
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                if (const bag = slots[i])
                    if (bag !is item && bag.proto.itemClass == proto.itemClass && (!swap || bag.slot != eslot))
                        return bag.proto.subClass == itemSubclassAmmoPouch ? InventoryResult.canEquipOnlyOneAmmoPouch
                            : InventoryResult.canEquipOnlyOneQuiver;

        const type = proto.inventoryType;
        if (eslot == equipmentSlotOffhand)
        {
            if (type == InventoryType.weapon || type == InventoryType.weaponOffhand)
            {
                if (!owner.dualWields)
                    return InventoryResult.cantDualWield;
            }
            else if (type == InventoryType.twoHandWeapon)
                return InventoryResult.cantDualWield;
            if (twoHandUsed())
                return InventoryResult.cantEquipWithTwoHanded;
        }
        if (type == InventoryType.twoHandWeapon)
        {
            if (eslot != equipmentSlotMainhand)
                return InventoryResult.itemCantBeEquipped;
            if (const offhand = slots[equipmentSlotOffhand])
            {
                ItemPosCount[] offDest;
                ubyte bagSlot;
                if (!directAction
                    || canUnequip(itemPos(inventorySlotBag0, equipmentSlotOffhand), false) != InventoryResult.ok
                    || canStore(nullBag, nullSlot, offDest, offhand, false, bagSlot) != InventoryResult.ok)
                    return swap ? InventoryResult.itemsCantBeSwapped : InventoryResult.inventoryFull;
            }
        }
        dest = itemPos(inventorySlotBag0, eslot);
        return InventoryResult.ok;
    }

    /// Whether what is at `pos` (worn or a bag) may be taken off.
    InventoryResult canUnequip(ushort pos, bool swap) const
    {
        if (!isEquipmentPos(pos) && !isBagPos(pos))
            return InventoryResult.ok;
        const item = this[pos];
        if (item is null)
            return InventoryResult.ok;
        if (!canChangeEquipStateInCombat(item.proto) && owner.inCombat)
            return InventoryResult.notInCombat;
        if (!swap && item.isBag && !item.isEmpty)
            return InventoryResult.canOnlyDoWithEmptyBags;
        return InventoryResult.ok;
    }

    // -----------------------------------------------------------------------
    // Changes
    // -----------------------------------------------------------------------

    /// A new item, as many as `dest` holds, put there.
    Item storeNew(const(ItemPosCount)[] dest, uint entry, uint randomProperty = 0, ulong creator = 0)
    {
        uint count;
        foreach (position; dest)
            count += position.count;
        auto item = create(entry, count, randomProperty);
        if (item is null)
            return null;
        enum hearthstone = 6948;
        if (creator && item.proto.stackable <= 1 && item.proto.itemClass != ItemClass.consumable
            && item.proto.itemClass != ItemClass.quest && !(item.proto.flags & itemFlagNoCreator) && entry != hearthstone)
            item.values.set!ITEM_FIELD_CREATOR(creator);
        return store(dest, item);
    }

    /// Puts the item at `dest`, carried or banked: every position but the last gets a copy. Returns the last.
    Item store(const(ItemPosCount)[] dest, Item item)
    {
        if (item is null)
            return null;
        Item last = item;
        foreach (index, position; dest)
            last = storeAt(position.pos, item, position.count, index + 1 < dest.length);
        return last;
    }

    /// Wears a new item of `entry` at `pos`.
    Item equipNew(ushort pos, uint entry)
    {
        auto item = create(entry, 1);
        return item is null ? null : equip(pos, item);
    }

    /// Wears `item` at `pos`, binding it if it binds.
    Item equip(ushort pos, Item item)
    {
        justEquipped ~= item;
        visualize(pos & 0xFF, item);
        if (owner.alive)
            equipmentChanged = true; // its stats change the owner's
        created(item);
        return item;
    }

    /// Takes the item out of its place, to be put somewhere else.
    void remove(ubyte bag, ubyte slot)
    {
        auto item = this[bag, slot];
        if (item is null)
            return;
        if (bag == inventorySlotBag0)
        {
            if (slot < inventorySlotBagEnd)
                equipmentChanged = true;
            slots[slot] = null;
            fields.set!PLAYER_FIELD_INV_SLOT_HEAD(slot, 0UL);
            if (slot < equipmentSlotEnd)
                setVisibleItem(slot, null);
        }
        else if (auto container = slots[bag])
            container.removeFromBag(slot);
        item.values.set!ITEM_FIELD_CONTAINED(0UL);
        item.slot = nullSlot;
    }

    /// Removes the item for good, and what is in it.
    void destroy(ubyte bag, ubyte slot)
    {
        auto item = this[bag, slot];
        if (item is null)
            return;
        if (item.isBag && item.isEquipped) // an equipped bag's slot is past the equipment slots
            foreach (ubyte i; 0 .. cast(ubyte) item.contents.length)
                destroy(slot, i);
        if (bag == inventorySlotBag0)
        {
            fields.set!PLAYER_FIELD_INV_SLOT_HEAD(slot, 0UL);
            if (slot < inventorySlotBagEnd)
                equipmentChanged = true;
            if (slot < equipmentSlotEnd)
                setVisibleItem(slot, null);
            slots[slot] = null;
        }
        else if (auto container = slots[bag])
            container.removeFromBag(slot);
        forget(item);
        item.values.set!ITEM_FIELD_CONTAINED(0UL);
        item.slot = nullSlot;
        setState(item, ItemState.removed);
    }

    /// Takes up to `count` off the stack.
    void destroyCount(Item item, ref uint count)
    {
        if (item.count <= count)
        {
            count -= item.count;
            destroy(item.bagSlot, item.slot);
        }
        else
        {
            item.count = item.count - count;
            count = 0;
            setState(item, ItemState.changed);
        }
    }

    /// Destroys `count` of `entry`, the backpack first. Returns what is left.
    uint destroyCount(uint entry, uint count, bool unequipCheck = false, bool inBank = false)
    {
        bool take(Item item)
        {
            if (item is null || item.entry != entry)
                return false;
            destroyCount(item, count);
            return count == 0;
        }

        foreach (ubyte i; inventorySlotItemStart .. inventorySlotItemEnd)
            if (take(slots[i]))
                return 0;
        foreach (ubyte i; keyringSlotStart .. keyringSlotEnd)
            if (take(slots[i]))
                return 0;
        foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            if (auto bag = slots[i])
                foreach (content; bag.contents)
                    if (take(content))
                        return 0;
        foreach (ubyte i; 0 .. inventorySlotBagEnd)
            if (auto item = slots[i])
                if (item.entry == entry && (!unequipCheck || item.count > count
                    || canUnequip(itemPos(inventorySlotBag0, i), false) == InventoryResult.ok))
                    if (take(item))
                        return 0;
        if (inBank)
        {
            foreach (ubyte i; bankSlotItemStart .. bankSlotItemEnd)
                if (take(slots[i]))
                    return 0;
            foreach (ubyte i; bankBagSlotStart .. bankBagSlotEnd)
                if (auto bag = slots[i])
                    foreach (content; bag.contents)
                        if (take(content))
                            return 0;
        }
        return count;
    }

    /// Moves `count` off the stack at `src` to `dst`.
    EquipError split(ushort src, ushort dst, uint count)
    {
        const srcBag = cast(ubyte)(src >> 8), srcSlot = cast(ubyte) src;
        const dstBag = cast(ubyte)(dst >> 8), dstSlot = cast(ubyte) dst;
        auto source = this[srcBag, srcSlot];
        if (source is null)
            return EquipError(InventoryResult.itemNotFound);
        if (source.count == count)
            return EquipError(InventoryResult.couldntSplitItems, source);
        if (source.count < count)
            return EquipError(InventoryResult.triedToSplitMoreThanCount, source);
        auto copy = cloneOf(source, count);
        if (copy is null)
            return EquipError(InventoryResult.itemNotFound, source);
        if (!isInventoryPos(dst) && !isBankPos(dst) && !isEquipmentPos(dst))
            return EquipError.init;

        source.count = source.count - count;
        ubyte bagSlot;
        if (isInventoryPos(dst) || isBankPos(dst))
        {
            ItemPosCount[] dest;
            const result = isInventoryPos(dst) ? canStore(dstBag, dstSlot, dest, copy, false, bagSlot)
                : canBank(dstBag, dstSlot, dest, copy, false, bagSlot);
            if (result != InventoryResult.ok)
            {
                source.count = source.count + count;
                return EquipError(result, source, null, bagSlot);
            }
            setState(source, ItemState.changed);
            store(dest, copy);
        }
        else if (isEquipmentPos(dst))
        {
            ushort dest;
            if (const result = canEquip(dstSlot, dest, copy, false))
            {
                source.count = source.count + count;
                return EquipError(result, source);
            }
            setState(source, ItemState.changed);
            equip(dest, copy);
            autoUnequipOffhand();
        }
        return EquipError.init;
    }

    /// Moves the item at `src` to `dst`, onto a stack there or trading places with it.
    EquipError swap(ushort src, ushort dst)
    {
        const srcBag = cast(ubyte)(src >> 8), srcSlot = cast(ubyte) src;
        const dstBag = cast(ubyte)(dst >> 8), dstSlot = cast(ubyte) dst;
        auto source = this[srcBag, srcSlot];
        auto target = this[dstBag, dstSlot];
        if (source is null)
            return EquipError.init;
        if (!owner.alive)
            return EquipError(InventoryResult.youAreDead, source, target);

        if (isEquipmentPos(src) || isBagPos(src))
            if (const result = canUnequip(src, !isBagPos(src) || isBagPos(dst)
                || (target !is null && target.isBag && target.isEmpty)))
                return EquipError(result, source, target);
        // A bag into itself, or a bag's own slot into it.
        if (isBagPos(src) && srcSlot == dstBag)
            return EquipError(InventoryResult.nonEmptyBagOverOtherBag, source, target);
        if (isBagPos(dst) && dstSlot == srcBag)
            return EquipError(InventoryResult.nonEmptyBagOverOtherBag, target, source);
        if (target !is null && (isEquipmentPos(dst) || isBagPos(dst)))
            if (const result = canUnequip(dst, !isBagPos(dst) || isBagPos(src) || (source.isBag && source.isEmpty)))
                return EquipError(result, source, target);

        ubyte bagSlot;
        if (target is null)
        {
            if (isInventoryPos(dst) || isBankPos(dst))
            {
                ItemPosCount[] dest;
                const result = isInventoryPos(dst) ? canStore(dstBag, dstSlot, dest, source, false, bagSlot)
                    : canBank(dstBag, dstSlot, dest, source, false, bagSlot);
                if (result != InventoryResult.ok)
                    return EquipError(result, source, null, bagSlot);
                remove(srcBag, srcSlot);
                store(dest, source);
            }
            else if (isEquipmentPos(dst))
            {
                ushort dest;
                if (const result = canEquip(dstSlot, dest, source, false))
                    return EquipError(result, source);
                remove(srcBag, srcSlot);
                equip(dest, source);
                autoUnequipOffhand();
            }
            return EquipError.init;
        }

        // Onto a stack of the same item.
        if (!source.isBag && !target.isBag)
        {
            const proto = source.proto;
            InventoryResult result;
            ItemPosCount[] dest;
            const overflows = source.count + target.count > proto.stackable;
            if (isEquipmentPos(dst) || ((isInventoryPos(dst) || isBankPos(dst)) && overflows))
            {
                result = source.isBoundNotWith(owner.ownerGuid) ? InventoryResult.dontOwnThatItem
                    : target.canBeMergedPartlyWith(proto);
                if (isEquipmentPos(dst))
                    dest ~= ItemPosCount(dst, source.count);
            }
            else if (isInventoryPos(dst))
                result = canStore(dstBag, dstSlot, dest, source, false, bagSlot);
            else if (isBankPos(dst))
                result = canBank(dstBag, dstSlot, dest, source, false, bagSlot);
            else
                return EquipError.init;

            if (result == InventoryResult.ok)
            {
                if (!overflows)
                {
                    remove(srcBag, srcSlot);
                    store(dest, source);
                }
                else
                {
                    source.count = source.count + target.count - proto.stackable;
                    target.count = proto.stackable;
                    setState(source, ItemState.changed);
                    setState(target, ItemState.changed);
                }
                return EquipError.init;
            }
        }

        // Trading places: each must fit where the other was.
        InventoryResult result = InventoryResult.cantDoRightNow;
        ItemPosCount[] sourceDest;
        ushort sourceEquip;
        if (isInventoryPos(dst))
            result = canStore(dstBag, dstSlot, sourceDest, source, true, bagSlot);
        else if (isBankPos(dst))
            result = canBank(dstBag, dstSlot, sourceDest, source, true, bagSlot);
        else if (isEquipmentPos(dst))
        {
            result = canEquip(dstSlot, sourceEquip, source, true);
            if (result == InventoryResult.ok)
                result = canUnequip(sourceEquip, true);
        }
        if (result != InventoryResult.ok)
            return EquipError(result, source, target, bagSlot);

        ItemPosCount[] targetDest;
        ushort targetEquip;
        ubyte bagSlot2;
        if (isInventoryPos(src))
            result = canStore(srcBag, srcSlot, targetDest, target, true, bagSlot2);
        else if (isBankPos(src))
            result = canBank(srcBag, srcSlot, targetDest, target, true, bagSlot2);
        else if (isEquipmentPos(src))
        {
            result = canEquip(srcSlot, targetEquip, target, true);
            if (result == InventoryResult.ok)
                result = canUnequip(targetEquip, true);
        }
        if (result != InventoryResult.ok)
            return EquipError(result, target, source, bagSlot2);

        // Two bags: what the full one holds moves into the empty one, when that is not worn.
        if (source.isBag && target.isBag)
        {
            Item emptyBag, fullBag;
            if (source.isEmpty && !isBagPos(src))
            {
                emptyBag = source;
                fullBag = target;
            }
            else if (target.isEmpty && !isBagPos(dst))
            {
                emptyBag = target;
                fullBag = source;
            }
            if (emptyBag !is null)
            {
                uint carried;
                foreach (content; fullBag.contents)
                {
                    if (content is null)
                        continue;
                    if (!itemCanGoIntoBag(content.proto, emptyBag.proto))
                        return EquipError(InventoryResult.nonEmptyBagOverOtherBag, source, target);
                    ++carried;
                }
                if (carried > emptyBag.contents.length)
                    return EquipError(InventoryResult.itemsCantBeSwapped, source, target);
                ubyte next;
                foreach (i, content; fullBag.contents)
                {
                    if (content is null)
                        continue;
                    fullBag.removeFromBag(cast(ubyte) i);
                    emptyBag.storeInBag(next++, content);
                    setState(content, ItemState.changed);
                }
            }
        }

        remove(dstBag, dstSlot);
        remove(srcBag, srcSlot);
        if (isInventoryPos(dst) || isBankPos(dst))
            store(sourceDest, source);
        else if (isEquipmentPos(dst))
            equip(sourceEquip, source);
        if (isInventoryPos(src) || isBankPos(src))
            store(targetDest, target);
        else if (isEquipmentPos(src))
            equip(targetEquip, target);
        autoUnequipOffhand();
        return EquipError.init;
    }

    /**
     * With a two-hander in the main hand, the off hand goes into `bag`, or anywhere carried. With no room it is
     * mailed to the owner (`toMail`, `AutoUnequipOffhandIfNeed`); where there is no mail (`canMail` off: a character
     * being made) it stays worn.
     */
    void autoUnequipOffhand(ubyte bag = nullBag)
    {
        auto offhand = slots[equipmentSlotOffhand];
        if (offhand is null || !twoHandUsed())
            return;
        ItemPosCount[] dest;
        ubyte bagSlot;
        if (canStore(bag, nullSlot, dest, offhand, false, bagSlot) == InventoryResult.ok)
        {
            remove(inventorySlotBag0, equipmentSlotOffhand);
            store(dest, offhand);
        }
        else if (canMail)
        {
            auto record = offhand.record;
            record.bag = 0;
            record.slot = 0;
            destroy(inventorySlotBag0, equipmentSlotOffhand);
            toMail ~= record;
        }
        else
            warning!"no room for off-hand item %s of %s next to a two-handed weapon; it stays worn"(
                offhand.entry, owner.ownerGuid);
    }

    /// A new stack of `count` with the source's creator, flags and duration.
    Item cloneOf(const Item source, uint count)
    {
        auto copy = create(source.entry, count);
        if (copy is null)
            return null;
        copy.values.set!ITEM_FIELD_CREATOR(source.values.get!ITEM_FIELD_CREATOR);
        copy.values.set!ITEM_FIELD_GIFTCREATOR(source.values.get!ITEM_FIELD_GIFTCREATOR);
        copy.values.set!ITEM_FIELD_FLAGS(source.values[ITEM_FIELD_FLAGS]);
        copy.values.set!ITEM_FIELD_DURATION(source.values[ITEM_FIELD_DURATION]);
        return copy;
    }

    /// Sets the save state of an item of this inventory and queues it for the next save.
    void setState(Item item, ItemState state)
    {
        if (item.state == ItemState.new_ && state == ItemState.removed)
        {
            // Never saved: as if it never existed.
            unqueue(item);
            return;
        }
        if (state == ItemState.unchanged)
            return;
        if (item.state != ItemState.new_)
            item.state = state;
        if (!item.queued)
        {
            item.queued = true;
            queue ~= item;
        }
    }

    // -----------------------------------------------------------------------
    // Buyback
    // -----------------------------------------------------------------------

    /// A sold item, which can be bought back for `money` until it is pushed out.
    void addToBuyback(Item item, uint money, uint secondsOnline)
    {
        ubyte slot = currentBuybackSlot;
        if (slots[slot] !is null)
        {
            // Stop at the first free slot; the slot taken is the oldest seen before it, not the free one.
            uint oldestTime = fields.get!PLAYER_FIELD_BUYBACK_TIMESTAMP_1(0);
            ubyte oldestSlot = buybackSlotStart;
            foreach (ubyte i; buybackSlotStart + 1 .. buybackSlotEnd)
            {
                if (slots[i] is null)
                    break;
                const time = fields.get!PLAYER_FIELD_BUYBACK_TIMESTAMP_1(i - buybackSlotStart);
                if (oldestTime > time)
                {
                    oldestTime = time;
                    oldestSlot = i;
                }
            }
            slot = oldestSlot;
        }
        removeFromBuyback(slot, true);
        slots[slot] = item;
        unqueue(item);
        item.slot = slot;
        item.container = null;
        created(item);
        const index = slot - buybackSlotStart;
        fields.set!PLAYER_FIELD_VENDORBUYBACK_SLOT_1(index, item.fullGuid);
        fields.set!PLAYER_FIELD_BUYBACK_PRICE_1(index, money);
        fields.set!PLAYER_FIELD_BUYBACK_TIMESTAMP_1(index, secondsOnline + 30 * 3600);
        if (currentBuybackSlot < buybackSlotEnd - 1)
            ++currentBuybackSlot;
    }

    /// The item in buyback slot `slot`, or null.
    inout(Item) buyback(uint slot) inout
    {
        return slot >= buybackSlotStart && slot < buybackSlotEnd ? slots[slot] : null;
    }

    /// The price of buying back the item in `slot`.
    uint buybackPrice(uint slot) const
    in (slot >= buybackSlotStart && slot < buybackSlotEnd)
    {
        return fields.get!PLAYER_FIELD_BUYBACK_PRICE_1(slot - buybackSlotStart);
    }

    /// Empties the slot; `destroy` deletes the item, else it is bought back.
    void removeFromBuyback(uint slot, bool destroy)
    {
        if (slot < buybackSlotStart || slot >= buybackSlotEnd)
            return;
        if (auto item = slots[slot])
        {
            if (destroy)
            {
                forget(item);
                setState(item, ItemState.removed);
            }
            item.slot = nullSlot;
        }
        slots[slot] = null;
        const index = slot - buybackSlotStart;
        fields.set!PLAYER_FIELD_VENDORBUYBACK_SLOT_1(index, 0UL);
        fields.set!PLAYER_FIELD_BUYBACK_PRICE_1(index, 0u);
        fields.set!PLAYER_FIELD_BUYBACK_TIMESTAMP_1(index, 0u);
        if (slots[currentBuybackSlot] !is null)
            currentBuybackSlot = cast(ubyte) slot;
    }

    // -----------------------------------------------------------------------
    // Telling the client and the database
    // -----------------------------------------------------------------------

    /**
     * Adds what the client should learn about the items to `update`: new items, then changed fields.
     * Returns whether anything was added. The items gone are `writeForgotten`'s.
     */
    bool writeUpdates(ref UpdateData update)
    {
        import dmangos.world.objects : MovementBlock, UpdateFlags;
        import dmangos.world.objects : seenByOwner, seenBySelf, UpdateType;

        const before = update.blockCount;
        MovementBlock movement;
        movement.flags = UpdateFlags.all;
        foreach (item; toCreate)
        {
            update.addCreate(UpdateType.createObject, item.fullGuid, movement, item.values, seenBySelf | seenByOwner);
            item.values.clearChanges();
            item.sent = true;
        }
        toCreate = null;
        foreach (item; all())
            if (item.values.hasChangesFor(seenBySelf | seenByOwner))
            {
                update.addValues(item.fullGuid, item.values, seenBySelf | seenByOwner);
                item.values.clearChanges();
            }
        return update.blockCount != before;
    }

    /**
     * Adds the items the client should forget to `update`, as one out-of-range block. It goes after
     * the owner's changed fields, which stop pointing at them. Returns whether there were any.
     */
    bool writeForgotten(ref UpdateData update)
    {
        if (toForget.length == 0)
            return false;
        update.addOutOfRange(toForget);
        toForget = null;
        return true;
    }

    /// The client was sent every item's create block (logging in): nothing is left to tell it.
    void markAllSent()
    {
        toCreate = null;
        toForget = null;
        foreach (item; all())
        {
            item.values.clearChanges();
            item.sent = true;
        }
    }

    /// Whether items changed since the last `takeChanges`.
    @property bool hasChanges() const pure nothrow @nogc @safe
    {
        return queue.length != 0;
    }

    /**
     * The rows to write, in order, and every item marked saved. Items in the
     * buyback slots are not kept: their rows are deleted, to be written again if they are bought back.
     * Returns null, with nothing marked, if an item is not where it says it is.
     */
    ItemChange[] takeChanges()
    {
        foreach (item; queue)
            if (item.state != ItemState.removed && this[item.bagSlot, item.slot] !is item)
            {
                error!"inventory of %s: item %s is not at bag %s slot %s; not saved"(owner.ownerGuid, item.guid,
                    item.bagSlot, item.slot);
                return null;
            }
        ItemChange[] changes;
        foreach (ubyte i; buybackSlotStart .. buybackSlotEnd)
            if (auto item = slots[i])
                if (item.state != ItemState.new_)
                {
                    changes ~= ItemChange(ItemState.removed, item.record);
                    item.state = ItemState.new_;
                }
        foreach (item; queue)
        {
            changes ~= ItemChange(item.state, item.record);
            item.state = ItemState.unchanged;
            item.queued = false;
        }
        queue = null;
        return changes;
    }

private:
    /// Puts `count` of the item at `pos`, as a copy if `clone`, onto a stack if one is there.
    Item storeAt(ushort pos, Item item, uint count, bool clone)
    {
        const bag = cast(ubyte)(pos >> 8), slot = cast(ubyte) pos;
        auto existing = this[bag, slot];
        if (existing is null)
        {
            if (clone)
                item = cloneOf(item, count);
            else
                item.count = count;
            if (item is null)
                return null;
            if (bindsWhenStored(item.proto, pos))
                item.bind();
            if (bag == inventorySlotBag0)
                place(slot, item);
            else if (auto container = slots[bag])
            {
                container.storeInBag(slot, item);
                setState(container, ItemState.changed);
            }
            created(item);
            setState(item, ItemState.changed);
            return item;
        }
        if (bindsWhenStored(existing.proto, pos))
            existing.bind();
        existing.count = existing.count + count;
        if (!clone)
        {
            forget(item);
            item.values.set!ITEM_FIELD_OWNER(owner.ownerGuid);
            setState(item, ItemState.removed);
        }
        setState(existing, ItemState.changed);
        return existing;
    }

    /// Bound when picked up, a quest item, or a bind-on-equip bag put in a bag slot.
    package static bool bindsWhenStored(const(ItemTemplate)* proto, ushort pos)
    {
        return proto.bonding == bindWhenPickedUp || proto.bonding == bindQuestItem
            || (proto.bonding == bindWhenEquipped && isBagPos(pos));
    }

    /// The owner's slot `slot` holds the item (the bag-0 half of `storeAt` and `visualize`).
    void place(ubyte slot, Item item)
    {
        slots[slot] = item;
        fields.set!PLAYER_FIELD_INV_SLOT_HEAD(slot, item.fullGuid);
        item.values.set!ITEM_FIELD_CONTAINED(owner.ownerGuid);
        item.values.set!ITEM_FIELD_OWNER(owner.ownerGuid);
        item.slot = slot;
        item.container = null;
        if (slot < equipmentSlotEnd)
        {
            setVisibleItem(slot, item);
            equipmentChanged = true;
        }
    }

    /// Wears the item in `slot`: binds it if it binds on equip or pickup, and queues it for saving.
    void visualize(ubyte slot, Item item)
    {
        const bonding = item.proto.bonding;
        if (bonding == bindWhenEquipped || bonding == bindWhenPickedUp || bonding == bindQuestItem)
            item.bind();
        place(slot, item);
        setState(item, ItemState.changed);
    }

    /// What others see worn in `slot`.
    void setVisibleItem(ubyte slot, const Item item)
    {
        // Each equipment slot has a block of `visibleItemStride` fields: the creator's guid, the entry and
        // seven enchantments, the random property.
        const block = slot * visibleItemStride;
        fields.set!PLAYER_VISIBLE_ITEM_1_CREATOR(block / 2, item is null ? 0UL : item.values.get!ITEM_FIELD_CREATOR);
        fields.set!PLAYER_VISIBLE_ITEM_1_0(block, item is null ? 0u : item.entry);
        foreach (i; 0 .. visibleEnchantments)
            fields.set!PLAYER_VISIBLE_ITEM_1_0(block + 1 + i,
                item is null ? 0u : item.values.get!ITEM_FIELD_ENCHANTMENT(3 * i));
        fields.set!PLAYER_VISIBLE_ITEM_1_PROPERTIES(block,
            item is null ? 0u : item.values[ITEM_FIELD_RANDOM_PROPERTIES_ID]);
    }

    /// The item was put somewhere: if the client has not seen it, it will.
    void created(Item item)
    {
        if (!item.sent && !toCreate.canFind!(other => other is item))
            toCreate ~= item;
        if (item.values[ITEM_FIELD_DURATION])
            newlyTimed ~= item;
    }

    /// The item is gone: the client forgets it if it was told about it.
    void forget(Item item)
    {
        const pending = toCreate.countUntil!(other => other is item);
        if (pending >= 0)
            toCreate = toCreate.remove(pending);
        if (item.sent)
            toForget ~= item.fullGuid;
        item.sent = false;
    }

    void unqueue(Item item)
    {
        if (!item.queued)
            return;
        const index = queue.countUntil!(other => other is item);
        if (index >= 0)
            queue = queue.remove(index);
        item.queued = false;
    }

    /// Where `count` of the item would go at one given position, bag 0 or in a bag.
    InventoryResult storeInSpecificSlot(ubyte bag, ubyte slot, ref ItemPosCount[] dest, const(ItemTemplate)* proto,
        ref uint count, bool swap, const Item source, ref ubyte bagSlot) const
    {
        const(Item) other = this[bag, slot] is source ? null : this[bag, slot];
        uint needSpace;
        if (other is null || swap)
        {
            if (bag == inventorySlotBag0)
            {
                if (slot >= keyringSlotStart && slot < keyringSlotStart + keyringSize && proto.bagFamily != bagFamilyKeys)
                {
                    bagSlot = bag;
                    return InventoryResult.itemDoesntGoIntoBag2;
                }
                if ((slot >= buybackSlotStart && slot < buybackSlotEnd) || slot >= playerSlots)
                {
                    bagSlot = bag;
                    return InventoryResult.itemDoesntGoIntoBag2;
                }
            }
            else
            {
                const container = slots[bag];
                if (container is null || !container.isBag || slot >= container.contents.length)
                {
                    bagSlot = bag;
                    return InventoryResult.intBagError;
                }
                if (!itemCanGoIntoBag(proto, container.proto))
                {
                    bagSlot = bag;
                    return InventoryResult.itemDoesntGoIntoBag2;
                }
            }
            needSpace = proto.stackable;
        }
        else
        {
            if (const result = other.canBeMergedPartlyWith(proto))
                return result;
            needSpace = proto.stackable - other.count;
        }
        addPosition(dest, itemPos(bag, slot), min(needSpace, count), count);
        return InventoryResult.ok;
    }

    /// Onto stacks (`merge`) or into free slots of an equipped bag.
    InventoryResult storeInBag(ubyte bag, ref ItemPosCount[] dest, const(ItemTemplate)* proto, ref uint count,
        bool merge, bool nonSpecialized, const Item source, ubyte skipBag, ubyte skipSlot, ref ubyte bagSlot) const
    {
        if (bag == skipBag)
        {
            bagSlot = bag;
            return InventoryResult.itemDoesntGoIntoBag2;
        }
        const container = slots[bag];
        if (container is null || container is source || !container.isBag)
        {
            bagSlot = bag;
            return InventoryResult.intBagError;
        }
        const bagProto = container.proto;
        if (nonSpecialized != (bagProto.itemClass == ItemClass.container && bagProto.subClass == itemSubclassContainer)
            || !itemCanGoIntoBag(proto, bagProto))
        {
            bagSlot = bag;
            return InventoryResult.itemDoesntGoIntoBag2;
        }
        foreach (ubyte j; 0 .. cast(ubyte) container.contents.length)
        {
            if (j == skipSlot)
                continue;
            if (fillSlot(container.contents[j], itemPos(bag, j), dest, proto, count, merge, source))
                return InventoryResult.ok;
        }
        return InventoryResult.ok;
    }

    /// Onto stacks (`merge`) or into free slots among the owner's slots `begin` to `end`.
    InventoryResult storeInSlots(ubyte begin, ubyte end, ref ItemPosCount[] dest, const(ItemTemplate)* proto,
        ref uint count, bool merge, const Item source, ubyte skipBag, ubyte skipSlot) const
    {
        foreach (ubyte j; begin .. end)
        {
            if (skipBag == inventorySlotBag0 && j == skipSlot)
                continue;
            if (fillSlot(slots[j], itemPos(inventorySlotBag0, j), dest, proto, count, merge, source))
                break;
        }
        return InventoryResult.ok;
    }

    /// One slot of the two searches above; true once everything is placed.
    static bool fillSlot(const Item occupant, ushort pos, ref ItemPosCount[] dest, const(ItemTemplate)* proto,
        ref uint count, bool merge, const Item source)
    {
        const other = occupant is source ? null : occupant;
        if ((other !is null) != merge)
            return false;
        uint needSpace = proto.stackable;
        if (other !is null)
        {
            if (other.canBeMergedPartlyWith(proto) != InventoryResult.ok)
                return false;
            needSpace -= other.count;
        }
        return addPosition(dest, pos, min(needSpace, count), count) && count == 0;
    }

    /// Adds a destination unless it is already one; takes `amount` off `count`.
    static bool addPosition(ref ItemPosCount[] dest, ushort pos, uint amount, ref uint count)
    {
        if (dest.canFind!(position => position.pos == pos))
            return false;
        dest ~= ItemPosCount(pos, amount);
        count -= amount;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testdata;

    /// A warrior who knows swords, staves and bows.
    private final class TestOwner : InventoryOwner
    {
        bool dualWield;
        uint level = 10;

        @property ulong ownerGuid() const { return makeGuid(HighGuid.player, 7); }
        @property uint ownerLevel() const { return level; }
        @property ubyte highestHonorRank() const { return 0; }
        @property ubyte ownerClass() const { return classWarrior; }
        @property ubyte ownerRace() const { return raceHuman; }
        ushort skillRank(uint skill) const
        {
            return skill == skillSwords || skill == skillStaves || skill == skillBows ? 1 : 0;
        }
        bool hasSpell(uint spell) const { return false; }
        ubyte reputationRank(uint faction) const { return faction == 59 ? 5 : 3; } // honored with Thorium Brotherhood
        @property bool dualWields() const { return dualWield; }
        @property bool alive() const { return true; }
        @property bool inCombat() const { return false; }
    }

    private Inventory testInventory(WorldData world, out UpdateValues* fields)
    {
        fields = new UpdateValues(TypeId.player);
        return new Inventory(world, new TestOwner, fields, testItemGuids());
    }
}

/// The keyring: 4 slots to level 40, 8 to 50, 12 to 60 (Blizzard's 1.11 announcement; it gave 8 at 40, 12 at 50).
unittest
{
    auto world = testWorldData(testClientData());
    auto owner = new TestOwner;
    auto inventory = new Inventory(world, owner, new UpdateValues(TypeId.player), testItemGuids());
    uint at(uint level)
    {
        owner.level = level;
        return inventory.keyringSize;
    }
    assert(at(1) == 4 && at(40) == 4 && at(41) == 8 && at(50) == 8 && at(51) == 12 && at(60) == 12);
}

/// Storing: onto stacks first, then free backpack slots; special bags take what belongs in them.
unittest
{
    auto world = testWorldData(testClientData());
    UpdateValues* fields;
    auto inventory = testInventory(world, fields);
    enum ubyte bag0 = inventorySlotBag0;

    ItemPosCount[] dest;
    assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 5) == InventoryResult.ok);
    auto jerky = inventory.storeNew(dest, itemJerky);
    assert(jerky.guid == 1000 && jerky.slot == inventorySlotItemStart && jerky.count == 5);
    assert(fields.get!PLAYER_FIELD_PACK_SLOT_1 == jerky.fullGuid);

    // 18 more: 15 onto the stack of 20, 3 in a new stack.
    dest = null;
    assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 18) == InventoryResult.ok);
    assert(dest == [ItemPosCount(itemPos(bag0, 23), 15), ItemPosCount(itemPos(bag0, 24), 3)]);
    inventory.storeNew(dest, itemJerky);
    assert(jerky.count == 20 && inventory[bag0, 24].count == 3 && inventory.count(itemJerky) == 23);

    // A quiver in a bag slot; arrows go into it before the backpack.
    auto quiver = inventory.create(itemQuiver, 1);
    assert(quiver.isBag && quiver.contents.length == 6);
    ushort equipDest;
    assert(inventory.canEquip(nullSlot, equipDest, quiver, false) == InventoryResult.ok);
    assert(equipDest == itemPos(bag0, inventorySlotBagStart));
    inventory.equip(equipDest, quiver);
    dest = null;
    assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemArrow, 250) == InventoryResult.ok);
    assert(dest == [ItemPosCount(itemPos(19, 0), 200), ItemPosCount(itemPos(19, 1), 50)]);
    inventory.storeNew(dest, itemArrow);
    assert(inventory[19, 1].count == 50 && inventory[19, 1].container is quiver);
    assert(quiver.values.get!CONTAINER_FIELD_SLOT_1(1) == inventory[19, 1].fullGuid);

    // Jerky does not go into a quiver, so a full backpack is full.
    foreach (ubyte slot; 25 .. inventorySlotItemEnd)
        inventory.storeNew([ItemPosCount(itemPos(bag0, slot), 1)], itemShirt);
    dest = null;
    uint noSpace;
    assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemShirt, 1, &noSpace) == InventoryResult.inventoryFull);
    assert(noSpace == 1);
    // ... though onto the stack of 3 there is room for 17.
    dest = null;
    assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 30, &noSpace) == InventoryResult.inventoryFull);
    assert(noSpace == 13 && dest == [ItemPosCount(itemPos(bag0, 24), 17)]);

    // A bag with something in it cannot be taken off; an item limit is kept.
    assert(inventory.canUnequip(quiver.pos, false) == InventoryResult.canOnlyDoWithEmptyBags);
    world.items.edit(itemHearthstone).maxCount = 1;
    world.items.edit(itemHearthstone).stackable = 1;
    assert(inventory.canTakeMoreSimilar(itemHearthstone, 1, null) == InventoryResult.ok);
    assert(inventory.canTakeMoreSimilar(itemHearthstone, 2, null) == InventoryResult.cantCarryMoreOfThis);
}

/// Equipping, swapping, two-handers and splitting stacks.
unittest
{
    auto world = testWorldData(testClientData());
    UpdateValues* fields;
    auto inventory = testInventory(world, fields);
    enum ubyte bag0 = inventorySlotBag0;

    ushort dest;
    assert(inventory.canEquipNew(nullSlot, dest, itemSword, false) == InventoryResult.ok);
    assert(dest == itemPos(bag0, equipmentSlotMainhand));
    auto sword = inventory.equipNew(dest, itemSword);
    assert(inventory.equipped(equipmentSlotMainhand) is sword && inventory.equipmentChanged);
    assert(fields.get!PLAYER_VISIBLE_ITEM_1_0(equipmentSlotMainhand * visibleItemStride) == itemSword);

    // A staff wants the main hand: taken, unless swapping.
    auto staff = inventory.create(itemStaff, 1);
    assert(inventory.canEquip(nullSlot, dest, staff, false) == InventoryResult.itemCantBeEquipped);
    assert(inventory.canEquip(nullSlot, dest, staff, true) == InventoryResult.ok);
    inventory.store([ItemPosCount(itemPos(bag0, 30), 1)], staff);

    // Dragging the staff onto the main hand trades places with the sword.
    assert(!inventory.swap(staff.pos, itemPos(bag0, equipmentSlotMainhand)));
    assert(inventory.equipped(equipmentSlotMainhand) is staff && inventory[bag0, 30] is sword);
    assert(inventory.twoHandUsed);
    assert(fields.get!PLAYER_VISIBLE_ITEM_1_0(equipmentSlotMainhand * visibleItemStride) == itemStaff);

    // Nothing goes in the off hand next to a two-hander; without dual wield no sword goes there at all.
    assert(inventory.swap(sword.pos, itemPos(bag0, equipmentSlotOffhand)).result == InventoryResult.itemCantBeEquipped);

    // A shirt cannot be worn as a weapon.
    auto shirt = inventory.storeNew([ItemPosCount(itemPos(bag0, 31), 1)], itemShirt, creator: 42);
    assert(shirt.record.creator == 42);
    const error = inventory.swap(shirt.pos, itemPos(bag0, equipmentSlotMainhand));
    assert(error.result == InventoryResult.itemCantBeEquipped && error.item is shirt);

    // Splitting: some of a stack moves, all of it or more cannot.
    auto jerky = inventory.storeNew([ItemPosCount(itemPos(bag0, 23), 20)], itemJerky, creator: 42);
    assert(jerky.record.creator == 0);
    assert(!inventory.split(jerky.pos, itemPos(bag0, 24), 5));
    assert(jerky.count == 15 && inventory[bag0, 24].count == 5);
    assert(inventory.split(jerky.pos, itemPos(bag0, 25), 15).result == InventoryResult.couldntSplitItems);
    assert(inventory.split(jerky.pos, itemPos(bag0, 25), 16).result == InventoryResult.triedToSplitMoreThanCount);

    // Dropping a stack onto another fills it and leaves the rest.
    assert(!inventory.swap(itemPos(bag0, 24), jerky.pos));
    assert(jerky.count == 20 && inventory[bag0, 24] is null);
}

/// Banking, buyback, and what saving and the client are told.
unittest
{
    import dmangos.world.objects : UpdateData;

    auto world = testWorldData(testClientData());
    UpdateValues* fields;
    auto inventory = testInventory(world, fields);
    enum ubyte bag0 = inventorySlotBag0;

    auto jerky = inventory.storeNew([ItemPosCount(itemPos(bag0, 23), 10)], itemJerky);
    auto shirt = inventory.storeNew([ItemPosCount(itemPos(bag0, 24), 1)], itemShirt);
    UpdateData update;
    assert(inventory.writeUpdates(update) && update.blockCount == 2, "two create blocks");
    const first = inventory.takeChanges();
    assert(first.length == 2 && first[0].state == ItemState.new_ && first[1].record.slot == 24);
    assert(jerky.state == ItemState.unchanged && inventory.takeChanges().length == 0);

    // To the bank: the first bank slot. A bank bag slot must be bought first.
    ItemPosCount[] dest;
    ubyte bagSlot;
    assert(inventory.canBank(nullBag, nullSlot, dest, jerky, false, bagSlot) == InventoryResult.ok);
    assert(dest == [ItemPosCount(itemPos(bag0, bankSlotItemStart), 10)]);
    inventory.remove(bag0, 23);
    inventory.store(dest, jerky);
    auto quiver = inventory.create(itemQuiver, 1);
    dest = null;
    assert(inventory.canBank(bag0, bankBagSlotStart, dest, quiver, false, bagSlot)
        == InventoryResult.mustPurchaseThatBagSlot);
    inventory.bankBagSlots = 1;
    dest = null;
    assert(inventory.canBank(bag0, bankBagSlotStart, dest, quiver, false, bagSlot) == InventoryResult.ok);
    const moved = inventory.takeChanges();
    assert(moved.length == 1 && moved[0].state == ItemState.changed && moved[0].record.slot == bankSlotItemStart);

    // Sold: the shirt waits in the first buyback slot, its rows deleted until it is bought back.
    inventory.remove(bag0, 24);
    inventory.addToBuyback(shirt, 7, 100);
    assert(inventory.buyback(buybackSlotStart) is shirt && inventory.buybackPrice(buybackSlotStart) == 7);
    assert(fields.get!PLAYER_FIELD_BUYBACK_TIMESTAMP_1 == 100 + 30 * 3600);
    const sold = inventory.takeChanges();
    assert(sold.length == 1 && sold[0].state == ItemState.removed && shirt.state == ItemState.new_);
    inventory.removeFromBuyback(buybackSlotStart, false);
    inventory.store([ItemPosCount(itemPos(bag0, 24), 1)], shirt);
    const bought = inventory.takeChanges();
    assert(bought.length == 1 && bought[0].state == ItemState.new_ && fields.get!PLAYER_FIELD_BUYBACK_PRICE_1 == 0);

    // Destroyed: its rows are deleted and the client forgets it; one never saved just vanishes.
    inventory.markAllSent();
    inventory.destroy(bag0, 24);
    auto never = inventory.storeNew([ItemPosCount(itemPos(bag0, 25), 1)], itemShirt);
    inventory.destroy(never.bagSlot, never.slot);
    const destroyed = inventory.takeChanges();
    assert(destroyed.length == 1 && destroyed[0].state == ItemState.removed && destroyed[0].record.guid == shirt.guid);
    UpdateData gone;
    assert(!inventory.writeUpdates(gone) && inventory.writeForgotten(gone) && gone.blockCount == 1,
        "one out-of-range block, nothing created");
}

/// Reputation-gated items (`RequiredReputationFaction`/`Rank`) ask for the owner's real rank with the faction.
unittest
{
    auto world = testWorldData(testClientData());
    UpdateValues* fields;
    auto inventory = testInventory(world, fields);
    world.items.edit(itemShirt).requiredReputationFaction = 59; // Thorium Brotherhood: the owner is honored
    world.items.edit(itemShirt).requiredReputationRank = 5;
    auto shirt = inventory.create(itemShirt, 1);
    assert(inventory.canUse(shirt) == InventoryResult.ok);
    world.items.edit(itemShirt).requiredReputationRank = 6; // revered
    assert(inventory.canUse(shirt) == InventoryResult.cantEquipReputation);
    world.items.edit(itemShirt).requiredReputationFaction = 21; // neutral with the Booty Bay pirates
    world.items.edit(itemShirt).requiredReputationRank = 3;
    assert(inventory.canUse(shirt) == InventoryResult.ok);
}
