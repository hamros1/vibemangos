/**
 * Spell data from the world database (`spell_template`, `spell_chain`,
 * `spell_learn_spell`), and the maps derived from them at load:
 * spell chains (`buildChains`), spells learned with other spells
 * (`buildLearnSpells`) and skills learned with spells (`buildLearnSkills`).
 *
 * Only the fields that character creation uses are loaded.
 */
module dmangos.world.spells;

import dmangos.frozen : StaticMap;
import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.clientdata : ClientData;

/// Spell effects that matter when spells are learned.
enum SpellEffect : uint
{
    none = 0,
    instantKill = 1,
    applyAura = 6,
    createItem = 24,
    learnSpell = 36,
    dualWield = 40,
    skillStep = 44,
    parry = 22,
    block = 23,
    proficiency = 60,
    skill = 118,
}

/// An `Attributes` bit: the spell is passive.
enum uint spellAttrPassive = 0x00000040;
/// An `Attributes` bit: the spell is not shown.
enum uint spellAttrDoNotDisplay = 0x00000080;
/// An `AttributesEx` bit: the spell is cast when learned.
enum uint spellAttrExCastWhenLearned = 0x80000000;
/// An `AttributesEx2` bit: the spell may be cast while not shapeshifted.
enum uint spellAttrEx2AllowWhileNotShapeshifted = 0x00080000;
/// An implicit target: the caster's pet.
enum uint targetUnitCasterPet = 5;

/// The `spell_template` fields character creation needs.
struct SpellInfo
{
    uint id;
    uint attributes;
    uint attributesEx;
    uint attributesEx2;
    uint stances;
    uint casterAuraState;
    int[8] reagents;
    uint[3] effect;
    int[3] basePoints;
    int[3] baseDice;
    uint[3] implicitTargetA;
    uint[3] itemType;
    int[3] miscValue;
    uint[3] triggerSpell;
    uint category;
    uint recoveryTime;          /// milliseconds
    uint categoryRecoveryTime;  /// milliseconds
    int equippedItemClass = -1;
    int equippedItemSubClassMask;
    uint spellLevel;            /// `SpellLevel`: the level a trainer teaches it from
    SpellCastInfo casting;      /// what casting it needs (`dmangos.world.spellcast`)

    /// Whether the spell is passive.
    bool isPassive() const pure nothrow @nogc @safe
    {
        return (attributes & spellAttrPassive) != 0;
    }

    /// Whether one of the spell's effects is `wanted`.
    bool hasEffect(SpellEffect wanted) const pure nothrow @nogc @safe
    {
        return effect[].canFind(wanted);
    }

    /// An effect's value without a roll: base points plus base dice.
    int simpleValue(size_t index) const pure nothrow @nogc @safe
    {
        return basePoints[index] + baseDice[index];
    }
}

/// The `spell_template` fields casting needs, beside `SpellInfo`'s own.
struct SpellCastInfo
{
    string name;
    uint school;
    uint dispel;
    uint mechanic;
    uint attributesEx3;
    uint stancesNot;
    uint targets;              /// `Targets`: `TARGET_FLAG_*` the client sends
    uint targetCreatureType;
    uint requiresSpellFocus;
    uint targetAuraState;
    uint castingTimeIndex;
    uint interruptFlags;       /// `SPELL_INTERRUPT_FLAG_*`
    uint auraInterruptFlags;   /// `AURA_INTERRUPT_FLAG_*`
    uint channelInterruptFlags;
    uint procFlags;
    uint procChance;
    uint procCharges;
    uint maxLevel;
    uint baseLevel;
    uint durationIndex;
    uint powerType;
    uint manaCost;
    uint manaCostPerLevel;
    uint manaPerSecond;
    uint manaPerSecondPerLevel;
    uint rangeIndex;
    float speed = 0;
    uint stackAmount;
    uint[8] reagentCount;
    int[3] dieSides;
    float[3] dicePerLevel = 0;
    float[3] realPointsPerLevel = 0;
    uint[3] implicitTargetB;
    uint[3] radiusIndex;
    uint[3] applyAuraName;
    uint[3] amplitude;
    float[3] multipleValue = 0;
    uint[3] chainTarget;
    float[3] pointsPerComboPoint = 0;
    uint spellVisual;
    uint spellIconId;          /// `SpellIconID`
    uint manaCostPercentage;
    uint startRecoveryCategory;
    uint startRecoveryTime;    /// the global cooldown it starts, in milliseconds
    uint maxTargetLevel;
    uint spellFamilyName;
    ulong spellFamilyFlags;
    uint maxAffectedTargets;
    uint dmgClass;             /// `SpellDmgClass`: none, magic, melee, ranged
    uint preventionType;
    float[3] dmgMultiplier = 0;
}

/// `spell_template`'s casting columns, in `SpellCastRow` order.
enum spellCastQuery = "SELECT Id, SpellName, School, Dispel, Mechanic, AttributesEx3, StancesNot, Targets, "
    ~ "TargetCreatureType, RequiresSpellFocus, TargetAuraState, CastingTimeIndex, InterruptFlags, AuraInterruptFlags, "
    ~ "ChannelInterruptFlags, ProcFlags, ProcChance, ProcCharges, MaxLevel, BaseLevel, DurationIndex, PowerType, "
    ~ "ManaCost, ManaCostPerlevel, ManaPerSecond, ManaPerSecondPerLevel, RangeIndex, Speed, StackAmount, "
    ~ "ReagentCount1, ReagentCount2, ReagentCount3, ReagentCount4, ReagentCount5, ReagentCount6, ReagentCount7, "
    ~ "ReagentCount8, EffectDieSides1, EffectDieSides2, EffectDieSides3, EffectDicePerLevel1, EffectDicePerLevel2, "
    ~ "EffectDicePerLevel3, EffectRealPointsPerLevel1, EffectRealPointsPerLevel2, EffectRealPointsPerLevel3, "
    ~ "EffectImplicitTargetB1, EffectImplicitTargetB2, EffectImplicitTargetB3, EffectRadiusIndex1, "
    ~ "EffectRadiusIndex2, EffectRadiusIndex3, EffectApplyAuraName1, EffectApplyAuraName2, EffectApplyAuraName3, "
    ~ "EffectAmplitude1, EffectAmplitude2, EffectAmplitude3, EffectMultipleValue1, EffectMultipleValue2, "
    ~ "EffectMultipleValue3, EffectChainTarget1, EffectChainTarget2, EffectChainTarget3, "
    ~ "EffectPointsPerComboPoint1, EffectPointsPerComboPoint2, EffectPointsPerComboPoint3, SpellVisual, SpellIconID, "
    ~ "ManaCostPercentage, StartRecoveryCategory, StartRecoveryTime, MaxTargetLevel, SpellFamilyName, "
    ~ "SpellFamilyFlags, MaxAffectedTargets, DmgClass, PreventionType, DmgMultiplier1, DmgMultiplier2, "
    ~ "DmgMultiplier3 FROM spell_template";

/// One row of `spellCastQuery` (flat, for `Row.as`).
struct SpellCastRow
{
    uint id;
    string name;
    uint school, dispel, mechanic, attributesEx3, stancesNot, targets, targetCreatureType, requiresSpellFocus,
        targetAuraState, castingTimeIndex, interruptFlags, auraInterruptFlags, channelInterruptFlags, procFlags,
        procChance, procCharges, maxLevel, baseLevel, durationIndex, powerType, manaCost, manaCostPerLevel,
        manaPerSecond, manaPerSecondPerLevel, rangeIndex;
    float speed;
    uint stackAmount;
    uint rc1, rc2, rc3, rc4, rc5, rc6, rc7, rc8;
    int ds1, ds2, ds3;
    float dpl1, dpl2, dpl3;
    float rpl1, rpl2, rpl3;
    uint tb1, tb2, tb3;
    uint ri1, ri2, ri3;
    uint aa1, aa2, aa3;
    uint am1, am2, am3;
    float mv1, mv2, mv3;
    uint ct1, ct2, ct3;
    float pc1, pc2, pc3;
    uint spellVisual, spellIconId, manaCostPercentage, startRecoveryCategory, startRecoveryTime, maxTargetLevel, spellFamilyName;
    ulong spellFamilyFlags;
    uint maxAffectedTargets, dmgClass, preventionType;
    float dm1, dm2, dm3;

    SpellCastInfo toInfo() const
    {
        SpellCastInfo c;
        static foreach (field; ["name", "school", "dispel", "mechanic", "attributesEx3", "stancesNot", "targets",
                "targetCreatureType", "requiresSpellFocus", "targetAuraState", "castingTimeIndex", "interruptFlags",
                "auraInterruptFlags", "channelInterruptFlags", "procFlags", "procChance", "procCharges", "maxLevel",
                "baseLevel", "durationIndex", "powerType", "manaCost", "manaCostPerLevel", "manaPerSecond",
                "manaPerSecondPerLevel", "rangeIndex", "speed", "stackAmount", "spellVisual", "spellIconId", "manaCostPercentage",
                "startRecoveryCategory", "startRecoveryTime", "maxTargetLevel", "spellFamilyName", "spellFamilyFlags",
                "maxAffectedTargets", "dmgClass", "preventionType"])
            __traits(getMember, c, field) = __traits(getMember, this, field);
        c.reagentCount = [rc1, rc2, rc3, rc4, rc5, rc6, rc7, rc8];
        c.dieSides = [ds1, ds2, ds3];
        c.dicePerLevel = [dpl1, dpl2, dpl3];
        c.realPointsPerLevel = [rpl1, rpl2, rpl3];
        c.implicitTargetB = [tb1, tb2, tb3];
        c.radiusIndex = [ri1, ri2, ri3];
        c.applyAuraName = [aa1, aa2, aa3];
        c.amplitude = [am1, am2, am3];
        c.multipleValue = [mv1, mv2, mv3];
        c.chainTarget = [ct1, ct2, ct3];
        c.pointsPerComboPoint = [pc1, pc2, pc3];
        c.dmgMultiplier = [dm1, dm2, dm3];
        return c;
    }
}

/// A spell's place in its chain: the rank before, the first rank, its rank, and a spell it requires.
struct SpellChainNode
{
    uint prev;
    uint first;
    ubyte rank;
    uint req;
}

/// A spell learned with another (`spell_learn_spell`, or a learn-spell effect).
struct SpellLearnSpellNode
{
    uint spell;
    bool active;
    bool autoLearned;
}

/// A skill learned with a spell: the skill, its step, and the effect that teaches it.
struct SpellLearnSkillNode
{
    uint skill;
    uint step;
    uint effect;
}

/// See the module documentation.
final class SpellData
{
    enum holdsStaticData = true; // `dmangos.frozen.freezeAll` goes into it

    StaticMap!(uint, SpellInfo) spells;
    StaticMap!(uint, SpellChainNode) chains;
    private uint[][uint] chainNext;                   // prev/req -> spells that follow it
    private SpellLearnSpellNode[][uint] learnSpells;  // spell -> spells learned with it
    private SpellLearnSkillNode[uint] learnSkills;    // spell -> skill it teaches

    /// The spell, or null.
    const(SpellInfo)* spell(uint id) const
    {
        return id in spells;
    }

    /// The rank before `id` in its chain; 0 if none.
    uint prevInChain(uint id) const
    {
        if (auto node = id in chains)
            return node.prev;
        return 0;
    }

    /// The rank of `id` in its chain; 0 if none.
    ubyte rank(uint id) const
    {
        if (auto node = id in chains)
            return node.rank;
        return 0;
    }

    /// Spells listed after `id` in a chain, in id order.
    const(uint)[] nextInChain(uint id) const
    {
        return chainNext.get(id, null);
    }

    /// The spells learned with spell `id`.
    const(SpellLearnSpellNode)[] learnedWith(uint id) const
    {
        return learnSpells.get(id, null);
    }

    /// Whether learning `spell` teaches `learned` too.
    bool learnsSpell(uint spell, uint learned) const
    {
        return learnedWith(spell).canFind!(node => node.spell == learned);
    }

    /// The skill spell `id` teaches, or null.
    const(SpellLearnSkillNode)* learnedSkill(uint id) const
    {
        return id in learnSkills;
    }

    /// Loads the spells and builds every derived map.
    static SpellData load(MySqlConnection world, const ClientData client)
    {
        auto data = new SpellData;
        foreach (row; world.queryAs!(SpellRow, "SELECT Id, Attributes, AttributesEx, AttributesEx2, Stances, "
            ~ "CasterAuraState, Reagent1, Reagent2, Reagent3, Reagent4, Reagent5, Reagent6, Reagent7, Reagent8, "
            ~ "Effect1, Effect2, Effect3, EffectBasePoints1, EffectBasePoints2, EffectBasePoints3, "
            ~ "EffectBaseDice1, EffectBaseDice2, EffectBaseDice3, EffectImplicitTargetA1, EffectImplicitTargetA2, "
            ~ "EffectImplicitTargetA3, EffectItemType1, EffectItemType2, EffectItemType3, EffectMiscValue1, "
            ~ "EffectMiscValue2, EffectMiscValue3, EffectTriggerSpell1, EffectTriggerSpell2, EffectTriggerSpell3, Category, RecoveryTime, "
            ~ "CategoryRecoveryTime, EquippedItemClass, EquippedItemSubClassMask, SpellLevel "
            ~ "FROM spell_template")())
            data.spells[row.id] = row.toInfo();
        foreach (row; world.queryAs!(SpellCastRow, spellCastQuery)())
            if (auto spell = data.spells.edit(row.id))
                spell.casting = row.toInfo();

        SpellChainRow[] chainRows = world.queryAs!(SpellChainRow,
            "SELECT spell_id, prev_spell, first_spell, `rank`, req_spell FROM spell_chain")();
        LearnRow[] learnRows = world.queryAs!(LearnRow, "SELECT entry, SpellID, Active FROM spell_learn_spell")();
        data.build(client, chainRows, learnRows);
        info!"loaded %s spells, %s spell chain nodes, %s spell-learn links, %s spell-learn skills"(
            data.spells.length, data.chains.length, data.learnSpells.length, data.learnSkills.length);
        return data;
    }

    /// Builds the derived maps from loaded spells and table rows. Tests call this directly.
    void build(const ClientData client, const(SpellChainRow)[] chainRows, const(LearnRow)[] learnRows)
    {
        buildLearnSkills();
        buildChains(client, chainRows);
        buildLearnSpells(client, learnRows);
    }

private:
    /// Spells with a SPELL_EFFECT_SKILL effect teach that skill.
    void buildLearnSkills()
    {
        learnSkills = null;
        foreach (id; ascending(spells.keys.dup))
        {
            const entry = (id in spells);
            foreach (i; 0 .. 3)
            {
                if (entry.effect[i] != SpellEffect.skill)
                    continue;
                const node = SpellLearnSkillNode(cast(uint) entry.miscValue[i], cast(uint) entry.simpleValue(i),
                    entry.effect[i]);
                if (node.skill && node.step)
                {
                    learnSkills[id] = node;
                    break;
                }
            }
        }
    }

    /// The spell chains: talent ranks, then SkillLineAbility forward links, then `spell_chain`.
    void buildChains(const ClientData client, const(SpellChainRow)[] rows)
    {
        chains.clear();
        chainNext = null;

        foreach (talentId; ascending(client.talents.ids.dup))
        {
            const talent = client.talents.lookup(talentId);
            if (!talent.rankId[1])
                continue;
            foreach (j, spellId; talent.rankId)
            {
                if (!spellId || spell(spellId) is null)
                    continue;
                chains[spellId] = SpellChainNode(j > 0 ? talent.rankId[j - 1] : 0, talent.rankId[0],
                    cast(ubyte)(j + 1), 0);
            }
        }

        uint[uint] prevRanks; // forward spell -> its previous rank
        foreach (spellId; client.spellsWithAbilities())
        {
            if (spell(spellId) is null)
                continue;
            foreach (ability; client.abilitiesForSpell(spellId))
            {
                uint forward = ability.forwardSpellId;
                if (spellId == 2366) // Herb Gathering, Apprentice
                    forward = 2368;
                if (!forward || spell(forward) is null || client.abilitiesForSpell(forward).length == 0)
                    continue;
                if (forward in chains || forward in prevRanks)
                    continue;
                if (auto prevNode = spellId in chains)
                {
                    chains[forward] = SpellChainNode(spellId, prevNode.first, cast(ubyte)(prevNode.rank + 1), 0);
                    continue;
                }
                prevRanks[forward] = spellId;
            }
        }
        while (prevRanks.length)
        {
            const spellId = ascending(prevRanks.keys)[0];
            const prevId = prevRanks[spellId];
            prevRanks.remove(spellId);
            abilityChainHelper(prevRanks, spellId, prevId, 30);
        }

        foreach (row; rows)
        {
            const node = SpellChainNode(row.prev, row.first, row.rank, row.req);
            if (spell(row.spell) is null)
                continue;
            if (auto existing = row.spell in chains)
            {
                if (existing.rank == node.rank && existing.prev == node.prev && existing.first == node.first
                    && node.req)
                    existing.req = node.req;
                continue;
            }
            if ((node.prev && spell(node.prev) is null) || spell(node.first) is null)
                continue;
            if ((row.spell == node.first) != (node.rank <= 1) || (row.spell == node.first) != (node.prev == 0)
                || (node.rank <= 1) != (node.prev == 0))
                continue;
            if (node.req && spell(node.req) is null)
                continue;
            if (auto pos = client.talentSpellPos(row.spell))
            {
                if (node.rank != pos.rank + 1)
                    continue;
                if (auto talent = client.talents.lookup(pos.talentId))
                {
                    if (node.first != talent.rankId[0]
                        || (node.rank > 1 && node.prev != talent.rankId[node.rank - 2])
                        || node.req != talent.dependsOnSpell)
                        continue;
                }
            }
            chains[row.spell] = node;
        }

        foreach (id; ascending(chains.keys.dup))
        {
            const node = chains[id];
            if (node.prev)
                chainNext[node.prev] ~= id;
            if (node.req)
                chainNext[node.req] ~= id;
        }
    }

    void abilityChainHelper(const uint[uint] prevRanks, uint spellId, uint prevId, uint depth)
    {
        if (spellId in chains)
            return;
        if (auto prevNode = prevId in chains)
        {
            chains[spellId] = SpellChainNode(prevId, prevNode.first, cast(ubyte)(prevNode.rank + 1), 0);
            return;
        }
        auto before = prevId in prevRanks;
        if (before is null)
        {
            chains[prevId] = SpellChainNode(0, prevId, 1, 0);
            chains[spellId] = SpellChainNode(prevId, prevId, 2, 0);
            return;
        }
        if (depth == 0)
        {
            error!"spell chain cycle in SkillLineAbility data at spell %s"(spellId);
            return;
        }
        abilityChainHelper(prevRanks, prevId, *before, depth - 1);
        if (auto prevNode = prevId in chains)
            chains[spellId] = SpellChainNode(prevId, prevNode.first, cast(ubyte)(prevNode.rank + 1), 0);
    }

    /// The spells learned with others: `spell_learn_spell` rows, then SPELL_EFFECT_LEARN_SPELL effects.
    void buildLearnSpells(const ClientData client, const(LearnRow)[] rows)
    {
        learnSpells = null;
        foreach (row; rows)
        {
            if (spell(row.spell) is null || spell(row.learned) is null)
                continue;
            if (client.talentSpellPos(row.learned) !is null)
                continue; // talent spells are never learned this way
            learnSpells[row.spell] ~= SpellLearnSpellNode(row.learned, row.active != 0, false);
        }

        foreach (id; ascending(spells.keys.dup))
        {
            const entry = (id in spells);
            foreach (i; 0 .. 3)
            {
                if (entry.effect[i] != SpellEffect.learnSpell)
                    continue;
                const learned = entry.triggerSpell[i];
                if (spell(learned) is null)
                    continue;
                const autoLearned = entry.implicitTargetA[i] == targetUnitCasterPet
                    || client.talentSpellPos(id) !is null || entry.isPassive || entry.hasEffect(SpellEffect.skillStep);
                if (!learnsSpell(id, learned))
                    learnSpells[id] ~= SpellLearnSpellNode(learned, true, autoLearned);
            }
        }
    }

    static uint[] ascending(uint[] ids)
    {
        ids.sort();
        return ids;
    }
}

/// One `spell_chain` row.
struct SpellChainRow
{
    uint spell;
    uint prev;
    uint first;
    ubyte rank;
    uint req;
}

/// One `spell_learn_spell` row.
struct LearnRow
{
    uint spell;
    uint learned;
    uint active;
}

/// One `spell_template` row as loaded (flat, for `Row.as`).
private struct SpellRow
{
    uint id, attributes, attributesEx, attributesEx2, stances, casterAuraState;
    int r1, r2, r3, r4, r5, r6, r7, r8;
    uint e1, e2, e3;
    int bp1, bp2, bp3;
    int bd1, bd2, bd3;
    uint t1, t2, t3;
    uint it1, it2, it3;
    int m1, m2, m3;
    uint ts1, ts2, ts3;
    uint category, recoveryTime, categoryRecoveryTime;
    int equippedItemClass, equippedItemSubClassMask;
    uint spellLevel;

    SpellInfo toInfo() const
    {
        return SpellInfo(id, attributes, attributesEx, attributesEx2, stances, casterAuraState,
            [r1, r2, r3, r4, r5, r6, r7, r8], [e1, e2, e3], [bp1, bp2, bp3], [bd1, bd2, bd3], [t1, t2, t3],
            [it1, it2, it3], [m1, m2, m3], [ts1, ts2, ts3], category, recoveryTime, categoryRecoveryTime,
            equippedItemClass, equippedItemSubClassMask, spellLevel);
    }
}

unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : skillLineAbilityFormat;

    auto data = new SpellData;
    foreach (id; [100, 101, 102, 200, 300, 301])
        data.spells[id] = SpellInfo(id);
    data.spells.edit(300).effect[0] = SpellEffect.learnSpell;
    data.spells.edit(300).triggerSpell[0] = 301;
    data.spells.edit(200).effect[1] = SpellEffect.skill;
    data.spells.edit(200).miscValue[1] = 98;
    data.spells.edit(200).basePoints[1] = 0;
    data.spells.edit(200).baseDice[1] = 1;

    // Ranks 100 -> 101 -> 102 linked through SkillLineAbility.forward_spellid.
    auto client = new ClientData;
    const uint[][] abilities = [
        [1, 8, 100, 0, 0, 0, 0, 0, 101, 0, 0, 0, 0, 0, 0],
        [2, 8, 101, 0, 0, 0, 0, 0, 102, 0, 0, 0, 0, 0, 0],
        [3, 8, 102, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ];
    client.skillLineAbilities = typeof(client.skillLineAbilities).parse(buildDbc(skillLineAbilityFormat, abilities),
        "SkillLineAbility.dbc");
    client.buildIndexes();
    data.build(client, null, [LearnRow(100, 200, 1)]);

    assert(data.prevInChain(101) == 100 && data.prevInChain(102) == 101 && data.prevInChain(100) == 0);
    assert(data.rank(100) == 1 && data.rank(102) == 3);
    assert(data.nextInChain(100) == [101]);
    assert(data.learnsSpell(100, 200) && data.learnedWith(300) == [SpellLearnSpellNode(301, true, false)]);
    assert(data.learnedSkill(200).skill == 98 && data.learnedSkill(200).step == 1);
}
