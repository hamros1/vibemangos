/**
 * Talent masks the tooltips contradict. A modifier's spells are its effect's family mask (`spell_affect`, else
 * `EffectItemType`: `dmangos.world.spellmods.affects`); where the world database's mask leaves out spells the 1.12.1
 * tooltip names, the tooltip wins and the missing family flags are added here, for every rank of the talent (the
 * rows name its first). Each row says which spells and why; none of them comes from an emulator.
 */
module dmangos.world.tooltipmasks;

import dmangos.world.spells : SpellData;

/// Family flags `add` to effect `effect` of every rank of the talent whose first rank is `firstRank`.
struct MaskFix
{
    uint firstRank;
    ubyte effect;
    ulong add;
    string why;
}

/// Mage fire damage spells' family flags: Fireball, Fire Blast, Flamestrike, Scorch, Pyroblast, Blast Wave.
private enum ulong mageFireDamage = 0x1 | 0x2 | 0x4 | 0x10 | 0x400000 | 0x800000;
private enum ulong mageBlastWave = 0x800000;

/// See the module documentation.
static immutable MaskFix[] maskFixes = [
    // "Increases your spell damage and critical strike chance": its damage effect's mask has the arcane and frost
    // spells only; its crit's has the fire ones too.
    MaskFix(15058, 0, mageFireDamage, "Arcane Instability: spell damage, the fire spells' too"),
    // "Frost and Fire spells": every fire spell but Blast Wave.
    MaskFix(29438, 0, mageBlastWave, "Elemental Precision: Blast Wave is a fire spell"),
    // "critical strike chance with Fire damage spells": every fire damage spell but Blast Wave.
    MaskFix(28682, 0, mageBlastWave, "Combustion: Blast Wave is a fire damage spell"),
    // "Increases the damage dealt or life drained by your Shadow spells": its direct damage's mask leaves out Death
    // Coil, its damage over time's Curse of Doom and Drain Soul (each named in the other).
    MaskFix(18271, 0, 0x80000, "Shadow Mastery: Death Coil's damage"),
    MaskFix(18271, 1, 0x200000000 | 0x4000, "Shadow Mastery: Curse of Doom's and Drain Soul's ticks"),
    // "your Affliction spells": every one but Drain Soul (Grim Reach's mask, of the same spells, has it).
    MaskFix(18174, 0, 0x4000, "Suppression: Drain Soul is an Affliction spell"),
];

/// Adds the flags of `maskFixes` to the ranks of each talent (built chains: `SpellData.build`).
void fixAffectMasks(SpellData data)
{
    foreach (ref fix; maskFixes)
        foreach (id; data.spells.keys)
        {
            const node = id in data.chains;
            if (id != fix.firstRank && (node is null || node.first != fix.firstRank))
                continue;
            auto spell = data.spells.edit(id);
            const had = spell.casting.affectMask[fix.effect] ? spell.casting.affectMask[fix.effect]
                : spell.itemType[fix.effect];
            spell.casting.affectMask[fix.effect] = had | fix.add;
        }
}
