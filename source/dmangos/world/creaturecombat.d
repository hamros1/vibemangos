/**
 * A creature fought by another creature: a pet and what it fights. Creatures fight players through
 * `Combatant`, which sessions implement; `CreatureCombatant` is a creature seen the same way, so a
 * creature's AI attacks a pet (or a pet a creature) with the code it attacks players with. A blow
 * from a pet taps the creature for the pet's owner; a creature a pet kills is the owner's kill
 * (its experience, loot and quests); a pet killed lies dead for its owner to revive.
 */
module dmangos.world.creaturecombat;

import dmangos.world.auras : Aura, makeAura;
import dmangos.world.combat : Fighter, MeleeDamage;
import dmangos.world.creature : Creature;
import dmangos.world.creatureai : Combatant;
import dmangos.world.map : Map;
import dmangos.world.opcodes : Opcode;
import dmangos.world.relations : Relating;
import dmangos.world.spells : SpellInfo;
import dmangos.script.api : MenuOption, QuestProgress;

/// What a creature's death or a blow means beyond itself: the context implements it.
interface CreatureCombatWorld
{
    /// The combatant of a creature (made once).
    Combatant combatantOf(Creature creature, Map map);

    /// A creature `killer` (a pet) killed `victim`: its owner's kill, or (no owner online) just a death.
    void creatureKilledBy(Creature victim, Creature killer, Map map);

    /// A pet died.
    void petDied(Creature pet, Map map);
}

/// See the module documentation.
final class CreatureCombatant : Combatant
{
    private Creature me;
    private Map map;
    private CreatureCombatWorld world;

    ///
    this(Creature me, Map map, CreatureCombatWorld world)
    {
        this.me = me;
        this.map = map;
        this.world = world;
    }

    /// The creature.
    @property Creature creature()
    {
        return me;
    }

    @property ulong combatGuid() const
    {
        return me.guid;
    }

    Fighter fighter() const
    {
        return me.fighter;
    }

    Relating relating()
    {
        return me.ai.relatingOf;
    }

    /// A blow (a creature's swing, a spell): the creature fights back, takes it, and may die of it.
    void takeHit(ulong attacker, uint damage)
    {
        if (!me.alive)
            return;
        auto from = map.creatureAt(attacker);
        if (from !is null)
        {
            auto other = world.combatantOf(from, map);
            me.ai.attackedBy(other, map);
            me.ai.damageTaken(other, damage);
            // A pet's blow taps the creature for its owner (`SetLootRecipient`).
            if (from.petOwner && !me.lootRecipient && !me.petOwner)
                me.setLootRecipient(from.petOwner, 0);
        }
        map.wake(me.guid);
        if (damage == 0)
            return;
        const killed = me.takeDamage(damage);
        map.flushObjectChanges(me);
        if (!killed)
            return;
        if (me.petOwner)
            return world.petDied(me, map);
        world.creatureKilledBy(me, from, map);
    }

    void meleeHitBy(ulong attacker, const ref MeleeDamage damage)
    {
        takeHit(attacker, damage.damage);
    }

    void threatAdded(ulong creature)
    {
    }

    void threatRemoved(ulong creature)
    {
    }

    void auraTick(Creature target, Aura aura, size_t effect)
    {
    }

    uint healthPercent()
    {
        return me.ai.healthPercent();
    }

    void spellHitBy(ulong caster, uint damage)
    {
        takeHit(caster, damage);
    }

    void auraFrom(ulong caster, const(SpellInfo)* spell, uint casterLevel, int durationMs, const int[3] values)
    {
        bool isNew;
        me.auras.apply(makeAura(spell, caster, casterLevel, durationMs, false, values), me.values, isNew);
        map.flushObjectChanges(me);
    }

    bool hasAuraOf(uint spell)
    {
        return me.auras.find(spell) !is null;
    }

    void tell(Opcode opcode, const(ubyte)[] body_)
    {
    }

    @property bool castingSpell()
    {
        return me.ai.castingNow;
    }

    void questEventHappened(uint quest)
    {
    }

    void killCreditFrom(uint entry, ulong creature)
    {
    }

    void auraRemovedBy(uint spell)
    {
        if (auto aura = me.auras.find(spell))
        {
            me.auras.remove(aura, me.values);
            map.flushObjectChanges(me);
        }
    }

    @property bool untouchable()
    {
        return false;
    }

    void castInterruptedBy(ulong creature)
    {
        me.ai.interruptCast();
    }

    void questFailedBy(uint quest)
    {
    }

    void showGossip(ulong npc, uint menu)
    {
    }

    void closeGossip()
    {
    }

    QuestProgress questStatusOf(uint quest)
    {
        return QuestProgress.none;
    }

    void showScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests)
    {
    }
}
