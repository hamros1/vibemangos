/**
 * Game objects (CMaNGOS `Entities/GameObject.cpp`): `gameobject_template`
 * entries, `gameobject` spawns, and the `GameObject` built from them as
 * `GameObject::Create` builds it. Doors, chests, mailboxes, herbs and veins
 * stand in the world; using them, and loot, come later. Boats and zeppelins
 * (`GAMEOBJECT_TYPE_MO_TRANSPORT`) move along paths and are not spawned yet.
 */
module dmangos.world.gameobject;

import std.math : cos, sin;

import dmangos.world.map : MapObject;
import dmangos.world.movement : Position;
import dmangos.world.objects;
import dmangos.world.updatefields;

/// `GameobjectTypes` the server treats specially.
enum GameObjectType : uint
{
    door = 0,
    button = 1,
    transport = 11,     /// elevators: stand in place, animated by the client
    moTransport = 15,   /// ships and zeppelins
}

/// A `gameobject_template` row.
struct GameObjectTemplate
{
    uint entry;
    uint type;
    uint displayId;
    string name;
    uint faction;
    uint flags;
    float size = 1;
    int[24] data;
}

/// A `gameobject` row: one spawn.
struct GameObjectSpawn
{
    uint guid;
    uint entry;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    float[4] rotation = 0;
    int respawnSeconds;
}

private enum : uint
{
    goStateActive = 0,  // GO_STATE_ACTIVE: open
    goStateReady = 1,   // GO_STATE_READY: closed
    goFlagTransport = 0x08,
    goFlagNoDespawn = 0x20,
}

/// See the module documentation.
final class GameObject : MapObject
{
    immutable ulong guid_;
    const(GameObjectTemplate)* template_;
    const GameObjectSpawn spawn;
    UpdateValues values;

    ///
    this(const ref GameObjectSpawn spawn, const(GameObjectTemplate)* template_)
    in (template_ !is null && template_.entry == spawn.entry)
    {
        this.spawn = spawn;
        this.template_ = template_;
        guid_ = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
        values = UpdateValues(TypeId.gameObject);
        setFields();
        values.clearChanges();
    }

    /// The guid: high part, entry and spawn guid.
    @property ulong guid() const
    {
        return guid_;
    }

    /// See `MapObject.fields`.
    ref UpdateValues fields()
    {
        return values;
    }

    /// Where it stands.
    @property Position position() const
    {
        return Position(spawn.x, spawn.y, spawn.z, spawn.orientation);
    }

    /// `Object::BuildCreateUpdateBlockForPlayer` for a game object: a position, no movement.
    UpdateData appearance(uint serverTime) const
    {
        UpdateData update;
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.hasPosition;
        if (template_.type == GameObjectType.transport)
            block.flags |= UpdateFlags.transport;
        block.position = position;
        block.transportTime = serverTime;
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }

private:
    void setFields()
    {
        alias t = template_;
        values.set!OBJECT_FIELD_GUID(guid_);
        values.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.gameObject);
        values.set!OBJECT_FIELD_ENTRY(t.entry);
        values.set!OBJECT_FIELD_SCALE_X(t.size > 0 ? t.size : 1.0f);
        values.set!GAMEOBJECT_POS_X(spawn.x);
        values.set!GAMEOBJECT_POS_Y(spawn.y);
        values.set!GAMEOBJECT_POS_Z(spawn.z);
        values.set!GAMEOBJECT_FACING(spawn.orientation);
        // UpdateRotationFields: the last two parts from the facing when the spawn has none.
        float[4] rotation = spawn.rotation;
        if (rotation[2] == 0 && rotation[3] == 0)
        {
            rotation[2] = sin(spawn.orientation / 2);
            rotation[3] = cos(spawn.orientation / 2);
        }
        foreach (i, part; rotation)
            values.set!GAMEOBJECT_ROTATION(i, part);
        values.set!GAMEOBJECT_FACTION(t.faction);
        uint flags = t.flags;
        uint state = goStateReady;
        switch (t.type)
        {
        case GameObjectType.door, GameObjectType.button:
            state = t.data[0] ? goStateActive : goStateReady; // startOpen
            break;
        case GameObjectType.transport:
            flags |= goFlagTransport | goFlagNoDespawn;
            values.set!GAMEOBJECT_LEVEL(cast(uint) t.data[1]); // transport.pause
            state = t.data[2] ? goStateActive : goStateReady;  // transport.startOpen
            break;
        default:
            break;
        }
        values.set!GAMEOBJECT_FLAGS(flags);
        values.set!GAMEOBJECT_DISPLAYID(t.displayId);
        values.set!GAMEOBJECT_STATE(state);
        values.set!GAMEOBJECT_TYPE_ID(t.type);
        values.set!GAMEOBJECT_ANIMPROGRESS(100u);
    }
}

unittest
{
    GameObjectTemplate mailbox;
    mailbox.entry = 32349;
    mailbox.type = 19;
    mailbox.displayId = 3851;
    mailbox.name = "Mailbox";
    const spawn = GameObjectSpawn(1001, 32349, 0, -9456, 45, 56, 1.0f);
    auto go = new GameObject(spawn, &mailbox);
    assert(highGuidOf(go.guid) == HighGuid.gameObject && counterOf(go.guid) == 1001);
    assert(go.values[GAMEOBJECT_DISPLAYID] == 3851 && go.values[GAMEOBJECT_STATE] == 1);
    assert(go.values.get!GAMEOBJECT_ROTATION(3) > 0.87f, "cos(0.5): the facing made a rotation");
    assert(go.appearance(0).blockCount == 1);
}
