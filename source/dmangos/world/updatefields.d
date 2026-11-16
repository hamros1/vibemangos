/**
 * The 1.12.1 client's update fields: the 32-bit slots that describe every
 * object it knows about.
 *
 * Everything here comes from one table, `updateFields`, which carries
 * CMaNGOS's `g_updateFieldsData` (`Entities/UpdateFields.cpp`, generated from
 * build 5875): each field's object type, name, first slot, size in slots,
 * value type and visibility. At compile time it is turned into
 * $(UL
 *   $(LI a `ushort` constant per field, under CMaNGOS's name (`UNIT_FIELD_HEALTH`), so
 *        fields can be looked up in any 1.12 reference;)
 *   $(LI `fieldCount!type`, the number of slots of each object type;)
 *   $(LI `fieldTypes!type` and `fieldVisibility!type`, a per-slot array of each.)
 * )
 * `dmangos.world.objects.UpdateValues` uses these to check, while compiling,
 * that a float is never written into an integer field, and to send other
 * players only the fields they may see.
 *
 * One correction to the generated data: CMaNGOS's table calls
 * `PLAYER_FIELD_MOD_DAMAGE_DONE_PCT` an integer, but CMaNGOS stores and sends
 * it as a float (1.0 = 100%), and so does this table.
 */
module dmangos.world.updatefields;

/// `TypeMask`, sent in `OBJECT_FIELD_TYPE`.
enum TypeMask : uint
{
    object = 0x0001,
    item = 0x0002,
    container = 0x0004,
    unit = 0x0008,
    player = 0x0010,
    gameObject = 0x0020,
    dynamicObject = 0x0040,
    corpse = 0x0080,
}

/// `TypeID`, sent in a create block.
enum TypeId : ubyte
{
    object = 0,
    item = 1,
    container = 2,
    unit = 3,
    player = 4,
    gameObject = 5,
    dynamicObject = 6,
    corpse = 7,
}

/// `UpdateFieldValueTypes`
enum FieldType : ubyte
{
    none,
    int_,     /// a 32-bit integer (signed or not)
    guid,     /// two slots, low half first
    float_,
    bytes,    /// four separate bytes
    twoShort, /// two 16-bit halves
}

/// `UpdateFieldFlags`: who may see a field.
enum Visibility : uint
{
    none = 0x000,
    public_ = 0x001,     /// everyone
    private_ = 0x002,    /// the player itself
    ownerOnly = 0x004,   /// the owner (of an item, a pet)
    unk1 = 0x008,
    unk2 = 0x010,
    specialInfo = 0x020, /// a caster of Beast Lore
    groupOnly = 0x040,   /// the group
    unk5 = 0x080,
    dynamic = 0x100,     /// everyone, with values that depend on who looks
}

/// One row of the field table.
struct UpdateField
{
    TypeMask owner; /// the type that declares the field
    string name;
    ushort offset;  /// first slot
    ushort size;    /// in slots; 0 for the `*_END` markers
    FieldType type;
    Visibility visibility;
}

/// The field table; see the module documentation.
immutable UpdateField[] updateFields = () {
    alias F = UpdateField, O = TypeMask, T = FieldType, V = Visibility;
    return [
    F(O.object, "OBJECT_FIELD_GUID", 0x0, 2, T.guid, V.public_),
    F(O.object, "OBJECT_FIELD_TYPE", 0x2, 1, T.int_, V.public_),
    F(O.object, "OBJECT_FIELD_ENTRY", 0x3, 1, T.int_, V.public_),
    F(O.object, "OBJECT_FIELD_SCALE_X", 0x4, 1, T.float_, V.public_),
    F(O.object, "OBJECT_FIELD_PADDING", 0x5, 1, T.int_, V.none),
    F(O.object, "OBJECT_END", 0x6, 0, T.none, V.none),
    F(O.item, "ITEM_FIELD_OWNER", 0x6, 2, T.guid, V.public_),
    F(O.item, "ITEM_FIELD_CONTAINED", 0x8, 2, T.guid, V.public_),
    F(O.item, "ITEM_FIELD_CREATOR", 0xA, 2, T.guid, V.public_),
    F(O.item, "ITEM_FIELD_GIFTCREATOR", 0xC, 2, T.guid, V.public_),
    F(O.item, "ITEM_FIELD_STACK_COUNT", 0xE, 1, T.int_, V.ownerOnly | V.unk2),
    F(O.item, "ITEM_FIELD_DURATION", 0xF, 1, T.int_, V.ownerOnly | V.unk2),
    F(O.item, "ITEM_FIELD_SPELL_CHARGES", 0x10, 5, T.int_, V.ownerOnly | V.unk2),
    F(O.item, "ITEM_FIELD_FLAGS", 0x15, 1, T.int_, V.public_),
    F(O.item, "ITEM_FIELD_ENCHANTMENT", 0x16, 21, T.int_, V.public_),
    F(O.item, "ITEM_FIELD_PROPERTY_SEED", 0x2B, 1, T.int_, V.public_),
    F(O.item, "ITEM_FIELD_RANDOM_PROPERTIES_ID", 0x2C, 1, T.int_, V.public_),
    F(O.item, "ITEM_FIELD_ITEM_TEXT_ID", 0x2D, 1, T.int_, V.ownerOnly),
    F(O.item, "ITEM_FIELD_DURABILITY", 0x2E, 1, T.int_, V.ownerOnly | V.unk2),
    F(O.item, "ITEM_FIELD_MAXDURABILITY", 0x2F, 1, T.int_, V.ownerOnly | V.unk2),
    F(O.item, "ITEM_END", 0x30, 0, T.none, V.none),
    F(O.container, "CONTAINER_FIELD_NUM_SLOTS", 0x30, 1, T.int_, V.public_),
    F(O.container, "CONTAINER_ALIGN_PAD", 0x31, 1, T.bytes, V.none),
    F(O.container, "CONTAINER_FIELD_SLOT_1", 0x32, 72, T.guid, V.public_),
    F(O.container, "CONTAINER_END", 0x7A, 0, T.none, V.none),
    F(O.unit, "UNIT_FIELD_CHARM", 0x6, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_SUMMON", 0x8, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_CHARMEDBY", 0xA, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_SUMMONEDBY", 0xC, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_CREATEDBY", 0xE, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_TARGET", 0x10, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_PERSUADED", 0x12, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_CHANNEL_OBJECT", 0x14, 2, T.guid, V.public_),
    F(O.unit, "UNIT_FIELD_HEALTH", 0x16, 1, T.int_, V.dynamic),
    F(O.unit, "UNIT_FIELD_POWER1", 0x17, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_POWER2", 0x18, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_POWER3", 0x19, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_POWER4", 0x1A, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_POWER5", 0x1B, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MAXHEALTH", 0x1C, 1, T.int_, V.dynamic),
    F(O.unit, "UNIT_FIELD_MAXPOWER1", 0x1D, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MAXPOWER2", 0x1E, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MAXPOWER3", 0x1F, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MAXPOWER4", 0x20, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MAXPOWER5", 0x21, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_LEVEL", 0x22, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_FACTIONTEMPLATE", 0x23, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_BYTES_0", 0x24, 1, T.bytes, V.public_),
    F(O.unit, "UNIT_VIRTUAL_ITEM_SLOT_DISPLAY", 0x25, 3, T.int_, V.public_),
    F(O.unit, "UNIT_VIRTUAL_ITEM_INFO", 0x28, 6, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_FLAGS", 0x2E, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_AURA", 0x2F, 48, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_AURAFLAGS", 0x5F, 6, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_AURALEVELS", 0x65, 12, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_AURAAPPLICATIONS", 0x71, 12, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_AURASTATE", 0x7D, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_BASEATTACKTIME", 0x7E, 2, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_RANGEDATTACKTIME", 0x80, 1, T.int_, V.private_),
    F(O.unit, "UNIT_FIELD_BOUNDINGRADIUS", 0x81, 1, T.float_, V.public_),
    F(O.unit, "UNIT_FIELD_COMBATREACH", 0x82, 1, T.float_, V.public_),
    F(O.unit, "UNIT_FIELD_DISPLAYID", 0x83, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_NATIVEDISPLAYID", 0x84, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MOUNTDISPLAYID", 0x85, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_MINDAMAGE", 0x86, 1, T.float_, V.private_ | V.ownerOnly | V.specialInfo),
    F(O.unit, "UNIT_FIELD_MAXDAMAGE", 0x87, 1, T.float_, V.private_ | V.ownerOnly | V.specialInfo),
    F(O.unit, "UNIT_FIELD_MINOFFHANDDAMAGE", 0x88, 1, T.float_, V.private_ | V.ownerOnly | V.specialInfo),
    F(O.unit, "UNIT_FIELD_MAXOFFHANDDAMAGE", 0x89, 1, T.float_, V.private_ | V.ownerOnly | V.specialInfo),
    F(O.unit, "UNIT_FIELD_BYTES_1", 0x8A, 1, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_PETNUMBER", 0x8B, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_PET_NAME_TIMESTAMP", 0x8C, 1, T.int_, V.public_),
    F(O.unit, "UNIT_FIELD_PETEXPERIENCE", 0x8D, 1, T.int_, V.ownerOnly),
    F(O.unit, "UNIT_FIELD_PETNEXTLEVELEXP", 0x8E, 1, T.int_, V.ownerOnly),
    F(O.unit, "UNIT_DYNAMIC_FLAGS", 0x8F, 1, T.int_, V.dynamic),
    F(O.unit, "UNIT_CHANNEL_SPELL", 0x90, 1, T.int_, V.public_),
    F(O.unit, "UNIT_MOD_CAST_SPEED", 0x91, 1, T.float_, V.public_),
    F(O.unit, "UNIT_CREATED_BY_SPELL", 0x92, 1, T.int_, V.public_),
    F(O.unit, "UNIT_NPC_FLAGS", 0x93, 1, T.int_, V.public_),
    F(O.unit, "UNIT_NPC_EMOTESTATE", 0x94, 1, T.int_, V.public_),
    F(O.unit, "UNIT_TRAINING_POINTS", 0x95, 1, T.twoShort, V.ownerOnly),
    F(O.unit, "UNIT_FIELD_STAT0", 0x96, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_STAT1", 0x97, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_STAT2", 0x98, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_STAT3", 0x99, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_STAT4", 0x9A, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_RESISTANCES", 0x9B, 7, T.int_, V.private_ | V.ownerOnly | V.specialInfo),
    F(O.unit, "UNIT_FIELD_BASE_MANA", 0xA2, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_BASE_HEALTH", 0xA3, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_BYTES_2", 0xA4, 1, T.bytes, V.public_),
    F(O.unit, "UNIT_FIELD_ATTACK_POWER", 0xA5, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_ATTACK_POWER_MODS", 0xA6, 1, T.twoShort, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_ATTACK_POWER_MULTIPLIER", 0xA7, 1, T.float_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_RANGED_ATTACK_POWER", 0xA8, 1, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_RANGED_ATTACK_POWER_MODS", 0xA9, 1, T.twoShort, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_RANGED_ATTACK_POWER_MULTIPLIER", 0xAA, 1, T.float_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_MINRANGEDDAMAGE", 0xAB, 1, T.float_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_MAXRANGEDDAMAGE", 0xAC, 1, T.float_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_POWER_COST_MODIFIER", 0xAD, 7, T.int_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_POWER_COST_MULTIPLIER", 0xB4, 7, T.float_, V.private_ | V.ownerOnly),
    F(O.unit, "UNIT_FIELD_PADDING", 0xBB, 1, T.int_, V.none),
    F(O.unit, "UNIT_END", 0xBC, 0, T.none, V.none),
    F(O.player, "PLAYER_DUEL_ARBITER", 0xBC, 2, T.guid, V.public_),
    F(O.player, "PLAYER_FLAGS", 0xBE, 1, T.int_, V.public_),
    F(O.player, "PLAYER_GUILDID", 0xBF, 1, T.int_, V.public_),
    F(O.player, "PLAYER_GUILDRANK", 0xC0, 1, T.int_, V.public_),
    F(O.player, "PLAYER_BYTES", 0xC1, 1, T.bytes, V.public_),
    F(O.player, "PLAYER_BYTES_2", 0xC2, 1, T.bytes, V.public_),
    F(O.player, "PLAYER_BYTES_3", 0xC3, 1, T.bytes, V.public_),
    F(O.player, "PLAYER_DUEL_TEAM", 0xC4, 1, T.int_, V.public_),
    F(O.player, "PLAYER_GUILD_TIMESTAMP", 0xC5, 1, T.int_, V.public_),
    F(O.player, "PLAYER_QUEST_LOG_1_1", 0xC6, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_1_2", 0xC7, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_2_1", 0xC9, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_2_2", 0xCA, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_3_1", 0xCC, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_3_2", 0xCD, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_4_1", 0xCF, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_4_2", 0xD0, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_5_1", 0xD2, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_5_2", 0xD3, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_6_1", 0xD5, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_6_2", 0xD6, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_7_1", 0xD8, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_7_2", 0xD9, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_8_1", 0xDB, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_8_2", 0xDC, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_9_1", 0xDE, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_9_2", 0xDF, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_10_1", 0xE1, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_10_2", 0xE2, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_11_1", 0xE4, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_11_2", 0xE5, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_12_1", 0xE7, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_12_2", 0xE8, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_13_1", 0xEA, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_13_2", 0xEB, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_14_1", 0xED, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_14_2", 0xEE, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_15_1", 0xF0, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_15_2", 0xF1, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_16_1", 0xF3, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_16_2", 0xF4, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_17_1", 0xF6, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_17_2", 0xF7, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_18_1", 0xF9, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_18_2", 0xFA, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_19_1", 0xFC, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_19_2", 0xFD, 2, T.int_, V.private_),
    F(O.player, "PLAYER_QUEST_LOG_20_1", 0xFF, 1, T.int_, V.groupOnly),
    F(O.player, "PLAYER_QUEST_LOG_20_2", 0x100, 2, T.int_, V.private_),
    F(O.player, "PLAYER_VISIBLE_ITEM_1_CREATOR", 0x102, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_1_0", 0x104, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_1_PROPERTIES", 0x10C, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_1_PAD", 0x10D, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_2_CREATOR", 0x10E, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_2_0", 0x110, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_2_PROPERTIES", 0x118, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_2_PAD", 0x119, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_3_CREATOR", 0x11A, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_3_0", 0x11C, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_3_PROPERTIES", 0x124, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_3_PAD", 0x125, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_4_CREATOR", 0x126, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_4_0", 0x128, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_4_PROPERTIES", 0x130, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_4_PAD", 0x131, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_5_CREATOR", 0x132, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_5_0", 0x134, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_5_PROPERTIES", 0x13C, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_5_PAD", 0x13D, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_6_CREATOR", 0x13E, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_6_0", 0x140, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_6_PROPERTIES", 0x148, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_6_PAD", 0x149, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_7_CREATOR", 0x14A, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_7_0", 0x14C, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_7_PROPERTIES", 0x154, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_7_PAD", 0x155, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_8_CREATOR", 0x156, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_8_0", 0x158, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_8_PROPERTIES", 0x160, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_8_PAD", 0x161, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_9_CREATOR", 0x162, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_9_0", 0x164, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_9_PROPERTIES", 0x16C, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_9_PAD", 0x16D, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_10_CREATOR", 0x16E, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_10_0", 0x170, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_10_PROPERTIES", 0x178, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_10_PAD", 0x179, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_11_CREATOR", 0x17A, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_11_0", 0x17C, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_11_PROPERTIES", 0x184, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_11_PAD", 0x185, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_12_CREATOR", 0x186, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_12_0", 0x188, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_12_PROPERTIES", 0x190, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_12_PAD", 0x191, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_13_CREATOR", 0x192, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_13_0", 0x194, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_13_PROPERTIES", 0x19C, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_13_PAD", 0x19D, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_14_CREATOR", 0x19E, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_14_0", 0x1A0, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_14_PROPERTIES", 0x1A8, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_14_PAD", 0x1A9, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_15_CREATOR", 0x1AA, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_15_0", 0x1AC, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_15_PROPERTIES", 0x1B4, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_15_PAD", 0x1B5, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_16_CREATOR", 0x1B6, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_16_0", 0x1B8, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_16_PROPERTIES", 0x1C0, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_16_PAD", 0x1C1, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_17_CREATOR", 0x1C2, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_17_0", 0x1C4, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_17_PROPERTIES", 0x1CC, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_17_PAD", 0x1CD, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_18_CREATOR", 0x1CE, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_18_0", 0x1D0, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_18_PROPERTIES", 0x1D8, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_18_PAD", 0x1D9, 1, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_19_CREATOR", 0x1DA, 2, T.guid, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_19_0", 0x1DC, 8, T.int_, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_19_PROPERTIES", 0x1E4, 1, T.twoShort, V.public_),
    F(O.player, "PLAYER_VISIBLE_ITEM_19_PAD", 0x1E5, 1, T.int_, V.public_),
    F(O.player, "PLAYER_FIELD_INV_SLOT_HEAD", 0x1E6, 46, T.guid, V.private_),
    F(O.player, "PLAYER_FIELD_PACK_SLOT_1", 0x214, 32, T.guid, V.private_),
    F(O.player, "PLAYER_FIELD_BANK_SLOT_1", 0x234, 48, T.guid, V.private_),
    F(O.player, "PLAYER_FIELD_BANKBAG_SLOT_1", 0x264, 12, T.guid, V.private_),
    F(O.player, "PLAYER_FIELD_VENDORBUYBACK_SLOT_1", 0x270, 24, T.guid, V.private_),
    F(O.player, "PLAYER_FIELD_KEYRING_SLOT_1", 0x288, 64, T.guid, V.private_),
    F(O.player, "PLAYER_FARSIGHT", 0x2C8, 2, T.guid, V.private_),
    F(O.player, "PLAYER__FIELD_COMBO_TARGET", 0x2CA, 2, T.guid, V.private_),
    F(O.player, "PLAYER_XP", 0x2CC, 1, T.int_, V.private_),
    F(O.player, "PLAYER_NEXT_LEVEL_XP", 0x2CD, 1, T.int_, V.private_),
    F(O.player, "PLAYER_SKILL_INFO_1_1", 0x2CE, 384, T.twoShort, V.private_),
    F(O.player, "PLAYER_CHARACTER_POINTS1", 0x44E, 1, T.int_, V.private_),
    F(O.player, "PLAYER_CHARACTER_POINTS2", 0x44F, 1, T.int_, V.private_),
    F(O.player, "PLAYER_TRACK_CREATURES", 0x450, 1, T.int_, V.private_),
    F(O.player, "PLAYER_TRACK_RESOURCES", 0x451, 1, T.int_, V.private_),
    F(O.player, "PLAYER_BLOCK_PERCENTAGE", 0x452, 1, T.float_, V.private_),
    F(O.player, "PLAYER_DODGE_PERCENTAGE", 0x453, 1, T.float_, V.private_),
    F(O.player, "PLAYER_PARRY_PERCENTAGE", 0x454, 1, T.float_, V.private_),
    F(O.player, "PLAYER_CRIT_PERCENTAGE", 0x455, 1, T.float_, V.private_),
    F(O.player, "PLAYER_RANGED_CRIT_PERCENTAGE", 0x456, 1, T.float_, V.private_),
    F(O.player, "PLAYER_EXPLORED_ZONES_1", 0x457, 64, T.bytes, V.private_),
    F(O.player, "PLAYER_REST_STATE_EXPERIENCE", 0x497, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_COINAGE", 0x498, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_POSSTAT0", 0x499, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_POSSTAT1", 0x49A, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_POSSTAT2", 0x49B, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_POSSTAT3", 0x49C, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_POSSTAT4", 0x49D, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_NEGSTAT0", 0x49E, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_NEGSTAT1", 0x49F, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_NEGSTAT2", 0x4A0, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_NEGSTAT3", 0x4A1, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_NEGSTAT4", 0x4A2, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_RESISTANCEBUFFMODSPOSITIVE", 0x4A3, 7, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_RESISTANCEBUFFMODSNEGATIVE", 0x4AA, 7, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_MOD_DAMAGE_DONE_POS", 0x4B1, 7, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_MOD_DAMAGE_DONE_NEG", 0x4B8, 7, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_MOD_DAMAGE_DONE_PCT", 0x4BF, 7, T.float_, V.private_),
    F(O.player, "PLAYER_FIELD_BYTES", 0x4C6, 1, T.bytes, V.private_),
    F(O.player, "PLAYER_AMMO_ID", 0x4C7, 1, T.int_, V.private_),
    F(O.player, "PLAYER_SELF_RES_SPELL", 0x4C8, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_PVP_MEDALS", 0x4C9, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_BUYBACK_PRICE_1", 0x4CA, 12, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_BUYBACK_TIMESTAMP_1", 0x4D6, 12, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_SESSION_KILLS", 0x4E2, 1, T.twoShort, V.private_),
    F(O.player, "PLAYER_FIELD_YESTERDAY_KILLS", 0x4E3, 1, T.twoShort, V.private_),
    F(O.player, "PLAYER_FIELD_LAST_WEEK_KILLS", 0x4E4, 1, T.twoShort, V.private_),
    F(O.player, "PLAYER_FIELD_THIS_WEEK_KILLS", 0x4E5, 1, T.twoShort, V.private_),
    F(O.player, "PLAYER_FIELD_THIS_WEEK_CONTRIBUTION", 0x4E6, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_LIFETIME_HONORBALE_KILLS", 0x4E7, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_LIFETIME_DISHONORBALE_KILLS", 0x4E8, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_YESTERDAY_CONTRIBUTION", 0x4E9, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_LAST_WEEK_CONTRIBUTION", 0x4EA, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_LAST_WEEK_RANK", 0x4EB, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_BYTES2", 0x4EC, 1, T.bytes, V.private_),
    F(O.player, "PLAYER_FIELD_WATCHED_FACTION_INDEX", 0x4ED, 1, T.int_, V.private_),
    F(O.player, "PLAYER_FIELD_COMBAT_RATING_1", 0x4EE, 20, T.int_, V.private_),
    F(O.player, "PLAYER_END", 0x502, 0, T.none, V.none),
    F(O.gameObject, "OBJECT_FIELD_CREATED_BY", 0x6, 2, T.guid, V.public_),
    F(O.gameObject, "GAMEOBJECT_DISPLAYID", 0x8, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_FLAGS", 0x9, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_ROTATION", 0xA, 4, T.float_, V.public_),
    F(O.gameObject, "GAMEOBJECT_STATE", 0xE, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_POS_X", 0xF, 1, T.float_, V.public_),
    F(O.gameObject, "GAMEOBJECT_POS_Y", 0x10, 1, T.float_, V.public_),
    F(O.gameObject, "GAMEOBJECT_POS_Z", 0x11, 1, T.float_, V.public_),
    F(O.gameObject, "GAMEOBJECT_FACING", 0x12, 1, T.float_, V.public_),
    F(O.gameObject, "GAMEOBJECT_DYN_FLAGS", 0x13, 1, T.int_, V.dynamic),
    F(O.gameObject, "GAMEOBJECT_FACTION", 0x14, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_TYPE_ID", 0x15, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_LEVEL", 0x16, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_ARTKIT", 0x17, 1, T.int_, V.public_),
    F(O.gameObject, "GAMEOBJECT_ANIMPROGRESS", 0x18, 1, T.int_, V.dynamic),
    F(O.gameObject, "GAMEOBJECT_PADDING", 0x19, 1, T.int_, V.none),
    F(O.gameObject, "GAMEOBJECT_END", 0x1A, 0, T.none, V.none),
    F(O.dynamicObject, "DYNAMICOBJECT_CASTER", 0x6, 2, T.guid, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_BYTES", 0x8, 1, T.bytes, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_SPELLID", 0x9, 1, T.int_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_RADIUS", 0xA, 1, T.float_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_POS_X", 0xB, 1, T.float_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_POS_Y", 0xC, 1, T.float_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_POS_Z", 0xD, 1, T.float_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_FACING", 0xE, 1, T.float_, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_PAD", 0xF, 1, T.bytes, V.public_),
    F(O.dynamicObject, "DYNAMICOBJECT_END", 0x10, 0, T.none, V.none),
    F(O.corpse, "CORPSE_FIELD_OWNER", 0x6, 2, T.guid, V.public_),
    F(O.corpse, "CORPSE_FIELD_FACING", 0x8, 1, T.float_, V.public_),
    F(O.corpse, "CORPSE_FIELD_POS_X", 0x9, 1, T.float_, V.public_),
    F(O.corpse, "CORPSE_FIELD_POS_Y", 0xA, 1, T.float_, V.public_),
    F(O.corpse, "CORPSE_FIELD_POS_Z", 0xB, 1, T.float_, V.public_),
    F(O.corpse, "CORPSE_FIELD_DISPLAY_ID", 0xC, 1, T.int_, V.public_),
    F(O.corpse, "CORPSE_FIELD_ITEM", 0xD, 19, T.int_, V.public_),
    F(O.corpse, "CORPSE_FIELD_BYTES_1", 0x20, 1, T.bytes, V.public_),
    F(O.corpse, "CORPSE_FIELD_BYTES_2", 0x21, 1, T.bytes, V.public_),
    F(O.corpse, "CORPSE_FIELD_GUILD", 0x22, 1, T.int_, V.public_),
    F(O.corpse, "CORPSE_FIELD_FLAGS", 0x23, 1, T.int_, V.public_),
    F(O.corpse, "CORPSE_FIELD_DYNAMIC_FLAGS", 0x24, 1, T.int_, V.dynamic),
    F(O.corpse, "CORPSE_FIELD_PAD", 0x25, 1, T.int_, V.none),
    F(O.corpse, "CORPSE_END", 0x26, 0, T.none, V.none),
    ];
}();

/**
 * A field's first slot, together with its row in `updateFields`.
 *
 * Fields of different object types share offsets (`ITEM_FIELD_SPELL_CHARGES`
 * and `UNIT_FIELD_TARGET` are both slot 16), so the offset alone does not say
 * which field is meant. The row does, and `UpdateValues.set!field` uses it
 * to look up the field's type. Everywhere else a field is just its offset:
 * `alias offset this` makes `UNIT_FIELD_STAT0 + 2` and `values[UNIT_FIELD_HEALTH]`
 * work as with plain numbers.
 */
struct UpdateFieldId
{
    ushort offset;
    ushort row;
    alias offset this;
}

// One constant per field: `enum UNIT_FIELD_HEALTH = UpdateFieldId(0x16, 54);` and so on.
mixin(() {
    import std.conv : to;

    string code;
    foreach (i, field; updateFields)
        code ~= "enum " ~ field.name ~ " = UpdateFieldId(" ~ field.offset.to!string ~ ", " ~ i.to!string ~ ");\n";
    return code;
}());

/// The type masks an object of `type` has: its own and those of its bases.
TypeMask typeMaskOf(TypeId type) pure nothrow @nogc @safe
{
    final switch (type)
    {
    case TypeId.object:
        return TypeMask.object;
    case TypeId.item:
        return TypeMask.object | TypeMask.item;
    case TypeId.container:
        return TypeMask.object | TypeMask.item | TypeMask.container;
    case TypeId.unit:
        return TypeMask.object | TypeMask.unit;
    case TypeId.player:
        return TypeMask.object | TypeMask.unit | TypeMask.player;
    case TypeId.gameObject:
        return TypeMask.object | TypeMask.gameObject;
    case TypeId.dynamicObject:
        return TypeMask.object | TypeMask.dynamicObject;
    case TypeId.corpse:
        return TypeMask.object | TypeMask.corpse;
    }
}

/// Number of slots an object of `type` has: the end of its last field.
enum ushort fieldCount(TypeId type) = () {
    ushort end;
    foreach (field; updateFields)
        if ((field.owner & typeMaskOf(type)) && field.offset + field.size > end)
            end = cast(ushort)(field.offset + field.size);
    return end;
}();

/// Each slot's value type, for an object of `type` (a guid's second slot is `guid` too).
immutable FieldType[] fieldTypes(TypeId type) = () {
    auto types = new FieldType[fieldCount!type];
    foreach (field; updateFields)
        if (field.owner & typeMaskOf(type))
            types[field.offset .. field.offset + field.size] = field.type;
    return types;
}();

/// Each slot's visibility, for an object of `type`.
immutable Visibility[] fieldVisibility(TypeId type) = () {
    auto flags = new Visibility[fieldCount!type];
    foreach (field; updateFields)
        if (field.owner & typeMaskOf(type))
            flags[field.offset .. field.offset + field.size] = field.visibility;
    return flags;
}();

/// The row of the field that starts at `offset` for an object of `type`.
UpdateField fieldAt(TypeId type, ushort offset) pure nothrow @safe
{
    foreach (field; updateFields)
        if ((field.owner & typeMaskOf(type)) && field.offset == offset && field.size > 0)
            return field;
    return UpdateField.init;
}

/// Slots per equipment entry in the `PLAYER_VISIBLE_ITEM_*` block.
enum ushort visibleItemStride = PLAYER_VISIBLE_ITEM_2_CREATOR - PLAYER_VISIBLE_ITEM_1_CREATOR;

/// Enchantments shown on a visible item (`MAX_INSPECTED_ENCHANTMENT_SLOT`).
enum visibleEnchantments = PLAYER_VISIBLE_ITEM_1_PROPERTIES - PLAYER_VISIBLE_ITEM_1_0 - 1;

/// Skills the client has slots for (`PLAYER_MAX_SKILLS`).
enum maxPlayerSkills = fieldAt(TypeId.player, PLAYER_SKILL_INFO_1_1).size / 3;

/// Inventory positions of bag 0 the player's fields have a guid for: equipment to keyring.
enum playerInventorySlots = (PLAYER_FARSIGHT - PLAYER_FIELD_INV_SLOT_HEAD) / 2;

/// Slots a bag can have (`MAX_BAG_SIZE`).
enum maxBagSize = fieldAt(TypeId.container, CONTAINER_FIELD_SLOT_1).size / 2;

// The layout, cross-checked against CMaNGOS's header.
static assert(updateFields.length == 324, "CMaNGOS's g_updateFieldsData has 324 entries");
static assert(fieldCount!(TypeId.player) == PLAYER_END && fieldCount!(TypeId.unit) == UNIT_END);
static assert(fieldCount!(TypeId.item) == ITEM_END && fieldCount!(TypeId.container) == CONTAINER_END);
static assert(PLAYER_END == 1282 && UNIT_END == 188 && CONTAINER_END == 122);
static assert(ITEM_FIELD_SPELL_CHARGES.offset == UNIT_FIELD_TARGET.offset
    && ITEM_FIELD_SPELL_CHARGES.row != UNIT_FIELD_TARGET.row, "same slot, different fields");
static assert(visibleItemStride == 12 && visibleEnchantments == 7);
static assert(maxPlayerSkills == 128 && maxBagSize == 36);
static assert(playerInventorySlots == 113, "INVENTORY_SLOT_BAG_0 positions 0 .. KEYRING_SLOT_END");
static assert(PLAYER_FIELD_PACK_SLOT_1 == PLAYER_FIELD_INV_SLOT_HEAD + 2 * 23, "the backpack follows equipment and bags");
static assert(fieldTypes!(TypeId.player)[UNIT_FIELD_STAT0] == FieldType.int_);
static assert(fieldTypes!(TypeId.player)[UNIT_FIELD_MINDAMAGE] == FieldType.float_);
static assert(fieldTypes!(TypeId.item)[ITEM_FIELD_OWNER + 1] == FieldType.guid);
static assert(fieldVisibility!(TypeId.player)[UNIT_FIELD_HEALTH] == Visibility.dynamic, "a percentage for strangers");
static assert(fieldVisibility!(TypeId.player)[PLAYER_FIELD_COINAGE] == Visibility.private_);
