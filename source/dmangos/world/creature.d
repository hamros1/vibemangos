/**
 * Creatures: what `creature_template` and its companion tables say about
 * an entry, what `creature` says about a spawn, and the `Creature` object
 * built from the two: its level, model, faction, equipment and combat
 * stats.
 *
 * A creature moves as its movement generator (`dmangos.world.motion`) has it
 * move, as the map ticks; AI, combat, death and respawning come with the
 * milestones that need them.
 */
module dmangos.world.creature;

import dmangos.world.pet : PetState;

import dmangos.world.combat : Fighter;
import dmangos.world.auras : AuraSet, AuraTick, Aura;
import dmangos.world.loot : Loot;
import dmangos.world.creatureai : CombatWorld, CreatureAI;
import dmangos.world.clientdata : FactionTemplateEntry;
import dmangos.world.defines : UnitFlags;

import std.algorithm.comparison : among, max, min;
import std.random : Random, uniform;

import dmangos.world.clientdata : ClientData;
import dmangos.world.map : Idler, Moving, PerViewer;
import dmangos.world.replication : Replica, Replicable;
import dmangos.world.motion : followSpline, IdleMovement, MotionType, MotionWorld, MovementGenerator;
import dmangos.world.movement : baseMoveSpeed, MovementFlags, MovementInfo, MoveType, Position;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.spline : MoveSpline;
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
    // Combat (see `selectLevel`).
    float damageMultiplier = 1; /// `DamageMultiplier`; negative: the template's own damage
    float damageVariance = 1;   /// `DamageVariance`
    float armorMultiplier = 1;  /// `ArmorMultiplier`; negative: the template's own armor
    float minMeleeDmg = 0;
    float maxMeleeDmg = 0;
    float minRangedDmg = 0;
    float maxRangedDmg = 0;
    uint armor;
    uint meleeAttackPower;
    uint rangedAttackPower;
    uint damageSchool;          /// `DamageSchool`: the school of its melee attacks
    uint detection;             /// `Detection`: its aggro radius against its own level, in yards
    uint pursuit;               /// `Pursuit`: milliseconds it chases before its victim may get away
    uint leash;                 /// `Leash`: how far from where the fight began it follows; 0: no limit
    float experienceMultiplier = 1; /// `ExperienceMultiplier`
    uint lootId;                /// `LootId`: its `creature_loot_template` entry
    uint minLootGold;           /// `MinLootGold`, in copper
    uint maxLootGold;           /// `MaxLootGold`
    uint skinningLootId;        /// `SkinningLootId`
    uint pickpocketLootId;      /// `PickpocketLootId`
    uint staticFlags1;          /// `StaticFlags1`: `NO_XP` 0x2, `NO_LOOT` 0x4
    uint callForHelp;           /// `CallForHelp`: how far it calls for help when it starts fighting; 0: 5 yards
    int resistanceHoly, resistanceFire, resistanceNature; /// `Resistance*`
    int resistanceFrost, resistanceShadow, resistanceArcane;
    uint spellList;             /// `SpellList`: its `creature_spell_list` (0: none)
    uint mechanicImmuneMask;    /// `MechanicImmuneMask`: bit `mechanic - 1` for each mechanic it ignores (bosses: stuns, fear)
    uint schoolImmuneMask;      /// `SchoolImmuneMask`: the schools that cannot hurt it

    /// Its resistance to `school` (1 holy .. 6 arcane).
    int resistance(uint school) const pure nothrow @nogc @safe
    {
        switch (school)
        {
        case 1: return resistanceHoly;
        case 2: return resistanceFire;
        case 3: return resistanceNature;
        case 4: return resistanceFrost;
        case 5: return resistanceShadow;
        case 6: return resistanceArcane;
        default: return 0;
        }
    }

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
    ~ "TrainerType, TrainerSpell, TrainerClass, TrainerRace, TrainerTemplateId, VendorTemplateId, "
    ~ "DamageMultiplier, DamageVariance, ArmorMultiplier, MinMeleeDmg, MaxMeleeDmg, MinRangedDmg, MaxRangedDmg, "
    ~ "Armor, MeleeAttackPower, RangedAttackPower, DamageSchool, Detection, Pursuit, Leash, ExperienceMultiplier, "
    ~ "LootId, MinLootGold, MaxLootGold, SkinningLootId, PickpocketLootId, StaticFlags1, CallForHelp, "
    ~ "ResistanceHoly, ResistanceFire, ResistanceNature, ResistanceFrost, ResistanceShadow, ResistanceArcane, "
    ~ "SpellList, MechanicImmuneMask, SchoolImmuneMask FROM creature_template";

/// When a summoned creature goes (`none`: not a summon).
enum TempSpawnType : ubyte
{
    manual = 0,              /// when unsummoned
    dead = 1,                /// when its corpse goes
    corpse = 2,              /// as soon as it dies
    corpseTimed = 3,         /// its time after it dies
    timed = 4,               /// after its time
    timedOutOfCombat = 5,    /// after its time out of combat
    timedOrDead = 6,         /// after its time, or when its corpse goes
    timedOrCorpse = 7,       /// after its time, or as soon as it dies
    timedOutOfCombatOrDead = 8,
    timedOutOfCombatOrCorpse = 9,
    none = 255,
}

/// A summoned creature's state.
struct TempSpawn
{
    TempSpawnType type = TempSpawnType.none;
    int timer;          /// milliseconds left
    uint duration;      /// the whole time, for the timers that start again in combat
    ulong summoner;

    /// Whether a timer runs while it is alive (it must keep ticking).
    @property bool timed() const pure nothrow @nogc @safe
    {
        with (TempSpawnType) return type.among(timed, timedOutOfCombat, timedOrDead, timedOrCorpse,
            timedOutOfCombatOrDead, timedOutOfCombatOrCorpse) != 0;
    }

    /// `diff` milliseconds on; whether it goes now.
    bool update(Creature creature, int diff)
    {
        with (TempSpawnType) final switch (type)
        {
        case none, manual, dead:
            return false; // a dead one goes with its corpse
        case corpse:
            return !creature.alive;
        case corpseTimed:
            return !creature.alive && (timer -= diff) <= 0;
        case timed:
            return (timer -= diff) <= 0;
        case timedOrDead:
            return creature.alive && (timer -= diff) <= 0;
        case timedOrCorpse:
            return !creature.alive || (timer -= diff) <= 0;
        case timedOutOfCombat, timedOutOfCombatOrDead, timedOutOfCombatOrCorpse:
            if (!creature.alive)
                return type == timedOutOfCombatOrCorpse;
            if (creature.ai !is null && creature.ai.inCombat)
            {
                timer = duration; // the time counts out of combat only
                return false;
            }
            return (timer -= diff) <= 0;
        }
    }
}

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
    uint respawnSecondsMax;     /// `spawntimesecsmax`: the respawn time is between the two
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
    uint baseHealth;            /// `BaseHealthExp0`
    uint baseMana;
    float baseDamage = 0;       /// `BaseDamageExp0`
    float baseMeleeAttackPower = 0;
    float baseRangedAttackPower = 0;
    float baseArmor = 0;
}

/**
 * A creature's combat stats: health, mana, armor, attack power and
 * weapon damage, from the class stats of its level, or (without them, or when the template's
 * multipliers say so) the template's own numbers. The creature rate settings
 * are all 1.
 */
struct CreatureCombatStats
{
    uint health = 1, mana;
    float armor = 0;
    float meleeAttackPower = 0, rangedAttackPower = 0;
    float[2][3] damage = 0;       /// by attack type (main hand, off hand, ranged): minimum, maximum
}

/// ditto
CreatureCombatStats selectLevel(const ref CreatureTemplate t, uint level, const(CreatureClassStats)* stats)
    pure nothrow @nogc @safe
{
    import std.math : round;

    CreatureCombatStats r;
    uint health = uint.max, mana = uint.max;
    float armor = -1;
    float[2][3] weapon = 0;
    float meleePower = 0, rangedPower = 0;
    bool usedDamageMulti;
    const damageMulti = t.damageMultiplier; // times the rank's damage modifier, which is 1
    if (stats !is null)
    {
        if (t.healthMultiplier >= 0)
            health = cast(uint) round(stats.baseHealth * t.healthMultiplier);
        if (t.powerMultiplier >= 0)
            mana = cast(uint) round(stats.baseMana * t.powerMultiplier);
        if (t.armorMultiplier >= 0)
            armor = round(stats.baseArmor * t.armorMultiplier);
        if (t.damageMultiplier >= 0 && t.armorMultiplier >= 0)
        {
            usedDamageMulti = true;
            const melee = t.meleeBaseAttackTime / 1000.0f, ranged = t.rangedBaseAttackTime / 1000.0f;
            weapon[0][0] = ((stats.baseDamage * t.damageVariance) + stats.baseMeleeAttackPower / 14.0f) * melee
                * damageMulti;
            weapon[0][1] = ((stats.baseDamage * t.damageVariance * 1.5f) + stats.baseMeleeAttackPower / 14.0f) * melee
                * damageMulti;
            weapon[1] = weapon[0]; // the off hand's modifier halves it
            weapon[2][0] = ((stats.baseDamage * t.damageVariance) + stats.baseRangedAttackPower / 14.0f) * ranged
                * damageMulti;
            weapon[2][1] = ((stats.baseDamage * t.damageVariance * 1.5f) + stats.baseRangedAttackPower / 14.0f)
                * ranged * damageMulti;
            meleePower = stats.baseMeleeAttackPower;
            rangedPower = stats.baseRangedAttackPower;
        }
    }
    if (!usedDamageMulti || armor == -1)
    {
        const span = t.maxLevel == t.minLevel ? 0 : float(level - t.minLevel) / (t.maxLevel - t.minLevel);
        if (armor == -1)
        {
            const lowHealth = t.minLevelHealth < t.maxLevelHealth ? t.minLevelHealth : t.maxLevelHealth;
            const highHealth = t.minLevelHealth < t.maxLevelHealth ? t.maxLevelHealth : t.minLevelHealth;
            health = lowHealth + cast(uint)(span * (highHealth - lowHealth));
            const lowMana = t.minLevelMana < t.maxLevelMana ? t.minLevelMana : t.maxLevelMana;
            const highMana = t.minLevelMana < t.maxLevelMana ? t.maxLevelMana : t.minLevelMana;
            mana = lowMana + cast(uint)(span * (highMana - lowMana));
            armor = t.armor;
        }
        if (!usedDamageMulti)
        {
            weapon[0] = [t.minMeleeDmg * damageMulti, t.maxMeleeDmg * damageMulti];
            weapon[1] = [t.minMeleeDmg * damageMulti / 2, t.maxMeleeDmg * damageMulti / 2];
            weapon[2] = [t.minRangedDmg * damageMulti, t.maxRangedDmg * damageMulti];
            meleePower = t.meleeAttackPower;
            rangedPower = t.rangedAttackPower;
        }
    }
    r.health = health < 1 ? 1 : health;
    r.mana = mana == uint.max ? 0 : mana;
    r.armor = armor;
    r.meleeAttackPower = meleePower;
    r.rangedAttackPower = rangedPower;
    // Physical damage: the weapon's damage and the attack power over its swing time;
    // the off hand's damage modifier is 50%.
    const uint[3] times = [t.meleeBaseAttackTime, t.meleeBaseAttackTime, t.rangedBaseAttackTime];
    foreach (type; 0 .. 3)
    {
        const power = type == 2 ? rangedPower : meleePower;
        const base = power * (times[type] / 1000.0f) / 14.0f;
        const totalPct = type == 1 ? 0.5f : 1.0f;
        r.damage[type] = [(base + weapon[type][0]) * totalPct, (base + weapon[type][1]) * totalPct];
    }
    return r;
}

/// The key of `CreatureClassStats` by level and class.
uint classStatsKey(uint level, uint unitClass) pure nothrow @nogc @safe
{
    return level << 8 | unitClass;
}

/// An item a creature holds: what `setVirtualItem` shows of it.
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
    float collisionHeight = 0;       /// the model's (`CreatureModelData.dbc`), before scaling; 0 if unknown
}

/// The collision height of a model that has none.
enum float defaultCollisionHeight = 2.03128f;

private enum : uint
{
    unitByte2FlagAuras = 0x10, // UNIT_BYTE2_FLAG_AURAS
    sheathMelee = 1,           // SHEATH_STATE_MELEE
}

/// A vendor's limited items: how many are left, and since when.
struct VendorStocks
{
    /// A limited item's stock since it was first bought, and when it last grew.
    static struct Stock
    {
        uint count;
        long lastIncrement;
    }

    Stock[uint] items; /// by item

    /**
     * How many of a limited item (`maxCount` > 0) the vendor
     * has at Unix time `now`; it grows by `buyCount` every `incrTime` seconds, back to `maxCount`.
     */
    uint count(uint item, uint maxCount, uint incrTime, uint buyCount, long now)
    {
        if (maxCount == 0)
            return 0;
        auto stock = item in items;
        if (stock is null)
            return maxCount;
        if (stock.lastIncrement + incrTime <= now)
        {
            // A restock time of 0 restocks the item fully at once, rather than dividing by zero.
            const steps = incrTime == 0 ? maxCount : cast(uint)((now - stock.lastIncrement) / incrTime);
            if (stock.count + steps * buyCount >= maxCount)
            {
                items.remove(item);
                return maxCount;
            }
            stock.count += steps * buyCount;
            stock.lastIncrement = now;
        }
        return stock.count;
    }

    /// `used` were bought; returns how many are left.
    uint take(uint item, uint maxCount, uint incrTime, uint buyCount, uint used, long now)
    {
        if (maxCount == 0)
            return 0;
        auto stock = item in items;
        if (stock is null)
        {
            const left = maxCount > used ? maxCount - used : 0;
            items[item] = Stock(left, now);
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

    /// Puts back `count` of a limited item a purchase did not complete with (stock it reserved).
    void giveBack(uint item, uint maxCount, uint count)
    {
        if (auto stock = item in items)
            stock.count = stock.count + count < maxCount ? stock.count + count : maxCount;
    }
}

/**
 * What NPC services (gossip, trainers, vendors, innkeepers, bankers) need of a creature: the creature
 * itself, or on a cluster node a stand-in for a replica of another node's (`NpcStandIn`).
 */
interface Npc
{
    @property ulong guid() const;
    @property Position position() const;
    ref inout(UpdateValues) npcValues() inout;
    @property const(CreatureTemplate)* npcTemplate() const;
    /// Its `creature` row (`npc_gossip` and the like are by spawn).
    @property uint spawnId() const;
    uint vendorItemCount(uint item, uint maxCount, uint incrTime, uint buyCount, long now);
    uint takeVendorItems(uint item, uint maxCount, uint incrTime, uint buyCount, uint used, long now);
}

/**
 * An NPC another node simulates, as this node serves it: its replica's fields and position,
 * its template from the world data every node shares. Limited vendor stock is counted here, apart from
 * the real creature's: a known gap until it is kept by the creature's node.
 */
final class NpcStandIn : Npc
{
    private Replica replica;
    private const(CreatureTemplate)* template_;
    private VendorStocks stock;

    ///
    this(Replica replica, const(CreatureTemplate)* template_)
    {
        this.replica = replica;
        this.template_ = template_;
    }

    /// The node simulating the real creature: limited stock is reserved there.
    @property ushort owner() const
    {
        return replica.owner;
    }

    /// The replica it stands for now (replicas are replaced when their owner changes).
    void follow(Replica replica)
    {
        this.replica = replica;
    }

    @property ulong guid() const { return replica.guid; }
    @property Position position() const { return replica.position; }
    ref inout(UpdateValues) npcValues() inout { return replica.fieldsOf; }
    @property const(CreatureTemplate)* npcTemplate() const { return template_; }
    @property uint spawnId() const { return cast(uint) counterOf(replica.guid); } // a creature's guid holds its spawn

    uint vendorItemCount(uint item, uint maxCount, uint incrTime, uint buyCount, long now)
    {
        return stock.count(item, maxCount, incrTime, buyCount, now);
    }

    uint takeVendorItems(uint item, uint maxCount, uint incrTime, uint buyCount, uint used, long now)
    {
        return stock.take(item, maxCount, incrTime, buyCount, used, now);
    }
}

/// See the module documentation.
final class Creature : Moving, Idler, Replicable, Npc, PerViewer
{
    immutable ulong guid_;
    const(CreatureTemplate)* template_;
    const CreatureSpawn spawn;
    MovementInfo movement;
    UpdateValues values;
    float[MoveType.max + 1] speeds = baseMoveSpeed;
    float collisionHeight = defaultCollisionHeight; /// its height, by its model and scale

    MoveSpline spline;              /// the walk under way, if not finalized
    int positionTimer;              /// milliseconds until the position follows the walk
    MovementGenerator generator;      /// how it moves on its own; idle unless set before its first tick
    private bool motionStarted;

    /**
     * A creature from a spawn: a level between the template's, a model among its models,
     * and the fields that follow. `display` is the chosen model; `level` the chosen level.
     */
    this(const ref CreatureSpawn spawn, const(CreatureTemplate)* template_, uint display, uint level,
        const ref CreatureParts parts, const ClientData client, uint petNumber = 0)
    in (template_ !is null && template_.entry == spawn.entry)
    {
        this.spawn = spawn;
        this.template_ = template_;
        // A pet's guid is `HIGHGUID_PET`'s, with its number where a creature has its entry.
        guid_ = petNumber ? makePetGuid(petNumber, spawn.guid) : makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
        movement.position = Position(spawn.x, spawn.y, spawn.z, spawn.orientation);
        movement.flags = MovementFlags.walkMode; // it walks, not runs
        generator = new IdleMovement;
        speeds[MoveType.walk] = baseMoveSpeed[MoveType.walk] * template_.speedWalk;
        speeds[MoveType.run] = baseMoveSpeed[MoveType.run] * template_.speedRun;
        values = UpdateValues(TypeId.unit);
        this.client = client;
        setFields(display, level, parts, client);
        factionTemplate = client.factionTemplates.lookup(template_.faction);
        // `FACTION_TEMPLATE_FLAG_ASSIST_PLAYERS`: such creatures fight players' fights, flagged as they are.
        if (factionTemplate !is null && (factionTemplate.flags & 0x800))
            values.set!UNIT_FIELD_FLAGS(values.get!UNIT_FIELD_FLAGS | UnitFlags.pvp);
        templateEquipment = parts.equipment;
        ai = new CreatureAI(this);
        // The model's collision height, scaled; `defaultCollisionHeight` if it has none.
        const height = parts.collisionHeight * values.get!OBJECT_FIELD_SCALE_X;
        collisionHeight = height == 0 ? defaultCollisionHeight : height;
        values.clearChanges();
    }

    /// What its template gives it to hold (main hand, off hand, ranged).
    VirtualItem[3] templateEquipment;

    /// What it holds in `slot` (0 main hand, 1 off hand, 2 ranged); no display: nothing.
    void setVirtualItem(size_t slot, const VirtualItem item)
    {
        values.set!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(slot, item.display);
        values.set!UNIT_VIRTUAL_ITEM_INFO(2 * slot, item.display ? item.itemClass | uint(item.subClass) << 8
            | uint(item.material) << 16 | uint(item.inventoryType) << 24 : 0);
        values.set!UNIT_VIRTUAL_ITEM_INFO(2 * slot + 1, item.display ? uint(item.sheath) : 0);
    }

    /**
     * Made a pet, before it is added to a map: it belongs to `owner`. Its guid is
     * already `HIGHGUID_PET`'s, with its pet number where a creature has its entry.
     */
    void becomePet(ulong owner, PetState state)
    in (highGuidOf(guid_) == HighGuid.pet, "made with its pet number (`WorldContext.makePetCreature`)")
    {
        petOwner = owner;
        petData = state;
    }

    /// The guid: high part, entry and spawn guid.
    @property ulong guid() const
    {
        return guid_;
    }

    private VendorStocks vendorStock; // what its limited items have left

    /// See `VendorStocks.count`.
    uint vendorItemCount(uint item, uint maxCount, uint incrTime, uint buyCount, long now)
    {
        return vendorStock.count(item, maxCount, incrTime, buyCount, now);
    }

    /// See `VendorStocks.take`.
    uint takeVendorItems(uint item, uint maxCount, uint incrTime, uint buyCount, uint used, long now)
    {
        return vendorStock.take(item, maxCount, incrTime, buyCount, used, now);
    }

    /// See `VendorStocks.giveBack`.
    void giveBackVendorItems(uint item, uint maxCount, uint count)
    {
        vendorStock.giveBack(item, maxCount, count);
    }

    /// See `Npc`.
    ref inout(UpdateValues) npcValues() inout
    {
        return values;
    }

    /// ditto
    @property const(CreatureTemplate)* npcTemplate() const
    {
        return template_;
    }

    /// ditto
    @property uint spawnId() const
    {
        return spawn.guid;
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

    /// The players attacking it, by guid.
    bool[ulong] attackers;

    /// A temporary summon: how it goes (`TempSpawnType`), its time, who summoned it.
    TempSpawn summon;

    /// A pet's owner (a player's guid); 0 for any other creature.
    ulong petOwner;
    ulong totemOwner;           /// a totem's owner (0: not a totem)
    uint totemSpell;            /// what a totem casts: its aura, or (active) at enemies
    bool totemActive;           /// it casts its spell at enemies (its spell has a cast time); else it holds an aura
    ushort eventShape;          /// the game event whose `game_event_creature_data` it was made with (0: none)
    /// A pet's owner's `PLAYER_FLAGS` (free-for-all, contested), for the relations (`dmangos.world.pvp`).
    uint controllerPlayerFlags;
    /// The pet's own state (`dmangos.world.pet`); null for any other creature.
    PetState petData;

    /// The dungeon instance it lives in (0: none): it does not respawn there, and is not saved.
    uint instanceId;

    /// Dead: milliseconds until its corpse goes; and when it comes back (Unix time).
    int corpseTimer;
    long respawnAt; /// ditto

    /// Who tapped it (its first damage), and that one's group.
    ulong lootRecipient;
    uint lootGroupRecipient; /// ditto
    /// Dead: what it dropped; null when nothing (or looted).
    Loot loot;

    /// Its auras (`dmangos.world.auras`): what players' spells left on it.
    AuraSet auras;

    /// `UNIT_DYNFLAG_LOOTABLE`, `UNIT_DYNFLAG_TAPPED`
    enum uint dynLootable = 0x01, dynTapped = 0x04;

    /// Tapped by `player` (and its group), or (0) by nobody; everyone sees it grey.
    void setLootRecipient(ulong player, uint group)
    {
        lootRecipient = player;
        lootGroupRecipient = player ? group : 0;
        const flags = values.get!UNIT_DYNAMIC_FLAGS & ~(dynLootable | dynTapped);
        values.set!UNIT_DYNAMIC_FLAGS(player ? flags | dynTapped : flags);
    }

    /// Whether `player` (or its group `group`) tapped it.
    bool tappedBy(ulong player, uint group) const
    {
        return lootRecipient && (player == lootRecipient || (lootGroupRecipient && group == lootGroupRecipient));
    }

    /// See `PerViewer.personalized`.
    bool personalized() const
    {
        return lootRecipient != 0 || loot !is null;
    }

    /// See `PerViewer.personalSlots`.
    const(size_t)[] personalSlots() const
    {
        static immutable size_t[1] slots = [UNIT_DYNAMIC_FLAGS];
        return slots[];
    }

    /**
     * See `PerViewer.fieldFor`: the dynamic flags each viewer sees. Who tapped it (or its
     * group) does not see it tapped, and sees its corpse sparkle while there is something for it.
     */
    uint fieldFor(ulong viewer, uint viewerGroup, size_t slot, uint value) const
    {
        if (slot != UNIT_DYNAMIC_FLAGS)
            return value;
        if (tappedBy(viewer, viewerGroup))
            value &= ~dynTapped;
        if (!alive && loot !is null && loot.canLoot(viewer))
            value |= dynLootable;
        return value;
    }

    private float auraSpeedFactor = 1; /// what its slows and speed-ups multiply its speeds by now
    private bool auraHeld;              /// rooted or stunned, as last told

    bool scriptRooted; /// held in place by its script
    bool scriptFlying; /// its script has it fly: its ways go straight through the air (raid scripts)

    /// Rooted or stunned (or held by its script): it does not move.
    @property bool immobilized() const
    {
        import dmangos.world.auras : AuraType;

        return scriptRooted || auras.has(AuraType.modRoot) || auras.has(AuraType.modStun);
    }

    /**
     * After its auras may have changed: its walk and run speeds by its strongest speed-up and slow, and held
     * where it is while rooted or stunned (a walk under way stops; stunned shows on its flags). The clients
     * are told what changed.
     */
    void refreshAuraMovement(MotionWorld world)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.auras : AuraType;
        import dmangos.world.motion : stopMoving;
        import dmangos.world.opcodes : Opcode;

        const factor = (1 + auras.strongest(AuraType.modIncreaseSpeed, true) / 100.0f)
            * (1 + auras.strongest(AuraType.modDecreaseSpeed, false) / 100.0f);
        if (factor != auraSpeedFactor && factor > 0)
        {
            foreach (type; [MoveType.walk, MoveType.run])
                speeds[type] = speeds[type] / auraSpeedFactor * factor;
            auraSpeedFactor = factor;
            foreach (pair; [[Opcode.SMSG_SPLINE_SET_WALK_SPEED, MoveType.walk],
                    [Opcode.SMSG_SPLINE_SET_RUN_SPEED, MoveType.run]])
            {
                ByteWriter w;
                w.putPackedGuid(guid);
                w.put(speeds[pair[1]]);
                world.sendToObservers(guid, cast(Opcode) pair[0], w.data);
            }
        }
        // Its attack times by its haste and slows (Thunder Clap, Chilled): the template's, scaled.
        {
            const melee = cast(uint)(template_.meleeBaseAttackTime * auras.attackTimeFactor(0)),
                ranged = cast(uint)(template_.rangedBaseAttackTime * auras.attackTimeFactor(2));
            if (melee != values.get!UNIT_FIELD_BASEATTACKTIME || ranged != values.get!UNIT_FIELD_RANGEDATTACKTIME)
            {
                values.set!UNIT_FIELD_BASEATTACKTIME(melee);
                values.set!UNIT_FIELD_BASEATTACKTIME(1, melee);
                values.set!UNIT_FIELD_RANGEDATTACKTIME(ranged);
                if (auto combat = cast(CombatWorld) world)
                    combat.flushCreature(this);
            }
        }
        const held = immobilized;
        const stunned = auras.has(AuraType.modStun);
        const flags = values.get!UNIT_FIELD_FLAGS;
        // Crowd control on its flags (CMaNGOS's `SetStunned`, `SetFleeing`, `SetConfused`, silence, pacify, disarm).
        uint flagged = flags & ~(UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused | UnitFlags.silenced
            | UnitFlags.pacified | UnitFlags.disarmed);
        if (stunned)
            flagged |= UnitFlags.stunned;
        if (auras.has(AuraType.modFear) || (ai !is null && ai.fleeingAtLowHealth))
            flagged |= UnitFlags.fleeing;
        if (auras.has(AuraType.modConfuse))
            flagged |= UnitFlags.confused;
        if (auras.has(AuraType.modSilence))
            flagged |= UnitFlags.silenced;
        if (auras.has(AuraType.modPacify))
            flagged |= UnitFlags.pacified;
        if (auras.has(AuraType.modDisarm))
            flagged |= UnitFlags.disarmed;
        // As a stun, fear or disorientation begins its cast stops; a silence stops a spell it prevents.
        if (ai !is null)
        {
            enum uint stopsAll = UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused;
            if ((flagged & stopsAll) & ~(flags & stopsAll))
                ai.crowdControlBegan(false);
            else if ((flagged & UnitFlags.silenced) && !(flags & UnitFlags.silenced))
                ai.crowdControlBegan(true);
        }
        if (flagged != flags)
        {
            values.set!UNIT_FIELD_FLAGS(flagged);
            if (auto combat = cast(CombatWorld) world)
                combat.flushCreature(this);
        }
        if (held == auraHeld)
            return;
        auraHeld = held;
        if (held)
            stopMoving(this, world);
        ByteWriter w;
        w.putPackedGuid(guid);
        world.sendToObservers(guid, held ? Opcode.SMSG_SPLINE_MOVE_ROOT : Opcode.SMSG_SPLINE_MOVE_UNROOT, w.data);
    }

    /**
     * It becomes a creature of template `t` (a script's doing): its look, faction, flags, speeds and its
     * stats at its level are the new entry's; it keeps its guid, place, fight and its health's share.
     */
    void changeEntry(const(CreatureTemplate)* t, uint display, const ref CreatureParts parts, const ClientData client)
    {
        const maxHealth = values.get!UNIT_FIELD_MAXHEALTH;
        const share = maxHealth ? float(values.get!UNIT_FIELD_HEALTH) / maxHealth : 1.0f;
        enum uint kept = UnitFlags.inCombat | UnitFlags.pvp | UnitFlags.stunned | UnitFlags.swimming;
        const flags = values.get!UNIT_FIELD_FLAGS & kept;
        const level = values.get!UNIT_FIELD_LEVEL;
        template_ = t;
        setFields(display, level, parts, client);
        values.set!UNIT_FIELD_FLAGS(values.get!UNIT_FIELD_FLAGS | flags);
        const health = cast(uint)(values.get!UNIT_FIELD_MAXHEALTH * share);
        values.set!UNIT_FIELD_HEALTH(health ? health : 1);
        factionTemplate = client.factionTemplates.lookup(t.faction);
        speeds[MoveType.walk] = baseMoveSpeed[MoveType.walk] * t.speedWalk * auraSpeedFactor;
        speeds[MoveType.run] = baseMoveSpeed[MoveType.run] * t.speedRun * auraSpeedFactor;
    }

    /// Its aura goes (it ran out, was dispelled or cancelled, or a script took it away): its script hears of it.
    void loseAura(Aura aura, CombatWorld world)
    {
        auras.remove(aura, values);
        if (ai !is null)
            ai.auraLost(aura.caster, aura.spell.id, world);
        if (auto caster = world.unit(aura.caster)) // its caster's class rules (Wyvern Sting's poison as it wakes)
            caster.auraEndedOn(this, aura);
    }

    /// Its auras' time passes: their casters do what their ticks do; those that ended go.
    void updateAuras(CombatWorld world, int diff)
    {
        AuraTick[] ticks;
        Aura[] expired;
        auras.update(diff, ticks, expired);
        foreach (tick; ticks)
        {
            if (!alive)
                break;
            if (auto caster = world.unit(tick.aura.caster))
                caster.auraTick(this, tick.aura, tick.effect);
        }
        foreach (aura; expired)
            loseAura(aura, world);
        if (expired.length)
            world.flushCreature(this);
    }

    /// Someone looks into its loot; the corpse lasts two minutes more at least.
    void inspectingLoot()
    {
        enum int minimumLootingTime = 2 * 60 * 1000;
        if (corpseTimer < minimumLootingTime)
            corpseTimer = minimumLootingTime;
    }

    /// Nothing left in its loot; it goes within two minutes.
    void lootedOut()
    {
        enum int minimumLootingTime = 2 * 60 * 1000;
        loot = null;
        // A creature with a skin to take is skinnable now; its corpse stays its full time for that.
        if (template_.skinningLootId && !skinned)
        {
            values.set!UNIT_FIELD_FLAGS(values.get!UNIT_FIELD_FLAGS | unitFlagSkinnable);
            return;
        }
        if (corpseTimer > minimumLootingTime)
            corpseTimer = minimumLootingTime;
    }

    /// `UNIT_FLAG_SKINNABLE`: looted, and its skin is still on.
    enum uint unitFlagSkinnable = 0x04000000;

    /// Its skin was taken (cast at): the corpse goes once that loot is gone.
    bool skinned;

    /// Its pockets were emptied; they fill again at `pocketsRestockAt` (Unix time).
    bool pocketsEmptied;
    long pocketsRestockAt; /// ditto

    /// Whether it may be skinned now: dead, looted, with its skin still on.
    @property bool skinnable() const
    {
        return !alive && (values.get!UNIT_FIELD_FLAGS & unitFlagSkinnable) != 0;
    }

    /// The skill a skin of it takes: herbalism or mining for those `CreatureTypeFlags` says, else skinning.
    @property uint skinningSkill() const
    {
        enum uint skinWithHerbalism = 0x100, skinWithMining = 0x200;
        enum uint herbalism = 182, mining = 186, skinning = 393;
        return template_.typeFlags & skinWithHerbalism ? herbalism : template_.typeFlags & skinWithMining ? mining
            : skinning;
    }

    /// Its fighting mind (`dmangos.world.creatureai`).
    CreatureAI ai;

    /// The client data (factions, for its relations), and its faction template (null if unknown).
    const ClientData client;
    const(FactionTemplateEntry)* factionTemplate;

    /// It has health left.
    @property bool alive() const
    {
        return values.get!UNIT_FIELD_HEALTH > 0;
    }

    /// What the melee formulas (`dmangos.world.combat`) need of it now.
    Fighter fighter() const
    {
        enum uint noParry = 0x04, noBlock = 0x10; // `extra_flags`: never parries, never blocks
        enum uint rankWorldBoss = 3;              // the world boss rank
        Fighter f;
        f.guid = guid_;
        f.worldBoss = template_.rank == rankWorldBoss;
        f.level = values.get!UNIT_FIELD_LEVEL;
        f.position = movement.position;
        f.combatReach = values.get!UNIT_FIELD_COMBATREACH;
        f.runningAround = !spline.finalized && !(movement.flags & MovementFlags.walkMode);
        f.alive = alive;
        f.standing = values.getByte!UNIT_FIELD_BYTES_1(0) == 0;
        f.damage = [[values.get!UNIT_FIELD_MINDAMAGE, values.get!UNIT_FIELD_MAXDAMAGE],
            [values.get!UNIT_FIELD_MINOFFHANDDAMAGE, values.get!UNIT_FIELD_MAXOFFHANDDAMAGE],
            [values.get!UNIT_FIELD_MINRANGEDDAMAGE, values.get!UNIT_FIELD_MAXRANGEDDAMAGE]];
        // A hunter's pet hits by its mood (its happiness, the fourth power).
        {
            import dmangos.world.pet : PetState, PetType;
            import dmangos.world.pethandlers : moodDamageFactor;

            if (const pet = petData)
                if (pet.type == PetType.hunter)
                {
                    const factor = moodDamageFactor(values.get!UNIT_FIELD_POWER1(4));
                    f.damage[0][0] *= factor;
                    f.damage[0][1] *= factor;
                }
        }
        f.damageSchool[] = template_.damageSchool;
        f.creatureType = template_.creatureType;
        {
            import dmangos.world.combat : AttackType, DamageMods;

            if (auras.list.length) // its own auras: an enrage's damage, a curse's damage taken; stealth
            {
                import dmangos.world.spellids : AuraType;

                DamageMods.of(auras, (ubyte) => -1, (AttackType) => uint(template_.damageSchool)).into(f);
                f.stealthed = auras.hasType(AuraType.modStealth);
                if (f.stealthed)
                    f.stealth = auras.total(AuraType.modStealth) + auras.total(AuraType.modStealthLevel);
                f.stealthDetect = auras.totalByMisc(AuraType.modStealthDetect, 0);
            }
            import dmangos.world.combat : Immunities;

            if (auras.list.length || template_.mechanicImmuneMask || template_.schoolImmuneMask)
                f.immune = Immunities.of(auras, template_.mechanicImmuneMask, template_.schoolImmuneMask);
        }
        // Crit, dodge, parry and block chances: 5% each for creatures.
        f.crit = f.dodge = f.parry = f.block = 5;
        f.canParry = !(template_.extraFlags & noParry);
        f.canBlock = !(template_.extraFlags & noBlock);
        f.armor = values.get!UNIT_FIELD_RESISTANCES(0);
        f.evading = ai !is null && ai.evading;
        return f;
    }

    /**
     * Takes `damage` from its health. Returns whether that killed it;
     * the caller then lets it die (`die`).
     */
    bool takeDamage(uint damage)
    {
        const health = values.get!UNIT_FIELD_HEALTH;
        // Death prevention: its script keeps it at 1 health.
        if (health <= damage && ai !is null && ai.deathPrevention)
        {
            values.set!UNIT_FIELD_HEALTH(1u);
            return false;
        }
        if (health <= damage)
        {
            values.set!UNIT_FIELD_HEALTH(0u);
            return true;
        }
        values.set!UNIT_FIELD_HEALTH(health - damage);
        return false;
    }

    /**
     * It has just died, as far as there is death yet: it stops where it is and
     * moves no more; its corpse stays (despawning, respawning and loot come with death proper).
     */
    void die(MotionWorld world, long now)
    {
        import std.random : uniform;
        import dmangos.world.motion : IdleMovement, stopMoving;

        // Its corpse lasts by its rank, at most 90% of its
        // respawn time (random between the spawn's two), which counts from now; it no longer offers its services.
        static immutable uint[5] decayByRank = [60, 300, 300, 3600, 300]; // normal, elite, rare elite, boss, rare
        const respawnDelay = spawn.respawnSecondsMax > spawn.respawnSeconds
            ? uniform!"[]"(spawn.respawnSeconds, spawn.respawnSecondsMax) : spawn.respawnSeconds;
        uint decay = decayByRank[template_.rank < decayByRank.length ? template_.rank : 0];
        if (decay > respawnDelay * 9 / 10)
            decay = respawnDelay * 9 / 10;
        corpseTimer = decay * 1000;
        respawnAt = now + respawnDelay;
        foreach (aura; auras.list.dup) // every aura goes on death
        {
            auras.remove(aura, values);
            if (auto combat = cast(CombatWorld) world) // its caster hears of it (a Soul Shard from Drain Soul)
                if (auto caster = combat.unit(aura.caster))
                    caster.auraEndedOn(this, aura);
        }
        values.set!UNIT_NPC_FLAGS(0u);
        stopMoving(this, world);
        generator = new IdleMovement;
        attackers = null;
        values.set!UNIT_FIELD_TARGET(0UL);
        values.set!UNIT_FIELD_FLAGS(values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
        if (ai !is null)
            ai.died(cast(CombatWorld) world);
    }

    /**
     * Movement on each tick: follows the walk under way, then lets the movement generator
     * decide, starting it on the first tick.
     */
    void tick(MotionWorld world, int diff)
    {
        if (!motionStarted)
        {
            motionStarted = true;
            generator.initialize(this, world);
        }
        if (summon.type != TempSpawnType.none && summon.update(this, diff))
        {
            if (auto combat = cast(CombatWorld) world)
            {
                // Eastern Kingdoms scripts: alive, its summoner's script hears it went.
                if (alive && summon.summoner)
                    if (auto summoner = combat.creatureAt(summon.summoner))
                        if (summoner.ai !is null)
                            summoner.ai.summonedGone(combat, guid);
                combat.corpseExpired(this); // its summoned time is up: it goes
            }
            return;
        }
        if (!alive)
        {
            // A corpse: rolls on its loot end; when its time is up it goes.
            if (loot !is null)
                loot.update();
            corpseTimer -= diff;
            if (corpseTimer <= 0)
                if (auto combat = cast(CombatWorld) world)
                    combat.corpseExpired(this);
            return;
        }
        if (auras.list.length)
            if (auto combat = cast(CombatWorld) world)
                updateAuras(combat, diff);
        if (!alive)
            return;
        enum uint crowdControlFlags = UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused | UnitFlags.silenced
            | UnitFlags.pacified | UnitFlags.disarmed;
        if (auras.list.length || auraHeld || auraSpeedFactor != 1 || (values.get!UNIT_FIELD_FLAGS & crowdControlFlags))
            refreshAuraMovement(world);
        if (ai !is null)
            if (auto combat = cast(CombatWorld) world)
                ai.update(combat, diff);
        followSpline(this, diff);
        generator.update(this, world, diff);
    }

    /// What a create block shows of it: a unit with its movement, its walk and public fields.
    UpdateData appearance(uint serverTime) const
    {
        UpdateData update;
        const block = motion(serverTime);
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }

    /**
     * See `Idler.idleFor`: alive, standing, without auras, timers or anything for its AI to do, it
     * only waits for its movement generator's next step; a corpse without loot only waits to go.
     */
    @property int idleFor() const
    {
        if (!motionStarted)
            return 0;
        if (!alive)
            return loot is null && corpseTimer > 0 ? corpseTimer : 0;
        if (summon.timed || auras.list.length || !spline.finalized || (ai !is null && ai.active))
            return 0;
        return generator.idleFor(this);
    }

    /// See `Moving.resting`: idle, standing, and started (a creature needs its first tick).
    @property bool resting() const
    {
        import dmangos.world.motion : IdleMovement;

        return motionStarted && spline.finalized && cast(const IdleMovement) generator !is null
            && (ai is null || !ai.active) && alive && auras.list.length == 0 && !summon.timed;
    }

    /// See `Replicable.motion`: living, with its speeds and the walk under way.
    MovementBlock motion(uint serverTime) const
    {
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
        block.info = movement;
        block.info.time = serverTime;
        block.speeds = speeds;
        block.spline = &spline;
        return block;
    }

    /**
     * Writes everything about the creature that changes once it exists, for its next owner to go on
     * with (docs/CLUSTER.md): every field, its movement and walk, its movement generator's
     * state and its vendor stock.
     */
    void saveState(ref ByteWriter w) const
    {
        w.put(cast(ushort) values.length);
        foreach (slot; 0 .. values.length)
            w.put(values[slot]);
        movement.write(w);
        foreach (speed; speeds)
            w.put(speed);
        spline.writeExact(w);
        w.put(positionTimer);
        w.put(motionStarted);
        w.put(cast(ubyte) generator.type);
        ByteWriter state;
        generator.save(state);
        w.put(cast(ushort) state.length);
        w.putBytes(state.data);
        w.put(cast(ushort) vendorStock.items.length);
        foreach (item, stock; vendorStock.items)
        {
            w.put(item);
            w.put(stock.count);
            w.put(stock.lastIncrement);
        }
        (cast() ai).saveBehaviour(w); // its script's state (docs/SCRIPTING.md)
    }

    /**
     * Reads what `saveState` wrote into a creature made anew from the same spawn (whose generator was
     * chosen as for any spawn): it is then the creature its last owner had, where it had it.
     */
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
        movement = MovementInfo.read(r);
        foreach (ref speed; speeds)
            speed = r.read!float;
        spline = MoveSpline.readExact(r);
        positionTimer = r.read!int;
        motionStarted = r.read!bool;
        const type = r.read!ubyte;
        auto state = ByteReader(r.readBytes(r.read!ushort));
        if (type == generator.type)
            generator.load(state);
        else if (type == MotionType.follow) // a linked creature following its master
        {
            import dmangos.world.motion : FollowMovement;

            auto follower = new FollowMovement(0, 0, 0);
            follower.load(state);
            generator = follower;
        }
        vendorStock.items = null;
        foreach (_; 0 .. r.read!ushort)
        {
            const item = r.read!uint;
            vendorStock.items[item] = VendorStocks.Stock(r.read!uint, r.read!long);
        }
        ai.loadBehaviour(r);
        // A corpse handed over: its time is not carried; it goes at the next tick, and respawns from then.
        corpseTimer = 0;
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

        // Class, gender, power type, model.
        enum : ubyte { powerMana = 0, powerRage = 1, powerEnergy = 3 }
        const powerType = t.unitClass == 1 ? powerRage : t.unitClass == 4 ? powerEnergy : powerMana;
        values.set!UNIT_FIELD_BYTES_0(uint(t.unitClass) << 8 | uint(parts.gender) << 16 | uint(powerType) << 24);
        values.set!UNIT_FIELD_DISPLAYID(display);
        values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        values.set!UNIT_FIELD_BOUNDINGRADIUS(parts.boundingRadius * scale);
        values.set!UNIT_FIELD_COMBATREACH(parts.combatReach * scale);
        values.set!UNIT_MOD_CAST_SPEED(1.0f);

        // Health, mana, armor, attack power and damage from the class stats, or the template's.
        values.set!UNIT_FIELD_LEVEL(level);
        const combat = selectLevel(*t, level, parts.hasClassStats ? &parts.classStats : null);
        const health = combat.health, mana = combat.mana;
        values.set!UNIT_FIELD_RESISTANCES(0, cast(uint) combat.armor);
        foreach (uint school; 1 .. 7)
            values.set!UNIT_FIELD_RESISTANCES(school, cast(uint) t.resistance(school));
        values.set!UNIT_FIELD_ATTACK_POWER(cast(int) combat.meleeAttackPower);
        values.set!UNIT_FIELD_RANGED_ATTACK_POWER(cast(int) combat.rangedAttackPower);
        values.set!UNIT_FIELD_MINDAMAGE(combat.damage[0][0]);
        values.set!UNIT_FIELD_MAXDAMAGE(combat.damage[0][1]);
        values.set!UNIT_FIELD_MINOFFHANDDAMAGE(combat.damage[1][0]);
        values.set!UNIT_FIELD_MAXOFFHANDDAMAGE(combat.damage[1][1]);
        values.set!UNIT_FIELD_MINRANGEDDAMAGE(combat.damage[2][0]);
        values.set!UNIT_FIELD_MAXRANGEDDAMAGE(combat.damage[2][1]);
        values.set!UNIT_FIELD_HEALTH(health);
        values.set!UNIT_FIELD_MAXHEALTH(health);
        values.set!UNIT_FIELD_POWER1(0, mana);
        values.set!UNIT_FIELD_MAXPOWER1(0, mana);
        values.set!UNIT_FIELD_MAXPOWER1(1, 1000u); // rage
        values.set!UNIT_FIELD_MAXPOWER1(3, 100u);  // energy
        values.set!UNIT_FIELD_POWER1(3, 100u);

        // Faction, flags, attack times.
        values.set!UNIT_FIELD_FACTIONTEMPLATE(t.faction);
        values.set!UNIT_NPC_FLAGS(t.npcFlags);
        values.set!UNIT_FIELD_FLAGS(t.unitFlags);
        values.set!UNIT_DYNAMIC_FLAGS(t.dynamicFlags);
        values.set!UNIT_FIELD_BASEATTACKTIME(t.meleeBaseAttackTime);
        values.set!UNIT_FIELD_BASEATTACKTIME(1, t.meleeBaseAttackTime);
        values.set!UNIT_FIELD_RANGEDATTACKTIME(t.rangedBaseAttackTime);
        values.setByte!UNIT_FIELD_BYTES_2(0, cast(ubyte) sheathMelee);
        values.setByte!UNIT_FIELD_BYTES_2(1, cast(ubyte) unitByte2FlagAuras);

        // What it holds.
        foreach (slot, ref item; parts.equipment)
            if (item.display)
                setVirtualItem(slot, item);

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

/// One of the template's models, each as likely.
uint chooseDisplay(const ref CreatureTemplate t, ref Random rng)
{
    uint[4] models;
    size_t count;
    foreach (model; t.modelIds)
        if (model)
            models[count++] = model;
    return count ? models[uniform(0, count, rng)] : 0;
}

/// The level: between the template's minimum and maximum.
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
    parts.classStats = CreatureClassStats(74, 0, 10.5f, 30, 4, 400);
    parts.hasClassStats = true;
    const spawn = CreatureSpawn(89, 448, 0, -9726, 1019, 45, 1.5f);
    auto creature = new Creature(spawn, &hogger, 384, 11, parts, testClientData());
    assert(highGuidOf(creature.guid) == HighGuid.unit && counterOf(creature.guid) == 89);
    assert(creature.values[OBJECT_FIELD_ENTRY] == 448 && creature.values[UNIT_FIELD_MAXHEALTH] == 222);
    // The combat numbers: armor 400, attack power 30; damage over its 2 s swing:
    // ((10.5 + 30 / 14) * 2) plus the attack power's 30 * 2 / 14 again (physical damage), up to 1.5 times the base.
    assert(creature.values[UNIT_FIELD_RESISTANCES] == 400 && creature.values.get!UNIT_FIELD_ATTACK_POWER == 30);
    const minDamage = creature.values.get!UNIT_FIELD_MINDAMAGE, maxDamage = creature.values.get!UNIT_FIELD_MAXDAMAGE;
    assert(minDamage > 29.56f && minDamage < 29.58f && maxDamage > 40.06f && maxDamage < 40.08f);
    assert(creature.values.get!UNIT_FIELD_MINOFFHANDDAMAGE > 14.78f, "the off hand: half");
    assert(creature.values[UNIT_NPC_FLAGS] == 2);
    assert(creature.values.getByte!UNIT_FIELD_BYTES_0(3) == 1, "a warrior uses rage");
    assert(creature.speeds[MoveType.run] > 7.9f && creature.appearance(0).blockCount == 1);
}
