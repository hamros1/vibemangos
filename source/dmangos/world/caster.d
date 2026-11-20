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
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

/// See the module documentation.
struct Caster
{
    UnitKind kind;
    Character character; /// a player's
    CreatureAI ai;       /// a creature's (a pet's, a totem's)
    Creature creature;   /// ... and the creature
    Map map;             /// where it casts
    WorldContext context;

    /// The player of `character`, on its map; none if it is not in the world.
    static Caster of(Character character)
    {
        if (character is null || character.player is null)
            return Caster.init;
        return Caster(UnitKind.player, character, null, null, character.currentMap, character.context);
    }

    /// `creature`, its AI casting, on `map`, in `context`.
    static Caster of(Creature creature, Map map, WorldContext context)
    {
        if (creature is null || creature.ai is null || map is null)
            return Caster.init;
        return Caster(UnitKind.creature, null, creature.ai, creature, map, context);
    }

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

    /// It as a unit.
    @property UnitRef unit()
    {
        final switch (kind)
        {
        case UnitKind.none: return UnitRef.init;
        case UnitKind.player: return character.unit;
        case UnitKind.creature: return UnitRef.of(creature, map);
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
