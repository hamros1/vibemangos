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
 *        possible, then everything in the backpack equipped or moved to its best place. The items
 *        follow `dmangos.world.inventory`'s rules, the same a player in the world is held to.)
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

import std.algorithm.comparison : max;
import std.algorithm.mutation : remove;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.array : replicate;
import std.conv : to;
import std.math : round;

import dmangos.auth.accounts : AccountLevel;
import dmangos.log;
import dmangos.world.clientdata;
import dmangos.world.inventory;
import dmangos.world.objects : HighGuid, makeGuid, UpdateValues;
public import dmangos.world.defines; // the inventory positions are part of this module's interface
import dmangos.world.spells;
import dmangos.world.stats : healthBonusFromStamina, manaBonusFromIntellect;
import dmangos.world.updatefields : maxPlayerSkills, TypeId;
import dmangos.world.worlddata;

// ---------------------------------------------------------------------------
// Constants (SharedDefines.h, Player.h, ItemPrototype.h)
// ---------------------------------------------------------------------------

private enum : uint
{
    skillPoisons = 40, skillLockpicking = 633, skillFishing = 356, skillCooking = 185,
    skillFirstAid = 129, skillRiding = 762,
    abilityLearnedOnGetRaceOrClassSkill = 2,
}

/// `TaxiMaskSize`
enum taxiMaskSize = 8;
/// `MAX_ENCHANTMENT_SLOT`
enum maxEnchantmentSlot = 7;
/// `AT_LOGIN_FIRST`
enum uint atLoginFirst = 0x20;

private enum uint powerRageDefault = 1000, powerEnergyDefault = 100;

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
        return "0 ".replicate(exploredZonesSize);
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

/// A packet `Player::learnSpell` sends to a player in the world.
struct LearnEvent
{
    enum Kind
    {
        learned,    /// `SMSG_LEARNED_SPELL`
        superseded, /// `SMSG_SUPERCEDED_SPELL`: `spell` is replaced by `newSpell`
    }

    Kind kind;
    uint spell;
    uint newSpell;
}

/// What `CharacterBuilder.learnInWorld` changed.
struct LearnResult
{
    KnownAbilities abilities;    /// the abilities now
    LearnEvent[] events;         /// in the order CMaNGOS sends them
    NewSpell[] savedSpells;      /// `character_spell` rows to write
    uint[] removedSpells;        /// `character_spell` rows to delete
    NewSkill[] savedSkills;      /// `character_skills` rows to write; a `max` of 0 deletes the row
}

/// `SkillRangeType`
enum SkillRange { none, language, level, mono, rank }

/// `GetSkillRangeType`
SkillRange skillRangeType(const(SkillLineEntry)* skill, bool racial)
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

/// `IsProfessionOrRidingSkill`
bool isProfessionOrRiding(const(SkillLineEntry)* skill)
{
    return skill.categoryId == SkillCategory.profession || skill.id == skillFishing || skill.id == skillCooking
        || skill.id == skillFirstAid || skill.id == skillRiding;
}

/// Creates one character, or loads one's abilities; see the module documentation. Use once per character.
final class CharacterBuilder : InventoryOwner
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
        bool dualWield;
        uint characterGuid;
        UpdateValues fields;  // the new character's: the inventory writes its slot fields here
        Inventory inventory;
        uint ammoId;
        bool loading; // loadAbilities: talent spells come from the database, not from creation
        bool inWorld; // learnInWorld: the player is told what it learns
        LearnEvent[] events;
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
        characterGuid = guid;
        fields = UpdateValues(TypeId.player);
        inventory = new Inventory(world, this, &fields, nextItemGuid);

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
        result.health = cast(uint) round(max(classStats.baseHealth + healthBonusFromStamina(stats.stats[Stat.stamina]),
            1.0f));
        if (classStats.baseMana > 0)
            result.power[Power.mana] = cast(uint) round(classStats.baseMana
                + manaBonusFromIntellect(stats.stats[Stat.intellect]));
        result.power[Power.energy] = powerEnergyDefault; // every player starts with full (if unused) energy

        if (auto raceEntry = client.races.lookup(req.race))
            result.taxiMask[0] = raceEntry.startingTaxiMask;

        initPrimaryProfessions();
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
        initPrimaryProfessions();

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
        result = abilities();
        return true;
    }

    /**
     * `Player::learnSpell` for a character in the world, as a trainer teaches it: after `loadAbilities`
     * has loaded what the character knows, learns `id` and what comes with it (lower ranks, dependent
     * spells, skills). The result says what to tell the player and what to save.
     */
    LearnResult learnInWorld(uint id)
    {
        loading = false;
        inWorld = true;
        learnSpell(id, false);

        LearnResult result;
        result.abilities = abilities();
        result.events = events;
        foreach (spellId, spell; spells)
        {
            if (spell.state == SpellState.removed)
                result.removedSpells ~= spellId;
            else if (spell.state != SpellState.unchanged)
                result.savedSpells ~= NewSpell(spellId, spell.active, spell.disabled);
        }
        foreach (skillId; skillOrder)
        {
            const skill = skills[skillId];
            if (skill.state == SkillState.deleted)
                result.savedSkills ~= NewSkill(skillId, 0, 0);
            else if (skill.state != SkillState.unchanged)
                result.savedSkills ~= NewSkill(skillId, skill.value, skill.max);
        }
        return result;
    }

    // -----------------------------------------------------------------------
    // InventoryOwner
    // -----------------------------------------------------------------------

    @property ulong ownerGuid() const
    {
        return makeGuid(HighGuid.player, characterGuid);
    }

    @property uint ownerLevel() const
    {
        return level;
    }

    /// A new character has no honor rank.
    @property ubyte highestHonorRank() const
    {
        return 0;
    }

    @property ubyte ownerClass() const
    {
        return request.classId;
    }

    @property ubyte ownerRace() const
    {
        return request.race;
    }

    /// `Player::HasSpell`
    bool hasSpell(uint id) const
    {
        if (auto spell = id in spells)
            return spell.state != SpellState.removed && !spell.disabled;
        return false;
    }

    ushort skillRank(uint skill) const
    {
        return skillValue(skill);
    }

    @property bool dualWields() const
    {
        return dualWield;
    }

    @property bool alive() const
    {
        return true;
    }

    @property bool inCombat() const
    {
        return false;
    }

private:
    /// The skills, in slot order, and the spellbook as they are now.
    KnownAbilities abilities() const
    {
        KnownAbilities result;
        foreach (id; skillOrder)
        {
            const skill = skills[id];
            if (skill.state != SkillState.deleted)
                result.skills ~= KnownSkill(id, skill.value, skill.max, skill.step);
        }
        foreach (id, spell; spells)
            if (spell.state != SpellState.removed && spell.active && !spell.disabled)
                result.spellbook ~= id;
        result.spellbook.sort();
        result.freePrimaryProfessions = freePrimaryProfessions;
        return result;
    }

    /// `Player::InitPrimaryProfessions`: `MaxPrimaryTradeSkill`, or 10 from the `TradeSkill.GMIgnore` account level.
    void initPrimaryProfessions()
    {
        freePrimaryProfessions = cast(uint) security < settings.gmIgnoreMaxPrimarySkills
            ? settings.maxPrimaryTradeSkill : 10;
    }

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
        if (addSpell(id, active, true, dependent, false) && inWorld)
            events ~= LearnEvent(LearnEvent.Kind.learned, id);
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
                dualWield = true;
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
                                if (inWorld)
                                    events ~= LearnEvent(LearnEvent.Kind.superseded, otherId, id);
                                other.active = false;
                                if (other.state != SpellState.newSpell)
                                    other.state = SpellState.changed;
                                supercededOld = true;
                            }
                            else if (otherId == id)
                            {
                                if (inWorld)
                                    events ~= LearnEvent(LearnEvent.Kind.superseded, id, otherId);
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
            {
                if (inWorld && node.active)
                    learnSpell(node.spell, true); // told, as a spell learned in the world
                else
                    addSpell(node.spell, node.active, true, true, false);
            }

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
    const(SkillRaceClassInfoEntry)* skillInfo(uint id,
        scope bool delegate(const ref SkillRaceClassInfoEntry) filter = null) const
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
    // Items (Player::StoreNewItemInBestSlots, on dmangos.world.inventory)
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
            auto item = inventory[inventorySlotBag0, i];
            if (item is null)
                continue;
            ushort dest;
            if (inventory.canEquip(nullSlot, dest, item, false) == InventoryResult.ok)
            {
                inventory.remove(inventorySlotBag0, i);
                inventory.equip(dest, item);
                continue;
            }
            ItemPosCount[] storeDest;
            ubyte bagSlot;
            if (inventory.canStore(nullBag, nullSlot, storeDest, item, false, bagSlot) == InventoryResult.ok)
            {
                inventory.remove(inventorySlotBag0, i);
                item = inventory.store(storeDest, item);
            }
            setAmmo(item.entry);
        }
    }

    bool storeNewItemInBestSlots(uint entry, uint amount)
    {
        while (amount > 0)
        {
            ushort dest;
            if (inventory.canEquipNew(nullSlot, dest, entry, false) != InventoryResult.ok)
                break;
            inventory.equipNew(dest, entry);
            inventory.autoUnequipOffhand();
            --amount;
        }
        if (amount == 0)
            return true;

        ItemPosCount[] dest;
        const result = inventory.canStoreNew(inventorySlotBag0, nullSlot, dest, entry, amount);
        if (result == InventoryResult.ok)
        {
            inventory.storeNew(dest, entry);
            return true;
        }
        error!"cannot equip or store initial item %s for race %s class %s: %s"(entry, request.race,
            request.classId, result);
        return false;
    }

    /// `Player::SetAmmo`
    void setAmmo(uint entry)
    {
        if (entry && ammoId != entry && inventory.canUseAmmo(entry) == InventoryResult.ok)
            ammoId = entry;
    }

    // -----------------------------------------------------------------------
    // Output
    // -----------------------------------------------------------------------

    void collect(ref NewCharacter result)
    {
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            if (const item = inventory.equipped(slot))
                result.equipmentCache[slot][0] = item.entry;
        if (const bag = inventory[inventorySlotBag0, inventorySlotBagStart])
            result.equipmentCache[equipmentSlotEnd][0] = bag.entry;

        // What was created and put somewhere, in the order it was created.
        auto placed = inventory.all();
        placed.sort!((a, b) => a.guid < b.guid);
        foreach (item; placed)
        {
            NewItem row;
            row.guid = item.guid;
            row.entry = item.entry;
            row.count = item.count;
            row.duration = item.proto.duration;
            row.charges = item.proto.spellCharges;
            row.flags = item.bound ? itemDynFlagBound : 0;
            row.durability = item.proto.maxDurability;
            row.containerGuid = item.container is null ? 0 : item.container.guid;
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
        ids.sort();
        foreach (id; ids)
        {
            const spell = spells[id];
            if (!spell.dependent && spell.state != SpellState.removed)
                result.spells ~= NewSpell(id, spell.active, spell.disabled);
        }
    }
}

/**
 * `Player::ValidateAppearance`: every chosen look must exist in `CharSections.dbc` and
 * `CharacterFacialHairStyles.dbc`.
 */
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
    const NewSkill[] skills = [NewSkill(skillUnarmed, 1, 5), NewSkill(skillSwords, 1, 5),
        NewSkill(skillCommon, 300, 300)];
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
    assert(c.skills.canFind(NewSkill(skillFireMagic, 5, 5)), "a maximized skill starts at the level cap");
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
    assert(builder.create(1, 1, AccountLevel.gameMaster, CreateRequest("Gm", raceHuman, PlayerClass.warrior), false,
        c));
    assert(c.level == 10);
    assert(!new CharacterBuilder(world, client, settings, () => nextGuid++).create(2, 1, AccountLevel.player,
        CreateRequest("Nope", raceOrc, classMage), false, c));

    assert(validateAppearance(client, raceHuman, 0, 1, 0, 0, 0, 0));
    assert(!validateAppearance(client, raceHuman, 0, 5, 0, 0, 0, 0), "hair style 5 does not exist");
}

/// Loading a saved character learns its default spells again, and the spells its skills teach.
unittest
{
    auto client = testClientData();
    auto world = testWorldData(client);
    auto builder = new CharacterBuilder(world, client, CreationSettings.init, () => 1u);
    KnownAbilities known;
    // Saved: the sword skill (which teaches One-Handed Swords) and an inactive fireball.
    assert(builder.loadAbilities(raceHuman, PlayerClass.warrior, 1, AccountLevel.player,
        [NewSkill(skillSwords, 1, 5), NewSkill(424242, 1, 1)], [NewSpell(spellFireball, false, false)], known));
    assert(known.skills[0] == KnownSkill(skillSwords, 1, 5, 0), "saved skills keep their place");

    // The default spells, what they teach, and what the skills teach, but not the inactive spell.
    assert(known.spellbook.canFind(spellOneHandedSwords) && known.spellbook.canFind(spellLanguageCommon));
    assert(known.spellbook.canFind(spellPassiveTrainer) && known.spellbook.canFind(spellLearnedByPassive));
    assert(!known.spellbook.canFind(spellFireball));
    assert(known.freePrimaryProfessions == CreationSettings.init.maxPrimaryTradeSkill);

    KnownAbilities none;
    assert(!new CharacterBuilder(world, client, CreationSettings.init, () => 1u)
        .loadAbilities(raceOrc, classMage, 1, AccountLevel.player, null, null, none));
}
