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

import std.algorithm.comparison : clamp, max, min;
import std.algorithm.iteration : sum;
import std.algorithm.searching : canFind;
import std.array : split;
import std.conv : to;

import dmangos.auth.accounts : AccountLevel;
import dmangos.log;
import dmangos.world.clientdata : ClientData, maskOf, skillFlagMaximized;
import dmangos.world.movement;
import dmangos.world.objects;
import dmangos.world.opcodes : ChatTag;
import dmangos.world.packets : ServerLevelUpInfo;
import dmangos.world.defines;
public import dmangos.world.inventory : ItemRecord, parseNumbers;
import dmangos.world.inventory : Inventory, InventoryOwner, Item;
import dmangos.world.playercreate : KnownAbilities, KnownSkill, NewSkill, NewSpell;
import dmangos.world.spells : SpellEffect;
import dmangos.world.stats;
import dmangos.world.auras : AuraSet, AuraType;
import dmangos.world.quests : QuestData, QuestStatus;
import dmangos.world.combat : AttackType, Fighter;
import dmangos.world.updatefields;
import dmangos.world.worlddata : CreateAction, maxLevel, WorldData;

/// Number of `character_tutorial` fields.
enum tutorialFields = 8;

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
    QuestStatus[] quests;          /// `character_queststatus`
    NewSpell[] spells;
    CreateAction[] actions;
    bool hasHomeBind;
    HomeBind homeBind;
    uint[tutorialFields] tutorials;
    bool[uint] rewardedQuests;   /// `character_queststatus` rows with `rewarded` set
    float restBonus = 0;         /// `rest_bonus`: rested XP
    long logoutTime;             /// `logout_time`, Unix time
    bool logoutResting;          /// `is_logout_resting`: logged out in an inn or a city
    long deathExpireTime;        /// `death_expire_time`: deaths until then make the corpse wait longer
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
    string equipmentCache; /// what the character screen shows worn: entry and enchantments per slot, then a bag
    uint ammoId;
    float restBonus = 0;
    bool resting;         /// `is_logout_resting`
    uint playerFlags;     /// `playerFlags`: the ghost flag among them
    long deathExpireTime; /// `death_expire_time`
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
    ghost = 0x10,
    resting = 0x20,
}

/// `DeathState`, for a player: alive, dead where it fell (`CORPSE`), or released (`DEAD`, a ghost).
enum DeathState : ubyte
{
    alive,
    corpse,
    ghost,
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
final class Player : InventoryOwner
{
    CharacterData data;
    ulong guid;
    UpdateValues values;
    Inventory inventory;
    MovementInfo movement;
    PlayerStats stats;
    MeleeChances chances;                /// own melee chances (`meleeChances`), for the combat rolls
    AuraSet auras;                       /// its auras (`dmangos.world.auras`)
    QuestStatus[uint] questStatus;       /// its progress in quests, by quest (`mQuestStatus`)
    DeathState deathState;               /// alive, a body, or a ghost (`dmangos.world.death`)
    uint[] spells;                       /// active, enabled spells: the spellbook
    uint[maxActionButtons] actionButtons; /// packed, 0 = empty
    uint[2] proficiency;                 /// item sub-class masks for weapons and armor (`SMSG_SET_PROFICIENCY`)
    string autoReply;                    /// the AFK or DND message (`Player::autoReplyMsg`)
    /// ArcEmu's `Player::bGMTagOn`: the GM tag in chat (`.gm on`, `.gm whisperblock`)
    bool gmTagOn;
    /// `Player::CanDualWield`: a spell with `SPELL_EFFECT_DUAL_WIELD` is known.
    bool dualWield;
    /// `Player::m_areaUpdateId`: the area within `data.zone`; the zone itself where there is no map data.
    uint area;

    /**
     * Builds the player from its database rows and the skills and spells
     * `CharacterBuilder.loadAbilities` worked out. Problems in the data are logged and skipped.
     * `nextItemGuid` numbers the items it will be given.
     */
    this(const ref CharacterData character, const ref KnownAbilities abilities, const WorldData world,
        const ClientData client, uint delegate() nextItemGuid)
    in (character.guid != 0, "guid 0 is no character")
    in (character.level > 0, "levels start at 1")
    out (; values.type == TypeId.player && !values.hasChanges, "a fresh player has nothing left to send")
    {
        data = cast(CharacterData) character;
        guid = makeGuid(HighGuid.player, character.guid);
        movement.position = character.position;
        values = UpdateValues(TypeId.player);
        inventory = new Inventory(world, this, &values, nextItemGuid);

        loadItems();
        computeDerived(world);
        setPlayerFields(world, client);
        setSkills(abilities.skills);
        setSpells(abilities, world, client);
        foreach (action; character.actions)
            if (action.button < maxActionButtons && world.isActionButtonDataValid(action))
                actionButtons[action.button] = packActionButton(action.action, action.type);
        values.clearChanges();
        inventory.equipmentChanged = false;
        foreach (item; inventory.all())
            item.values.clearChanges();
    }

    /// The equipped item in `slot` (0 .. 18), or null.
    const(Item) equipped(ubyte slot) const
    in (slot < equipmentSlotEnd)
    {
        return inventory.equipped(slot);
    }

    // -----------------------------------------------------------------------
    // InventoryOwner
    // -----------------------------------------------------------------------

    @property ulong ownerGuid() const
    {
        return guid;
    }

    @property uint ownerLevel() const
    {
        return data.level;
    }

    @property ubyte ownerClass() const
    {
        return data.classId;
    }

    @property ubyte ownerRace() const
    {
        return data.race;
    }

    ushort skillRank(uint skill) const
    {
        return skillValue(skill)[0];
    }

    @property bool dualWields() const
    {
        return dualWield;
    }

    /// Players do not die yet.
    @property bool alive() const
    {
        return true;
    }

    /// Nobody fights yet.
    @property bool inCombat() const
    {
        return false;
    }

    /**
     * `Player::BuildCreateUpdateBlockForPlayer` for the player itself: its items, then the player.
     * Once it is sent, call `inventory.markAllSent`.
     */
    UpdateData createForSelf(uint serverTime) const
    {
        UpdateData update;
        MovementBlock itemMovement;
        itemMovement.flags = UpdateFlags.all;
        foreach (item; inventory.all())
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

    /**
     * The player as another player first sees it: no items and no private fields. A stranger sees
     * health in percent (`Visibility.FogOfWar.Health` 0); a group mate sees the real values and the
     * group-only fields.
     */
    UpdateData createForOthers(uint serverTime, bool groupMate) const
    {
        UpdateData update;
        const other = motionForOthers(serverTime);
        update.addCreate(UpdateType.createObject, guid, other, values, groupMate ? seenByGroup : seenByEveryone,
            groupMate ? null : &strangerValue);
        return update;
    }

    /// The movement part of the player's create block for others.
    MovementBlock motionForOthers(uint serverTime) const
    {
        MovementBlock other;
        other.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
        other.info = movement;
        other.info.time = serverTime;
        other.speeds = speeds;
        return other;
    }

    /// The fields a stranger sees, as (slot, value): a replica's state on another node (phase 3).
    SlotValue[] strangerSlots() const
    {
        auto slots = values.publicSlots;
        foreach (ref s; slots)
            s.value = strangerValue(s.slot, s.value);
        return slots;
    }

    /// Those changed since `clearChanges`.
    SlotValue[] changedStrangerSlots() const
    {
        auto slots = values.changedPublicSlots;
        foreach (ref s; slots)
            s.value = strangerValue(s.slot, s.value);
        return slots;
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
        return inventory.count(entry) >= count;
    }

    /// `PLAYER_FIELD_COINAGE`
    @property uint money() const
    {
        return values[PLAYER_FIELD_COINAGE];
    }

    /// `Player::ModifyMoney`: adds `amount` (or takes it, if negative), within 0 and `MAX_MONEY_AMOUNT`.
    void modifyMoney(long amount)
    {
        enum long maxMoney = int.max;
        values.set!PLAYER_FIELD_COINAGE(cast(uint) clamp(money + amount, 0, maxMoney));
    }

    /**
     * `Player::_ApplyItemMods` for every worn item at once: the stats, armor, damage and the rest
     * worked out again from what is worn now. Health and mana keep their values, within the new maximums.
     */
    void refreshEquipmentStats(const WorldData world)
    {
        inventory.equipmentChanged = false;
        computeDerived(world);
        uint[maxPowers] power;
        foreach (i; 0 .. maxPowers)
            power[i] = values[UNIT_FIELD_POWER1 + i];
        setStatFields(values[UNIT_FIELD_HEALTH], power);
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
        p.equipmentCache = equipmentCacheText();
        p.ammoId = values[PLAYER_AMMO_ID];
        p.restBonus = restBonus;
        p.resting = hasFlag(PlayerFlags.resting);
        p.playerFlags = values.get!PLAYER_FLAGS;
        p.deathExpireTime = data.deathExpireTime;
        return p;
    }

    /**
     * `characters.equipmentCache` as `Player::SaveToDB` writes it: per equipment slot the visible
     * entry and its permanent and temporary enchantments as one number, then the first bag.
     */
    string equipmentCacheText() const
    {
        import std.array : appender;
        import std.format : formattedWrite;

        auto text = appender!string;
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
        {
            const block = PLAYER_VISIBLE_ITEM_1_0 + slot * visibleItemStride;
            text.formattedWrite!"%s %s "(values[block], values[block + 1] | values[block + 2] << 16);
        }
        const bag = inventory[inventorySlotBag0, inventorySlotBagStart];
        text.formattedWrite!"%s 0 "(bag is null ? 0 : bag.entry);
        return text[];
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
    bool regenerate(uint milliseconds, float healthRate, float manaRate, float rageLoss, float energyRate,
        bool inCombat = false)
    {
        bool changed;
        const health = values.get!UNIT_FIELD_HEALTH, maxHealth = values.get!UNIT_FIELD_MAXHEALTH;
        // `Player::RegenerateAll`: health, and the loss of rage, only out of combat.
        if (!inCombat && health < maxHealth && health > 0)
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
        if (!inCombat)
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
        updateSkillsForLevel(client);
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

    /**
     * `Player::UpdateSkillsForLevel`: a skill that goes with the level (weapons, defense) may now
     * rise to 5 a level; one the race and class have maximized (`SKILL_FLAG_MAXIMIZED`) is full.
     */
    void updateSkillsForLevel(const ClientData client)
    {
        import dmangos.world.playercreate : skillRangeType, SkillRange;

        const maxNew = cast(ushort) min(data.level * 5, ushort.max);
        const raceMask = 1u << (data.race - 1), classMask = 1u << (data.classId - 1);
        foreach (skill; skillList())
        {
            const entry = client.skillLines.lookup(skill[0]);
            if (entry is null || skill[2] == 1)
                continue;
            const range = skillRangeType(entry, false);
            if (range != SkillRange.level && range != SkillRange.mono)
                continue;
            bool maximized;
            foreach (info; client.raceClassInfo(skill[0]))
                if ((info.raceMask & raceMask) && (info.classMask & classMask))
                {
                    maximized = (info.flags & skillFlagMaximized) != 0;
                    break;
                }
            const value = maximized ? maxNew : cast(ushort) min(skill[1], maxNew);
            if (value != skill[1] || maxNew != skill[2])
                setSkill(skill[0], value, maxNew);
        }
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

    /**
     * `_LoadQuestStatus`: the saved progress, and the quest log: the quests taken and not yet
     * rewarded, in slots, complete or with their kill counters.
     */
    void loadQuestLog(const QuestData quests)
    {
        import dmangos.world.quests : maxQuestLogSize, QuestState;

        foreach (q; data.quests)
            questStatus[q.quest] = q;
        uint slot;
        foreach (ref q; data.quests)
        {
            if (slot >= maxQuestLogSize)
                break;
            if (quests.quest(q.quest) is null
                || (q.status != QuestState.incomplete && (q.status != QuestState.complete || q.rewarded)))
                continue;
            const base = PLAYER_QUEST_LOG_1_1 + 3 * slot;
            values.setSlot(base, q.quest);
            uint counters;
            foreach (i; 0 .. 4)
                counters |= (q.mobCount[i] & 0x3F) << (6 * i);
            if (q.status == QuestState.complete)
                counters |= 1u << 24;
            values.setSlot(base + 1, counters);
            ++slot;
        }
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

    /// `Player::HasSpell`: in the spellbook, or a saved lower rank it replaced; not disabled.
    bool hasSpell(uint spell) const
    {
        return knowsSpell(spell) || data.spells.canFind!(row => row.spell == spell && !row.disabled);
    }

    /// A `character_spell` row was written: `data.spells`, which the next `loadAbilities` starts from, follows.
    void recordSpellRow(const NewSpell row)
    {
        foreach (ref saved; data.spells)
            if (saved.spell == row.spell)
            {
                saved = row;
                return;
            }
        data.spells ~= row;
    }

    /// A `character_spell` row was deleted.
    void forgetSpellRow(uint spell)
    {
        import std.algorithm.mutation : remove;

        data.spells = data.spells.remove!(row => row.spell == spell);
    }

    /// A `character_skills` row was written; a `max` of 0 means it was deleted.
    void recordSkillRow(const NewSkill row)
    {
        import std.algorithm.mutation : remove;

        data.skills = data.skills.remove!(saved => saved.skill == row.skill);
        if (row.max)
            data.skills ~= row;
    }

    /**
     * The spellbook, skills and proficiencies of new abilities (a spell learned in the world). True if
     * the proficiencies changed, which the client is told with `SMSG_SET_PROFICIENCY`.
     */
    bool applyAbilities(const ref KnownAbilities abilities, const WorldData world, const ClientData client)
    {
        foreach (skill; skillList)
            if (!abilities.skills.canFind!(known => known.skill == skill[0]))
                setSkill(skill[0], 0, 0);
        foreach (known; abilities.skills)
            setSkill(known.skill, known.value, known.max);
        const before = proficiency;
        spells = null;
        proficiency = [0, 0];
        dualWield = false;
        setSpells(abilities, world, client);
        return proficiency != before;
    }

private:
    // -----------------------------------------------------------------------
    // Items (Player::_LoadInventory)
    // -----------------------------------------------------------------------

    void loadItems()
    {
        // Character slots first, so the bags exist before what is in them.
        foreach (pass; 0 .. 2)
            foreach (ref record; data.items)
            {
                if ((record.bag == 0) != (pass == 0))
                    continue;
                if (auto problem = inventory.load(record))
                    warning!"character %s: item %s (entry %s) in bag %s slot %s not loaded: %s"(data.guid,
                        record.guid, record.entry, record.bag, record.slot, problem);
            }
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
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            if (const item = inventory.equipped(slot))
                if (item.durability != 0 || item.maxDurability == 0) // a broken item gives nothing
                    input.equipment[slot] = item.proto;
        // What auras add (`Aura::HandleAuraModStat`, `HandleAuraModResistance`, ...).
        foreach (i; 0 .. 5)
        {
            input.auras.stats[i] = auras.totalByMisc(AuraType.modStat, i) + auras.totalByMisc(AuraType.modStat, -1);
            input.auras.statPercent[i] = auras.totalByMisc(AuraType.modPercentStat, i)
                + auras.totalByMisc(AuraType.modPercentStat, -1);
        }
        foreach (school; 0 .. 7)
            input.auras.resistances[school] = auras.totalByMiscMask(AuraType.modResistance, 1 << school);
        input.auras.attackPower = auras.total(AuraType.modAttackPower);
        input.auras.rangedAttackPower = auras.total(AuraType.modRangedAttackPower);
        input.auras.health = auras.total(AuraType.modIncreaseHealth);
        input.auras.mana = auras.totalByMisc(AuraType.modIncreaseEnergy, 0);
        stats = computeStats(input);
        chances = meleeChances(chanceInputs(world));
    }

    /**
     * What the melee formulas (`dmangos.world.combat`) need of this player now: its weapons and their
     * skills and damage, its own chances, its defense and armor.
     */
    public Fighter fighter() const
    {
        import dmangos.world.inventory : itemSkill;

        Fighter f;
        f.guid = guid;
        f.player = f.playerControlled = true;
        f.level = data.level;
        f.classId = data.classId;
        f.position = movement.position;
        f.combatReach = values.get!UNIT_FIELD_COMBATREACH;
        enum uint running = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
            | MovementFlags.strafeRight;
        f.runningAround = (movement.flags & running) && !(movement.flags & MovementFlags.walkMode);
        f.alive = deathState == DeathState.alive && values.get!UNIT_FIELD_HEALTH > 0;
        f.standing = values.getByte!UNIT_FIELD_BYTES_1(0) == 0;
        enum uint skillUnarmed = 162, skillDefense = 95;
        static immutable ubyte[3] slots = [equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged];
        foreach (type, slot; slots)
        {
            const item = weaponFor(slot);
            const skill = item !is null ? itemSkill(item.proto) : type == AttackType.mainHand ? skillUnarmed : 0;
            if (skill)
            {
                const value = skillValue(skill);
                f.weaponSkill[type] = value[0];
                f.weaponSkillMax[type] = value[1];
            }
            f.damage[type] = [stats.damage[type].min, stats.damage[type].max];
            if (item !is null)
                f.damageSchool[type] = item.proto.details.damage[0].school;
        }
        f.crit = chances.crit;
        f.dualWield = dualWield && weaponFor(equipmentSlotOffhand) !is null; // `hasOffhandWeaponForAttack`
        const defense = skillValue(skillDefense);
        f.defenseSkill = defense[0];
        f.defenseSkillMax = defense[1];
        f.dodge = chances.dodge;
        f.parry = chances.parry;
        f.block = chances.block;
        // A parry needs a weapon in hand; a block a shield.
        f.canParry = chances.canParry
            && (weaponFor(equipmentSlotMainhand) !is null || weaponFor(equipmentSlotOffhand) !is null);
        const shield = inventory.equipped(equipmentSlotOffhand);
        f.canBlock = chances.canBlock && shield !is null && shield.proto.details.block
            && (shield.durability != 0 || shield.maxDurability == 0);
        f.shieldBlock = chances.shieldBlock;
        f.armor = stats.resistances[0] > 0 ? stats.resistances[0] : 0;
        return f;
    }

    /// `GetWeaponForAttack`: the weapon (item class 2) in `slot`, if it is not broken; null otherwise.
    /// `GetWeaponSkillIdForAttack`: the skill a swing of `type` uses (unarmed for an empty main hand); 0 if none.
    public uint weaponSkillFor(AttackType type) const
    {
        import dmangos.world.inventory : itemSkill;

        enum uint skillUnarmed = 162;
        static immutable ubyte[3] slots = [equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged];
        const item = weaponFor(slots[type]);
        return item !is null ? itemSkill(item.proto) : type == AttackType.mainHand ? skillUnarmed : 0;
    }

    /// The melee chances again, after a weapon or defense skill changed (`UpdateAllCritPercentages`, `UpdateDefenseBonusesMod`).
    public void refreshChances(const WorldData world)
    {
        chances = meleeChances(chanceInputs(world));
    }

    private const(Item) weaponFor(ubyte slot) const
    {
        enum uint itemClassWeapon = 2;
        const item = inventory.equipped(slot);
        if (item is null || item.proto.itemClass != itemClassWeapon)
            return null;
        return item.durability != 0 || item.maxDurability == 0 ? item : null;
    }

    /// Adds (or takes) power of `type`, within 0 and the maximum (`ModifyPower`). Returns whether it changed.
    public bool modifyPower(Power type, int amount)
    {
        return addPower(type, amount);
    }

    /// What `meleeChances` needs of this player: its weapons' and defense skills, its Parry and Block.
    private ChanceInputs chanceInputs(const WorldData world) const
    {
        import dmangos.world.inventory : itemSkill;
        import dmangos.world.spells : SpellEffect;

        ChanceInputs c;
        c.classId = data.classId;
        c.level = data.level;
        c.agility = stats.stats[Stat.agility];
        c.strength = stats.stats[Stat.strength];
        uint skillFor(ubyte slot, uint unarmed)
        {
            const item = inventory.equipped(slot);
            const skill = item is null ? unarmed : itemSkill(item.proto);
            return skill ? skillValue(skill)[0] : 0;
        }
        enum uint skillUnarmed = 162, skillDefense = 95;
        c.mainHandSkill = skillFor(equipmentSlotMainhand, skillUnarmed);
        c.rangedSkill = skillFor(equipmentSlotRanged, 0);
        c.defenseSkill = skillValue(skillDefense)[0];
        foreach (id; spells)
            if (const info = world.spells.spell(id))
            {
                c.canParry |= info.hasEffect(SpellEffect.parry);
                c.canBlock |= info.hasEffect(SpellEffect.block);
            }
        if (const shield = inventory.equipped(equipmentSlotOffhand))
            if (shield.durability != 0 || shield.maxDurability == 0)
                c.shieldBlock = shield.proto.details.block;
        return c;
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
        setStatFields(data.health == 0 ? uint.max : data.health, data.power);

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

    /// The fields `stats` decides; health and powers are set to `health` and `power`, within the maximums.
    void setStatFields(uint health, const uint[maxPowers] power)
    {
        alias v = values;
        v.set!UNIT_FIELD_MAXHEALTH(stats.maxHealth);
        v.set!UNIT_FIELD_HEALTH(min(health, stats.maxHealth));
        foreach (i; 0 .. maxPowers)
        {
            v.set!UNIT_FIELD_MAXPOWER1(i, stats.maxPower[i]);
            v.set!UNIT_FIELD_POWER1(i, min(power[i], stats.maxPower[i]));
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
        v.set!PLAYER_CRIT_PERCENTAGE(chances.critShown);
        v.set!PLAYER_RANGED_CRIT_PERCENTAGE(chances.rangedCritShown);
        v.set!PLAYER_DODGE_PERCENTAGE(chances.dodgeShown);
        v.set!PLAYER_PARRY_PERCENTAGE(chances.parryShown);
        v.set!PLAYER_BLOCK_PERCENTAGE(chances.blockShown);
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
            if (info.hasEffect(SpellEffect.dualWield)) // Spell::EffectDualWield
                dualWield = true;
        }

        // Player::UpdateFreeTalentPoints
        const spent = talentRanks.byValue.sum;
        const earned = talentPointsForLevel(data.level);
        values.set!PLAYER_CHARACTER_POINTS1(earned > spent ? earned - spent : 0);
        values.set!PLAYER_CHARACTER_POINTS2(abilities.freePrimaryProfessions);
    }
}

/// The talent points a character of `level` has earned: one per level from 10 on.
package uint talentPointsForLevel(uint level) pure nothrow @nogc @safe
{
    return level < 10 ? 0 : level - 9;
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
    auto p = new Player(c, abilities, world, client, testItemGuids());
    assert(p.guid == 7);
    const loaded = p.inventory.all();
    assert(loaded.length == 4, "the unknown, overflowing and doubled-up items are not loaded");

    // The player's slots and the quiver's contents point at the item objects.
    assert(p.values.get!PLAYER_FIELD_INV_SLOT_HEAD(15) == makeGuid(HighGuid.item, 100));
    assert(p.values.get!PLAYER_FIELD_INV_SLOT_HEAD(19) == makeGuid(HighGuid.item, 102));
    assert(p.values.get!PLAYER_FIELD_PACK_SLOT_1 == makeGuid(HighGuid.item, 101));
    const quiver = p.inventory[inventorySlotBag0, 19];
    assert(quiver.values.type == TypeId.container && quiver.values[CONTAINER_FIELD_NUM_SLOTS] == 6);
    assert(quiver.values.get!CONTAINER_FIELD_SLOT_1 == makeGuid(HighGuid.item, 103));
    const arrows = p.inventory[19, 0];
    assert(arrows.values.get!ITEM_FIELD_CONTAINED == makeGuid(HighGuid.item, 102));
    assert(arrows.values.get!ITEM_FIELD_OWNER == p.guid && arrows.count == 200);
    const sword = p.equipped(15);
    assert(sword.values[OBJECT_FIELD_TYPE] == (TypeMask.object | TypeMask.item));
    assert(sword.durability == 20 && sword.maxDurability == 20);

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
    assert(saved.equipmentCache.split.length == 2 * (equipmentSlotEnd + 1));
    assert(saved.equipmentCache.split[2 * equipmentSlotMainhand] == "25" && saved.equipmentCache.split[$ - 2] == "2101",
        "the sword, and the quiver in the first bag slot");
}
