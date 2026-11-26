/**
 * Pets: a creature that belongs to a player, follows it, fights for
 * it, and is saved with it. A hunter tames a beast (Tame Beast) and calls it back later (Call Pet);
 * a warlock summons a demon (Summon Imp, ...). The pet's state lives in `PetState`, which the
 * creature carries (`Creature.petData`); `dmangos.world.petai` moves and fights with it, and
 * `dmangos.world.pethandlers` does what the owner asks.
 *
 * This module holds what is the same for every pet: the types, the action bar of ten buttons and
 * how it is saved, the stats of a level, the
 * world tables (`pet_levelstats`, `petcreateinfo_spell`, `pet_name_generation`), and the packets.
 */
module dmangos.world.pet;

import std.array : split;
import std.conv : to, ConvException;
import std.random : uniform;

import dmangos.bytes : ByteWriter;
import dmangos.world.creature : CreatureClassStats, CreatureTemplate;
import dmangos.world.creatureai : ReactState;
import dmangos.world.database : PetRecord, PetSpellRecord;
import dmangos.world.movement : Position;

/// What kind of pet a creature is.
enum PetType : ubyte
{
    summon = 0,   /// a warlock's demon
    hunter = 1,   /// a tamed beast
    guardian = 2, /// not controlled
}

/// Where a pet is saved (`character_pet.slot`).
enum PetSlot : uint
{
    current = 0,       /// with its owner
    firstStable = 1,
    lastStable = 2,    /// `maxStableSlots`
    notInSlot = 100,   /// dismissed (a warlock's other demons, a hunter's dead pet)
}

/// The stable slots a player can buy.
enum uint maxStableSlots = 2;

/// What an action bar button is: its type, in its top byte.
enum ActiveState : ubyte
{
    passive = 0x01,   /// a spell cast by hand (or a passive one)
    disabled = 0x81,  /// a spell that could autocast, but does not
    enabled = 0xC1,   /// a spell cast by itself
    command = 0x07,   /// attack, follow, stay, dismiss
    reaction = 0x06,  /// passive, defensive, aggressive
    decide = 0x00,    /// a spell: `disabled` if it can autocast, else `passive`
}

/// What the pet was last told to do.
enum CommandState : ubyte
{
    stay = 0,
    follow = 1,
    attack = 2,
    dismiss = 3,
}

/// Why a pet did not do what it was told (`SMSG_PET_ACTION_FEEDBACK`).
enum PetFeedback : ubyte
{
    none = 0,
    dead = 1,
    nothingToAttack = 2,
    cantAttackTarget = 3,
    noPath = 4,
}

/// Why a beast could not be tamed (`SMSG_PET_TAME_FAILURE`).
enum PetTameFailure : ubyte
{
    invalidCreature = 1,
    tooMany = 2,
    creatureAlreadyOwned = 3,
    notTameable = 4,
    anotherSummonActive = 5,
    unitsCantTame = 6,
    noPetAvailable = 7,
    internalError = 8,
    tooHighLevel = 9,
    dead = 10,
    notDead = 11,
    unknownError = 12,
}

/// The outcome of a stable master's service (`SMSG_STABLE_RESULT`).
enum StableResult : ubyte
{
    notEnoughMoney = 0x01,
    failed = 0x06,
    stabled = 0x08,
    unstabled = 0x09,
    slotBought = 0x0A,
}

/// The bar's spell buttons are `barSpellStart .. barSpellEnd` of `barSize`.
enum size_t barSpellStart = 3, barSpellEnd = 7, barSize = 10;

/// An action and its type in one word.
uint actionButton(uint action, ubyte type) pure nothrow @nogc @safe
{
    return (action & 0x00FF_FFFF) | uint(type) << 24;
}

/// A button's action (its low 24 bits) and type (its top byte).
uint buttonAction(uint button) pure nothrow @nogc @safe
{
    return button & 0x00FF_FFFF;
}

/// ditto
ubyte buttonType(uint button) pure nothrow @nogc @safe
{
    return cast(ubyte)(button >> 24);
}

/// Whether a button of `type` holds a spell.
bool isSpellType(ubyte type) pure nothrow @nogc @safe
{
    return type == ActiveState.passive || type == ActiveState.disabled || type == ActiveState.enabled
        || type == ActiveState.decide;
}

/// The ten buttons of a pet's bar.
struct ActionBar
{
    uint[barSize] buttons;

    /// A new bar: attack, follow, stay; four empty spell buttons; aggressive, defensive, passive.
    static ActionBar initial() pure nothrow @safe
    {
        ActionBar bar;
        foreach (i; 0 .. barSpellStart)
            bar.buttons[i] = actionButton(CommandState.attack - cast(uint) i, ActiveState.command);
        foreach (i; barSpellStart .. barSpellEnd)
            bar.buttons[i] = actionButton(0, ActiveState.disabled);
        foreach (i; barSpellEnd .. barSize)
            bar.buttons[i] = actionButton(ReactState.aggressive - cast(uint)(i - barSpellEnd), ActiveState.reaction);
        return bar;
    }

    /// Puts the spell on the first empty spell button (or where a lower rank is).
    bool addSpell(uint spell, ubyte state, uint firstRank = 0)
    {
        foreach (ref b; buttons[barSpellStart .. barSpellEnd])
            if (buttonAction(b) && (buttonAction(b) == spell || (firstRank && buttonAction(b) == firstRank))
                && isSpellType(buttonType(b)))
            {
                b = actionButton(spell, buttonType(b));
                return true;
            }
        foreach (ref b; buttons[barSpellStart .. barSpellEnd])
            if (!buttonAction(b) && isSpellType(buttonType(b)))
            {
                b = actionButton(spell, state);
                return true;
            }
        return false;
    }

    /// Empties every button that holds `spell`.
    void removeSpell(uint spell)
    {
        foreach (ref b; buttons)
            if (buttonAction(b) == spell && isSpellType(buttonType(b)))
                b = actionButton(0, ActiveState.disabled);
    }

    /// Turns autocasting of `spell` on or off on the first button that holds it.
    void setAutocast(uint spell, bool on)
    {
        foreach (ref b; buttons)
            if (buttonAction(b) == spell && isSpellType(buttonType(b)))
            {
                b = actionButton(spell, on ? ActiveState.enabled : ActiveState.disabled);
                break;
            }
    }

    /// `abdata`: each button's type and action, separated by spaces.
    string toString() const
    {
        string s;
        foreach (b; buttons)
            s ~= to!string(buttonType(b)) ~ " " ~ to!string(buttonAction(b)) ~ " ";
        return s;
    }

    /// The saved bar, or the initial one if it is not twenty numbers.
    static ActionBar parse(string saved)
    {
        auto bar = initial();
        const tokens = saved.split;
        if (tokens.length != barSize * 2)
            return bar;
        try
            foreach (i; 0 .. barSize)
                bar.buttons[i] = actionButton(tokens[2 * i + 1].to!uint, tokens[2 * i].to!ubyte);
        catch (ConvException)
            return initial();
        return bar;
    }
}

/// What a pet is beyond its creature: carried in `Creature.petData`.
final class PetState
{
    uint number;                /// `character_pet.id`; `UNIT_FIELD_PETNUMBER`
    PetType type;
    ulong owner;
    uint createdBySpell;
    CommandState command = CommandState.follow;
    bool hasStay;               /// told to stay: where
    Position stayAt;
    ActionBar bar;
    PetSpellRecord[] spells;    /// what it knows, with each spell's autocast state
    string name;
    bool renamed;
    int loyaltyPoints;
    uint loyalty = 1;
    uint xpForNextLoyalty;
    int trainingPoints;
    uint happiness;
    string teachSpells;
    uint resetCost;   /// what its last untraining cost, and when (Unix time)
    long resetTime;   /// ditto
    PetStats base;    /// its stats at its level, without auras (`showPetStats` adds theirs)
    uint statsShownAt = uint.max; /// its auras' `changes` when its stats were last shown
    uint[] passives;  /// the passive auras it was given (`dmangos.world.petauras`), to take back when they change

    /// Whether it knows `spell`.
    bool knows(uint spell) const
    {
        foreach (s; spells)
            if (s.spell == spell)
                return true;
        return false;
    }

    /// Forgets a spell, and takes it off the bar.
    void unlearn(uint spell)
    {
        import std.algorithm.mutation : remove;

        foreach (i, s; spells)
            if (s.spell == spell)
            {
                spells = spells.remove(i);
                break;
            }
        bar.removeSpell(spell);
    }

    /// Learns a spell, and puts it on the bar unless passive.
    void learn(uint spell, bool passive, bool autocastable, uint replaces = 0)
    {
        if (knows(spell))
            return;
        ubyte state = passive ? ActiveState.passive : autocastable ? ActiveState.enabled : ActiveState.passive;
        if (replaces)
        {
            foreach (known; spells)
                if (known.spell == replaces)
                    state = known.active;
            if (!passive)
                bar.addSpell(spell, state, replaces);
            unlearn(replaces);
        }
        spells ~= PetSpellRecord(spell, state);
        if (!passive)
            bar.addSpell(spell, state);
    }

    /// The saved record of it, with what the creature holds (`fill`'s level, health, ...).
    PetRecord record(uint entry, uint modelId, uint level, uint exp, ReactState react, uint health, uint mana,
        uint slot, long now) const
    {
        PetRecord r;
        r.id = number;
        r.entry = entry;
        r.owner = cast(uint) owner;
        r.modelId = modelId;
        r.createdBySpell = createdBySpell;
        r.type = type;
        r.level = level;
        r.exp = exp;
        r.reactState = react;
        r.loyaltyPoints = loyaltyPoints;
        r.loyalty = type == PetType.hunter ? loyalty : 1;
        r.xpForNextLoyalty = xpForNextLoyalty;
        r.trainingPoints = trainingPoints;
        r.name = name;
        r.renamed = renamed;
        r.slot = slot;
        r.health = health;
        r.mana = mana;
        r.happiness = happiness;
        r.saveTime = now;
        r.actionBar = bar.toString();
        r.teachSpells = teachSpells.length ? teachSpells : "0 0 0 0 0 0 0 0 ";
        r.resetCost = resetCost;
        r.resetTime = resetTime;
        r.spells = spells.dup;
        return r;
    }

    /// From its saved record.
    static PetState from(const ref PetRecord r, ulong owner)
    {
        auto p = new PetState;
        p.number = r.id;
        p.type = cast(PetType) r.type;
        p.owner = owner;
        p.createdBySpell = r.createdBySpell;
        p.bar = ActionBar.parse(r.actionBar);
        p.spells = r.spells.dup;
        p.name = r.name;
        p.renamed = r.renamed;
        p.loyaltyPoints = r.loyaltyPoints;
        p.loyalty = r.loyalty ? r.loyalty : 1;
        p.xpForNextLoyalty = r.xpForNextLoyalty;
        p.trainingPoints = r.trainingPoints;
        p.happiness = r.happiness;
        p.teachSpells = r.teachSpells;
        p.resetCost = r.resetCost;
        p.resetTime = r.resetTime;
        return p;
    }
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

/// A `pet_levelstats` row.
struct PetLevelStats
{
    uint health;
    uint mana;
    uint armor;
    uint[5] stats; /// strength, agility, stamina, intellect, spirit
}

/// The stats a pet has at a level, without auras (`petStats`), or with them (`withAuras`).
struct PetStats
{
    uint health;
    uint mana;
    uint armor;
    int[6] resistances; /// holy .. arcane
    uint[5] stats;
    int attackPower;
    float minDamage = 0;
    float maxDamage = 0;
    float scale = 0; /// a hunter pet's size by its family and level; 0: its model's own
    float weaponMin = 0, weaponMax = 0; /// its weapon, before its attack power's share
    float apPerStrength = 2, apOffset = -20; /// its attack power by its strength
}

/**
 * A pet's stats at `level`. A hunter pet's health, armor and stats are `pet_levelstats`' of entry 1,
 * its weapon `attack time * level / 2000` (less a quarter, up to half as much again), its size its
 * family's. A demon's come from its own entry's rows, its weapon from its class's level stats.
 * Without auras, maximum health and power add nothing to the base (their bonuses are
 * for stamina and intellect above it); attack power is `2 * strength - 20` (the imp's `strength - 10`),
 * and a fourteenth of it is added to each end of the weapon.
 */
PetStats petStats(PetType type, const ref CreatureTemplate t, uint level, const(PetLevelStats)* levelStats,
    const(CreatureClassStats)* classStats, float minScale = 0, uint minScaleLevel = 0, float maxScale = 0,
    uint maxScaleLevel = 0)
{
    enum uint imp = 416;
    PetStats s;
    if (levelStats is null)
    {
        // "levelstats missing in DB": weak, so it shows.
        s.health = 1;
        s.mana = type == PetType.summon ? 1 : 0;
        s.armor = type == PetType.summon ? 1 : 0;
        s.stats[] = 1;
        s.minDamage = s.maxDamage = 1;
        return s;
    }
    s.health = levelStats.health;
    s.armor = levelStats.armor;
    s.stats = levelStats.stats;
    float weaponMin = 0, weaponMax = 0;
    if (type == PetType.hunter)
    {
        s.mana = 0;
        const mDmg = (t.meleeBaseAttackTime * level) / 2000;
        weaponMin = mDmg - mDmg / 4.0f;
        weaponMax = (mDmg - mDmg / 4.0f) * 1.5f;
        if (minScale > 0)
        {
            if (level >= maxScaleLevel)
                s.scale = maxScale;
            else if (level <= minScaleLevel)
                s.scale = minScale;
            else
                s.scale = minScale + float(level - minScaleLevel) / maxScaleLevel * (maxScale - minScale);
        }
    }
    else
    {
        s.mana = levelStats.mana;
        if (classStats !is null)
        {
            const minDmg = (classStats.baseDamage * t.damageVariance
                + (classStats.baseMeleeAttackPower / 14) * (t.meleeBaseAttackTime / 1000.0f)) * t.damageMultiplier;
            weaponMin = minDmg;
            weaponMax = minDmg * 1.5f;
        }
        else if (t.minLevel && t.maxLevel)
        {
            const dMin = t.minMeleeDmg / t.minLevel, dMax = t.maxMeleeDmg / t.maxLevel;
            const mDmg = (dMax - (dMax - dMin) / 2) * level;
            weaponMin = mDmg - mDmg / 4;
            weaponMax = (mDmg - mDmg / 4) * 1.5f;
        }
    }
    if (t.entry == imp)
    {
        s.apPerStrength = 1;
        s.apOffset = -10;
    }
    s.weaponMin = weaponMin;
    s.weaponMax = weaponMax;
    setDamage(s, s.apPerStrength * s.stats[0] + s.apOffset);
    if (s.health < 1)
        s.health = 1;
    return s;
}

/// Its attack power `ap`, and a fourteenth of it added to each end of its weapon.
private void setDamage(ref PetStats s, float ap) pure nothrow @nogc @safe
{
    s.attackPower = cast(int) ap;
    s.minDamage = s.weaponMin + ap / 14;
    s.maxDamage = s.weaponMax + ap / 14;
    if (s.minDamage < 0)
        s.minDamage = 0;
    if (s.maxDamage < s.minDamage)
        s.maxDamage = s.minDamage;
}

/**
 * A pet's stats with its auras, as a player's are made of its own (`dmangos.world.stats.computeStats`): its stats
 * by `MOD_STAT` and the percentages of them; health by `MOD_INCREASE_HEALTH` and 10 for each point of stamina above
 * its level's, times `MOD_INCREASE_HEALTH_PERCENT` (Endurance Training's, Fel Stamina's); mana by 15 for each point
 * of intellect above and `MOD_INCREASE_ENERGY`, times `MOD_INCREASE_ENERGY_PERCENT` (Fel Intellect's); armor by 2 for
 * each point of agility above and `MOD_RESISTANCE`, times `MOD_BASE_RESISTANCE_PCT` and `MOD_RESISTANCE_PCT` (Thick
 * Hide's: a pet's armor is all base armor); resistances by `MOD_RESISTANCE` (and the strongest exclusive one) times
 * theirs; attack power by its strength and `MOD_ATTACK_POWER`, times `MOD_ATTACK_POWER_PCT`. The points above its
 * level's count as a player's points above 20 do (docs/FORMULAS.md).
 */
PetStats withAuras(A)(const PetStats base, const ref A auras)
{
    import std.math : round;
    import dmangos.world.spellids : AuraType;

    PetStats s = base;
    if (auras.list.length == 0)
        return s;
    float[5] stats;
    foreach (int i; 0 .. 5)
    {
        float v = base.stats[i] + auras.totalByMisc(AuraType.modStat, i) + auras.totalByMisc(AuraType.modStat, -1);
        v *= 1 + (auras.totalByMisc(AuraType.modPercentStat, i) + auras.totalByMisc(AuraType.modPercentStat, -1)) / 100.0f;
        v *= auras.multiplier(AuraType.modTotalStatPercentage, (int m) => m == i || m == -1);
        stats[i] = v > 0 ? v : 0;
        s.stats[i] = cast(uint) stats[i];
    }
    const health = (base.health + (stats[2] - base.stats[2]) * 10 + auras.total(AuraType.modIncreaseHealth))
        * auras.multiplier(AuraType.modIncreaseHealthPercent);
    s.health = health >= 1 ? cast(uint) round(health) : 1;
    if (base.mana)
    {
        const mana = (base.mana + (stats[3] - base.stats[3]) * 15 + auras.totalByMisc(AuraType.modIncreaseEnergy, 0))
            * auras.multiplier(AuraType.modIncreaseEnergyPercent, (int m) => m == 0);
        s.mana = mana > 0 ? cast(uint) round(mana) : 0;
    }
    float resistance(int school, float baseValue)
    {
        const flat = baseValue + auras.totalByMiscMask(AuraType.modResistance, 1 << school)
            + auras.greatestByMiscMask(AuraType.modResistanceExclusive, 1 << school);
        return flat * auras.multiplier(AuraType.modBaseResistancePct, (int m) => (m & (1 << school)) != 0)
            * auras.multiplier(AuraType.modResistancePct, (int m) => (m & (1 << school)) != 0);
    }
    const armor = resistance(0, base.armor + (stats[1] - base.stats[1]) * 2);
    s.armor = armor > 0 ? cast(uint) round(armor) : 0;
    foreach (int school; 1 .. 7)
        s.resistances[school - 1] = cast(int) round(resistance(school, base.resistances[school - 1]));
    setDamage(s, (s.apPerStrength * stats[0] + s.apOffset + auras.total(AuraType.modAttackPower))
        * auras.multiplier(AuraType.modAttackPowerPct));
    return s;
}

/**
 * The pet's stats with its auras (`withAuras`) on its fields: health, mana, armor and resistances, stats, attack
 * power and damage. A pet at full health (or mana) stays full as its maximum rises (`full`: it is made full);
 * otherwise it keeps what it has, at most the new maximum.
 */
void showPetStats(C)(C creature, bool full = false)
{
    import dmangos.world.updatefields;

    auto state = creature.petData;
    if (state is null || state.base.health == 0) // (a charmed creature keeps its own)
        return;
    const s = withAuras(state.base, creature.auras);
    ref v = creature.values;
    const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
    v.set!UNIT_FIELD_MAXHEALTH(s.health);
    if (full || (health && (health >= maxHealth || health > s.health)))
        v.set!UNIT_FIELD_HEALTH(s.health);
    if (state.type != PetType.hunter)
    {
        const mana = v.get!UNIT_FIELD_POWER1(0), maxMana = v.get!UNIT_FIELD_MAXPOWER1(0);
        v.set!UNIT_FIELD_MAXPOWER1(0, s.mana);
        if (full || mana >= maxMana || mana > s.mana)
            v.set!UNIT_FIELD_POWER1(0, s.mana);
    }
    v.set!UNIT_FIELD_RESISTANCES(0, s.armor);
    foreach (school; 1 .. 7)
        v.set!UNIT_FIELD_RESISTANCES(school, cast(uint)(s.resistances[school - 1] > 0 ? s.resistances[school - 1] : 0));
    v.set!UNIT_FIELD_STAT0(s.stats[0]);
    v.set!UNIT_FIELD_STAT1(s.stats[1]);
    v.set!UNIT_FIELD_STAT2(s.stats[2]);
    v.set!UNIT_FIELD_STAT3(s.stats[3]);
    v.set!UNIT_FIELD_STAT4(s.stats[4]);
    v.set!UNIT_FIELD_ATTACK_POWER(s.attackPower);
    v.set!UNIT_FIELD_MINDAMAGE(s.minDamage);
    v.set!UNIT_FIELD_MAXDAMAGE(s.maxDamage);
    state.statsShownAt = creature.auras.changes;
}

// ---------------------------------------------------------------------------
// World tables
// ---------------------------------------------------------------------------

/// `pet_levelstats`, `petcreateinfo_spell`, `pet_name_generation`.
struct PetData
{
    PetLevelStats[uint][uint] levelStats; /// by creature entry (1: every hunter pet), then level
    uint[4][uint] createSpells;           /// the spells a new pet of an entry starts with
    string[][2][uint] nameParts;          /// by entry: first halves, second halves
    /// `spell_pet_auras`: the aura a pet of an entry (0: any) has while its owner has a spell (a talent: Master
    /// Demonologist, Spirit Bond; Soul Link's spell), by the owner's spell, then the entry. CMaNGOS's table, read
    /// only for what the spells' own data does not link: their dummy effects and auras name no aura of the pet's.
    uint[uint][uint] petAuras;

    /// The aura a pet of `entry` has while its owner has `spell`; 0 if none.
    uint petAuraOf(uint spell, uint entry) const
    {
        if (const byEntry = spell in petAuras)
        {
            if (const aura = entry in *byEntry)
                return *aura;
            if (const aura = 0 in *byEntry)
                return *aura;
        }
        return 0;
    }

    /// The stats of entry `entry` at `level`; null if there are none.
    const(PetLevelStats)* statsFor(uint entry, uint level) const
    {
        if (auto byLevel = entry in levelStats)
            return level in *byLevel;
        return null;
    }

    /// A random name for a new pet: a first half and a second, or (none for it) the creature's name.
    string generateName(uint entry, string creatureName) const
    {
        if (auto parts = entry in nameParts)
            if ((*parts)[0].length && (*parts)[1].length)
                return (*parts)[0][uniform(0, $)] ~ (*parts)[1][uniform(0, $)];
        return creatureName;
    }

    /// Reads them from the world database.
    static PetData load(Db)(Db world)
    {
        PetData d;
        foreach (row; world.query!"SELECT creature_entry, level, hp, mana, armor, str, agi, sta, inte, spi FROM pet_levelstats"())
        {
            PetLevelStats s;
            s.health = row.get!uint(2);
            s.mana = row.get!uint(3);
            s.armor = row.get!uint(4);
            foreach (i; 0 .. 5)
                s.stats[i] = row.get!uint(5 + i);
            d.levelStats.require(row.get!uint(0), null)[row.get!uint(1)] = s;
        }
        foreach (row; world.query!"SELECT entry, Spell1, Spell2, Spell3, Spell4 FROM petcreateinfo_spell"())
            d.createSpells[row.get!uint(0)] = [row.get!uint(1), row.get!uint(2), row.get!uint(3), row.get!uint(4)];
        foreach (row; world.query!"SELECT spell, pet, aura FROM spell_pet_auras"())
            d.petAuras.require(row.get!uint(0))[row.get!uint(1)] = row.get!uint(2);
        foreach (row; world.query!"SELECT word, entry, half FROM pet_name_generation"())
            d.nameParts.require(row.get!uint(1))[row.get!uint(2) ? 1 : 0] ~= row.get!string(0);
        return d;
    }
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

/// A cooldown of a pet's spell, for `SMSG_PET_SPELLS`.
struct PetCooldown
{
    uint spell;
    uint spellMs;
    uint category;
    uint categoryMs;
}

/**
 * `SMSG_PET_SPELLS`: the pet, its react and command states, the ten
 * buttons, the spells it knows (for the spellbook) and its cooldowns. An empty body (just a zero
 * guid) takes the bar away.
 */
const(ubyte)[] petSpellsPacket(ulong pet, ReactState react, CommandState command, const ref ActionBar bar,
    const(PetSpellRecord)[] spells, const(PetCooldown)[] cooldowns)
{
    ByteWriter w;
    w.put(pet);
    w.put(0u);
    w.put(cast(ubyte) react);
    w.put(cast(ubyte) command);
    w.put(cast(ushort) 0);
    foreach (b; bar.buttons)
        w.put(b);
    w.put(cast(ubyte) spells.length);
    foreach (s; spells)
        w.put(actionButton(s.spell, s.active));
    w.put(cast(ubyte) cooldowns.length);
    foreach (c; cooldowns)
    {
        w.put(cast(ushort) c.spell);
        w.put(cast(ushort) c.category);
        w.put(c.spellMs);
        w.put(c.categoryMs);
    }
    return w.data;
}

/// `SMSG_PET_SPELLS` with only a zero guid: the owner has no pet bar any more.
const(ubyte)[] noPetSpellsPacket()
{
    ByteWriter w;
    w.put(0UL);
    return w.data;
}

/// `SMSG_PET_NAME_QUERY_RESPONSE`; `name` null: no such pet.
const(ubyte)[] petNameQueryResponse(uint number, string name, uint timestamp)
{
    ByteWriter w;
    w.put(number);
    if (name is null)
    {
        w.put(cast(ubyte) 0);
        w.put(0u);
        w.put(cast(ubyte) 0);
        return w.data;
    }
    w.putCString(name);
    w.put(timestamp);
    return w.data;
}

/// One stabled (or the current) pet, for `MSG_LIST_STABLED_PETS`.
struct StableEntry
{
    uint number;
    uint entry;
    uint level;
    string name;
    uint loyalty;
    ubyte slot; /// 1: the current pet; 2, 3: the stable slots; 3 also: a dismissed pet
}

/// `MSG_LIST_STABLED_PETS`: the stable master's list of the player's pets and its bought slots.
const(ubyte)[] stableListPacket(ulong npc, uint slotsBought, const(StableEntry)[] pets)
{
    ByteWriter w;
    w.put(npc);
    w.put(cast(ubyte) pets.length);
    w.put(cast(ubyte) slotsBought);
    foreach (p; pets)
    {
        w.put(p.number);
        w.put(p.entry);
        w.put(p.level);
        w.putCString(p.name);
        w.put(p.loyalty);
        w.put(p.slot);
    }
    return w.data;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest
{
    auto bar = ActionBar.initial();
    // attack, follow, stay as commands; aggressive, defensive, passive as reactions.
    assert(bar.buttons[0] == actionButton(CommandState.attack, ActiveState.command));
    assert(bar.buttons[2] == actionButton(CommandState.stay, ActiveState.command));
    assert(bar.buttons[7] == actionButton(ReactState.aggressive, ActiveState.reaction));
    assert(bar.buttons[9] == actionButton(ReactState.passive, ActiveState.reaction));
    assert(bar.addSpell(3110, ActiveState.enabled) && buttonAction(bar.buttons[3]) == 3110);
    assert(bar.addSpell(7799, ActiveState.enabled, 3110) && buttonAction(bar.buttons[3]) == 7799, "a higher rank takes its place");
    bar.setAutocast(7799, false);
    assert(buttonType(bar.buttons[3]) == ActiveState.disabled);
    const saved = bar.toString();
    assert(ActionBar.parse(saved) == bar && ActionBar.parse("1 2 3") == ActionBar.initial());
    assert(saved[0 .. 4] == "7 2 ");
}

unittest
{
    CreatureTemplate wolf;
    wolf.entry = 299;
    wolf.meleeBaseAttackTime = 2000;
    auto stats = PetLevelStats(198, 1, 518, [31, 26, 30, 22, 23]);
    const s = petStats(PetType.hunter, wolf, 10, &stats, null, 0.5f, 1, 1.0f, 60);
    assert(s.health == 198 && s.mana == 0 && s.armor == 518);
    // weapon: 10 * 2000 / 2000 = 10, so 7.5 to 11.25; attack power 2 * 31 - 20 = 42, a fourteenth of it added.
    assert(s.attackPower == 42 && s.minDamage == 7.5f + 3 && s.maxDamage == 11.25f + 3);
    assert(s.scale > 0.5f && s.scale < 1);
    CreatureTemplate imp;
    imp.entry = 416;
    imp.meleeBaseAttackTime = 2000;
    imp.damageMultiplier = 1;
    auto impStats = PetLevelStats(140, 48, 20, [20, 5, 20, 24, 23]);
    auto cls = CreatureClassStats(0, 0, 2.0f, 14.0f);
    const i = petStats(PetType.summon, imp, 1, &impStats, &cls);
    assert(i.health == 140 && i.mana == 48 && i.attackPower == 10);
    assert(i.minDamage == 2 + 2 + 10 / 14.0f && i.scale == 0);
    assert(petStats(PetType.hunter, wolf, 10, null, null).health == 1, "no stats: weak");
}

unittest
{
    auto p = new PetState;
    p.number = 5;
    p.type = PetType.hunter;
    p.owner = 7;
    p.name = "Wolf";
    p.bar = ActionBar.initial();
    p.learn(17253, false, true);
    p.learn(4187, true, false);
    assert(p.knows(17253) && buttonAction(p.bar.buttons[3]) == 17253 && buttonAction(p.bar.buttons[4]) == 0);
    const r = p.record(299, 903, 10, 0, ReactState.defensive, 100, 0, PetSlot.current, 1000);
    assert(r.id == 5 && r.owner == 7 && r.level == 10 && r.spells.length == 2 && r.reactState == ReactState.defensive);
    auto back = PetState.from(r, 7);
    assert(back.bar == p.bar && back.name == "Wolf" && back.spells == p.spells);
    assert(petNameQueryResponse(5, null, 0) == [5, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    const spells = petSpellsPacket(0x1234, ReactState.defensive, CommandState.follow, p.bar, p.spells, null);
    assert(spells.length == 8 + 4 + 4 + 40 + 1 + 8 + 1);
    PetData d;
    d.nameParts[416] = [["Aba"], ["zim"]];
    assert(d.generateName(416, "Imp") == "Abazim" && d.generateName(417, "Felhunter") == "Felhunter");
    d.petAuras[23785] = [416: 23759, 417: 23762];
    d.petAuras[19028] = [0: 25228];
    assert(d.petAuraOf(23785, 417) == 23762 && d.petAuraOf(23785, 1860) == 0 && d.petAuraOf(19028, 1860) == 25228);
}

/// A pet's stats with its auras: 15% more health (Fel Stamina's share of 18735), 30% more armor, 5 more stamina.
unittest
{
    import dmangos.world.auras : AuraSet, makeAura;
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields : TypeId;

    PetStats base;
    base.health = 1000;
    base.mana = 500;
    base.armor = 200;
    base.stats = [20, 20, 30, 40, 10];
    base.apPerStrength = 2;
    base.apOffset = -20;
    SpellInfo health, armor, stamina;
    health.id = 1;
    health.effect[0] = SpellEffect.applyAura;
    health.casting.applyAuraName[0] = AuraType.modIncreaseHealthPercent;
    armor.id = 2;
    armor.effect[0] = SpellEffect.applyAura;
    armor.casting.applyAuraName[0] = AuraType.modResistancePct;
    armor.miscValue[0] = 1;
    stamina.id = 3;
    stamina.effect[0] = SpellEffect.applyAura;
    stamina.casting.applyAuraName[0] = AuraType.modStat;
    stamina.miscValue[0] = 2;
    auto values = UpdateValues(TypeId.unit);
    AuraSet auras;
    bool isNew;
    assert(withAuras(base, auras).health == 1000, "nothing without auras");
    auras.apply(makeAura(&health, 1, 60, -1, true, [15, 0, 0]), values, isNew);
    auras.apply(makeAura(&armor, 1, 60, -1, true, [30, 0, 0]), values, isNew);
    auras.apply(makeAura(&stamina, 1, 60, -1, true, [5, 0, 0]), values, isNew);
    const s = withAuras(base, auras);
    assert(s.health == cast(uint)((1000 + 5 * 10) * 1.15f + 0.5f) && s.armor == 260 && s.stats[2] == 35 && s.mana == 500);
}
