/**
 * A dead player's body: where the player died, looking like it,
 * until the ghost reclaims it or is resurrected elsewhere. It is saved in `corpse` while it lasts,
 * so a ghost that logs out finds it again.
 *
 * A corpse's guid is its player's, not counted on its own: a player has at most one corpse, and
 * the guid needs no counter of its own across a cluster.
 */
module dmangos.world.corpse;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.movement : Position;
import dmangos.world.objects;
import dmangos.world.player : Player, PlayerFlags;
import dmangos.world.replication : Replicable;
import dmangos.world.updatefields;

/// What a corpse is: bones, or a body to come back to (from a death in PvE or PvP).
enum CorpseType : ubyte
{
    bones,
    resurrectablePve,
    resurrectablePvp,
}


/// `CORPSE_FIELD_FLAGS`
enum CorpseFlags : uint { bones = 0x01, pvp = 0x04, lootable = 0x20 }

/// `CORPSE_FIELD_DYNAMIC_FLAGS`: its loot may be taken (bones whose insignia was removed).
enum uint corpseDynLootable = 0x01;

/// How long bones lie before they go (CMaNGOS's `Corpse::IsExpired`), in seconds.
enum long bonesLifetime = 60 * 60;

/// How near its corpse a ghost must be to come back to life there.
enum float corpseReclaimRadius = 39;

/// See the module documentation.
final class Corpse : Replicable
{
    immutable ulong guid_;
    immutable uint owner;          /// the player's low guid
    immutable uint map;
    uint instanceId;               /// the dungeon instance it lies in (0: none; not saved)
    Position at;
    CorpseType type;
    long ghostTime;                /// when the player released its spirit (Unix time); bones: when they were left
    UpdateValues values;
    import dmangos.world.loot : Loot;
    Loot loot;                     /// bones whose insignia was removed: what the remover may take

    /**
     * The bones a body leaves (CMaNGOS's `ConvertCorpseForPlayer`): its fields, bare of what it wore, with the
     * bones flag; `guid` its own (the body's goes with it).
     */
    this(const Corpse body_, ulong guid, long now)
    {
        guid_ = guid;
        owner = body_.owner;
        map = body_.map;
        instanceId = body_.instanceId;
        at = body_.at;
        type = CorpseType.bones;
        ghostTime = now;
        values = UpdateValues(TypeId.corpse);
        const v = &body_.values;
        values.set!OBJECT_FIELD_GUID(guid);
        values.set!OBJECT_FIELD_SCALE_X(1.0f);
        values.set!CORPSE_FIELD_OWNER(v.get!CORPSE_FIELD_OWNER);
        values.set!CORPSE_FIELD_FACING(v.get!CORPSE_FIELD_FACING);
        values.set!CORPSE_FIELD_POS_X(v.get!CORPSE_FIELD_POS_X);
        values.set!CORPSE_FIELD_POS_Y(v.get!CORPSE_FIELD_POS_Y);
        values.set!CORPSE_FIELD_POS_Z(v.get!CORPSE_FIELD_POS_Z);
        values.set!CORPSE_FIELD_BYTES_1(v.get!CORPSE_FIELD_BYTES_1);
        values.set!CORPSE_FIELD_BYTES_2(v.get!CORPSE_FIELD_BYTES_2);
        values.set!CORPSE_FIELD_DISPLAY_ID(v.get!CORPSE_FIELD_DISPLAY_ID);
        values.set!CORPSE_FIELD_FLAGS((body_.values.get!CORPSE_FIELD_FLAGS & CorpseFlags.pvp) | CorpseFlags.bones);
        values.clearChanges();
    }

    /// `player`'s body where it stands, looking like it.
    this(const Player player, CorpseType type, long now)
    {
        this(player, type, now, player.data.map, player.position);
    }

    this(const Player player, CorpseType type, long now, uint mapId, Position position)
    {
        enum uint flagUnk2 = 0x04, hideHelm = 0x08, hideCloak = 0x10;               // corpse flags
        enum uint playerHideHelm = 0x00000400, playerHideCloak = 0x00000800;      // player flags
        owner = player.data.guid;
        guid_ = makeGuid(HighGuid.corpse, owner);
        map = mapId;
        at = position;
        this.type = type;
        ghostTime = now;
        values = UpdateValues(TypeId.corpse);
        values.set!OBJECT_FIELD_GUID(guid_);
        values.set!OBJECT_FIELD_SCALE_X(1.0f);
        values.set!CORPSE_FIELD_OWNER(player.guid);
        values.set!CORPSE_FIELD_FACING(at.orientation);
        values.set!CORPSE_FIELD_POS_X(at.x);
        values.set!CORPSE_FIELD_POS_Y(at.y);
        values.set!CORPSE_FIELD_POS_Z(at.z);
        const v = &player.values;
        values.setByte!CORPSE_FIELD_BYTES_1(1, player.data.race);
        values.setByte!CORPSE_FIELD_BYTES_1(2, player.data.gender);
        values.setByte!CORPSE_FIELD_BYTES_1(3, v.getByte!PLAYER_BYTES(0)); // skin
        values.setByte!CORPSE_FIELD_BYTES_2(0, v.getByte!PLAYER_BYTES(1)); // face
        values.setByte!CORPSE_FIELD_BYTES_2(1, v.getByte!PLAYER_BYTES(2)); // hair style
        values.setByte!CORPSE_FIELD_BYTES_2(2, v.getByte!PLAYER_BYTES(3)); // hair colour
        values.setByte!CORPSE_FIELD_BYTES_2(3, v.getByte!PLAYER_BYTES_2(0)); // facial hair
        uint flags = flagUnk2;
        const playerFlags = v.get!PLAYER_FLAGS;
        if (playerFlags & playerHideHelm)
            flags |= hideHelm;
        if (playerFlags & playerHideCloak)
            flags |= hideCloak;
        values.set!CORPSE_FIELD_FLAGS(flags);
        values.set!CORPSE_FIELD_DISPLAY_ID(v.get!UNIT_FIELD_NATIVEDISPLAYID);
        foreach (ubyte slot; 0 .. 19)
            if (const item = player.inventory.equipped(slot))
                values.set!CORPSE_FIELD_ITEM(slot, item.proto.displayId | uint(item.proto.inventoryType) << 24);
        values.clearChanges();
    }

    package void writeHandoff(ref ByteWriter writer) const
    {
        writer.put(map);
        writer.put(instanceId);
        writer.put(at.x);
        writer.put(at.y);
        writer.put(at.z);
        writer.put(at.orientation);
        writer.put(cast(ubyte) type);
        writer.put(ghostTime);
        foreach (slot; 0 .. values.length)
            writer.put(values[slot]);
    }

    package this(uint player, ref ByteReader reader)
    {
        owner = player;
        guid_ = makeGuid(HighGuid.corpse, owner);
        map = reader.read!uint;
        instanceId = reader.read!uint;
        at = Position(reader.read!float, reader.read!float, reader.read!float, reader.read!float);
        type = cast(CorpseType) reader.read!ubyte;
        ghostTime = reader.read!long;
        values = UpdateValues(TypeId.corpse);
        foreach (slot; 0 .. values.length)
            values.setSlot(slot, reader.read!uint);
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

    /// Its movement block is stationary and identical for local observers and replicas.
    MovementBlock motion(uint serverTime) const
    {
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.hasPosition;
        block.position = at;
        return block;
    }

    /// Its create block: a position and its fields (`UPDATEFLAG_ALL | UPDATEFLAG_HAS_POSITION`).
    UpdateData appearance(uint serverTime) const
    {
        const block = motion(serverTime);
        UpdateData update;
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }
}
