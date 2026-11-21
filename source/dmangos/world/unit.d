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

import dmangos.world.auras : Aura, AuraSet, makeAura;
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

/// Returns a defensive proc to the attacker's node. Spell zero selects a damage shield such as Thorns.
alias SwingRetaliationReply = void delegate(uint damage, uint school, uint spell, float threatFactor);

/// The circumstances of damage: its kind, and for a swing its roll.
struct Blow
{
    BlowKind kind;
    MeleeDamage melee; /// a swing's outcome, hit flags and damage before blocks
    uint school;       /// a spell's or a tick's school index (a swing's is its own)
    float threat = 1;  /// its threat's factor by its spell's modifiers (`SPELLMOD_THREAT`; Holy Shield's 20% more)
    bool crit;         /// a spell's crit (Eye for an Eye's)
    ulong remotePlayer; /// a spell's caster, when simulated by another node
    bool remotePlayerPvP;
    SwingRetaliationReply retaliate; /// sends defensive damage back to a remote attacker

    ///
    static Blow swing(const ref MeleeDamage d)
    {
        return Blow(BlowKind.melee, d, d.school);
    }

    ///
    static Blow spell(uint school = 0, bool crit = false)
    {
        return Blow(BlowKind.spell, MeleeDamage.init, school, 1, crit);
    }

    ///
    static Blow periodic(uint school = 0)
    {
        return Blow(BlowKind.periodic, MeleeDamage.init, school);
    }
}

/// See the module documentation.
struct UnitRef
{
    UnitKind kind;
    Character session; /// a player's
    Creature creature;    /// a creature's
    Map map;              /// where it is
    imported!"dmangos.world.replication".Replica replica; /// observed across a node boundary, for proc targets

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

    /// A read-only proc target. The replica supplies identity, position and health.
    static UnitRef observed(typeof(replica) replica, Map map)
    {
        return UnitRef(UnitKind.none, null, null, map, replica);
    }

    /// Whether it is a unit at all.
    bool opCast(B : bool)() const
    {
        return kind != UnitKind.none || replica !is null;
    }

    /// Its guid.
    @property ulong combatGuid() const
    {
        final switch (kind)
        {
        case UnitKind.none: return replica is null ? 0 : replica.guid;
        case UnitKind.player: return session.combatGuid;
        case UnitKind.creature: return creature.guid;
        }
    }

    /// Where it is: what `fighter.position` says, without building a `Fighter`.
    @property imported!"dmangos.world.movement".Position position() const
    {
        final switch (kind)
        {
        case UnitKind.none: return replica is null ? typeof(return).init : replica.position;
        case UnitKind.player: return session.player is null ? typeof(return).init : session.player.position;
        case UnitKind.creature: return creature.position;
        }
    }

    /// Alive: what `fighter.alive` says, without building a `Fighter` (a player's whole stats, its immunities).
    @property bool alive() const
    {
        final switch (kind)
        {
        case UnitKind.none: return replica !is null && health != 0;
        case UnitKind.player: return session.player !is null && session.player.alive;
        case UnitKind.creature: return creature.alive;
        }
    }

    /// What the formulas need of it now.
    Fighter fighter() const
    {
        final switch (kind)
        {
        case UnitKind.none: return replica is null ? Fighter.init : replica.meleeGeometry();
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
        import dmangos.world.auras : maxAuras;
        import dmangos.world.updatefields : UNIT_FIELD_AURA;

        final switch (kind)
        {
        case UnitKind.none:
            if (replica !is null)
                foreach (slot; 0 .. maxAuras)
                    if (replica.fieldsOf.get!UNIT_FIELD_AURA(slot) == spell)
                        return true;
            return false;
        case UnitKind.player: return session.hasAuraOf(spell);
        case UnitKind.creature: return creature.auras.find(spell) !is null;
        }
    }

    /// Its auras and its fields; null if it is not a unit here (a player not in the world).
    @property imported!"dmangos.world.auras".AuraSet* auraSet()
    {
        final switch (kind)
        {
        case UnitKind.none: return null;
        case UnitKind.player: return session.player is null ? null : &session.player.auras;
        case UnitKind.creature: return &creature.auras;
        }
    }

    /// ditto
    @property imported!"dmangos.world.objects".UpdateValues* fields()
    {
        final switch (kind)
        {
        case UnitKind.none: return null;
        case UnitKind.player: return session.player is null ? null : &session.player.values;
        case UnitKind.creature: return &creature.values;
        }
    }

    /// The stacks of its aura of `spell`; 0 if it has none.
    uint auraStacks(uint spell)
    {
        auto set = auraSet;
        auto aura = set is null ? null : set.find(spell);
        return aura is null ? 0 : aura.stacks;
    }

    /// Its mana in percent; uint.max if it has no mana (another power, or none at all).
    uint manaPercent()
    {
        import dmangos.world.updatefields : UNIT_FIELD_BYTES_0, UNIT_FIELD_MAXPOWER1, UNIT_FIELD_POWER1;

        auto v = fields;
        if (v is null || v.getByte!UNIT_FIELD_BYTES_0(3) != 0 || v.get!UNIT_FIELD_MAXPOWER1 == 0)
            return uint.max;
        return cast(uint)(ulong(v.get!UNIT_FIELD_POWER1) * 100 / v.get!UNIT_FIELD_MAXPOWER1);
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

    /// An aura this unit cast on `target` ticked: its effect, done by its caster (`dmangos.world.spellauras.periodicTick`).
    void auraTick(Creature target, Aura aura, size_t effect)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            return session.auraTick(target, aura, effect);
        case UnitKind.creature:
            if (creature.ai is null)
                return;
            auto caster = creature.ai.spellCaster(map);
            imported!"dmangos.world.spellauras".periodicTick(caster, target, aura, effect);
            return;
        }
    }

    /// An aura this unit cast on `target` ended.
    void auraEndedOn(Creature target, Aura aura)
    {
        if (kind == UnitKind.player)
            session.classCreatureAuraLost(target, aura);
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
                creature.loseAura(aura, map);
                map.flushObjectChanges(creature);
            }
            return;
        }
    }

    /// An interrupt (`SPELL_EFFECT_INTERRUPT_CAST`) by `by`: its cast or channel stops if interruptible, its school
    /// locked for `lockMs`.
    void castInterruptedBy(ulong by, int lockMs = 0)
    {
        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player: return session.castInterruptedBy(by, lockMs);
        case UnitKind.creature: return creature.ai.interruptedBySpell(lockMs);
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

    /// Its resistance to school `school` (an index; 0 is armor).
    int resistance(uint school) const
    {
        import dmangos.world.updatefields : UNIT_FIELD_RESISTANCES;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return cast(int) session.character.values.get!UNIT_FIELD_RESISTANCES(school);
        case UnitKind.creature: return cast(int) creature.values.get!UNIT_FIELD_RESISTANCES(school);
        }
    }

    /// Its health now.
    @property uint health() const
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

        final switch (kind)
        {
        case UnitKind.none: return replica is null ? 0 : replica.fieldsOf.get!UNIT_FIELD_HEALTH;
        case UnitKind.player: return session.character.values.get!UNIT_FIELD_HEALTH;
        case UnitKind.creature: return creature.values.get!UNIT_FIELD_HEALTH;
        }
    }

    /// A hostile spell landed on it: a player's auras that end with that go (Sap, Polymorph, Stealth...).
    void hostileSpellLanded()
    {
        import dmangos.world.auras : AuraInterrupt;

        if (kind == UnitKind.player)
            session.interruptAuras(AuraInterrupt.hostileAction);
    }

    /// Its `UNIT_FIELD_FLAGS` (in combat, stunned, ...).
    @property uint unitFlags() const
    {
        import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return session.character.values.get!UNIT_FIELD_FLAGS;
        case UnitKind.creature: return creature.values.get!UNIT_FIELD_FLAGS;
        }
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

/// Use observed fields for a remote unit, including its melee controller's player flags when visible.
package Relating combatRelations(UnitRef unit, const imported!"dmangos.world.clientdata".ClientData client)
{
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : TypeId;

    if (unit.replica is null)
        return unit.relating();
    auto relation = unit.replica.unitRelations(client);
    if (unit.replica.meleeController)
    {
        auto controller = unit.map.unit(relation.controller);
        if (controller.kind == UnitKind.player)
            relation.playerFlags = controller.relating().playerFlags;
        else if (auto owner = cast(Replica) unit.map.findObject(relation.controller))
            if (owner.fields.type == TypeId.player)
                relation.playerFlags = owner.unitRelations(client).playerFlags;
    }
    return relation;
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
        const c = unit.creature;
        const owner = c.petOwner ? c.petOwner : c.totemOwner ? c.totemOwner : c.guardianOwner;
        if (!owner)
            return null;
        return cast(Character) unit.map.find(owner);
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
    // A player's worn items wear a little with the damage it deals and takes (`Unit::DealDamage`).
    if (damage)
    {
        if (attacker.kind == UnitKind.player && attacker != victim)
            attacker.session.wearOnHit();
        if (victim.kind == UnitKind.player)
            victim.session.wearOnHit();
    }
    // What a dodge, a parry or a block lets its victim and its striker do (Revenge, Overpower).
    if (blow.kind == BlowKind.melee)
    {
        import dmangos.world.classspells : swingReactions;

        swingReactions(attacker, victim, blow.melee);
    }
    if (blow.kind == BlowKind.melee && blow.melee.targetState == VictimState.parry)
        final switch (victim.kind)
        {
        case UnitKind.none:
            break;
        case UnitKind.player:
            victim.session.parried();
            break;
        case UnitKind.creature:
            if (victim.creature.ai !is null)
                victim.creature.ai.parried();
            break;
        }
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
        // A player's threat by its auras for the school (`MOD_THREAT`: Defiance, Subtlety).
        float threat = 1;
        if (attacker.kind == UnitKind.player && blow.school < 7)
            if (const p = attacker.session.character)
                threat = p.damageMods.threat[blow.school];
        creature.ai.damageTaken(attacker, damage, threat * blow.threat);
    }
    else if (blow.remotePlayer && creature.ai !is null)
        creature.ai.remoteDamageTaken(blow.remotePlayer, damage, blow.threat, map);
    map.wake(creature.guid);
    if (damage == 0)
        return;
    foreach (aura; brokenByDamage(creature.auras, blow, map.random))
        creature.loseAura(aura, map);
    // A blow of its school uses a charge of what adds to the damage it takes (Hemorrhage: "30 charges"); what any
    // damage ends ends (`AuraInterruptFlags` damage: Wyvern Sting's "Any damage will cancel the effect", Sap).
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.auras : AuraInterrupt, AuraType;

        foreach (aura; creature.auras.interruptedBy(AuraInterrupt.damage))
            if (creature.auras.list.canFind!(a => a is aura))
                creature.loseAura(aura, map);
        foreach (aura; creature.auras.list.dup)
        {
            if (!aura.charges || blow.school >= 7)
                continue;
            bool counts;
            foreach (i; 0 .. 3)
                counts |= (aura.effects & (1 << i)) && aura.type(i) == AuraType.modDamageTaken
                    && (aura.misc(i) & (1 << blow.school));
            if (counts && --aura.charges == 0)
                creature.loseAura(aura, map);
        }
    }
    auto credited = creditedPlayer(attacker);
    if (credited !is null && !creature.petOwner)
        credited.tapCreature(creature);
    const killed = creature.takeDamage(damage);
    map.flushObjectChanges(creature);
    if (!killed)
        return;
    deathItems(creature, map);
    deathProcs(creature, map);
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

/**
 * The auras that `blow`'s damage breaks: a hold whose spell's proc flags take such a blow ("Damage caused may
 * interrupt the effect": Frost Nova, Fear, Psychic Scream, Howl of Terror; their `ProcFlags` the blows taken, their
 * `ProcChance` the chance, with no proc effect of their own), a root, a fear, a stun or a confusion; and a more
 * damage taken that lasts its charges ("until 4 non-periodic damage sources are applied": Improved Shadow Bolt's
 * Shadow Vulnerability), its last spent.
 */
Aura[] brokenByDamage(R)(ref AuraSet auras, const Blow blow, ref R random)
{
    import std.random : uniform01;
    import dmangos.world.aurahandlers : ProcFlag;
    import dmangos.world.auras : AuraType;

    const uint taken = blow.kind == BlowKind.melee ? ProcFlag.takeMeleeSwing | ProcFlag.takeMeleeAbility
        : blow.kind == BlowKind.periodic ? ProcFlag.takeHarmfulPeriodic
        : ProcFlag.takeHarmfulSpell | ProcFlag.takeHarmfulAbility | ProcFlag.takeRangedAbility | ProcFlag.takeRangedAttack;
    Aura[] broken;
    foreach (aura; auras.list)
    {
        const spell = aura.spell;
        if (!(spell.casting.procFlags & taken) || aura.has(AuraType.procTriggerSpell) || aura.has(AuraType.dummy))
            continue;
        if (aura.charges && aura.has(AuraType.modDamagePercentTaken))
        {
            // (a blow of a school it adds to: Stormstrike's "next 2 sources of Nature damage")
            bool ofItsSchool;
            foreach (i; 0 .. 3)
                ofItsSchool |= (aura.effects & (1 << i)) && aura.type(i) == AuraType.modDamagePercentTaken
                    && blow.school < 7 && (aura.misc(i) & (1 << blow.school));
            if (ofItsSchool && --aura.charges == 0)
                broken ~= aura;
            continue;
        }
        if (!aura.has(AuraType.modRoot) && !aura.has(AuraType.modFear) && !aura.has(AuraType.modStun)
                && !aura.has(AuraType.modConfuse))
            continue;
        if (uniform01(random) * 100 < spell.casting.procChance)
            broken ~= aura;
    }
    return broken;
}

/**
 * A creature dies under an aura of a player's that procs on the kill (its proc flags: Drain Soul's Soul Siphon,
 * 18371): the caster's to roll (`Character.deathAuraProc`).
 */
private void deathProcs(Creature creature, Map map)
{
    import dmangos.world.aurahandlers : ProcFlag;
    import dmangos.world.auras : AuraType;

    foreach (aura; creature.auras.list.dup)
        if ((aura.spell.casting.procFlags & ProcFlag.kill) && aura.has(AuraType.procTriggerSpell))
            if (auto caster = cast(Character) map.find(aura.caster))
                if (caster.player !is null && caster.player.alive)
                    caster.deathAuraProc(aura);
}

/**
 * A creature dies under a `SPELL_AURA_CHANNEL_DEATH_ITEM` (Drain Soul, Shadowburn): the caster gets the item
 * (CMaNGOS's `Aura::HandleChannelDeathItem`). A Soul Shard only from a creature that is not grey to the warlock and
 * tapped by it or its group, and one only for several such auras of the warlock on it.
 */
private void deathItems(Creature creature, Map map)
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.experience : grayLevel;
    import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

    enum uint soulShard = 6265;
    bool[ulong] shardGiven;
    foreach (aura; creature.auras.list)
        foreach (i; 0 .. 3)
        {
            if (!(aura.effects & (1 << i)) || aura.type(i) != AuraType.channelDeathItem || aura.amount[i] <= 0)
                continue;
            const item = aura.spell.itemType[i];
            auto caster = cast(Character) map.find(aura.caster);
            if (item == 0 || caster is null || caster.player is null)
                continue;
            if (item == soulShard)
            {
                const level = creature.values.get!UNIT_FIELD_LEVEL;
                auto group = caster.context.groups.of(caster.player.guid);
                if (level <= grayLevel(caster.player.data.level)
                        || !creature.tappedBy(caster.player.guid, group is null ? 0 : group.id)
                        || aura.caster in shardGiven)
                    continue;
                shardGiven[aura.caster] = true;
            }
            caster.giveItem(item, aura.amount[i], true, true);
        }
}
