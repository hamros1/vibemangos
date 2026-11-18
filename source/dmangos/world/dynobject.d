/**
 * Dynamic objects: the spot a persistent area aura covers
 * (Blizzard, Consecration, Rain of Fire), seen by the clients as the spell's effect on the ground.
 * The caster's session ticks it (`dmangos.world.spellhandlers`); here is what the clients see of it.
 */
module dmangos.world.dynobject;

import dmangos.world.map : MapObject;
import dmangos.world.movement : Position;
import dmangos.world.objects;
import dmangos.world.updatefields;

/// See the module documentation.
final class DynamicObject : MapObject
{
    immutable ulong guid_;
    Position at;
    UpdateValues values;

    /// `spell`'s spot of `radius` yards at `at`, cast by `caster`.
    this(uint counter, ulong caster, uint spell, size_t effect, float radius, Position at)
    {
        guid_ = makeGuid(HighGuid.dynamicObject, counter);
        this.at = at;
        values = UpdateValues(TypeId.dynamicObject);
        values.set!OBJECT_FIELD_GUID(guid_);
        values.set!OBJECT_FIELD_ENTRY(spell);
        values.set!OBJECT_FIELD_SCALE_X(1.0f);
        values.set!DYNAMICOBJECT_CASTER(caster);
        values.setByte!DYNAMICOBJECT_BYTES(0, cast(ubyte)(1 << effect)); // which effect
        values.set!DYNAMICOBJECT_SPELLID(spell);
        values.set!DYNAMICOBJECT_RADIUS(radius);
        values.set!DYNAMICOBJECT_POS_X(at.x);
        values.set!DYNAMICOBJECT_POS_Y(at.y);
        values.set!DYNAMICOBJECT_POS_Z(at.z);
        values.set!DYNAMICOBJECT_FACING(at.orientation);
        values.clearChanges();
    }

    /// Its guid.
    @property ulong guid() const
    {
        return guid_;
    }

    /// Where it lies.
    @property Position position() const
    {
        return at;
    }

    /// Its fields.
    ref UpdateValues fields()
    {
        return values;
    }

    /// Its create block: a position and its fields (`UPDATEFLAG_ALL | UPDATEFLAG_HAS_POSITION`).
    UpdateData appearance(uint serverTime) const
    {
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.hasPosition;
        block.position = at;
        UpdateData update;
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }
}

unittest
{
    auto spot = new DynamicObject(5, 7, 10, 0, 8, Position(1, 2, 3, 0));
    assert(highGuidOf(spot.guid) == HighGuid.dynamicObject && spot.values.get!DYNAMICOBJECT_SPELLID == 10);
    assert(spot.values.get!DYNAMICOBJECT_RADIUS == 8 && spot.appearance(0).blockCount == 1);
}
