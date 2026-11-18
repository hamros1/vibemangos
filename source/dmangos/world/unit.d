/**
 * Units: players and creatures under the same rules (docs/DESIGN.md, "Players and creatures: one
 * unit core", step 2).
 *
 * A `UnitRef` is a unit on a map, whichever kind it is: a player (its session) or a creature. It is a
 * small value, made where it is needed (`Map.unit`), never kept as an object of its own. What happens
 * to a unit is written once here and branches on its kind with `final switch`, so every rule handles
 * both kinds and the compiler says so when a kind is added. A creature fights a player, a player a
 * creature, a player a player and a pet a creature through the same code.
 *
 * `dealDamage` is the one way damage reaches a unit, from a swing, a
 * spell or an aura's tick, with what follows from it on each side (fighting back, threat, tapping,
 * rage, the combat state, death and who it is credited to).
 */
module dmangos.world.unit;

import dmangos.world.auras : Aura, makeAura;
import dmangos.world.combat : Fighter, MeleeDamage, MeleeHitOutcome, VictimState;
import dmangos.world.creature : Creature;
import dmangos.world.map : Map;
import dmangos.world.opcodes : Opcode;
import dmangos.world.relations : Relating;
import dmangos.world.character : Character;
import dmangos.world.spells : SpellInfo;
import dmangos.script.api : MenuOption, QuestProgress;

/// What a unit is.
enum UnitKind : ubyte
{
    none,     /// no unit (not here, or not a unit)
    player,   /// a player simulated here
    creature, /// a creature here (a pet is one)
}

/// How damage came.
enum BlowKind : ubyte
{
    melee,    /// a swing
    spell,    /// a spell's direct damage
    periodic, /// an aura's tick (damage over time)
}

/// The circumstances of damage: its kind, and for a swing its roll.
struct Blow
{
    BlowKind kind;
    MeleeDamage melee; /// a swing's outcome, hit flags and damage before blocks

    ///
    static Blow swing(const ref MeleeDamage d)
    {
        return Blow(BlowKind.melee, d);
    }

    ///
    static Blow spell()
    {
        return Blow(BlowKind.spell);
    }

    ///
    static Blow periodic()
    {
        return Blow(BlowKind.periodic);
    }
}

/// See the module documentation.
struct UnitRef
{
    UnitKind kind;
    Character session; /// a player's
    Creature creature;    /// a creature's
    Map map;              /// where it is

    /// The player of `session`, on its map.
    static UnitRef of(Character session)
    {
        if (session is null || session.character is null)
            return UnitRef.init;
        return UnitRef(UnitKind.player, session, null, session.currentMap);
    }

    /// `creature`, on `map`.
    static UnitRef of(Creature creature, Map map)
    {
        return creature is null ? UnitRef.init : UnitRef(UnitKind.creature, null, creature, map);
    }

    /// Whether it is a unit at all.
    bool opCast(B : bool)() const
    {
        return kind != UnitKind.none;
    }

    /// Its guid.
    @property ulong combatGuid() const
    {
        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return session.combatGuid;
        case UnitKind.creature: return creature.guid;
        }
    }

    /// What the formulas need of it now.
    Fighter fighter() const
    {
        final switch (kind)
        {
        case UnitKind.none: return Fighter.init;
        case UnitKind.player: return session.fighter;
        case UnitKind.creature: return creature.fighter;
        }
    }

    /// How the relations see it.
    Relating relating()
    {
        final switch (kind)
        {
        case UnitKind.none: return Relating.init;
        case UnitKind.player: return session.relating;
        case UnitKind.creature: return creature.ai.relatingOf;
        }
    }

    /// Whether nothing may attack it (a GM, a player arriving): left alone.
    @property bool untouchable()
    {
        return kind == UnitKind.player && session.untouchable;
    }

    /// Its health in percent.
    uint healthPercent()
    {
        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return session.healthPercent;
        case UnitKind.creature: return creature.ai.healthPercent;
        }
    }

    /// Whether it has an aura of `spell`.
    bool hasAuraOf(uint spell)
    {
        final switch (kind)
        {
        case UnitKind.none: return false;
        case UnitKind.player: return session.hasAuraOf(spell);
        case UnitKind.creature: return creature.auras.find(spell) !is null;
        }
    }

    /// Whether it is casting.
    @property bool castingSpell()
    {
        final switch (kind)
        {
        case UnitKind.none: return false;
        case UnitKind.player: return session.castingSpell;
        case UnitKind.creature: return creature.ai.castingNow;
        }
    }

    /// The creature `creature` put it in its threat list (a player is in combat while any has it).
    void threatAdded(ulong creature)
    {
        if (kind == UnitKind.player)
            session.threatAdded(creature);
    }

    /// ditto: took it out.
    void threatRemoved(ulong creature)
    {
        if (kind == UnitKind.player)
            session.threatRemoved(creature);
    }

    /// An aura this unit cast on `target` ticked: its effect, done by its caster (a player's).
    void auraTick(Creature target, Aura aura, size_t effect)
    {
        if (kind == UnitKind.player)
            session.auraTick(target, aura, effect);
    }

    /// An aura of `spell` from `caster`.
    void auraFrom(ulong caster, const(SpellInfo)* spell, uint casterLevel, int durationMs, const int[3] values)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            return session.auraFrom(caster, spell, casterLevel, durationMs, values);
        case UnitKind.creature:
            bool isNew;
            creature.auras.apply(makeAura(spell, caster, casterLevel, durationMs, false, values), creature.values,
                isNew);
            map.flushObjectChanges(creature);
            return;
        }
    }

    /// Its aura of `spell` goes (its caster stopped channelling it, or a script took it away).
    void auraRemovedBy(uint spell)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            return session.auraRemovedBy(spell);
        case UnitKind.creature:
            if (auto aura = creature.auras.find(spell))
            {
                creature.auras.remove(aura, creature.values);
                map.flushObjectChanges(creature);
            }
            return;
        }
    }

    /// Its cast is interrupted by the creature `by`.
    void castInterruptedBy(ulong by)
    {
        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player: return session.castInterruptedBy(by);
        case UnitKind.creature: return creature.ai.interruptCast();
        }
    }

    /// A swing from `attacker` landed (or not): `dealDamage`.
    void meleeHitBy(ulong attacker, const ref MeleeDamage damage)
    {
        dealDamage(map.unit(attacker), this, damage.damage, Blow.swing(damage));
    }

    /// Damage of `school` (an index) about to hit it: what its shields absorb comes off `damage` (a player's; a creature has none).
    uint absorb(uint school, ref uint damage)
    {
        return kind == UnitKind.player ? session.absorbIncoming(school, damage) : 0;
    }

    /// A spell from `caster` hit it for `damage`: `dealDamage`.
    void spellHitBy(ulong caster, uint damage)
    {
        dealDamage(map.unit(caster), this, damage, Blow.spell());
    }

    // What only a player has: its client, its quests, its gossip window. Nothing for a creature.

    /// A packet for its client.
    void tell(Opcode opcode, const(ubyte)[] body_)
    {
        if (kind == UnitKind.player)
            session.tell(opcode, body_);
    }

    /// A quest's event happened for it (or its place was explored).
    void questEventHappened(uint quest)
    {
        if (kind == UnitKind.player)
            session.questEventHappened(quest);
    }

    /// Its quest failed.
    void questFailedBy(uint quest)
    {
        if (kind == UnitKind.player)
            session.questFailedBy(quest);
    }

    /// Kill credit for `entry` from `creature`.
    void killCreditFrom(uint entry, ulong creature)
    {
        if (kind == UnitKind.player)
            session.killCreditFrom(entry, creature);
    }

    /// Where it stands with `quest`.
    QuestProgress questStatusOf(uint quest)
    {
        return kind == UnitKind.player ? session.questStatusOf(quest) : QuestProgress.none;
    }

    /// The gossip menu `menu` of `npc`.
    void showGossip(ulong npc, uint menu)
    {
        if (kind == UnitKind.player)
            session.showGossip(npc, menu);
    }

    /// A menu a script built.
    void showScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests)
    {
        if (kind == UnitKind.player)
            session.showScriptGossip(npc, textId, options, withQuests);
    }

    /// Its gossip window closes.
    void closeGossip()
    {
        if (kind == UnitKind.player)
            session.closeGossip();
    }
}

/// The player who owns `unit`'s kills and taps: itself, or a pet's owner (if on the map); null otherwise.
Character creditedPlayer(UnitRef unit)
{
    final switch (unit.kind)
    {
    case UnitKind.none:
        return null;
    case UnitKind.player:
        return unit.session;
    case UnitKind.creature:
        if (!unit.creature.petOwner)
            return null;
        return cast(Character) unit.map.find(unit.creature.petOwner);
    }
}

/**
 * Deals `damage` from `attacker` (none: from nowhere, a GM's kill) to `victim`, as
 * `blow` says it came. A player suffers it (`Character.sufferDamage`: standing up, rage, the
 * combat state, a duel's last blow, death). A creature fights back and takes it as
 * threat, is tapped for the player the blow is credited to, and may die: its death is that player's
 * kill (experience, loot, quests), a pet's dies for its owner, and any other just dies.
 */
void dealDamage(UnitRef attacker, UnitRef victim, uint damage, const Blow blow)
{
    final switch (victim.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.player:
        return victim.session.sufferDamage(attacker, damage, blow);
    case UnitKind.creature:
        return creatureDamaged(attacker, victim, damage, blow);
    }
}

private void creatureDamaged(UnitRef attacker, UnitRef victim, uint damage, const Blow blow)
{
    auto creature = victim.creature;
    auto map = victim.map;
    if (!creature.alive || (blow.kind == BlowKind.melee && blow.melee.targetState == VictimState.evades))
        return;
    if (attacker)
    {
        creature.ai.attackedBy(attacker, map);
        creature.ai.damageTaken(attacker, damage);
    }
    map.wake(creature.guid);
    if (damage == 0)
        return;
    auto credited = creditedPlayer(attacker);
    if (credited !is null && !creature.petOwner)
        credited.tapCreature(creature);
    const killed = creature.takeDamage(damage);
    map.flushObjectChanges(creature);
    if (!killed)
        return;
    if (creature.petOwner)
    {
        // A pet: dead for its owner to revive (or to summon again).
        map.creatureDeath(creature);
        if (auto owner = cast(Character) map.find(creature.petOwner))
            owner.ownPetDied();
        return;
    }
    if (credited !is null)
        return credited.killedCreature(creature); // the player's kill: its rewards
    map.creatureDeath(creature);
}
