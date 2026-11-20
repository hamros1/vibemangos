/**
 * The item and holiday spells CMaNGOS's core scripts by id (the generic cases of `Spell::EffectDummy` and
 * `Spell::EffectScriptEffect`, which no `spell_scripts` row names), bound here by `@spellIds`: the Deviate
 * Fish and its Savory Delight, the Noggenfogger Elixir, the engineers' gadgets (the Shrink Ray, the
 * Net-o-Matic, the Mind Control Cap, the Universal Remote, the transporter, the dragonlings and the battle
 * chicken), the Six Demon Bag, Hourglass Sand, the Hallow's End treats and costumes, the tributes of
 * Uther and Grom, the Love is in the Air candies and bracelets, Elune's Candle, the fetid skull, the
 * bending shinbone, Polly, the worg pup, the RC tank, the Jubling and the Ashbringer's call.
 *
 * Each does what the case does and nothing else: no database script follows (the case returned).
 */
module dmangos.scripts.itemeffects;

import dmangos.script;

/// `Gender`
private enum : ubyte { male = 0, female = 1 }

/// Deviate Fish: one of its five surprises (sleepy, invigorated, shrunk, party time, a healthy spirit).
@spell("spell_deviate_fish") @spellIds(8063)
struct DeviateFish
{
    static immutable uint[5] surprises = [8064, 8065, 8066, 8067, 8068];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, surprises[it.random(5)], e.caster);
    }
}

/// Savory Deviate Delight: the eater flips out as a ninja, or turns pirate, as a man or a woman.
@spell("spell_savory_deviate_delight") @spellIds(8213)
struct SavoryDeviateDelight
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.caster.isPlayer)
            return;
        const man = it.genderOf(e.caster) == male;
        const spell = it.random(2) ? (man ? 8219 : 8220) : (man ? 8221 : 8222); // Flip Out, Yaaarrrr
        it.castSpell(e.caster, spell, e.caster);
    }
}

/// Noggenfogger Elixir: a skeleton, slow fall, or shrunk.
@spell("spell_noggenfogger_elixir") @spellIds(16589)
struct NoggenfoggerElixir
{
    static immutable uint[3] outcomes = [16595, 16593, 16591];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, outcomes[it.random(3)], e.caster);
    }
}

/// Hourglass Sand: the bronze affliction of Chromaggus goes.
@spell("spell_hourglass_sand") @spellIds(23645)
struct HourglassSand
{
    enum uint broodAfflictionBronze = 23170;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        it.removeAura(e.caster, broodAfflictionBronze);
    }
}

/**
 * The Six Demon Bag: a fireball (a quarter), a frostbolt (a quarter), chain lightning (a fifth), enveloping
 * winds, a felhound minion, or a polymorph: on the target, or (three in a hundred) on its user.
 */
@spell("spell_six_demon_bag") @spellIds(14537)
struct SixDemonBag
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target)
            return;
        const roll = it.random(100);
        if (roll < 25)
            it.castSpell(e.caster, 15662, e.target); // Fireball
        else if (roll < 50)
            it.castSpell(e.caster, 11538, e.target); // Frostbolt
        else if (roll < 70)
            it.castSpell(e.caster, 21179, e.target); // Chain Lightning
        else if (roll < 85)
            it.castSpell(e.caster, 25189, e.target); // Enveloping Winds
        else if (roll < 90)
            it.castSpell(e.caster, 14642, e.caster); // Summon Felhound Minion
        else if (roll < 97)
            it.castSpell(e.caster, 14621, e.target); // Polymorph
        else
            it.castSpell(e.caster, 14621, e.caster); // Polymorph, backfiring
    }
}

/// The Gnomish Shrink Ray: mostly the target shrinks; sometimes its user does, or both sides grow or shrink.
@spell("spell_gnomish_shrink_ray") @spellIds(13006)
struct GnomishShrinkRay
{
    enum : uint { grow = 13004, shrinkAll = 13010, shrink = 13003 }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target)
            return;
        const roll = it.random(100);
        if (roll < 3)
            it.castSpell(e.caster, grow, e.caster); // the user's party grows
        else if (roll < 6)
            it.castSpell(e.caster, shrinkAll, e.caster); // the user's party shrinks
        else if (roll < 9)
            it.castSpell(e.caster, grow, e.target); // the enemies grow
        else if (roll < 12)
            it.castSpell(e.caster, shrinkAll, e.target); // the enemies shrink
        else if (roll < 24)
            it.castSpell(e.caster, shrink, e.caster); // the user shrinks
        else
            it.castSpell(e.caster, shrink, e.target);
    }
}

/// The Net-o-Matic Projector: the target netted; now and then its user instead, or a longer net with a charge.
@spell("spell_net_o_matic") @spellIds(13120)
struct NetOMatic
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target)
            return;
        const roll = it.random(100);
        it.castSpell(e.caster, roll < 2 ? 16566 : roll < 4 ? 13119 : 13099, e.target);
    }
}

/// The Gnomish Mind Control Cap: nine times in ten the target is controlled; once in ten a player turns it on its user.
@spell("spell_gnomish_mind_control_cap") @spellIds(13180)
struct GnomishMindControlCap
{
    enum uint mindControl = 13181;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target)
            return;
        const roll = it.random(10);
        if (roll == 1 && e.target.isPlayer)
            it.castSpell(e.target, mindControl, e.caster);
        else if (roll)
            it.castSpell(e.caster, mindControl, e.target);
    }
}

/// The Gnomish Universal Remote: the machine is controlled, malfunctions (rooted), or is enraged.
@spell("spell_gnomish_universal_remote") @spellIds(8344)
struct GnomishUniversalRemote
{
    static immutable uint[3] outcomes = [8345, 8346, 8347];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.target)
            it.castSpell(e.caster, outcomes[it.random(3)], e.target);
    }
}

/// The Ultrasafe Transporter: Gadgetzan: there, or (one in six) somewhere else.
@spell("spell_ultrasafe_transporter_gadgetzan") @spellIds(23453)
struct UltrasafeTransporterGadgetzan
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        it.castSpell(e.caster, it.random(6) ? 23441 : 23446, e.caster);
    }
}

/// The dragonlings and the battle chicken: the item summons its machine.
@spell("spell_engineering_companion") @spellIds(23074, 23075, 23076, 23133)
struct EngineeringCompanion
{
    static uint summonOf(uint spell)
    {
        switch (spell)
        {
        case 23074: return 19804; // Arcanite Dragonling
        case 23075: return 12749; // Mithril Mechanical Dragonling
        case 23076: return 4073;  // Mechanical Dragonling
        case 23133: return 13166; // Gnomish Battle Chicken
        default: return 0;
        }
    }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, summonOf(it.spellId), e.caster);
    }
}

/// A Hallow's End treat: larger and orange, a skeleton, a pirate or a ghost.
@spell("spell_hallows_end_treat") @spellIds(24930)
struct HallowsEndTreat
{
    static immutable uint[4] outcomes = [24924, 24925, 24926, 24927];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        it.castSpell(e.caster, outcomes[it.random(4)], e.caster);
    }
}

/// The Hallow's End costumes: a player of the group dressed as a pirate, a ninja, a leper gnome or a ghost (of its
/// sex), or (the random one) as any of them, a skeleton, a bat or a wisp.
@spell("spell_hallows_end_costume") @spellIds(24717, 24718, 24719, 24720, 24737)
struct HallowsEndCostume
{
    static uint costume(uint spell, bool man, uint roll)
    {
        switch (spell)
        {
        case 24717: return man ? 24708 : 24709; // Pirate
        case 24718: return man ? 24711 : 24710; // Ninja
        case 24719: return man ? 24712 : 24713; // Leper Gnome
        case 24737: return man ? 24735 : 24736; // Ghost
        case 24720: // Random
            switch (roll)
            {
            case 0: return man ? 24708 : 24709;
            case 1: return man ? 24711 : 24710;
            case 2: return man ? 24712 : 24713;
            case 3: return 24723; // Skeleton
            case 4: return 24732; // Bat
            case 5: return man ? 24735 : 24736;
            default: return 24740; // Wisp
            }
        default:
            return 0;
        }
    }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target.isPlayer)
            return;
        if (const spell = costume(it.spellId, it.genderOf(e.target) == male, it.random(7)))
            it.castSpell(e.caster, spell, e.target);
    }
}

/// Uther's and Grom's Tributes: the blessing of the user's race.
@spell("spell_tribute") @spellIds(24194, 24195)
struct Tribute
{
    static uint blessingOf(uint spell, ubyte race)
    {
        if (spell == 24194) // Uther's
            switch (race)
            {
            case 1: return 24105; // human
            case 3: return 24107; // dwarf
            case 4: return 24108; // night elf
            case 7: return 24106; // gnome
            default: return 0;
            }
        switch (race) // Grom's
        {
        case 2: return 24104; // orc
        case 5: return 24103; // undead
        case 6: return 24102; // tauren
        case 8: return 24101; // troll
        default: return 0;
        }
    }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            if (const blessing = blessingOf(it.spellId, it.raceOf(e.caster)))
                it.castSpell(e.caster, blessing, e.caster);
    }
}

/// Create Heart Candy: one of the eight sayings.
@spell("spell_create_heart_candy") @spellIds(26678)
struct CreateHeartCandy
{
    static immutable uint[8] candies = [26668, 26670, 26671, 26672, 26673, 26674, 26675, 26676];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        it.castSpell(e.caster, candies[it.random(8)], e.caster);
    }
}

/// Give Friendship Bracelet: a heartbroken player is heartbroken no more, and makes a bracelet of its own.
@spell("spell_give_friendship_bracelet") @spellIds(26899)
struct GiveFriendshipBracelet
{
    enum uint heartbroken = 26898, cancelHeartbroken = 26921;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target.isPlayer || !it.hasAura(e.target, heartbroken))
            return;
        it.removeAura(e.target, heartbroken);
        it.castSpell(e.target, cancelHeartbroken, e.target);
    }
}

/// Elune's Candle: at Omen, one of its five burning sparks (damage); at anything else, a harmless one.
@spell("spell_elunes_candle") @spellIds(26374)
struct ElunesCandle
{
    enum uint omen = 15467, harmless = 26636;
    static immutable uint[5] sparks = [26622, 26623, 26624, 26625, 26649];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target)
            return;
        it.castSpell(e.caster, e.target.entry == omen && e.target.isCreature ? sparks[it.random(5)] : harmless, e.target);
    }
}

/// Test Fetid Skull: a resonating skull, or bone dust.
@spell("spell_test_fetid_skull") @spellIds(17271)
struct TestFetidSkull
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, it.random(2) ? 17269 : 17270, e.caster);
    }
}

/// The Bending Shinbone: one time in five it breaks; else it bends.
@spell("spell_bending_shinbone") @spellIds(8856)
struct BendingShinbone
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, it.random(5) == 0 ? 8854 : 8855, e.caster);
    }
}

/// Polly Eats the E.C.A.C.: Polly becomes Polly Jr.
@spell("spell_polly_eats_the_ecac") @spellIds(9976)
struct PollyEatsTheEcac
{
    enum uint summonPollyJr = 9998;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (!e.target.isCreature)
            return;
        it.castSpell(e.target, summonPollyJr, e.target);
        it.despawn(e.target, 100);
    }
}

/// Capture Worg Pup: the pup goes (into the cage the spell makes).
@spell("spell_capture_worg_pup") @spellIds(15998)
struct CaptureWorgPup
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect != 0)
            return;
        it.consume();
        if (e.target.isCreature)
            it.despawn(e.target);
    }
}

/// Summon RC Tank: the tank, for a player.
@spell("spell_summon_rc_tank") @spellIds(24935)
struct SummonRcTank
{
    enum uint rcTank = 24934;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.castSpell(e.caster, rcTank, e.target);
    }
}

/// Jubling Cooldown: the Jubling's own cooldown spell, cast by who it reaches (not triggered).
@spell("spell_jubling_cooldown") @spellIds(23853)
struct JublingCooldown
{
    enum uint jublingCooldown = 23852;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.target)
            it.castSpell(e.target, jublingCooldown, EntityRef.init, false);
    }
}

/// Call of the Ashbringer: one of its twelve whispers, heard by its bearer alone.
@spell("spell_call_of_the_ashbringer") @spellIds(28414)
struct CallOfTheAshbringer
{
    static immutable uint[12] whispers = [8906, 8907, 8908, 8920, 8921, 8922, 8923, 8924, 8925, 8926, 8927, 8928];

    void on(ref SpellContext it, const ref EffectHit e)
    {
        it.consume();
        if (e.caster.isPlayer)
            it.playSound(e.caster, whispers[it.random(12)]);
    }
}
