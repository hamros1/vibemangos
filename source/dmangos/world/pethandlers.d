/**
 * A player's pet: taming, summoning, its bar and spells, saving and loading it, its experience, and
 * the stable master, mixed into `dmangos.world.character.Character`.
 *
 * A hunter tames a beast (Tame Beast: a twenty-second channel, then the beast is its pet), calls it
 * (Call Pet), dismisses it (Dismiss Pet) and revives it (Revive Pet); a warlock summons a demon, the
 * one it had before going back to rest. The pet comes out beside its owner, follows it, fights for
 * it as told (its bar: attack, follow, stay; aggressive, defensive, passive; its spells, set to cast
 * by themselves or not), and is saved in `character_pet` and `pet_spell`: with its owner when out,
 * in a stable slot, or set aside. It goes away with its owner at logout and on a teleport or a move
 * to another node, and comes back after. A hunter pet gains a quarter of a level's experience, as
 * its owner gains it, up to its owner's level. At a stable master a hunter keeps up to two pets
 * besides the one out.
 */
module dmangos.world.pethandlers;

import dmangos.world.money : Copper;

/// `CLASS_HUNTER`, `CLASS_WARLOCK`
enum ubyte classHunter = 3, classWarlock = 9;

/// Tame Beast: the channel and what makes the beast a pet at its end.
enum uint spellTameBeast = 1515, spellTameBeastDone = 13481;

/// Summon Imp: the imp casts from afar and does not melee.
enum uint spellSummonImp = 688;

enum uint spellEyesOfTheBeast = 1002;

/// The imp's casting distance.
enum float impAttackDistance = 25;

/// `UNIT_FLAG_PET_RENAME`, `UNIT_FLAG_PET_ABANDON`
enum uint unitFlagPetRename = 0x10, unitFlagPetAbandon = 0x20;

/// `UNIT_BYTE2_FLAG_SUPPORTABLE | UNIT_BYTE2_FLAG_AURAS`
enum ubyte petByte2Flags = 0x08 | 0x10;

/// A hunter pet's happiness: its most, and a tamed beast's.
enum uint maxHappiness = 1_050_000, tamedHappiness = 166_500;
/// A newly tamed pet's loyalty points (rebellious, the lowest level).
enum int tamedLoyaltyPoints = 1000;

/// A third of the happiness bar: below one third a pet is unhappy, from two thirds happy.
enum uint happinessLevel = 333_000;

/// A hunter pet's mood, by its happiness.
enum Happiness : ubyte { unhappy = 1, content = 2, happy = 3 }

/// The mood `happiness` is.
Happiness moodOf(uint happiness) pure nothrow @nogc @safe
{
    return happiness < happinessLevel ? Happiness.unhappy : happiness >= 2 * happinessLevel ? Happiness.happy
        : Happiness.content;
}

/// The loyalty points that take a pet to the next loyalty level, and those it starts a level with (levels 1 to 6).
immutable int[6] loyaltyToLevelUp = [5500, 11500, 17000, 23500, 31000, 39500];
/// ditto
immutable int[6] loyaltyAtLevelStart = [2000, 4500, 7000, 10000, 13500, 17500];

/// What a hunter pet's melee damage is multiplied by: a happy pet hits a quarter harder, an unhappy one a quarter softer.
float moodDamageFactor(uint happiness) pure nothrow @nogc @safe
{
    final switch (moodOf(happiness))
    {
    case Happiness.happy:
        return 1.25f;
    case Happiness.content:
        return 1;
    case Happiness.unhappy:
        return 0.75f;
    }
}

/// How much happiness food of `itemLevel` gives a pet of `petLevel` (0: too poor to eat).
uint foodBenefit(uint petLevel, uint itemLevel) pure nothrow @nogc @safe
{
    if (petLevel <= itemLevel + 5)
        return 35_000;
    if (petLevel <= itemLevel + 10)
        return 17_000;
    if (petLevel <= itemLevel + 14)
        return 8000;
    return 0;
}

unittest
{
    assert(moodOf(0) == Happiness.unhappy && moodOf(333_000) == Happiness.content && moodOf(666_000) == Happiness.happy);
    assert(moodDamageFactor(700_000) == 1.25f && moodDamageFactor(100_000) == 0.75f);
    assert(foodBenefit(20, 18) == 35_000 && foodBenefit(30, 18) == 8000 && foodBenefit(40, 18) == 0);
}

/// A hunter pet's focus.
enum uint maxFocus = 100;

/// How long a hunter pet's corpse lies before it is set aside.
enum int petCorpseMs = 60_000;

/// The longest and shortest pet names, in letters.
enum size_t maxPetName = 12, minPetName = 2;

/// `SPELL_ATTR_EX_DISMISS_PET_FIRST`
enum uint spellAttrExDismissPetFirst = 0x0000_0001;

/// `CREATURE_TYPE_BEAST`, `CREATURE_TYPEFLAGS_TAMEABLE`
enum uint creatureTypeBeast = 1, typeFlagTameable = 0x01;

/// Whether a creature can be tamed: a beast of a family, marked tameable.
bool isTameable(const ref imported!"dmangos.world.creature".CreatureTemplate t) pure nothrow @nogc @safe
{
    return t.creatureType == creatureTypeBeast && t.family != 0 && (t.typeFlags & typeFlagTameable);
}

/// Whether a pet name is valid: 2 to 12 letters.
bool validPetName(string name) @safe
{
    import std.uni : isAlpha;
    import std.utf : count, UTFException;

    try
    {
        const length = name.count;
        if (length < minPetName || length > maxPetName)
            return false;
        foreach (dchar c; name)
            if (!isAlpha(c))
                return false;
        return true;
    }
    catch (UTFException)
        return false;
}

/// See the module documentation.
mixin template PetHandlers()
{
    import dmangos.world.money : Copper;
    import std.algorithm.sorting : sort;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.ownership : IdKind;
    import dmangos.world.creature : classStatsKey, Creature;
    import dmangos.world.creatureai : ReactState;
    import dmangos.world.unit : UnitRef;
    import dmangos.world.experience : KillValue;
    import dmangos.world.database : AuraRecord, PetRecord, PetSpellRecord;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : baseMoveSpeed, MovementInfo, MoveType, Position;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.opcodes;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.pet;
    import dmangos.world.petai : isAutocastable;
    import dmangos.world.pethandlers;
    import dmangos.world.spellcast : castResultPacket, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.updatefields;

    private Creature pet_;          // the pet out, alive or dead; null if none
    private uint stableSlots_;      // the stable slots bought
    private bool stableSlotsRead;

    private struct PetPossessionHandoff
    {
        ulong guid;
        uint map, instance;
        MovementInfo movement;
        int remaining, maxDuration;
        int[3] amount;
    }

    // -----------------------------------------------------------------------
    // The pet
    // -----------------------------------------------------------------------

    /// The pet out (alive or its corpse); null if none.
    package @property Creature ownPet()
    {
        return pet_;
    }

    /// Its state.
    private PetState petState()
    {
        return pet_ is null ? null : pet_.petData;
    }

    /// The stable slots bought, read when first needed.
    private @property uint stableSlots()
    {
        if (!stableSlotsRead)
        {
            stableSlots_ = context.database.loadStableSlots(player.data.guid);
            stableSlotsRead = true;
        }
        return stableSlots_;
    }

    /// The saved pets of this player.
    private PetRecord[] savedPets()
    {
        return context.database.loadPets(player.data.guid);
    }

    /**
     * The saved pet for a hunter's Call Pet, Revive Pet and the stables: the pet out with it or
     * set aside (not stabled). Null if none.
     */
    private PetRecord* unstabledPet()
    {
        foreach (ref r; savedPets())
            if (r.slot == PetSlot.current || r.slot > PetSlot.lastStable)
            {
                auto copy = new PetRecord;
                *copy = r;
                return copy;
            }
        return null;
    }

    /// Where a pet comes out: beside its owner, a yard and a half to its left.
    private Position petSpawnPosition()
    {
        import std.math : cos, sin;
        import dmangos.world.petai : petFollowAngle, petFollowDistance;

        const at = player.position;
        const angle = at.orientation + petFollowAngle;
        auto spot = Position(at.x + petFollowDistance * cos(angle), at.y + petFollowDistance * sin(angle), at.z,
            at.orientation);
        const ground = map.groundHeight(spot.x, spot.y, at.z + 2, false);
        if (ground > -100_000)
            spot.z = ground;
        return spot;
    }

    /**
     * The pet's level, health, power, armor, stats, attack
     * power and damage; `full`: at full health and power, else at most what it has.
     */
    private void setPetLevel(Creature creature, uint level, bool full)
    {
        auto state = creature.petData;
        const t = creature.template_;
        const statsEntry = state.type == PetType.hunter ? 1 : t.entry;
        const classStats = classStatsKey(level, t.unitClass) in context.data.creatureClassStats;
        float minScale = 0, maxScale = 0;
        uint minScaleLevel, maxScaleLevel;
        if (state.type == PetType.hunter)
            if (const family = context.client.creatureFamilies.lookup(t.family))
            {
                minScale = family.minScale;
                maxScale = family.maxScale;
                minScaleLevel = family.minScaleLevel;
                maxScaleLevel = family.maxScaleLevel;
            }
        const s = petStats(state.type, *t, level, context.data.pets.statsFor(statsEntry, level), classStats,
            minScale, minScaleLevel, maxScale, maxScaleLevel);
        ref v = creature.values;
        v.set!UNIT_FIELD_LEVEL(level);
        state.base = s;
        if (state.type == PetType.hunter)
        {
            v.set!UNIT_FIELD_MAXPOWER1(0, 0u);
            v.set!UNIT_FIELD_POWER1(0, 0u);
        }
        v.set!UNIT_FIELD_MAXPOWER1(1, 0u); // no rage
        v.set!UNIT_FIELD_POWER1(1, 0u);
        if (s.scale > 0)
            v.set!OBJECT_FIELD_SCALE_X(s.scale);
        refreshPetPassives(creature); // its family's passive auras and its owner's talents' (`dmangos.world.petauras`)
        showPetStats(creature, full);
    }

    /// The experience a pet needs for its next level: a quarter of what a player needs.
    private uint petXpForLevel(uint level)
    {
        return level < context.data.xpForNextLevel.length ? context.data.xpForNextLevel[level] / 4 : 0;
    }

    /**
     * Loading a saved pet or making a new one: a creature of `entry` beside the player, made
     * its pet with `state`, at `level`, with `health` and `mana`. New pets start full.
     * `restoreMana` preserves zero mana on a saved pet. Loading callers finish after restoring its effects.
     */
    private Creature bringPet(PetState state, uint entry, uint modelId, uint level, uint exp, ReactState react,
        uint health, uint mana, uint focus = maxFocus, const PetPossessionHandoff handoff = PetPossessionHandoff.init,
        bool restoreMana = false, bool loading = false)
    {
        import dmangos.world.objects : counterOf;

        auto creature = context.makePetCreature(map, entry, state.number,
            handoff.guid ? handoff.movement.position : petSpawnPosition(), handoff.guid ? counterOf(handoff.guid) : 0);
        if (creature is null)
            return null;
        if (handoff.guid)
            creature.movement = handoff.movement;
        state.owner = player.guid;
        creature.becomePet(player.guid, state);
        ref v = creature.values;
        if (modelId)
        {
            v.set!UNIT_FIELD_DISPLAYID(modelId);
            v.set!UNIT_FIELD_NATIVEDISPLAYID(modelId);
        }
        // The owner's faction, and the flags of something a player controls.
        const faction = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        v.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
        creature.factionTemplate = context.client.factionTemplates.lookup(faction);
        v.set!UNIT_NPC_FLAGS(0u);
        v.set!UNIT_DYNAMIC_FLAGS(0u);
        uint flags = UnitFlags.playerControlled | (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp);
        if (state.type == PetType.hunter)
            flags |= state.renamed ? unitFlagPetAbandon : unitFlagPetRename | unitFlagPetAbandon;
        v.set!UNIT_FIELD_FLAGS(flags);
        v.setByte!UNIT_FIELD_BYTES_2(1, petByte2Flags);
        v.set!UNIT_FIELD_SUMMONEDBY(player.guid);
        // And made by it, as vmangos sets it (and as totems have it here): the 1.12 client showed an attack
        // cursor over a pet without it.
        v.set!UNIT_FIELD_CREATEDBY(player.guid);
        v.set!UNIT_FIELD_PETNUMBER(state.number);
        v.set!UNIT_FIELD_PET_NAME_TIMESTAMP(cast(uint) context.unixTime);
        v.set!UNIT_CREATED_BY_SPELL(state.createdBySpell);
        if (state.type == PetType.hunter)
        {
            // Focus, and happiness; its loyalty level.
            v.setByte!UNIT_FIELD_BYTES_0(3, cast(ubyte) 2);
            v.set!UNIT_FIELD_MAXPOWER1(2, maxFocus);
            v.set!UNIT_FIELD_POWER1(2, focus > maxFocus ? maxFocus : focus);
            v.set!UNIT_FIELD_MAXPOWER1(4, maxHappiness);
            v.set!UNIT_FIELD_POWER1(4, state.happiness > maxHappiness ? maxHappiness : state.happiness);
            v.setByte!UNIT_FIELD_BYTES_1(1, cast(ubyte) state.loyalty);
        }
        else
            v.setByte!UNIT_FIELD_BYTES_0(3, cast(ubyte) 0);
        // As fast as its owner, to follow it.
        creature.speeds[MoveType.walk] = baseMoveSpeed[MoveType.walk];
        creature.speeds[MoveType.run] = baseMoveSpeed[MoveType.run];
        setPetLevel(creature, level, true);
        if (health)
        {
            const most = v.get!UNIT_FIELD_MAXHEALTH;
            v.set!UNIT_FIELD_HEALTH(health > most ? most : health);
        }
        if (state.type != PetType.hunter && (mana || restoreMana))
        {
            const most = v.get!UNIT_FIELD_MAXPOWER1(0);
            v.set!UNIT_FIELD_POWER1(0, mana > most ? most : mana);
        }
        creature.ai.react = react;
        if (state.createdBySpell == spellSummonImp)
            creature.ai.petRangedAttacker(impAttackDistance);
        creature.values.clearChanges();
        map.addObject(creature);
        map.wake(creature.guid);
        pet_ = creature;
        // What only its owner sees, now that it is there.
        if (state.type == PetType.hunter)
        {
            const atMost = level >= context.config.maxPlayerLevel;
            v.set!UNIT_FIELD_PETEXPERIENCE(atMost ? 0 : exp);
            v.set!UNIT_FIELD_PETNEXTLEVELEXP(atMost ? 1000 : petXpForLevel(level));
        }
        else
            v.set!UNIT_FIELD_PETNEXTLEVELEXP(1000u);
        v.set!UNIT_TRAINING_POINTS(shownTrainingPoints(state));
        map.flushObjectChanges(creature);
        player.values.set!UNIT_FIELD_SUMMON(creature.guid);
        flushPlayerChanges();
        if (!loading)
        {
            writePet(PetSlot.current);
            sendPetSpells();
        }
        return creature;
    }

    /// The saved pet `r` comes out. `fullHealth`: at full health and mana (a
    /// demon summoned again); `healthPercent`: a dead hunter pet revived with so much.
    private bool loadPet(const PetRecord r, bool fullHealth = false, uint healthPercent = 0,
        const PetPossessionHandoff handoff = PetPossessionHandoff.init)
    {
        const t = r.entry in context.data.creatureTemplates;
        if (t is null)
            return false;
        if (r.type == PetType.hunter && !isTameable(*t))
            return false;
        uint health = fullHealth ? 0 : r.health, mana = fullHealth ? 0 : r.mana, focus = r.mana;
        if (r.health == 0 && !fullHealth)
        {
            if (r.type == PetType.hunter && healthPercent)
                focus = 0;
            else if (r.type != PetType.summon)
                return false; // a dead hunter pet stays dead
        }
        // A demon has its master's level; a beast no more than its owner's.
        uint level = r.level;
        if (r.type == PetType.summon || level > player.data.level)
            level = player.data.level;
        const savedAuras = context.database.loadPetAuras(r.id), savedCooldowns = context.database.loadPetCooldowns(r.id);
        auto state = PetState.from(r, player.guid);
        auto creature = bringPet(state, r.entry, r.modelId, level, r.exp, cast(ReactState) r.reactState,
            r.health == 0 && healthPercent ? 1 : health, mana, focus, handoff,
            restoreMana: !fullHealth && r.health != 0, loading: true);
        if (creature is null)
            return false;
        if (r.health != 0 || fullHealth)
            restorePetAurasAndCooldowns(savedAuras, savedCooldowns);
        if (r.health == 0 && healthPercent)
        {
            const most = creature.values.get!UNIT_FIELD_MAXHEALTH;
            creature.values.set!UNIT_FIELD_HEALTH(cast(uint)(ulong(most) * healthPercent / 100 > 0
                ? ulong(most) * healthPercent / 100 : 1));
            map.flushObjectChanges(creature);
        }
        writePet(PetSlot.current);
        sendPetSpells();
        return true;
    }

    /**
     * The pet out, saved in `slot`. A dead one is not saved as current; a
     * stable slot taken by another pet has that one set aside; a hunter has only one pet out or set
     * aside, so any other there goes.
     */
    private void writePet(uint slot, bool reconcileSlots = true)
    {
        auto state = petState();
        if (state is null || (pet_ is charmed_ && state.type == PetType.guardian))
            return;
        if (slot == PetSlot.current && !pet_.alive)
            slot = PetSlot.notInSlot;
        ref v = pet_.values;
        const power = state.type == PetType.hunter ? v.get!UNIT_FIELD_POWER1(2) : v.get!UNIT_FIELD_POWER1(0);
        if (state.type == PetType.hunter)
            state.happiness = v.get!UNIT_FIELD_POWER1(4);
        auto r = state.record(pet_.template_.entry, v.get!UNIT_FIELD_NATIVEDISPLAYID, v.get!UNIT_FIELD_LEVEL,
            v.get!UNIT_FIELD_PETEXPERIENCE, pet_.ai.react, pet_.alive ? v.get!UNIT_FIELD_HEALTH : 0, power, slot,
            context.unixTime);
        if (reconcileSlots)
            foreach (other; savedPets())
            {
                if (other.id == r.id)
                    continue;
                if (slot >= PetSlot.firstStable && slot <= PetSlot.lastStable && other.slot == slot)
                    context.database.setPetSlot(player.data.guid, other.id, PetSlot.notInSlot);
                else if (state.type == PetType.hunter && (slot == PetSlot.current || slot > PetSlot.lastStable)
                    && (other.slot == PetSlot.current || other.slot > PetSlot.lastStable))
                    context.database.deletePet(player.data.guid, other.id);
            }
        context.database.savePet(r);
        savePetAurasAndCooldowns(r.id);
    }

    package void checkpointPet()
    {
        if (pet_ !is null && pet_.alive)
            writePet(PetSlot.current, false);
    }

    /// The pet's auras that last and its cooldowns still running, saved with it (`pet_aura`, `pet_spell_cooldown`).
    private void savePetAurasAndCooldowns(uint id)
    {
        AuraRecord[] rows;
        if (pet_.alive)
            foreach (aura; pet_.auras.list)
                if (!aura.passive && aura.duration != 0
                    && (pet_ !is charmed_ || aura.spell.id != charmSpell || aura.caster != player.guid))
                    rows ~= AuraRecord(aura.caster, aura.spell.id, aura.stacks, aura.amount, aura.periodTimer,
                        aura.maxDuration, aura.duration, aura.savedEffectMask, aura.charges);
        context.database.savePetAuras(id, rows);
        ulong[2][] cooldowns;
        const now = context.unixTime;
        foreach (spell, ms; pet_.ai.petCooldowns)
            if (ms >= 1000)
                cooldowns ~= [ulong(spell), cast(ulong)(now + ms / 1000)];
        context.database.savePetCooldowns(id, cooldowns);
    }

    /// The pet's saved auras (with the time they had left) and cooldowns (read before it came: it is saved as it comes), on it.
    private void restorePetAurasAndCooldowns(const(AuraRecord)[] auras, const(ulong[2])[] cooldowns)
    {
        import dmangos.world.auras : Aura, makeAura;

        foreach (ref row; auras)
        {
            const spell = context.data.spells.spell(row.spell);
            if (spell is null || row.remaining == 0)
                continue;
            auto aura = makeAura(spell, row.caster, pet_.values.get!UNIT_FIELD_LEVEL, row.maxDuration,
                Aura.savedPositive(*spell, row.effectMask), row.amount);
            aura.duration = row.remaining;
            if (row.charges)
                aura.charges = row.charges;
            aura.stacks = row.stacks ? row.stacks : 1;
            foreach (i; 0 .. 3)
                if (aura.period[i] > 0 && row.periodTimer[i] > 0)
                    aura.periodTimer[i] = row.periodTimer[i];
            bool isNew;
            pet_.auras.apply(aura, pet_.values, isNew);
        }
        const now = context.unixTime;
        foreach (c; cooldowns)
            if (c[1] > now)
            {
                const left = cast(int)((c[1] - now) * 1000);
                pet_.ai.petCooldowns[cast(uint) c[0]] = left;
                // Its category waits as long (the spells sharing it), no longer than the category's own time.
                if (const info = context.data.spells.spell(cast(uint) c[0]))
                    if (info.category && info.categoryRecoveryTime)
                        pet_.ai.petCategoryCooldowns[info.category] = left < info.categoryRecoveryTime ? left
                            : info.categoryRecoveryTime;
            }
        map.flushObjectChanges(pet_);
    }

    /**
     * The pet goes, saved in `slot` (`deleted`: forgotten), and its bar with it.
     */
    package void unsummonPet(uint slot, bool deleted = false, bool save = true)
    {
        if (pet_ is null)
            return;
        if (pet_ is charmed_) // a charmed creature is let go, not sent away
            return endCharm();
        auto state = petState();
        if (deleted)
            context.database.deletePet(player.data.guid, state.number);
        else if (save)
            writePet(slot);
        if (pet_.ai !is null && pet_.alive)
            pet_.ai.petStopAttack(map);
        if (map.findObject(pet_.guid) is pet_)
            map.removeObject(pet_.guid);
        pet_ = null;
        updatePetAreaAuras(); // what it gave its owner goes (dmangos.world.petauras)
        if (player !is null)
        {
            player.values.set!UNIT_FIELD_SUMMON(0UL);
            flushPlayerChanges();
            deliver(Opcode.SMSG_PET_SPELLS, noPetSpellsPacket());
        }
    }

    /// The pet's bar and spellbook, sent to the owner.
    package void sendPetSpells()
    {
        auto state = petState();
        if (state is null)
            return;
        import dmangos.world.pet : PetCooldown;

        PetCooldown[] cooldowns;
        foreach (spell, ms; pet_.ai.petCooldowns)
            cooldowns ~= PetCooldown(spell, ms > 0 ? ms : 0, 0, 0);
        deliver(Opcode.SMSG_PET_SPELLS, petSpellsPacket(pet_.guid, pet_.ai.react, state.command, state.bar,
            state.spells, cooldowns));
    }

    /// `SMSG_PET_TAME_FAILURE`
    private void sendTameFailure(PetTameFailure reason)
    {
        deliver(Opcode.SMSG_PET_TAME_FAILURE, [cast(ubyte) reason]);
    }

    /// `SMSG_PET_ACTION_FEEDBACK`
    private void sendPetFeedback(PetFeedback feedback)
    {
        deliver(Opcode.SMSG_PET_ACTION_FEEDBACK, [cast(ubyte) feedback]);
    }

    /// The pet out learns (or forgets) `spell` (a game master's doing); its bar is sent again and it is saved.
    package void petLearnsSpell(uint spell, bool learns)
    {
        auto state = petState();
        const info = context.data.spells.spell(spell);
        if (state is null || info is null)
            return;
        if (learns)
            state.learn(spell, info.isPassive, isAutocastable(*info));
        else
            state.unlearn(spell);
        sendPetSpells();
        writePet(PetSlot.current);
    }

    /// The pet out is named `name` (a game master's doing, without the client's name rules).
    package void renamePetTo(string name)
    {
        auto state = petState();
        if (state is null)
            return;
        state.name = name;
        state.renamed = true;
        pet_.values.set!UNIT_FIELD_PET_NAME_TIMESTAMP(cast(uint) context.unixTime);
        map.flushObjectChanges(pet_);
        writePet(PetSlot.current);
    }

    /**
     * What `petcreateinfo_spell` gives a new pet of `entry` (a spell that teaches a pet spell gives that
     * spell). A hunter's beast starts owing the training points of what it knows; and its owner learns
     * the teaching spells of its passive abilities at once, and those of its others (noted with the pet)
     * a little at a time, as the pet uses them (`petUsedSpell`).
     */
    private void learnCreateSpells(PetState state, uint entry)
    {
        enum uint learnSpell = 36, learnPetSpell = 57;
        const spells = entry in context.data.pets.createSpells;
        if (spells is null)
            return;
        int used;
        foreach (id; *spells)
        {
            if (!id)
                break;
            const info = context.data.spells.spell(id);
            if (info is null)
                continue;
            uint learned = id;
            const teaches = info.effect[0] == learnSpell || info.effect[0] == learnPetSpell;
            if (teaches)
                learned = info.triggerSpell[0];
            const taught = context.data.spells.spell(learned);
            if (taught is null)
                continue;
            if (teaches && state.type == PetType.hunter && !player.knowsSpell(id))
            {
                if (taught.isPassive)
                    learn(id);
                else
                    setTeachSpell(state, learned, id);
            }
            state.learn(learned, taught.isPassive, isAutocastable(*taught));
            used += abilityTrainingPoints(learned);
        }
        if (state.type == PetType.hunter)
            state.trainingPoints = -used;
    }

    /// The training points `SkillLineAbility.dbc` asks for `spell` (0 if none).
    private int abilityTrainingPoints(uint spell)
    {
        foreach (a; context.client.abilitiesForSpell(spell))
            return cast(int) a.reqTrainPoints;
        return 0;
    }

    /// The first rank of `spell`'s chain (itself if it has none).
    private uint firstRankOf(uint spell)
    {
        uint s = spell;
        foreach (_; 0 .. 16)
        {
            const prev = context.data.spells.prevInChain(s);
            if (!prev)
                break;
            s = prev;
        }
        return s;
    }

    /// What teaching the pet `spell` costs: its training points, less the most a rank of it the pet knows cost.
    private int trainingCost(const PetState state, uint spell)
    {
        const base = abilityTrainingPoints(spell);
        if (base == 0)
            return 0;
        const first = firstRankOf(spell);
        int spent;
        foreach (s; state.spells)
            if (firstRankOf(s.spell) == first)
            {
                const cost = abilityTrainingPoints(s.spell);
                if (cost > spent)
                    spent = cost;
            }
        return base - spent;
    }

    /**
     * The training points field: a hunter's pet's points, as the client reads them (two shorts: a debt as
     * it is, points to spend as their complement less one); no points for other pets.
     */
    private static uint shownTrainingPoints(const PetState state)
    {
        if (state.type != PetType.hunter)
            return 0;
        const tp = state.trainingPoints;
        return tp < 0 ? cast(uint)(-tp) : cast(uint)(-(tp + 1));
    }

    /// The teaching spells noted with a pet: pairs of the pet's spell and the spell that teaches it.
    private static uint[2][] teachPairs(const PetState state)
    {
        import std.algorithm.iteration : splitter;
        import std.conv : to;

        uint[] numbers;
        foreach (word; state.teachSpells.splitter(' '))
            if (word.length)
                numbers ~= word.to!uint;
        uint[2][] pairs;
        for (size_t i = 0; i + 1 < numbers.length; i += 2)
            if (numbers[i])
                pairs ~= [numbers[i], numbers[i + 1]];
        return pairs;
    }

    /// Notes (or, with teacher 0, forgets) the teaching spell of the pet's `spell`: four at most, as saved.
    private static void setTeachSpell(PetState state, uint spell, uint teacher)
    {
        import std.format : format;

        uint[2][] pairs;
        foreach (p; teachPairs(state))
            if (p[0] != spell)
                pairs ~= p;
        if (teacher && pairs.length < 4)
            pairs ~= [spell, teacher];
        string text;
        foreach (i; 0 .. 4)
            text ~= i < pairs.length ? format!"%s %s "(pairs[i][0], pairs[i][1]) : "0 0 ";
        state.teachSpells = text;
    }

    /// The pet used `spell`: one time in ten its owner learns the spell that teaches it (if it was noted).
    public void petCastSpell(uint spell)
    {
        import std.random : uniform;

        auto state = petState();
        if (state is null || state.type != PetType.hunter)
            return;
        foreach (p; teachPairs(state))
            if (p[0] == spell)
            {
                if (uniform(0, 100, map.random) >= 10)
                    return;
                learn(p[1]);
                setTeachSpell(state, spell, 0);
                writePet(PetSlot.current);
                return;
            }
    }

    /// The pet is taught `spell` (a teaching spell cast at it): it costs its training points.
    package void teachPet(uint spell)
    {
        auto state = petState();
        const info = context.data.spells.spell(spell);
        if (canTeachPet(spell) != SpellCastResult.ok || state.knows(spell))
            return;
        state.trainingPoints -= trainingCost(state, spell);
        const first = firstRankOf(spell);
        uint replaces;
        foreach (known; state.spells.dup)
            if (firstRankOf(known.spell) == first)
            {
                if (replaces)
                    state.unlearn(replaces);
                replaces = known.spell;
            }
        state.learn(spell, info.isPassive, isAutocastable(*info), replaces);
        pet_.values.set!UNIT_TRAINING_POINTS(shownTrainingPoints(state));
        map.flushObjectChanges(pet_);
        sendPetSpells();
        writePet(PetSlot.current);
    }

    /// A higher rank uses the same active ability slot. Passives use none.
    private bool hasPetSkillSlot(const PetState state, uint spell)
    {
        const first = firstRankOf(spell);
        bool[uint] active;
        foreach (known; state.spells)
        {
            const info = context.data.spells.spell(known.spell);
            if (info is null || info.isPassive)
                continue;
            const chain = firstRankOf(known.spell);
            if (chain == first)
                return true;
            active[chain] = true;
        }
        return active.length < 4;
    }

    private bool familyCanLearn(uint familyId, uint spell)
    {
        import std.algorithm.searching : canFind;

        const family = context.client.creatureFamilies.lookup(familyId);
        if (family is null)
            return true;
        bool familySkill;
        foreach (ability; context.client.abilitiesForSpell(spell))
        {
            if (ability.skillId && family.skillLines[].canFind(ability.skillId))
                return true;
            foreach (ref entry; context.client.creatureFamilies.rows)
                if (ability.skillId && entry.skillLines[].canFind(ability.skillId))
                {
                    familySkill = true;
                    break;
                }
        }
        return !familySkill;
    }

    /// Whether the pet out can be taught `spell` now: there is a pet, it is of its level, it has the points.
    package SpellCastResult canTeachPet(uint spell)
    {
        auto state = petState();
        const info = context.data.spells.spell(spell);
        if (state is null || pet_ is null || !pet_.alive)
            return SpellCastResult.noPet;
        if (info is null)
            return SpellCastResult.notKnown;
        if (state.type == PetType.hunter && !familyCanLearn(pet_.template_.family, spell))
            return SpellCastResult.badTargets;
        const first = firstRankOf(spell);
        foreach (known; state.spells)
            if (firstRankOf(known.spell) == first && context.data.spells.rank(known.spell) > context.data.spells.rank(spell))
                return SpellCastResult.lowCastLevel;
        if (!info.isPassive && !hasPetSkillSlot(state, spell))
            return SpellCastResult.tooManySkills;
        if (info.spellLevel > pet_.values.get!UNIT_FIELD_LEVEL)
            return SpellCastResult.lowLevel;
        const cost = trainingCost(state, spell);
        if (cost < 0 || (cost != 0 && state.trainingPoints - cost < 0))
            return SpellCastResult.trainingPoints;
        return SpellCastResult.ok;
    }

    // -----------------------------------------------------------------------
    // Spells
    // -----------------------------------------------------------------------

    /// The cast checks of the pet spells: summoning, calling, reviving, taming.
    package SpellCastResult petCastCheck(const(SpellInfo)* spell, const ref SpellTargets targets)
    {
        // A teaching spell: the pet must be there, of the spell's level, with the training points.
        enum uint learnSpellEffect = 36, learnPetSpellEffect = 57, targetPet = 5;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == learnPetSpellEffect
                    || (spell.effect[i] == learnSpellEffect && spell.implicitTargetA[i] == targetPet))
            {
                const result = canTeachPet(spell.triggerSpell[i]);
                if (result != SpellCastResult.ok)
                    return result;
            }
        enum uint summonPetEffect = 56, summonDeadPetEffect = 109;
        if (spell.id == spellTameBeast)
        {
            // Tame Beast
            auto target = cast(Creature) map.findObject(targets.unit);
            if (target is null)
                return SpellCastResult.badImplicitTargets;
            if (target.values.get!UNIT_FIELD_LEVEL > player.data.level)
                return SpellCastResult.highLevel;
        }
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == summonPetEffect)
            {
                if (player.data.classId == classHunter)
                {
                    if (pet_ !is null)
                    {
                        if (!pet_.alive)
                        {
                            sendTameFailure(PetTameFailure.dead);
                            return SpellCastResult.dontReport;
                        }
                        if (!(spell.attributesEx & spellAttrExDismissPetFirst))
                            return SpellCastResult.alreadyHaveSummon;
                    }
                    auto r = unstabledPet();
                    if (r is null)
                        return SpellCastResult.noPet;
                    if (r.health == 0)
                    {
                        sendTameFailure(PetTameFailure.dead);
                        return SpellCastResult.dontReport;
                    }
                }
                else if (pet_ !is null && !(spell.attributesEx & spellAttrExDismissPetFirst))
                    return SpellCastResult.alreadyHaveSummon;
            }
            else if (spell.effect[i] == summonDeadPetEffect)
            {
                if (pet_ is null)
                {
                    auto r = unstabledPet();
                    if (r is null)
                        return SpellCastResult.noPet;
                    if (r.health != 0)
                    {
                        sendTameFailure(PetTameFailure.notDead);
                        return SpellCastResult.dontReport;
                    }
                }
                else if (pet_.alive)
                    return SpellCastResult.alreadyHaveSummon;
            }
        }
        return SpellCastResult.ok;
    }

    /// The end of Tame Beast's channel: the beast is tamed.
    package void tameBeastChannelDone(ulong target)
    {
        if (const spell = context.data.spells.spell(spellTameBeastDone))
            castSpell(spell, SpellTargets(TargetFlags.unit, target), true, 0);
    }

    /// Creates a normal hunter pet from the template without consuming a world spawn.
    package bool createStaffPet(uint entry)
    {
        if (player.data.classId != classHunter || !player.alive || pet_ !is null || !context.canWrite())
            return false;
        const template_ = entry in context.data.creatureTemplates;
        if (template_ is null || !isTameable(*template_))
            return false;
        foreach (ref pet; savedPets())
            if (pet.slot == PetSlot.current || pet.slot == PetSlot.notInSlot)
                return false; // leave the existing hunter pet callable
        uint number;
        if (!context.takeId(IdKind.pet, number))
            return false;
        auto state = new PetState;
        state.number = number;
        state.type = PetType.hunter;
        state.createdBySpell = spellTameBeastDone;
        state.name = template_.name;
        state.bar = ActionBar.initial();
        state.happiness = tamedHappiness;
        state.loyalty = 1;
        state.loyaltyPoints = tamedLoyaltyPoints;
        learnCreateSpells(state, entry);
        return bringPet(state, entry, 0, player.data.level, 0, ReactState.defensive, 0, 0) !is null;
    }

    /**
     * `SPELL_EFFECT_TAMECREATURE` (with its cast checks): a hunter with no pet makes a tameable beast
     * of no higher level its pet, at the beast's level and health; the beast itself goes.
     */
    package void tameCreature(const(SpellInfo)* spell, ulong target)
    {
        auto beast = cast(Creature) map.findObject(target);
        if (beast is null)
            return;
        const gm = player.hasFlag(PlayerFlags.gm);
        if (player.data.classId != classHunter && !gm)
            return sendTameFailure(PetTameFailure.unitsCantTame);
        if (beast.petOwner)
            return sendTameFailure(PetTameFailure.creatureAlreadyOwned);
        if (beast.values.get!UNIT_FIELD_LEVEL > player.data.level && !gm)
            return sendTameFailure(PetTameFailure.tooHighLevel);
        if (!isTameable(*beast.template_))
            return sendTameFailure(PetTameFailure.notTameable);
        if (pet_ !is null)
            return sendTameFailure(PetTameFailure.anotherSummonActive);
        if (!beast.alive)
            return sendTameFailure(PetTameFailure.dead);
        uint number;
        if (!context.takeId(IdKind.pet, number))
            return sendTameFailure(PetTameFailure.internalError);
        auto state = new PetState;
        state.number = number;
        state.type = PetType.hunter;
        state.createdBySpell = spell.id;
        state.name = beast.template_.name;
        state.bar = ActionBar.initial();
        state.happiness = tamedHappiness;
        state.loyalty = 1;
        state.loyaltyPoints = tamedLoyaltyPoints; // unhappy, it loses 20 every 12 s: some ten minutes before it rebels
        learnCreateSpells(state, beast.template_.entry);
        const level = beast.values.get!UNIT_FIELD_LEVEL;
        const health = beast.values.get!UNIT_FIELD_HEALTH, maxHealth = beast.values.get!UNIT_FIELD_MAXHEALTH;
        const percent = maxHealth ? (ulong(health) * 100 + maxHealth - 1) / maxHealth : 100;
        const entry = beast.template_.entry, model = beast.values.get!UNIT_FIELD_DISPLAYID;
        // The beast goes, to come back after its respawn time; whoever it fought (the hunter, as it tamed it)
        // is no longer in combat with it.
        beast.ai.dropThreat(map);
        beast.ai.petStopAttack(map);
        map.corpseExpired(beast);
        auto creature = bringPet(state, entry, model, level, 0, ReactState.defensive, 0, 0);
        if (creature is null)
            return sendTameFailure(PetTameFailure.internalError);
        const most = creature.values.get!UNIT_FIELD_MAXHEALTH;
        creature.values.set!UNIT_FIELD_HEALTH(cast(uint)(ulong(most) * percent / 100 > 0 ? ulong(most) * percent / 100 : 1));
        map.flushObjectChanges(creature);
        writePet(PetSlot.current);
    }

    /**
     * `SPELL_EFFECT_SUMMON_PET`: a hunter's Call Pet brings its pet; a warlock's summon sends the demon
     * out back to rest and brings the one of the spell's entry, as it was saved (at full health) or
     * new (with a generated name, its spells from `petcreateinfo_spell`).
     */
    package void summonPetEffect(const(SpellInfo)* spell, size_t i)
    {
        const entry = cast(uint) spell.miscValue[i];
        if (player.data.classId == classHunter || entry == 0)
        {
            if (pet_ !is null)
                return;
            if (auto r = unstabledPet())
                loadPet(*r);
            return;
        }
        demonSummoned(); // a Demonic Sacrifice's effect is cancelled (dmangos.world.petauras)
        if (pet_ !is null)
            unsummonPet(PetSlot.notInSlot);
        foreach (r; savedPets())
            if (r.entry == entry && (r.slot == PetSlot.current || r.slot > PetSlot.lastStable))
                if (loadPet(r, true))
                    return;
        const t = entry in context.data.creatureTemplates;
        if (t is null)
            return;
        uint number;
        if (!context.takeId(IdKind.pet, number))
            return;
        auto state = new PetState;
        state.number = number;
        state.type = PetType.summon;
        state.createdBySpell = spell.id;
        state.name = context.data.pets.generateName(entry, t.name);
        state.bar = ActionBar.initial();
        learnCreateSpells(state, entry);
        bringPet(state, entry, 0, player.data.level, 0, ReactState.defensive, 0, 0);
    }

    /// `SPELL_EFFECT_DISMISS_PET`: the living pet goes back, set aside.
    package void dismissPetEffect()
    {
        if (pet_ is null || !pet_.alive)
            return;
        unsummonPet(PetSlot.notInSlot);
    }

    /**
     * `SPELL_EFFECT_SUMMON_DEAD_PET` (Revive Pet): the dead pet, lying here or set aside, lives again
     * with `percent` of its health.
     */
    package void reviveDeadPet(int percent)
    {
        const share = cast(uint)(percent > 0 ? percent : 1);
        if (pet_ !is null)
        {
            if (pet_.alive)
                return;
            unsummonPet(PetSlot.notInSlot);
        }
        if (auto r = unstabledPet())
            if (r.health == 0)
                loadPet(*r, false, share);
    }

    // -----------------------------------------------------------------------
    // What happens to the pet and its owner
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Charm: a creature made the player's for a while (Enslave Demon, Mind Control, Eyes of the Beast)
    // -----------------------------------------------------------------------

    private Creature charmed_;         // the creature charmed, null if none
    private uint charmedFaction;       // its own faction, back when the charm ends
    private uint charmedFlags;         // its own unit flags, ditto
    private ReactState charmedReaction;
    private uint charmSpell;           // the charm's spell
    private bool possessing;           // the player moves and sees as it (Mind Control, Eyes of the Beast)

    /// The creature charmed, if any.
    package @property Creature charmed()
    {
        return charmed_;
    }

    /**
     * `creature` is the player's for as long as `spell`'s aura lasts (CMaNGOS's `Unit::TakeCharmOf`): a pet the
     * player commands from a pet bar of the creature's own spells, of the player's faction, out of the fights it
     * was in; a pet out is set aside first. `possess` (`SPELL_AURA_MOD_POSSESS`, `MOD_POSSESS_PET`): the player
     * also moves it and sees as it (`TakePossessOf`): the client's control and camera are on it.
     */
    package void takeCharm(Creature creature, const(SpellInfo)* spell, bool possess)
    {
        if (creature is null || !creature.alive || creature is charmed_)
            return;
        if (charmed_ !is null)
            endCharm();
        const ownPet = creature is pet_; // Eyes of the Beast: one's own pet, possessed
        if (pet_ !is null && !ownPet)
            unsummonPet(PetSlot.current); // set aside, as CMaNGOS's `UnsummonPetTemporaryIfAny`
        charmSpell = spell is null ? 0 : spell.id; // GM possession creates no spell aura
        possessing = possess;
        if (!ownPet)
        {
            charmedFaction = creature.values.get!UNIT_FIELD_FACTIONTEMPLATE;
            charmedFlags = creature.values.get!UNIT_FIELD_FLAGS;
            charmedReaction = creature.ai.react;
            creature.ai.dropThreat(map);
            creature.ai.petStopAttack(map);
            auto state = new PetState;
            state.type = PetType.guardian; // never saved: `writePet` keeps no charm
            state.owner = player.guid;
            state.createdBySpell = charmSpell;
            state.name = creature.template_.name;
            state.bar = ActionBar.initial();
            // The possession bar and AI rotation can contain different spells (notably in raids).
            if (const bar = creature.spawn.entry in context.data.creatureControlSpells)
            {
                foreach (id; *bar)
                    if (const info = context.data.spells.spell(id))
                        state.learn(id, info.isPassive, isAutocastable(*info));
            }
            else if (const list = creature.template_.spellList in context.data.creatureSpellLists)
                foreach (entry; *list)
                    if (const info = context.data.spells.spell(entry.spell))
                        state.learn(entry.spell, info.isPassive, isAutocastable(*info));
            creature.petOwner = player.guid;
            creature.petData = state;
            creature.charmSequence = context.nextGameplaySequence();
            const faction = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
            creature.values.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
            creature.factionTemplate = context.client.factionTemplates.lookup(faction);
            creature.values.set!UNIT_FIELD_FLAGS((charmedFlags & ~UnitFlags.pvp) | UnitFlags.playerControlled
                | (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp));
            creature.controllerPlayerFlags = player.values.get!PLAYER_FLAGS;
            creature.ai.react = ReactState.defensive;
            pet_ = creature;
        }
        charmed_ = creature;
        creature.values.set!UNIT_FIELD_CHARMEDBY(player.guid);
        player.values.set!UNIT_FIELD_CHARM(creature.guid);
        map.flushObjectChanges(creature);
        flushPlayerChanges();
        sendPetSpells();
        if (possess)
            possessBegins(creature);
    }

    /// The charm ends (its aura went, the creature died, the player left): the creature is its own again and,
    /// if it lives, turns on the player (CMaNGOS's `Unit::Uncharm`).
    package void endCharm()
    {
        auto creature = charmed_;
        if (creature is null)
            return;
        charmed_ = null;
        if (possessing)
            possessEnds(creature);
        possessing = false;
        creature.values.set!UNIT_FIELD_CHARMEDBY(0UL);
        player.values.set!UNIT_FIELD_CHARM(0UL);
        if (creature.petData !is null && creature.petData.type == PetType.guardian && creature.petOwner == player.guid
                && pet_ is creature)
        {
            if (creature.ai !is null && creature.alive)
                creature.ai.petStopAttack(map);
            creature.petOwner = 0;
            creature.petData = null;
            creature.values.set!UNIT_FIELD_FACTIONTEMPLATE(charmedFaction);
            creature.factionTemplate = context.client.factionTemplates.lookup(charmedFaction);
            creature.values.set!UNIT_FIELD_FLAGS(charmedFlags & ~UnitFlags.playerControlled);
            if (creature.ai !is null)
                creature.ai.react = charmedReaction;
            pet_ = null;
            deliver(Opcode.SMSG_PET_SPELLS, noPetSpellsPacket());
            if (charmSpell && creature.alive && creature.ai !is null
                && canAttack(creature.ai.relatingOf(), relatingNow(), context.client))
                creature.ai.attackedBy(unit, map); // it remembers who held it
        }
        map.flushObjectChanges(creature);
        flushPlayerChanges();
        // Its aura goes with the charm, whichever ended first.
        if (auto aura = creature.auras.find(charmSpell))
            if (aura.caster == player.guid)
                creature.loseAura(aura, map);
    }

    /// Release control while both the player and the native creature are still here.
    package void releaseCharmForHandoff()
    {
        if (channelSpell !is null && channelSpell.id == charmSpell)
            endChannel(true);
        endCharm();
    }

    /// The player takes control of `creature` (`TakePossessOf`): the client moves it and sees as it.
    private void possessBegins(Creature creature)
    {
        import dmangos.world.motion : stopMoving;
        stopMoving(creature, map);
        activeMover = creature.guid;
        ByteWriter w;
        w.putPackedGuid(creature.guid);
        w.put(ubyte(1));
        deliver(Opcode.SMSG_CLIENT_CONTROL_UPDATE, w.data);
        seeFrom(creature.guid);
    }

    /// ... and gives it back: the client moves the player again, and sees as it.
    private void possessEnds(Creature creature)
    {
        activeMover = 0;
        ByteWriter w;
        w.putPackedGuid(creature.guid);
        w.put(ubyte(0));
        deliver(Opcode.SMSG_CLIENT_CONTROL_UPDATE, w.data);
        seeFrom(0);
    }

    /// The unit the client moves when it is not the player's own (a possessed creature); 0 for the player.
    package ulong activeMover;

    /// The pet died: a demon goes back at once; a beast lies dead a while, a third of its happiness lost (not in a battleground).
    public void ownPetDied()
    {
        if (pet_ is null)
            return;
        if (petState().type != PetType.hunter)
            return unsummonPet(PetSlot.notInSlot);
        if (const entry = context.client.maps.lookup(map.id))
            if (!entry.isBattleground)
            {
                const now = pet_.values.get!UNIT_FIELD_POWER1(4);
                pet_.values.set!UNIT_FIELD_POWER1(4, now > happinessLevel ? now - happinessLevel : 0u);
            }
        pet_.corpseTimer = petCorpseMs;
        writePet(PetSlot.notInSlot);
    }

    /// The pet's corpse went: it is set aside, dead.
    public void petCorpseGone(Creature creature)
    {
        if (pet_ !is creature)
            return;
        writePet(PetSlot.notInSlot);
        pet_ = null;
        player.values.set!UNIT_FIELD_SUMMON(0UL);
        flushPlayerChanges();
        deliver(Opcode.SMSG_PET_SPELLS, noPetSpellsPacket());
    }

    /// The owner attacks or is attacked: the pet joins its owner's fight against `enemy`.
    package void petAssistAgainst(ulong enemy)
    {
        guardians.guardiansAssist(enemy); // and the guardians (`dmangos.world.guardians`)
        if (pet_ is null || !pet_.alive || petState().command == CommandState.stay)
            return;
        if (auto other = map.unit(enemy))
            pet_.ai.petAssist(other, map);
        else if (auto creature = map.creatureAt(enemy))
            pet_.ai.petAssist(map.unitOf(creature), map);
    }

    /**
     * A hunter pet's share of its owner's kill, up to its owner's level; each level
     * it gains brings it to full health.
     */
    package void petGainsXp(uint xp)
    {
        if (pet_ is null || !pet_.alive || petState().type != PetType.hunter || xp == 0)
            return;
        ref v = pet_.values;
        uint level = v.get!UNIT_FIELD_LEVEL;
        const most = player.data.level < context.config.maxPlayerLevel ? player.data.level : context.config.maxPlayerLevel;
        if (level < most)
            petLevelsUp(xp, level, most);
        // Its loyalty, at its owner's level too: experience counts towards the next level; a kill earns a little
        // (more at low levels).
        auto state = petState();
        state.xpForNextLoyalty = xp >= state.xpForNextLoyalty ? 0 : state.xpForNextLoyalty - xp;
        if (level <= 100)
            modifyLoyalty(cast(int)((100 - level) / 10 + (6 - state.loyalty)));
    }

    /**
     * A kill's experience for the hunter pet, of its own level (patch 1.7.0: "Hunter pets now gain experience based
     * on the level difference between them and their target"; CMaNGOS's `XP::Gain(pet, victim)` too) on a kill of
     * `value`: all of it alone (`share` 1), or in a group the share its owner had of the kill (`halved`: the half
     * and one of a group whose highest member is grey to the kill).
     */
    package void petGainsKillXp(const KillValue value, float share = 1, bool halved = false)
    {
        import dmangos.world.experience : killGain;
        import std.math : round;

        if (pet_ is null)
            return;
        const xp = killGain(pet_.values.get!UNIT_FIELD_LEVEL, value) * share;
        petGainsXp(cast(uint) round(halved ? xp * 0.5f + 1.0f : xp));
    }

    private void petLevelsUp(uint xp, ref uint level, uint most)
    {
        ref v = pet_.values;
        uint next = v.get!UNIT_FIELD_PETNEXTLEVELEXP, current = v.get!UNIT_FIELD_PETEXPERIENCE + xp;
        while (current >= next && level < most)
        {
            current -= next;
            ++level;
            setPetLevel(pet_, level, true);
            // Each level brings training points: its loyalty level less one.
            auto st = petState();
            st.trainingPoints += cast(int)(st.loyalty > 0 ? st.loyalty - 1 : 0);
            v.set!UNIT_TRAINING_POINTS(shownTrainingPoints(st));
            next = petXpForLevel(level);
            v.set!UNIT_FIELD_PETNEXTLEVELEXP(level >= context.config.maxPlayerLevel ? 1000 : next);
        }
        v.set!UNIT_FIELD_PETEXPERIENCE(level < most ? current : 0);
        map.flushObjectChanges(pet_);
    }

    // -----------------------------------------------------------------------
    // A hunter pet's happiness and loyalty
    // -----------------------------------------------------------------------

    private int happinessTimerMs = 7500, loyaltyTimerMs = 12_000;

    /**
     * Each tick: a hunter pet out and alive loses happiness every 7.5 s (less the more loyal it is, half
     * again in combat), and every 12 s its loyalty moves by its mood: up when happy or content, down when
     * unhappy.
     */
    package void updatePetMood(Duration elapsed)
    {
        if (pet_ is null || !pet_.alive || petState() is null || petState().type != PetType.hunter)
            return;
        const ms = cast(int) elapsed.total!"msecs";
        happinessTimerMs -= ms;
        if (happinessTimerMs <= 0)
        {
            happinessTimerMs += 7500;
            const loyalty = petState().loyalty < 7 ? petState().loyalty : 6;
            int loss = (140 >> loyalty) * 125;
            if (pet_.ai !is null && pet_.ai.inCombat)
                loss = loss * 3 / 2;
            const now = pet_.values.get!UNIT_FIELD_POWER1(4);
            pet_.values.set!UNIT_FIELD_POWER1(4, now > loss ? now - loss : 0u);
            petState().happiness = pet_.values.get!UNIT_FIELD_POWER1(4);
            map.flushObjectChanges(pet_);
        }
        loyaltyTimerMs -= ms;
        if (loyaltyTimerMs <= 0)
        {
            loyaltyTimerMs += 12_000;
            final switch (moodOf(pet_.values.get!UNIT_FIELD_POWER1(4)))
            {
            case Happiness.happy:
                modifyLoyalty(20);
                break;
            case Happiness.content:
                modifyLoyalty(10);
                break;
            case Happiness.unhappy:
                modifyLoyalty(-20);
                break;
            }
        }
    }

    /**
     * Loyalty points gained or lost: past a level's points (and the experience it asks for) the pet's
     * loyalty rises, its training points with it; below none it falls, and a rebellious pet runs off.
     */
    package void modifyLoyalty(int change)
    {
        auto state = petState();
        if (state is null || state.type != PetType.hunter)
            return;
        uint level = state.loyalty >= 1 && state.loyalty <= 6 ? state.loyalty : 1;
        if (level >= 6 && state.loyaltyPoints + change > loyaltyToLevelUp[5])
            return;
        state.loyaltyPoints += change;
        const petLevel = pet_.values.get!UNIT_FIELD_LEVEL;
        if (state.loyaltyPoints < 0)
        {
            if (level > 1)
            {
                --level;
                setLoyalty(level);
                state.loyaltyPoints = loyaltyAtLevelStart[level - 1];
                state.trainingPoints -= petLevel;
            }
            else
            {
                // Rebellious and out of loyalty: one of three, at random. It leaves its master; or it turns
                // aggressive; or it stays where it is, passive. In the last two its points start again at 500.
                import std.random : uniform;

                final switch (uniform(0, 3, map.random))
                {
                case 0:
                    info!"%s: '%s''s pet ran away"(remoteAddress, player.data.name);
                    deliver(Opcode.SMSG_PET_BROKEN, null);
                    state.loyaltyPoints = 0;
                    return unsummonPet(0, true);
                case 1:
                    pet_.ai.react = ReactState.aggressive;
                    state.loyaltyPoints = 500;
                    break;
                case 2:
                    pet_.ai.petStopAttack(map);
                    pet_.ai.react = ReactState.passive;
                    state.command = CommandState.stay;
                    state.hasStay = false;
                    state.loyaltyPoints = 500;
                    break;
                }
                sendPetSpells(); // the bar shows its new mood
                return;
            }
        }
        else if (state.loyaltyPoints > loyaltyToLevelUp[level - 1] && state.xpForNextLoyalty == 0 && level < 6)
        {
            ++level;
            setLoyalty(level);
            state.loyaltyPoints = loyaltyAtLevelStart[level - 1];
            state.trainingPoints += petLevel;
        }
        else
            return;
        pet_.values.set!UNIT_TRAINING_POINTS(shownTrainingPoints(state));
        map.flushObjectChanges(pet_);
        writePet(PetSlot.current);
    }

    /// The pet's loyalty level, and the experience its next one asks for (5% of a level of its owner's).
    private void setLoyalty(uint level)
    {
        auto state = petState();
        state.loyalty = level;
        pet_.values.setByte!UNIT_FIELD_BYTES_1(1, cast(ubyte) level);
        const ownerLevel = player.data.level;
        const at = ownerLevel < context.config.maxPlayerLevel ? ownerLevel : ownerLevel - 1;
        state.xpForNextLoyalty = level >= 6 ? 0
            : (at < context.data.xpForNextLevel.length ? context.data.xpForNextLevel[at] * 5 / 100 : 0);
    }

    /// Feeding the pet (spell effect 101): one of the food item gone, happiness for it by its level.
    package void feedPet(ulong foodGuid)
    {
        if (pet_ is null || !pet_.alive || petState().type != PetType.hunter)
            return;
        auto food = player.inventory.byGuid(foodGuid);
        if (food is null || food.proto is null)
            return;
        const benefit = foodBenefit(pet_.values.get!UNIT_FIELD_LEVEL, food.proto.details.itemLevel);
        if (benefit == 0)
            return;
        player.inventory.destroyCount(food.proto.entry, 1);
        flushInventory();
        const now = pet_.values.get!UNIT_FIELD_POWER1(4);
        pet_.values.set!UNIT_FIELD_POWER1(4, now + benefit > maxHappiness ? maxHappiness : now + benefit);
        petState().happiness = pet_.values.get!UNIT_FIELD_POWER1(4);
        map.flushObjectChanges(pet_);
    }

    /// The owner reaches a new level: a demon rises with its master.
    package void petOwnerLevelChanged()
    {
        if (pet_ is null || !pet_.alive)
            return;
        const level = player.data.level;
        const petLevel = pet_.values.get!UNIT_FIELD_LEVEL;
        if (petState().type == PetType.summon ? petLevel != level : petLevel > level)
        {
            setPetLevel(pet_, level, true);
            map.flushObjectChanges(pet_);
        }
    }

    /// At logout, a teleport to another map, or a move to another node: the pet goes, saved as out
    /// with its owner (or set aside if dead), to come back with it.
    package void petsOnLeave(bool handoff = false)
    {
        endCharm(); // a charm stays where it is, its own again
        if (!handoff)
        {
            guardians.removeGuardians(player is null || player.alive); // at its death, only those not fighting
            unsummonTotems();
            if (player !is null && map !is null)
                checkpointSummons(true);
        }
        if (pet_ !is null)
            unsummonPet(PetSlot.current);
    }

    private PetPossessionHandoff preparePetHandoff(bool sameMap)
    {
        if (sameMap && pet_ !is null && pet_ is charmed_ && pet_.alive && possessing
            && petState().type == PetType.hunter && channelSpell !is null
            && channelSpell.id == spellEyesOfTheBeast && channelTarget == pet_.guid && channelTimer > 0)
            if (auto aura = pet_.auras.find(spellEyesOfTheBeast, player.guid))
                if (aura.duration > 0)
                {
                    writePet(PetSlot.current);
                    return PetPossessionHandoff(pet_.guid, map.id, map.instanceId, pet_.movement,
                        aura.duration, aura.maxDuration, aura.amount);
                }
        petsOnLeave(true);
        return PetPossessionHandoff.init;
    }

    private void detachPossessedPetForHandoff()
    {
        endCharm();
        unsummonPet(PetSlot.current, save: false);
    }

    private static void writePetPossession(ref ByteWriter state, const ref PetPossessionHandoff pet)
    {
        state.put(pet.guid);
        if (!pet.guid)
            return;
        state.put(pet.map);
        state.put(pet.instance);
        pet.movement.write(state);
        state.put(pet.remaining);
        state.put(pet.maxDuration);
        foreach (value; pet.amount)
            state.put(value);
    }

    private static PetPossessionHandoff readPetPossession(ref ByteReader state)
    {
        PetPossessionHandoff pet;
        pet.guid = state.read!ulong;
        if (pet.guid)
        {
            pet.map = state.read!uint;
            pet.instance = state.read!uint;
            pet.movement = MovementInfo.read(state);
            pet.remaining = state.read!int;
            pet.maxDuration = state.read!int;
            foreach (ref value; pet.amount)
                value = state.read!int;
        }
        return pet;
    }

    private bool matchesPetPossession(const ref PetPossessionHandoff pet, const ref PetRecord record)
    {
        import dmangos.world.objects : counterOf, makePetGuid, temporaryCounterStart;

        const at = pet.movement.position;
        const counter = counterOf(pet.guid);
        return pet.guid && pet.map == map.id && pet.instance == map.instanceId && record.type == PetType.hunter
            && record.health && counter >= temporaryCounterStart && pet.guid == makePetGuid(record.id, counter)
            && channelSpell !is null && channelSpell.id == spellEyesOfTheBeast && channelTarget == pet.guid
            && channelTimer > 0 && pet.remaining > 0 && pet.maxDuration >= pet.remaining
            && context.client.isValidMapCoord(map.id, at.x, at.y, at.z, at.orientation);
    }

    private bool resumePetPossession(const ref PetPossessionHandoff pet, const ref PetRecord record)
    {
        import dmangos.world.auras : makeAura;

        if (map.findObject(pet.guid) !is null && !map.isReplica(pet.guid))
        {
            endChannel(true);
            return true; // the original GUID is already authoritative here
        }
        if (!loadPet(record, false, 0, pet))
            return false;
        auto aura = makeAura(channelSpell, player.guid, player.data.level, pet.maxDuration, true, pet.amount);
        aura.duration = pet.remaining;
        bool added;
        if (pet_.receiveAura(aura, map, added) !is null)
            takeCharm(pet_, channelSpell, true);
        else
            endChannel(true);
        return true;
    }

    private enum ubyte loneTotemSlot = 4, guardianSlot = 5;
    private enum ubyte summonCheckpointVersion = 7;
    private bool summonCheckpointExists, detachingSummons;

    private const(ubyte)[] playerSummonState(bool departing, ulong removed = 0)
    {
        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(context.fleet.transportNow());
        const now = context.clock();
        const countAt = state.length;
        state.put(0u);
        uint count;

        void carry(ulong guid, ubyte slot)
        {
            import dmangos.world.migration : MigrantKind;

            if (guid == removed)
                return;
            auto creature = map.creatureAt(guid);
            if (creature is null || !creature.alive)
                return;
            const moved = context.migrants.savePlayerSummon(creature, departing);
            if (moved.kind != MigrantKind.summonedCreature)
                return;
            state.put(slot);
            state.put(moved.spawn);
            state.put(moved.home);
            state.put(creature.totemSpell);
            state.put(creature.totemActive);
            state.put(cast(uint) moved.state.length);
            state.putBytes(moved.state);
            uint tickCount;
            const ticksAt = state.length;
            state.put(tickCount);
            if (slot != guardianSlot)
                foreach (key, deadline; totemTickAt)
                    if (key.totem == creature.guid)
                    {
                        state.put(key.spell);
                        state.put(cast(int) (deadline - now).total!"msecs");
                        ++tickCount;
                    }
            state.patch(ticksAt, tickCount);
            ++count;
        }

        foreach (slot, guid; totems)
            if (guid)
                carry(guid, cast(ubyte) slot);
        if (loneTotem)
            carry(loneTotem, loneTotemSlot);
        foreach (guid; guardians.guardians_)
            carry(guid, guardianSlot);
        const traps = playerTrapState(removed);
        if (!count && !traps.length)
            return null;
        state.patch(countAt, count);
        state.putBytes(traps);
        return state.data;
    }

    private const(ubyte)[] takeSummonsOnHandoff()
    {
        const state = playerSummonState(true);
        detachingSummons = true;
        scope(exit) detachingSummons = false;
        unsummonTotems();
        guardians.removeGuardians(true);
        removeTraps();
        return state;
    }

    /// Save transient effects for this gateway login. A pending removal is still on the map during its callback.
    package bool checkpointSummons(bool immediate = false, ulong removed = 0, bool savePosition = false)
    {
        import dmangos.world.instancescripting : toHex;

        const home = connection.gatewayHome;
        if (!home.node || detachingSummons)
            return true;
        if (!context.canWrite())
            return false;
        const summons = player.alive ? playerSummonState(false, removed) : null;
        const fishing = player.alive && bobber && bobber != removed ? fishingRecoveryState() : null;
        const ground = player.alive && persistentAreas.length ? groundRecoveryState() : null;
        const environmentState = player.alive ? environmentRecoveryState() : null;
        const encounterAuras = player.alive ? encounterAuraRecoveryState() : null;
        const casting = player.alive && (generic.active || pendingHits.length || context.remoteSpells.replicaImpactCount(player.guid)
            || activeRecoveryChannelAura() !is null || rituals.ritualChannelOwner || cameraChannel())
            ? castRecoveryState() : null;
        const active = summons.length || fishing.length || ground.length || casting.length || environmentState.length
            || encounterAuras.length;
        if (!active && !summonCheckpointExists)
            return true;
        ByteWriter checkpoint;
        if (active)
        {
            checkpoint.put(summonCheckpointVersion);
            checkpoint.put(home.node);
            checkpoint.put(home.incarnation);
            checkpoint.put(cast(uint) summons.length);
            checkpoint.putBytes(summons);
            checkpoint.put(cast(uint) fishing.length);
            checkpoint.putBytes(fishing);
            checkpoint.put(cast(uint) ground.length);
            checkpoint.putBytes(ground);
            checkpoint.put(cast(uint) environmentState.length);
            checkpoint.putBytes(environmentState);
            checkpoint.put(cast(uint) encounterAuras.length);
            checkpoint.putBytes(encounterAuras);
            checkpoint.putBytes(casting);
        }
        const state = active ? toHex(checkpoint.data) : null;
        if ((immediate || savePosition) && !removed)
        {
            const progress = player.progress(secondsInWorld());
            context.database.savePlayerRecovery(progress, state);
        }
        else
            context.database.savePlayerSummons(player.data.guid, state);
        if (immediate && !context.settleWrites())
        {
            summonCheckpointExists = true;
            return false;
        }
        summonCheckpointExists = active;
        return true;
    }

    private void openSummonCheckpoint(scope const(imported!"dmangos.world.session".GatewayRecoveryCheckpoints)* checkpoints)
    {
        import dmangos.log : warning;
        import dmangos.world.instancescripting : fromHex;

        if (!context.config.cluster.enabled)
            return;
        if (checkpoints is null)
        {
            context.database.savePlayerSummons(player.data.guid, null);
            if (connection.gatewayHome.node && player.alive && encounterAuraRecoveryState().length)
                checkpointSummons();
            context.settleWrites();
            return;
        }
        try
        {
            const saved = checkpoints.ongoingEffects;
            summonCheckpointExists = saved.length != 0;
            if (!summonCheckpointExists)
                return;
            auto state = ByteReader(fromHex(saved));
            const home = connection.gatewayHome;
            const version_ = state.read!ubyte;
            if (state.read!ushort == home.node && state.read!ulong == home.incarnation && player.alive && !taxi.flying)
            {
                if (version_ == 1)
                    restorePlayerSummons(state, true);
                else if (version_ >= 2 && version_ <= summonCheckpointVersion)
                {
                    auto summons = ByteReader(state.readBytes(state.read!uint));
                    restorePlayerSummons(summons, true);
                    if (version_ == 2)
                        restoreFishingRecovery(state);
                    else
                    {
                        auto fishing = ByteReader(state.readBytes(state.read!uint));
                        restoreFishingRecovery(fishing);
                        if (version_ == 3)
                            restoreGroundRecovery(state);
                        else
                        {
                            auto ground = ByteReader(state.readBytes(state.read!uint));
                            restoreGroundRecovery(ground);
                            if (version_ >= 5)
                            {
                                auto environmentState = ByteReader(state.readBytes(state.read!uint));
                                restoreEnvironmentRecovery(environmentState);
                            }
                            if (version_ >= 7)
                            {
                                auto encounterAuras = ByteReader(state.readBytes(state.read!uint));
                                restoreEncounterAuraRecovery(encounterAuras);
                            }
                            restoreCastRecovery(state, version_ >= 6);
                        }
                    }
                }
            }
            checkpointSummons();
        }
        catch (Exception error)
            warning!"could not restore temporary summons for player %s: %s"(player.data.guid, error.msg);
    }

    private void restoreSummonsOnHandoff(ref ByteReader reader)
    {
        auto state = ByteReader(reader.readBytes(reader.read!uint));
        summonCheckpointExists = !state.empty;
        restorePlayerSummons(state, false);
    }

    private void restorePlayerSummons(ref ByteReader state, bool recovered)
    {
        import core.time : msecs;
        import dmangos.world.auras : AuraType;
        import dmangos.world.creatureai : ReactState;
        import dmangos.world.migration : Migrant, MigrantKind;

        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = cast(int)(context.fleet.transportNow() - state.read!uint);
        const now = context.clock();
        const then = now - (elapsed > 0 ? elapsed : 0).msecs;
        foreach (_; 0 .. state.read!uint)
        {
            const slot = state.read!ubyte;
            const spawn = state.read!uint;
            const home = state.read!ulong;
            const spell = state.read!uint;
            const active = state.read!bool;
            const bytes = state.readBytes(state.read!uint);
            enum tickSize = uint.sizeof + int.sizeof;
            auto ticks = ByteReader(state.readBytes(cast(size_t) state.read!uint * tickSize));
            if (slot > guardianSlot || (slot == loneTotemSlot && loneTotem)
                || (slot < totems.length && totems[slot]))
                continue;
            const moved = Migrant(MigrantKind.summonedCreature, spawn, home, bytes);
            if (auto creature = context.migrants.restorePlayerSummon(map, moved, player.guid))
            {
                if (slot == guardianSlot)
                {
                    creature.guardianOwner = player.guid;
                    guardians.guardians_ ~= creature.guid;
                }
                else
                {
                    creature.totemOwner = player.guid;
                    creature.totemSpell = spell;
                    creature.totemActive = active;
                    creature.ai.react = ReactState.passive;
                    creature.ai.scriptMelee(false);
                    creature.ai.scriptCombatMovement(false);
                    if (slot == loneTotemSlot)
                        loneTotem = creature.guid;
                    else
                        totems[slot] = creature.guid;
                    while (!ticks.empty)
                    {
                        const aura = ticks.read!uint;
                        auto deadline = then + ticks.read!int.msecs;
                        // Pulses that fell during downtime are skipped. Keep the next original tick.
                        if (recovered && deadline <= now)
                            if (const activeAura = creature.auras.find(aura, creature.guid))
                                foreach (i, period; activeAura.period)
                                    if (period > 0 && activeAura.effects & (1 << i)
                                        && activeAura.type(i) == AuraType.periodicTriggerSpell)
                                    {
                                        const past = (now - deadline).total!"msecs";
                                        deadline = now + (period - past % period).msecs;
                                        break;
                                    }
                        totemTickAt[TotemTick(creature.guid, aura)] = deadline;
                    }
                }
                creature.controllerPlayerFlags = player.values.get!PLAYER_FLAGS;
                map.addObject(creature);
            }
        }
        restorePlayerTraps(state, elapsed > 0 ? elapsed : 0);
    }

    /// At login, after a teleport or move, and on coming back to life: the pet saved out with the player comes back (not to the dead).
    package void petsOnArrival(const PetPossessionHandoff handoff = PetPossessionHandoff.init)
    {
        import dmangos.world.player : DeathState;

        // Not in flight: it comes back at the landing (`Player::IsPetNeedBeTemporaryUnsummoned`).
        if (pet_ !is null || player is null || player.deathState != DeathState.alive || taxi.flying)
            return;
        foreach (r; savedPets())
            if (r.slot == PetSlot.current)
            {
                if (handoff.guid && matchesPetPossession(handoff, r) && resumePetPossession(handoff, r))
                    return;
                if (r.health || r.type == PetType.summon)
                    loadPet(r);
                break;
            }
        if (handoff.guid && channelSpell !is null && channelSpell.id == spellEyesOfTheBeast)
            endChannel(true);
    }

    // -----------------------------------------------------------------------
    // Handlers
    // -----------------------------------------------------------------------

    /// The pet `guid` if it is this player's (out and here); null if not.
    private Creature ownPetNamed(ulong guid)
    {
        if (pet_ is null || pet_.guid != guid || map.findObject(guid) !is pet_)
            return null;
        return pet_;
    }

    /// The client presses a button of the pet's bar.
    @Handles(Opcode.CMSG_PET_ACTION, WorldState.inWorld)
    void handlePetAction(ref ByteReader reader)
    {
        import dmangos.world.relations : canAttack;
        import dmangos.world.unit : combatRelations;

        const guid = reader.read!ulong;
        const data = reader.read!uint;
        const targetGuid = reader.read!ulong;
        auto pet = ownPetNamed(guid);
        if (pet is null)
            return;
        if (!pet.alive)
            return sendPetFeedback(PetFeedback.dead);
        auto state = petState();
        const action = buttonAction(data);
        switch (buttonType(data))
        {
        case ActiveState.command:
            switch (action)
            {
            case CommandState.stay:
                pet.ai.petStopAttack(map);
                state.command = CommandState.stay;
                state.hasStay = false;
                break;
            case CommandState.follow:
                pet.ai.petStopAttack(map);
                state.command = CommandState.follow;
                state.hasStay = false;
                break;
            case CommandState.attack:
            {
                auto target = pet.ai.combatTarget(map, targetGuid);
                if (!target)
                    return sendPetFeedback(PetFeedback.nothingToAttack);
                if (target.combatGuid == pet.guid || !target.alive
                    || !canAttack(pet.ai.relatingOf, target.combatRelations(context.client), context.client))
                    return sendPetFeedback(PetFeedback.cantAttackTarget);
                if (pet.ai.currentVictim != target.combatGuid)
                {
                    pet.ai.petStopAttack(map);
                    pet.ai.petAttack(target, map);
                    // The pet reacts with hostility.
                    ByteWriter w;
                    w.put(pet.guid);
                    w.put(2u); // AI_REACTION_HOSTILE
                    deliver(Opcode.SMSG_AI_REACTION, w.data);
                }
                break;
            }
            case CommandState.dismiss:
                // A demon goes back; a beast is dismissed by its spell only.
                if (state.type != PetType.hunter)
                    unsummonPet(PetSlot.notInSlot);
                break;
            default:
                break;
            }
            break;
        case ActiveState.reaction:
            if (action > ReactState.aggressive)
                return;
            if (action == ReactState.passive)
                pet.ai.petStopAttack(map);
            pet.ai.react = cast(ReactState) action;
            break;
        case ActiveState.disabled, ActiveState.passive, ActiveState.enabled:
            petCastOrdered(pet, action, targetGuid);
            break;
        default:
            break;
        }
    }

    /// A spell the owner has the pet cast at `target` (none: its victim, or itself).
    private void petCastOrdered(Creature pet, uint spell, ulong target)
    {
        auto state = petState();
        if (!state.knows(spell))
            return;
        const info = context.data.spells.spell(spell);
        if (info is null || info.isPassive)
            return;
        if (!pet.ai.petSpellReady(info))
            return; // not ready: nothing said (`HandlePetCastSpellOpcode`)
        if (pet.ai.petCastByCommand(info, target, map))
        {
            petCastSpell(spell);
            ByteWriter w;
            w.put(pet.guid);
            w.put(2u);
            deliver(Opcode.SMSG_AI_REACTION, w.data);
        }
        else // why not, to the owner (`Spell::SendCastResult` of a pet's cast)
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell, pet.ai.castRefusal, info));
    }

    /// The client casts a spell from the pet's spellbook.
    @Handles(Opcode.CMSG_PET_CAST_SPELL, WorldState.inWorld)
    void handlePetCastSpell(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        const spell = reader.read!uint;
        const targets = SpellTargets.read(reader);
        auto pet = ownPetNamed(guid);
        if (pet is null || !pet.alive)
            return;
        petCastOrdered(pet, spell, targets.unit);
    }

    /// The client moves a button, or a spell put on or taken off the bar.
    @Handles(Opcode.CMSG_PET_SET_ACTION, WorldState.inWorld)
    void handlePetSetAction(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        const count = reader.remaining >= 16 ? 2 : 1;
        uint[2] position, data;
        bool moveCommand;
        foreach (i; 0 .. count)
        {
            position[i] = reader.read!uint;
            data[i] = reader.read!uint;
            if (position[i] >= barSize)
                return;
            const type = buttonType(data[i]);
            if (type == ActiveState.command || type == ActiveState.reaction)
            {
                if (count == 1)
                    return; // a command or reaction can be moved, not taken off
                moveCommand = true;
            }
        }
        auto pet = ownPetNamed(guid);
        if (pet is null)
            return;
        auto state = petState();
        if (moveCommand)
            foreach (i; 0 .. 2)
            {
                const type = buttonType(data[i]);
                if ((type == ActiveState.command || type == ActiveState.reaction) && state.bar.buttons[position[1 - i]] != data[i])
                    return; // it must be the button that was in the other place
            }
        foreach (i; 0 .. count)
        {
            const spell = buttonAction(data[i]);
            const type = buttonType(data[i]);
            const forSpell = type == ActiveState.enabled || type == ActiveState.disabled || type == ActiveState.passive;
            if (forSpell && spell && !state.knows(spell))
                continue;
            if (spell && (type == ActiveState.enabled || type == ActiveState.disabled))
                setPetAutocast(state, spell, type == ActiveState.enabled);
            state.bar.buttons[position[i]] = data[i];
        }
    }

    /// Sets an autocastable spell of the pet to cast by itself, or not.
    private void setPetAutocast(PetState state, uint spell, bool on)
    {
        if (const info = context.data.spells.spell(spell))
            if (!isAutocastable(*info))
                return;
        foreach (ref s; state.spells)
            if (s.spell == spell)
                s.active = on ? ActiveState.enabled : ActiveState.disabled;
    }

    /// The client sets a pet spell to cast by itself, or not.
    @Handles(Opcode.CMSG_PET_SPELL_AUTOCAST, WorldState.inWorld)
    void handlePetSpellAutocast(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        const spell = reader.read!uint;
        const on = reader.read!ubyte != 0;
        auto pet = ownPetNamed(guid);
        if (pet is null)
            return;
        auto state = petState();
        if (!state.knows(spell))
            return;
        if (const info = context.data.spells.spell(spell))
            if (!isAutocastable(*info))
                return;
        setPetAutocast(state, spell, on);
        state.bar.setAutocast(spell, on);
    }

    /// The client asks for a pet's name.
    @Handles(Opcode.CMSG_PET_NAME_QUERY, WorldState.inWorld)
    void handlePetNameQuery(ref ByteReader reader)
    {
        const number = reader.read!uint;
        const guid = reader.read!ulong;
        auto creature = map.creatureAt(guid);
        auto state = creature is null ? null : creature.petData;
        if (state is null || state.number != number)
            return deliver(Opcode.SMSG_PET_NAME_QUERY_RESPONSE, petNameQueryResponse(number, null, 0));
        deliver(Opcode.SMSG_PET_NAME_QUERY_RESPONSE, petNameQueryResponse(number, state.name,
            creature.values.get!UNIT_FIELD_PET_NAME_TIMESTAMP));
    }

    /// The client renames the pet: a hunter pet never renamed takes a name of 2 to 12 letters, not reserved.
    @Handles(Opcode.CMSG_PET_RENAME, WorldState.inWorld)
    void handlePetRename(ref ByteReader reader)
    {
        import dmangos.world.worlddata : toLowerName;

        const guid = reader.read!ulong;
        const name = reader.readCString();
        auto pet = ownPetNamed(guid);
        if (pet is null || !(pet.values.get!UNIT_FIELD_FLAGS & unitFlagPetRename))
            return;
        auto state = petState();
        if (state.type != PetType.hunter)
            return;
        if (!validPetName(name) || (toLowerName(name) in context.data.reservedNames) !is null)
            return deliver(Opcode.SMSG_PET_NAME_INVALID, null);
        state.name = name;
        state.renamed = true;
        pet.values.set!UNIT_FIELD_FLAGS(pet.values.get!UNIT_FIELD_FLAGS & ~unitFlagPetRename);
        pet.values.set!UNIT_FIELD_PET_NAME_TIMESTAMP(cast(uint) context.unixTime);
        map.flushObjectChanges(pet);
        writePet(PetSlot.current);
    }

    /// `SPELL_EFFECT_SUMMON_TOTEM` by this player (`dmangos.world.spellsummons.summonTotem`): the one in its slot goes,
    /// the new one is kept in it.
    package void summonTotem(const(SpellInfo)* spell, size_t i, int value)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spellsummons;

        enum uint slotFirst = 87;
        const effect = spell.effect[i];
        const slot = effect >= slotFirst && effect < slotFirst + 4 ? effect - slotFirst : uint.max;
        if (slot != uint.max)
            unsummonTotem(slot);
        auto me = Caster.of(this);
        auto totem = dmangos.world.spellsummons.summonTotem(me, spell, i, value, slot);
        if (totem is null)
            return;
        if (slot != uint.max)
            totems[slot] = totem.guid;
        else
            loneTotem = totem.guid;
        checkpointSummons(true);
    }

    /// The totem in `slot` goes.
    package void unsummonTotem(uint slot)
    {
        if (slot >= totems.length || !totems[slot])
            return;
        forgetTotem(totems[slot]);
        totems[slot] = 0;
    }

    /// Every totem goes (the owner dies, leaves the map, logs out).
    package void unsummonTotems()
    {
        foreach (slot; 0 .. totems.length)
            unsummonTotem(cast(uint) slot);
        if (loneTotem)
            forgetTotem(loneTotem);
        loneTotem = 0;
    }

    private void forgetTotem(ulong guid)
    {
        map.removeObject(guid);
        foreach (key; totemTickAt.keys)
            if (key.totem == guid)
                totemTickAt.remove(key);
    }

    private ulong loneTotem; /// a totem of no slot

    /// Each tick: its active totems cast at its enemies (`dmangos.world.spellsummons.totemsAct`).
    package void updateTotems()
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellsummons : totemsAct;

        auto mine = ownTotems();
        if (!mine.length)
            return;
        auto me = Caster.of(this);
        totemsAct(me, mine);
    }

    /**
     * Each tick: a totem's aura that casts a spell now and then (`SPELL_AURA_PERIODIC_TRIGGER_SPELL`), whose ticks the
     * totem itself has no caster to do: at each of its periods the totem casts it (Fire Nova Totem's nova, Magma
     * Totem's fire, Earthbind Totem's slow, the cleansing totems'). One that enchants a held item (Flametongue Totem,
     * Windfury Totem: `SPELL_EFFECT_ENCHANT_HELD_ITEM`) gives it to the main hand weapon of each party member within
     * the spell's radius, for two periods: it lasts while they stay near (the tooltips: "enchants all party members'
     * main-hand weapons ... if they are within 20 yards").
     */
    package void updateTotemEnchants()
    {
        import core.time : msecs;
        import dmangos.world.auras : AuraType;
        import dmangos.world.spells : SpellEffect;

        const now = context.clock();
        bool initializedPulse;
        foreach (totem; ownTotems())
            foreach (aura; totem.auras.list)
                foreach (k; 0 .. 3)
                {
                    if (!(aura.effects & (1 << k)) || aura.type(k) != AuraType.periodicTriggerSpell)
                        continue;
                    const trigger = context.data.spells.spell(aura.spell.triggerSpell[k]);
                    const period = aura.period[k];
                    if (trigger is null || period <= 0)
                        continue;
                    const key = TotemTick(totem.guid, aura.spell.id);
                    if (const at = key in totemTickAt)
                    {
                        if (*at > now)
                            continue;
                    }
                    else if (!trigger.hasEffect(SpellEffect.enchantHeldItem))
                    {
                        totemTickAt[key] = now + period.msecs; // its first tick a period after it stands
                        initializedPulse = true;
                        continue;
                    }
                    totemTickAt[key] = now + period.msecs;
                    if (!trigger.hasEffect(SpellEffect.enchantHeldItem))
                    {
                        import dmangos.world.eventai : castTriggered;

                        totem.ai.castSpell(trigger, totem.guid, castTriggered);
                        continue;
                    }
                    foreach (i; 0 .. 3)
                        if (trigger.effect[i] == SpellEffect.enchantHeldItem)
                            applyTotemWeaponPulse(totem, aura.spell.id, k, trigger, i, period * 2);
                }
        if (initializedPulse)
            checkpointSummons();
    }

    private MonoTime[TotemTick] totemTickAt; // a totem's aura -> when it ticks again

    private static struct TotemTick
    {
        ulong totem;
        uint spell;
    }

    private void applyTotemWeaponPulse(Creature totem, uint aura, size_t auraEffect,
        const(SpellInfo)* spell, size_t effect, uint ms)
    {
        import dmangos.cluster.protocol : TotemWeaponEnchant;
        import dmangos.world.player : DeathState;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : radius;

        const reach = radius(*spell, effect, context.client);
        const at = totem.position;
        bool near(Position where)
        {
            return (at.x - where.x) ^^ 2 + (at.y - where.y) ^^ 2 + (at.z - where.z) ^^ 2 <= reach * reach;
        }
        const enchantment = cast(uint) spell.miscValue[effect];
        if (near(player.position))
            enchanting.enchantWeaponFromTotem(enchantment, ms);
        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        foreach (ref member; group.members)
        {
            if (member.guid == player.guid || group.subGroupOf(member.guid) != group.subGroupOf(player.guid))
                continue;
            if (auto local = context.onlinePlayer(member.guid))
            {
                if (local.player !is null && local.map is map && local.player.deathState == DeathState.alive
                    && !local.dueling.duelingWith(player.guid) && near(local.player.position))
                    local.enchanting.enchantWeaponFromTotem(enchantment, ms);
            }
            else if (context.sendTotemWeaponEnchant !is null)
                if (auto mirror = cast(Replica) map.findObject(member.guid))
                    if (near(mirror.position))
                    {
                        const pulse = TotemWeaponEnchant(totem.guid, player.guid, member.guid,
                            group.id, aura, map.id, map.instanceId, context.fleet.transportNow() + ms,
                            cast(ubyte) auraEffect, cast(ubyte) effect);
                        context.sendTotemWeaponEnchant(mirror.owner, pulse);
                    }
        }
    }

    /// The player's totems out.
    package Creature[] ownTotems()
    {
        Creature[] found;
        foreach (guid; totems[] ~ loneTotem)
            if (guid)
                if (auto c = cast(Creature) map.findObject(guid))
                    if (c.alive)
                        found ~= c;
        return found;
    }

    package ulong[4] totems; /// the totem in each slot (fire, earth, water, air); 0 if none

    /**
     * What untraining the pet costs: 10 silver the first time (or a day after the last), then 50 silver, then
     * a gold, then a gold more each time, at most 10 gold.
     */
    package uint petUntrainCost()
    {
        auto state = petState();
        if (state is null)
            return 0;
        enum uint silver = 100, gold = 10_000;
        const days = (context.unixTime - state.resetTime) / 86_400;
        if (state.resetCost < 10 * silver || days > 0)
            return 10 * silver;
        if (state.resetCost < 50 * silver)
            return 50 * silver;
        if (state.resetCost < gold)
            return gold;
        return state.resetCost + gold > 10 * gold ? 10 * gold : state.resetCost + gold;
    }

    /// Whether a pet trainer would untrain the pet: a hunter's, knowing more than one spell.
    package bool petMayUntrain()
    {
        auto state = petState();
        return state !is null && state.type == PetType.hunter && state.spells.length > 1;
    }

    /// The pet trainer offers to untrain the pet: `SMSG_PET_UNLEARN_CONFIRM` with its cost.
    package void offerPetUntrain()
    {
        if (!petMayUntrain())
            return;
        ByteWriter w;
        w.put(pet_.guid);
        w.put(petUntrainCost());
        deliver(Opcode.SMSG_PET_UNLEARN_CONFIRM, w.data);
    }

    /**
     * The player has the pet untrained: for its cost, the pet forgets the spells it was taught (its passive
     * ones stay), and its training points are its level times its loyalty level less one.
     */
    @Handles(Opcode.CMSG_PET_UNLEARN, WorldState.inWorld)
    void handlePetUnlearn(ref ByteReader reader)
    {
        import dmangos.world.inventory : BuyResult;

        auto pet = ownPetNamed(reader.read!ulong);
        if (pet is null || !petMayUntrain())
            return;
        const cost = Copper(petUntrainCost());
        if (!player.canAfford(cost))
            return sendBuyError(BuyResult.notEnoughMoney, null, 0);
        auto state = petState();
        foreach (s; state.spells.dup)
            if (const info = context.data.spells.spell(s.spell))
                if (!info.isPassive)
                    state.unlearn(s.spell);
        state.trainingPoints = cast(int)(pet.values.get!UNIT_FIELD_LEVEL * (state.loyalty > 0 ? state.loyalty - 1 : 0));
        pet.values.set!UNIT_TRAINING_POINTS(shownTrainingPoints(state));
        map.flushObjectChanges(pet);
        state.resetCost = cost.amount;
        state.resetTime = context.unixTime;
        player.pay(cost);
        flushPlayerChanges();
        sendPetSpells();
        writePet(PetSlot.current);
    }

    /// The client tells the pet to stop attacking.
    @Handles(Opcode.CMSG_PET_STOP_ATTACK, WorldState.inWorld)
    void handlePetStopAttack(ref ByteReader reader)
    {
        auto pet = ownPetNamed(reader.read!ulong);
        if (pet is null || !pet.alive || pet.ai is null)
            return;
        pet.ai.petStopAttack(map);
    }

    /// The client abandons the pet: a beast is let go for good; a demon goes back.
    @Handles(Opcode.CMSG_PET_ABANDON, WorldState.inWorld)
    void handlePetAbandon(ref ByteReader reader)
    {
        auto pet = ownPetNamed(reader.read!ulong);
        if (pet is null)
            return;
        if (petState().type == PetType.hunter)
            unsummonPet(0, true);
        else
            unsummonPet(PetSlot.notInSlot);
    }

    /// `CMSG_REQUEST_PET_INFO`: the bar again.
    @Handles(Opcode.CMSG_REQUEST_PET_INFO, WorldState.inWorld)
    void handleRequestPetInfo()
    {
        sendPetSpells();
    }

    /// `CMSG_PET_CANCEL_AURA`: one of the pet's auras taken off.
    @Handles(Opcode.CMSG_PET_CANCEL_AURA, WorldState.inWorld)
    void handlePetCancelAura(ref ByteReader reader)
    {
        auto pet = ownPetNamed(reader.read!ulong);
        const spell = reader.read!uint;
        if (pet is null)
            return;
        if (auto aura = pet.auras.find(spell))
        {
            pet.auras.remove(aura, pet.values);
            map.flushObjectChanges(pet);
        }
    }

    // -----------------------------------------------------------------------
    // Stables
    // -----------------------------------------------------------------------

    /// Whether `npc` is a stable master the player can talk to.
    private bool atStableMaster(ulong npc)
    {
        return interactableNpc(npc, NpcFlag.stableMaster) !is null;
    }

    /// `SMSG_STABLE_RESULT`
    private void sendStableResult(StableResult result)
    {
        deliver(Opcode.SMSG_STABLE_RESULT, [cast(ubyte) result]);
    }

    /// The stable list: the pet out (or those set aside), then the stabled ones.
    package void sendStableList(ulong npc)
    {
        StableEntry[] list;
        auto state = petState();
        auto rows = savedPets();
        if (pet_ !is null && pet_.alive && state.type == PetType.hunter)
            list ~= StableEntry(state.number, pet_.template_.entry, pet_.values.get!UNIT_FIELD_LEVEL, state.name,
                state.loyalty, 1);
        else
            foreach (ref r; rows)
                if (r.slot == PetSlot.notInSlot)
                    list ~= StableEntry(r.id, r.entry, r.level, r.name, r.loyalty, 3);
        rows.sort!((a, b) => a.slot < b.slot);
        foreach (ref r; rows)
            if (r.slot >= PetSlot.firstStable && r.slot <= PetSlot.lastStable)
                list ~= StableEntry(r.id, r.entry, r.level, r.name, r.loyalty, cast(ubyte)(r.slot + 1));
        deliver(Opcode.MSG_LIST_STABLED_PETS, stableListPacket(npc, stableSlots, list));
    }

    /// The client asks for the stable list.
    @Handles(Opcode.MSG_LIST_STABLED_PETS, WorldState.inWorld)
    void handleListStabledPets(ref ByteReader reader)
    {
        const npc = reader.read!ulong;
        if (!atStableMaster(npc))
            return;
        sendStableList(npc);
    }

    /**
     * Whether the pet out (or set aside) is a living beast that can go into the stable or out of it;
     * the reasons it cannot are told (`PetTameFailure.dead`, `notOk`).
     */
    private bool stablePetUsable(PetTameFailure notOk, out PetRecord* setAside)
    {
        if (pet_ !is null)
        {
            if (!pet_.alive)
            {
                sendTameFailure(PetTameFailure.dead);
                return false;
            }
            if (petState().type != PetType.hunter)
            {
                sendTameFailure(notOk);
                return false;
            }
            return true;
        }
        setAside = unstabledPet();
        if (setAside is null)
            return true; // nothing out: nothing to put away
        if (setAside.health == 0)
        {
            sendTameFailure(PetTameFailure.dead);
            return false;
        }
        if (setAside.type != PetType.hunter)
        {
            sendTameFailure(notOk);
            return false;
        }
        return true;
    }

    /// The client stables the pet: the pet out (or set aside) into the first free stable slot bought.
    @Handles(Opcode.CMSG_STABLE_PET, WorldState.inWorld)
    void handleStablePet(ref ByteReader reader)
    {
        const npc = reader.read!ulong;
        if (player.deathState != DeathState.alive || !atStableMaster(npc))
            return sendStableResult(StableResult.failed);
        PetRecord* setAside;
        if (!stablePetUsable(PetTameFailure.invalidCreature, setAside))
            return sendStableResult(StableResult.failed);
        if (pet_ is null && setAside is null)
            return sendStableResult(StableResult.failed);
        bool[uint] taken;
        foreach (r; savedPets())
            taken[r.slot] = true;
        uint free = PetSlot.firstStable;
        while (free in taken)
            ++free;
        if (free > stableSlots)
            return sendStableResult(StableResult.failed);
        if (pet_ !is null)
            unsummonPet(free);
        else
            context.database.setPetSlot(player.data.guid, setAside.id, free);
        sendStableResult(StableResult.stabled);
    }

    /// Unstabling or swapping: a stabled pet comes out; the one out takes its slot.
    private void takeOutOfStable(ulong npc, uint number)
    {
        if (!atStableMaster(npc))
            return sendStableResult(StableResult.failed);
        PetRecord wanted;
        bool found;
        foreach (r; savedPets())
            if (r.id == number && r.slot >= PetSlot.firstStable && r.slot <= PetSlot.lastStable)
            {
                wanted = r;
                found = true;
            }
        if (!found)
            return sendStableResult(StableResult.failed);
        const t = wanted.entry in context.data.creatureTemplates;
        if (t is null || !isTameable(*t))
            return sendStableResult(StableResult.failed);
        PetRecord* setAside;
        if (!stablePetUsable(PetTameFailure.anotherSummonActive, setAside))
            return sendStableResult(StableResult.failed);
        // The one out (or set aside) into the slot; the one wanted out of it.
        context.database.setPetSlot(player.data.guid, wanted.id, PetSlot.notInSlot);
        if (pet_ !is null)
            unsummonPet(wanted.slot);
        else if (setAside !is null)
            context.database.setPetSlot(player.data.guid, setAside.id, wanted.slot);
        wanted.slot = PetSlot.notInSlot;
        if (!loadPet(wanted))
            return sendStableResult(StableResult.failed);
        sendStableResult(StableResult.unstabled);
    }

    /// ditto
    @Handles(Opcode.CMSG_UNSTABLE_PET, WorldState.inWorld)
    void handleUnstablePet(ref ByteReader reader)
    {
        const npc = reader.read!ulong;
        takeOutOfStable(npc, reader.read!uint);
    }

    /// ditto
    @Handles(Opcode.CMSG_STABLE_SWAP_PET, WorldState.inWorld)
    void handleStableSwapPet(ref ByteReader reader)
    {
        const npc = reader.read!ulong;
        takeOutOfStable(npc, reader.read!uint);
    }

    /// The client buys another stable slot, at `StableSlotPrices.dbc`'s price.
    @Handles(Opcode.CMSG_BUY_STABLE_SLOT, WorldState.inWorld)
    void handleBuyStableSlot(ref ByteReader reader)
    {
        if (!atStableMaster(reader.read!ulong))
            return sendStableResult(StableResult.failed);
        if (stableSlots >= maxStableSlots)
            return sendStableResult(StableResult.failed);
        const price = context.client.stableSlotPrices.lookup(stableSlots + 1);
        const cost = Copper(price is null ? 0 : price.price);
        if (!player.canAfford(cost))
            return sendStableResult(StableResult.notEnoughMoney);
        stableSlots_ = stableSlots + 1;
        context.database.saveStableSlots(player.data.guid, stableSlots_);
        player.pay(cost);
        flushPlayerChanges();
        sendStableResult(StableResult.slotBought);
    }

    /// The client asks to revive a stabled pet: nothing happens.
    @Handles(Opcode.CMSG_STABLE_REVIVE_PET, WorldState.inWorld)
    void handleStableRevivePet()
    {
    }
}
