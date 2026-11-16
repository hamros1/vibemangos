/**
 * Character creation: a port of CMaNGOS's `Player::Create`, limited to what
 * ends up in the database.
 *
 * `CharacterBuilder` keeps only the parts of CMaNGOS's `Player` state that
 * creation touches: spells, skills, inventory, ammo and dual wielding. It
 * runs the same steps in the same order:
 * $(OL
 *   $(LI start position, appearance, level, money;)
 *   $(LI stats for the level, then health and mana from stamina and intellect;)
 *   $(LI the race's starting taxi nodes;)
 *   $(LI default skills (`LearnDefaultSkills`) and spells (`learnDefaultSpells` -> `addSpell`),
 *        including the skills and spells each of them teaches in turn;)
 *   $(LI default action bars;)
 *   $(LI the starting outfit (`CharStartOutfit.dbc`) and `playercreateinfo_item`, equipped where
 *        possible, then everything in the backpack equipped or moved to its best place.)
 * )
 *
 * The result is a `NewCharacter`, the rows CMaNGOS's `SaveToDB` would write.
 *
 * `CharacterBuilder.loadAbilities` runs the skill and spell part of
 * `Player::LoadFromDB` with the same machinery, for a character entering the
 * world.
 *
 * Like CMaNGOS, this saves only spells learned as non-dependent (default
 * spells are re-learned at every login), and no reputations (they are
 * initialized at the first login). Passive spells are "cast" only for the
 * effects that persist (learning a spell or a skill step) and for dual
 * wielding, which decides where weapons can go. Their auras do not change
 * what is saved: health is stored before any spell is learned.
 */
module dmangos.world.playercreate;

import std.algorithm.comparison : max, min;
import std.algorithm.mutation : remove;
import std.conv : to;
import std.math : round;

import dmangos.auth.accounts : AccountLevel;
import dmangos.log;
import dmangos.world.clientdata;
public import dmangos.world.defines; // the inventory positions are part of this module's interface
import dmangos.world.spells;
import dmangos.world.stats : healthBonusFromStamina, manaBonusFromIntellect;
import dmangos.world.updatefields : maxPlayerSkills;
import dmangos.world.worlddata;

// ---------------------------------------------------------------------------
// Constants (SharedDefines.h, Player.h, ItemPrototype.h)
// ---------------------------------------------------------------------------

private enum : uint
{
    itemSubclassFood = 5, itemSubclassContainer = 0, itemSubclassSoulContainer = 1, itemSubclassHerbContainer = 2,
    itemSubclassEnchantingContainer = 3, itemSubclassEngineeringContainer = 4,
    itemSubclassQuiver = 2, itemSubclassAmmoPouch = 3, itemSubclassWeaponFist = 13,
    itemSubclassArmorMisc = 0, itemSubclassArmorLibram = 7, itemSubclassArmorIdol = 8, itemSubclassArmorTotem = 9,
    bagFamilyArrows = 1, bagFamilyBullets = 2, bagFamilySoulShards = 3, bagFamilyHerbs = 6,
    bagFamilyEnchantingSupp = 7, bagFamilyEngineeringSupp = 8, bagFamilyKeys = 9,
    bindWhenPickedUp = 1, bindWhenEquipped = 2, bindQuestItem = 4,
    itemFlagUniqueEquippable = 0x00080000,
}

private enum : uint
{
    skillPoisons = 40, skillLockpicking = 633, skillFistWeapons = 473, skillFishing = 356, skillCooking = 185,
    skillFirstAid = 129, skillRiding = 762,
    abilityLearnedOnGetRaceOrClassSkill = 2,
}


/// `TaxiMaskSize`
enum taxiMaskSize = 8;
/// `PLAYER_EXPLORED_ZONES_SIZE`
enum exploredZonesSize = 64;
/// `MAX_ENCHANTMENT_SLOT`
enum maxEnchantmentSlot = 7;
/// `AT_LOGIN_FIRST`
enum uint atLoginFirst = 0x20;

private enum uint powerRageDefault = 1000, powerEnergyDefault = 100;

/// `LevelUpKeyringSize`: keyring slots by level / 10.
private immutable uint[7] keyringSizeByLevel = [4, 4, 4, 4, 8, 12, 12];

/// Equip/store results (`InventoryResult`, subset). Only success matters to creation; the rest is for logs.
enum InventoryResult
{
    ok,
    itemNotFound,
    cantCarryMoreOfThis,
    itemCantBeEquipped,
    noEquipmentSlotAvailable,
    cantDualWield,
    cantEquipWithTwoHanded,
    noRequiredProficiency,
    cantEquipSkill,
    cantEquipLevel,
    youCanNeverUseThatItem,
    cantEquipRank,
    cantEquipReputation,
    canEquipOnlyOneQuiver,
    canEquipOnlyOneAmmoPouch,
    onlyAmmoCanGoHere,
    itemDoesntGoIntoBag,
    intBagError,
    itemCantStack,
    inventoryFull,
    nonEmptyBagOverOtherBag,
}

// ---------------------------------------------------------------------------
// Input and output
// ---------------------------------------------------------------------------

/// What the client asked for in `CMSG_CHAR_CREATE`, after the name was normalized.
struct CreateRequest
{
    string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    ubyte skin;
    ubyte face;
    ubyte hairStyle;
    ubyte hairColor;
    ubyte facialHair;
    ubyte outfitId;
}

/// Configuration that affects new characters (mangosd.conf equivalents in parentheses).
struct CreationSettings
{
    uint startPlayerLevel = 1;          /// `StartPlayerLevel`
    uint startGmLevel = 1;              /// `GM.StartLevel`, for accounts of moderator level and up
    uint startPlayerMoney = 0;          /// `StartPlayerMoney`
    uint maxPrimaryTradeSkill = 2;      /// `MaxPrimaryTradeSkill`
    uint gmIgnoreMaxPrimarySkills = 4;  /// `TradeSkill.GMIgnore.MaxPrimarySkillsCount`
}

/// One item of a new character, as `item_instance` and `character_inventory` store it.
struct NewItem
{
    uint guid;
    uint entry;
    uint count;
    uint duration;
    int[5] charges;
    uint flags;        /// `ITEM_DYNFLAG_BINDED` if bound
    uint durability;
    uint containerGuid; /// the bag it is in, 0 for the backpack and equipment
    ubyte slot;
}

/// One `character_skills` row.
struct NewSkill
{
    uint skill;
    uint value;
    uint max;
}

/// One `character_spell` row.
struct NewSpell
{
    uint spell;
    bool active;
    bool disabled;
}

/// Everything `SaveToDB` writes for a new character.
struct NewCharacter
{
    uint guid;
    uint account;
    string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    uint level;
    uint money;
    uint playerBytes;
    uint playerBytes2;
    uint playerFlags;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    uint[taxiMaskSize] taxiMask;
    uint cinematic;
    uint atLogin;
    uint zone;
    uint health;
    uint[maxPowers] power;
    uint[2][equipmentSlotEnd + 1] equipmentCache; /// entry, enchantments per equipment slot, then the first bag slot
    uint ammoId;
    NewItem[] items;
    NewSkill[] skills;
    NewSpell[] spells;
    CreateAction[] actions;

    /// `taximask`: every mask value followed by a space.
    string taxiMaskText() const
    {
        string text;
        foreach (value; taxiMask)
            text ~= value.to!string ~ " ";
        return text;
    }

    /// `equipmentCache`: entry and enchantment pair per slot, space-terminated.
    string equipmentCacheText() const
    {
        string text;
        foreach (pair; equipmentCache)
            text ~= pair[0].to!string ~ " " ~ pair[1].to!string ~ " ";
        return text;
    }

    /// `exploredZones` of a new character: 64 zeros.
    static string exploredZonesText()
    {
        string text;
        foreach (i; 0 .. exploredZonesSize)
            text ~= "0 ";
        return text;
    }
}

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

private enum SpellState { unchanged, changed, newSpell, removed }

private struct PlayerSpell
{
    SpellState state;
    bool active;
    bool dependent;
    bool disabled;
}

private enum SkillState { unchanged, changed, newSkill, deleted }

private struct SkillStatus
{
    ushort value;
    ushort max;
    ushort step;
    SkillState state;
}

private final class ItemObject
{
    uint guid;
    const(ItemTemplate)* proto;
    uint count = 1;
    bool bound;
    ItemObject container;
    ubyte slot;
    ItemObject[] contents; // for bags, ContainerSlots long

    @property uint entry() const { return proto.entry; }
    @property bool isBag() const { return proto.itemClass == ItemClass.container || proto.itemClass == ItemClass.quiver; }
}

private struct ItemPosCount
{
    ushort pos;
    uint count;
}

/// A skill a character has, at its place in the skill list.
struct KnownSkill
{
    uint skill;
    ushort value;
    ushort max;
    ushort step;
}

/// The skills and spells a character knows once logged in (`CharacterBuilder.loadAbilities`).
struct KnownAbilities
{
    KnownSkill[] skills;         /// in the order of the client's skill slots
    uint[] spellbook;            /// active, enabled spells, by id
    uint freePrimaryProfessions; /// primary professions that can still be learned
}

/// Creates one character, or loads one's abilities; see the module documentation. Use once per character.
final class CharacterBuilder
{
    private
    {
        const WorldData world;
        const ClientData client;
        CreationSettings settings;
        uint delegate() nextItemGuid;

        CreateRequest request;
        AccountLevel security;
        uint level;
        uint raceMask;
        uint classMask;
        uint freePrimaryProfessions;

        PlayerSpell[uint] spells;
        SkillStatus[uint] skills;
        uint[] skillOrder; // insertion order, for deterministic output
        bool canDualWield;
        ItemObject[playerSlots] items;
        ItemObject[] createdItems; // every item ever created, in guid order
        uint ammoId;
        bool loading; // loadAbilities: talent spells come from the database, not from creation
    }

    ///
    this(const WorldData world, const ClientData client, CreationSettings settings, uint delegate() nextItemGuid)
    in (world !is null && client !is null && nextItemGuid !is null)
    {
        this.world = world;
        this.client = client;
        this.settings = settings;
        this.nextItemGuid = nextItemGuid;
    }

    /**
     * Runs `Player::Create`. Returns false, as CMaNGOS does, if the race/class pair or the
     * gender is invalid, or the class is missing from the DBC files.
     */
    bool create(uint guid, uint account, AccountLevel accountLevel, CreateRequest req, bool skipCinematic,
        out NewCharacter result)
    {
        request = req;
        security = accountLevel;
        const info = world.createInfo(req.race, req.classId);
        if (info is null)
        {
            error!"cannot create a character of race %s and class %s: no playercreateinfo"(req.race, req.classId);
            return false;
        }
        const classEntry = client.classes.lookup(req.classId);
        if (classEntry is null)
        {
            error!"class %s not found in ChrClasses.dbc (wrong DBC files?)"(req.classId);
            return false;
        }
        if (req.gender > 1)
        {
            error!"invalid gender %s at character creation"(req.gender);
            return false;
        }
        raceMask = maskOf(req.race);
        classMask = maskOf(req.classId);

        result.guid = guid;
        result.account = account;
        result.name = req.name;
        result.race = req.race;
        result.classId = req.classId;
        result.gender = req.gender;
        result.map = info.map;
        result.x = info.x;
        result.y = info.y;
        result.z = info.z;
        result.orientation = info.orientation;
        result.playerBytes = req.skin | req.face << 8 | req.hairStyle << 16 | req.hairColor << 24;
        result.playerBytes2 = req.facialHair | RestState.normal << 24;

        level = security >= AccountLevel.moderator ? settings.startGmLevel : settings.startPlayerLevel;
        result.level = level;
        result.money = settings.startPlayerMoney;

        // InitStatsForLevel, then UpdateMaxHealth / UpdateMaxPower(POWER_MANA) in Create.
        const stats = world.levelStats(req.race, req.classId, level);
        const classStats = world.classStats(req.classId, level);
        result.health = cast(uint) round(max(classStats.baseHealth + healthBonusFromStamina(stats.stats[2]), 1.0f));
        if (classStats.baseMana > 0)
            result.power[Power.mana] = cast(uint) round(classStats.baseMana + manaBonusFromIntellect(stats.stats[3]));
        result.power[Power.energy] = powerEnergyDefault; // every player starts with full (if unused) energy

        if (auto raceEntry = client.races.lookup(req.race))
            result.taxiMask[0] = raceEntry.startingTaxiMask;

        freePrimaryProfessions = cast(uint) security < settings.gmIgnoreMaxPrimarySkills
            ? settings.maxPrimaryTradeSkill : 10;

        learnDefaultSkills(*info);
        learnDefaultSpells(*info);
        result.actions = info.actions.dup;
        addStartingItems(*info);

        result.cinematic = skipCinematic ? 1 : 0;
        result.atLogin = atLoginFirst;
        result.zone = 0; // CMaNGOS saves the cached zone, which is only known once in the world
        result.ammoId = ammoId;
        collect(result);
        return true;
    }

    /**
     * The skill and spell part of `Player::LoadFromDB`: `InitPrimaryProfessions`, `_LoadSkills`,
     * `_LoadSpells` (talents first, then what the skills teach, then the other saved spells) and
     * `learnDefaultSpells`. Default spells and the spells skills teach are never saved, so this
     * learns them again, as CMaNGOS does at every login. Returns false for an invalid race/class pair.
     */
    bool loadAbilities(ubyte race, ubyte classId, uint characterLevel, AccountLevel accountLevel,
        const(NewSkill)[] savedSkills, const(NewSpell)[] savedSpells, out KnownAbilities result)
    {
        const info = world.createInfo(race, classId);
        if (info is null)
            return false;
        request.race = race;
        request.classId = classId;
        security = accountLevel;
        level = characterLevel;
        raceMask = maskOf(race);
        classMask = maskOf(classId);
        loading = true;
        freePrimaryProfessions = cast(uint) security < settings.gmIgnoreMaxPrimarySkills
            ? settings.maxPrimaryTradeSkill : 10;

        // _LoadSkills: the saved value and maximum, with the step derived from SkillTiers.
        foreach (saved; savedSkills)
        {
            if (skillOrder.length == maxPlayerSkills)
            {
                error!"a character has more than %s skills; the rest are not loaded"(maxPlayerSkills);
                break;
            }
            if (saved.value == 0 || (saved.skill in skills) !is null)
                continue;
            if (client.skillLines.lookup(saved.skill) is null)
            {
                warning!"unknown skill %s not loaded"(saved.skill);
                continue;
            }
            auto value = cast(ushort) saved.value, maxValue = cast(ushort) saved.max;
            ushort step;
            foreach (entry; client.raceClassInfo(saved.skill))
            {
                if (!(entry.raceMask & raceMask) || !(entry.classMask & classMask))
                    continue;
                if (entry.flags & skillFlagMaximized)
                    value = maxValue;
                if (const tiers = client.skillTiers.lookup(entry.skillTierId))
                    foreach (i, tierMax; tiers.maxSkillValue)
                        if (tierMax && tierMax == maxValue)
                        {
                            step = cast(ushort)(i + 1);
                            break;
                        }
                break;
            }
            skills[saved.skill] = SkillStatus(value, maxValue, step, SkillState.unchanged);
            skillOrder ~= saved.skill;
        }

        // _LoadSpells
        foreach (saved; savedSpells)
            if (client.talentSpellPos(saved.spell) !is null)
                addSpell(saved.spell, saved.active, false, false, saved.disabled);
        foreach (id; skillOrder.dup)
            if (const skill = id in skills)
                updateSkillTrainedSpells(id, skill.value);
        foreach (saved; savedSpells)
            if (client.talentSpellPos(saved.spell) is null)
                addSpell(saved.spell, saved.active, false, false, saved.disabled);

        learnDefaultSpells(*info);

        foreach (id; skillOrder)
        {
            const skill = skills[id];
            if (skill.state != SkillState.deleted)
                result.skills ~= KnownSkill(id, skill.value, skill.max, skill.step);
        }
        foreach (id, spell; spells)
            if (spell.state != SpellState.removed && spell.active && !spell.disabled)
                result.spellbook ~= id;
        import std.algorithm.sorting : sort;

        result.spellbook.sort();
        result.freePrimaryProfessions = freePrimaryProfessions;
        return true;
    }

private:
    // -----------------------------------------------------------------------
    // Stats (StatSystem.cpp)
    // -----------------------------------------------------------------------

    @property ushort skillMaxForLevel() const
    {
        return cast(ushort)(level * 5);
    }

    // -----------------------------------------------------------------------
    // Spells (Player::addSpell, learnSpell, learnDefaultSpells)
    // -----------------------------------------------------------------------

    bool hasSpell(uint id) const
    {
        if (auto spell = id in spells)
            return spell.state != SpellState.removed && !spell.disabled;
        return false;
    }

    void learnDefaultSpells(const ref PlayerInfo info)
    {
        foreach (spell; info.spells)
            addSpell(spell, true, true, true, false);
    }

    void learnSpell(uint id, bool dependent)
    {
        const existing = id in spells;
        const disabled = existing ? existing.disabled : false;
        const active = disabled ? existing.active : true;
        addSpell(id, active, true, dependent, false);
        if (disabled)
            foreach (next; world.spells.nextInChain(id))
                if (auto spell = next in spells)
                    if (spell.disabled)
                        learnSpell(next, false);
    }

    /// `SpellMgr::GetSpellBookSuccessorSpellId`
    uint spellBookSuccessor(uint id) const
    {
        foreach (ability; client.abilitiesForSpell(id))
            if (ability.forwardSpellId)
                return ability.forwardSpellId;
        return 0;
    }

    /// `SpellMgr::IsSpellValid`
    bool isSpellValid(const(SpellInfo)* spell) const
    {
        if (spell is null)
            return false;
        bool checkReagents;
        foreach (i; 0 .. 3)
        {
            switch (spell.effect[i])
            {
            case SpellEffect.createItem:
                if ((spell.itemType[i] in world.items) is null)
                    return false;
                checkReagents = true;
                break;
            case SpellEffect.learnSpell:
                if (!isSpellValid(world.spells.spell(spell.triggerSpell[i])))
                    return false;
                break;
            default:
                break;
            }
        }
        if (checkReagents)
            foreach (reagent; spell.reagents)
                if (reagent > 0 && (cast(uint) reagent in world.items) is null)
                    return false;
        return true;
    }

    /// `Player::IsNeedCastPassiveLikeSpellAtLearn`, for a player in no shapeshift form and without aura states.
    static bool needCastAtLearn(const(SpellInfo)* spell)
    {
        if (spell.attributesEx & spellAttrExCastWhenLearned)
            return true;
        if (!spell.isPassive)
            return false;
        const needCast = !spell.stances || (spell.attributesEx2 & spellAttrEx2AllowWhileNotShapeshifted);
        return needCast && !spell.casterAuraState;
    }

    /// The persistent effects of casting a learned spell on oneself (`Spell::EffectLearnSpell`, `EffectLearnSkill`,
    /// `EffectDualWield`).
    void castOnSelf(const(SpellInfo)* spell)
    {
        foreach (i; 0 .. 3)
        {
            switch (spell.effect[i])
            {
            case SpellEffect.learnSpell:
                learnSpell(spell.triggerSpell[i], false);
                break;
            case SpellEffect.skillStep:
                const step = spell.simpleValue(i);
                if (step >= 0)
                    setSkillStep(cast(ushort) spell.miscValue[i], cast(ushort) step);
                break;
            case SpellEffect.dualWield:
                canDualWield = true;
                break;
            default:
                break;
            }
        }
    }

    bool addSpell(uint id, bool active, bool learning, bool dependent, bool disabled)
    {
        const spell = world.spells.spell(id);
        if (spell is null)
        {
            error!"addSpell: nonexistent spell %s"(id);
            return false;
        }
        if (!isSpellValid(spell))
        {
            error!"addSpell: broken spell %s, learning not allowed"(id);
            return false;
        }

        auto state = learning ? SpellState.newSpell : SpellState.unchanged;
        bool disabledCase, supercededOld;

        if (auto existing = id in spells)
        {
            bool dependentSet;
            if (const nextId = spellBookSuccessor(id))
                if (hasSpell(nextId))
                    active = false;

            if (existing.state != SpellState.removed && existing.active == active && existing.dependent == dependent
                && existing.disabled == disabled)
                return false;
            if (existing.state != SpellState.removed && !existing.dependent && dependent)
            {
                existing.dependent = dependent;
                if (existing.state != SpellState.newSpell)
                    existing.state = SpellState.changed;
                dependentSet = true;
            }
            if (existing.active != active && existing.state != SpellState.removed && !existing.disabled)
            {
                existing.active = active;
                if (existing.state != SpellState.newSpell)
                    existing.state = SpellState.changed;
                if (active && needCastAtLearn(spell))
                    castOnSelf(spell);
                return active;
            }
            if (existing.disabled != disabled && existing.state != SpellState.removed)
            {
                if (existing.state != SpellState.newSpell)
                    existing.state = SpellState.changed;
                existing.disabled = disabled;
                if (disabled)
                    return false;
                disabledCase = true;
            }
            else
            {
                final switch (existing.state)
                {
                case SpellState.unchanged:
                    return false;
                case SpellState.removed:
                    spells.remove(id);
                    state = SpellState.changed;
                    break;
                case SpellState.newSpell:
                case SpellState.changed:
                    return false;
                }
            }
        }

        const talentPos = client.talentSpellPos(id);
        if (!disabledCase)
        {
            if (talentPos !is null && !loading)
                warning!"addSpell: talent spell %s learned at creation; lower ranks are not removed"(id);
            else if (const prev = world.spells.prevInChain(id))
            {
                bool talent;
                foreach (talentId; client.talents.ids)
                {
                    const talentInfo = client.talents.lookup(talentId);
                    const tab = client.talentTabs.lookup(talentInfo.talentTab);
                    if (tab is null || !(classMask & tab.classMask))
                        continue;
                    uint parent;
                    foreach (rank; talentInfo.rankId)
                        if (rank && world.spells.learnsSpell(rank, prev))
                        {
                            parent = rank;
                            break;
                        }
                    if (parent)
                    {
                        talent = !hasSpell(parent);
                        break;
                    }
                }
                if (!talent)
                    addSpell(prev, active, true, true, disabled);
            }

            auto created = PlayerSpell(state, active, dependent, disabled);
            if (created.active && !created.disabled)
            {
                foreach (otherId, ref other; spells)
                {
                    if (other.state == SpellState.removed)
                        continue;
                    if (const nextId = spellBookSuccessor(otherId))
                    {
                        if (other.active)
                        {
                            if (nextId == id)
                            {
                                other.active = false;
                                if (other.state != SpellState.newSpell)
                                    other.state = SpellState.changed;
                                supercededOld = true;
                            }
                            else if (otherId == id)
                            {
                                created.active = false;
                                if (created.state != SpellState.newSpell)
                                    created.state = SpellState.changed;
                                other.disabled = false;
                                other.state = SpellState.changed;
                            }
                        }
                    }
                }
            }
            spells[id] = created;
            if (created.disabled)
                return false;
        }

        if (freePrimaryProfessions && isPrimaryProfessionFirstRank(id))
            --freePrimaryProfessions;

        if (talentPos !is null && spell.hasEffect(SpellEffect.learnSpell))
            castOnSelf(spell);
        else if (needCastAtLearn(spell))
            castOnSelf(spell);
        else if (spell.hasEffect(SpellEffect.skillStep))
        {
            castOnSelf(spell);
            return false;
        }

        updateSpellTrainedSkills(id);

        foreach (node; world.spells.learnedWith(id))
            if (!node.autoLearned)
                addSpell(node.spell, node.active, true, true, false);

        return active && !disabled && !supercededOld;
    }

    /// `SpellMgr::IsPrimaryProfessionFirstRankSpell`
    bool isPrimaryProfessionFirstRank(uint id) const
    {
        const spell = world.spells.spell(id);
        if (spell is null || spell.effect[1] != SpellEffect.skill)
            return false;
        const skillLine = client.skillLines.lookup(cast(uint) spell.miscValue[1]);
        return skillLine !is null && skillLine.categoryId == SkillCategory.profession && world.spells.rank(id) == 1;
    }

    void removeSpell(uint id)
    {
        if (auto spell = id in spells)
        {
            if (spell.state == SpellState.newSpell)
                spells.remove(id);
            else
                spell.state = SpellState.removed;
        }
    }

    // -----------------------------------------------------------------------
    // Skills (Player::SetSkill, SetSkillStep, UpdateSkillTrainedSpells, UpdateSpellTrainedSkills)
    // -----------------------------------------------------------------------

    bool hasSkill(uint id) const
    {
        if (auto skill = id in skills)
            return skill.state != SkillState.deleted;
        return false;
    }

    ushort skillValue(uint id) const
    {
        if (auto skill = id in skills)
            return skill.state == SkillState.deleted ? 0 : skill.value;
        return 0;
    }

    ushort skillStep(uint id) const
    {
        if (auto skill = id in skills)
            return skill.state == SkillState.deleted ? 0 : skill.step;
        return 0;
    }

    /// `Player::GetSkillInfo`: the first race/class info for a skill that `filter` accepts.
    const(SkillRaceClassInfoEntry)* skillInfo(uint id, scope bool delegate(const ref SkillRaceClassInfoEntry) filter = null) const
    {
        if (!id)
            return null;
        foreach (entry; client.raceClassInfo(id))
        {
            if (!(entry.raceMask & raceMask) || !(entry.classMask & classMask))
                continue;
            if (filter is null || filter(*entry))
                return entry;
        }
        return null;
    }

    enum SkillRange { none, language, level, mono, rank }

    /// `GetSkillRangeType`
    static SkillRange skillRangeType(const(SkillLineEntry)* skill, bool racial)
    {
        switch (skill.categoryId)
        {
        case SkillCategory.languages:
            return SkillRange.language;
        case SkillCategory.weapon:
            return skill.id != skillFistWeapons ? SkillRange.level : SkillRange.mono;
        case SkillCategory.armor:
        case SkillCategory.classSkill:
            return skill.id != skillPoisons && skill.id != skillLockpicking ? SkillRange.mono : SkillRange.level;
        case SkillCategory.secondary:
        case SkillCategory.profession:
            if (isProfessionOrRiding(skill))
                return SkillRange.rank;
            return racial ? SkillRange.none : SkillRange.mono;
        default:
            return SkillRange.none;
        }
    }

    static bool isProfessionOrRiding(const(SkillLineEntry)* skill)
    {
        return skill.categoryId == SkillCategory.profession || skill.id == skillFishing || skill.id == skillCooking
            || skill.id == skillFirstAid || skill.id == skillRiding;
    }

    void learnDefaultSkills(const ref PlayerInfo info)
    {
        foreach (createSkill; info.skills)
        {
            const id = cast(ushort) createSkill.skillId;
            if (hasSkill(id))
                continue;
            ushort value, maxValue, step;
            if (const entry = client.skillLines.lookup(id))
            {
                final switch (skillRangeType(entry, false))
                {
                case SkillRange.language:
                    value = maxValue = 300;
                    break;
                case SkillRange.level:
                    value = 1;
                    maxValue = skillMaxForLevel;
                    break;
                case SkillRange.mono:
                case SkillRange.rank:
                    const predefined = createSkill.step != 0;
                    step = cast(ushort)(predefined ? createSkill.step : 1);
                    const stepIndex = step - 1;
                    const found = skillInfo(id, (const ref SkillRaceClassInfoEntry rci) {
                        if (rci.skillTierId)
                        {
                            if (const tiers = client.skillTiers.lookup(rci.skillTierId))
                            {
                                value = 1;
                                maxValue = cast(ushort) tiers.maxSkillValue[stepIndex];
                                if (rci.flags & skillFlagMaximized)
                                    value = maxValue;
                                else if (predefined)
                                    value = cast(ushort) max(1, (level - 1) * 5);
                                return true;
                            }
                        }
                        else if (rci.flags & skillFlagMaximized)
                        {
                            value = maxValue = skillMaxForLevel;
                            return true;
                        }
                        return false;
                    });
                    if (found is null)
                        continue;
                    break;
                case SkillRange.none:
                    break;
                }
            }
            setSkill(id, value, maxValue, step);
        }
    }

    void setSkill(uint id, ushort value, ushort maxValue, ushort step = 0)
    {
        if (!id)
            return;
        auto existing = id in skills;
        if (existing && existing.state != SkillState.deleted)
        {
            if (value)
            {
                if (step)
                    existing.step = step;
                existing.value = value;
                existing.max = maxValue;
                if (existing.state != SkillState.newSkill)
                    existing.state = SkillState.changed;
            }
            else if (existing.state == SkillState.newSkill)
            {
                skills.remove(id);
                skillOrder = skillOrder.remove!(other => other == id);
            }
            else
                existing.state = SkillState.deleted;
            updateSkillTrainedSpells(id, value);
            return;
        }
        if (!value)
            return;
        if (existing is null && client.skillLines.lookup(id) is null)
        {
            error!"skill %s not found in SkillLine.dbc"(id);
            return;
        }
        if (existing)
            *existing = SkillStatus(value, maxValue, step, SkillState.changed);
        else
        {
            skills[id] = SkillStatus(value, maxValue, step, SkillState.newSkill);
            skillOrder ~= id;
        }
        updateSkillTrainedSpells(id, value);
    }

    void setSkillStep(ushort id, ushort step)
    {
        if (!id || step > maxSkillStep)
            return;
        if (!step)
            return setSkill(id, 0, 0);

        ushort value, maxValue;
        const entry = skillInfo(id, (const ref SkillRaceClassInfoEntry rci) {
            if (rci.skillTierId)
                if (const tiers = client.skillTiers.lookup(rci.skillTierId))
                {
                    value = cast(ushort) tiers.skillValue[step - 1];
                    maxValue = cast(ushort) tiers.maxSkillValue[step - 1];
                    return true;
                }
            return false;
        });
        const maxed = entry !is null && (entry.flags & skillFlagMaximized);
        if (maxValue)
            setSkill(id, cast(ushort) max(1, maxed ? maxValue : skillValue(id)), maxValue, step);
    }

    void updateSkillTrainedSpells(uint id, ushort currentValue)
    {
        const step = skillStep(id);
        foreach (ability; client.abilitiesForSkill(id))
        {
            if (!currentValue)
            {
                removeSpell(ability.spellId);
                continue;
            }
            if (ability.raceMask && !(ability.raceMask & raceMask))
                continue;
            if (ability.classMask && !(ability.classMask & classMask))
                continue;
            if (!ability.learnOnGetSkill)
            {
                if (const training = world.spells.learnedSkill(ability.spellId))
                    if (training.skill == id && training.effect == SpellEffect.skill && training.step < step
                        && !hasSpell(ability.spellId))
                        addSpell(ability.spellId, true, true, true, false);
                continue;
            }
            if (currentValue < ability.reqSkillValue)
                removeSpell(ability.spellId);
            else
                addSpell(ability.spellId, true, true, true, false);
        }
    }

    void updateSpellTrainedSkills(uint spellId)
    {
        if (const learn = world.spells.learnedSkill(spellId))
        {
            setSkillStep(cast(ushort) learn.skill, cast(ushort) learn.step);
            return;
        }
        foreach (ability; client.abilitiesForSpell(spellId))
        {
            const skillLine = client.skillLines.lookup(ability.skillId);
            if (skillLine is null)
                continue;
            const id = cast(ushort) skillLine.id;
            if (id == skillPoisons || id == skillLockpicking)
            {
                if (ability.maxValue)
                    continue;
            }
            else if (ability.learnOnGetSkill != abilityLearnedOnGetRaceOrClassSkill)
                continue;
            if (hasSkill(id))
                continue;
            const entry = skillInfo(id);
            if (entry is null)
                continue;
            switch (skillRangeType(skillLine, ability.raceMask != 0))
            {
            case SkillRange.language:
                setSkill(id, 300, 300);
                break;
            case SkillRange.level:
                setSkill(id, 1, skillMaxForLevel);
                break;
            case SkillRange.mono:
                if (entry.flags & skillFlagMaximized)
                    setSkill(id, skillMaxForLevel, skillMaxForLevel);
                else
                    setSkill(id, 1, 1);
                break;
            default:
                break;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Items (Player::StoreNewItemInBestSlots and the inventory functions it uses)
    // -----------------------------------------------------------------------

    void addStartingItems(const ref PlayerInfo info)
    {
        const raceClassGender = request.race | request.classId << 8 | request.gender << 16;
        const(CharStartOutfitEntry)* outfit;
        foreach (id; 1 .. client.startOutfits.idLimit)
            if (const entry = client.startOutfits.lookup(id))
                if (entry.raceClassGender == raceClassGender)
                {
                    outfit = entry;
                    break;
                }

        if (outfit !is null)
        {
            foreach (itemId; outfit.itemId)
            {
                if (itemId <= 0)
                    continue;
                const proto = cast(uint) itemId in world.items;
                if (proto is null)
                    continue;
                uint count = proto.buyCount;
                if (proto.itemClass == ItemClass.consumable && proto.subClass == itemSubclassFood)
                {
                    if (proto.spellCategory[0] == 11 && proto.stackable > 4) // food
                        count = 4;
                    else if (proto.spellCategory[0] == 59 && proto.stackable > 2) // drink
                        count = 2;
                }
                storeNewItemInBestSlots(cast(uint) itemId, count);
            }
        }
        else
            warning!"no CharStartOutfit entry for race %s class %s gender %s"(request.race, request.classId,
                request.gender);

        foreach (item; info.items)
            storeNewItemInBestSlots(item.itemId, item.amount);

        // Equip what can be equipped from the backpack; move the rest (e.g. arrows) to its best place.
        foreach (ubyte i; inventorySlotItemStart .. inventorySlotItemEnd)
        {
            auto item = items[i];
            if (item is null)
                continue;
            ushort dest;
            if (canEquipItem(nullSlot, dest, item, false) == InventoryResult.ok)
            {
                removeItem(inventorySlotBag0, i);
                equipItem(dest, item);
                continue;
            }
            ItemPosCount[] storeDest;
            if (canStoreItem(nullBag, nullSlot, storeDest, item.entry, item.count, item) == InventoryResult.ok)
            {
                removeItem(inventorySlotBag0, i);
                item = storeItem(storeDest, item);
            }
            if (canUseAmmo(item.entry) == InventoryResult.ok)
                setAmmo(item.entry);
        }
    }

    bool storeNewItemInBestSlots(uint entry, uint amount)
    {
        while (amount > 0)
        {
            ushort dest;
            if (canEquipNewItem(nullSlot, dest, entry) != InventoryResult.ok)
                break;
            equipItem(dest, createItem(entry, 1));
            autoUnequipOffhandIfNeeded();
            --amount;
        }
        if (amount == 0)
            return true;

        ItemPosCount[] dest;
        const result = canStoreItem(inventorySlotBag0, nullSlot, dest, entry, amount, null);
        if (result == InventoryResult.ok)
        {
            uint count;
            foreach (position; dest)
                count += position.count;
            storeItem(dest, createItem(entry, count));
            return true;
        }
        error!"cannot equip or store initial item %s for race %s class %s: %s"(entry, request.race,
            request.classId, result);
        return false;
    }

    /// `Item::CreateItem`: allocates a guid even for items that end up merged or thrown away, as CMaNGOS does.
    ItemObject createItem(uint entry, uint count)
    {
        const proto = entry in world.items;
        if (proto is null || count < 1)
            return null;
        auto item = new ItemObject;
        item.guid = nextItemGuid();
        item.proto = proto;
        item.count = min(count, proto.stackable);
        if (proto.randomProperty)
            warning!"starting item %s has random properties; they are not generated"(entry);
        if (item.isBag)
            item.contents = new ItemObject[proto.containerSlots];
        createdItems ~= item;
        return item;
    }

    ItemObject itemAt(ubyte bag, ubyte slot)
    {
        if (bag == inventorySlotBag0)
            return slot < playerSlots ? items[slot] : null;
        if (bag >= inventorySlotBagStart && bag < inventorySlotBagEnd)
            if (auto container = items[bag])
                if (slot < container.contents.length)
                    return container.contents[slot];
        return null;
    }

    bool isTwoHandUsed()
    {
        const main = items[equipmentSlotMainhand];
        return main !is null && main.proto.inventoryType == InventoryType.twoHandWeapon;
    }

    InventoryResult canUseItem(const(ItemTemplate)* proto)
    {
        if ((proto.allowableClass & classMask) == 0 || (proto.allowableRace & raceMask) == 0)
            return InventoryResult.youCanNeverUseThatItem;
        if (proto.requiredSkill != 0)
        {
            if (skillValue(proto.requiredSkill) == 0)
                return InventoryResult.noRequiredProficiency;
            if (skillValue(proto.requiredSkill) < proto.requiredSkillRank)
                return InventoryResult.cantEquipSkill;
        }
        if (proto.requiredSpell != 0 && !hasSpell(proto.requiredSpell))
            return InventoryResult.noRequiredProficiency;
        if (proto.requiredHonorRank > 0) // a new character has no honor rank
            return InventoryResult.cantEquipRank;
        if (level < proto.requiredLevel)
            return InventoryResult.cantEquipLevel;
        return InventoryResult.ok;
    }

    /// `Item::GetSkill`
    static uint itemSkill(const(ItemTemplate)* proto)
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

    InventoryResult canUseItem(ItemObject item)
    {
        if (const result = canUseItem(item.proto))
            return result;
        if (uint skill = itemSkill(item.proto))
        {
            if (item.proto.subClass == itemSubclassWeaponFist)
                skill = skillFistWeapons;
            if (!skillValue(skill))
                return InventoryResult.noRequiredProficiency;
        }
        // Reputations are not initialized until the first login: every faction is neutral (3).
        if (item.proto.requiredReputationFaction && 3 < item.proto.requiredReputationRank)
            return InventoryResult.cantEquipReputation;
        return InventoryResult.ok;
    }

    /// `Player::ViableEquipSlots`
    bool viableEquipSlots(const(ItemTemplate)* proto, ref ubyte[4] slots)
    {
        slots[] = nullSlot;
        if (canUseItem(proto) != InventoryResult.ok)
            return false;
        switch (proto.inventoryType)
        {
        case InventoryType.head: slots[0] = equipmentSlotHead; break;
        case InventoryType.neck: slots[0] = equipmentSlotNeck; break;
        case InventoryType.shoulders: slots[0] = equipmentSlotShoulders; break;
        case InventoryType.body: slots[0] = equipmentSlotBody; break;
        case InventoryType.chest:
        case InventoryType.robe: slots[0] = equipmentSlotChest; break;
        case InventoryType.waist: slots[0] = equipmentSlotWaist; break;
        case InventoryType.legs: slots[0] = equipmentSlotLegs; break;
        case InventoryType.feet: slots[0] = equipmentSlotFeet; break;
        case InventoryType.wrists: slots[0] = equipmentSlotWrists; break;
        case InventoryType.hands: slots[0] = equipmentSlotHands; break;
        case InventoryType.finger: slots[0] = equipmentSlotFinger1; slots[1] = equipmentSlotFinger2; break;
        case InventoryType.trinket: slots[0] = equipmentSlotTrinket1; slots[1] = equipmentSlotTrinket2; break;
        case InventoryType.cloak: slots[0] = equipmentSlotBack; break;
        case InventoryType.weapon:
        case InventoryType.twoHandWeapon:
            slots[0] = equipmentSlotMainhand;
            if (canDualWield)
                slots[1] = equipmentSlotOffhand;
            break;
        case InventoryType.shield:
        case InventoryType.weaponOffhand:
        case InventoryType.holdable: slots[0] = equipmentSlotOffhand; break;
        case InventoryType.ranged:
        case InventoryType.thrown:
        case InventoryType.rangedRight: slots[0] = equipmentSlotRanged; break;
        case InventoryType.tabard: slots[0] = equipmentSlotTabard; break;
        case InventoryType.weaponMainhand: slots[0] = equipmentSlotMainhand; break;
        case InventoryType.bag:
            foreach (i; 0 .. 4)
                slots[i] = cast(ubyte)(inventorySlotBagStart + i);
            break;
        case InventoryType.relic:
            const relicClass = proto.subClass == itemSubclassArmorLibram ? PlayerClass.paladin
                : proto.subClass == itemSubclassArmorIdol ? PlayerClass.druid
                : proto.subClass == itemSubclassArmorTotem ? PlayerClass.shaman
                : proto.subClass == itemSubclassArmorMisc ? PlayerClass.warlock : 0;
            if (relicClass && relicClass == request.classId)
                slots[0] = equipmentSlotRanged;
            break;
        default:
            break;
        }
        return slots[0] != nullSlot;
    }

    /// `Player::FindEquipSlot` with no slot requested and no swap.
    ubyte findEquipSlot(const(ItemTemplate)* proto)
    {
        ubyte[4] slots;
        if (!viableEquipSlots(proto, slots))
            return nullSlot;
        foreach (slot; slots)
        {
            if (slot == nullSlot || items[slot] !is null)
                continue;
            if (slot == equipmentSlotOffhand && (isTwoHandUsed() || proto.inventoryType == InventoryType.twoHandWeapon))
                continue;
            return slot;
        }
        return nullSlot;
    }

    InventoryResult canEquipNewItem(ubyte slot, out ushort dest, uint entry)
    {
        auto probe = createItem(entry, 1); // CMaNGOS creates (and numbers) a throw-away item for the check
        if (probe is null)
            return InventoryResult.itemNotFound;
        createdItems = createdItems[0 .. $ - 1];
        return canEquipItem(slot, dest, probe, false);
    }

    InventoryResult canEquipItem(ubyte slot, out ushort dest, ItemObject item, bool swap)
    {
        const proto = item.proto;
        if (const res = canTakeMoreSimilarItems(item.entry, item.count, item))
            return res;
        const eslot = findEquipSlot(proto);
        if (eslot == nullSlot)
            return InventoryResult.itemCantBeEquipped;
        if (const res = canUseItem(item))
            return res;
        if (items[eslot] !is null)
            return InventoryResult.noEquipmentSlotAvailable;
        if (proto.flags & itemFlagUniqueEquippable)
            foreach (ubyte s; 0 .. equipmentSlotEnd)
                if (items[s] !is null && items[s].entry == item.entry)
                    return InventoryResult.itemCantBeEquipped;
        if (proto.itemClass == ItemClass.quiver)
            foreach (ubyte s; inventorySlotBagStart .. inventorySlotBagEnd)
                if (auto bag = items[s])
                    if (bag !is item && bag.proto.itemClass == proto.itemClass)
                        return bag.proto.subClass == itemSubclassAmmoPouch ? InventoryResult.canEquipOnlyOneAmmoPouch
                            : InventoryResult.canEquipOnlyOneQuiver;
        const type = proto.inventoryType;
        if (eslot == equipmentSlotOffhand)
        {
            if (type == InventoryType.weapon || type == InventoryType.weaponOffhand)
            {
                if (!canDualWield)
                    return InventoryResult.cantDualWield;
            }
            else if (type == InventoryType.twoHandWeapon)
                return InventoryResult.cantDualWield;
            if (isTwoHandUsed())
                return InventoryResult.cantEquipWithTwoHanded;
        }
        if (type == InventoryType.twoHandWeapon)
        {
            if (eslot != equipmentSlotMainhand)
                return InventoryResult.itemCantBeEquipped;
            if (auto offhand = items[equipmentSlotOffhand])
            {
                ItemPosCount[] offDest;
                if (canStoreItem(nullBag, nullSlot, offDest, offhand.entry, offhand.count, offhand) != InventoryResult.ok)
                    return InventoryResult.inventoryFull;
            }
        }
        dest = inventorySlotBag0 << 8 | eslot;
        return InventoryResult.ok;
    }

    InventoryResult canUseAmmo(uint entry)
    {
        const proto = entry in world.items;
        if (proto is null)
            return InventoryResult.itemNotFound;
        if (proto.inventoryType != InventoryType.ammo)
            return InventoryResult.onlyAmmoCanGoHere;
        return canUseItem(proto);
    }

    void setAmmo(uint entry)
    {
        if (!entry || ammoId == entry)
            return;
        if (canUseAmmo(entry) == InventoryResult.ok)
            ammoId = entry;
    }

    void autoUnequipOffhandIfNeeded()
    {
        auto offhand = items[equipmentSlotOffhand];
        if (offhand is null || !isTwoHandUsed())
            return;
        ItemPosCount[] dest;
        if (canStoreItem(nullBag, nullSlot, dest, offhand.entry, offhand.count, offhand) == InventoryResult.ok)
        {
            removeItem(inventorySlotBag0, equipmentSlotOffhand);
            storeItem(dest, offhand);
        }
        else
            error!"no room for the off-hand item %s at character creation; CMaNGOS would mail it"(offhand.entry);
    }

    uint itemCount(uint entry, ItemObject skip)
    {
        uint count;
        void add(ItemObject item)
        {
            if (item !is null && item !is skip && item.entry == entry)
                count += item.count;
        }

        foreach (ubyte i; 0 .. inventorySlotItemEnd)
            add(items[i]);
        foreach (ubyte i; keyringSlotStart .. keyringSlotEnd)
            add(items[i]);
        foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            if (auto bag = items[i])
                foreach (content; bag.contents)
                    add(content);
        return count;
    }

    InventoryResult canTakeMoreSimilarItems(uint entry, uint count, ItemObject item, uint* noSpace = null)
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
            const current = itemCount(entry, item);
            if (current + count > cast(uint) proto.maxCount)
            {
                if (noSpace)
                    *noSpace = count + current - proto.maxCount;
                return InventoryResult.cantCarryMoreOfThis;
            }
        }
        return InventoryResult.ok;
    }

    static bool itemFitsBag(const(ItemTemplate)* proto, const(ItemTemplate)* bag)
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

    static bool contains(const(ItemPosCount)[] dest, ushort pos)
    {
        foreach (position; dest)
            if (position.pos == pos)
                return true;
        return false;
    }

    /// `_CanStoreItem_InInventorySlots`
    void storeInInventorySlots(ubyte begin, ubyte end, ref ItemPosCount[] dest, const(ItemTemplate)* proto,
        ref uint count, bool merge, ItemObject source, ubyte skipBag, ubyte skipSlot)
    {
        foreach (ubyte j; begin .. end)
        {
            if (skipBag == inventorySlotBag0 && j == skipSlot)
                continue;
            auto other = items[j];
            if (other is source)
                other = null;
            if ((other !is null) != merge)
                continue;
            uint needSpace = proto.stackable;
            if (other)
            {
                if (other.entry != proto.entry || other.count >= proto.stackable)
                    continue;
                needSpace -= other.count;
            }
            if (needSpace > count)
                needSpace = count;
            const pos = cast(ushort)(inventorySlotBag0 << 8 | j);
            if (!contains(dest, pos))
            {
                dest ~= ItemPosCount(pos, needSpace);
                count -= needSpace;
                if (count == 0)
                    return;
            }
        }
    }

    /// `_CanStoreItem_InBag`
    InventoryResult storeInBag(ubyte bag, ref ItemPosCount[] dest, const(ItemTemplate)* proto, ref uint count,
        bool merge, bool nonSpecialized, ItemObject source, ubyte skipBag, ubyte skipSlot)
    {
        if (bag == skipBag)
            return InventoryResult.itemDoesntGoIntoBag;
        auto container = items[bag];
        if (container is null || container is source)
            return InventoryResult.intBagError;
        const bagProto = container.proto;
        if (nonSpecialized != (bagProto.itemClass == ItemClass.container && bagProto.subClass == itemSubclassContainer))
            return InventoryResult.itemDoesntGoIntoBag;
        if (!itemFitsBag(proto, bagProto))
            return InventoryResult.itemDoesntGoIntoBag;
        foreach (j; 0 .. container.contents.length)
        {
            if (j == skipSlot)
                continue;
            auto other = container.contents[j];
            if (other is source)
                other = null;
            if ((other !is null) != merge)
                continue;
            uint needSpace = proto.stackable;
            if (other)
            {
                if (other.entry != proto.entry || other.count >= proto.stackable)
                    continue;
                needSpace -= other.count;
            }
            if (needSpace > count)
                needSpace = count;
            const pos = cast(ushort)(bag << 8 | j);
            if (!contains(dest, pos))
            {
                dest ~= ItemPosCount(pos, needSpace);
                count -= needSpace;
                if (count == 0)
                    return InventoryResult.ok;
            }
        }
        return InventoryResult.ok;
    }

    /// `Player::_CanStoreItem` without a specific slot and without swapping.
    InventoryResult canStoreItem(ubyte bag, ubyte slot, ref ItemPosCount[] dest, uint entry, uint count,
        ItemObject item)
    {
        const proto = entry in world.items;
        if (proto is null)
            return InventoryResult.itemNotFound;

        uint noSimilar;
        if (const res = canTakeMoreSimilarItems(entry, count, item, &noSimilar))
        {
            if (count == noSimilar)
                return res;
            count -= noSimilar;
        }
        InventoryResult done()
        {
            return noSimilar == 0 ? InventoryResult.ok : InventoryResult.cantCarryMoreOfThis;
        }

        // GetMaxKeyringClientSize: by level up to 60, every keyring slot above.
        const keyringSize = level <= 60 ? keyringSizeByLevel[level / 10] : keyringSlotEnd - keyringSlotStart;

        if (bag != nullBag)
        {
            if (proto.stackable > 1)
            {
                if (bag == inventorySlotBag0)
                {
                    storeInInventorySlots(keyringSlotStart, keyringSlotEnd, dest, proto, count, true, item, bag, slot);
                    if (count == 0)
                        return done();
                    storeInInventorySlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, true,
                        item, bag, slot);
                    if (count == 0)
                        return done();
                }
                else
                {
                    if (storeInBag(bag, dest, proto, count, true, false, item, nullBag, slot) != InventoryResult.ok)
                        if (const res = storeInBag(bag, dest, proto, count, true, true, item, nullBag, slot))
                            return res;
                    if (count == 0)
                        return done();
                }
            }
            if (bag == inventorySlotBag0)
            {
                if (proto.bagFamily == bagFamilyKeys)
                {
                    storeInInventorySlots(keyringSlotStart, cast(ubyte)(keyringSlotStart + keyringSize), dest,
                        proto, count, false, item, bag, slot);
                    if (count == 0)
                        return done();
                }
                storeInInventorySlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, false, item,
                    bag, slot);
                if (count == 0)
                    return done();
            }
            else
            {
                if (storeInBag(bag, dest, proto, count, false, false, item, nullBag, slot) != InventoryResult.ok)
                    if (const res = storeInBag(bag, dest, proto, count, false, true, item, nullBag, slot))
                        return res;
                if (count == 0)
                    return done();
            }
        }

        if (proto.stackable > 1)
        {
            storeInInventorySlots(keyringSlotStart, keyringSlotEnd, dest, proto, count, true, item, bag, slot);
            if (count == 0)
                return done();
            storeInInventorySlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, true, item, bag,
                slot);
            if (count == 0)
                return done();
            if (proto.bagFamily)
                foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                {
                    if (storeInBag(i, dest, proto, count, true, false, item, bag, slot) != InventoryResult.ok)
                        continue;
                    if (count == 0)
                        return done();
                }
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            {
                if (storeInBag(i, dest, proto, count, true, true, item, bag, slot) != InventoryResult.ok)
                    continue;
                if (count == 0)
                    return done();
            }
        }

        if (proto.bagFamily)
        {
            if (proto.bagFamily == bagFamilyKeys)
            {
                storeInInventorySlots(keyringSlotStart, cast(ubyte)(keyringSlotStart + keyringSize), dest, proto,
                    count, false, item, bag, slot);
                if (count == 0)
                    return done();
            }
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
            {
                if (storeInBag(i, dest, proto, count, false, false, item, bag, slot) != InventoryResult.ok)
                    continue;
                if (count == 0)
                    return done();
            }
        }

        if (item !is null && item.isBag)
            foreach (content; item.contents)
                if (content !is null)
                    return InventoryResult.nonEmptyBagOverOtherBag;

        storeInInventorySlots(inventorySlotItemStart, inventorySlotItemEnd, dest, proto, count, false, item, bag, slot);
        if (count == 0)
            return done();
        foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
        {
            if (storeInBag(i, dest, proto, count, false, true, item, bag, slot) != InventoryResult.ok)
                continue;
            if (count == 0)
                return done();
        }
        return InventoryResult.inventoryFull;
    }

    /// `Player::StoreItem`: every position but the last gets a clone (a new item and guid).
    ItemObject storeItem(const(ItemPosCount)[] dest, ItemObject item)
    {
        if (item is null)
            return null;
        ItemObject last = item;
        foreach (index, position; dest)
        {
            const isLast = index + 1 == dest.length;
            last = placeItem(position.pos, item, position.count, !isLast);
        }
        return last;
    }

    /// `Player::_StoreItem`
    ItemObject placeItem(ushort pos, ItemObject item, uint count, bool clone)
    {
        const bag = cast(ubyte)(pos >> 8);
        const slot = cast(ubyte)(pos & 0xFF);
        auto existing = itemAt(bag, slot);
        if (existing is null)
        {
            auto placed = clone ? createItem(item.entry, count) : item;
            placed.count = count;
            const bonding = placed.proto.bonding;
            if (bonding == bindWhenPickedUp || bonding == bindQuestItem
                || (bonding == bindWhenEquipped && isBagPos(pos)))
                placed.bound = true;
            placed.slot = slot;
            if (bag == inventorySlotBag0)
            {
                items[slot] = placed;
                placed.container = null;
            }
            else
            {
                auto container = items[bag];
                container.contents[slot] = placed;
                placed.container = container;
            }
            return placed;
        }
        const bonding = existing.proto.bonding;
        if (bonding == bindWhenPickedUp || bonding == bindQuestItem || (bonding == bindWhenEquipped && isBagPos(pos)))
            existing.bound = true;
        existing.count += count;
        if (!clone)
            forget(item); // merged into the stack: never saved
        return existing;
    }

    static bool isBagPos(ushort pos)
    {
        const bag = pos >> 8, slot = pos & 0xFF;
        return bag == inventorySlotBag0 && slot >= inventorySlotBagStart && slot < inventorySlotBagEnd;
    }

    /// `Player::EquipItem` (through `VisualizeItem`)
    void equipItem(ushort pos, ItemObject item)
    {
        const slot = cast(ubyte)(pos & 0xFF);
        const bonding = item.proto.bonding;
        if (bonding == bindWhenEquipped || bonding == bindWhenPickedUp || bonding == bindQuestItem)
            item.bound = true;
        items[slot] = item;
        item.slot = slot;
        item.container = null;
    }

    void removeItem(ubyte bag, ubyte slot)
    {
        if (bag == inventorySlotBag0)
            items[slot] = null;
        else if (auto container = items[bag])
            container.contents[slot] = null;
    }

    void forget(ItemObject item)
    {
        foreach (i, created; createdItems)
            if (created is item)
            {
                createdItems = createdItems[0 .. i] ~ createdItems[i + 1 .. $];
                return;
            }
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    void collect(ref NewCharacter result)
    {
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            if (auto item = items[slot])
                result.equipmentCache[slot][0] = item.entry;
        if (auto bag = items[inventorySlotBagStart])
            result.equipmentCache[equipmentSlotEnd][0] = bag.entry;

        // Only items that are actually somewhere are saved.
        bool[ItemObject] placed;
        foreach (item; items)
            if (item !is null)
            {
                placed[item] = true;
                foreach (content; item.contents)
                    if (content !is null)
                        placed[content] = true;
            }
        foreach (item; createdItems)
        {
            if (item !in placed)
                continue;
            NewItem row;
            row.guid = item.guid;
            row.entry = item.entry;
            row.count = item.count;
            row.duration = item.proto.duration;
            row.charges = item.proto.spellCharges;
            row.flags = item.bound ? 1 : 0;
            row.durability = item.proto.maxDurability;
            row.containerGuid = item.container ? item.container.guid : 0;
            row.slot = item.slot;
            result.items ~= row;
        }

        foreach (id; skillOrder)
        {
            const skill = skills[id];
            if (skill.state != SkillState.deleted)
                result.skills ~= NewSkill(id, skill.value, skill.max);
        }

        auto ids = spells.keys;
        import std.algorithm.sorting : sort;

        ids.sort();
        foreach (id; ids)
        {
            const spell = spells[id];
            if (!spell.dependent && spell.state != SpellState.removed)
                result.spells ~= NewSpell(id, spell.active, spell.disabled);
        }
    }

}

/// `Player::ValidateAppearance`: every chosen look must exist in `CharSections.dbc` and `CharacterFacialHairStyles.dbc`.
bool validateAppearance(const ClientData client, ubyte race, ubyte gender, ubyte hairStyle, ubyte hairColor,
    ubyte face, ubyte facialHair, ubyte skin)
{
    enum ubyte raceNightElf = 4, raceUndead = 5, raceTauren = 6, genderFemale = 1;
    if (client.charSection(race, CharSectionType.skin, gender, 0, skin) is null)
        return false;
    if (client.charSection(race, CharSectionType.face, gender, face, skin) is null)
        return false;
    if (client.charSection(race, CharSectionType.hair, gender, hairStyle, hairColor) is null)
        return false;
    // These combinations have no facial hair sections at all.
    const exclude = race == raceTauren || (gender == genderFemale && race != raceNightElf && race != raceUndead);
    if (!exclude && client.charSection(race, CharSectionType.facialHair, gender, facialHair, hairColor) is null)
        return false;
    return client.facialHair(race, gender, facialHair) !is null;
}

version (unittest)
{
    import dmangos.world.testdata;

    private NewCharacter build(ubyte race, ubyte classId, AccountLevel level = AccountLevel.player)
    {
        setLogLevel(LogLevel.error);
        auto client = testClientData();
        auto world = testWorldData(client);
        uint nextGuid = 1;
        auto builder = new CharacterBuilder(world, client, CreationSettings.init, () => nextGuid++);
        NewCharacter character;
        assert(builder.create(7, 3, level, CreateRequest("Tester", race, classId, 0, 0, 0, 1, 0, 0, 0), false,
            character));
        return character;
    }

    private const(NewItem)* itemOf(const ref NewCharacter character, uint entry)
    {
        foreach (ref item; character.items)
            if (item.entry == entry)
                return &item;
        return null;
    }
}

/// A human warrior: equipped sword and shirt, food and a bound hearthstone in the backpack, derived skills.
unittest
{
    const c = build(raceHuman, PlayerClass.warrior);
    assert(c.guid == 7 && c.account == 3 && c.level == 1 && c.atLogin == atLoginFirst && c.zone == 0);
    assert(c.playerBytes == (1 << 16) && c.playerBytes2 == (RestState.normal << 24));
    assert(c.health == 20 + 20 + 2 * 10, "base health plus the stamina bonus");
    assert(c.power[Power.mana] == 0 && c.power[Power.energy] == 100);
    assert(c.taxiMask[0] == 0x2 && c.taxiMask[1 .. $] == [0, 0, 0, 0, 0, 0, 0]);
    assert(c.equipmentCache[equipmentSlotMainhand][0] == itemSword);
    assert(c.equipmentCache[equipmentSlotBody][0] == itemShirt);
    assert(c.equipmentCacheText.length && c.taxiMaskText == "2 0 0 0 0 0 0 0 ");

    // Every equip check creates (and numbers) a throw-away item first, as CMaNGOS does.
    assert(c.items.length == 4);
    assert(itemOf(c, itemSword).guid == 2 && itemOf(c, itemSword).slot == equipmentSlotMainhand);
    assert(itemOf(c, itemSword).durability == 20);
    assert(itemOf(c, itemShirt).slot == equipmentSlotBody);
    assert(itemOf(c, itemJerky).slot == inventorySlotItemStart && itemOf(c, itemJerky).count == 5);
    assert(itemOf(c, itemHearthstone).slot == inventorySlotItemStart + 1 && itemOf(c, itemHearthstone).flags == 1);

    // Skills: unarmed from playercreateinfo_skills, swords and Common taught by the default spells.
    const NewSkill[] skills = [NewSkill(skillUnarmed, 1, 5), NewSkill(skillSwords, 1, 5), NewSkill(skillCommon, 300, 300)];
    assert(c.skills == skills);
    // Default spells are dependent and not saved; the one a passive spell taught when cast is.
    assert(c.spells == [NewSpell(spellLearnedByPassive, true, false)]);
    assert(c.actions == [CreateAction(0, 6603, 0)]);
}

/// A human mage: a two-handed staff, a maximized class skill, and mana from intellect.
unittest
{
    const c = build(raceHuman, classMage);
    assert(c.health == 32 + 20);
    assert(c.power[Power.mana] == 100 + 20 + 3 * 15);
    assert(itemOf(c, itemStaff).slot == equipmentSlotMainhand);
    bool hasFireMagic;
    foreach (skill; c.skills)
        if (skill.skill == skillFireMagic)
            hasFireMagic = skill.value == 5 && skill.max == 5;
    assert(hasFireMagic, "a maximized skill starts at the level cap");
}

/// An orc hunter: the quiver goes into a bag slot, the arrows move into it, and become the ammo.
unittest
{
    const c = build(raceOrc, PlayerClass.hunter);
    const quiver = itemOf(c, itemQuiver);
    assert(quiver.slot == inventorySlotBagStart && quiver.containerGuid == 0);
    assert(c.equipmentCache[equipmentSlotEnd][0] == itemQuiver, "the first bag slot ends the equipment cache");
    const arrows = itemOf(c, itemArrow);
    assert(arrows.containerGuid == quiver.guid && arrows.slot == 0 && arrows.count == 200);
    assert(c.ammoId == itemArrow);
    assert(itemOf(c, itemBow).slot == equipmentSlotRanged);
    // With the arrows moved out, the hearthstone moves up to the first backpack slot.
    assert(itemOf(c, itemHearthstone).slot == inventorySlotItemStart);
}

/// GM accounts start at GM.StartLevel; invalid race/class pairs are refused.
unittest
{
    auto client = testClientData();
    auto world = testWorldData(client);
    uint nextGuid = 1;
    auto settings = CreationSettings.init;
    settings.startGmLevel = 10;
    auto builder = new CharacterBuilder(world, client, settings, () => nextGuid++);
    NewCharacter c;
    assert(builder.create(1, 1, AccountLevel.gameMaster, CreateRequest("Gm", raceHuman, PlayerClass.warrior), false, c));
    assert(c.level == 10);
    assert(!new CharacterBuilder(world, client, settings, () => nextGuid++).create(2, 1, AccountLevel.player,
        CreateRequest("Nope", raceOrc, classMage), false, c));

    assert(validateAppearance(client, raceHuman, 0, 1, 0, 0, 0, 0));
    assert(!validateAppearance(client, raceHuman, 0, 5, 0, 0, 0, 0), "hair style 5 does not exist");
}

/// Loading a saved character learns its default spells again, and the spells its skills teach.
unittest
{
    import dmangos.world.testdata;

    auto client = testClientData();
    auto world = testWorldData(client);
    auto builder = new CharacterBuilder(world, client, CreationSettings.init, () => 1u);
    KnownAbilities known;
    // Saved: the sword skill (which teaches One-Handed Swords) and an inactive fireball.
    assert(builder.loadAbilities(raceHuman, PlayerClass.warrior, 1, AccountLevel.player,
        [NewSkill(skillSwords, 1, 5), NewSkill(424242, 1, 1)], [NewSpell(spellFireball, false, false)], known));
    assert(known.skills[0] == KnownSkill(skillSwords, 1, 5, 0), "saved skills keep their place");
    import std.algorithm.searching : canFind;

    // The default spells, what they teach, and what the skills teach, but not the inactive spell.
    assert(known.spellbook.canFind(spellOneHandedSwords) && known.spellbook.canFind(spellLanguageCommon));
    assert(known.spellbook.canFind(spellPassiveTrainer) && known.spellbook.canFind(spellLearnedByPassive));
    assert(!known.spellbook.canFind(spellFireball));
    assert(known.freePrimaryProfessions == CreationSettings.init.maxPrimaryTradeSkill);

    KnownAbilities none;
    assert(!new CharacterBuilder(world, client, CreationSettings.init, () => 1u)
        .loadAbilities(raceOrc, classMage, 1, AccountLevel.player, null, null, none));
}
