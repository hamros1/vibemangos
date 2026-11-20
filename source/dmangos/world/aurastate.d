/**
 * Aura states (`UNIT_FIELD_AURASTATE`): the flags a unit carries for a while after something happened to it,
 * which the client reads to let a spell be cast at all. A spell's `CasterAuraState` names one the caster must
 * have (Revenge after a dodge, a parry or a block; Judgement while a seal lasts), its `TargetAuraState` one its
 * target must have (Execute below a fifth of its health): the client greys the spell out without it and sends
 * no cast, so the server only keeps the flags right, as CMaNGOS does (`Unit::ModifyAuraState`; it does not
 * check them again at the cast).
 *
 * Who sets which: the health rule here, for every unit as its health changes (`UpdateValues`); the defensive
 * states as a swing is dodged, parried or blocked (`dmangos.world.classspells`, for four seconds: the
 * reactive timers); Judgement's while a seal is on (also there); frozen while a frost root or stun is.
 */
module dmangos.world.aurastate;

/// CMaNGOS's `AuraState` (1.12 has these; 6 is unused, and 7 is the hunter's parry).
enum AuraState : ubyte
{
    defense = 1,             /// AURA_STATE_DEFENSE: it dodged, parried or blocked (Revenge, Overpower's warrior side)
    healthless20Percent = 2, /// AURA_STATE_HEALTHLESS_20_PERCENT: under a fifth of its health (Execute, Hammer of Wrath)
    berserking = 3,          /// AURA_STATE_BERSERKING: the troll's racial, after a crit taken
    frozen = 4,              /// AURA_STATE_FROZEN: rooted or stunned by frost (Shatter)
    judgement = 5,           /// AURA_STATE_JUDGEMENT: a seal is on (Judgement)
    hunterParry = 7,         /// AURA_STATE_HUNTER_PARRY: a hunter parried (Counterattack)
}

/// The state's bit in `UNIT_FIELD_AURASTATE` (`convertEnumToFlag`: state n is bit n - 1).
uint auraStateFlag(AuraState state) pure nothrow @nogc @safe
{
    return 1u << (state - 1);
}

/// `flags` with `state` on or off.
uint withAuraState(uint flags, AuraState state, bool on) pure nothrow @nogc @safe
{
    return on ? flags | auraStateFlag(state) : flags & ~auraStateFlag(state);
}

/// Whether `health` of `maxHealth` is under a fifth (alive: a dead unit has no such state).
bool healthless20Percent(uint health, uint maxHealth) pure nothrow @nogc @safe
{
    return health > 0 && health < maxHealth * 0.20f;
}

///
unittest
{
    assert(auraStateFlag(AuraState.defense) == 1 && auraStateFlag(AuraState.judgement) == 0x10);
    assert(withAuraState(0, AuraState.healthless20Percent, true) == 2);
    assert(withAuraState(3, AuraState.defense, false) == 2);
    assert(healthless20Percent(19, 100) && !healthless20Percent(20, 100) && !healthless20Percent(0, 100));
}
