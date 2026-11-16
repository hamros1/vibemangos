/**
 * Spell data from the world database (`spell_template`, `spell_chain`,
 * `spell_learn_spell`), and the derived maps CMaNGOS's `SpellMgr` builds:
 * spell chains (`LoadSpellChains`), spells learned with other spells
 * (`LoadSpellLearnSpells`) and skills learned with spells (`LoadSpellLearnSkills`).
 *
 * Only the fields that character creation uses are loaded.
 */
module dmangos.world.spells;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.clientdata : ClientData;

/// Spell effects that matter when spells are learned (`SpellEffects`).
enum SpellEffect : uint
{
    none = 0,
    instantKill = 1,
    applyAura = 6,
    createItem = 24,
    learnSpell = 36,
    dualWield = 40,
    skillStep = 44,
    proficiency = 60,
    skill = 118,
}

/// `SPELL_ATTR_PASSIVE`
enum uint spellAttrPassive = 0x00000040;
/// `SPELL_ATTR_DO_NOT_DISPLAY`
enum uint spellAttrDoNotDisplay = 0x00000080;
/// `SPELL_ATTR_EX_CAST_WHEN_LEARNED`
enum uint spellAttrExCastWhenLearned = 0x80000000;
/// `SPELL_ATTR_EX2_ALLOW_WHILE_NOT_SHAPESHIFTED`
enum uint spellAttrEx2AllowWhileNotShapeshifted = 0x00080000;
/// `TARGET_UNIT_CASTER_PET`
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

    /// `IsPassiveSpell`
    bool isPassive() const pure nothrow @nogc @safe
    {
        return (attributes & spellAttrPassive) != 0;
    }

    /// `IsSpellHaveEffect`
    bool hasEffect(SpellEffect wanted) const pure nothrow @nogc @safe
    {
        return effect[].canFind(wanted);
    }

    /// `CalculateSimpleValue`: base points plus base dice.
    int simpleValue(size_t index) const pure nothrow @nogc @safe
    {
        return basePoints[index] + baseDice[index];
    }
}

/// `SpellChainNode`
struct SpellChainNode
{
    uint prev;
    uint first;
    ubyte rank;
    uint req;
}

/// `SpellLearnSpellNode`
struct SpellLearnSpellNode
{
    uint spell;
    bool active;
    bool autoLearned;
}

/// `SpellLearnSkillNode`
struct SpellLearnSkillNode
{
    uint skill;
    uint step;
    uint effect;
}

/// See the module documentation.
final class SpellData
{
    SpellInfo[uint] spells;
    SpellChainNode[uint] chains;
    private uint[][uint] chainNext;                   // prev/req -> spells that follow it
    private SpellLearnSpellNode[][uint] learnSpells;  // spell -> spells learned with it
    private SpellLearnSkillNode[uint] learnSkills;    // spell -> skill it teaches

    /// The spell, or null.
    const(SpellInfo)* spell(uint id) const
    {
        return id in spells;
    }

    /// `GetPrevSpellInChain`
    uint prevInChain(uint id) const
    {
        if (auto node = id in chains)
            return node.prev;
        return 0;
    }

    /// `GetSpellRank`
    ubyte rank(uint id) const
    {
        if (auto node = id in chains)
            return node.rank;
        return 0;
    }

    /// Spells listed after `id` in a chain (`GetSpellChainNext`), in id order.
    const(uint)[] nextInChain(uint id) const
    {
        return chainNext.get(id, null);
    }

    /// `GetSpellLearnSpellMapBounds`
    const(SpellLearnSpellNode)[] learnedWith(uint id) const
    {
        return learnSpells.get(id, null);
    }

    /// `IsSpellLearnToSpell`
    bool learnsSpell(uint spell, uint learned) const
    {
        return learnedWith(spell).canFind!(node => node.spell == learned);
    }

    /// `GetSpellLearnSkill`
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
            ~ "CategoryRecoveryTime, EquippedItemClass, EquippedItemSubClassMask "
            ~ "FROM spell_template")())
            data.spells[row.id] = row.toInfo();

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
    /// `LoadSpellLearnSkills`: spells with a SPELL_EFFECT_SKILL effect teach that skill.
    void buildLearnSkills()
    {
        learnSkills = null;
        foreach (id; ascending(spells.keys))
        {
            const entry = &spells[id];
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

    /// `LoadSpellChains`: talent ranks, then SkillLineAbility forward links, then `spell_chain`.
    void buildChains(const ClientData client, const(SpellChainRow)[] rows)
    {
        chains = null;
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

        foreach (id; ascending(chains.keys))
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

    /// `LoadSpellLearnSpells`: `spell_learn_spell` rows, then SPELL_EFFECT_LEARN_SPELL effects.
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

        foreach (id; ascending(spells.keys))
        {
            const entry = &spells[id];
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

    SpellInfo toInfo() const
    {
        return SpellInfo(id, attributes, attributesEx, attributesEx2, stances, casterAuraState,
            [r1, r2, r3, r4, r5, r6, r7, r8], [e1, e2, e3], [bp1, bp2, bp3], [bd1, bd2, bd3], [t1, t2, t3],
            [it1, it2, it3], [m1, m2, m3], [ts1, ts2, ts3], category, recoveryTime, categoryRecoveryTime,
            equippedItemClass, equippedItemSubClassMask);
    }
}

unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : skillLineAbilityFormat;

    auto data = new SpellData;
    foreach (id; [100, 101, 102, 200, 300, 301])
        data.spells[id] = SpellInfo(id);
    data.spells[300].effect[0] = SpellEffect.learnSpell;
    data.spells[300].triggerSpell[0] = 301;
    data.spells[200].effect[1] = SpellEffect.skill;
    data.spells[200].miscValue[1] = 98;
    data.spells[200].basePoints[1] = 0;
    data.spells[200].baseDice[1] = 1;

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
