/**
 * A dead player's body (CMaNGOS `Entities/Corpse.cpp`): where the player died, looking like it,
 * until the ghost reclaims it or is resurrected elsewhere. It is saved in `corpse` while it lasts,
 * so a ghost that logs out finds it again.
 *
 * Deviation: a corpse's guid is its player's (CMaNGOS counts corpses on their own); a player has
 * at most one corpse, and the guid needs no counter of its own across a cluster.
 */
module dmangos.world.corpse;

import dmangos.world.map : MapObject;
import dmangos.world.movement : Position;
import dmangos.world.objects;
import dmangos.world.player : Player, PlayerFlags;
import dmangos.world.updatefields;

/// `CorpseType`
enum CorpseType : ubyte
{
    bones,
    resurrectablePve,
    resurrectablePvp,
}

/// `HIGHGUID_CORPSE`
enum ushort highGuidCorpse = 0xF101;

/// `CORPSE_RECLAIM_RADIUS`: how near its corpse a ghost must be to come back to life there.
enum float corpseReclaimRadius = 39;

/// See the module documentation.
final class Corpse : MapObject
{
    immutable ulong guid_;
    immutable uint owner;          /// the player's low guid
    immutable uint map;
    Position at;
    CorpseType type;
    long ghostTime;                /// `m_time`: when the player released its spirit (Unix time)
    UpdateValues values;

    /// `Corpse::Create` and `Player::CreateCorpse`: `player`'s body where it stands, looking like it.
    this(const Player player, CorpseType type, long now)
    {
        enum uint flagUnk2 = 0x04, hideHelm = 0x08, hideCloak = 0x10;               // CORPSE_FLAG_*
        enum uint playerHideHelm = 0x00000400, playerHideCloak = 0x00000800;      // PLAYER_FLAGS_HIDE_*
        owner = player.data.guid;
        guid_ = ulong(highGuidCorpse) << 48 | owner;
        map = player.data.map;
        at = player.position;
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
