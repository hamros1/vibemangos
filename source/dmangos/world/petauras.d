/**
 * What a pet has of its own and of its owner, mixed into `dmangos.world.character.Character` (the owner):
 * $(UL
 * $(LI Its passive auras: those of its family's skill lines (`CreatureFamily.dbc`; the "learned on getting the skill"
 *   spells of `SkillLineAbility.dbc`: a hunter pet's "Tamed Pet Passive" 8875, 19580 .. 19591, 20784; a demon's 18727
 *   .. 18742), the passive spells it knows (Great Stamina), and those its owner's spells give it (`spell_pet_auras`:
 *   Master Demonologist, Spirit Bond). Cast by the pet on itself (`refreshPetPassives`), at its level.)
 * $(LI Its owner's spell modifiers (talents) on its spells and auras (`petSpellMod`, `petEffectMod`; CMaNGOS's
 *   `GetSpellModOwner`): most pet talents are modifiers of all the effects of those passives (Endurance Training
 *   adds 15 to "Max Health increased by 0%", Unleashed Fury 20 to "Damage increased by 0%", Fel Stamina, Fel Intellect,
 *   Unholy Power, Thick Hide, Ferocity, Bestial Swiftness, Bestial Discipline; Frenzy to its proc's chance), so the
 *   passives are cast again as the owner's modifiers change. A modifier of a spell only for outdoors (Bestial
 *   Swiftness, `SPELL_ATTR_OUTDOORS_ONLY`) counts while the pet is outdoors.)
 * $(LI `SPELL_EFFECT_APPLY_AREA_AURA_PET`: an aura of the pet's own with it is given to its owner too, as the pet's
 *   (Master Demonologist: "both the Warlock and the summoned demon"; Spirit Bond: "you and your pet"; Soul Link); one
 *   of the owner's own to its pet (`updatePetAreaAuras`, each second, and as the pet comes or goes).)
 * $(LI `SPELL_AURA_SPLIT_DAMAGE_PCT`: of the damage about to hit its bearer, the aura's share goes to the aura's caster
 *   instead (`splitDamagePct`): Soul Link's copy on the warlock, cast by the demon ("30% of all damage taken by the
 *   caster is taken by your ... demon instead"); the demon's own (its caster itself) splits nothing.)
 * $(LI Soul Link's spell (a dummy at the pet: `petAuraDummy`) has the pet cast the aura `spell_pet_auras` names; Demonic
 *   Sacrifice's kill of the pet gives the warlock what its tooltip names for the demon (`petSacrificed`), which a demon
 *   summoned cancels.)
 * )
 */
module dmangos.world.petauras;

import dmangos.world.clientdata : ClientData;

/// The passive spells of a family's pets (`CreatureFamily.dbc`'s skill lines, the spells `SkillLineAbility.dbc` has a
/// pet learn as it gets the skill), as `isPassive` says of each.
uint[] familyPassives(const ClientData client, uint family, scope bool delegate(uint spell) isPassive)
{
    uint[] spells;
    const entry = client.creatureFamilies.lookup(family);
    if (entry is null)
        return null;
    foreach (skill; entry.skillLines)
        if (skill)
            foreach (ability; client.abilitiesForSkill(skill))
                if (ability.learnOnGetSkill && isPassive(ability.spellId))
                {
                    bool known;
                    foreach (s; spells)
                        known |= s == ability.spellId;
                    if (!known)
                        spells ~= ability.spellId;
                }
    return spells;
}

/// See the module documentation.
mixin template PetAuraRules()
{
    import dmangos.world.auras : Aura, AuraType, makeAura;
    import dmangos.world.creature : Creature;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.spellmods : applySpellMod, effectOp, SpellModOp;
    import dmangos.world.spells : SpellInfo;

    /// The owner's modifiers that count for `pet`'s spells: an outdoors-only talent's while the pet is outdoors.
    private const(Aura)[] petModifiers(Creature pet)
    {
        enum uint onlyOutdoors = 0x8000; // SPELL_ATTR_OUTDOORS_ONLY
        bool outdoors = true, checked;
        const(Aura)[] mods;
        foreach (aura; player.auras.list)
        {
            if (!aura.has(AuraType.addFlatModifier) && !aura.has(AuraType.addPctModifier))
                continue;
            if (aura.spell.attributes & onlyOutdoors)
            {
                if (!checked)
                {
                    checked = true;
                    outdoors = petOutdoors(pet);
                }
                if (!outdoors)
                    continue;
            }
            mods ~= aura;
        }
        return mods;
    }

    /// Whether `pet` is outdoors (where the map has no buildings to tell, it is).
    private bool petOutdoors(Creature pet)
    {
        if (pet is null)
            return true;
        if (auto terrain = map.collision)
            if (terrain.hasVmaps)
            {
                const p = pet.position;
                return terrain.isOutdoors(p.x, p.y, p.z + 2.0f);
            }
        return true;
    }

    /// `value` of `spell`'s property `op` as `pet` casts it: with this owner's modifiers (its talents).
    package T petSpellMod(T)(SpellModOp op, const(SpellInfo)* spell, T value, Creature pet)
    {
        if (player is null)
            return value;
        return applySpellMod(petModifiers(pet), op, *spell, value);
    }

    /// The value of effect `i` of `pet`'s `spell`, with this owner's modifiers of its index and of all effects.
    package int petEffectMod(const(SpellInfo)* spell, size_t i, int value, Creature pet)
    {
        if (player is null)
            return value;
        const mods = petModifiers(pet);
        return applySpellMod(mods, SpellModOp.allEffects, *spell, applySpellMod(mods, effectOp(i), *spell, value));
    }

    private bool petOutdoorsWas = true; // where the pet was at its passives' last casting

    /**
     * `pet` casts its passive auras on itself again, with this owner's modifiers as they are now (see the module
     * documentation); the ones it had of them go first. Its stats follow (`showPetStats`, at its next tick).
     */
    package void refreshPetPassives(Creature pet)
    {
        import dmangos.world.petauras : familyPassives;
        import dmangos.world.spellcast : effectValue;
        import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

        auto state = pet is null ? null : pet.petData;
        if (state is null || player is null || pet is charmed_ || !pet.alive)
            return;
        foreach (id; state.passives)
            foreach (aura; pet.auras.list.dup)
                if (aura.spell.id == id && aura.caster == pet.guid)
                    pet.auras.remove(aura, pet.values);
        state.passives = null;
        uint[] spells = familyPassives(context.client, pet.template_.family, (uint id) {
            const s = context.data.spells.spell(id);
            return s !is null && s.isPassive;
        });
        foreach (s; state.spells)
            if (const info = context.data.spells.spell(s.spell))
                if (info.isPassive && info.hasEffect(SpellEffect.applyAura))
                    spells ~= s.spell;
        foreach (aura; player.auras.list) // the owner's talents' (`spell_pet_auras`)
            if (aura.caster == player.guid)
                if (const given = context.data.pets.petAuraOf(aura.spell.id, pet.template_.entry))
                    spells ~= given;
        const level = pet.values.get!UNIT_FIELD_LEVEL;
        petOutdoorsWas = petOutdoors(pet);
        foreach (id; spells)
        {
            const spell = context.data.spells.spell(id);
            if (spell is null || pet.auras.find(id) !is null)
                continue;
            castOnPet(pet, spell, level);
            state.passives ~= id;
        }
        updatePetAreaAuras();
    }

    /// `pet` casts the aura of `spell` on itself at `level`, its owner's modifiers on its values.
    private Aura castOnPet(Creature pet, const(SpellInfo)* spell, uint level)
    {
        import std.random : uniform01;
        import dmangos.world.spellcast : duration, effectValue;

        int[3] values;
        foreach (j; 0 .. 3)
            if (spell.effect[j] == SpellEffect.applyAura || spell.effect[j] == SpellEffect.applyAreaAuraParty
                    || spell.effect[j] == SpellEffect.applyAreaAuraPet)
                values[j] = petEffectMod(spell, j, effectValue(*spell, j, level, uniform01(map.random)), pet);
        const ms = duration(*spell, context.client, level);
        bool isNew;
        auto aura = pet.auras.apply(makeAura(spell, pet.guid, level, ms, true, values), pet.values, isNew);
        if (map.findObject(pet.guid) is pet) // (not while it is being made)
            map.flushObjectChanges(pet);
        return aura;
    }

    /// An aura of this player's began or ended: a modifier (a talent) or a pet aura's spell changes its pet's passives.
    package void petOwnerAuraChanged(Aura aura, bool apply)
    {
        auto pet = ownPet;
        if (pet is null || pet.petData is null || !pet.alive)
            return;
        if (aura.has(AuraType.addFlatModifier) || aura.has(AuraType.addPctModifier)
                || aura.spell.id in context.data.pets.petAuras)
            refreshPetPassives(pet);
    }

    /// Whether `spell` has an effect of `SPELL_EFFECT_APPLY_AREA_AURA_PET`; its mask.
    private static ubyte petAreaEffects(const(SpellInfo)* spell)
    {
        ubyte mask;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.applyAreaAuraPet)
                mask |= 1 << i;
        return mask;
    }

    /// The radius of `spell`'s pet area aura (0: anywhere on the map).
    private float petAreaRadius(const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : radius;

        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.applyAreaAuraPet)
                return radius(*spell, i, context.client);
        return 0;
    }

    /**
     * The pet area auras (`SPELL_EFFECT_APPLY_AREA_AURA_PET`): the pet's own are given to this player, this player's
     * own to its pet, while both live within the aura's radius; those whose source is gone go. Each second
     * (`updateAreaAuras`), and as the pet's auras change. A pet that went in or out of doors casts its passives
     * again (an outdoors-only talent: Bestial Swiftness).
     */
    package void updatePetAreaAuras()
    {
        import dmangos.world.player : DeathState;

        if (player is null)
            return;
        auto pet = ownPet;
        const petHere = pet !is null && pet !is charmed_ && pet.alive && map.findObject(pet.guid) is pet;
        const alive = player.deathState == DeathState.alive;
        if (petHere && pet.petData !is null && petOutdoors(pet) != petOutdoorsWas)
            return refreshPetPassives(pet); // (which comes back here)
        bool near(const(SpellInfo)* spell)
        {
            const r = petAreaRadius(spell);
            if (r <= 0)
                return true;
            const a = player.position, b = pet.position;
            return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= r * r;
        }
        // The pet's, on this player.
        foreach (aura; player.auras.list.dup)
            if (aura.caster != player.guid && petAreaEffects(aura.spell))
            {
                Aura source = petHere && aura.caster == pet.guid ? pet.auras.find(aura.spell.id) : null;
                if (source is null || source.caster != pet.guid || !alive || !near(aura.spell))
                    removeAura(aura);
            }
        if (petHere && alive)
            foreach (source; pet.auras.list.dup)
                if (source.caster == pet.guid && petAreaEffects(source.spell) && near(source.spell))
                {
                    if (auto had = player.auras.find(source.spell.id))
                    {
                        if (had.caster != pet.guid || had.amount == source.amount)
                            continue;
                        removeAura(had); // its amounts changed (its owner's talents)
                    }
                    auto copy = makeAura(source.spell, pet.guid, source.casterLevel, -1, true, source.amount);
                    copy.effects &= petAreaEffects(source.spell);
                    addAura(copy);
                }
        // This player's, on its pet.
        if (!petHere)
            return;
        bool changed;
        foreach (aura; pet.auras.list.dup)
            if (aura.caster == player.guid && petAreaEffects(aura.spell))
            {
                auto source = player.auras.find(aura.spell.id);
                if (source is null || source.caster != player.guid || !alive || !near(aura.spell))
                {
                    pet.loseAura(aura, map);
                    changed = true;
                }
            }
        if (alive)
            foreach (source; player.auras.list)
                if (source.caster == player.guid && petAreaEffects(source.spell) && near(source.spell))
                {
                    if (auto had = pet.auras.find(source.spell.id))
                    {
                        if (had.caster != player.guid || had.amount == source.amount)
                            continue;
                        pet.loseAura(had, map);
                    }
                    auto copy = makeAura(source.spell, player.guid, source.casterLevel, -1, true, source.amount);
                    copy.effects &= petAreaEffects(source.spell);
                    bool isNew;
                    pet.auras.apply(copy, pet.values, isNew);
                    changed = true;
                }
        if (changed)
            map.flushObjectChanges(pet);
    }

    /**
     * `SPELL_AURA_SPLIT_DAMAGE_PCT` on this player: of `damage` of school `school` about to hit it, each such aura's
     * share goes to the aura's caster instead, if that is another unit here and alive (Soul Link's copy: its demon),
     * logged as this player's damage to it. Returns what was split off.
     */
    package uint splitDamagePct(uint school, ref uint damage)
    {
        import dmangos.world.spellcast : nonMeleeDamageLog;
        import dmangos.world.unit : Blow, dealDamage;

        uint split;
        foreach (aura; player.auras.list.dup)
            foreach (i; 0 .. 3)
            {
                if (damage == 0 || !(aura.effects & (1 << i)) || aura.type(i) != AuraType.splitDamagePct
                        || !(aura.misc(i) & (1 << school)) || aura.amount[i] <= 0 || aura.caster == player.guid)
                    continue;
                auto caster = map.unit(aura.caster);
                if (!caster || !caster.alive)
                    continue;
                const take = cast(uint)(ulong(damage) * aura.amount[i] / 100);
                if (take == 0)
                    continue;
                damage -= take;
                split += take;
                tellAround(aura.caster, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(aura.caster,
                    player.guid, aura.spell.id, take, school, 0, 0, false, 0, false));
                dealDamage(UnitRef.init, caster, take, Blow.spell(school));
            }
        return split;
    }

    /**
     * A dummy effect of this player's spell at its pet that `spell_pet_auras` gives the pet an aura for (Soul Link:
     * "Lasts as long as the demon is active"): the pet casts it on itself. True if it was one.
     */
    package bool petAuraDummy(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

        auto pet = ownPet;
        if (pet is null || pet.guid != target || !pet.alive || pet is charmed_)
            return false;
        const id = context.data.pets.petAuraOf(spell.id, pet.template_.entry);
        if (!id)
            return false;
        if (const aura = context.data.spells.spell(id))
        {
            if (auto had = pet.auras.find(id))
                pet.auras.remove(had, pet.values);
            castOnPet(pet, aura, pet.values.get!UNIT_FIELD_LEVEL);
            updatePetAreaAuras();
        }
        return true;
    }

    /// `spell` (Demonic Sacrifice) is about to kill this player's pet: what it gives for that demon, after (the
    /// aura's spell; 0: nothing).
    package uint petSacrificed(const(SpellInfo)* spell, Creature pet)
    {
        import dmangos.world.tooltipeffects : sacrificeAuraOf;

        if (pet is null || pet !is ownPet || pet is charmed_)
            return 0;
        return sacrificeAuraOf(spell.id, pet.template_.entry);
    }

    /// A demon is summoned: a sacrifice's effect is cancelled ("The effect is canceled if any Demon is summoned").
    package void demonSummoned()
    {
        import dmangos.world.tooltipeffects : isSacrificeAura;

        foreach (aura; player.auras.list.dup)
            if (isSacrificeAura(aura.spell.id))
                removeAura(aura);
    }
}
