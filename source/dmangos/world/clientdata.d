/**
 * The client's DBC tables needed to create characters, plus the indexes
 * CMaNGOS builds from them (`Server/DBCStores.cpp`, `Spells/SpellMgr.cpp`).
 *
 * Every record struct follows CMaNGOS's `DBCStructure.h`, field for field,
 * with its format string from `DBCfmt.h`. `DbcStore` verifies the pair at
 * compile time. The files are read from `<data_dir>/dbc/`, the same layout
 * mangosd uses for its `DataDir`.
 *
 * Indexes iterate the stores in ascending id order, as CMaNGOS's
 * `for (i = 0; i < GetNumRows(); ++i) LookupEntry(i)` loops do, so
 * multimap order (which decides "first match" lookups) is the same.
 */
module dmangos.world.clientdata;

import std.algorithm.sorting : sort;
import std.path : buildPath;

import dmangos.dbc;
import dmangos.log;

/// Bitmask of the eight playable 1.12 races (`RACEMASK_ALL_PLAYABLE`).
enum uint playableRaceMask = 0xFF;
/// Bitmask of the nine playable 1.12 classes (`CLASSMASK_ALL_PLAYABLE`).
enum uint playableClassMask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 8)
    | (1 << 10);

/// `1 << (value - 1)`, as CMaNGOS's `convertEnumToFlag`.
uint maskOf(uint raceOrClass) pure nothrow @nogc @safe
{
    return raceOrClass ? 1u << (raceOrClass - 1) : 0;
}

/// `CharSectionType`
enum CharSectionType : uint
{
    skin = 0,
    face = 1,
    facialHair = 2,
    hair = 3,
    underwear = 4,
}

/// `SECTION_FLAG_UNAVAILABLE`
enum uint sectionFlagUnavailable = 0x01;

/// `SKILL_FLAG_MAXIMIZED`
enum uint skillFlagMaximized = 0x010;

/// `MAX_SKILL_STEP`
enum maxSkillStep = 16;

// ---------------------------------------------------------------------------
// Records (DBCStructure.h) with their formats (DBCfmt.h)
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

/// `CreatureDisplayInfoEntry`
struct CreatureDisplayInfoEntry
{
    uint id;
    uint modelId;
    uint extendedDisplayInfoId;
    float scale = 0;
}

enum creatureDisplayInfoFormat = "nixifxxxxxxx"; ///

/// `CreatureModelDataEntry`
struct CreatureModelDataEntry
{
    uint id;
    uint flags;
    float scale = 0;
    float collisionWidth = 0;
    float collisionHeight = 0;
}

enum creatureModelDataFormat = "nixxfxxxxxxxxxff"; ///

/// `EmotesTextEntry`: what a text emote (/wave) animates.
struct EmotesTextEntry
{
    uint id;
    uint emote; /// `Emotes.dbc` id; 0 for none
}

enum emotesTextFormat = "nxixxxxxxxxxxxxxxxx"; ///

/// `EmotesEntry`
struct EmotesEntry
{
    uint id;
    uint flags;
    uint emoteType; /// 0 a one-shot animation; 1 and 2 a state that lasts (dancing)
    uint standState;
}

enum emotesFormat = "nxxiiix"; ///

/// Number of item slots in a starting outfit (`MAX_OUTFIT_ITEMS`).
enum maxOutfitItems = 12;

/**
 * In the 1.12 file, race, class, gender and outfit are four one-byte fields.
 * CMaNGOS reads them as one 32-bit `RaceClassGender` field. That works only
 * because its loader never checks the record size, and the skipped fields
 * after it absorb the difference. Here the layout is exact, and
 * `raceClassGender` rebuilds the value CMaNGOS compares against.
 */
struct CharStartOutfitEntry
{
    ubyte race;
    ubyte classId;
    ubyte gender;
    ubyte outfit;
    int[maxOutfitItems] itemId;

    /// race | class << 8 | gender << 16 | outfit << 24, as CMaNGOS's `RaceClassGender`.
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

/// `FactionTemplateEntry`: how a unit of a faction stands to others (`dmangos.world.relations`).
struct FactionTemplateEntry
{
    uint id;
    uint faction;
    uint flags;
    uint groupMask;          /// `FactionGroupMask` of the groups this one is in
    uint friendGroupMask;    /// groups it is friendly to
    uint enemyGroupMask;     /// groups it is hostile to
    uint[4] enemyFactions;
    uint[4] friendFactions;
}

enum factionTemplateFormat = "niiiiiiiiiiiii"; ///

/// `WorldSafeLocsEntry`: a graveyard (or other safe place) where ghosts appear.
struct WorldSafeLocsEntry
{
    uint id;
    uint map;
    float x = 0, y = 0, z = 0;
}

enum worldSafeLocsFormat = "nifffxxxxxxxxx"; ///

/// `SpellCastTimesEntry`: a cast time, in milliseconds.
struct SpellCastTimesEntry
{
    uint id;
    int castTime;
    int perLevel;
    int minimum;
}

enum spellCastTimesFormat = "niii"; ///

/// `SpellDurationEntry`: how long an aura lasts, in milliseconds (-1: until cancelled).
struct SpellDurationEntry
{
    uint id;
    int duration;
    int perLevel;
    int maximum;
}

enum spellDurationFormat = "niii"; ///

/// `SpellRangeEntry`
struct SpellRangeEntry
{
    uint id;
    float minRange;
    float maxRange;
    uint flags;
}

enum spellRangeFormat = "nffixxxxxxxxxxxxxxxxxx"; ///

/// `SpellRadiusEntry`
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

/// Ranks a talent can have (`MAX_TALENT_RANK`).
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

///
struct TalentTabEntry
{
    uint tabId;
    uint classMask;
    uint tabPage;
}

enum talentTabFormat = "nxxxxxxxxxxxiix"; ///

/// `MapEntry`
struct MapEntry
{
    uint mapId;
    uint mapType;    /// `MapTypes`
    string[8] name;
    uint linkedZone;
    uint multimapId;

    /// `MapEntry::IsDungeon`: an instance or a raid.
    @property bool isDungeon() const pure nothrow @nogc @safe
    {
        return mapType == MapType.instance || mapType == MapType.raid;
    }

    /// `MapEntry::IsRaid`
    @property bool isRaid() const pure nothrow @nogc @safe
    {
        return mapType == MapType.raid;
    }

    /// `MapEntry::IsBattleGround`
    @property bool isBattleground() const pure nothrow @nogc @safe
    {
        return mapType == MapType.battleground;
    }

    /// `MapEntry::IsContinent`: Eastern Kingdoms or Kalimdor.
    @property bool isContinent() const pure nothrow @nogc @safe
    {
        return mapId == 0 || mapId == 1;
    }
}

enum mapFormat = "nxixssssssssxxxxxxxixxxxxxxxxxxxxxxxxxixxx"; ///

/// `MapTypes`
enum MapType : uint
{
    common = 0,
    instance = 1,
    raid = 2,
    battleground = 3,
}

/// `AreaTableEntry`: zones and the areas inside them.
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

/// `AreaTriggerEntry`: a sphere (radius) or a box the client reports entering.
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

    /// `IsPointInAreaTriggerZone`: whether a point on `map` is inside, give or take `delta` yards.
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

/// `ChatChannelsEntry`: the built-in channels (General, Trade, LocalDefense, ...).
struct ChatChannelsEntry
{
    uint channelId;
    uint flags;       /// `ChannelDBCFlags`
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

/// `LiquidTypeEntry`
struct LiquidTypeEntry
{
    uint id;
    uint liquidId;
    uint type;    /// 0 magma, 2 slime, 3 water: the bit of `MAP_LIQUID_TYPE_*` it sets
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

/// Talent and rank a spell belongs to (`TalentSpellPos`).
struct TalentSpellPos
{
    uint talentId;
    uint rank; /// 0-based
}

// ---------------------------------------------------------------------------
// The loaded data and its indexes
// ---------------------------------------------------------------------------

/// See the module documentation.
final class ClientData
{
    DbcStore!(CharSectionsEntry, charSectionsFormat) charSections;
    DbcStore!(CharacterFacialHairStylesEntry, characterFacialHairStylesFormat) facialHairStyles;
    DbcStore!(ChrClassesEntry, chrClassesFormat) classes;
    DbcStore!(ChrRacesEntry, chrRacesFormat) races;
    DbcStore!(CharStartOutfitEntry, charStartOutfitFormat) startOutfits;
    DbcStore!(SkillLineEntry, skillLineFormat) skillLines;
    DbcStore!(SkillLineAbilityEntry, skillLineAbilityFormat) skillLineAbilities;
    DbcStore!(SkillRaceClassInfoEntry, skillRaceClassInfoFormat) skillRaceClassInfos;
    DbcStore!(SkillTiersEntry, skillTiersFormat) skillTiers;
    DbcStore!(TalentEntry, talentFormat) talents;
    DbcStore!(TalentTabEntry, talentTabFormat) talentTabs;
    DbcStore!(CreatureDisplayInfoEntry, creatureDisplayInfoFormat) creatureDisplays;
    DbcStore!(CreatureModelDataEntry, creatureModelDataFormat) creatureModels;
    DbcStore!(EmotesTextEntry, emotesTextFormat) emotesText;
    DbcStore!(EmotesEntry, emotesFormat) emotes;
    DbcStore!(MapEntry, mapFormat) maps;
    DbcStore!(AreaTableEntry, areaTableFormat) areas;
    DbcStore!(AreaTriggerEntry, areaTriggerFormat) areaTriggers;
    DbcStore!(ChatChannelsEntry, chatChannelsFormat) chatChannels;
    DbcStore!(BankBagSlotPricesEntry, bankBagSlotPricesFormat) bankBagSlotPrices;
    DbcStore!(DurabilityCostsEntry, durabilityCostsFormat) durabilityCosts;
    DbcStore!(DurabilityQualityEntry, durabilityQualityFormat) durabilityQualities;
    DbcStore!(LiquidTypeEntry, liquidTypeFormat) liquidTypes;
    DbcStore!(WmoAreaTableEntry, wmoAreaTableFormat) wmoAreas;
    DbcStore!(FactionEntry, factionFormat) factions;
    DbcStore!(FactionTemplateEntry, factionTemplateFormat) factionTemplates;
    DbcStore!(WorldSafeLocsEntry, worldSafeLocsFormat) worldSafeLocs;
    DbcStore!(SpellCastTimesEntry, spellCastTimesFormat) spellCastTimes;
    DbcStore!(SpellDurationEntry, spellDurationFormat) spellDurations;
    DbcStore!(SpellRangeEntry, spellRangeFormat) spellRanges;
    DbcStore!(SpellRadiusEntry, spellRadiusFormat) spellRadii;

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
        import std.algorithm.searching : findSplit;

        auto data = new ClientData;
        const dir = buildPath(dataDir, "dbc");
        static foreach (member; ["charSections:CharSections", "facialHairStyles:CharacterFacialHairStyles",
            "classes:ChrClasses", "races:ChrRaces", "startOutfits:CharStartOutfit", "skillLines:SkillLine",
            "skillLineAbilities:SkillLineAbility", "skillRaceClassInfos:SkillRaceClassInfo", "skillTiers:SkillTiers",
            "talents:Talent", "talentTabs:TalentTab", "creatureDisplays:CreatureDisplayInfo",
            "creatureModels:CreatureModelData", "emotesText:EmotesText", "emotes:Emotes", "maps:Map",
            "areas:AreaTable", "areaTriggers:AreaTrigger", "chatChannels:ChatChannels",
            "bankBagSlotPrices:BankBagSlotPrices", "durabilityCosts:DurabilityCosts",
            "durabilityQualities:DurabilityQuality", "liquidTypes:LiquidType", "wmoAreas:WMOAreaTable",
            "factions:Faction", "factionTemplates:FactionTemplate", "worldSafeLocs:WorldSafeLocs", "spellCastTimes:SpellCastTimes", "spellDurations:SpellDuration",
            "spellRanges:SpellRange", "spellRadii:SpellRadius"])
        {{
            enum parts = member.findSplit(":");
            enum field = parts[0];
            enum file = parts[2] ~ ".dbc";
            __traits(getMember, data, field) = typeof(__traits(getMember, data, field)).load(buildPath(dir, file));
        }}
        data.buildIndexes();
        info!"loaded client data from %s (%s races, %s classes, %s skill lines, %s skill abilities)"(dir,
            data.races.rows.length, data.classes.rows.length, data.skillLines.rows.length,
            data.skillLineAbilities.rows.length);
        return data;
    }

    /// Builds the derived lookups. Call after filling the stores by hand (tests).
    void buildIndexes()
    {
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
     * `GetAreaEntryByAreaFlagAndMap`: the area whose explore flag a map cell holds. 1.12's
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

    /// `GetWMOAreaTableEntriesByTripple`: the areas of a building group, by root, placement name set and group.
    const(WmoAreaTableEntry*)[] wmoAreasOf(int rootId, int adtId, int groupId) const
    {
        return wmoAreasByTriple.get([rootId, adtId, groupId], null);
    }

    /// `GetAreaFlagByMapId`: the explore flag of an instance's area; 0 if it has none.
    uint areaFlagOfMap(uint map) const
    {
        return areaFlagByMap.get(map, 0);
    }

    /// `GetCharSectionEntry`: an available section of a type, variation and color, or null.
    const(CharSectionsEntry)* charSection(ubyte race, CharSectionType type, ubyte gender, ubyte variation,
        ubyte color) const
    {
        foreach (entry; sectionsByKey.get(sectionKey(race, type, gender), null))
            if (entry.variationIndex == variation && entry.colorIndex == color
                && !(entry.flags & sectionFlagUnavailable))
                return entry;
        return null;
    }

    /// `GetCharFacialHairEntry`
    const(CharacterFacialHairStylesEntry)* facialHair(ubyte race, ubyte gender, ubyte facialHairId) const
    {
        if (auto entry = (race | gender << 8 | facialHairId << 16) in facialHairByKey)
            return *entry;
        return null;
    }

    /// `GetSkillRaceClassInfoMapBounds`
    const(SkillRaceClassInfoEntry*)[] raceClassInfo(uint skillId) const
    {
        return raceClassInfoBySkill.get(skillId, null);
    }

    /// `GetSkillLineAbilityMapBoundsBySpellId`
    const(SkillLineAbilityEntry*)[] abilitiesForSpell(uint spellId) const
    {
        return abilitiesBySpell.get(spellId, null);
    }

    /// `GetSkillLineAbilityMapBoundsBySkillId`
    const(SkillLineAbilityEntry*)[] abilitiesForSkill(uint skillId) const
    {
        return abilitiesBySkill.get(skillId, null);
    }

    /// Every spell id that has a SkillLineAbility entry, ascending (CMaNGOS's multimap order).
    uint[] spellsWithAbilities() const
    {
        return abilitiesBySpell.keys.sort().release;
    }

    /// `displayInfo->scale * modelData->Scale`, as `Player::InitDisplayIds` sets the object scale; 1 if unknown.
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

        /// `GetTalentSpellPos`
    const(TalentSpellPos)* talentSpellPos(uint spellId) const
    {
        return spellId in talentSpellPositions;
    }

    /**
     * `GetChatChannelsEntryFor`: the built-in channel a name belongs to, or null for a custom channel.
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
     * `MapManager::IsValidMapCoord`: a map the client has, and a finite position within its
     * 64 by 64 grids of 533.33 yards.
     */
    bool isValidMapCoord(uint map, float x, float y, float z, float orientation = 0) const
    {
        import std.math : abs, isFinite;

        enum float mapHalfSize = 32 * 533.3333f;
        return maps.lookup(map) !is null && x.isFinite && y.isFinite && z.isFinite && orientation.isFinite
            && abs(x) <= mapHalfSize - 0.5f && abs(y) <= mapHalfSize - 0.5f;
    }

    /// The team of a race: `Alliance` for TeamID 7, `Horde` for 1 (`Player::TeamForRace`).
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
