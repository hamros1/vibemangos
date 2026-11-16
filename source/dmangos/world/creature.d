/**
 * Creatures (CMaNGOS `Entities/Creature.cpp`, the creature parts of
 * `ObjectMgr`): what `creature_template` and its companion tables say about
 * an entry, what `creature` says about a spawn, and the `Creature` object
 * built from the two, as `Creature::Create`, `InitEntry`, `UpdateEntry` and
 * `SelectLevel` build it.
 *
 * Creatures stand where they spawned for now: movement, AI, combat, death
 * and respawning come with the milestones that need them.
 */
module dmangos.world.creature;

import std.algorithm.comparison : max, min;
import std.random : Random, uniform;

import dmangos.world.clientdata : ClientData;
import dmangos.world.map : MapObject;
import dmangos.world.movement : baseMoveSpeed, MovementInfo, MoveType, Position;
import dmangos.world.objects;
import dmangos.world.updatefields;

/// The `creature_template` columns the server uses, in this order.
struct CreatureTemplate
{
    uint entry;
    string name;
    string subName;
    uint minLevel;
    uint maxLevel;
    uint modelId1;
    uint modelId2;
    uint modelId3;
    uint modelId4;
    uint faction;
    float scale = 0;
    uint family;
    uint creatureType;
    uint inhabitType;
    uint racialLeader;
    uint npcFlags;
    uint unitFlags;
    uint dynamicFlags;
    uint extraFlags;
    uint typeFlags;
    float speedWalk = 1;
    float speedRun = 1;
    uint unitClass;
    uint rank;
    float healthMultiplier = 1;
    float powerMultiplier = 1;
    uint minLevelHealth;
    uint maxLevelHealth;
    uint minLevelMana;
    uint maxLevelMana;
    uint meleeBaseAttackTime;
    uint rangedBaseAttackTime;
    uint petSpellDataId;
    uint movementType;
    uint gossipMenuId;
    uint equipmentTemplateId;
    uint civilian;
    uint trainerType;           /// `TrainerType`: class, mounts, tradeskills or pets
    uint trainerSpell;          /// `TrainerSpell`: a tradeskill trainer teaches those who know this spell
    uint trainerClass;          /// `TrainerClass`
    uint trainerRace;           /// `TrainerRace`
    uint trainerTemplateId;     /// `TrainerTemplateId`: its `npc_trainer_template` list
    uint vendorTemplateId;      /// `VendorTemplateId`: its `npc_vendor_template` list

    /// The four models, `ModelId1` .. `ModelId4`.
    @property uint[4] modelIds() const pure nothrow @nogc @safe
    {
        return [modelId1, modelId2, modelId3, modelId4];
    }
}

/// The `creature_template` query that fills `CreatureTemplate`.
enum creatureTemplateQuery = "SELECT Entry, Name, IFNULL(SubName, ''), MinLevel, MaxLevel, ModelId1, ModelId2, "
    ~ "ModelId3, ModelId4, Faction, Scale, Family, CreatureType, InhabitType, RacialLeader, NpcFlags, UnitFlags, "
    ~ "DynamicFlags, ExtraFlags, CreatureTypeFlags, SpeedWalk, SpeedRun, UnitClass, `Rank`, HealthMultiplier, "
    ~ "PowerMultiplier, MinLevelHealth, MaxLevelHealth, MinLevelMana, MaxLevelMana, MeleeBaseAttackTime, "
    ~ "RangedBaseAttackTime, PetSpellDataId, MovementType, GossipMenuId, EquipmentTemplateId, Civilian, "
    ~ "TrainerType, TrainerSpell, TrainerClass, TrainerRace, TrainerTemplateId, VendorTemplateId "
    ~ "FROM creature_template";

/// A `creature` row: one spawn.
struct CreatureSpawn
{
    uint guid;
    uint entry;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    uint respawnSeconds;
    float wanderDistance = 0;
    uint movementType;
}

/// `creature_addon` or `creature_template_addon`: how a creature stands, sits, rides or loops an emote.
struct CreatureAddon
{
    uint mount;       /// a display id
    uint standState;
    uint sheathState;
    uint emote;
}

/// `creature_template_classlevelstats` for one level and class.
struct CreatureClassStats
{
    uint baseHealth;
    uint baseMana;
}

/// The key of `CreatureClassStats` by level and class.
uint classStatsKey(uint level, uint unitClass) pure nothrow @nogc @safe
{
    return level << 8 | unitClass;
}

/// An item a creature holds: what `SetVirtualItem` shows of it.
struct VirtualItem
{
    uint display;
    ubyte itemClass;
    ubyte subClass;
    ubyte material;
    ubyte inventoryType;
    ubyte sheath;
}

/// What building a creature needs besides its spawn and template.
struct CreatureParts
{
    const(CreatureAddon)* addon;     /// null if none
    VirtualItem[3] equipment;        /// main hand, off hand, ranged
    CreatureClassStats classStats;   /// for the chosen level; zero if there is no row
    bool hasClassStats;
    float boundingRadius = 0.5f;     /// from `creature_model_info`
    float combatReach = 1.5f;        /// ditto
    ubyte gender;                    /// ditto
}

private enum : uint
{
    unitByte2FlagAuras = 0x10, // UNIT_BYTE2_FLAG_AURAS
    sheathMelee = 1,           // SHEATH_STATE_MELEE
}

/// See the module documentation.
final class Creature : MapObject
{
    immutable ulong guid_;
    const(CreatureTemplate)* template_;
    const CreatureSpawn spawn;
    MovementInfo movement;
    UpdateValues values;
    float[MoveType.max + 1] speeds = baseMoveSpeed;

    /**
     * `Creature::Create` from a spawn: a level between the template's, a model among its models,
     * and the fields that follow. `display` is the chosen model; `level` the chosen level.
     */
    this(const ref CreatureSpawn spawn, const(CreatureTemplate)* template_, uint display, uint level,
        const ref CreatureParts parts, const ClientData client)
    in (template_ !is null && template_.entry == spawn.entry)
    {
        this.spawn = spawn;
        this.template_ = template_;
        guid_ = makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
        movement.position = Position(spawn.x, spawn.y, spawn.z, spawn.orientation);
        speeds[MoveType.walk] = baseMoveSpeed[MoveType.walk] * template_.speedWalk;
        speeds[MoveType.run] = baseMoveSpeed[MoveType.run] * template_.speedRun;
        values = UpdateValues(TypeId.unit);
        setFields(display, level, parts, client);
        values.clearChanges();
    }

    /// The guid: high part, entry and spawn guid.
    @property ulong guid() const
    {
        return guid_;
    }

    /// `VendorItemCount`: a limited item's stock since it was first bought, and when it last grew.
    private struct VendorStock
    {
        uint count;
        long lastIncrement;
    }

    private VendorStock[uint] vendorStock; // by item: `m_vendorItemCounts`

    /**
     * `Creature::GetVendorItemCurrentCount`: how many of a limited item (`maxCount` > 0) the vendor
     * has at Unix time `now`; it grows by `buyCount` every `incrTime` seconds, back to `maxCount`.
     */
    uint vendorItemCount(uint item, uint maxCount, uint incrTime, uint buyCount, long now)
    {
        if (maxCount == 0)
            return 0;
        auto stock = item in vendorStock;
        if (stock is null)
            return maxCount;
        if (stock.lastIncrement + incrTime <= now)
        {
            // A restock time of 0 would divide by zero in CMaNGOS: here the item is simply back.
            const steps = incrTime == 0 ? maxCount : cast(uint)((now - stock.lastIncrement) / incrTime);
            if (stock.count + steps * buyCount >= maxCount)
            {
                vendorStock.remove(item);
                return maxCount;
            }
            stock.count += steps * buyCount;
            stock.lastIncrement = now;
        }
        return stock.count;
    }

    /// `Creature::UpdateVendorItemCurrentCount`: `used` were bought; returns how many are left.
    uint takeVendorItems(uint item, uint maxCount, uint incrTime, uint buyCount, uint used, long now)
    {
        if (maxCount == 0)
            return 0;
        auto stock = item in vendorStock;
        if (stock is null)
        {
            const left = maxCount > used ? maxCount - used : 0;
            vendorStock[item] = VendorStock(left, now);
            return left;
        }
        if (stock.lastIncrement + incrTime <= now)
        {
            const steps = incrTime == 0 ? maxCount : cast(uint)((now - stock.lastIncrement) / incrTime);
            stock.count = stock.count + steps * buyCount < maxCount ? stock.count + steps * buyCount : maxCount;
        }
        stock.count = stock.count > used ? stock.count - used : 0;
        stock.lastIncrement = now;
        return stock.count;
    }

    /// See `MapObject.fields`.
    ref UpdateValues fields()
    {
        return values;
    }

    /// Where the creature is.
    @property Position position() const
    {
        return movement.position;
    }

    /// `Object::BuildCreateUpdateBlockForPlayer`: a unit with its movement and public fields.
    UpdateData appearance(uint serverTime) const
    {
        UpdateData update;
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
        block.info = movement;
        block.info.time = serverTime;
        block.speeds = speeds;
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }

private:
    void setFields(uint display, uint level, const ref CreatureParts parts, const ClientData client)
    {
        alias t = template_;
        values.set!OBJECT_FIELD_GUID(guid_);
        values.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.unit);
        values.set!OBJECT_FIELD_ENTRY(t.entry);
        const scale = t.scale > 0 ? t.scale : client.displayScale(display);
        values.set!OBJECT_FIELD_SCALE_X(scale);

        // InitEntry: class, gender, power type, model.
        enum : ubyte { powerMana = 0, powerRage = 1, powerEnergy = 3 }
        const powerType = t.unitClass == 1 ? powerRage : t.unitClass == 4 ? powerEnergy : powerMana;
        values.set!UNIT_FIELD_BYTES_0(uint(t.unitClass) << 8 | uint(parts.gender) << 16 | uint(powerType) << 24);
        values.set!UNIT_FIELD_DISPLAYID(display);
        values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        values.set!UNIT_FIELD_BOUNDINGRADIUS(parts.boundingRadius * scale);
        values.set!UNIT_FIELD_COMBATREACH(parts.combatReach * scale);
        values.set!UNIT_MOD_CAST_SPEED(1.0f);

        // SelectLevel: health and mana from the class stats, or the template's range.
        values.set!UNIT_FIELD_LEVEL(level);
        uint health, mana;
        if (parts.hasClassStats)
        {
            health = cast(uint)(parts.classStats.baseHealth * (t.healthMultiplier > 0 ? t.healthMultiplier : 1));
            mana = cast(uint)(parts.classStats.baseMana * (t.powerMultiplier > 0 ? t.powerMultiplier : 1));
        }
        else
        {
            const span = t.maxLevel > t.minLevel ? float(level - t.minLevel) / (t.maxLevel - t.minLevel) : 0;
            const lowHealth = min(t.minLevelHealth, t.maxLevelHealth);
            const highHealth = max(t.minLevelHealth, t.maxLevelHealth);
            const lowMana = min(t.minLevelMana, t.maxLevelMana), highMana = max(t.minLevelMana, t.maxLevelMana);
            health = lowHealth + cast(uint)(span * (highHealth - lowHealth));
            mana = lowMana + cast(uint)(span * (highMana - lowMana));
        }
        health = max(health, 1);
        values.set!UNIT_FIELD_HEALTH(health);
        values.set!UNIT_FIELD_MAXHEALTH(health);
        values.set!UNIT_FIELD_POWER1(0, mana);
        values.set!UNIT_FIELD_MAXPOWER1(0, mana);
        values.set!UNIT_FIELD_MAXPOWER1(1, 1000u); // rage, as Unit::SetPowerType gives it
        values.set!UNIT_FIELD_MAXPOWER1(3, 100u);  // energy
        values.set!UNIT_FIELD_POWER1(3, 100u);

        // UpdateEntry: faction, flags, attack times.
        values.set!UNIT_FIELD_FACTIONTEMPLATE(t.faction);
        values.set!UNIT_NPC_FLAGS(t.npcFlags);
        values.set!UNIT_FIELD_FLAGS(t.unitFlags);
        values.set!UNIT_DYNAMIC_FLAGS(t.dynamicFlags);
        values.set!UNIT_FIELD_BASEATTACKTIME(t.meleeBaseAttackTime);
        values.set!UNIT_FIELD_BASEATTACKTIME(1, t.meleeBaseAttackTime);
        values.set!UNIT_FIELD_RANGEDATTACKTIME(t.rangedBaseAttackTime);
        values.setByte!UNIT_FIELD_BYTES_2(0, cast(ubyte) sheathMelee);
        values.setByte!UNIT_FIELD_BYTES_2(1, cast(ubyte) unitByte2FlagAuras);

        // LoadEquipment: what it holds.
        foreach (slot, ref item; parts.equipment)
        {
            if (item.display == 0)
                continue;
            values.set!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(slot, item.display);
            values.set!UNIT_VIRTUAL_ITEM_INFO(2 * slot, item.itemClass | uint(item.subClass) << 8
                | uint(item.material) << 16 | uint(item.inventoryType) << 24);
            values.set!UNIT_VIRTUAL_ITEM_INFO(2 * slot + 1, uint(item.sheath));
        }

        // The addon: mount, stand and sheath state, looping emote.
        if (const addon = parts.addon)
        {
            values.set!UNIT_FIELD_MOUNTDISPLAYID(addon.mount);
            values.setByte!UNIT_FIELD_BYTES_1(0, cast(ubyte) addon.standState);
            values.setByte!UNIT_FIELD_BYTES_2(0, cast(ubyte) addon.sheathState);
            values.set!UNIT_NPC_EMOTESTATE(addon.emote);
        }
    }
}

/// `Creature::ChooseDisplayId`: one of the template's models, each as likely.
uint chooseDisplay(const ref CreatureTemplate t, ref Random rng)
{
    uint[4] models;
    size_t count;
    foreach (model; t.modelIds)
        if (model)
            models[count++] = model;
    return count ? models[uniform(0, count, rng)] : 0;
}

/// `SelectLevel`'s level: between the template's minimum and maximum.
uint chooseLevel(const ref CreatureTemplate t, ref Random rng)
{
    const low = max(1, min(t.minLevel, t.maxLevel)), high = max(low, max(t.minLevel, t.maxLevel));
    return low == high ? low : uniform!"[]"(low, high, rng);
}

unittest
{
    import dmangos.world.testdata : testClientData;

    CreatureTemplate hogger;
    hogger.entry = 448;
    hogger.name = "Hogger";
    hogger.minLevel = hogger.maxLevel = 11;
    hogger.modelId1 = 384;
    hogger.faction = 20;
    hogger.unitClass = 1;
    hogger.healthMultiplier = 3;
    hogger.meleeBaseAttackTime = 2000;
    hogger.npcFlags = 2;
    hogger.speedRun = 1.14286f;
    auto rng = Random(1);
    assert(chooseDisplay(hogger, rng) == 384 && chooseLevel(hogger, rng) == 11);

    CreatureParts parts;
    parts.classStats = CreatureClassStats(222, 0);
    parts.hasClassStats = true;
    const spawn = CreatureSpawn(89, 448, 0, -9726, 1019, 45, 1.5f);
    auto creature = new Creature(spawn, &hogger, 384, 11, parts, testClientData());
    assert(highGuidOf(creature.guid) == HighGuid.unit && counterOf(creature.guid) == 89);
    assert(creature.values[OBJECT_FIELD_ENTRY] == 448 && creature.values[UNIT_FIELD_MAXHEALTH] == 666);
    assert(creature.values[UNIT_NPC_FLAGS] == 2);
    assert(creature.values.getByte!UNIT_FIELD_BYTES_0(3) == 1, "a warrior uses rage");
    assert(creature.speeds[MoveType.run] > 7.9f && creature.appearance(0).blockCount == 1);
}
