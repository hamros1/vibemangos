/**
 * What professions need beyond reagents, and the professions that work on an item, mixed into
 * `dmangos.world.character.Character`, as CMaNGOS's `Spell::CheckItems`, `Spell::CheckCast`,
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

unittest
{
    assert(focusInReach(8, 1, 10, 1, 11, 1.5f), "within its 10 yards and the caster's reach");
    assert(!focusInReach(8, 1, 10, 1, 11.6f, 1.5f) && !focusInReach(8, 3, 10, 1, 1, 1.5f) && !focusInReach(3, 1, 10, 1, 1, 1.5f));
    assert(lockResists(100, 99) && !lockResists(100, 100));
}

/// See the module documentation.
mixin template ProfessionHandlers()
{
    import std.random : uniform;
    import dmangos.world.gameobject : GameObject, GameObjectType;
    import dmangos.world.inventory : Item, ItemState, itemDynFlagUnlocked;
    import dmangos.world.professions : focusInReach, lockResists;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    /// The spell's focus near (see the module documentation), or `SPELL_FAILED_REQUIRES_SPELL_FOCUS`.
    package SpellCastResult checkSpellFocus(const(SpellInfo)* spell)
    {
        const focus = spell.casting.requiresSpellFocus;
        if (!focus || spell.isPassive)
            return SpellCastResult.ok;
        const at = player.position, reach = player.values.get!UNIT_FIELD_COMBATREACH;
        enum float search = 100; // the farthest focus distance in the data
        foreach (o; map.objectsNear(at, search))
            if (auto go = cast(GameObject) o)
            {
                const p = go.position;
                const distance = ((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2) ^^ 0.5f;
                if (focusInReach(go.template_.type, go.template_.data[0], go.template_.data[1], focus, distance, reach))
                    return SpellCastResult.ok;
            }
        return SpellCastResult.requiresSpellFocus;
    }

    /// The spell's tools in the bags (see the module documentation), or `SPELL_FAILED_TOTEMS`.
    package SpellCastResult checkTools(const(SpellInfo)* spell)
    {
        foreach (tool; spell.casting.totems)
            if (tool && player.inventory.count(tool) == 0)
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
                const item = itemByGuid(targets.item);
                if (item is null || !item.proto.details.disenchantId)
                    return SpellCastResult.cantBeDisenchanted;
                break;
            }
            case SpellEffect.openLock, SpellEffect.openLockItem:
            {
                if (targets.gameObject || !targets.item)
                    break; // a game object's: `checkGameObjectTarget`
                const item = itemByGuid(targets.item);
                if (item is null)
                    return SpellCastResult.itemGone;
                const lockId = item.proto.details.lockId;
                if (!lockId || (item.values[ITEM_FIELD_FLAGS] & itemDynFlagUnlocked))
                    return SpellCastResult.alreadyOpen;
                uint skillId;
                int required, value;
                const result = canOpenLock(spell, i, lockId, castItem, skillId, required, value);
                if (result != SpellCastResult.ok)
                    return result;
                // An orange lock may resist as the cast completes (lockpicking may fail even at the most skill).
                if (!start && skillId && !castItem && lockResists(required, uniform!"[]"(value - 25, value + 37, map.random)))
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
        auto item = itemByGuid(itemGuid);
        if (item is null || !item.proto.details.disenchantId)
            return;
        updateCraftSkill(spell.id);
        showItemLoot(item, true);
    }

    /**
     * `SPELL_EFFECT_OPEN_LOCK` on the player's item `itemGuid` (a lockbox): its lock opened, the lockpicking
     * skill may rise (not with a key, and once: not while its loot is open), the item is unlocked and its loot
     * opens.
     */
    package void openItemLock(const(SpellInfo)* spell, size_t i, ulong itemGuid, uint castItem)
    {
        auto item = itemByGuid(itemGuid);
        if (item is null)
            return;
        uint skillId;
        int required, value;
        if (canOpenLock(spell, i, item.proto.details.lockId, castItem, skillId, required, value) != SpellCastResult.ok)
            return;
        if (skillId && !castItem && itemGuid !in itemLoots)
            if (const pure_ = player.skillValue(skillId)[0])
                updateGatherSkill(skillId, pure_, required);
        item.values.set!ITEM_FIELD_FLAGS(item.values[ITEM_FIELD_FLAGS] | itemDynFlagUnlocked);
        player.inventory.setState(item, ItemState.changed);
        flushInventory();
        showItemLoot(item);
    }
}
