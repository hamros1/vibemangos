/**
 * What professions need beyond reagents, and the professions that work on an item, as CMaNGOS's `Spell::CheckItems`, `Spell::CheckCast`,
 * `Spell::EffectDisEnchant` and `Spell::EffectOpenLock` do it:
 *
 * $(UL
 * $(LI A spell focus (`RequiresSpellFocus`): a game object of type `GAMEOBJECT_TYPE_SPELL_FOCUS` whose focus
 *   (data0) is the spell's must stand within its own distance (data1, plus the caster's combat reach):
 *   an anvil, a forge, a cooking fire. Else `SPELL_FAILED_REQUIRES_SPELL_FOCUS`, with the focus id, and the
 *   client names it ("Requires Anvil").)
 * $(LI Tools (`Totem1`, `Totem2`): each must be in the bags (a blacksmith hammer, a mining pick, thieves'
 *   tools); else `SPELL_FAILED_TOTEMS` with the tools. A triggered spell needs neither tools nor reagents.)
 * $(LI Disenchanting (`SPELL_EFFECT_DISENCHANT`): the item aimed at must be the caster's own, with a
 *   `DisenchantID` (uncommon to epic weapons and armor); else `SPELL_FAILED_CANT_BE_DISENCHANTED`. Cast, the
 *   enchanting skill may rise as a craft's, and the item's `disenchant_loot_template` opens as a loot window;
 *   released, what was not taken goes into the bags and the item is destroyed. CMaNGOS checks no enchanting
 *   skill against the item: the client does that.)
 * $(LI Picking an item's lock (a lockbox: `SPELL_EFFECT_OPEN_LOCK` or `_OPEN_LOCK_ITEM` aimed at an item with a
 *   `LockID`): the item must be the caster's (`SPELL_FAILED_ITEM_GONE`), still locked
 *   (`SPELL_FAILED_ALREADY_OPEN`), and the lock opened by the spell's lock type and skill
 *   (`canOpenLock`: `SPELL_FAILED_LOW_CASTLEVEL`). As the cast completes an orange lock may still resist
 *   (`SPELL_FAILED_TRY_AGAIN`: the lock's level against a roll from 25 under to 37 over the skill). Opened,
 *   the lockpicking skill may rise (not with a key), the item is marked unlocked (`ITEM_DYNFLAG_UNLOCKED`)
 *   and its loot opens.)
 * )
 */
module dmangos.world.professions;

/// Whether a picked lock resists this attempt (CMaNGOS `Spell::CheckCast`, open lock): the lock's level
/// `required` above `roll`, a roll from 25 under to 37 over the skill `value`.
bool lockResists(int required, int roll) pure nothrow @nogc @safe
{
    return required > roll;
}

/// Whether `go` (type, focus, distance) is a spell focus of `focus` close enough to `distance` away (3D, yards)
/// for a caster of reach `combatReach` (CMaNGOS `GameObjectFocusCheck`, `IsWithinDistInMap`).
bool focusInReach(uint type, uint goFocus, uint goDistance, uint focus, float distance, float combatReach) pure nothrow @nogc @safe
{
    enum uint spellFocusType = 8;
    return type == spellFocusType && goFocus == focus && distance < goDistance + combatReach;
}

/**
 * The skinning skill a creature of `level` asks for (docs/FORMULAS.md, "Skinning"): 1 up to level 10, ten a level
 * from there (100 at level 20), then five a level (300 at level 60).
 */
int skinningSkillFor(int level) pure nothrow @nogc @safe
{
    if (level <= 10)
        return 1;
    return level <= 20 ? (level - 10) * 10 : level * 5;
}

/**
 * The chance in a thousand that a fish caught raises fishing `skill` (without what a pole or lure adds) by one
 * (docs/FORMULAS.md, "Fishing"): every catch below 100, then a point every 2 catches, and one catch more every 25
 * points from 115 (10 catches a point from 290).
 */
int fishingSkillUpChance(int skill) pure nothrow @nogc @safe
{
    const catches = skill < 100 ? 1 : (skill - 90) / 25 + 2;
    return 1000 / catches;
}

unittest
{
    assert(skinningSkillFor(5) == 1 && skinningSkillFor(10) == 1 && skinningSkillFor(11) == 10);
    assert(skinningSkillFor(20) == 100 && skinningSkillFor(21) == 105 && skinningSkillFor(60) == 300);
    assert(fishingSkillUpChance(1) == 1000 && fishingSkillUpChance(99) == 1000);
    assert(fishingSkillUpChance(100) == 500 && fishingSkillUpChance(114) == 500 && fishingSkillUpChance(115) == 333);
    assert(fishingSkillUpChance(140) == 250 && fishingSkillUpChance(289) == 111 && fishingSkillUpChance(290) == 100);
}

unittest
{
    assert(focusInReach(8, 1, 10, 1, 11, 1.5f), "within its 10 yards and the caster's reach");
    assert(!focusInReach(8, 1, 10, 1, 11.6f, 1.5f) && !focusInReach(8, 3, 10, 1, 1, 1.5f) && !focusInReach(3, 1, 10, 1, 1, 1.5f));
    assert(lockResists(100, 99) && !lockResists(100, 100));
}

/// A focus on the other side of a region boundary works at the same distance as a local one.
unittest
{
    import dmangos.world.character : Character;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(100, 100, 40);
    auto client = loggedIn(context, db, 7, "Anduin", at);
    auto caster = context.onlinePlayer(client.session.character.guid);
    auto map = context.map(0);
    SpellInfo spell;
    spell.casting.requiresSpellFocus = 501;
    GameObjectTemplate focus = {entry: 800, type: GameObjectType.spellFocus};
    focus.data[0] = 501;
    focus.data[1] = 10;
    context.data.gameObjectTemplates[800] = focus;
    auto wrong = focus;
    wrong.entry = 801;
    wrong.data[0] = 502;
    context.data.gameObjectTemplates[801] = wrong;
    ulong observe(uint guid, uint entry, float z)
    {
        const spawn = GameObjectSpawn(guid: guid, entry: entry, x: at.x, y: at.y, z: z);
        auto go = context.makeGameObject(spawn);
        map.replicaCreated(2, cellKeyAt(at.x, at.y), go.guid, encodeState(go, 0));
        return go.guid;
    }
    observe(1, 801, at.z);
    observe(2, 800, at.z + 20);
    assert(caster.professions.checkSpellFocus(&spell) == SpellCastResult.requiresSpellFocus);
    const near = observe(3, 800, at.z + 5);
    assert(caster.professions.checkSpellFocus(&spell) == SpellCastResult.ok);
    map.replicaRemoved(2, near);
    assert(caster.professions.checkSpellFocus(&spell) == SpellCastResult.requiresSpellFocus);
}

/// See the module documentation.
final class Professions
{
    import dmangos.world.character : Character;
    import dmangos.world.session : Handles, WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import std.random : uniform;
    import dmangos.world.gameobject : GameObject, GameObjectTemplate, GameObjectType;
    import dmangos.world.inventory : Item, ItemState, itemDynFlagUnlocked;
    import dmangos.world.professions : focusInReach, lockResists;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    /// The spell's focus near (see the module documentation), or `SPELL_FAILED_REQUIRES_SPELL_FOCUS`.
    package SpellCastResult checkSpellFocus(const(SpellInfo)* spell)
    {
        import dmangos.world.replication : Replica;

        const focus = spell.casting.requiresSpellFocus;
        if (!focus || spell.isPassive)
            return SpellCastResult.ok;
        const at = me.player.position, reach = me.player.values.get!UNIT_FIELD_COMBATREACH;
        enum float search = 100; // the farthest focus distance in the data
        foreach (object; me.map.objectsNear(at, search))
        {
            const(GameObjectTemplate)* template_;
            if (auto go = cast(GameObject) object)
                template_ = go.template_;
            else if (auto copy = cast(Replica) object)
                if (copy.fields.type == TypeId.gameObject)
                    template_ = copy.fields.get!OBJECT_FIELD_ENTRY in me.context.data.gameObjectTemplates;
            if (template_ is null)
                continue;
            const p = object.position;
            const distance = ((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2) ^^ 0.5f;
            if (focusInReach(template_.type, template_.data[0], template_.data[1], focus, distance, reach))
                return SpellCastResult.ok;
        }
        return SpellCastResult.requiresSpellFocus;
    }

    /// The spell's tools in the bags (see the module documentation), or `SPELL_FAILED_TOTEMS`.
    package SpellCastResult checkTools(const(SpellInfo)* spell)
    {
        foreach (tool; spell.casting.totems)
            if (tool && me.player.inventory.count(tool) == 0)
                return SpellCastResult.totems;
        return SpellCastResult.ok;
    }

    /**
     * Whether a spell may work on the item aimed at (`targets.item`): disenchanting, or picking its lock.
     * `start`: the cast is starting (the chance that the lock resists is rolled as it completes).
     */
    package SpellCastResult checkItemTarget(const(SpellInfo)* spell, const ref SpellTargets targets, uint castItem,
        bool start)
    {
        foreach (i; 0 .. 3)
            switch (spell.effect[i])
            {
            case SpellEffect.disenchant:
            {
                // The caster's own (not one in the trade window), and one that disenchants.
                const item = me.trading.itemByGuid(targets.item);
                if (item is null || !item.proto.details.disenchantId)
                    return SpellCastResult.cantBeDisenchanted;
                break;
            }
            case SpellEffect.openLock, SpellEffect.openLockItem:
            {
                if (targets.gameObject || !targets.item)
                    break; // a game object's: `checkGameObjectTarget`
                const item = me.trading.itemByGuid(targets.item);
                if (item is null)
                    return SpellCastResult.itemGone;
                const lockId = item.proto.details.lockId;
                if (!lockId || (item.values[ITEM_FIELD_FLAGS] & itemDynFlagUnlocked))
                    return SpellCastResult.alreadyOpen;
                uint skillId;
                int required, value;
                const result = me.canOpenLock(spell, i, lockId, castItem, skillId, required, value);
                if (result != SpellCastResult.ok)
                    return result;
                // An orange lock may resist as the cast completes (lockpicking may fail even at the most skill).
                if (!start && skillId && !castItem && lockResists(required, uniform!"[]"(value - 25, value + 37, me.map.random)))
                    return SpellCastResult.tryAgain;
                break;
            }
            default:
                break;
            }
        return SpellCastResult.ok;
    }

    /// `SPELL_EFFECT_DISENCHANT` on the player's item `itemGuid`: see the module documentation.
    package void disenchantItem(const(SpellInfo)* spell, ulong itemGuid)
    {
        auto item = me.trading.itemByGuid(itemGuid);
        if (item is null || !item.proto.details.disenchantId)
            return;
        me.enchanting.updateCraftSkill(spell.id);
        me.showItemLoot(item, true);
    }

    /**
     * `SPELL_EFFECT_OPEN_LOCK` on the player's item `itemGuid` (a lockbox): its lock opened, the lockpicking
     * skill may rise (not with a key, and once: not while its loot is open), the item is unlocked and its loot
     * opens.
     */
    package void openItemLock(const(SpellInfo)* spell, size_t i, ulong itemGuid, uint castItem)
    {
        auto item = me.trading.itemByGuid(itemGuid);
        if (item is null)
            return;
        uint skillId;
        int required, value;
        if (me.canOpenLock(spell, i, item.proto.details.lockId, castItem, skillId, required, value) != SpellCastResult.ok)
            return;
        if (skillId && !castItem && itemGuid !in me.itemLoots)
            if (const pure_ = me.player.skillValue(skillId)[0])
                me.updateGatherSkill(skillId, pure_, required);
        item.values.set!ITEM_FIELD_FLAGS(item.values[ITEM_FIELD_FLAGS] | itemDynFlagUnlocked);
        me.player.inventory.setState(item, ItemState.changed);
        me.flushInventory();
        me.showItemLoot(item);
    }
}
