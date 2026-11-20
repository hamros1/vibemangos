/**
 * The client's DBC tables the world server needs, plus the indexes built
 * from them (by area, skill, spell, talent, channel, ...).
 *
 * Every record struct follows its 1.12 DBC file's layout, field for field,
 * with a format string; `DbcStore` verifies the pair at compile time. The
 * files are read from `<data_dir>/dbc/`.
 *
 * Indexes are built by iterating the stores in ascending id order, so the
 * order of entries under one key (which decides "first match" lookups) is
 * the order of ids.
 */
module dmangos.world.clientdata;

import dmangos.world.auctionhouse : AuctionHouseEntry, auctionHouseFormat;
import std.algorithm.sorting : sort;
import std.path : buildPath;

import dmangos.dbc;
import dmangos.log;

/// Bitmask of the eight playable 1.12 races.
enum uint playableRaceMask = 0xFF;
/// Bitmask of the nine playable 1.12 classes.
enum uint playableClassMask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 8)
    | (1 << 10);

/// The mask bit of a race or class: `1 << (value - 1)`; 0 for 0.
uint maskOf(uint raceOrClass) pure nothrow @nogc @safe
{
    return raceOrClass ? 1u << (raceOrClass - 1) : 0;
}

/// What part of a character a `CharSections.dbc` record textures.
enum CharSectionType : uint
{
    skin = 0,
    face = 1,
    facialHair = 2,
    hair = 3,
    underwear = 4,
}

/// A `CharSections.dbc` flag: the section may not be chosen.
enum uint sectionFlagUnavailable = 0x01;

/// A `SkillRaceClassInfo.dbc` flag: the skill's value is always its maximum.
enum uint skillFlagMaximized = 0x010;

/// Steps in a `SkillTiers.dbc` record.
enum maxSkillStep = 16;

// ---------------------------------------------------------------------------
// Records with their formats
// ---------------------------------------------------------------------------

///
struct CharSectionsEntry
{
    uint race;
    uint gender;
    uint baseSection;
    uint variationIndex;
    uint colorIndex;
    uint flags;
}

enum charSectionsFormat = "diiiiixxxi"; ///

///
struct CharacterFacialHairStylesEntry
{
    uint raceId;
    uint sexId;
    uint variationId;
}

enum characterFacialHairStylesFormat = "iiixxxxxx"; ///

///
struct ChrClassesEntry
{
    uint classId;
    uint powerType;
    string[8] name;
    uint spellFamily;
}

enum chrClassesFormat = "nxxixssssssssxxix"; ///

///
struct ChrRacesEntry
{
    uint raceId;
    uint factionId;
    uint maleDisplayId;
    uint femaleDisplayId;
    uint teamId;            /// 7 = Alliance, 1 = Horde
    uint startingTaxiMask;
    uint cinematicSequence;
    string[8] name;
}

enum chrRacesFormat = "nxixiixxixxxxxixissssssssxxxx"; ///

/// A `CreatureDisplayInfo.dbc` record.
struct CreatureDisplayInfoEntry
{
    uint id;
    uint modelId;
    uint extendedDisplayInfoId;
    float scale = 0;
}

enum creatureDisplayInfoFormat = "nixifxxxxxxx"; ///

/// A `CreatureModelData.dbc` record.
struct CreatureModelDataEntry
{
    uint id;
    uint flags;
    float scale = 0;
    float collisionWidth = 0;
    float collisionHeight = 0;
}

enum creatureModelDataFormat = "nixxfxxxxxxxxxff"; ///

/// `EmotesText.dbc`: what a text emote (/wave) animates.
struct EmotesTextEntry
{
    uint id;
    uint emote; /// `Emotes.dbc` id; 0 for none
}

enum emotesTextFormat = "nxixxxxxxxxxxxxxxxx"; ///

/// An `Emotes.dbc` record.
struct EmotesEntry
{
    uint id;
    uint flags;
    uint emoteType; /// 0 a one-shot animation; 1 and 2 a state that lasts (dancing)
    uint standState;
}

enum emotesFormat = "nxxiiix"; ///

/// Number of item slots in a starting outfit.
enum maxOutfitItems = 12;

/**
 * In the 1.12 file, race, class, gender and outfit are four one-byte fields.
 * They are read as four bytes here, so the layout is exact, and
 * `raceClassGender` packs them into the one 32-bit key lookups compare.
 */
struct CharStartOutfitEntry
{
    ubyte race;
    ubyte classId;
    ubyte gender;
    ubyte outfit;
    int[maxOutfitItems] itemId;

    /// The four bytes as one key: race | class << 8 | gender << 16 | outfit << 24.
    @property uint raceClassGender() const pure nothrow @nogc @safe
    {
        return race | classId << 8 | gender << 16 | outfit << 24;
    }
}

enum charStartOutfitFormat = "dbbbbiiiiiiiiiiiixxxxxxxxxxxxxxxxxxxxxxxx"; /// 41 fields, 152 bytes

///
struct FactionEntry
{
    uint id;
    int reputationListId;
    uint[4] baseRepRaceMask;
    uint[4] baseRepClassMask;
    int[4] baseRepValue;
    uint[4] reputationFlags;
    uint team;
    string[8] name;

    /// Whether the faction appears in the reputation list.
    bool hasReputation() const pure nothrow @nogc @safe
    {
        return reputationListId >= 0;
    }

    /// Index of the base reputation entry that applies to a race and class, or -1.
    int indexFitTo(uint raceMask, uint classMask) const pure nothrow @nogc @safe
    {
        foreach (i; 0 .. 4)
            if ((baseRepRaceMask[i] == 0 || (baseRepRaceMask[i] & raceMask))
                && (baseRepClassMask[i] == 0 || (baseRepClassMask[i] & classMask)))
                return i;
        return -1;
    }
}

enum factionFormat = "niiiiiiiiiiiiiiiiiissssssssxxxxxxxxxx"; ///

/// `Lock.dbc`: what opens a lock, case by case (a key item, or a lock type and its skill).
struct LockEntry
{
    uint id;
    uint[8] type;   /// the key's kind: 1 an item, 2 a skill
    uint[8] index;  /// the item, or the lock type
    uint[8] skill;  /// the skill needed
}

enum lockFormat = "niiiiiiiiiiiiiiiiiiiiiiiixxxxxxxx"; ///

/// `MailTemplate.dbc`: the letters the client knows the subject and text of, by id.
struct MailTemplateEntry
{
    uint id;
}

enum mailTemplateFormat = "nxxxxxxxxx"; ///

/// `ItemRandomProperties.dbc`: a random property, and the enchantments it gives (up to three).
struct ItemRandomPropertiesEntry
{
    uint id;
    uint[3] enchantments;
}

enum itemRandomPropertiesFormat = "nxiiixxxxxxxxxxx"; ///

/// `SpellItemEnchantment.dbc`: an enchantment's effects (`dmangos.world.enchantments`).
struct SpellItemEnchantmentEntry
{
    uint id;
    uint[3] type;
    uint[3] amount;
    uint[3] arg;     /// the stat type, the resistance's school or the spell
    uint itemVisual;
    uint flags;
}

enum spellItemEnchantmentFormat = "niiiiiixxxiiixxxxxxxxxii"; ///

/// `TaxiNodes.dbc`: a flight master's place, and the mounts of its flights (Horde, Alliance).
struct TaxiNodesEntry
{
    uint id;
    uint mapId;
    float x = 0, y = 0, z = 0;
    string[8] name;
    uint[2] mountCreature;
}

enum taxiNodesFormat = "nifffssssssssxii"; ///

/// `TaxiPath.dbc`: a flight from one node to another, and its price.
struct TaxiPathEntry
{
    uint id;
    uint from;
    uint to;
    uint price;
}

enum taxiPathFormat = "niii"; ///

/// `TaxiPathNode.dbc`: a point of a flight's path.
struct TaxiPathNodeEntry
{
    uint path;
    uint index;
    uint mapId;
    float x = 0, y = 0, z = 0;
    uint actionFlag;
    uint delay;
}

enum taxiPathNodeFormat = "diiifffii"; ///

/// `FactionTemplate.dbc`: how a unit of a faction stands to others (`dmangos.world.relations`).
struct FactionTemplateEntry
{
    uint id;
    uint faction;
    uint flags;
    uint groupMask;          /// the faction groups this one is in
    uint friendGroupMask;    /// groups it is friendly to
    uint enemyGroupMask;     /// groups it is hostile to
    uint[4] enemyFactions;
    uint[4] friendFactions;
}

enum factionTemplateFormat = "niiiiiiiiiiiii"; ///

/// `WorldSafeLocs.dbc`: a graveyard (or other safe place) where ghosts appear.
struct WorldSafeLocsEntry
{
    uint id;
    uint map;
    float x = 0, y = 0, z = 0;
}

enum worldSafeLocsFormat = "nifffxxxxxxxxx"; ///

/// `SpellCastTimes.dbc`: a cast time, in milliseconds.
struct SpellCastTimesEntry
{
    uint id;
    int castTime;
    int perLevel;
    int minimum;
}

enum spellCastTimesFormat = "niii"; ///

/// `SpellDuration.dbc`: how long an aura lasts, in milliseconds (-1: until cancelled).
struct SpellDurationEntry
{
    uint id;
    int duration;
    int perLevel;
    int maximum;
}

enum spellDurationFormat = "niii"; ///

/// A `SpellShapeshiftForm.dbc` record: whether a form acts as a shapeshift for spells.
struct SpellShapeshiftFormEntry
{
    uint id;
    uint flags; /// `flags1`: 1 = a stance (battle, Shadowform, Stealth, Moonkin): spells are cast as unshifted
}

enum spellShapeshiftFormFormat = "nxxxxxxxxxxixx"; ///

/// Whether being in `form` (0: none) counts as shapeshifted for spells (CMaNGOS's `GetErrorAtShapeshiftedCast`):
/// Cat, Bear, Travel Form, Ghost Wolf do; the warrior's stances, Shadowform, Stealth and Moonkin Form do not.
bool actsAsShapeshifted(const ClientData client, uint form)
{
    if (form == 0)
        return false;
    const entry = client.spellShapeshiftForms.lookup(form);
    return entry !is null && !(entry.flags & 1);
}

/// A `SpellRange.dbc` record.
struct SpellRangeEntry
{
    uint id;
    float minRange;
    float maxRange;
    uint flags;
}

enum spellRangeFormat = "nffixxxxxxxxxxxxxxxxxx"; ///

/// A `SpellRadius.dbc` record.
struct SpellRadiusEntry
{
    uint id;
    float radius;
}

enum spellRadiusFormat = "nfxx"; ///

///
struct SkillLineEntry
{
    uint id;
    int categoryId;
    string[8] name;
    uint spellIcon;
}

enum skillLineFormat = "nixssssssssxxxxxxxxxxi"; ///

///
struct SkillLineAbilityEntry
{
    uint id;
    uint skillId;
    uint spellId;
    uint raceMask;
    uint classMask;
    uint reqSkillValue;
    uint forwardSpellId;
    uint learnOnGetSkill;
    uint maxValue;
    uint minValue;
    uint reqTrainPoints;
}

enum skillLineAbilityFormat = "niiiixxiiiiixxi"; ///

///
struct SkillRaceClassInfoEntry
{
    uint skillId;
    uint raceMask;
    uint classMask;
    uint flags;
    uint reqLevel;
    uint skillTierId;
}

enum skillRaceClassInfoFormat = "diiiiiix"; ///

///
struct SkillTiersEntry
{
    uint id;
    uint[maxSkillStep] skillValue;
    uint[maxSkillStep] maxSkillValue;
}

enum skillTiersFormat = "niiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii"; ///

/// Ranks a talent can have.
enum maxTalentRank = 5;

///
struct TalentEntry
{
    uint talentId;
    uint talentTab;
    uint row;
    uint col;
    uint[maxTalentRank] rankId;
    uint dependsOn;
    uint dependsOnRank;
    uint dependsOnSpell;
}

enum talentFormat = "niiiiiiiixxxxixxixxxi"; ///

/// An item set (`ItemSet.dbc`): its bonus spells and how many of its items each needs.
struct ItemSetEntry
{
    uint id;
    uint[8] spells;            /// `m_setSpellID`
    uint[8] thresholds;        /// `m_setThreshold`: items worn for each spell
    uint requiredSkill;        /// `m_requiredSkill`
    uint requiredSkillValue;   /// `m_requiredSkillRank`
}

enum itemSetFormat = "nxxxxxxxxxxxxxxxxxxxxxxxxxxiiiiiiiiiiiiiiiiii"; ///

///
struct TalentTabEntry
{
    uint tabId;
    uint classMask;
    uint tabPage;
}

enum talentTabFormat = "nxxxxxxxxxxxiix"; ///

/// A `Map.dbc` record.
struct MapEntry
{
    uint mapId;
    uint mapType;    /// a `MapType`
    string[8] name;
    uint linkedZone;
    uint multimapId;

    /// Whether it is a dungeon: an instance or a raid.
    @property bool isDungeon() const pure nothrow @nogc @safe
    {
        return mapType == MapType.instance || mapType == MapType.raid;
    }

    /// Whether it is a raid.
    @property bool isRaid() const pure nothrow @nogc @safe
    {
        return mapType == MapType.raid;
    }

    /// Whether it is a battleground.
    @property bool isBattleground() const pure nothrow @nogc @safe
    {
        return mapType == MapType.battleground;
    }

    /// Whether it is a continent: Eastern Kingdoms or Kalimdor.
    @property bool isContinent() const pure nothrow @nogc @safe
    {
        return mapId == 0 || mapId == 1;
    }
}

enum mapFormat = "nxixssssssssxxxxxxxixxxxxxxxxxxxxxxxxxixxx"; ///

/// What kind of map a `Map.dbc` record is.
enum MapType : uint
{
    common = 0,
    instance = 1,
    raid = 2,
    battleground = 3,
}

/// `AreaTable.dbc`: zones and the areas inside them.
struct AreaTableEntry
{
    uint id;
    uint mapId;
    uint zone;        /// the zone an area is part of; 0 for a zone
    uint exploreFlag;
    uint flags;
    int areaLevel;
    string[8] name;
    uint team;
    uint liquidTypeOverride;
}

enum areaTableFormat = "niiiixxxxxissssssssxixxxi"; ///

/// `AreaTrigger.dbc`: a sphere (radius) or a box the client reports entering.
struct AreaTriggerEntry
{
    uint id;
    uint mapId;
    float x = 0;
    float y = 0;
    float z = 0;
    float radius = 0;
    float boxX = 0;
    float boxY = 0;
    float boxZ = 0;
    float boxOrientation = 0;

    /// Whether a point on `map` is inside, give or take `delta` yards.
    bool contains(uint map, float px, float py, float pz, float delta) const pure nothrow @nogc @safe
    {
        import std.math : abs, cos, PI, sin;

        if (map != mapId)
            return false;
        if (radius > 0)
            return (px - x) ^^ 2 + (py - y) ^^ 2 + (pz - z) ^^ 2 <= (radius + delta) ^^ 2;
        // A box: turn the point instead of the box, then compare each axis.
        const rotation = 2 * PI - boxOrientation;
        const dx = px - x, dy = py - y;
        const rotatedX = dx * cos(rotation) - dy * sin(rotation);
        const rotatedY = dy * cos(rotation) + dx * sin(rotation);
        return abs(rotatedX) <= boxX / 2 + delta && abs(rotatedY) <= boxY / 2 + delta
            && abs(pz - z) <= boxZ / 2 + delta;
    }
}

enum areaTriggerFormat = "niffffffff"; ///

/// `ChatChannels.dbc`: the built-in channels (General, Trade, LocalDefense, ...).
struct ChatChannelsEntry
{
    uint channelId;
    uint flags;       /// the channel's flags in the DBC
    string[8] pattern; /// "General - %s"
}

enum chatChannelsFormat = "iixssssssssxxxxxxxxxx"; ///

///
struct BankBagSlotPricesEntry
{
    uint id;
    uint price;
}

enum bankBagSlotPricesFormat = "ni"; ///

/// `StableSlotPrices.dbc`: what the stable slot of each number costs.
struct StableSlotPricesEntry
{
    uint id;
    uint price;
}

enum stableSlotPricesFormat = "ni"; ///

/// `CreatureFamily.dbc`: a beast family's size by level, its pets' skill lines (their passive spells), and what its
/// pets eat.
struct CreatureFamilyEntry
{
    uint id;
    float minScale = 0;
    uint minScaleLevel;
    float maxScale = 0;
    uint maxScaleLevel;
    uint[2] skillLines; /// "Pet - Wolf", "Pet - Generic" (0: none)
    uint petFoodMask;
    string name;
}

enum creatureFamilyFormat = "nfifiiiisxxxxxxxxx"; ///

///
struct DurabilityCostsEntry
{
    uint itemLevel;
    uint[29] multiplier; /// by weapon sub-class, then armor sub-class + 21
}

enum durabilityCostsFormat = "niiiiiiiiiiiiiiiiiiiiiiiiiiiii"; ///

///
struct DurabilityQualityEntry
{
    uint id;
    float qualityMod;
}

enum durabilityQualityFormat = "nf"; ///

/// A `LiquidType.dbc` record.
struct LiquidTypeEntry
{
    uint id;
    uint liquidId;
    uint type;    /// 0 magma, 2 slime, 3 water: which liquid-type bit of the `.map` files it sets
    uint spellId;
}

enum liquidTypeFormat = "niii"; ///

/// `WMOAreaTableEntry`: the area a building group belongs to.
struct WmoAreaTableEntry
{
    uint id;
    int rootId;   /// the building's WMO id
    int adtId;    /// the name set its placement gives
    int groupId;  /// the group's WMO id
    uint flags;
    uint areaId;  /// `AreaTable.dbc`; 0 to take the land's
    string[8] name;
}

enum wmoAreaTableFormat = "niiixxxxxiissssssssx"; ///

/// Talent and rank a spell belongs to.
struct TalentSpellPos
{
    uint talentId;
    uint rank; /// 0-based
}

// ---------------------------------------------------------------------------
// The loaded data and its indexes
// ---------------------------------------------------------------------------

/// On a `DbcStore` field of `ClientData`: the file (`name`.dbc) it is read from.
struct DbcFile
{
    string name;
}

private enum isDbcStore(T) = is(T == DbcStore!(E, format), E, string format);

/// See the module documentation.
/// One effect's coefficient as Blizzard's data has it, with what the effect is there (to tell a rebuilt one).
struct SpellCoefficient
{
    bool known; /// the data has this effect
    ushort effect, aura;
    float value = 0;
}

/**
 * One aura's proc data as Classic Era's SpellAuraOptions has it. Its type mask is the later encoding: bits 0 to 20
 * mean what 1.12's `ProcFlags` bits mean, the others are later events (`dmangos.world.procs.procFlagsOf`).
 */
struct ProcOptions
{
    uint typeMask;   /// `ProcTypeMask_0`
    uint typeMask1;  /// `ProcTypeMask_1`
    uint chance;     /// `ProcChance`, percent (101: none of its own)
    uint recovery;   /// `ProcCategoryRecovery`: milliseconds before it may proc again
    uint charges;    /// `ProcCharges`
}

final class ClientData
{
    @DbcFile("CharSections") DbcStore!(CharSectionsEntry, charSectionsFormat) charSections;
    @DbcFile("CharacterFacialHairStyles") DbcStore!(CharacterFacialHairStylesEntry, characterFacialHairStylesFormat) facialHairStyles;
    @DbcFile("ChrClasses") DbcStore!(ChrClassesEntry, chrClassesFormat) classes;
    @DbcFile("ChrRaces") DbcStore!(ChrRacesEntry, chrRacesFormat) races;
    @DbcFile("CharStartOutfit") DbcStore!(CharStartOutfitEntry, charStartOutfitFormat) startOutfits;
    @DbcFile("SkillLine") DbcStore!(SkillLineEntry, skillLineFormat) skillLines;
    @DbcFile("SkillLineAbility") DbcStore!(SkillLineAbilityEntry, skillLineAbilityFormat) skillLineAbilities;
    @DbcFile("SkillRaceClassInfo") DbcStore!(SkillRaceClassInfoEntry, skillRaceClassInfoFormat) skillRaceClassInfos;
    @DbcFile("SkillTiers") DbcStore!(SkillTiersEntry, skillTiersFormat) skillTiers;
    @DbcFile("Talent") DbcStore!(TalentEntry, talentFormat) talents;
    @DbcFile("ItemSet") DbcStore!(ItemSetEntry, itemSetFormat) itemSets;
    @DbcFile("TalentTab") DbcStore!(TalentTabEntry, talentTabFormat) talentTabs;
    @DbcFile("CreatureDisplayInfo") DbcStore!(CreatureDisplayInfoEntry, creatureDisplayInfoFormat) creatureDisplays;
    @DbcFile("CreatureModelData") DbcStore!(CreatureModelDataEntry, creatureModelDataFormat) creatureModels;
    @DbcFile("EmotesText") DbcStore!(EmotesTextEntry, emotesTextFormat) emotesText;
    @DbcFile("Emotes") DbcStore!(EmotesEntry, emotesFormat) emotes;
    @DbcFile("Map") DbcStore!(MapEntry, mapFormat) maps;
    @DbcFile("AreaTable") DbcStore!(AreaTableEntry, areaTableFormat) areas;
    @DbcFile("AreaTrigger") DbcStore!(AreaTriggerEntry, areaTriggerFormat) areaTriggers;
    @DbcFile("ChatChannels") DbcStore!(ChatChannelsEntry, chatChannelsFormat) chatChannels;
    @DbcFile("BankBagSlotPrices") DbcStore!(BankBagSlotPricesEntry, bankBagSlotPricesFormat) bankBagSlotPrices;
    @DbcFile("StableSlotPrices") DbcStore!(StableSlotPricesEntry, stableSlotPricesFormat) stableSlotPrices;
    @DbcFile("CreatureFamily") DbcStore!(CreatureFamilyEntry, creatureFamilyFormat) creatureFamilies;
    @DbcFile("DurabilityCosts") DbcStore!(DurabilityCostsEntry, durabilityCostsFormat) durabilityCosts;
    @DbcFile("DurabilityQuality") DbcStore!(DurabilityQualityEntry, durabilityQualityFormat) durabilityQualities;
    @DbcFile("LiquidType") DbcStore!(LiquidTypeEntry, liquidTypeFormat) liquidTypes;
    @DbcFile("WMOAreaTable") DbcStore!(WmoAreaTableEntry, wmoAreaTableFormat) wmoAreas;
    @DbcFile("Faction") DbcStore!(FactionEntry, factionFormat) factions;
    @DbcFile("Lock") DbcStore!(LockEntry, lockFormat) locks;
    @DbcFile("MailTemplate") DbcStore!(MailTemplateEntry, mailTemplateFormat) mailTemplates;
    @DbcFile("TaxiNodes") DbcStore!(TaxiNodesEntry, taxiNodesFormat) taxiNodes;
    @DbcFile("TaxiPath") DbcStore!(TaxiPathEntry, taxiPathFormat) taxiPaths;
    @DbcFile("TaxiPathNode") DbcStore!(TaxiPathNodeEntry, taxiPathNodeFormat) taxiPathNodes;
    /// The taxi network: from -> to -> path; each path's points in order; the nodes flown from or to.
    uint[uint][uint] taxiPathBetween;
    /// Blizzard's spell power coefficients by spell (data/coefficients.csv, tools/fetch-coefficients.py): what each
    /// effect of it gets of the caster's spell power. Empty without the file: the 1.12 formula then (`bonusCoefficient`).
    SpellCoefficient[3][uint] spellCoefficients;
    /// Blizzard's reset interval of each instanced map (data/instance-resets.csv, tools/fetch-instance-resets.py:
    /// MapDifficulty's `ResetInterval`, see `resetIntervalDays`). Empty without the file: `instance_template` then.
    ubyte[uint] instanceResets;
    /// Blizzard's proc data of each aura that procs (data/procs.csv, tools/fetch-procs.py: SpellAuraOptions). Empty
    /// without the file: the world database's `spell_proc_event` then (`dmangos.world.procs.procRule`).
    ProcOptions[uint] procOptions;
    const(TaxiPathNodeEntry)*[][uint] taxiPathPoints;
    bool[uint] taxiNetwork;
    @DbcFile("AuctionHouse") DbcStore!(AuctionHouseEntry, auctionHouseFormat) auctionHouses;
    @DbcFile("FactionTemplate") DbcStore!(FactionTemplateEntry, factionTemplateFormat) factionTemplates;
    @DbcFile("WorldSafeLocs") DbcStore!(WorldSafeLocsEntry, worldSafeLocsFormat) worldSafeLocs;
    @DbcFile("ItemRandomProperties") DbcStore!(ItemRandomPropertiesEntry, itemRandomPropertiesFormat) itemRandomProperties;
    @DbcFile("SpellItemEnchantment") DbcStore!(SpellItemEnchantmentEntry, spellItemEnchantmentFormat) spellItemEnchantments;
    @DbcFile("SpellCastTimes") DbcStore!(SpellCastTimesEntry, spellCastTimesFormat) spellCastTimes;
    @DbcFile("SpellDuration") DbcStore!(SpellDurationEntry, spellDurationFormat) spellDurations;
    @DbcFile("SpellRange") DbcStore!(SpellRangeEntry, spellRangeFormat) spellRanges;
    @DbcFile("SpellShapeshiftForm") DbcStore!(SpellShapeshiftFormEntry, spellShapeshiftFormFormat) spellShapeshiftForms;
    @DbcFile("SpellRadius") DbcStore!(SpellRadiusEntry, spellRadiusFormat) spellRadii;

    private
    {
        const(CharSectionsEntry)*[][uint] sectionsByKey;
        const(CharacterFacialHairStylesEntry)*[uint] facialHairByKey;
        const(SkillRaceClassInfoEntry)*[][uint] raceClassInfoBySkill;
        const(SkillLineAbilityEntry)*[][uint] abilitiesBySpell;
        const(SkillLineAbilityEntry)*[][uint] abilitiesBySkill;
        TalentSpellPos[uint] talentSpellPositions;
        const(AreaTableEntry)*[][uint] areasByFlag; // explore flag -> areas, ascending ids
        uint[uint] areaFlagByMap;                   // `sAreaFlagByMapID`
        const(WmoAreaTableEntry)*[][int[3]] wmoAreasByTriple; // `sWMOAreaInfoByTripple`
    }

    /// Reads the DBC files from `<dataDir>/dbc/`.
    static ClientData load(string dataDir)
    {
        import std.traits : getUDAs;

        auto data = new ClientData;
        const dir = buildPath(dataDir, "dbc");
        // Each store, from the file its `DbcFile` names.
        static foreach (i, field; data.tupleof)
            static if (isDbcStore!(typeof(field)))
            {
                static assert(getUDAs!(data.tupleof[i], DbcFile).length == 1,
                    __traits(identifier, data.tupleof[i]) ~ " needs a @DbcFile naming the file it is read from");
                data.tupleof[i] = typeof(field).load(buildPath(dir, getUDAs!(data.tupleof[i], DbcFile)[0].name ~ ".dbc"));
            }
        data.buildIndexes();
        data.loadCoefficients(buildPath(dataDir, "coefficients.csv"));
        data.loadInstanceResets(buildPath(dataDir, "instance-resets.csv"));
        data.loadProcs(buildPath(dataDir, "procs.csv"));
        info!"loaded client data from %s (%s races, %s classes, %s skill lines, %s skill abilities)"(dir,
            data.races.rows.length, data.classes.rows.length, data.skillLines.rows.length,
            data.skillLineAbilities.rows.length);
        return data;
    }

    /**
     * The spell power coefficients of `path` (`spell,effect index,effect,aura,coefficient` a line, `#` comments), if
     * it is there.
     */
    void loadCoefficients(string path)
    {
        import std.array : split;
        import std.conv : to;
        import std.file : exists, readText;
        import std.string : lineSplitter, strip;

        if (!exists(path))
        {
            warning!"no %s (tools/fetch-coefficients.py): spell power by the 1.12 formula"(path);
            return;
        }
        foreach (line; readText(path).lineSplitter)
        {
            line = line.strip;
            if (line.length == 0 || line[0] == '#')
                continue;
            const f = line.split(",");
            const index = f[1].to!uint;
            if (f.length != 5 || index > 2)
                continue;
            const spell = f[0].to!uint;
            if (spell !in spellCoefficients)
                spellCoefficients[spell] = (SpellCoefficient[3]).init;
            spellCoefficients[spell][index] = SpellCoefficient(true, f[2].to!ushort, f[3].to!ushort, f[4].to!float);
        }
        info!"spell power coefficients of %s spells from %s"(spellCoefficients.length, path);
    }

    /**
     * The proc data of `path` (`spell,proc type mask 0,proc type mask 1,proc chance,proc category recovery,proc
     * charges` a line, `#` comments), if it is there.
     */
    void loadProcs(string path)
    {
        import std.array : split;
        import std.conv : to;
        import std.file : exists, readText;
        import std.string : lineSplitter, strip;

        if (!exists(path))
        {
            warning!"no %s (tools/fetch-procs.py): proc cooldowns from spell_proc_event"(path);
            return;
        }
        foreach (line; readText(path).lineSplitter)
        {
            line = line.strip;
            if (line.length == 0 || line[0] == '#')
                continue;
            const f = line.split(",");
            if (f.length == 6)
                procOptions[f[0].to!uint] = ProcOptions(f[1].to!uint, f[2].to!uint, f[3].to!uint, f[4].to!uint,
                    f[5].to!uint);
        }
        info!"proc data of %s spells from %s"(procOptions.length, path);
    }

    /// The instance reset intervals of `path` (`map,reset interval,max players` a line, `#` comments), if it is there.
    void loadInstanceResets(string path)
    {
        import std.array : split;
        import std.conv : to;
        import std.file : exists, readText;
        import std.string : lineSplitter, strip;

        if (!exists(path))
        {
            warning!"no %s (tools/fetch-instance-resets.py): raid resets from instance_template"(path);
            return;
        }
        foreach (line; readText(path).lineSplitter)
        {
            line = line.strip;
            if (line.length == 0 || line[0] == '#')
                continue;
            const f = line.split(",");
            if (f.length == 3)
                instanceResets[f[0].to!uint] = f[1].to!ubyte;
        }
        info!"reset intervals of %s maps from %s"(instanceResets.length, path);
    }

    /**
     * How many days apart map `mapId`'s copies reset by Blizzard's data (docs/FORMULAS.md, "Raid resets"):
     * MapDifficulty's `ResetInterval` 1 a day, 2 a week, 3 three days, 4 five days; 0 when it never does (a
     * dungeon) or the data does not say (no file, or a map it lacks: `known` false).
     */
    uint resetIntervalDays(uint mapId, out bool known) const
    {
        static immutable uint[5] days = [0, 1, 7, 3, 5];
        const interval = mapId in instanceResets;
        known = interval !is null && *interval < days.length;
        return known ? days[*interval] : 0;
    }

    /// Builds the derived lookups. Call after filling the stores by hand (tests).
    void buildIndexes()
    {
        import std.algorithm.sorting : sort;

        // `sTaxiPathSetBySource`, `sTaxiPathNodesByPath`, `sTaxiNodesMask`.
        taxiPathBetween = null;
        taxiPathPoints = null;
        taxiNetwork = null;
        foreach (id; 0 .. taxiPaths.idLimit)
            if (const p = taxiPaths.lookup(id))
            {
                taxiPathBetween[p.from][p.to] = p.id;
                taxiNetwork[p.from] = true;
                taxiNetwork[p.to] = true;
            }
        foreach (ref row; taxiPathNodes.rows)
            taxiPathPoints[row.path] ~= &row;
        foreach (ref points; taxiPathPoints)
            points.sort!((a, b) => a.index < b.index);
        sectionsByKey = null;
        facialHairByKey = null;
        raceClassInfoBySkill = null;
        abilitiesBySpell = null;
        abilitiesBySkill = null;
        talentSpellPositions = null;
        areasByFlag = null;
        areaFlagByMap = null;
        wmoAreasByTriple = null;
        foreach (id; ascendingIds(wmoAreas.ids))
        {
            const entry = wmoAreas.lookup(id);
            wmoAreasByTriple[[entry.rootId, entry.adtId, entry.groupId]] ~= entry;
        }

        foreach (id; ascendingIds(areas.ids))
        {
            const area = areas.lookup(id);
            areasByFlag[area.exploreFlag] ~= area;
            // An instance's area, for maps without .map files (no sub-zones, no continents).
            if (area.zone == 0 && area.mapId != 0 && area.mapId != 1)
                areaFlagByMap.require(area.mapId, area.exploreFlag);
        }
        foreach (id; ascendingIds(charSections.ids))
        {
            const entry = charSections.lookup(id);
            if (entry.race && (maskOf(entry.race) & playableRaceMask))
                sectionsByKey[sectionKey(cast(ubyte) entry.race, entry.baseSection, cast(ubyte) entry.gender)] ~= entry;
        }
        foreach (id; ascendingIds(facialHairStyles.ids))
        {
            const entry = facialHairStyles.lookup(id);
            if (entry.raceId && (maskOf(entry.raceId) & playableRaceMask))
                facialHairByKey[entry.raceId | entry.sexId << 8 | entry.variationId << 16] = entry;
        }
        foreach (id; ascendingIds(skillRaceClassInfos.ids))
        {
            const entry = skillRaceClassInfos.lookup(id);
            if (skillLines.lookup(entry.skillId) !is null)
                raceClassInfoBySkill[entry.skillId] ~= entry;
        }
        foreach (id; ascendingIds(skillLineAbilities.ids))
        {
            const entry = skillLineAbilities.lookup(id);
            abilitiesBySpell[entry.spellId] ~= entry;
            abilitiesBySkill[entry.skillId] ~= entry;
        }
        foreach (id; ascendingIds(talents.ids))
        {
            const talent = talents.lookup(id);
            foreach (rank, spell; talent.rankId)
                if (spell)
                    talentSpellPositions[spell] = TalentSpellPos(id, cast(uint) rank);
        }
    }

    /**
     * The area whose explore flag a map cell holds. 1.12's
     * `AreaTable.dbc` repeats flags, so the one on `map` is taken, else the last other one, else
     * the map's own zone.
     */
    const(AreaTableEntry)* areaByFlag(uint flag, uint map) const
    {
        const(AreaTableEntry)* found;
        if (flag != 0)
            foreach (area; areasByFlag.get(flag, null))
            {
                if (area.mapId == map)
                    return area;
                found = area;
            }
        if (found !is null)
            return found;
        if (const entry = maps.lookup(map))
            return areas.lookup(entry.linkedZone);
        return null;
    }

    /// The areas of a building group, by root, placement name set and group.
    const(WmoAreaTableEntry*)[] wmoAreasOf(int rootId, int adtId, int groupId) const
    {
        return wmoAreasByTriple.get([rootId, adtId, groupId], null);
    }

    /// The explore flag of an instance's area; 0 if it has none.
    uint areaFlagOfMap(uint map) const
    {
        return areaFlagByMap.get(map, 0);
    }

    /// An available section of a type, variation and color, or null.
    const(CharSectionsEntry)* charSection(ubyte race, CharSectionType type, ubyte gender, ubyte variation,
        ubyte color) const
    {
        foreach (entry; sectionsByKey.get(sectionKey(race, type, gender), null))
            if (entry.variationIndex == variation && entry.colorIndex == color
                && !(entry.flags & sectionFlagUnavailable))
                return entry;
        return null;
    }

    /// The facial hair style `facialHairId` of a race and gender, or null.
    const(CharacterFacialHairStylesEntry)* facialHair(ubyte race, ubyte gender, ubyte facialHairId) const
    {
        if (auto entry = (race | gender << 8 | facialHairId << 16) in facialHairByKey)
            return *entry;
        return null;
    }

    /// The `SkillRaceClassInfo.dbc` records of a skill.
    const(SkillRaceClassInfoEntry*)[] raceClassInfo(uint skillId) const
    {
        return raceClassInfoBySkill.get(skillId, null);
    }

    /// The `SkillLineAbility.dbc` records of a spell.
    const(SkillLineAbilityEntry*)[] abilitiesForSpell(uint spellId) const
    {
        return abilitiesBySpell.get(spellId, null);
    }

    /// The `SkillLineAbility.dbc` records of a skill.
    const(SkillLineAbilityEntry*)[] abilitiesForSkill(uint skillId) const
    {
        return abilitiesBySkill.get(skillId, null);
    }

    /// Every spell id that has a SkillLineAbility entry, ascending.
    uint[] spellsWithAbilities() const
    {
        return abilitiesBySpell.keys.sort().release;
    }

    /// The object scale of a display: the display's scale times its model's; 1 if unknown.
    float displayScale(uint displayId) const
    {
        const display = creatureDisplays.lookup(displayId);
        if (display is null)
            return 1;
        const model = creatureModels.lookup(display.modelId);
        return model is null ? display.scale : display.scale * model.scale;
    }

    /// `CreatureModelData.CollisionHeight` of a display's model, unscaled; 0 if unknown.
    float collisionHeight(uint displayId) const
    {
        if (const display = creatureDisplays.lookup(displayId))
            if (const model = creatureModels.lookup(display.modelId))
                return model.collisionHeight;
        return 0;
    }

        /// The talent and rank of a spell, or null if it is no talent's.
    const(TalentSpellPos)* talentSpellPos(uint spellId) const
    {
        return spellId in talentSpellPositions;
    }

    /**
     * The built-in channel a name belongs to, or null for a custom channel.
     * A pattern with `%s` matches any name containing the rest ("General - " in "General - Elwynn Forest").
     */
    const(ChatChannelsEntry)* chatChannelFor(string name) const
    {
        import std.algorithm.searching : canFind;
        import std.array : replace;
        import std.uni : toLower;

        if (name.length == 0)
            return null;
        const lowered = name.toLower;
        foreach (ref entry; chatChannels.rows)
            foreach (pattern; entry.pattern)
            {
                if (pattern.length == 0)
                    continue;
                const p = pattern.toLower;
                if (p.canFind("%s") ? lowered.canFind(p.replace("%s", "")) : lowered == p)
                    return &entry;
            }
        return null;
    }

    /// The English name of a zone or area, or null.
    string areaName(uint id) const
    {
        const area = areas.lookup(id);
        return area is null ? null : area.name[0];
    }

    /**
     * Whether a position is valid: a map the client has, and a finite position within its
     * 64 by 64 grids of 533.33 yards.
     */
    bool isValidMapCoord(uint map, float x, float y, float z, float orientation = 0) const
    {
        import std.math : abs, isFinite;

        enum float mapHalfSize = 32 * 533.3333f;
        return maps.lookup(map) !is null && x.isFinite && y.isFinite && z.isFinite && orientation.isFinite
            && abs(x) <= mapHalfSize - 0.5f && abs(y) <= mapHalfSize - 0.5f;
    }

    /// The team of a race: `Alliance` for TeamID 7, `Horde` for 1.
    Team teamForRace(ubyte race) const
    {
        if (auto entry = races.lookup(race))
        {
            if (entry.teamId == 7)
                return Team.alliance;
            if (entry.teamId == 1)
                return Team.horde;
            return Team.none;
        }
        return Team.alliance;
    }

    private static uint sectionKey(ubyte race, uint type, ubyte gender) pure nothrow @nogc @safe
    {
        return cast(ubyte) type | gender << 8 | race << 16;
    }

    private static uint[] ascendingIds(const(uint)[] ids)
    {
        return ids.dup.sort().release;
    }
}

/// `Team`
enum Team
{
    none,
    alliance,
    horde,
}

unittest
{
    auto data = new ClientData;
    const uint[][] sections = [
        [1, 1, 0, 0, 0, 2, 0, 0, 0, 0],  // human male skin, color 2
        [2, 1, 0, 3, 4, 1, 0, 0, 0, 0],  // human male hair 4, color 1
        [3, 1, 0, 3, 5, 1, 0, 0, 0, 1],  // hair 5 is unavailable
        [4, 10, 0, 0, 0, 0, 0, 0, 0, 0], // a non-playable race, ignored
    ];
    data.charSections = typeof(data.charSections).parse(buildDbc(charSectionsFormat, sections), "CharSections.dbc");
    data.buildIndexes();
    assert(data.charSection(1, CharSectionType.skin, 0, 0, 2) !is null);
    assert(data.charSection(1, CharSectionType.hair, 0, 4, 1) !is null);
    assert(data.charSection(1, CharSectionType.hair, 0, 5, 1) is null, "unavailable sections do not count");
    assert(data.charSection(1, CharSectionType.skin, 1, 0, 2) is null, "wrong gender");
    assert(maskOf(1) == 1 && maskOf(8) == 0x80 && maskOf(0) == 0);
}

// The load finds the stores by their type, and each names its file.
unittest
{
    import std.traits : getUDAs;

    static assert(isDbcStore!(typeof(ClientData.races)) && !isDbcStore!(typeof(ClientData.taxiNetwork)));
    static assert(getUDAs!(ClientData.races, DbcFile)[0].name == "ChrRaces");
}
