/**
 * A character in the world: what `Player::LoadFromDB` reads, the player
 * and item objects built from it, and what logging out saves.
 *
 * `Player` fills the update fields as CMaNGOS does on login
 * (`Player::LoadFromDB`, `InitStatsForLevel`, `_LoadInventory`,
 * `_LoadSkills`, `InitDisplayIds`), with the derived numbers from
 * `dmangos.world.stats`. The client draws the character, its gear, bags,
 * skills and spellbook from these fields and from the packets of
 * `Player::SendInitialPacketsBeforeAddToMap`, which `WorldSession` sends.
 *
 * Not loaded yet: auras, quests, reputation, guild membership, pets and
 * corpses. A dead character (health 0) is loaded alive with full health.
 */
module dmangos.world.player;

import std.algorithm.comparison : max, min;
import std.algorithm.iteration : sum;
import std.algorithm.searching : canFind, find;
import std.array : split;
import std.conv : ConvException, to;

import dmangos.auth.accounts : AccountLevel;
import dmangos.log;
import dmangos.world.clientdata : ClientData, maskOf, skillFlagMaximized;
import dmangos.world.movement;
import dmangos.world.objects;
import dmangos.world.opcodes : ChatTag;
import dmangos.world.packets : ServerLevelUpInfo;
import dmangos.world.defines;
import dmangos.world.playercreate : KnownAbilities, KnownSkill, NewSkill, NewSpell;
import dmangos.world.spells : SpellEffect;
import dmangos.world.stats;
import dmangos.world.updatefields;
import dmangos.world.worlddata : CreateAction, ItemTemplate, maxLevel, WorldData;

/// Number of `character_tutorial` fields.
enum tutorialFields = 8;

/// One `character_inventory` row joined with its `item_instance`.
struct ItemRecord
{
    uint bag;          /// the low guid of the bag it is in; 0 for the character's own slots
    ubyte slot;
    uint guid;
    uint entry;
    uint creator;
    uint giftCreator;
    uint count;
    uint duration;
    string charges;      /// five numbers
    uint flags;
    string enchantments; /// 21 numbers
    int randomPropertyId;
    uint durability;
    uint textId;
}

/// `character_homebind`
struct HomeBind
{
    uint map;
    uint zone;
    float x = 0;
    float y = 0;
    float z = 0;
}

/// What logging a character in reads from the characters database.
struct CharacterData
{
    uint guid;
    uint account;
    string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    uint level;
    uint xp;
    uint money;
    uint playerBytes;
    uint playerBytes2;
    uint playerFlags;
    Position position;
    uint map;
    uint zone;
    uint cinematic;
    uint totalTime;      /// seconds played
    uint levelTime;      /// seconds played at this level
    uint atLogin;
    uint watchedFaction;
    uint health;
    uint[5] power;
    string exploredZones;
    uint ammoId;
    ubyte actionBars;

    ItemRecord[] items;
    NewSkill[] skills;
    NewSpell[] spells;
    CreateAction[] actions;
    bool hasHomeBind;
    HomeBind homeBind;
    uint[tutorialFields] tutorials;
    bool[uint] rewardedQuests;   /// `character_queststatus` rows with `rewarded` set
    float restBonus = 0;         /// `rest_bonus`: rested XP
    long logoutTime;             /// `logout_time`, Unix time
    bool logoutResting;          /// `is_logout_resting`: logged out in an inn or a city
}

/// What logging out writes back (`Player::SaveToDB`, the fields that can change in the world so far).
struct CharacterProgress
{
    uint guid;
    Position position;
    uint map;
    uint zone;
    uint totalTime;
    uint levelTime;
    uint health;
    uint[5] power;
    ubyte actionBars;
    uint cinematic;
    uint atLogin;
    uint level;
    uint xp;
    uint money;
    string exploredZones; /// 64 numbers
    float restBonus = 0;
    bool resting;         /// `is_logout_resting`
}

/// An item object the player owns.
struct InventoryItem
{
    uint guid;
    uint bag;  /// low guid of the containing bag, 0 for the player's own slots
    ubyte slot;
    const(ItemTemplate)* template_;
    UpdateValues values;

    /// An item or a container.
    @property TypeId typeId() const pure nothrow @nogc @safe
    {
        return values.type;
    }

    /// The full guid.
    @property ulong fullGuid() const pure nothrow @nogc @safe
    {
        return makeGuid(HighGuid.item, guid);
    }
}

/// Who looks at a player: the player itself, a member of its group, or anyone else.
enum Viewer
{
    self,
    groupMate,
    stranger,
}

/// A packed `SMSG_ACTION_BUTTONS` entry: the action in the low 24 bits, the type above.
uint packActionButton(uint action, ubyte type) pure nothrow @nogc @safe
{
    return (action & 0x00FF_FFFF) | uint(type) << 24;
}

/// `PlayerFlags` that change in the world.
enum PlayerFlags : uint
{
    groupLeader = 0x01,
    afk = 0x02,
    dnd = 0x04,
    gm = 0x08,
    resting = 0x20,
}

/// `RestType`: why a player is resting.
enum RestType
{
    none,
    tavern, /// inside an inn's area trigger
    city,   /// in a capital
}

private enum : uint
{
    unitFlagPlayerControlled = 0x00000008,
    unitByte2FlagSupportable = 0x08,
    unitByte2FlagUnk5 = 0x20,
}

private enum float defaultBoundingRadius = 0.388999998569489f, defaultCombatReach = 1.5f;

/// See the module documentation.
final class Player
{
    CharacterData data;
    ulong guid;
    UpdateValues values;
    InventoryItem[] items;
    MovementInfo movement;
    PlayerStats stats;
    uint[] spells;                       /// active, enabled spells: the spellbook
    uint[maxActionButtons] actionButtons; /// packed, 0 = empty
    uint[2] proficiency;                 /// item sub-class masks for weapons and armor (`SMSG_SET_PROFICIENCY`)
    string autoReply;                    /// the AFK or DND message (`Player::autoReplyMsg`)
    /// ArcEmu's `Player::bGMTagOn`: the GM tag in chat (`.gm on`, `.gm whisperblock`)
    bool gmTagOn;

    /**
     * Builds the player from its database rows and the skills and spells
     * `CharacterBuilder.loadAbilities` worked out. Problems in the data are logged and skipped.
     */
    this(const ref CharacterData character, const ref KnownAbilities abilities, const WorldData world,
        const ClientData client)
    in (character.guid != 0, "guid 0 is no character")
    in (character.level > 0, "levels start at 1")
    out (; values.type == TypeId.player && !values.hasChanges, "a fresh player has nothing left to send")
    {
        data = cast(CharacterData) character;
        guid = makeGuid(HighGuid.player, character.guid);
        movement.position = character.position;
        values = UpdateValues(TypeId.player);

        loadItems(world);
        computeDerived(world);
        setPlayerFields(world, client);
        setSkills(abilities.skills);
        setSpells(abilities, world, client);
        foreach (action; character.actions)
            if (action.button < maxActionButtons && world.isActionButtonDataValid(action))
                actionButtons[action.button] = packActionButton(action.action, action.type);
        values.clearChanges();
        foreach (ref item; items)
            item.values.clearChanges();
    }

    /// The equipped item in `slot` (0 .. 18), or null.
    const(InventoryItem)* equipped(ubyte slot) const
    in (slot < equipmentSlotEnd)
    {
        auto found = items.find!(item => item.bag == 0 && item.slot == slot);
        return found.length ? &found[0] : null;
    }

    /// `Player::BuildCreateUpdateBlockForPlayer` for the player itself: its items, then the player.
    UpdateData createForSelf(uint serverTime) const
    {
        UpdateData update;
        MovementBlock itemMovement;
        itemMovement.flags = UpdateFlags.all;
        foreach (ref item; items)
            update.addCreate(UpdateType.createObject, item.fullGuid, itemMovement, item.values,
                seenBySelf | seenByOwner);

        MovementBlock self;
        self.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition | UpdateFlags.self;
        self.info = movement;
        self.info.time = serverTime;
        self.speeds = speeds;
        update.addCreate(UpdateType.createObject2, guid, self, values, seenBySelf);
        return update;
    }

    /// The create block of one of the player's items, for the player (an item it was just given).
    UpdateData createItemForSelf(uint itemGuid) const
    {
        UpdateData update;
        MovementBlock itemMovement;
        itemMovement.flags = UpdateFlags.all;
        foreach (ref item; items)
            if (item.guid == itemGuid)
                update.addCreate(UpdateType.createObject, item.fullGuid, itemMovement, item.values,
                    seenBySelf | seenByOwner);
        return update;
    }

    /**
     * The player as another player first sees it: no items and no private fields. A stranger sees
     * health in percent (`Visibility.FogOfWar.Health` 0); a group mate sees the real values and the
     * group-only fields.
     */
    UpdateData createForOthers(uint serverTime, bool groupMate) const
    {
        UpdateData update;
        MovementBlock other;
        other.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
        other.info = movement;
        other.info.time = serverTime;
        other.speeds = speeds;
        update.addCreate(UpdateType.createObject, guid, other, values, groupMate ? seenByGroup : seenByEveryone,
            groupMate ? null : &strangerValue);
        return update;
    }

    /// Adds a values block with the fields changed since `clearChanges` that `viewer` may see; false if none.
    bool addChanges(ref UpdateData update, Viewer viewer) const
    {
        const seen = seenBy(viewer);
        if (!values.hasChangesFor(seen))
            return false;
        update.addValues(guid, values, seen, viewer == Viewer.stranger ? &strangerValue : null);
        return true;
    }

    /**
     * `Group::_updateMembersOnRosterChanged`: health, maximum health and the group-only fields as
     * `viewer` should now see them, for a player who joined or left the viewer's group.
     */
    UpdateData groupView(Viewer viewer) const
    in (viewer != Viewer.self)
    {
        size_t[] slots = [size_t(UNIT_FIELD_HEALTH), size_t(UNIT_FIELD_MAXHEALTH)];
        if (viewer == Viewer.groupMate)
            slots ~= values.slotsOnlyFor(seenByGroup);
        UpdateData update;
        update.addSlots(guid, values, slots, viewer == Viewer.stranger ? &strangerValue : null);
        return update;
    }

    /// The fields `viewer` sees.
    static Visibility seenBy(Viewer viewer) pure nothrow @nogc @safe
    {
        final switch (viewer)
        {
        case Viewer.self:
            return seenBySelf;
        case Viewer.groupMate:
            return seenByGroup;
        case Viewer.stranger:
            return seenByEveryone;
        }
    }

    /// Forgets the changes once every viewer has been told.
    void clearChanges()
    {
        values.clearChanges();
    }

    /// The player's position.
    @property Position position() const pure nothrow @nogc @safe
    {
        return movement.position;
    }

    /// `Unit::SetStandState`
    void setStandState(ubyte state)
    {
        values.setByte!UNIT_FIELD_BYTES_1(0, state);
    }

    /// `Unit::SetTargetGuid`: whom the player has selected; 0 for nobody.
    void setTarget(ulong target)
    {
        values.set!UNIT_FIELD_TARGET(target);
    }

    /// `Unit::HandleEmoteState`: a looping emote (dancing, ...) or 0.
    void setEmoteState(uint emote)
    {
        values.set!UNIT_NPC_EMOTESTATE(emote);
    }

    /// The power the class uses (`Unit::GetPowerType`).
    @property Power powerType() const
    {
        return cast(Power) values.getByte!UNIT_FIELD_BYTES_0(3);
    }

    /// `Player::HasItemCount`: carried or equipped, not in the bank.
    bool hasItem(uint entry, uint count = 1) const
    {
        return itemCount(entry) >= count;
    }

    /// The player's slot holding the bag with this low guid.
    private ubyte bagSlotOf(uint bagGuid) const
    {
        foreach (ref item; items)
            if (item.guid == bagGuid)
                return item.slot;
        return ubyte.max;
    }

    /// Whether a `PlayerFlags` flag is set.
    bool hasFlag(PlayerFlags flag) const
    {
        return (values.get!PLAYER_FLAGS & flag) != 0;
    }

    /// Sets or clears a `PlayerFlags` flag.
    void setFlag(PlayerFlags flag, bool on)
    {
        const flags = values.get!PLAYER_FLAGS;
        values.set!PLAYER_FLAGS(on ? flags | flag : flags & ~flag);
    }

    /// `Player::GetChatTag`
    @property ChatTag chatTag() const
    {
        if (gmTagOn)
            return ChatTag.CHAT_TAG_GM;
        if (hasFlag(PlayerFlags.afk))
            return ChatTag.CHAT_TAG_AFK;
        if (hasFlag(PlayerFlags.dnd))
            return ChatTag.CHAT_TAG_DND;
        return ChatTag.CHAT_TAG_NONE;
    }

    /// `Object::BuildValuesUpdate` for a viewer outside the group: health in percent of 100.
    uint strangerValue(size_t slot, uint value) const
    {
        import std.math : ceil;

        if (slot == UNIT_FIELD_HEALTH)
        {
            const maximum = values.get!UNIT_FIELD_MAXHEALTH;
            return maximum ? cast(uint) ceil(100.0 * value / maximum) : 0;
        }
        return slot == UNIT_FIELD_MAXHEALTH ? 100 : value;
    }

    /// What logging out saves, with `secondsInWorld` added to the played time.
    CharacterProgress progress(uint secondsInWorld) const
    {
        CharacterProgress p;
        p.guid = data.guid;
        p.position = movement.position;
        p.map = data.map;
        p.zone = data.zone;
        p.totalTime = data.totalTime + secondsInWorld;
        p.levelTime = data.levelTime + secondsInWorld;
        p.health = values[UNIT_FIELD_HEALTH];
        foreach (i; 0 .. maxPowers)
            p.power[i] = values[UNIT_FIELD_POWER1 + i];
        p.actionBars = values.getByte!PLAYER_FIELD_BYTES(2);
        p.cinematic = data.cinematic;
        p.atLogin = data.atLogin;
        p.level = data.level;
        p.xp = values[PLAYER_XP];
        p.money = values[PLAYER_FIELD_COINAGE];
        p.exploredZones = exploredZonesText();
        p.restBonus = restBonus;
        p.resting = hasFlag(PlayerFlags.resting);
        return p;
    }

    /// `PLAYER_EXPLORED_ZONES_1`, as `characters.exploredZones` stores it.
    string exploredZonesText() const
    {
        import std.algorithm.iteration : map;
        import std.array : join;

        uint[exploredZonesSize] zones;
        foreach (i, ref zone; zones)
            zone = values.get!PLAYER_EXPLORED_ZONES_1(i);
        return zones[].map!(z => z.to!string).join(" ") ~ " ";
    }

    // -----------------------------------------------------------------------
    // Regeneration and rest (Player::RegenerateAll, SetRestBonus, ComputeRest)
    // -----------------------------------------------------------------------

    /// Rested XP: the bonus left, why the player rests, and since when it has been counted.
    float restBonus = 0;
    RestType restType; /// ditto
    uint innTrigger;   /// the inn's area trigger, while resting in it
    long restCountedAt; /// Unix time

    /// `Unit::OCTRegenHPPerSpirit`: health per second out of combat, from spirit and class.
    float healthRegenPerSecond() const
    {
        const spirit = float(values.get!UNIT_FIELD_STAT0(Stat.spirit));
        switch (cast(PlayerClass) data.classId)
        {
        default: return 0;
        case PlayerClass.druid: return spirit * 0.11f + 1;
        case PlayerClass.hunter: return spirit * 0.43f - 5.5f;
        case PlayerClass.mage: return spirit * 0.11f + 1;
        case PlayerClass.paladin: return spirit * 0.25f;
        case PlayerClass.priest: return spirit * 0.15f + 1.4f;
        case PlayerClass.rogue: return spirit * 0.84f - 13;
        case PlayerClass.shaman: return spirit * 0.28f - 3.6f;
        case PlayerClass.warlock: return spirit * 0.12f + 1.5f;
        case PlayerClass.warrior: return spirit * 1.26f - 22.6f;
        }
    }

    /// `Unit::OCTRegenMPPerSpirit`: mana per second, from spirit and class.
    float manaRegenPerSecond() const
    {
        const spirit = float(values.get!UNIT_FIELD_STAT0(Stat.spirit));
        float perTick;
        switch (cast(PlayerClass) data.classId)
        {
        case PlayerClass.druid, PlayerClass.hunter, PlayerClass.paladin, PlayerClass.warlock:
            perTick = spirit / 5 + 15;
            break;
        case PlayerClass.mage, PlayerClass.priest:
            perTick = spirit / 4 + 12.5f;
            break;
        case PlayerClass.shaman:
            perTick = spirit / 5 + 17;
            break;
        default:
            perTick = 0;
            break;
        }
        return perTick / 2; // the values above are per two-second tick
    }

    /**
     * `Player::RegenerateAll` for `milliseconds` out of combat: health (half again as fast sitting),
     * mana, energy, and rage decaying. Returns whether anything changed.
     */
    bool regenerate(uint milliseconds, float healthRate, float manaRate, float rageLoss, float energyRate)
    {
        bool changed;
        const health = values.get!UNIT_FIELD_HEALTH, maxHealth = values.get!UNIT_FIELD_MAXHEALTH;
        if (health < maxHealth && health > 0)
        {
            float add = max(0, healthRegenPerSecond() * healthRate);
            if (values.getByte!UNIT_FIELD_BYTES_1(0) != 0)
                add *= 1.5f; // not standing
            const gained = cast(uint)(add * milliseconds / 1000);
            if (gained)
            {
                values.set!UNIT_FIELD_HEALTH(min(health + gained, maxHealth));
                changed = true;
            }
        }
        changed |= addPower(Power.mana, cast(int)(manaRegenPerSecond() * manaRate * (milliseconds / 1000)));
        changed |= addPower(Power.energy, cast(int)((milliseconds / 100) * energyRate));
        changed |= addPower(Power.rage, -cast(int)((milliseconds / 200) * 2.5f * rageLoss));
        return changed;
    }

    /// Adds (or takes) power, within 0 and the maximum. Returns whether it changed.
    private bool addPower(Power power, int amount)
    {
        const now = values.get!UNIT_FIELD_POWER1(power), maximum = values.get!UNIT_FIELD_MAXPOWER1(power);
        const next = cast(uint) (amount < 0 ? (now > -amount ? now + amount : 0) : min(now + amount, maximum));
        if (next == now)
            return false;
        values.set!UNIT_FIELD_POWER1(power, next);
        return true;
    }

    /// `Player::SetRestBonus`: at most one and a half levels, shown as "rested" over 10.
    void setRestBonus(float bonus, uint maxPlayerLevel)
    {
        if (data.level >= maxPlayerLevel || bonus < 0)
            bonus = 0;
        const maximum = values.get!PLAYER_NEXT_LEVEL_XP * 1.5f / 2;
        restBonus = bonus > maximum ? maximum : bonus;
        if (restBonus > 10)
            values.setByte!PLAYER_BYTES_2(3, RestState.rested);
        else if (restBonus <= 1)
            values.setByte!PLAYER_BYTES_2(3, RestState.normal);
        values.set!PLAYER_REST_STATE_EXPERIENCE(cast(uint) restBonus);
    }

    /// `Player::ComputeRest`: the rested XP of `seconds`; a full level takes 1152000 s (13.3 days) at rate 1.
    float computeRest(long seconds, float rate) const
    {
        return seconds * (values.get!PLAYER_NEXT_LEVEL_XP / 1_152_000.0f) * rate;
    }

    /// `Player::SetRestType`
    void setRestType(RestType type, long now, uint trigger = 0)
    {
        restType = type;
        setFlag(PlayerFlags.resting, type != RestType.none);
        if (type != RestType.none)
        {
            innTrigger = trigger;
            restCountedAt = now;
        }
    }

    /// `Unit::SetStunned` for logging out: the stunned flag, and sitting down if standing.
    void setLogoutStun(bool on)
    {
        enum uint unitFlagStunned = 0x00040000; // UNIT_FLAG_STUNNED
        const flags = values.get!UNIT_FIELD_FLAGS;
        values.set!UNIT_FIELD_FLAGS(on ? flags | unitFlagStunned : flags & ~unitFlagStunned);
        if (on && values.getByte!UNIT_FIELD_BYTES_1(0) == 0)
            setStandState(1);
        else if (!on && values.getByte!UNIT_FIELD_BYTES_1(0) == 1)
            setStandState(0);
    }

    // -----------------------------------------------------------------------
    // What GM commands change
    // -----------------------------------------------------------------------

    /**
     * `Player::GiveLevel` and `InitStatsForLevel`: the stats of `level`, with full health and mana
     * and no XP. Returns what the level added (`SMSG_LEVELUP_INFO`).
     */
    ServerLevelUpInfo changeLevel(uint level, const WorldData world, const ClientData client)
    in (level >= 1 && level <= maxLevel)
    {
        const before = world.classStats(data.classId, data.level), beforeStats = world.levelStats(data.race,
            data.classId, data.level);
        const earnedBefore = talentPointsForLevel(data.level);
        const spentTalents = earnedBefore - min(earnedBefore, values[PLAYER_CHARACTER_POINTS1]);
        const xp = data.level == level ? values[PLAYER_XP] : 0;

        data.level = level;
        data.health = 0;              // full
        data.power[Power.mana] = uint.max; // full; rage and energy keep what they have
        data.xp = xp;
        data.money = values[PLAYER_FIELD_COINAGE];
        data.exploredZones = exploredZonesText();
        computeDerived(world);
        setPlayerFields(world, client);
        const earned = talentPointsForLevel(level);
        values.set!PLAYER_CHARACTER_POINTS1(earned > spentTalents ? earned - spentTalents : 0);

        const after = world.classStats(data.classId, level),
            afterStats = world.levelStats(data.race, data.classId, level);
        ServerLevelUpInfo info;
        info.level = level;
        info.health = after.baseHealth - before.baseHealth;
        info.powers[0] = after.baseMana - before.baseMana;
        foreach (i; 0 .. 5)
            info.stats[i] = afterStats.stats[i] - beforeStats.stats[i];
        return info;
    }

    /// Movement speeds, in yards per second (`Unit::m_speed_rate` times the base speeds).
    float[MoveType.max + 1] speeds = baseMoveSpeed;

    /// The fastest the player can move on the ground or in water.
    @property float fastestSpeed() const
    {
        return max(speeds[MoveType.run], speeds[MoveType.swim], speeds[MoveType.runBack], speeds[MoveType.walk]);
    }

    /// `Player::ExploreArea` for everything: every bit of `PLAYER_EXPLORED_ZONES_1`.
    void exploreAll()
    {
        foreach (i; 0 .. exploredZonesSize)
            values.set!PLAYER_EXPLORED_ZONES_1(i, uint.max);
    }

    /// The skill slot of `skill`, or -1.
    ptrdiff_t skillSlot(uint skill) const
    {
        foreach (i; 0 .. maxPlayerSkills)
            if ((values[PLAYER_SKILL_INFO_1_1 + 3 * i] & 0xFFFF) == skill && skill != 0)
                return i;
        return -1;
    }

    /// A skill's value and maximum, or [0, 0] if the player does not have it.
    ushort[2] skillValue(uint skill) const
    {
        const slot = skillSlot(skill);
        if (slot < 0)
            return [0, 0];
        const word = values[PLAYER_SKILL_INFO_1_1 + 3 * slot + 1];
        return [cast(ushort) word, cast(ushort)(word >> 16)];
    }

    /// The skills the player has: id, value and maximum.
    uint[3][] skillList() const
    {
        uint[3][] list;
        foreach (i; 0 .. maxPlayerSkills)
            if (const id = values[PLAYER_SKILL_INFO_1_1 + 3 * i] & 0xFFFF)
            {
                const word = values[PLAYER_SKILL_INFO_1_1 + 3 * i + 1];
                list ~= [id, word & 0xFFFF, word >> 16];
            }
        return list;
    }

    /// `Player::SetSkill`: adds the skill or changes it; a maximum of 0 removes it. False if no slot is free.
    bool setSkill(uint skill, ushort value, ushort maxValue)
    in (skill > 0 && skill <= ushort.max)
    {
        auto slot = skillSlot(skill);
        if (maxValue == 0)
        {
            if (slot >= 0)
                foreach (i; 0 .. 3)
                    values.set!PLAYER_SKILL_INFO_1_1(3 * slot + i, 0u);
            return true;
        }
        if (slot < 0)
            foreach (i; 0 .. maxPlayerSkills)
                if (values[PLAYER_SKILL_INFO_1_1 + 3 * i] == 0)
                {
                    slot = i;
                    break;
                }
        if (slot < 0)
            return false;
        values.set!PLAYER_SKILL_INFO_1_1(3 * slot, skill);
        values.set!PLAYER_SKILL_INFO_1_1(3 * slot + 1, value | uint(maxValue) << 16);
        return true;
    }

    /// Whether the spellbook has the spell.
    bool knowsSpell(uint spell) const
    {
        return spells.canFind(spell);
    }

    /**
     * `Player::_LoadInventory` for one more item: adds the item object and points its slot at it.
     * Returns why it could not, or null.
     */
    string addItem(const ItemRecord record, const WorldData world)
    {
        return placeItem(record, world);
    }

    /// `Player::RemoveItem` and `DestroyItem`: forgets the item and clears its slot.
    void removeItem(uint itemGuid)
    {
        import std.algorithm.mutation : remove;

        foreach (i, ref item; items)
            if (item.guid == itemGuid)
            {
                if (item.bag == 0)
                {
                    values.set!PLAYER_FIELD_INV_SLOT_HEAD(item.slot, 0UL);
                    if (item.slot < equipmentSlotEnd)
                        clearVisibleItem(item.slot);
                }
                else
                    foreach (ref bag; items)
                        if (bag.guid == item.bag)
                            bag.values.set!CONTAINER_FIELD_SLOT_1(item.slot, 0UL);
                items = items.remove(i);
                return;
            }
    }

    /// The item object with this low guid, or null.
    InventoryItem* item(uint itemGuid)
    {
        foreach (ref it; items)
            if (it.guid == itemGuid)
                return &it;
        return null;
    }

    /**
     * Where a new item of `template_` can go (`Player::CanStoreNewItem`, without its merging of
     * several destinations): the backpack first, then the equipped bags that may hold it. Returns
     * false if there is no room.
     */
    bool freeSlot(const ref ItemTemplate template_, out uint bag, out ubyte slot) const
    {
        foreach (ubyte s; inventorySlotItemStart .. inventorySlotItemEnd)
            if (values.get!PLAYER_FIELD_INV_SLOT_HEAD(s) == 0)
            {
                slot = s;
                return true;
            }
        foreach (ref container; items)
        {
            if (container.typeId != TypeId.container || container.bag != 0 || container.slot < inventorySlotBagStart
                || container.slot >= inventorySlotBagEnd)
                continue;
            // A special bag (quiver, soul bag, ...) takes only what belongs in it.
            if (container.template_.bagFamily && !(container.template_.bagFamily & template_.bagFamily))
                continue;
            foreach (ubyte s; 0 .. cast(ubyte) container.values[CONTAINER_FIELD_NUM_SLOTS])
                if (container.values.get!CONTAINER_FIELD_SLOT_1(s) == 0)
                {
                    bag = container.guid;
                    slot = s;
                    return true;
                }
        }
        return false;
    }

    /// How many items of `entry` the player carries, equipped or in bags, not in the bank.
    uint itemCount(uint entry) const
    {
        uint n;
        foreach (ref item; items)
            if (item.template_.entry == entry && !inBank(item))
                n += item.values[ITEM_FIELD_STACK_COUNT];
        return n;
    }

    /// Whether the item is in the bank, or in a bag in the bank.
    bool inBank(const ref InventoryItem item) const
    {
        enum bankStart = 39, bankEnd = 69; // `BANK_SLOT_ITEM_START` .. `BANK_SLOT_BAG_END`
        const slot = item.bag == 0 ? item.slot : bagSlotOf(item.bag);
        return slot >= bankStart && slot < bankEnd;
    }

private:
    // -----------------------------------------------------------------------
    // Items (Player::_LoadInventory, Item::LoadFromDB, Bag::LoadFromDB)
    // -----------------------------------------------------------------------

    void loadItems(const WorldData world)
    {
        // Character slots first, so the bags exist before what is in them.
        foreach (pass; 0 .. 2)
            foreach (ref record; data.items)
            {
                if ((record.bag == 0) != (pass == 0))
                    continue;
                if (auto problem = placeItem(record, world))
                    warning!"character %s: item %s (entry %s) in bag %s slot %s not loaded: %s"(data.guid,
                        record.guid, record.entry, record.bag, record.slot, problem);
            }
    }

    string placeItem(const ref ItemRecord record, const WorldData world)
    {
        const template_ = record.entry in world.items;
        if (template_ is null)
            return "no such item template";
        foreach (ref other; items)
            if (other.bag == record.bag && other.slot == record.slot)
                return "the slot is taken";

        InventoryItem* bag;
        if (record.bag == 0)
        {
            if (record.slot >= playerInventorySlots)
                return "no such inventory slot";
        }
        else
        {
            foreach (ref other; items)
                if (other.guid == record.bag)
                    bag = &other;
            if (bag is null || bag.typeId != TypeId.container || bag.bag != 0)
                return "the bag is not equipped";
            if (record.slot >= bag.values[CONTAINER_FIELD_NUM_SLOTS])
                return "the bag has no such slot";
        }

        const isBag = template_.containerSlots > 0 && template_.containerSlots <= maxBagSize
            && (template_.itemClass == ItemClass.container || template_.itemClass == ItemClass.quiver);
        InventoryItem item;
        item.guid = record.guid;
        item.bag = record.bag;
        item.slot = record.slot;
        item.template_ = template_;
        item.values = UpdateValues(isBag ? TypeId.container : TypeId.item);
        fillItemFields(item, record, *template_);

        // Index of the new item, before taking pointers into the array again.
        if (bag !is null)
            bag.values.set!CONTAINER_FIELD_SLOT_1(record.slot, item.fullGuid);
        else
            values.set!PLAYER_FIELD_INV_SLOT_HEAD(record.slot, item.fullGuid);
        if (record.bag == 0 && record.slot < equipmentSlotEnd)
            setVisibleItem(record.slot, item);
        item.values.set!ITEM_FIELD_CONTAINED(record.bag ? makeGuid(HighGuid.item, record.bag) : guid);
        items ~= item;
        return null;
    }

    void fillItemFields(ref InventoryItem item, const ref ItemRecord record, const ref ItemTemplate template_)
    {
        ref v = item.values;
        v.set!OBJECT_FIELD_GUID(item.fullGuid);
        v.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.item
            | (item.typeId == TypeId.container ? TypeMask.container : 0));
        v.set!OBJECT_FIELD_ENTRY(record.entry);
        v.set!OBJECT_FIELD_SCALE_X(1.0f);
        v.set!ITEM_FIELD_OWNER(guid);
        if (record.creator)
            v.set!ITEM_FIELD_CREATOR(makeGuid(HighGuid.player, record.creator));
        if (record.giftCreator)
            v.set!ITEM_FIELD_GIFTCREATOR(makeGuid(HighGuid.player, record.giftCreator));
        v.set!ITEM_FIELD_STACK_COUNT(record.count);
        v.set!ITEM_FIELD_DURATION((template_.duration == 0) != (record.duration == 0) ? template_.duration
            : record.duration);
        foreach (i, n; parseNumbers(record.charges, 5))
            v.set!ITEM_FIELD_SPELL_CHARGES(i, n);
        v.set!ITEM_FIELD_FLAGS(record.flags);
        foreach (i, n; parseNumbers(record.enchantments, 21))
            v.set!ITEM_FIELD_ENCHANTMENT(i, n);
        v.set!ITEM_FIELD_RANDOM_PROPERTIES_ID(record.randomPropertyId);
        v.set!ITEM_FIELD_ITEM_TEXT_ID(record.textId);
        v.set!ITEM_FIELD_MAXDURABILITY(template_.maxDurability);
        v.set!ITEM_FIELD_DURABILITY(min(record.durability, template_.maxDurability));
        if (item.typeId == TypeId.container)
            v.set!CONTAINER_FIELD_NUM_SLOTS(template_.containerSlots);
    }

    /// `Player::SetVisibleItemSlot` for an empty slot.
    void clearVisibleItem(ubyte slot)
    {
        const block = slot * visibleItemStride;
        values.set!PLAYER_VISIBLE_ITEM_1_CREATOR(block / 2, 0UL);
        foreach (i; 0 .. 1 + visibleEnchantments)
            values.set!PLAYER_VISIBLE_ITEM_1_0(block + i, 0u);
        values.set!PLAYER_VISIBLE_ITEM_1_PROPERTIES(block, 0u);
    }

    /// `Player::SetVisibleItemSlot`
    void setVisibleItem(ubyte slot, const ref InventoryItem item)
    {
        // Each equipment slot has a block of `visibleItemStride` slots: the creator's guid, the entry and
        // seven enchantments, the random property.
        const block = slot * visibleItemStride;
        values.set!PLAYER_VISIBLE_ITEM_1_CREATOR(block / 2, item.values.get!ITEM_FIELD_CREATOR);
        values.set!PLAYER_VISIBLE_ITEM_1_0(block, item.values.get!OBJECT_FIELD_ENTRY);
        foreach (i; 0 .. visibleEnchantments)
            values.set!PLAYER_VISIBLE_ITEM_1_0(block + 1 + i, item.values.get!ITEM_FIELD_ENCHANTMENT(3 * i));
        values.set!PLAYER_VISIBLE_ITEM_1_PROPERTIES(block, item.values.get!ITEM_FIELD_RANDOM_PROPERTIES_ID);
    }

    // -----------------------------------------------------------------------
    // Fields (LoadFromDB, InitStatsForLevel, InitDisplayIds, the stat system)
    // -----------------------------------------------------------------------

    void computeDerived(const WorldData world)
    {
        StatInputs input;
        input.race = data.race;
        input.classId = data.classId;
        input.level = data.level;
        input.levelStats = world.levelStats(data.race, data.classId, data.level);
        input.classStats = world.classStats(data.classId, data.level);
        foreach (ref item; items)
            if (item.bag == 0 && item.slot < equipmentSlotEnd
                && (item.values[ITEM_FIELD_DURABILITY] != 0 || item.template_.maxDurability == 0))
                input.equipment[item.slot] = item.template_;
        stats = computeStats(input);
    }

    void setPlayerFields(const WorldData world, const ClientData client)
    {
        alias v = values;
        const race = client.races.lookup(data.race);
        const classEntry = client.classes.lookup(data.classId);
        const powerType = classEntry is null ? Power.mana : cast(Power) classEntry.powerType;

        v.set!OBJECT_FIELD_GUID(guid);
        v.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.unit | TypeMask.player);

        // InitDisplayIds
        const displayId = race is null ? 0 : (data.gender == 0 ? race.maleDisplayId : race.femaleDisplayId);
        v.set!OBJECT_FIELD_SCALE_X(client.displayScale(displayId));
        v.set!UNIT_FIELD_DISPLAYID(displayId);
        v.set!UNIT_FIELD_NATIVEDISPLAYID(displayId);
        const model = displayId in world.models;
        v.set!UNIT_FIELD_BOUNDINGRADIUS(model is null ? defaultBoundingRadius : model.boundingRadius);
        v.set!UNIT_FIELD_COMBATREACH(model is null ? defaultCombatReach : model.combatReach);

        v.set!UNIT_FIELD_LEVEL(data.level);
        v.set!UNIT_FIELD_FACTIONTEMPLATE(race is null ? 0 : race.factionId);
        v.set!UNIT_FIELD_BYTES_0(data.race | data.classId << 8 | data.gender << 16 | uint(powerType) << 24);
        if (powerType == Power.rage || powerType == Power.mana)
            v.setByte!UNIT_FIELD_BYTES_1(1, 0xEE); // UNIT_BYTES_1_OFFSET_PET_LOYALTY
        v.setByte!UNIT_FIELD_BYTES_2(1, unitByte2FlagSupportable | unitByte2FlagUnk5);
        v.set!UNIT_FIELD_FLAGS(unitFlagPlayerControlled);
        v.set!UNIT_MOD_CAST_SPEED(1.0f);

        // Health and powers: saved values, within the maximums.
        v.set!UNIT_FIELD_MAXHEALTH(stats.maxHealth);
        v.set!UNIT_FIELD_HEALTH(data.health == 0 || data.health > stats.maxHealth ? stats.maxHealth : data.health);
        foreach (i; 0 .. maxPowers)
        {
            v.set!UNIT_FIELD_MAXPOWER1(i, stats.maxPower[i]);
            v.set!UNIT_FIELD_POWER1(i, min(data.power[i], stats.maxPower[i]));
        }
        v.set!UNIT_FIELD_BASE_HEALTH(stats.baseHealth);
        v.set!UNIT_FIELD_BASE_MANA(stats.baseMana);
        // Stats are whole numbers on the wire: UNIT_FIELD_STAT* are integer fields, and CMaNGOS converts
        // the float bonus fields to integers when it sends them (Object::BuildValuesUpdate).
        foreach (i; 0 .. 5)
        {
            v.set!UNIT_FIELD_STAT0(i, cast(int) stats.stats[i]);
            v.set!PLAYER_FIELD_POSSTAT0(i, cast(int) stats.positiveBonus[i]);
            v.set!PLAYER_FIELD_NEGSTAT0(i, cast(int) stats.negativeBonus[i]);
        }
        foreach (i; 0 .. 7)
        {
            v.set!UNIT_FIELD_RESISTANCES(i, stats.resistances[i]);
            v.set!PLAYER_FIELD_MOD_DAMAGE_DONE_PCT(i, 1.0f);
        }
        v.set!UNIT_FIELD_ATTACK_POWER(stats.attackPower);
        v.set!UNIT_FIELD_RANGED_ATTACK_POWER(stats.rangedAttackPower);
        // CMaNGOS sends attack times as whole numbers, not floats (Object::BuildValuesUpdate).
        v.set!UNIT_FIELD_BASEATTACKTIME(stats.attackTime[AttackType.mainHand]);
        v.set!UNIT_FIELD_BASEATTACKTIME(1, stats.attackTime[AttackType.offHand]); // the off hand
        v.set!UNIT_FIELD_RANGEDATTACKTIME(stats.attackTime[AttackType.ranged]);
        v.set!UNIT_FIELD_MINDAMAGE(stats.damage[AttackType.mainHand].min);
        v.set!UNIT_FIELD_MAXDAMAGE(stats.damage[AttackType.mainHand].max);
        v.set!UNIT_FIELD_MINOFFHANDDAMAGE(stats.damage[AttackType.offHand].min);
        v.set!UNIT_FIELD_MAXOFFHANDDAMAGE(stats.damage[AttackType.offHand].max);
        v.set!UNIT_FIELD_MINRANGEDDAMAGE(stats.damage[AttackType.ranged].min);
        v.set!UNIT_FIELD_MAXRANGEDDAMAGE(stats.damage[AttackType.ranged].max);

        // Player
        v.set!PLAYER_FLAGS(data.playerFlags & ~(PlayerFlags.afk | PlayerFlags.dnd | PlayerFlags.gm));
        v.set!PLAYER_BYTES(data.playerBytes);
        v.set!PLAYER_BYTES_2(data.playerBytes2);
        v.setByte!PLAYER_BYTES_2(3, RestState.normal);
        v.setHalf!PLAYER_BYTES_3(0, data.gender);
        v.setByte!PLAYER_FIELD_BYTES(2, data.actionBars);
        v.set!PLAYER_XP(data.xp);
        v.set!PLAYER_NEXT_LEVEL_XP(world.xpForLevel(data.level));
        v.set!PLAYER_FIELD_COINAGE(data.money);
        v.set!PLAYER_AMMO_ID(data.ammoId);
        v.set!PLAYER_FIELD_WATCHED_FACTION_INDEX(data.watchedFaction);
        foreach (i, n; parseNumbers(data.exploredZones, exploredZonesSize))
            v.set!PLAYER_EXPLORED_ZONES_1(i, n);
    }

    /// The skill fields: id and step, value and maximum, bonus.
    void setSkills(const(KnownSkill)[] known)
    {
        foreach (position, skill; known)
        {
            if (position == maxPlayerSkills)
                break;
            values.set!PLAYER_SKILL_INFO_1_1(3 * position, skill.skill | uint(skill.step) << 16);
            values.set!PLAYER_SKILL_INFO_1_1(3 * position + 1, skill.value | uint(skill.max) << 16);
        }
    }

    /// The spellbook, unspent talent points, free professions and proficiencies.
    void setSpells(const ref KnownAbilities abilities, const WorldData world, const ClientData client)
    {
        uint[uint] talentRanks; // talent id -> highest rank known, 1-based
        foreach (id; abilities.spellbook)
        {
            const info = world.spells.spell(id);
            if (info is null)
                continue;
            spells ~= id;
            if (const position = client.talentSpellPos(id))
                if (position.rank + 1 > talentRanks.get(position.talentId, 0))
                    talentRanks[position.talentId] = position.rank + 1;
            // Spell::EffectProficiency, which runs when the passive spell is cast at login
            if (info.hasEffect(SpellEffect.proficiency))
            {
                if (info.equippedItemClass == ItemClass.weapon)
                    proficiency[0] |= info.equippedItemSubClassMask;
                else if (info.equippedItemClass == ItemClass.armor)
                    proficiency[1] |= info.equippedItemSubClassMask;
            }
        }

        // Player::UpdateFreeTalentPoints
        const spent = talentRanks.byValue.sum;
        const earned = talentPointsForLevel(data.level);
        values.set!PLAYER_CHARACTER_POINTS1(earned > spent ? earned - spent : 0);
        values.set!PLAYER_CHARACTER_POINTS2(abilities.freePrimaryProfessions);
    }
}

/// The talent points a character of `level` has earned: one per level from 10 on.
private uint talentPointsForLevel(uint level) pure nothrow @nogc @safe
{
    return level < 10 ? 0 : level - 9;
}

/// `count` space-separated numbers from a CMaNGOS text column; missing or malformed ones are 0.
int[] parseNumbers(string text, size_t count) pure @safe
out (numbers; numbers.length == count)
{
    auto numbers = new int[count];
    foreach (i, token; text.split)
    {
        if (i == count)
            break;
        try
            numbers[i] = cast(int) token.to!long;
        catch (ConvException)
            numbers[i] = 0;
    }
    return numbers;
}

unittest
{
    assert(parseNumbers("1 -1 4294967295", 4) == [1, -1, -1, 0]);
    assert(parseNumbers("", 2) == [0, 0] && parseNumbers("x 5", 2) == [0, 5]);
    assert(packActionButton(6603, 0) == 6603 && packActionButton(117, 0x80) == 0x8000_0075);
}

unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.testdata;

    auto client = testClientData();
    auto world = testWorldData(client);
    world.items[itemSword].details.delay = 2300;
    world.items[itemSword].details.damage[0].min = 2;
    world.items[itemSword].details.damage[0].max = 5;
    world.xpForNextLevel = [0, 400];

    CharacterData c;
    c.guid = 7;
    c.name = "Tester";
    c.race = raceHuman;
    c.classId = classWarrior;
    c.level = 1;
    c.xp = 50;
    c.money = 1234;
    c.playerBytes = 0x01020304;
    c.position = Position(-8949.95f, -132.493f, 83.5312f, 0);
    c.health = 999; // more than the maximum: clamped
    c.power[Power.rage] = 2000;
    c.exploredZones = "1 2 3";
    c.watchedFaction = uint.max;
    c.items = [
        ItemRecord(0, 15, 100, itemSword, 0, 0, 1, 0, "0 0 0 0 0", 0, "", 0, 20),
        ItemRecord(0, 23, 101, itemJerky, 0, 0, 5, 0, "", 0, "", 0, 0),
        ItemRecord(0, 19, 102, itemQuiver, 0, 0, 1, 0, "", 0, "", 0, 0),
        ItemRecord(102, 0, 103, itemArrow, 0, 0, 200, 0, "", 0, "", 0, 0),
        ItemRecord(102, 9, 104, itemArrow, 0, 0, 1, 0, "", 0, "", 0, 0), // the quiver has 6 slots
        ItemRecord(0, 24, 105, 999999, 0, 0, 1, 0, "", 0, "", 0, 0),      // no template
        ItemRecord(0, 15, 106, itemShirt, 0, 0, 1, 0, "", 0, "", 0, 0),   // slot taken
    ];
    c.skills = [NewSkill(skillSwords, 1, 5), NewSkill(12345, 1, 1)];
    c.spells = [NewSpell(spellOneHandedSwords, true, false), NewSpell(spellFireball, false, false)];
    // 6603 is not a test spell.
    c.actions = [CreateAction(0, 6603, 0), CreateAction(1, spellOneHandedSwords, 0), CreateAction(200, 1, 0)];

    import dmangos.world.playercreate : CharacterBuilder, CreationSettings;

    KnownAbilities abilities;
    assert(new CharacterBuilder(world, client, CreationSettings.init, () => 1u).loadAbilities(c.race, c.classId,
        c.level, AccountLevel.player, c.skills, c.spells, abilities));
    auto p = new Player(c, abilities, world, client);
    assert(p.guid == 7);
    assert(p.items.length == 4, "the unknown, overflowing and doubled-up items are not loaded");

    // The player's slots and the quiver's contents point at the item objects.
    assert(p.values.get!PLAYER_FIELD_INV_SLOT_HEAD(15) == makeGuid(HighGuid.item, 100));
    assert(p.values.get!PLAYER_FIELD_INV_SLOT_HEAD(19) == makeGuid(HighGuid.item, 102));
    assert(p.values.get!PLAYER_FIELD_PACK_SLOT_1 == makeGuid(HighGuid.item, 101));
    const quiver = p.items[$ - 2];
    assert(quiver.typeId == TypeId.container && quiver.values[CONTAINER_FIELD_NUM_SLOTS] == 6);
    assert(quiver.values.get!CONTAINER_FIELD_SLOT_1 == makeGuid(HighGuid.item, 103));
    const arrows = p.items[$ - 1];
    assert(arrows.values.get!ITEM_FIELD_CONTAINED == makeGuid(HighGuid.item, 102));
    assert(arrows.values.get!ITEM_FIELD_OWNER == p.guid && arrows.values[ITEM_FIELD_STACK_COUNT] == 200);
    assert(p.items[0].values[OBJECT_FIELD_TYPE] == (TypeMask.object | TypeMask.item));
    assert(p.items[0].values[ITEM_FIELD_DURABILITY] == 20 && p.items[0].values[ITEM_FIELD_MAXDURABILITY] == 20);

    // The sword is visible in the main hand.
    assert(p.values[PLAYER_VISIBLE_ITEM_1_0 + 15 * visibleItemStride] == itemSword);

    // Unit fields.
    assert(p.values[UNIT_FIELD_BYTES_0] == (raceHuman | classWarrior << 8 | 0 << 16 | Power.rage << 24));
    assert(p.values[UNIT_FIELD_MAXHEALTH] == 20 + 20 + 2 * 10 && p.values[UNIT_FIELD_HEALTH] == 60);
    assert(p.values[UNIT_FIELD_POWER1 + Power.rage] == 1000);
    assert(p.values[UNIT_FIELD_BASEATTACKTIME] == 2300);
    assert(p.values.get!UNIT_FIELD_MAXDAMAGE > 5);
    assert(p.values.get!OBJECT_FIELD_SCALE_X == 1, "no display info: scale 1");
    assert(p.values[UNIT_FIELD_STAT0] == 23 && p.values[UNIT_FIELD_STAT0 + 2] == 22, "stats are integers");

    // Player fields.
    assert(p.values[PLAYER_BYTES] == 0x01020304 && p.values.getByte!PLAYER_BYTES_2(3) == 2);
    assert(p.values[PLAYER_XP] == 50 && p.values[PLAYER_NEXT_LEVEL_XP] == 400);
    assert(p.values[PLAYER_FIELD_COINAGE] == 1234);
    assert(p.values[PLAYER_EXPLORED_ZONES_1 + 2] == 3);
    assert(p.values[PLAYER_FIELD_WATCHED_FACTION_INDEX] == uint.max);
    assert(p.values[PLAYER_CHARACTER_POINTS1] == 0 && p.values[PLAYER_CHARACTER_POINTS2] == 2);

    // Skills: the saved one first, then those the default spells teach; the unknown one is skipped.
    assert(p.values[PLAYER_SKILL_INFO_1_1] == skillSwords && p.values[PLAYER_SKILL_INFO_1_1 + 1] == (1 | 5 << 16));
    foreach (i; 0 .. maxPlayerSkills)
        assert((p.values[PLAYER_SKILL_INFO_1_1 + 3 * i] & 0xFFFF) != 12345);

    // The spellbook has the saved active spells and the re-learned default ones; invalid action buttons
    // are dropped.
    assert(p.spells.canFind(spellOneHandedSwords) && p.spells.canFind(spellLanguageCommon)
        && !p.spells.canFind(spellFireball));
    assert(p.actionButtons[0] == 0 && p.actionButtons[1] == spellOneHandedSwords);

    // The create packet: four items, then the player.
    const update = p.createForSelf(1000);
    assert(update.blockCount == 5);

    // Changes after loading are sent as a values block.
    UpdateData changes;
    assert(!p.addChanges(changes, Viewer.self));
    p.setStandState(1);
    p.values.set!PLAYER_FIELD_COINAGE(1);
    assert(p.addChanges(changes, Viewer.self) && p.addChanges(changes, Viewer.stranger) && changes.blockCount == 2);
    p.clearChanges();
    p.values.set!PLAYER_FIELD_COINAGE(2);
    assert(p.addChanges(changes, Viewer.self) && !p.addChanges(changes, Viewer.stranger), "money is private");

    // Others see health in percent, and no items.
    p.values.set!UNIT_FIELD_HEALTH(31);
    assert(p.strangerValue(UNIT_FIELD_HEALTH, 31) == 52 && p.strangerValue(UNIT_FIELD_MAXHEALTH, 60) == 100);
    assert(p.createForOthers(1000, false).blockCount == 1 && p.groupView(Viewer.groupMate).blockCount == 1);

    // Flags and the chat tag.
    p.setFlag(PlayerFlags.afk, true);
    assert(p.hasFlag(PlayerFlags.afk) && p.chatTag == ChatTag.CHAT_TAG_AFK);
    p.gmTagOn = true;
    assert(p.chatTag == ChatTag.CHAT_TAG_GM && p.powerType == Power.rage);

    // Saving adds the time played.
    p.movement.position = Position(1, 2, 3, 4);
    const saved = p.progress(60);
    assert(saved.position == Position(1, 2, 3, 4) && saved.totalTime == 60 && saved.health == 31);
}
