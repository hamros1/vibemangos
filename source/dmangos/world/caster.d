/**
 * Who casts a spell: a player, or a creature (a pet and a totem are creatures), as one value the spell pipeline is
 * written over (docs/SPELLS.md).
 *
 * A `Caster` is to a spell what a `UnitRef` is to a blow: a small value naming the caster, its map and the world,
 * made where a cast needs it and never kept. What every caster has (its guid, level, place, fields, auras, how the
 * relations see it) is read the same way whatever its kind; what differs by kind is a method with a `final switch`,
 * so a kind added does not compile until each says what it does. There are no virtual interfaces.
 */
module dmangos.world.caster;

import dmangos.world.auras : AuraSet;
import dmangos.world.character : Character;
import dmangos.world.combat : Fighter;
import dmangos.world.context : WorldContext;
import dmangos.world.creature : Creature;
import dmangos.world.creatureai : CreatureAI;
import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.objects : UpdateValues;
import dmangos.world.opcodes : Opcode;
import dmangos.world.relations : Relating;
import dmangos.world.spellids : DamageClass;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

/// See the module documentation.
struct Caster
{
    /// The unit casting: a player, or a creature (with its map).
    UnitRef unit;
    WorldContext context;

    /// The player of `character`, on its map; none if it is not in the world.
    static Caster of(Character character)
    {
        if (character is null || character.player is null)
            return Caster.init;
        return Caster(UnitRef.of(character), character.context);
    }

    /// `creature`, its AI casting, on `map`, in `context`.
    static Caster of(Creature creature, Map map, WorldContext context)
    {
        if (creature is null || creature.ai is null || map is null)
            return Caster.init;
        return Caster(UnitRef.of(creature, map), context);
    }

    /// What kind of unit it is, and that unit as a player, a creature or its AI (null for the other kind); its map.
    @property UnitKind kind() const { return unit.kind; }
    @property inout(Character) character() inout { return unit.session; } /// ditto
    @property inout(Creature) creature() inout { return unit.creature; } /// ditto
    @property CreatureAI ai() { return unit.creature is null ? null : unit.creature.ai; } /// ditto
    @property inout(Map) map() inout { return unit.map; } /// ditto

    /// Whether it is a caster at all.
    bool opCast(B : bool)() const
    {
        return kind != UnitKind.none;
    }

    /// Its guid.
    @property ulong guid() const
    {
        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.player.guid;
        case UnitKind.creature: return creature.guid;
        }
    }

    /// Its level.
    @property uint level() const
    {
        import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.player.data.level;
        case UnitKind.creature: return creature.values.get!UNIT_FIELD_LEVEL;
        }
    }

    /// Where it is.
    @property Position position() const
    {
        final switch (kind)
        {
        case UnitKind.none: return Position.init;
        case UnitKind.player: return character.player.position;
        case UnitKind.creature: return creature.position;
        }
    }

    /// Its fields.
    @property UpdateValues* fields()
    {
        final switch (kind)
        {
        case UnitKind.none: return null;
        case UnitKind.player: return &character.player.values;
        case UnitKind.creature: return &creature.values;
        }
    }

    /// Its auras.
    @property AuraSet* auras()
    {
        final switch (kind)
        {
        case UnitKind.none: return null;
        case UnitKind.player: return &character.player.auras;
        case UnitKind.creature: return &creature.auras;
        }
    }

    /// Alive.
    @property bool alive() const
    {
        final switch (kind)
        {
        case UnitKind.none: return false;
        case UnitKind.player: return character.player.alive;
        case UnitKind.creature: return creature.alive;
        }
    }

    /// What the formulas need of it now.
    Fighter fighter()
    {
        final switch (kind)
        {
        case UnitKind.none: return Fighter.init;
        case UnitKind.player: return character.player.fighter;
        case UnitKind.creature: return creature.fighter;
        }
    }

    /// How the relations see it now.
    Relating relating()
    {
        final switch (kind)
        {
        case UnitKind.none: return Relating.init;
        case UnitKind.player: return character.relatingNow();
        case UnitKind.creature: return ai.relatingOf();
        }
    }

    /// Whether it may attack `other` (a spell at it is hostile, rolls to hit, is a debuff).
    bool hostileTo(UnitRef other)
    {
        import dmangos.world.relations : canAttack;

        return other && other.combatGuid != guid && canAttack(relating, other.relating, context.client);
    }

    /// A packet for those who see it (a player's own client too).
    void sendAround(Opcode opcode, const(ubyte)[] body_)
    {
        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player: return map.sendToWatchers(character, opcode, body_, true);
        case UnitKind.creature: return map.sendToObservers(creature.guid, opcode, body_);
        }
    }

    /// What changed in its fields, to those who see it.
    void flush()
    {
        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player: return character.flushPlayerChanges();
        case UnitKind.creature: return map.flushCreature(creature);
        }
    }

    /// It casts `spell` at `target` as a triggered spell (no cost, no cast time): a trigger effect's, a proc's.
    void castTriggered(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.eventai : castTriggered;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player:
            character.castSpell(spell, SpellTargets(target ? TargetFlags.unit : TargetFlags.self,
                target ? target : character.player.guid), true, 0);
            return;
        case UnitKind.creature:
            ai.castSpell(spell, target, castTriggered);
            return;
        }
    }

    // -----------------------------------------------------------------------
    // The numbers its spells get
    // -----------------------------------------------------------------------

    /// Its modifier `op` of `spell` on `value` (`SPELLMOD_*`): a player's talents, a pet's or a totem's owner's
    /// (Improved Imp, Call of Flame); none for any other creature.
    T spellMod(T)(imported!"dmangos.world.spellmods".SpellModOp op, const(SpellInfo)* spell, T value)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return value;
        case UnitKind.player:
            return character.spellMod(op, spell, value);
        case UnitKind.creature:
            auto owner = modOwner();
            if (owner is null)
                return value;
            return creature.petOwner ? owner.petSpellMod(op, spell, value, creature) : owner.spellMod(op, spell, value);
        }
    }

    /// What `spell`'s threat (its damage's, its heal's) is times: its threat modifiers (`SPELLMOD_THREAT`: Shadow
    /// Affinity) and its `spell_threat` multiplier (Mind Blast's double: CMaNGOS's `GetSpellThreatMultiplier`).
    float threatFactor(const(SpellInfo)* spell)
    {
        import dmangos.world.spellmods : SpellModOp;

        import dmangos.world.creatureai : spellAttrExNoThreat;

        // A spell that angers no one (`SPELL_ATTR_EX_NO_THREAT`: Twin Empathy, Elune's Candle): its damage none either
        // (CMaNGOS's `HandleDamageDealt`).
        if (spell.attributesEx & spellAttrExNoThreat)
            return 0;
        return spellMod(SpellModOp.threat, spell, 1.0f) * spell.casting.threatMultiplier;
    }

    /// Its spell power for spells of the schools in `schoolMask` (`SpellBaseDamageBonusDone`): its `MOD_DAMAGE_DONE`
    /// auras (a player's spirit's share too).
    int spellPower(uint schoolMask)
    {
        import dmangos.world.auras : AuraType;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.spellPower(schoolMask);
        case UnitKind.creature: return creature.auras.totalByMiscMask(AuraType.modDamageDone, cast(int) schoolMask);
        }
    }

    /// Its healing power: its `MOD_HEALING_DONE` auras (a player's spirit's share too).
    int healingPower()
    {
        import dmangos.world.auras : AuraType;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.healingPower();
        case UnitKind.creature: return creature.auras.total(AuraType.modHealingDone);
        }
    }

    /**
     * `damage` of `school` with what auras make of it: its own for the school and the victim's creature type
     * (`MOD_DAMAGE_PERCENT_DONE`, `MOD_DAMAGE_DONE_VERSUS`), the victim's for the school (`MOD_DAMAGE_TAKEN`,
     * `MOD_DAMAGE_PERCENT_TAKEN`).
     */
    uint damageFactors(uint damage, uint school, const ref Fighter victim)
    {
        import dmangos.world.auras : AuraType;

        if (school >= 7)
            return damage;
        // Its flat bonus against the victim's creature type first (`MOD_FLAT_SPELL_DAMAGE_VERSUS`: the Holy
        // Mightstone's, `MOD_DAMAGE_DONE_CREATURE`), as CMaNGOS's `SpellDamageBonusDone` adds it before the percents.
        if (const all = auras)
            if (victim.creatureType > 0 && victim.creatureType <= 31)
            {
                const typeMask = 1 << (victim.creatureType - 1);
                const versus = all.totalByMiscMask(AuraType.modFlatSpellDamageVersus, typeMask)
                    + all.totalByMiscMask(AuraType.modDamageDoneCreature, typeMask);
                damage = versus < 0 && -versus >= damage ? 0 : cast(uint)(damage + versus);
            }
        final switch (kind)
        {
        case UnitKind.none:
            return damage;
        case UnitKind.player:
            return character.spellDamageFactors(damage, school, victim.creatureType, victim.damageTaken,
                victim.damageTakenFlat);
        case UnitKind.creature:
            const done = creature.auras.list.length
                ? creature.auras.multiplier(AuraType.modDamagePercentDone, (int mask) => (mask & (1 << school)) != 0, -1) : 1;
            const total = (damage * done + victim.damageTakenFlat[school]) * victim.damageTaken[school];
            return total > 0 ? cast(uint) total : 0;
        }
    }

    /**
     * The crit chance of its spell `spell` (no victim's part): a player's from its intellect, class and level; a
     * creature's 5% (CMaNGOS's `Unit::GetCritChance`: "base crit chance, needed for units only"); and what their
     * auras add, to every spell and to its school's, and the spell's modifiers.
     */
    float spellCritChance(const(SpellInfo)* spell)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.spellmods : SpellModOp;

        final switch (kind)
        {
        case UnitKind.none:
            return 0;
        case UnitKind.player:
            return character.spellCritOf(spell);
        case UnitKind.creature:
            enum float creatureBase = 5;
            return creatureBase + spellMod(SpellModOp.critChance, spell, 0) + creature.auras.total(AuraType.modSpellCritChance)
                + creature.auras.totalByMiscMask(AuraType.modSpellCritChanceSchool, 1 << spell.casting.school);
        }
    }

    /// The crit chance of `spell` at `victim`: a melee or ranged ability's is its weapon's, a spell's the spell crit
    /// (`spellCritChance`); a player's class rules add theirs (Shatter).
    float critChance(const(SpellInfo)* spell, UnitRef victim)
    {
        import dmangos.world.combat : AttackType, meleeCritChance = critChance;
        import dmangos.world.spellmods : SpellModOp;

        final switch (kind)
        {
        case UnitKind.none:
            return 0;
        case UnitKind.player:
            return character.critChanceOf(spell, victim);
        case UnitKind.creature:
            if (victim && weaponCrit(spell))
                return meleeCritChance(creature.fighter, victim.fighter, spell.casting.dmgClass == DamageClass.ranged
                    ? AttackType.ranged : AttackType.mainHand) + spellMod(SpellModOp.critChance, spell, 0);
            return spellCritChance(spell);
        }
    }

    /// Whether `spell` is a melee or ranged ability: it crits as its weapon does, for double.
    static bool weaponCrit(const(SpellInfo)* spell) pure nothrow @nogc @safe
    {
        return spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged;
    }

    /**
     * A crit's damage (CMaNGOS's `GetCritMultiplier`): double for a melee or ranged ability, half again for a spell,
     * times what `MOD_CRIT_PERCENT_VERSUS` adds against `victimType` (the Slaying talents); the bonus over the damage
     * more by the spell's modifiers (`SPELLMOD_CRIT_DAMAGE_BONUS`: Ice Shards, Ruin double a spell's half).
     */
    uint critDamage(const(SpellInfo)* spell, uint damage, uint victimType = 0)
    {
        import dmangos.world.combat : creatureTypes;
        import dmangos.world.spellmods : SpellModOp;

        const versus = victimType && victimType < creatureTypes ? fighter.critVersus[victimType] : 0;
        const multiplier = (weaponCrit(spell) ? 2.0f : 1.5f) * (1 + versus / 100);
        const bonus = versus ? cast(uint)(damage * (multiplier - 1)) : weaponCrit(spell) ? damage : damage / 2;
        return damage + spellMod(SpellModOp.critDamageBonus, spell, bonus);
    }

    /// A target's resistance to `school` as its spells meet it: less by its `MOD_TARGET_RESISTANCE` (negative
    /// amounts: Arcane Subtlety), never below none.
    int targetResistance(int resistance, uint school)
    {
        import dmangos.world.auras : AuraType;

        const reduced = resistance + (school < 7 ? auras.totalByMiscMask(AuraType.modTargetResistance, 1 << school) : 0);
        return reduced > 0 ? reduced : 0;
    }

    /// Percent less often its spells miss: its `MOD_SPELL_HIT_CHANCE` auras and the spell's modifiers
    /// (`SPELLMOD_RESIST_MISS_CHANCE`: Arcane Focus).
    float hitBonus(const(SpellInfo)* spell)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.spellmods : SpellModOp;

        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.spellHitBonusOf(spell);
        case UnitKind.creature: return creature.auras.total(AuraType.modSpellHitChance) + spellMod(SpellModOp.resistMissChance, spell, 0);
        }
    }

    /// It dealt `damage` with a spell: it is in combat (a player for a while; a creature's pursuit restarts).
    void enteredCombat(uint damage)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            return character.enterCombatFor(character.combatLinger);
        case UnitKind.creature:
            if (damage)
                ai.triggerCombatTimer();
            return;
        }
    }

    /**
     * Its spell `spell` hurt `victim` for `damage` (`periodic`: a tick): its procs and the victim's (a player's proc
     * engine; a pet's, `dmangos.world.creatureprocs`); a creature's script hears of a kill.
     */
    void damageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, bool periodic)
    {
        final switch (kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            if (!victim.alive)
                return;
            if (periodic)
                character.tickProcs(victim, spell, damage);
            else
                character.spellHitProcs(spell, victim, crit, damage);
            return;
        case UnitKind.creature:
            return ai.spellDamageDealt(spell, victim, crit, damage);
        }
    }

    /**
     * The amount of effect `i` of `spell` as it casts it (`SpellCast` its cast's): a player's rolled (or its cast's
     * own) with its combo points and modifiers; a creature's rolled at its level and scaled by it, a pet's or a
     * totem's with its owner's talents.
     */
    int effectAmount(const(SpellInfo)* spell, size_t i)
    {
        final switch (kind)
        {
        case UnitKind.none: return 0;
        case UnitKind.player: return character.effectAmount(spell, i);
        case UnitKind.creature: return ai.effectAmount(spell, i);
        }
    }

    /// `ms` of `spell`'s duration as its modifiers make it (`SPELLMOD_DURATION`: a player's talents, a finisher's
    /// combo points; a pet's or a totem's owner's: Improved Succubus).
    int modDuration(const(SpellInfo)* spell, int ms)
    {
        import dmangos.world.spellmods : SpellModOp;

        final switch (kind)
        {
        case UnitKind.none: return ms;
        case UnitKind.player: return character.modDuration(spell, ms);
        case UnitKind.creature: return ms > 0 ? spellMod(SpellModOp.duration, spell, ms) : ms;
        }
    }

    /// A log about `target` (it or another unit) for everyone who sees `target`, and for a player caster itself.
    void tellAround(ulong target, Opcode opcode, const(ubyte)[] body_)
    {
        final switch (kind)
        {
        case UnitKind.none: return;
        case UnitKind.player: return character.tellAround(target, opcode, body_);
        case UnitKind.creature: return map.sendToObservers(target, opcode, body_);
        }
    }

    /// Its power type (`UNIT_FIELD_BYTES_0`'s fourth byte: mana, rage, focus, energy).
    @property ubyte powerType()
    {
        import dmangos.world.updatefields : UNIT_FIELD_BYTES_0;

        return kind == UnitKind.none ? 0 : fields.getByte!UNIT_FIELD_BYTES_0(3);
    }

    /**
     * The player whose talents change its spells (CMaNGOS's `GetSpellModOwner`): a player itself, a pet's or a
     * totem's owner in the world here; null for any other creature.
     */
    Character modOwner()
    {
        final switch (kind)
        {
        case UnitKind.none:
            return null;
        case UnitKind.player:
            return character;
        case UnitKind.creature:
            const owner = creature.petOwner ? creature.petOwner : creature.totemOwner;
            if (!owner)
                return null;
            auto unit = map.unit(owner);
            return unit.kind == UnitKind.player && unit.session.player !is null ? unit.session : null;
        }
    }
}
