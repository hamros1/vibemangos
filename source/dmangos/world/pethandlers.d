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

/// The imp's casting distance.
enum float impAttackDistance = 25;

/// `UNIT_FLAG_PET_RENAME`, `UNIT_FLAG_PET_ABANDON`
enum uint unitFlagPetRename = 0x10, unitFlagPetAbandon = 0x20;

/// `UNIT_BYTE2_FLAG_SUPPORTABLE | UNIT_BYTE2_FLAG_AURAS`
enum ubyte petByte2Flags = 0x08 | 0x10;

/// A hunter pet's happiness: its most, and a tamed beast's.
enum uint maxHappiness = 1_050_000, tamedHappiness = 166_500;

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
    import dmangos.world.database : AuraRecord, PetRecord, PetSpellRecord;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : baseMoveSpeed, MoveType, Position;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.opcodes;
    import dmangos.world.player : PlayerFlags;
    import dmangos.world.pet;
    import dmangos.world.petai : isAutocastable;
    import dmangos.world.pethandlers;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.updatefields;

    private Creature pet_;          // the pet out, alive or dead; null if none
    private uint stableSlots_;      // the stable slots bought
    private bool stableSlotsRead;

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
        return pet_ is null ? null : cast(PetState) pet_.petData;
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
        auto state = cast(PetState) creature.petData;
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
        auto v = &creature.values;
        v.set!UNIT_FIELD_LEVEL(level);
        const health = v.get!UNIT_FIELD_HEALTH;
        v.set!UNIT_FIELD_MAXHEALTH(s.health);
        v.set!UNIT_FIELD_HEALTH(full || health > s.health ? s.health : health);
        if (state.type == PetType.hunter)
        {
            v.set!UNIT_FIELD_MAXPOWER1(0, 0u);
            v.set!UNIT_FIELD_POWER1(0, 0u);
        }
        else
        {
            const mana = v.get!UNIT_FIELD_POWER1(0);
            v.set!UNIT_FIELD_MAXPOWER1(0, s.mana);
            v.set!UNIT_FIELD_POWER1(0, full || mana > s.mana ? s.mana : mana);
        }
        v.set!UNIT_FIELD_MAXPOWER1(1, 0u); // no rage
        v.set!UNIT_FIELD_POWER1(1, 0u);
        v.set!UNIT_FIELD_RESISTANCES(0, s.armor);
        v.set!UNIT_FIELD_STAT0(s.stats[0]);
        v.set!UNIT_FIELD_STAT1(s.stats[1]);
        v.set!UNIT_FIELD_STAT2(s.stats[2]);
        v.set!UNIT_FIELD_STAT3(s.stats[3]);
        v.set!UNIT_FIELD_STAT4(s.stats[4]);
        v.set!UNIT_FIELD_ATTACK_POWER(s.attackPower);
        v.set!UNIT_FIELD_MINDAMAGE(s.minDamage);
        v.set!UNIT_FIELD_MAXDAMAGE(s.maxDamage);
        if (s.scale > 0)
            v.set!OBJECT_FIELD_SCALE_X(s.scale);
    }

    /// The experience a pet needs for its next level: a quarter of what a player needs.
    private uint petXpForLevel(uint level)
    {
        return level < context.data.xpForNextLevel.length ? context.data.xpForNextLevel[level] / 4 : 0;
    }

    /**
     * Loading a saved pet or making a new one: a creature of `entry` beside the player, made
     * its pet with `state`, at `level`, with `health` and `mana` (0: as the stats for the level
     * leave it, full). It is saved as the player's current pet, and its bar is sent.
     */
    private Creature bringPet(PetState state, uint entry, uint modelId, uint level, uint exp, ReactState react,
        uint health, uint mana, uint focus = maxFocus)
    {
        auto creature = context.makePetCreature(map, entry, state.number, petSpawnPosition());
        if (creature is null)
            return null;
        state.owner = player.guid;
        creature.becomePet(player.guid, state);
        auto v = &creature.values;
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
        if (state.type != PetType.hunter && mana)
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
        writePet(PetSlot.current);
        sendPetSpells();
        return creature;
    }

    /// The saved pet `r` comes out. `fullHealth`: at full health and mana (a
    /// demon summoned again); `healthPercent`: a dead hunter pet revived with so much.
    private bool loadPet(PetRecord r, bool fullHealth = false, uint healthPercent = 0)
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
            r.health == 0 && healthPercent ? 1 : health, mana, focus);
        if (creature is null)
            return false;
        if (r.health != 0 || fullHealth)
        {
            restorePetAurasAndCooldowns(savedAuras, savedCooldowns);
            if (savedAuras.length || savedCooldowns.length)
                writePet(PetSlot.current); // as it is now
        }
        if (r.health == 0 && healthPercent)
        {
            const most = creature.values.get!UNIT_FIELD_MAXHEALTH;
            creature.values.set!UNIT_FIELD_HEALTH(cast(uint)(ulong(most) * healthPercent / 100 > 0
                ? ulong(most) * healthPercent / 100 : 1));
            map.flushObjectChanges(creature);
            writePet(PetSlot.current);
        }
        return true;
    }

    /**
     * The pet out, saved in `slot`. A dead one is not saved as current; a
     * stable slot taken by another pet has that one set aside; a hunter has only one pet out or set
     * aside, so any other there goes.
     */
    private void writePet(uint slot)
    {
        auto state = petState();
        if (state is null)
            return;
        if (slot == PetSlot.current && !pet_.alive)
            slot = PetSlot.notInSlot;
        auto v = &pet_.values;
        const power = state.type == PetType.hunter ? v.get!UNIT_FIELD_POWER1(2) : v.get!UNIT_FIELD_POWER1(0);
        if (state.type == PetType.hunter)
            state.happiness = v.get!UNIT_FIELD_POWER1(4);
        auto r = state.record(pet_.template_.entry, v.get!UNIT_FIELD_NATIVEDISPLAYID, v.get!UNIT_FIELD_LEVEL,
            v.get!UNIT_FIELD_PETEXPERIENCE, pet_.ai.react, pet_.alive ? v.get!UNIT_FIELD_HEALTH : 0, power, slot,
            context.unixTime);
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

    /// The pet's auras that last and its cooldowns still running, saved with it (`pet_aura`, `pet_spell_cooldown`).
    private void savePetAurasAndCooldowns(uint id)
    {
        AuraRecord[] rows;
        if (pet_.alive)
            foreach (aura; pet_.auras.list)
                if (!aura.passive && aura.duration != 0)
                    rows ~= AuraRecord(aura.caster, aura.spell.id, aura.stacks, aura.amount, aura.periodTimer,
                        aura.maxDuration, aura.duration, aura.effects);
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
        import dmangos.world.auras : makeAura;

        foreach (ref row; auras)
        {
            const spell = context.data.spells.spell(row.spell);
            if (spell is null || row.remaining == 0)
                continue;
            auto aura = makeAura(spell, row.caster, pet_.values.get!UNIT_FIELD_LEVEL, row.maxDuration, true, row.amount);
            aura.duration = row.remaining;
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
                pet_.ai.petCooldowns[cast(uint) c[0]] = cast(int)((c[1] - now) * 1000);
        map.flushObjectChanges(pet_);
    }

    /**
     * The pet goes, saved in `slot` (`deleted`: forgotten), and its bar with it.
     */
    package void unsummonPet(uint slot, bool deleted = false)
    {
        if (pet_ is null)
            return;
        auto state = petState();
        if (deleted)
            context.database.deletePet(player.data.guid, state.number);
        else
            writePet(slot);
        if (pet_.ai !is null && pet_.alive)
            pet_.ai.petStopAttack(map);
        if (map.findObject(pet_.guid) is pet_)
            map.removeObject(pet_.guid);
        pet_ = null;
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
    package void petUsedSpell(uint spell)
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
        if (state is null || info is null || pet_ is null || !pet_.alive || state.knows(spell))
            return;
        state.trainingPoints -= trainingCost(state, spell);
        state.learn(spell, info.isPassive, isAutocastable(*info));
        pet_.values.set!UNIT_TRAINING_POINTS(shownTrainingPoints(state));
        map.flushObjectChanges(pet_);
        sendPetSpells();
        writePet(PetSlot.current);
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
        learnCreateSpells(state, beast.template_.entry);
        const level = beast.values.get!UNIT_FIELD_LEVEL;
        const health = beast.values.get!UNIT_FIELD_HEALTH, maxHealth = beast.values.get!UNIT_FIELD_MAXHEALTH;
        const percent = maxHealth ? (ulong(health) * 100 + maxHealth - 1) / maxHealth : 100;
        const entry = beast.template_.entry, model = beast.values.get!UNIT_FIELD_DISPLAYID;
        // The beast goes, to come back after its respawn time.
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

    /// The pet died: a demon goes back at once; a beast lies dead a while, a third of its happiness lost (not in a battleground).
    package void petDiedHere()
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
    package void petCorpseGoneHere(Creature creature)
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
        auto v = &pet_.values;
        uint level = v.get!UNIT_FIELD_LEVEL;
        const most = player.data.level < context.config.maxPlayerLevel ? player.data.level : context.config.maxPlayerLevel;
        if (level >= most)
            return;
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
        // Its loyalty: experience counts towards the next level; a kill earns a little (more at low levels).
        auto state = petState();
        state.xpForNextLoyalty = xp >= state.xpForNextLoyalty ? 0 : state.xpForNextLoyalty - xp;
        if (level <= 100)
            modifyLoyalty(cast(int)((100 - level) / 10 + (6 - state.loyalty)));
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
                // Rebellious and unhappy: it leaves its master.
                info!"%s: '%s''s pet ran away"(remoteAddress, player.data.name);
                deliver(Opcode.SMSG_PET_BROKEN, null);
                state.loyaltyPoints = 0;
                return unsummonPet(0, true);
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
    package void petsOnLeave()
    {
        unsummonTotems(); // totems do not follow their owner
        if (pet_ !is null)
            unsummonPet(PetSlot.current);
    }

    /// At login, after a teleport or move, and on coming back to life: the pet saved out with the player comes back (not to the dead).
    package void petsOnArrival()
    {
        import dmangos.world.player : DeathState;

        if (pet_ !is null || player is null || player.deathState != DeathState.alive)
            return;
        foreach (r; savedPets())
            if (r.slot == PetSlot.current)
            {
                if (r.health || r.type == PetType.summon)
                    loadPet(r);
                return;
            }
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
                UnitRef target;
                if (targetGuid)
                {
                    target = map.unit(targetGuid);
                    if (!target)
                        if (auto creature = map.creatureAt(targetGuid))
                            target = map.unitOf(creature);
                }
                if (!target)
                    return sendPetFeedback(PetFeedback.nothingToAttack);
                if (target.combatGuid == pet.guid || !target.fighter.alive
                    || !canAttack(pet.ai.relatingOf, target.relating, context.client))
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
        if (pet.ai.petCastByCommand(info, target, map))
        {
            petUsedSpell(spell);
            ByteWriter w;
            w.put(pet.guid);
            w.put(2u);
            deliver(Opcode.SMSG_AI_REACTION, w.data);
        }
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
        auto state = creature is null ? null : cast(PetState) creature.petData;
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

    /**
     * A totem summoned (spell effect 74, or 87 to 90 for the fire, earth, water and air slots): the one in
     * its slot goes, and the totem stands beside the player (each slot its own side), the player's
     * faction and level, with the effect's value as health, for the spell's duration. A passive totem
     * holds its spell's aura (given to the party, `updateAreaAuras`); an active one casts its spell at the
     * nearest enemy in its range (`updateTotems`). Its kills are its owner's.
     */
    package void summonTotem(const(SpellInfo)* spell, size_t i, int value)
    {
        import std.math : cos, PI, sin;
        import dmangos.world.auras : makeAura;
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.creatureai : ReactState;
        import dmangos.world.spellcast : castTime, duration, effectValue;

        enum uint summonTotemAny = 74, slotFirst = 87;
        const effect = spell.effect[i];
        const slot = effect >= slotFirst && effect < slotFirst + 4 ? effect - slotFirst : uint.max;
        if (slot != uint.max)
            unsummonTotem(slot);
        const entry = cast(uint) spell.miscValue[i];
        if (entry !in context.data.creatureTemplates)
            return;
        const angle = slot != uint.max ? PI / 4 - slot * PI / 2 : 0;
        const o = player.position.orientation + angle;
        auto at = Position(player.position.x + 2 * cos(o), player.position.y + 2 * sin(o), player.position.z,
            player.position.orientation);
        const ground = map.groundHeight(at.x, at.y, at.z + 2, false);
        if (ground > -100_000 && (ground - at.z) ^^ 2 < 25)
            at.z = ground;
        const ms = duration(*spell, context.client, player.data.level);
        auto totem = context.summonCreature(map, entry, at, ms > 0 ? TempSpawnType.timedOrDead : TempSpawnType.dead,
            ms > 0 ? ms : 0, player.guid);
        if (totem is null)
            return;
        auto v = &totem.values;
        const faction = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        v.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
        totem.factionTemplate = context.client.factionTemplates.lookup(faction);
        v.set!UNIT_FIELD_LEVEL(player.data.level);
        if (value > 0)
        {
            v.set!UNIT_FIELD_MAXHEALTH(cast(uint) value);
            v.set!UNIT_FIELD_HEALTH(cast(uint) value);
        }
        v.set!UNIT_CREATED_BY_SPELL(spell.id);
        v.set!UNIT_FIELD_SUMMONEDBY(player.guid);
        v.set!UNIT_FIELD_CREATEDBY(player.guid);
        v.set!UNIT_FIELD_FLAGS(v.get!UNIT_FIELD_FLAGS | UnitFlags.playerControlled);
        totem.totemOwner = player.guid;
        totem.ai.react = ReactState.passive; // it stands and casts; it does not fight
        totem.ai.scriptMelee(false);
        totem.ai.scriptCombatMovement(false);
        if (const s = entry in context.data.creatureFirstSpell)
            if (const info = context.data.spells.spell(*s))
            {
                totem.totemSpell = *s;
                totem.totemActive = castTime(*info, context.client, player.data.level) > 0;
                if (!totem.totemActive)
                {
                    // Its aura on itself, whence it reaches the party.
                    int[3] amounts;
                    foreach (j; 0 .. 3)
                        amounts[j] = effectValue(*info, j, player.data.level, 0);
                    bool isNew;
                    totem.auras.apply(makeAura(info, totem.guid, player.data.level, -1, true, amounts), totem.values,
                        isNew);
                }
            }
        map.flushObjectChanges(totem);
        if (slot != uint.max)
            totems[slot] = totem.guid;
        else
            loneTotem = totem.guid;
    }

    /// The totem in `slot` goes.
    package void unsummonTotem(uint slot)
    {
        if (slot >= totems.length || !totems[slot])
            return;
        map.removeObject(totems[slot]);
        totems[slot] = 0;
    }

    /// Every totem goes (the owner dies, leaves the map, logs out).
    package void unsummonTotems()
    {
        foreach (slot; 0 .. totems.length)
            unsummonTotem(cast(uint) slot);
        if (loneTotem)
            map.removeObject(loneTotem);
        loneTotem = 0;
    }

    private ulong loneTotem; /// a totem of no slot

    /// Each tick: an active totem casts its spell at the nearest enemy of its owner within its range, when it can.
    package void updateTotems()
    {
        import dmangos.world.relations : canAttack;
        import dmangos.world.spellcast : range;

        foreach (totem; ownTotems())
        {
            if (!totem.totemActive || totem.ai is null || totem.ai.castingNow)
                continue;
            const info = context.data.spells.spell(totem.totemSpell);
            if (info is null)
                continue;
            const reach = range(*info, context.client)[1];
            Creature nearest;
            float best = reach * reach;
            foreach (c; map.creaturesNear(totem.position, reach))
            {
                if (!c.alive || c is totem || c.totemOwner || c.petOwner == player.guid || c.ai is null)
                    continue;
                if (!canAttack(relatingNow(), c.ai.relatingOf(), context.client))
                    continue;
                const d = (c.position.x - totem.position.x) ^^ 2 + (c.position.y - totem.position.y) ^^ 2;
                if (d <= best)
                {
                    best = d;
                    nearest = c;
                }
            }
            if (nearest !is null)
                totem.ai.castSpell(info, nearest.guid, 0);
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
