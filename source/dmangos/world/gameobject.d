/**
 * Game objects (CMaNGOS `Entities/GameObject.cpp`): `gameobject_template`
 * entries, `gameobject` spawns, and the `GameObject` built from them as
 * `GameObject::Create` builds it, with its loot state (`GameObject::Update`):
 * a door or button used opens and closes again after its time; a goober is in
 * use for its time; a chest opened holds its loot until emptied (or 5 minutes);
 * a consumable chest or goober, and a generic object used, goes once done and
 * comes back after its spawn's respawn time. What using them does is
 * `dmangos.world.gameobjecthandlers`. Boats and zeppelins
 * (`GAMEOBJECT_TYPE_MO_TRANSPORT`) move along paths and are not spawned yet.
 */
module dmangos.world.gameobject;

import std.math : cos, sin;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.loot : Loot;
import dmangos.world.map : MapObject, Moving, PerViewer;
import dmangos.world.motion : MotionWorld;
import dmangos.world.replication : Replicable;
import dmangos.world.movement : Position;
import dmangos.world.objects;
import dmangos.world.updatefields;

/// `GameobjectTypes` the server treats specially.
enum GameObjectType : uint
{
    door = 0,
    button = 1,
    questGiver = 2,
    chest = 3,          /// herbs and veins too
    binder = 4,
    generic = 5,
    trap = 6,
    chair = 7,
    spellFocus = 8,
    text = 9,
    goober = 10,
    transport = 11,     /// elevators: stand in place, animated by the client
    camera = 13,
    moTransport = 15,   /// ships and zeppelins
    fishingNode = 17,   /// the bobber
    mailbox = 19,
    flagStand = 24,     /// a battleground's flag at its base
    fishingHole = 25,   /// a school of fish: a catch near it comes from it
    flagDrop = 26,      /// a battleground's flag on the ground
}

/// `LootState` of a game object.
enum GoLootState : ubyte
{
    notReady,
    ready,              /// as spawned
    activated,          /// in use: open, looted from
    justDeactivated,    /// done: back to ready, or gone
}

/// What a game object needs of its map while it acts (the map implements it).
interface GameObjectWorld
{
    /// Sends what changed in its fields to those who see it.
    void flushGameObject(GameObject go);

    /// It is used up: it goes, and comes back when its spawn's respawn time is up.
    void gameObjectUsedUp(GameObject go);
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

/// `GOState`, `GameObjectFlags`, `GameObjectDynamicLowFlags`
enum : uint
{
    goStateActive = 0,  // GO_STATE_ACTIVE: open
    goStateReady = 1,   // GO_STATE_READY: closed
    goFlagInUse = 0x01,
    goDynFlagActivate = 0x01, // GO_DYNFLAG_LO_ACTIVATE: usable (for a quest), and it sparkles
    goFlagTransport = 0x08,
    goFlagNoDespawn = 0x20,
}

/// See the module documentation.
import dmangos.script.registry : ScriptHandle, ScriptRuntime;

final class GameObject : Replicable, Moving, PerViewer
{
    immutable ulong guid_;
    const(GameObjectTemplate)* template_;
    const GameObjectSpawn spawn;
    UpdateValues values;
    GoLootState lootState = GoLootState.ready;
    Loot loot;                   /// what it holds while open (a chest)
    int restoreTimer;            /// ms until a door or button goes back, or a goober is done
    uint instanceId;             /// the dungeon instance it is in (0: none): used up there, it stays so
    long trapReadyAt;            /// a trap's cooldown: it springs again from then (Unix time)
    ulong owner;                 /// who made it (a fishing bobber's angler); 0: a spawn
    uint holeCatches;            /// a fishing hole's catches so far, against `holeMaxCatches`
    uint holeMaxCatches;         /// ... chosen between its least and greatest when first fished
    uint trapUses;               /// a trap's springs so far, against its charges
    int despawnTimer;            /// ms until a chest opened but not emptied goes (`SetChestDespawn`); 0: none
    bool[ulong] skilledUp;       /// those it gave a skill-up (`m_SkillupList`): once until it respawns
    /// Whether it is usable for `viewer`'s quests (`ActivateToQuest`); null: for nobody.
    bool delegate(ulong viewer) activatesFor;

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

    /// `GetGoType`
    @property GameObjectType type() const
    {
        return cast(GameObjectType) template_.type;
    }

    /// `GetGoState`
    @property uint goState() const
    {
        return values.get!GAMEOBJECT_STATE;
    }

    /// `GameObjectInfo::GetLockId`: the `Lock.dbc` entry opening it needs; 0 for none.
    @property uint lockId() const
    {
        switch (type)
        {
        case GameObjectType.door, GameObjectType.button:
            return template_.data[1];
        case GameObjectType.questGiver, GameObjectType.chest, GameObjectType.trap, GameObjectType.goober:
            return template_.data[0];
        default:
            return 0;
        }
    }

    /// `GetLootId`: its `gameobject_loot_template` id (a chest's).
    @property uint lootId() const
    {
        return type == GameObjectType.chest || type == GameObjectType.fishingHole ? template_.data[1] : 0;
    }

    /// `GetAutoCloseTime`, in milliseconds (the template's value is seconds times 0x10000).
    @property int autoCloseMs() const
    {
        int raw;
        switch (type)
        {
        case GameObjectType.door, GameObjectType.button:
            raw = template_.data[2];
            break;
        case GameObjectType.goober:
            raw = template_.data[3];
            break;
        default:
            return 0;
        }
        return cast(int)(cast(long) cast(uint) raw * 1000 / 0x10000);
    }

    /// `IsDespawnAtAction`: a consumable chest or goober goes once used.
    @property bool consumable() const
    {
        return (type == GameObjectType.chest && template_.data[3]) || (type == GameObjectType.goober && template_.data[5]);
    }

    /// `UseDoorOrButton`: open (or closed) for its time, if it is not in use already.
    void useDoorOrButton(GameObjectWorld world, uint restoreMs = 0)
    {
        if (lootState != GoLootState.ready)
            return;
        switchDoorOrButton(true);
        lootState = GoLootState.activated;
        restoreTimer = restoreMs ? restoreMs : autoCloseMs;
        world.flushGameObject(this);
    }

    /// A door a script opens or closes for good (`DoUseDoorOrButton` with no reset): no timer brings it back.
    void setDoorOpen(bool open)
    {
        values.set!GAMEOBJECT_STATE(open ? goStateActive : goStateReady);
    }

    /// `UseOpenableObject`: opened (or closed) for `restoreMs`, unless it is so already.
    void useOpenable(GameObjectWorld world, bool open, uint restoreMs)
    {
        if (goState == (open ? goStateActive : goStateReady))
            return;
        useDoorOrButton(world, restoreMs);
    }

    /// `SwitchDoorOrButton`: the in-use flag, and the state the other way.
    private void switchDoorOrButton(bool activate)
    {
        const flags = values.get!GAMEOBJECT_FLAGS;
        values.set!GAMEOBJECT_FLAGS(activate ? flags | goFlagInUse : flags & ~goFlagInUse);
        values.set!GAMEOBJECT_STATE(goState == goStateReady ? goStateActive : goStateReady);
    }

    /// The goober used (`GAMEOBJECT_TYPE_GOOBER` in `Use`): in use and open for its time.
    void activateGoober(GameObjectWorld world)
    {
        values.set!GAMEOBJECT_FLAGS(values.get!GAMEOBJECT_FLAGS | goFlagInUse);
        lootState = GoLootState.activated;
        values.set!GAMEOBJECT_STATE(goStateActive);
        restoreTimer = autoCloseMs;
        world.flushGameObject(this);
    }

    /// See `Moving.tick`: `GameObject::Update`'s loot states.
    void tick(MotionWorld w, int diff)
    {
        auto world = cast(GameObjectWorld) w;
        if (world is null)
            return;
        final switch (lootState)
        {
        case GoLootState.notReady, GoLootState.ready:
            return;
        case GoLootState.activated:
            switch (type)
            {
            case GameObjectType.door, GameObjectType.button:
                if (restoreTimer > 0 && (restoreTimer -= diff) <= 0) // its time, or a script's
                {
                    // `ResetDoorOrButton`
                    switchDoorOrButton(false);
                    lootState = GoLootState.justDeactivated;
                }
                break;
            case GameObjectType.goober:
                if ((restoreTimer -= diff) <= 0)
                {
                    values.set!GAMEOBJECT_FLAGS(values.get!GAMEOBJECT_FLAGS & ~goFlagInUse);
                    lootState = GoLootState.justDeactivated;
                }
                break;
            case GameObjectType.chest:
                if (loot !is null)
                {
                    loot.update();
                    if (despawnTimer && (despawnTimer -= diff) <= 0)
                        lootState = GoLootState.justDeactivated;
                }
                break;
            default:
                break;
            }
            if (lootState == GoLootState.activated)
                return;
            break;
        case GoLootState.justDeactivated:
            break;
        }
        // `GO_JUST_DEACTIVATED`: ready again; the consumable (and the generic used) go for their respawn time.
        if (type == GameObjectType.goober)
            values.set!GAMEOBJECT_STATE(goStateReady);
        loot = null;
        despawnTimer = 0;
        lootState = GoLootState.ready;
        world.flushGameObject(this);
        if (consumable || type == GameObjectType.generic)
            world.gameObjectUsedUp(this);
    }

    /// A trap's activation radius (`trap.diameter` / 2; the hunters' traps, lock 12, use it whole); 0: none.
    @property float trapRadius() const
    {
        if (type != GameObjectType.trap)
            return 0;
        return template_.data[0] == 12 ? template_.data[2] : template_.data[2] / 2.0f;
    }

    /// See `Moving.resting`: nothing pending (a door that stays open waits for nothing either).
    @property bool resting() const
    {
        if (lootState == GoLootState.activated)
            return (type == GameObjectType.door || type == GameObjectType.button) && restoreTimer <= 0;
        return lootState == GoLootState.ready || lootState == GoLootState.notReady;
    }

    /// See `PerViewer`: whether some viewer may see a quest's sparkle on it.
    bool personalized() const
    {
        return activatesFor !is null;
    }

    /// ditto
    const(size_t)[] personalSlots() const
    {
        static immutable size_t[1] slots = [GAMEOBJECT_DYN_FLAGS];
        return slots[];
    }

    /// ditto: `GAMEOBJECT_DYN_FLAGS` with `GO_DYNFLAG_LO_ACTIVATE` for one whose quest needs it.
    uint fieldFor(ulong viewer, uint viewerGroup, size_t slot, uint value) const
    {
        if (slot == GAMEOBJECT_DYN_FLAGS && activatesFor !is null && activatesFor(viewer))
            return value | goDynFlagActivate;
        return value;
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
        const block = motion(serverTime);
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }

    /// Its fields, for its next owner (docs/CLUSTER.md, phase 4).
    void saveState(ref ByteWriter w) const
    {
        w.put(cast(ushort) values.length);
        foreach (slot; 0 .. values.length)
            w.put(values[slot]);
        // Its script's state (docs/SCRIPTING.md).
        ByteWriter state;
        if (scripts !is null)
            (cast() scripts).save(behaviour, state);
        w.put(cast(uint) state.length);
        w.putBytes(state.data);
    }

    /// The server's scripts, and its own script's state; no handle if it has none.
    ScriptRuntime scripts;
    /// ditto
    ScriptHandle behaviour;

    /// Reads what `saveState` wrote into one made anew from the same spawn.
    void loadState(ref ByteReader r)
    {
        const count = r.read!ushort;
        foreach (slot; 0 .. count)
        {
            const value = r.read!uint;
            if (slot < values.length)
                values.setSlot(slot, value);
        }
        values.clearChanges();
        auto state = ByteReader(r.readBytes(r.read!uint));
        if (scripts !is null && state.remaining)
            scripts.load(behaviour, state);
    }

    /// See `Replicable.motion`: a position, and an elevator's path time.
    MovementBlock motion(uint serverTime) const
    {
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.hasPosition;
        if (template_.type == GameObjectType.transport)
            block.flags |= UpdateFlags.transport;
        block.position = position;
        block.transportTime = serverTime;
        return block;
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
