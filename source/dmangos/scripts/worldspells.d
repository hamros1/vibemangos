/**
 * Spell scripts found all over the world (ScriptDevAI's `spell_scripts`, `item_scripts` and the Scourge
 * Invasion's): eating and drinking, the creatures a gatherer's or a lockpicker's opening calls on, hate
 * halved or added, the Naxxramas attunement, the stone skin of statues, the banished exiles of Arathi,
 * the invasion's camps, and the Orb of Deception.
 */
module dmangos.scripts.worldspells;

import dmangos.script;

/// `SpellVisualKit`s of eating and drinking.
enum : uint { visualFood = 406, visualDrink = 438 }

/// Food: the eater chews at each heartbeat (every five seconds) while it eats.
@spell("spell_food_animation")
struct FoodAnimation
{
    void on(ref SpellContext it, const ref AuraHeartbeat e)
    {
        it.playVisual(e.target, visualFood);
    }
}

/// Drink: the drinker drinks at each heartbeat while it drinks.
@spell("spell_drink_animation")
struct DrinkAnimation
{
    void on(ref SpellContext it, const ref AuraHeartbeat e)
    {
        it.playVisual(e.target, visualDrink);
    }
}

/**
 * Opening, mining, herb gathering, a lock picked or blown open: as it begins, the enemies within twelve
 * yards of the one at it (critters not) come for it.
 */
@spell("spell_gameobject_call_for_help_on_usage")
struct GameobjectCallForHelpOnUsage
{
    enum float range = 12;

    void on(ref SpellContext it, const ref CastStarted e)
    {
        EntityRef[32] found;
        foreach (enemy; found[0 .. it.enemiesNear(e.caster, range, found[])])
            it.attack(enemy, e.caster);
    }
}

/// Hate to 50% (a creature's spell): half of its target's threat on it is gone.
@spell("spell_hate_to_half")
struct HateToHalf
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect == 0 && e.target)
            it.modifyThreat(e.caster, e.target, -50);
    }
}

/// Net Guard, triggered by Net (6533), halves the victim's threat on its caster when applied.
@spell("spell_net_guard") @spellIds(11920)
struct NetGuard
{
    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (e.effect == 0 && e.caster.isCreature)
            it.modifyThreat(e.caster, e.target, -50);
    }
}

/// Random Aggro (a creature's spell): each enemy it reaches is on its threat list.
@spell("spell_random_aggro")
struct RandomAggro
{
    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.target)
            it.addThreat(e.caster, e.target);
    }
}

/// Arcane Cloaking (the Dread Citadel's reward): a player it reaches gets the flag that lets it into Naxxramas.
@spell("spell_arcane_cloaking")
struct ArcaneCloaking
{
    enum uint naxxramasEntryFlagTrigger = 29296;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.effect == 0 && e.target.isPlayer)
            it.castSpell(e.caster, naxxramasEntryFlagTrigger, e.target);
    }
}

/**
 * Stoned: a statue under its stone skin can be neither fought nor spoken to, and stands still; when the skin
 * goes it wakes (the Stone Dwarf Awaken Visual, whose effect frees it).
 */
@spell("spell_stoned")
struct Stoned
{
    enum uint awakenVisual = 10254;
    enum uint flags = UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc | UnitFlag.uninteractible;

    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (!e.target.isCreature)
            return;
        it.unitFlags(e.target, flags);
        it.rooted(e.target, true);
    }

    void on(ref SpellContext it, const ref AuraEnded e)
    {
        if (!e.target.isCreature)
            return;
        it.castSpell(e.target, awakenVisual, e.target);
        it.rooted(e.target, false);
        it.unitFlags(e.target, flags, false);
    }
}

/**
 * Banish Burning, Cresting or Thundering Exile (an item of the Arathi Highlands): only at its own exile,
 * which is torn from this world.
 */
@spell("spell_banish_exile")
struct BanishExile
{
    enum int emoteBanished = -1010004;
    enum uint banished = 3617;

    static uint exileOf(uint spell)
    {
        switch (spell)
        {
        case 4130: return 2760; // Burning Exile
        case 4131: return 2761; // Cresting Exile
        case 4132: return 2762; // Thundering Exile
        default: return 0;
        }
    }

    void on(ref SpellContext it, const ref CastChecked e)
    {
        if (e.target && e.target.entry != exileOf(it.spellId))
            it.refuse();
    }

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (!e.target)
            return;
        it.say(e.target, emoteBanished, e.caster);
        it.castSpell(e.target, banished, EntityRef.init);
    }
}

/// The Scourge Invasion's Scourge Strike (its guardians'): it strikes the Scourge's creatures, never a player or a pet.
@spell("spell_scourge_strike")
struct ScourgeStrike
{
    void on(ref SpellContext it, const ref TargetChecked e)
    {
        if (!e.target.isCreature)
            it.exclude();
    }
}

/// The Scourge Invasion's Communique Trigger: the camp it reaches sends its message on (the purple bolt).
@spell("spell_communique_trigger")
struct CommuniqueTrigger
{
    enum uint campToRelay = 28281;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (e.target)
            it.castSpell(e.target, campToRelay, EntityRef.init);
    }
}

/// The Scourge Invasion's Despawner, self: a minion not fighting fades away.
@spell("spell_despawner_self")
struct DespawnerSelf
{
    enum uint spiritSpawnOut = 17680;

    void on(ref SpellContext it, const ref EffectHit e)
    {
        if (!it.inCombat(e.caster))
            it.castSpell(e.caster, spiritSpawnOut, EntityRef.init);
    }
}

/**
 * The Orb of Deception: its bearer looks like one of the other side, of its own sex and the race its own
 * matches (a troll an undead's twin, a tauren a dwarf's, ...).
 */
@spell("spell_orb_of_deception")
struct OrbOfDeception
{
    /// The bearer's own model, the model it takes.
    static uint modelFor(uint native)
    {
        switch (native)
        {
        case 1479: return 10134; // troll female
        case 1478: return 10135; // troll male
        case 59: return 10136;   // tauren male
        case 49: return 10137;   // human male
        case 50: return 10138;   // human female
        case 51: return 10139;   // orc male
        case 52: return 10140;   // orc female
        case 53: return 10141;   // dwarf male
        case 54: return 10142;   // dwarf female
        case 55: return 10143;   // night elf male
        case 56: return 10144;   // night elf female
        case 58: return 10145;   // undead female
        case 57: return 10146;   // undead male
        case 60: return 10147;   // tauren female
        case 1563: return 10148; // gnome male
        case 1564: return 10149; // gnome female
        default: return 0;
        }
    }

    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (const model = modelFor(it.nativeDisplay(e.target)))
            it.transformModel(e.target, model);
    }
}

/**
 * The Corrupted Ashbringer's aura (28282, worn): its bearer is friendly to the Scarlet Crusade, by AB Effect 001
 * (28442, `SPELL_AURA_FORCE_REACTION` on faction 56, cast with the friendly rank as its amount); taken off, that
 * goes too (`AshbringerItemAura`).
 */
@spell("spell_ashbringer_item")
struct AshbringerItem
{
    enum uint effect001 = 28442;

    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (e.effect == 0 && e.target.isPlayer)
            it.castCustom(e.target, effect001, e.target, [int(Standing.friendly), 0, 0]);
    }

    void on(ref SpellContext it, const ref AuraEnded e)
    {
        if (e.effect == 0 && e.target.isPlayer)
            it.removeAura(e.target, effect001);
    }
}
