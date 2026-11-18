/**
 * Casting spells: the cast opcodes, checking, counting down, casting, the cost, the hit rolls and
 * the spell effects, mixed into `dmangos.world.character.Character`.
 *
 * A cast is checked (known, alive, not busy, off cooldown, enough power and reagents, a fitting
 * target in range and in sight), shown (`SMSG_SPELL_START`), counts down its cast time (moving
 * interrupts most), then goes: its cooldowns start, its power and reagents are taken, the hit is
 * rolled against each hostile target, everyone around sees it (`SMSG_SPELL_GO`) and the effects
 * happen. Spells "on next swing" (Heroic Strike) wait for the next main-hand swing and replace it.
 * Items with an on-use spell (food, drink, the hearthstone) cast it.
 *
 * The effects done so far: school damage, weapon damage (with bonus and percentage), heals,
 * energize, teleports (home bind), creating items, learning spells, triggering spells. Auras
 * (`SPELL_EFFECT_APPLY_AURA`) are logged as not yet done; so are the others.
 */
module dmangos.world.spellhandlers;

/// See the module documentation.
mixin template SpellHandlers()
{
    import dmangos.world.spellmods : applySpellMod, effectOp, SpellModOp;
    import std.algorithm.comparison : max;
    import core.time : Duration, msecs, MonoTime;
    import std.random : uniform, uniform01;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info, warning;
    import dmangos.world.combat : AttackType, armorReducedDamage, blockChance, critChance, dodgeChance, missChance,
        parryChance, weaponDamage;
    import dmangos.world.auras : AuraInterrupt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.creature : Creature;
    import dmangos.world.unit : UnitKind, UnitRef;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.loot : LootItem;
    import dmangos.world.defines : Power, Stat;
    import dmangos.world.movement : MovementFlags, Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : DeathState;
    import dmangos.world.relations : canAttack, isEnemy, isFriend;
    import dmangos.world.spellcast;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.updatefields;

private:
    /// A spell being cast or waiting for the next swing.
    struct Casting
    {
        const(SpellInfo)* spell;
        SpellTargets targets;
        int timer;            // milliseconds until it goes
        uint castItemEntry;   // the item it is cast from: no power, the item's cooldown
        bool triggered;
        bool active;
        ubyte persistentDone; // effects whose persistent area is made (once a cast, not once a target)
    }

    /// A missile's effect on its target, due when it arrives.
    static struct PendingHit
    {
        const(SpellInfo)* spell;
        size_t effect;
        ulong target;
        Casting casting;
        int left;      // ms of flight left
    }

    /// A persistent area aura's spot under way (`DynamicObject` with its aura).
    static struct PersistentArea
    {
        import dmangos.world.dynobject : DynamicObject;

        DynamicObject spot;
        const(SpellInfo)* spell;
        size_t effect;
        int value;      // each tick's damage
        int amplitude;  // ms between ticks
        int timer;      // ms to the next tick
        int left;       // ms it lasts yet
    }

    Casting generic;                 // the spell being cast (with a cast time), if any
    const(SpellInfo)* channelSpell;  // the spell being channelled, if any
    ulong channelObject;             // an object the channel is at (a fishing bobber)
    ulong bobber;                    // this angler's fishing bobber, while it floats
    int bobberAge, bobberBite, bobberGone; // ms since cast; when the fish bites; when the bobber goes
    bool bobberLooted;               // the catch is being looted: the bobber stays until then
    bool channelFailed;              // an effect of the spell failed (not fishable): no channel
    PersistentArea[] persistentAreas; // this caster's spots of persistent area auras
    PendingHit[] pendingHits;         // missiles on their way: their effects when they arrive
    ulong channelTarget;             // ... at whom
    int channelTimer;                // ... for so many more milliseconds
    Casting nextSwing;               // the spell waiting for the next main-hand swing, if any
    MonoTime[uint] spellReadyAt;     // when each spell's cooldown ends
    MonoTime[uint] categoryReadyAt;  // ... and by category
    uint[uint] cooldownCategory;     // spell -> the category its cooldown started (to save and show it)
    uint[uint] cooldownItem;         // spell -> the item it was cast from
    MonoTime gcdReadyAt;             // when category 133's global cooldown ends

    // -----------------------------------------------------------------------
    // The opcodes
    // -----------------------------------------------------------------------

    /// The client casts a spell the player knows, at what it chose.
    @Handles(Opcode.CMSG_CAST_SPELL, WorldState.inWorld)
    void handleCastSpell(ref ByteReader reader)
    {
        const id = reader.read!uint;
        auto targets = SpellTargets.read(reader);
        const spell = context.data.spells.spell(id);
        // Not known or passive: a cheat, ignored.
        if (spell is null || !player.knowsSpell(id) || spell.isPassive)
            return;
        // At another node's creature: cast there.
        if (targets.unit && targets.unit != player.guid && actAtReplica(targets.unit, ArrivalAction(0, id, targets.unit)))
            return;
        // At another node's game object (a lock): opened there.
        if (targets.gameObject && actAtReplica(targets.gameObject, ArrivalAction(0, id, 0, 0, 0, targets.gameObject)))
            return;
        castSpell(spell, targets, false, 0);
    }

    /// The client cancels the cast in progress.
    @Handles(Opcode.CMSG_CANCEL_CAST, WorldState.inWorld)
    void handleCancelCast(ref ByteReader reader)
    {
        const id = reader.read!uint;
        if (generic.active && generic.spell.id == id)
            interruptCast(SpellCastResult.interrupted);
        else if (nextSwing.active && nextSwing.spell.id == id)
            nextSwing.active = false;
    }

    /// The client uses an item: its on-use spell (food, drink, a hearthstone).
    @Handles(Opcode.CMSG_USE_ITEM, WorldState.inWorld)
    void handleUseItem(ref ByteReader reader)
    {
        const bag = reader.read!ubyte, slot = reader.read!ubyte;
        reader.read!ubyte; // spell count
        auto targets = SpellTargets.read(reader);
        const item = player.inventory[bag, slot];
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        const proto = item.proto;
        if (proto.requiredLevel > player.data.level)
            return sendEquipError(InventoryResult.cantEquipLevel, item);
        enum uint triggerOnUse = 0;
        foreach (ref use; proto.details.spells)
        {
            if (use.id == 0 || use.trigger != triggerOnUse)
                continue;
            const spell = context.data.spells.spell(use.id);
            if (spell is null)
                continue;
            castSpell(spell, targets, false, proto.entry);
            break;
        }
    }

    // -----------------------------------------------------------------------
    // Casting
    // -----------------------------------------------------------------------

    /**
     * A spell starting: checked, shown, and either cast now (instant), kept for the
     * next swing, or counted down.
     */
    /// A spell a script casts for the player (triggered: no checks, no cost): at `target` (a unit), or itself.
    package void castTriggeredAt(uint spellId, ulong target)
    {
        const spell = context.data.spells.spell(spellId);
        if (spell is null || player is null)
            return;
        castSpell(spell, SpellTargets(TargetFlags.unit, target ? target : player.guid), true, 0);
    }

    // -----------------------------------------------------------------------
    // Auto-repeating spells (Auto Shot, a wand's Shoot)
    // -----------------------------------------------------------------------

    private const(SpellInfo)* autoRepeat; /// the spell shot again and again; null if none
    private int autoRepeatMs;             /// until the next shot
    private bool autoRepeatWindUp;        /// moved (or just began): half a second before shooting

    /**
     * What a shot of `spell` (a spell of the ranged slot, `SPELL_ATTR_RANGED`) uses up: with a bow, gun or
     * crossbow, one of the ammunition set (`PLAYER_AMMO_ID`); with a thrown weapon that stacks, one of it.
     * False if it uses nothing.
     */
    private bool ammoFor(const(SpellInfo)* spell, out uint entry)
    {
        import dmangos.world.defines : equipmentSlotRanged, InventoryType;

        enum uint spellAttrRanged = 0x2, itemClassWeapon = 2, bow = 2, gun = 3, crossbow = 18;
        if (!(spell.attributes & spellAttrRanged))
            return false;
        const weapon = player.inventory.equipped(equipmentSlotRanged);
        if (weapon is null || weapon.proto is null)
            return false;
        if (weapon.proto.inventoryType == InventoryType.thrown)
        {
            if (weapon.proto.stackable <= 1)
                return false; // one that does not stack is not used up (it would wear instead)
            entry = weapon.proto.entry;
            return true;
        }
        const sub = weapon.proto.subClass;
        if (weapon.proto.itemClass != itemClassWeapon || (sub != bow && sub != gun && sub != crossbow))
            return false;
        entry = player.values.get!PLAYER_AMMO_ID;
        return true;
    }

    /// Whether the player has what a shot of `spell` uses up.
    private bool hasAmmoFor(const(SpellInfo)* spell)
    {
        uint entry;
        return !ammoFor(spell, entry) || (entry != 0 && player.inventory.count(entry) > 0);
    }

    /// A shot of `spell` uses up its ammunition (or thrown weapon).
    private void takeAmmo(const(SpellInfo)* spell)
    {
        uint entry;
        if (ammoFor(spell, entry) && entry)
        {
            player.inventory.destroyCount(entry, 1);
            flushInventory();
        }
    }

    /// Whether `spell` is off its cooldown.
    package bool spellIsReady(uint spell)
    {
        if (auto at = spell in spellReadyAt)
            return context.clock() >= *at;
        return true;
    }

    /// Starts `spell`'s cooldown (its recovery time), as casting it does.
    private MonoTime[7] schoolLockedUntil; /// each school's lockout (an interrupt's), till then

    /**
     * Interrupted: the school of the cast that was going is locked for `ms` (the interrupt's duration); the
     * client sees its spells of the school cooling down (`SMSG_SPELL_COOLDOWN`).
     */
    package void lockOutSchool(uint school, int ms)
    {
        import core.time : msecs;
        import dmangos.bytes : ByteWriter;

        if (school >= schoolLockedUntil.length || ms <= 0)
            return;
        schoolLockedUntil[school] = context.clock() + ms.msecs;
        ByteWriter w;
        w.put(player.guid);
        foreach (id; player.spells)
            if (const s = context.data.spells.spell(id))
                if (s.casting.school == school && !s.isPassive)
                {
                    w.put(id);
                    w.put(cast(uint) ms);
                }
        deliver(Opcode.SMSG_SPELL_COOLDOWN, w.data);
    }

    package void startCooldown(const(SpellInfo)* spell)
    {
        import core.time : msecs;

        if (spell.recoveryTime > 0 && !cooldownCheat)
            spellReadyAt[spell.id] = context.clock() + (cast(long) spell.recoveryTime).msecs;
    }

    /// An auto-repeating spell (`SPELL_ATTR_EX2_AUTOREPEAT_FLAG`) cast by the client.
    static bool autoRepeats(const(SpellInfo)* spell) pure nothrow @nogc @safe
    {
        enum uint spellAttrEx2AutoRepeat = 0x20;
        return (spell.attributesEx2 & spellAttrEx2AutoRepeat) != 0;
    }

    /// Starts shooting `spell` again and again at the player's target (the first shot after half a second).
    private SpellCastResult startAutoRepeat(const(SpellInfo)* spell, SpellTargets targets)
    {
        const result = checkCast(spell, targets, false, 0, false);
        if (result != SpellCastResult.ok)
        {
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
            return result;
        }
        autoRepeat = spell;
        autoRepeatWindUp = true;
        return SpellCastResult.ok;
    }

    /// The client stops shooting.
    @Handles(Opcode.CMSG_CANCEL_AUTO_REPEAT_SPELL, WorldState.inWorld)
    void handleCancelAutoRepeat()
    {
        autoRepeat = null;
    }

    /**
     * Each tick: the auto-repeating spell shoots at the player's current target whenever its time comes
     * (the ranged weapon's attack time). Moving holds it (and ends a wand's, which moving cancels); a
     * target it may not shoot at, or a failed check, ends it.
     */
    package void updateAutoRepeat(Duration elapsed)
    {
        if (autoRepeat is null || player is null)
            return;
        enum uint movingCancels = 0x08; // AURA_INTERRUPT_FLAG_MOVING
        import dmangos.world.movement : MovementFlags;

        enum uint moving = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
            | MovementFlags.strafeRight | MovementFlags.fallingFar; // not just turning
        if (player.movement.flags & moving)
        {
            if (autoRepeat.casting.channelInterruptFlags & movingCancels)
            {
                autoRepeat = null;
                return;
            }
            autoRepeatWindUp = true;
            return;
        }
        if (autoRepeatWindUp)
        {
            autoRepeatWindUp = false;
            if (autoRepeatMs < 500)
                autoRepeatMs = 500;
            return;
        }
        autoRepeatMs -= cast(int) elapsed.total!"msecs";
        if (autoRepeatMs > 0)
            return;
        const target = player.values.get!UNIT_FIELD_TARGET;
        if (!target)
        {
            autoRepeat = null;
            return;
        }
        auto targets = SpellTargets(TargetFlags.unit, target);
        const result = checkCast(autoRepeat, targets, false, 0, false);
        if (result != SpellCastResult.ok)
        {
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(autoRepeat.id, result, autoRepeat));
            autoRepeat = null;
            return;
        }
        const spell = autoRepeat;
        if (!hasAmmoFor(spell))
        {
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.noAmmo, spell));
            autoRepeat = null;
            return;
        }
        castSpell(spell, targets, true, 0);
        takeAmmo(spell);
        // A ranged attack that went: the shooter's auras that proc on it, and the target's if a player.
        {
            import dmangos.world.aurahandlers : ProcFlag;

            procAuras(ProcFlag.dealRangedAttack, map.unit(target));
            if (auto other = cast(typeof(this)) context.onlinePlayer(target))
                if (other.player !is null && other.map is map)
                    other.procAuras(ProcFlag.takeRangedAttack, unit);
        }
        autoRepeatMs = cast(int) player.values.get!UNIT_FIELD_RANGEDATTACKTIME + cast(int) spell.recoveryTime;
    }

    package SpellCastResult castSpell(const(SpellInfo)* spell, SpellTargets targets, bool triggered, uint itemEntry)
    {
        // Auto Shot and the like: from now on, at each of their times.
        if (!triggered && autoRepeats(spell))
            return startAutoRepeat(spell, targets);
        if (targets.mask == TargetFlags.self)
            targets.unit = player.guid;
        const result = checkCast(spell, targets, triggered, itemEntry, true);
        if (result != SpellCastResult.ok)
        {
            if (!triggered)
                deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
            return result;
        }
        auto c = Casting(spell, targets, 0, itemEntry, triggered, true);
        if (!triggered)
        {
            c.timer = castTimeCheat ? 0 : max(0, spellMod(SpellModOp.castingTime, spell,
                castTime(*spell, context.client, player.data.level)));
            enum uint gcdCategory = 133;
            if (spell.casting.startRecoveryCategory == gcdCategory && spell.casting.startRecoveryTime)
                gcdReadyAt = context.clock() + spell.casting.startRecoveryTime.msecs;
            map.sendToWatchers(this, Opcode.SMSG_SPELL_START, spellStartPacket(player.guid, spell.id,
                cast(uint) c.timer, targets), true);
        }
        if (isNextMeleeSwingSpell(*spell))
        {
            nextSwing = c;
            return SpellCastResult.ok;
        }
        if (c.timer <= 0)
            return go(c);
        generic = c;
        return SpellCastResult.ok;
    }

    /// The countdown of a cast in progress: it goes when its time is up.
    void updateSpells(Duration elapsed)
    {
        if (bobber)
            updateBobber(cast(int) elapsed.total!"msecs");
        if (persistentAreas.length)
            updatePersistentAreas(cast(int) elapsed.total!"msecs");
        if (pendingHits.length)
        {
            // The missiles that arrive now (a copy: an effect may cast another).
            const diff = cast(int) elapsed.total!"msecs";
            PendingHit[] due;
            PendingHit[] still;
            foreach (hit; pendingHits)
            {
                hit.left -= diff;
                (hit.left <= 0 ? due : still) ~= hit;
            }
            pendingHits = still;
            foreach (hit; due)
                doEffect(hit.spell, hit.effect, hit.target, hit.casting);
            if (due.length)
                flushPlayerChanges();
        }
        if (channelSpell !is null && (channelTimer -= cast(int) elapsed.total!"msecs") <= 0)
            endChannel(false);
        if (!generic.active)
            return;
        generic.timer -= cast(int) elapsed.total!"msecs";
        if (generic.timer > 0)
            return;
        auto c = generic;
        generic.active = false;
        go(c);
    }

    /// The cast in progress stops; the player and everyone around are told.
    void interruptCast(SpellCastResult reason)
    {
        if (!generic.active)
            return;
        const id = generic.spell.id;
        generic.active = false;
        map.sendToWatchers(this, Opcode.SMSG_SPELL_FAILURE, spellFailurePacket(player.guid, id, reason), true);
        deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(id, reason));
    }

    /**
     * A channelled spell (`SPELL_ATTR_EX_IS_CHANNELED`, `_IS_SELF_CHANNELED`)
     * goes on for its duration: `MSG_CHANNEL_START`, and the caster's channel fields for everyone.
     */
    void startChannel(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.spellcast : duration;

        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        if (ms <= 0)
            return;
        if (channelSpell !is null)
            endChannel(true);
        channelSpell = spell;
        channelTarget = channelObject ? channelObject : target ? target : player.guid;
        channelObject = 0;
        channelTimer = ms;
        ByteWriter w;
        w.put(spell.id);
        w.put(cast(uint) ms);
        deliver(Opcode.MSG_CHANNEL_START, w.data);
        player.values.set!UNIT_CHANNEL_SPELL(spell.id);
        player.values.set!UNIT_FIELD_CHANNEL_OBJECT(channelTarget);
        flushPlayerChanges();
    }

    /**
     * The channel ends, at its time or cut short (`cancelled`: moving,
     * `CMSG_CANCEL_CHANNELLING`, another cast), when its auras on the target go with it.
     */
    void endChannel(bool cancelled)
    {
        if (channelSpell is null)
            return;
        const spell = channelSpell;
        channelSpell = null;
        if (cancelled)
        {
            if (auto creature = cast(Creature) map.findObject(channelTarget))
            {
                if (auto aura = creature.auras.find(spell.id))
                    if (aura.caster == player.guid)
                    {
                        creature.auras.remove(aura, creature.values);
                        map.flushCreature(creature);
                    }
            }
            else if (channelTarget == player.guid)
            {
                if (auto aura = player.auras.find(spell.id))
                    removeAura(aura);
            }
            else if (auto other = map.unit(channelTarget))
                other.auraRemovedBy(spell.id);
            map.sendToWatchers(this, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(player.guid, spell.id, SpellCastResult.interrupted), true);
        }
        if (bobber && !bobberLooted)
            removeBobber();
        // Tame Beast's twenty seconds are up: the beast is tamed.
        if (!cancelled && spell.id == imported!"dmangos.world.pethandlers".spellTameBeast)
            tameBeastChannelDone(channelTarget);
        // A channel cancelled: its spots go with it.
        if (cancelled)
            foreach_reverse (k, ref area; persistentAreas)
                if (area.spell is spell)
                {
                    map.removeObject(area.spot.guid);
                    persistentAreas = persistentAreas[0 .. k] ~ persistentAreas[k + 1 .. $];
                }
        ByteWriter w;
        w.put(0u);
        deliver(Opcode.MSG_CHANNEL_UPDATE, w.data);
        player.values.set!UNIT_CHANNEL_SPELL(0u);
        player.values.set!UNIT_FIELD_CHANNEL_OBJECT(0UL);
        flushPlayerChanges();
    }

    /// The client stops channelling.
    @Handles(Opcode.CMSG_CANCEL_CHANNELLING, WorldState.inWorld)
    void handleCancelChanneling(ref ByteReader reader)
    {
        const id = reader.read!uint;
        if (channelSpell !is null && channelSpell.id == id)
            endChannel(true);
    }

    /**
     * A fishing bobber cast: between the spell's least and greatest range in
     * front of the angler, a little to either side, on the water there (or the cast fails: not
     * fishable). The fish bites 3, 7, 13 or 17 seconds before the channel would end, and the bobber
     * waits 5 seconds more for the angler.
     */
    void castBobber(const(SpellInfo)* spell, size_t i)
    {
        import std.math : cos, sin;
        import std.random : uniform, uniform01;
        import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectType;
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.world.spellcast : duration, range;

        const entry = cast(uint) spell.miscValue[i];
        const t = entry in context.data.gameObjectTemplates;
        if (t is null || t.type != GameObjectType.fishingNode)
            return;
        auto r = range(*spell, context.client);
        r[1] = spellMod(SpellModOp.range, spell, r[1]);
        const distance = uniform01(map.random) * (r[1] - r[0]) + r[0];
        const maxAngle = (r[1] - r[0]) / (r[1] + 0.5f);
        const at = player.position;
        const angle = at.orientation + maxAngle * (uniform01(map.random) - 0.5f);
        const x = at.x + (distance + 0.5f) * cos(angle), y = at.y + (distance + 0.5f) * sin(angle);
        float level;
        if (!map.waterAt(x, y, at.z + 1, level))
        {
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.notFishable));
            channelFailed = true;
            return;
        }
        if (bobber)
            removeBobber();
        GameObjectSpawn spawn = {guid: context.nextTemporaryCounter(), entry: entry, map: map.id, x: x, y: y, z: level,
            orientation: at.orientation, respawnSeconds: -1};
        auto go = new GameObject(spawn, t);
        go.owner = player.guid;
        go.instanceId = map.instanceId;
        go.values.set!OBJECT_FIELD_CREATED_BY(player.guid);
        go.values.set!GAMEOBJECT_LEVEL(player.data.level);
        map.addObject(go);
        bobber = go.guid;
        channelObject = go.guid;
        bobberAge = 0;
        bobberLooted = false;
        static immutable int[4] lastSeconds = [3, 7, 13, 17];
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        bobberBite = ms - lastSeconds[uniform(0, 4, map.random)] * 1000;
        bobberGone = bobberBite + 5000;
    }

    /// The bobber's time: the fish bites (the bobber splashes); later, it got away (`SMSG_FISH_NOT_HOOKED`).
    void updateBobber(int diff)
    {
        import dmangos.world.gameobject : GameObject;

        auto go = cast(GameObject) map.findObject(bobber);
        if (go is null)
            return cast(void)(bobber = 0);
        const before = bobberAge;
        bobberAge += diff;
        if (before < bobberBite && bobberAge >= bobberBite)
        {
            go.values.set!GAMEOBJECT_STATE(0u); // GO_STATE_ACTIVE
            map.flushGameObject(go);
            ByteWriter w;
            w.put(go.guid);
            w.put(0u);
            map.sendToObservers(go.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, w.data);
        }
        if (!bobberLooted && bobberAge >= bobberGone)
        {
            deliver(Opcode.SMSG_FISH_NOT_HOOKED, null);
            endChannel(false);
        }
    }

    /**
     * A persistent area effect: a dynamic object at the destination (or the caster) of the effect's
     * radius, lasting the spell's duration; every amplitude it hurts the creatures the caster may
     * attack within it (`SPELL_AURA_PERIODIC_DAMAGE`'s ticks).
     */
    void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)
    {
        import dmangos.world.dynobject : DynamicObject;
        import dmangos.world.spellcast : duration, radius;

        const r = spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)),
            ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        if (r <= 0 || ms <= 0)
            return;
        Position at = player.position;
        if (targets.mask & TargetFlags.destLocation)
            at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
        auto spot = new DynamicObject(context.nextTemporaryCounter(), player.guid, spell.id, i, r, at);
        map.addObject(spot);
        const amplitude = spell.casting.amplitude[i] > 0 ? spell.casting.amplitude[i] : 1000;
        persistentAreas ~= PersistentArea(spot, spell, i, value > 0 ? value : 0, amplitude, amplitude, ms);
    }

    /// A persistent area's aura amounts: its own effect's (the spot's value), the others' as cast.
    private int[3] areaAuraValues(const ref PersistentArea area)
    {
        int[3] values;
        foreach (j; 0 .. 3)
            values[j] = j == area.effect ? area.value
                : effectValue(*area.spell, j, player.data.level, uniform01(map.random));
        return values;
    }

    /// The spots' ticks and ends.
    void updatePersistentAreas(int diff)
    {
        import dmangos.world.auras : AuraType, makeAura;
        import dmangos.world.spellcast : radius;

        foreach_reverse (k, ref area; persistentAreas)
        {
            area.left -= diff;
            area.timer -= diff;
            while (area.timer <= 0 && area.left > -area.amplitude)
            {
                area.timer += area.amplitude;
                const r = radius(*area.spell, area.effect, context.client);
                const at = area.spot.position;
                bool inside(Position p)
                {
                    return (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 <= r * r;
                }
                // Damage over time hurts; another aura (a slow, a stun) is held on those inside, a little past each tick.
                const auraType = area.spell.casting.applyAuraName[area.effect];
                const hurts = auraType == 0 || auraType == AuraType.periodicDamage;
                const holdMs = area.amplitude + 500;
                foreach (creature; map.creaturesNear(at, r))
                {
                    if (!inside(creature.position) || !spellEnemy(creature))
                        continue;
                    if (hurts)
                        spellDamage(area.spell, creature, area.value, area.spell.casting.school);
                    else
                    {
                        bool isNew;
                        creature.auras.apply(makeAura(area.spell, player.guid, player.data.level, holdMs, false,
                            areaAuraValues(area)), creature.values, isNew);
                        map.flushObjectChanges(creature);
                        if (isNew)
                            spellAttacked(creature, 0);
                    }
                }
                // Players it may fight (a duel's opponent, the other faction where that is allowed).
                foreach (u; map.playersNear(at, r))
                    if (auto other = enemyPlayer(u.combatGuid))
                    {
                        if (!other.player.fighter.alive || !inside(other.player.position))
                            continue;
                        if (hurts)
                            spellDamageToPlayer(area.spell, other, area.value);
                        else
                            other.addAura(makeAura(area.spell, player.guid, player.data.level, holdMs, false,
                                areaAuraValues(area)));
                    }
            }
            if (area.left <= 0)
            {
                map.removeObject(area.spot.guid);
                persistentAreas = persistentAreas[0 .. k] ~ persistentAreas[k + 1 .. $];
            }
        }
    }

    /// A missile's flight time, in milliseconds: to `target` at the spell's speed (yards a second); 0: at once.
    int flightTime(const(SpellInfo)* spell, ulong target)
    {
        import std.math : sqrt;

        if (spell.casting.speed <= 0 || target == player.guid)
            return 0;
        Position to;
        if (auto creature = cast(Creature) map.findObject(target))
            to = creature.position;
        else if (auto who = map.find(target))
            to = who.character.position;
        else
            return 0;
        const at = player.position;
        const distance = sqrt((to.x - at.x) ^^ 2 + (to.y - at.y) ^^ 2 + (to.z - at.z) ^^ 2);
        return cast(int)(distance / spell.casting.speed * 1000);
    }

    /// The bobber goes.
    void removeBobber()
    {
        if (bobber)
            map.removeObject(bobber);
        bobber = 0;
        bobberLooted = false;
    }

    /**
     * The angler uses its own bobber: before the bite nothing is hooked; in the bite's
     * 5 seconds the catch depends on the fishing skill against the area's (or zone's)
     * `skill_fishing_base_level` (5% at that skill, more above it), and every try may raise the skill;
     * a catch is looted from `fishing_loot_template`, else the fish escaped.
     */
    package void useBobber(GameObject go)
    {
        import std.random : uniform;

        enum uint skillFishing = 356;
        if (go.owner != player.guid || go.guid != bobber)
            return;
        if (bobberAge < bobberBite)
        {
            deliver(Opcode.SMSG_FISH_NOT_HOOKED, null);
            return endChannel(false);
        }
        const area = player.area, zone = player.data.zone;
        int zoneSkill = context.data.fishingBaseSkill.get(area, 0);
        if (!zoneSkill)
            zoneSkill = context.data.fishingBaseSkill.get(zone, 0);
        const skill = cast(int) player.skillValue(skillFishing)[0];
        const chance = skill - zoneSkill + 5;
        const success = skill >= zoneSkill && chance >= uniform!"[]"(1, 100, map.random);
        // Every try may raise the fishing skill, less often the higher it is.
        const pure_ = player.skillValue(skillFishing)[0];
        updateSkillPro(skillFishing, (pure_ < 75 ? 100 : 2500 / (pure_ - 50)) * 10, 1);
        if (!success)
        {
            // Junk, if the server gives it (`fishing_loot_template` entry 0); else the fish escaped.
            auto junk = context.config.skillFailLootFishing && context.data.loot.fishing !is null
                ? context.data.loot.fishing[0] : null;
            if (junk is null)
            {
                deliver(Opcode.SMSG_FISH_ESCAPED, null);
                return endChannel(false);
            }
            auto loot = makeGameObjectLoot(go);
            loot.fill(junk, context.data.loot, context.data.items, map.random, (uint c) => conditionMet(c),
                (ulong guid, const LootItem item) => item.condition == 0 || conditionMet(item.condition));
            loot.lootedForAll = () { removeBobber(); };
            go.loot = loot;
            bobberLooted = true;
            endChannel(false);
            loot.showContentTo(this);
            return;
        }
        // A school of fish within 20 yards of the bobber gives the catch, from
        // its own loot; it is fished out after a few catches (its least to greatest, chosen once).
        GameObject hole;
        float nearest = 20.0f * 20.0f;
        foreach (o; map.objectsNear(go.position, 20))
            if (auto h = cast(GameObject) o)
                if (h.type == GameObjectType.fishingHole)
                {
                    const p = h.position, b = go.position;
                    const d = (p.x - b.x) ^^ 2 + (p.y - b.y) ^^ 2 + (p.z - b.z) ^^ 2;
                    if (d <= nearest)
                    {
                        nearest = d;
                        hole = h;
                    }
                }
        if (hole !is null)
        {
            if (hole.holeMaxCatches == 0)
            {
                const least = hole.template_.data[2], most = hole.template_.data[3];
                hole.holeMaxCatches = most > least ? uniform!"[]"(least, most, map.random) : (least > 0 ? least : 1);
            }
            auto fromHole = makeGameObjectLoot(hole);
            fromHole.lootedForAll = () {
                hole.loot = null;
                if (++hole.holeCatches >= hole.holeMaxCatches)
                    map.gameObjectUsedUp(hole);
                removeBobber();
            };
            hole.loot = fromHole;
            bobberLooted = true;
            endChannel(false);
            fromHole.showContentTo(this);
            return;
        }
        auto template_ = context.data.loot.fishing is null ? null : context.data.loot.fishing[area];
        if (template_ is null && context.data.loot.fishing !is null)
            template_ = context.data.loot.fishing[zone];
        auto loot = makeGameObjectLoot(go);
        if (template_ !is null)
        {
            bool meets(uint condition)
            {
                return conditionMet(condition);
            }

            bool allowed(ulong guid, const LootItem item)
            {
                return item.condition == 0 || conditionMet(item.condition);
            }

            loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowed);
        }
        loot.lootedForAll = () { removeBobber(); };
        go.loot = loot;
        bobberLooted = true;
        endChannel(false);
        loot.showContentTo(this);
    }

    /// Moving interrupts a cast that moving interrupts (`SPELL_INTERRUPT_FLAG_MOVEMENT`).
    void spellsOnMovement(uint movementFlags)
    {
        enum uint moving = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
            | MovementFlags.strafeRight | MovementFlags.jumping | MovementFlags.fallingFar;
        // A channel ends when the player moves (or turns), if its `ChannelInterruptFlags` say so.
        enum uint channelMove = 0x08, channelTurn = 0x10; // AURA_INTERRUPT_FLAG_MOVE, _TURNING
        if (channelSpell !is null)
        {
            const flags = channelSpell.casting.channelInterruptFlags;
            if (((movementFlags & moving) && (flags & channelMove))
                || ((movementFlags & (MovementFlags.turnLeft | MovementFlags.turnRight)) && (flags & channelTurn)))
                endChannel(true);
        }
        if (generic.active && (movementFlags & moving) && (generic.spell.casting.interruptFlags & interruptMovement))
            interruptCast(SpellCastResult.interrupted);
        enum uint turning = MovementFlags.turnLeft | MovementFlags.turnRight;
        if (movementFlags & moving)
            interruptAuras(AuraInterrupt.moving);
        else if (movementFlags & turning)
            interruptAuras(AuraInterrupt.turning);
    }

    /// Death, logging out, a far teleport: casts end.
    void spellsOnLeave()
    {
        areaAurasOnLeave();
        if (generic.active)
            interruptCast(SpellCastResult.interrupted);
        endChannel(true);
        foreach (ref area; persistentAreas)
            map.removeObject(area.spot.guid);
        persistentAreas = null;
        nextSwing.active = false;
    }

    /// A spell waiting for the next main-hand swing is cast
    /// instead of it. False if there was none (or it cannot be cast now): the swing goes as usual.
    bool swingSpell(ulong victim)
    {
        if (!nextSwing.active)
            return false;
        auto c = nextSwing;
        nextSwing.active = false;
        if (c.targets.unit == 0 || c.targets.unit == player.guid)
            c.targets.unit = victim;
        if (checkCast(c.spell, c.targets, true, 0, false) != SpellCastResult.ok)
            return false;
        go(c);
        return true;
    }

    /**
     * Whether the cast may go, and if not, why. `start`: also what only matters
     * when it starts (cooldowns, a cast in progress, standing, moving).
     */
    /**
     * Whether the player wears an item of the spell's class and subclass, not broken:
     * a weapon in the hands or the ranged slot; armour anywhere worn (a shield in the off hand).
     */
    bool hasItemFitToSpell(const(SpellInfo)* spell)
    {
        import dmangos.world.defines : equipmentSlotHead, equipmentSlotMainhand, equipmentSlotOffhand,
            equipmentSlotRanged, equipmentSlotTabard, ItemClass;

        bool fits(ubyte slot)
        {
            const item = player.inventory.equipped(slot);
            if (item is null || item.proto is null || (item.maxDurability && item.durability == 0))
                return false;
            return item.proto.itemClass == spell.equippedItemClass
                && (spell.equippedItemSubClassMask == 0 || (spell.equippedItemSubClassMask & (1 << item.proto.subClass)));
        }

        if (spell.equippedItemClass == ItemClass.weapon)
        {
            foreach (slot; [equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged])
                if (fits(cast(ubyte) slot))
                    return true;
            return false;
        }
        if (spell.equippedItemClass == ItemClass.armor)
        {
            foreach (slot; equipmentSlotHead .. equipmentSlotTabard)
                if (fits(cast(ubyte) slot))
                    return true;
            return false;
        }
        return true;
    }

    SpellCastResult checkCast(const(SpellInfo)* spell, const ref SpellTargets targets, bool triggered, uint itemEntry,
        bool start)
    {
        enum uint castableWhileSitting = 0x08000000; // SPELL_ATTR_CASTABLE_WHILE_SITTING
        const now = context.clock();
        if (player.deathState != DeathState.alive && !(spell.attributes & spellAttrCastableWhileDead))
            return player.deathState == DeathState.ghost ? SpellCastResult.notWhileGhost : SpellCastResult.casterDead;
        if (start && !triggered)
        {
            if (generic.active)
                return SpellCastResult.spellInProgress;
            if (!cooldownCheat)
                if (const at = spell.id in spellReadyAt)
                    if (*at > now)
                        return SpellCastResult.notReady;
            if (spell.category && !cooldownCheat)
                if (const at = spell.category in categoryReadyAt)
                    if (*at > now)
                        return SpellCastResult.notReady;
            if (spell.casting.startRecoveryCategory == 133 && gcdReadyAt > now && !cooldownCheat)
                return SpellCastResult.notReady;
            if (spell.casting.school < schoolLockedUntil.length && schoolLockedUntil[spell.casting.school] > now
                    && !cooldownCheat)
                return SpellCastResult.notReady; // its school locked out by an interrupt
            if ((spell.attributes & spellAttrNotInCombat) && inCombat)
                return SpellCastResult.affectingCombat;
            if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0 && !(spell.attributes & castableWhileSitting))
                return SpellCastResult.notStanding;
            // The item the spell needs worn (a fishing pole, a ranged weapon to shoot).
            if (spell.equippedItemClass >= 0 && !hasItemFitToSpell(spell))
                return SpellCastResult.equippedItemClass;
            // A spell for some stances (or forms) only in one of them.
            enum uint allowWhileNotShapeshifted = 0x00080000; // SPELL_ATTR_EX2_ALLOW_WHILE_NOT_SHAPESHIFTED
            enum SpellCastResult onlyShapeshift = cast(SpellCastResult) 0x56;
            const form = player.values.getByte!UNIT_FIELD_BYTES_1(2);
            if (form == 0 && spell.stances && !(spell.attributesEx2 & allowWhileNotShapeshifted))
                return onlyShapeshift;
            if (form != 0 && spell.stances && !(spell.stances & (1u << (form - 1))))
                return onlyShapeshift;
        }
        if (start && !triggered)
        {
            const petResult = petCastCheck(spell, targets);
            if (petResult != SpellCastResult.ok)
                return petResult;
        }
        // The target the effects need (a triggered spell's at any range: the range check is not for it).
        const result = checkTarget(spell, targets, triggered);
        if (result != SpellCastResult.ok)
            return result;
        if (spell.hasEffect(SpellEffect.pickpocket))
            if (auto victim = cast(Creature) map.findObject(targets.unit))
                if (!victim.template_.pickpocketLootId)
                    return SpellCastResult.targetNoPockets;
        if (spell.hasEffect(SpellEffect.skinning))
        {
            const skinResult = checkSkinning(targets.unit);
            if (skinResult != SpellCastResult.ok)
                return skinResult;
        }
        // A game object: near, free, its lock opened.
        const goResult = checkGameObjectTarget(spell, targets, itemEntry);
        if (goResult != SpellCastResult.ok)
            return goResult;
        if (!triggered && itemEntry == 0)
        {
            const cost = costOf(*spell);
            if (cost > 0 && player.values.get!UNIT_FIELD_POWER1(cast(Power) spell.casting.powerType) < cost)
                return SpellCastResult.noPower;
            foreach (i, reagent; spell.reagents)
                if (reagent > 0 && player.inventory.count(reagent) < spell.casting.reagentCount[i])
                    return SpellCastResult.reagents;
            if (!hasAmmoFor(spell))
                return SpellCastResult.noAmmo;
        }
        return SpellCastResult.ok;
    }

    /**
     * Whether `target` may be skinned by this player: a creature, dead, looted, with its skin on, and
     * the player's skill high enough for its level (under 100 skill, (level - 10) x 10; then level x 5).
     */
    SpellCastResult checkSkinning(ulong target)
    {
        auto creature = cast(Creature) map.findObject(target);
        if (creature is null)
            return SpellCastResult.badTargets;
        if (creature.alive)
            return SpellCastResult.targetNotDead;
        if (!creature.skinnable)
            return SpellCastResult.targetUnskinnable;
        if (creature.loot !is null)
            return SpellCastResult.targetNotLooted;
        const value = cast(int) player.skillValue(creature.skinningSkill)[0];
        const level = cast(int) creature.values.get!UNIT_FIELD_LEVEL;
        const required = value < 100 ? (level - 10) * 10 : level * 5;
        if (required > value)
            return SpellCastResult.lowCastLevel;
        return SpellCastResult.ok;
    }

    /**
     * The skinning effect: the creature's skin as loot for this player alone (`skinning_loot_template`),
     * a chance to improve the skill (twice for elites), and the corpse no longer skinnable; once the
     * skin is all taken, the corpse goes.
     */
    void skinCreature(ulong target)
    {
        import dmangos.world.loot : ClientLootType, Loot, LootRule;

        auto creature = cast(Creature) map.findObject(target);
        if (creature is null || !creature.skinnable)
            return;
        const t = creature.template_;
        auto loot = new Loot(creature.guid, (ulong guid) => guid == player.guid ? cast(Looter) this : null);
        loot.clock = () => context.unixTime;
        loot.clientType = ClientLootType.pickpocketing; // the window a skin's loot opens in
        loot.owners[player.guid] = true;
        loot.currentLooter = player.guid;
        loot.rule = LootRule.notGroup;
        if (const template_ = context.data.loot.skinning[t.skinningLootId])
            loot.fill(template_, context.data.loot, context.data.items, map.random, (uint condition) => conditionMet(condition),
                (ulong, const LootItem item) => item.condition == 0 || conditionMet(item.condition));
        // The skill: a chance to rise by the level's requirement.
        const level = cast(int) creature.values.get!UNIT_FIELD_LEVEL;
        const required = level < 10 ? 0 : level < 20 ? (level - 10) * 10 : level * 5;
        const skill = creature.skinningSkill;
        enum uint rankNormal = 0, rankRare = 4;
        updateGatherSkill(skill, player.skillValue(skill)[0], required,
            t.rank != rankNormal && t.rank != rankRare ? 2 : 1);
        creature.values.set!UNIT_FIELD_FLAGS(creature.values.get!UNIT_FIELD_FLAGS & ~Creature.unitFlagSkinnable);
        creature.skinned = true;
        creature.loot = loot;
        auto theMap = map;
        loot.changed = () => theMap.refreshViewers(creature);
        loot.lootedForAll = () {
            creature.loot = null;
            creature.corpseTimer = 1; // nothing more to take from it: it goes
            theMap.refreshViewers(creature);
        };
        map.flushObjectChanges(creature);
        if (lootTarget && lootTarget != creature.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        loot.showContentTo(this);
    }

    /**
     * The pickpocketing effect: a living creature's pockets (`pickpocketing_loot_template`, and some
     * money by both levels) as loot for this player alone. Pockets not yet emptied open again as they
     * were; emptied, they are empty until `creature_pickpocket_restock_delay` has passed.
     */
    void pickPocket(ulong target)
    {
        import std.random : uniform;
        import dmangos.world.loot : ClientLootType, Loot, LootRule;

        auto creature = cast(Creature) map.findObject(target);
        if (creature is null || !creature.alive || !creature.template_.pickpocketLootId)
            return;
        enum ubyte lootErrorAlreadyPickpocketed = 15;
        if (creature.loot !is null && creature.pocketsEmptied)
        {
            if (context.unixTime < creature.pocketsRestockAt)
            {
                ByteWriter w;
                w.put(creature.guid);
                w.put(ubyte(0));
                w.put(lootErrorAlreadyPickpocketed);
                return deliver(Opcode.SMSG_LOOT_RESPONSE, w.data);
            }
            creature.loot = null;
            creature.pocketsEmptied = false;
        }
        if (creature.loot is null)
        {
            auto loot = new Loot(creature.guid, (ulong guid) => guid == player.guid ? cast(Looter) this : null);
            loot.clock = () => context.unixTime;
            loot.clientType = ClientLootType.pickpocketing;
            loot.owners[player.guid] = true;
            loot.currentLooter = player.guid;
            loot.rule = LootRule.notGroup;
            if (const template_ = context.data.loot.pickpocketing[creature.template_.pickpocketLootId])
                loot.fill(template_, context.data.loot, context.data.items, map.random,
                    (uint condition) => conditionMet(condition),
                    (ulong, const LootItem item) => item.condition == 0 || conditionMet(item.condition));
            const a = uniform!"[]"(0, creature.values.get!UNIT_FIELD_LEVEL / 2, map.random);
            const b = uniform!"[]"(0, player.data.level / 2, map.random);
            loot.gold = 10 * (a + b);
            creature.loot = loot;
            auto pocketed = creature;
            loot.lootedForAll = () {
                pocketed.pocketsEmptied = true;
                pocketed.pocketsRestockAt = context.unixTime + context.config.creaturePickpocketRestockDelay;
            };
        }
        if (lootTarget && lootTarget != creature.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        creature.loot.showContentTo(this);
    }

    /// The power `spell` costs this player.
    int costOf(const ref SpellInfo spell)
    {
        if (powerCheat)
            return 0;
        const level = player.data.level;
        const createMana = player.stats.baseMana, createHealth = player.stats.baseHealth;
        const maxPower = spell.casting.powerType < 5
            ? player.values.get!UNIT_FIELD_MAXPOWER1(cast(Power) spell.casting.powerType) : 0;
        return max(0, spellMod(SpellModOp.cost, &spell, powerCost(spell, level, createMana, createHealth, maxPower)));
    }

    /// Whether the effects' implicit targets have what they need: an enemy, a friend, any unit, in range and sight.
    SpellCastResult checkTarget(const(SpellInfo)* spell, const ref SpellTargets targets, bool triggered = false)
    {
        bool needsEnemy, needsUnit;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == 0)
                continue;
            const a = spell.implicitTargetA[i];
            if (a == ImplicitTarget.enemy)
                needsEnemy = true;
            else if (a == ImplicitTarget.unit || a == ImplicitTarget.friend)
                needsUnit = true;
        }
        if (!needsEnemy && !needsUnit)
            return SpellCastResult.ok;
        // A resurrection: at a dead player (or its corpse, which stands for it), never the living.
        enum uint resurrect = 18, resurrectNew = 113;
        const raising = spell.hasEffect(cast(SpellEffect) resurrect) || spell.hasEffect(cast(SpellEffect) resurrectNew);
        ulong unitTarget = targets.unit;
        bool atCorpse;
        Position corpseAt;
        if (raising && !unitTarget && targets.corpse)
        {
            import dmangos.world.corpse : Corpse;

            if (auto corpse = cast(Corpse) map.findObject(targets.corpse))
            {
                unitTarget = corpse.values.get!CORPSE_FIELD_OWNER;
                atCorpse = true;
                corpseAt = corpse.position;
            }
        }
        const guid = unitTarget ? unitTarget : player.guid;
        if (guid == player.guid)
            return needsEnemy ? SpellCastResult.badTargets : SpellCastResult.ok;
        auto creature = cast(Creature) map.findObject(guid);
        Position at;
        float reach;
        if (creature !is null)
        {
            if (!creature.alive && !spell.hasEffect(SpellEffect.skinning))
                return SpellCastResult.targetsDead;
            if (needsEnemy && !canAttack(relatingNow(), creature.ai.relatingOf(), context.client))
                return SpellCastResult.targetFriendly;
            at = creature.position;
            reach = creature.values.get!UNIT_FIELD_COMBATREACH;
        }
        else if (auto other = cast(typeof(this)) context.onlinePlayer(guid))
        {
            if (other.map !is map || other.player is null)
                return SpellCastResult.badTargets;
            if (needsEnemy && !canAttack(relatingNow(), other.relatingNow(), context.client))
                return SpellCastResult.targetFriendly;
            if (raising)
            {
                if (other.player.deathState == DeathState.alive)
                    return SpellCastResult.targetNotDead;
            }
            else if (other.player.deathState != DeathState.alive)
                return SpellCastResult.targetsDead;
            at = atCorpse ? corpseAt : other.player.position;
            reach = other.player.values.get!UNIT_FIELD_COMBATREACH;
        }
        else
            return SpellCastResult.badTargets;
        if (triggered)
            return SpellCastResult.ok;
        // Within the spell's range, reaches included, and in line of sight.
        auto r = range(*spell, context.client);
        r[1] = spellMod(SpellModOp.range, spell, r[1]);
        const p = player.position;
        const distance = ((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2) ^^ 0.5f;
        const ownReach = player.values.get!UNIT_FIELD_COMBATREACH;
        const melee = r[1] <= 5 && spell.casting.dmgClass == DamageClass.melee;
        const maxRange = melee ? (ownReach + reach + 4.0f / 3 > 5 ? ownReach + reach + 4.0f / 3 : 5) : r[1] + ownReach + reach;
        if (r[1] > 0 && distance > maxRange)
            return SpellCastResult.outOfRange;
        if (r[0] > 0 && distance < r[0])
            return SpellCastResult.tooClose;
        if (!map.inLineOfSight(p, at))
            return SpellCastResult.lineOfSight;
        return SpellCastResult.ok;
    }

    /**
     * The cast goes: checked again, its cooldowns started, its cost taken, the hits rolled, everyone
     * around shown, and the effects done on each target hit.
     */
    SpellCastResult go(Casting c)
    {
        const spell = c.spell;
        const result = checkCast(spell, c.targets, c.triggered, c.castItemEntry, false);
        if (result != SpellCastResult.ok)
        {
            if (!c.triggered)
            {
                map.sendToWatchers(this, Opcode.SMSG_SPELL_FAILURE, spellFailurePacket(player.guid, spell.id, result),
                    true);
                deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
            }
            return result;
        }
        const now = context.clock();
        if (!c.triggered)
        {
            // The cooldowns start: the item's, else the spell's.
            int recovery = spell.recoveryTime, categoryRecovery = spell.categoryRecoveryTime;
            uint category = spell.category;
            if (c.castItemEntry)
                if (const proto = c.castItemEntry in context.data.items)
                    foreach (i, ref use; proto.details.spells)
                        if (use.id == spell.id)
                        {
                            if (use.cooldown >= 0)
                                recovery = use.cooldown;
                            if (use.categoryCooldown >= 0)
                                categoryRecovery = use.categoryCooldown;
                            if (proto.spellCategory[i])
                                category = proto.spellCategory[i];
                        }
            recovery = spellMod(SpellModOp.cooldown, spell, recovery);
            categoryRecovery = spellMod(SpellModOp.cooldown, spell, categoryRecovery);
            if (recovery > 0 && !cooldownCheat)
                spellReadyAt[spell.id] = now + recovery.msecs;
            if (category && categoryRecovery > 0 && !cooldownCheat)
                categoryReadyAt[category] = now + categoryRecovery.msecs;
            if ((recovery > 0 || (category && categoryRecovery > 0)) && !cooldownCheat)
            {
                cooldownCategory[spell.id] = category && categoryRecovery > 0 ? category : 0;
                cooldownItem[spell.id] = c.castItemEntry;
            }
            // The power and reagents taken, and an item used up (`spellcharges` -1: one use).
            if (c.castItemEntry == 0)
            {
                const cost = costOf(*spell);
                if (cost > 0)
                    player.modifyPower(cast(Power) spell.casting.powerType, -cost);
                foreach (i, reagent; spell.reagents)
                    if (reagent > 0 && spell.casting.reagentCount[i])
                        player.inventory.destroyCount(reagent, spell.casting.reagentCount[i]);
                if (!autoRepeats(spell))
                    takeAmmo(spell); // an auto-repeating shot's is taken as it shoots
            }
            else if (const proto = c.castItemEntry in context.data.items)
                foreach (i, ref use; proto.details.spells)
                    if (use.id == spell.id && proto.spellCharges[i] < 0)
                        player.inventory.destroyCount(c.castItemEntry, 1);
            flushInventory();
        }

        // The targets of each effect, and whether each hostile one is hit.
        TargetResult[] results;
        SpellMissInfo[ulong] missOf;
        ulong[][3] effectTargets;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == 0)
                continue;
            const a = spell.implicitTargetA[i];
            ulong[] targets;
            const area = spell.effect[i] == 27 ? null : areaTargets(spell, i, c.targets);
            if (spell.effect[i] == 27) // SPELL_EFFECT_PERSISTENT_AREA_AURA: once, whoever stands there
                targets = [player.guid];
            else if (area.length || isAreaTarget(spell, i))
                targets = area.dup; // an area, a cone, the party
            else if (a == ImplicitTarget.caster || a == ImplicitTarget.none)
                targets = [player.guid];
            else if (a == ImplicitTarget.enemy || a == ImplicitTarget.unit || a == ImplicitTarget.friend)
            {
                targets = [c.targets.unit ? c.targets.unit : player.guid];
                if (spell.casting.chainTarget[i] > 1 && a == ImplicitTarget.enemy)
                    targets ~= chainTargets(targets[0], spell.casting.chainTarget[i] - 1);
            }
            else if (a == ImplicitTarget.gameObject || a == ImplicitTarget.gameObjectItem)
            {
                if (!c.targets.gameObject)
                    continue; // an item's lock: not yet
                targets = [c.targets.gameObject];
            }
            else
                targets = [player.guid]; // other targets: not yet; the caster stands in
            foreach (target; targets)
            {
                effectTargets[i] ~= target;
                if (target !in missOf)
                {
                    missOf[target] = rollHit(*spell, target);
                    results ~= TargetResult(target, missOf[target]);
                }
            }
        }
        if (!c.triggered)
        {
            interruptAuras(AuraInterrupt.action); // auras that end when the player casts
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.ok));
        }
        map.sendToWatchers(this, Opcode.SMSG_SPELL_GO, spellGoPacket(player.guid, spell.id, results, c.targets), true);
        foreach (r; results)
            if (r.miss != SpellMissInfo.none)
            {
                map.sendToWatchers(this, Opcode.SMSG_SPELLLOGMISS, spellMissLog(spell.id, player.guid, r.guid, r.miss),
                    true);
                if (auto creature = cast(Creature) map.findObject(r.guid))
                    spellAttacked(creature, 0);
            }
        // A missile (`speed`) reaches each target after its flight: the effects then.
        foreach (i; 0 .. 3)
            foreach (target; effectTargets[i])
                if (missOf[target] == SpellMissInfo.none)
                {
                    const flight = flightTime(spell, target);
                    if (flight > 0)
                        pendingHits ~= PendingHit(spell, i, target, c, flight);
                    else
                        doEffect(spell, i, target, c);
                }
        // A channelled spell goes on (`SPELL_ATTR_EX_IS_CHANNELED`, `_IS_SELF_CHANNELED`).
        enum uint channeled = 0x04, selfChanneled = 0x40;
        if ((spell.attributesEx & (channeled | selfChanneled)) && !c.triggered && !channelFailed)
            startChannel(spell, results.length ? results[0].guid : c.targets.unit);
        channelFailed = false;
        // `SpellHit` for the creatures hit (their scripts).
        foreach (r; results)
            if (r.miss == SpellMissInfo.none)
                if (auto creature = cast(Creature) map.findObject(r.guid))
                    if (creature.alive && creature.ai !is null)
                        creature.ai.spellHitBy(player.guid, spell.id, 1u << spell.casting.school, map);
        flushPlayerChanges();
        return SpellCastResult.ok;
    }

    /**
     * The hit roll against a creature: a magic spell misses (resisted) by
     * the level-based spell miss chance; a melee one by the attack table (miss, dodge, parry, block).
     * Friendly targets are always hit.
     */
    SpellMissInfo rollHit(const ref SpellInfo spell, ulong target)
    {
        auto creature = cast(Creature) map.findObject(target);
        if (creature is null)
        {
            // A player: an enemy (a duel's opponent) can be missed; a friend never is.
            auto other = target == player.guid ? null : cast(typeof(this)) context.onlinePlayer(target);
            if (other is null || other.player is null || !canAttack(relatingNow(), other.relatingNow(), context.client))
                return SpellMissInfo.none;
            if ((spell.casting.attributesEx3 & spellAttrEx3AlwaysHit) || spell.casting.dmgClass == DamageClass.none)
                return SpellMissInfo.none; // no damage class, no roll
            const roll = uniform01(map.random) * 100;
            if (spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged)
            {
                const me = player.fighter, it = other.player.fighter;
                const type = spell.casting.dmgClass == DamageClass.ranged ? AttackType.ranged : AttackType.mainHand;
                float edge = missChance(me, it, type);
                if (roll < edge)
                    return SpellMissInfo.miss;
                edge += dodgeChance(it, me, type);
                if (roll < edge)
                    return SpellMissInfo.dodge;
                edge += parryChance(it, me, type);
                return roll < edge ? SpellMissInfo.parry : SpellMissInfo.none;
            }
            // Missed, or (a magic spell) resisted whole by the target's resistance.
            float chance = spellMissChance(player.data.level, other.player.data.level, true) - spellHitBonus;
            if (spell.casting.dmgClass == DamageClass.magic && spell.casting.school > 1)
            {
                import dmangos.world.combat : fullResistChance;

                chance += fullResistChance(cast(int) other.player.values.get!UNIT_FIELD_RESISTANCES(spell.casting.school),
                    player.data.level, other.player.data.level, isBinarySpell(spell), false);
            }
            return roll < chance ? SpellMissInfo.resist : SpellMissInfo.none;
        }
        if (!creature.alive)
            return SpellMissInfo.none;
        if (!canAttack(relatingNow(), creature.ai.relatingOf(), context.client))
            return SpellMissInfo.none;
        if (creature.ai.evading)
            return SpellMissInfo.evade;
        if ((spell.casting.attributesEx3 & spellAttrEx3AlwaysHit) || spell.casting.dmgClass == DamageClass.none)
            return SpellMissInfo.none;
        const roll = uniform01(map.random) * 100;
        if (spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged)
        {
            const me = player.fighter, it = creature.fighter;
            const type = spell.casting.dmgClass == DamageClass.ranged ? AttackType.ranged : AttackType.mainHand;
            float edge = missChance(me, it, type);
            if (roll < edge)
                return SpellMissInfo.miss;
            edge += dodgeChance(it, me, type);
            if (roll < edge)
                return SpellMissInfo.dodge;
            edge += parryChance(it, me, type);
            if (roll < edge)
                return SpellMissInfo.parry;
            return SpellMissInfo.none;
        }
        const level = creature.values.get!UNIT_FIELD_LEVEL;
        float chance = spellMissChance(player.data.level, level, false) - spellHitBonus;
        // A magic spell is also fully resisted by resistance: a binary spell
        // by its whole percent, another by the distribution's chance of all of it.
        const school = spell.casting.school;
        if (spell.casting.dmgClass == DamageClass.magic && school > 1)
        {
            import dmangos.world.combat : effectiveResistPercent, partialResistRows;

            const binary = isBinarySpell(spell);
            const percent = effectiveResistPercent(cast(int) creature.values.get!UNIT_FIELD_RESISTANCES(school),
                player.data.level, level, !binary);
            if (percent > 0)
                chance += binary ? percent : partialResistRows[cast(uint) percent][4] * 0.01f;
        }
        return roll < chance ? SpellMissInfo.resist : SpellMissInfo.none;
    }

    // -----------------------------------------------------------------------
    // Effects
    // -----------------------------------------------------------------------

    void doEffect(const(SpellInfo)* spell, size_t i, ulong target, ref Casting c)
    {
        const value = effectMod(spell, i, effectValue(*spell, i, player.data.level, uniform01(map.random)));
        switch (spell.effect[i])
        {
        case 2: // SPELL_EFFECT_SCHOOL_DAMAGE
        {
            const damage = spellMod(SpellModOp.damage, spell, value);
            if (auto creature = cast(Creature) map.findObject(target))
                spellDamage(spell, creature, damage > 0 ? damage : 0, spell.casting.school);
            else if (auto other = enemyPlayer(target))
                spellDamageToPlayer(spell, other, damage > 0 ? damage : 0);
            break;
        }
        case 3, 77: // SPELL_EFFECT_DUMMY, SPELL_EFFECT_SCRIPT_EFFECT: the spell's script, then its database script
        {
            import dmangos.world.dbscripts : DbScriptType;

            if (spellEffectScript(spell, i, target, value))
                break;
            context.startScript(DbScriptType.spell, spell.id, map, player.guid, target ? target : c.targets.gameObject);
            break;
        }
        case 41: // SPELL_EFFECT_SUMMON_WILD: creatures of its entry, at the destination or near the caster
        {
            import dmangos.world.creature : TempSpawnType;
            import dmangos.world.spellcast : duration, TargetFlags;

            const entry = cast(uint) spell.miscValue[i];
            if (!entry)
                break;
            const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
            const count = value > 0 ? value : 1;
            foreach (n; 0 .. count)
            {
                Position at; // all zeros: near the caster
                if ((c.targets.mask & TargetFlags.destLocation) && n == 0)
                    at = Position(c.targets.dest[0], c.targets.dest[1], c.targets.dest[2], player.position.orientation);
                context.summonCreature(map, entry, at, ms > 0 ? TempSpawnType.timedOrDead : TempSpawnType.dead,
                    ms > 0 ? ms : 0, player.guid);
            }
            break;
        }
        case 27: // SPELL_EFFECT_PERSISTENT_AREA_AURA: a spot that hurts who stands in it, made once a cast
            if (!(c.persistentDone & (1 << i)))
            {
                c.persistentDone |= cast(ubyte)(1 << i);
                makePersistentArea(spell, i, c.targets, value);
            }
            break;
        case 50: // SPELL_EFFECT_TRANS_DOOR: an object the spell puts down (a fishing bobber)
            castBobber(spell, i);
            break;
        case 61: // SPELL_EFFECT_SEND_EVENT: the event's script, the caster its source and a game object its target
        {
            import dmangos.world.dbscripts : DbScriptType;

            context.startScript(DbScriptType.event, cast(uint) spell.miscValue[i], map, player.guid,
                c.targets.gameObject);
            break;
        }
        case 83: // SPELL_EFFECT_DUEL
            startDuel(target);
            break;
        case 55: // SPELL_EFFECT_TAMECREATURE
            tameCreature(spell, target ? target : c.targets.unit);
            break;
        case 56: // SPELL_EFFECT_SUMMON_PET
            summonPetEffect(spell, i);
            break;
        case 102: // SPELL_EFFECT_DISMISS_PET
            dismissPetEffect();
            break;
        case 109: // SPELL_EFFECT_SUMMON_DEAD_PET
            reviveDeadPet(value);
            break;
        case 1: // SPELL_EFFECT_INSTAKILL
            instakill(spell, target);
            break;
        case 36: // SPELL_EFFECT_LEARN_SPELL: the pet (a teaching spell aimed at it), or the target player, learns
        {
            enum uint targetPet = 5;
            const learned = spell.triggerSpell[i];
            if (spell.implicitTargetA[i] == targetPet)
                teachPet(learned);
            else if (learned)
                learn(learned);
            break;
        }
        case 57: // SPELL_EFFECT_LEARN_PET_SPELL
            teachPet(spell.triggerSpell[i]);
            break;
        case 74, 87, 88, 89, 90: // SPELL_EFFECT_SUMMON_TOTEM, _SLOT1 .. _SLOT4 (fire, earth, water, air)
            summonTotem(spell, i, value);
            break;
        case 94: // SPELL_EFFECT_SELF_RESURRECT
            selfResurrect(spell, i, value);
            break;
        case 18, 113: // SPELL_EFFECT_RESURRECT (a share of health and mana), SPELL_EFFECT_RESURRECT_NEW (amounts)
            resurrectEffect(spell, i, target, value, c);
            break;
        case 38: // SPELL_EFFECT_DISPEL
            dispelEffect(spell, i, target, value);
            break;
        case 71: // SPELL_EFFECT_PICKPOCKET
            pickPocket(target);
            break;
        case 95: // SPELL_EFFECT_SKINNING
            skinCreature(target);
            break;
        case 33: // SPELL_EFFECT_OPEN_LOCK
            openLock(spell, i, target, c.castItemEntry);
            break;
        case 68: // SPELL_EFFECT_INTERRUPT_CAST: the target's cast ends, and its school is locked out for the interrupt's time
        {
            import dmangos.world.spellcast : duration;

            const lockMs = duration(*spell, context.client, player.data.level);
            if (auto creature = cast(Creature) map.findObject(target))
                creature.ai.interruptCast(lockMs);
            else if (auto other = enemyPlayer(target))
                if (other.generic.active)
                {
                    const school = other.generic.spell.casting.school;
                    other.interruptCast(SpellCastResult.interrupted);
                    other.lockOutSchool(school, lockMs);
                }
            break;
        }
        case 17: // SPELL_EFFECT_WEAPON_DAMAGE_NOSCHOOL
        case 58: // SPELL_EFFECT_WEAPON_DAMAGE
        case 121: // SPELL_EFFECT_NORMALIZED_WEAPON_DMG
        case 31: // SPELL_EFFECT_WEAPON_PERCENT_DAMAGE
            if (auto victim = map.unit(target)) // a creature or a player (a duel, world PvP)
                weaponSpellDamage(spell, i, victim, value);
            break;
        case 10: // SPELL_EFFECT_HEAL
            heal(spell, target, spellMod(SpellModOp.damage, spell, value));
            break;
        case 30: // SPELL_EFFECT_ENERGIZE
            energize(spell, i, target, value);
            break;
        case 5: // SPELL_EFFECT_TELEPORT_UNITS
            teleportUnits(spell, i, c);
            break;
        case SpellEffect.createItem:
            if (spell.itemType[i])
                if (giveItem(spell.itemType[i], value > 0 ? value : 1))
                    updateCraftSkill(spell.id); // made: a chance to learn from it
            break;
        case 101: // SPELL_EFFECT_FEED_PET
            feedPet(c.targets.item);
            break;
        case 53: // SPELL_EFFECT_ENCHANT_ITEM
            enchantItem(c.targets.item, cast(uint) spell.miscValue[i], false, 0);
            updateCraftSkill(spell.id);
            break;
        case 54: // SPELL_EFFECT_ENCHANT_ITEM_TEMPORARY
            enchantItem(c.targets.item, cast(uint) spell.miscValue[i], true, value);
            break;
        case 64: // SPELL_EFFECT_TRIGGER_SPELL
            if (const triggered = context.data.spells.spell(spell.triggerSpell[i]))
                castSpell(triggered, c.targets, true, 0);
            break;
        case 6: // SPELL_EFFECT_APPLY_AURA
            applyAuraEffect(spell, i, target);
            break;
        case 35: // SPELL_EFFECT_APPLY_AREA_AURA_PARTY: on the caster, and from it on its party (`updateAreaAuras`)
            applyAuraEffect(spell, i, player.guid);
            break;
        case 78: // SPELL_EFFECT_ATTACK
            break;
        default:
            info!"%s: spell %s effect %s (%s) is not done yet"(remoteAddress, spell.id, i, spell.effect[i]);
            break;
        }
    }

    /// An instant kill: `SMSG_SPELLINSTAKILLLOG` around, and damage of all the target's health.
    void instakill(const(SpellInfo)* spell, ulong target)
    {
        ByteWriter w;
        w.put(target);
        w.put(spell.id);
        if (auto creature = cast(Creature) map.findObject(target))
        {
            if (!creature.alive)
                return;
            map.sendToWatchers(this, Opcode.SMSG_SPELLINSTAKILLLOG, w.data, true);
            return spellAttacked(creature, creature.values.get!UNIT_FIELD_HEALTH);
        }
        auto other = target == player.guid ? this : cast(typeof(this)) context.onlinePlayer(target);
        if (other is null || other.player is null || other.map !is map || other.player.deathState != DeathState.alive)
            return;
        map.sendToWatchers(this, Opcode.SMSG_SPELLINSTAKILLLOG, w.data, true);
        {
            import dmangos.world.unit : Blow, dealDamage;

            dealDamage(unit, other.unit, other.player.values.get!UNIT_FIELD_HEALTH, Blow.spell());
        }
    }

    /// The cooldowns still running, saved, with when they end (Unix time).
    package void saveCooldowns()
    {
        import dmangos.world.database : CooldownRecord;

        const now = context.clock(), unixNow = context.unixTime;
        CooldownRecord[] rows;
        foreach (spellId, category; cooldownCategory)
        {
            CooldownRecord r;
            r.spell = spellId;
            r.item = cooldownItem.get(spellId, 0);
            if (const at = spellId in spellReadyAt)
                if (*at > now)
                    r.spellExpires = unixNow + (*at - now).total!"seconds" + 1;
            if (category)
                if (const at = category in categoryReadyAt)
                    if (*at > now)
                    {
                        r.category = category;
                        r.categoryExpires = unixNow + (*at - now).total!"seconds" + 1;
                    }
            if (r.spellExpires || r.categoryExpires)
                rows ~= r;
        }
        context.database.saveCooldowns(player.data.guid, rows);
    }

    /// The saved cooldowns that have not ended yet, loaded.
    package void loadCooldowns()
    {
        const now = context.clock(), unixNow = context.unixTime;
        foreach (r; context.database.loadCooldowns(player.data.guid))
        {
            if (r.spellExpires > unixNow)
                spellReadyAt[r.spell] = now + (r.spellExpires - unixNow).seconds;
            if (r.category && r.categoryExpires > unixNow)
                categoryReadyAt[r.category] = now + (r.categoryExpires - unixNow).seconds;
            if (r.spellExpires > unixNow || (r.category && r.categoryExpires > unixNow))
            {
                cooldownCategory[r.spell] = r.categoryExpires > unixNow ? r.category : 0;
                cooldownItem[r.spell] = r.item;
            }
        }
    }

    /// The cooldowns running, as `SMSG_INITIAL_SPELLS` lists them.
    package InitialCooldown[] initialCooldowns()
    {
        const now = context.clock();
        InitialCooldown[] list;
        foreach (spellId, category; cooldownCategory)
        {
            const spellLeft = spellId in spellReadyAt ? spellReadyAt[spellId] - now : Duration.zero;
            const categoryLeft = category && category in categoryReadyAt ? categoryReadyAt[category] - now
                : Duration.zero;
            if (spellLeft <= Duration.zero && categoryLeft <= Duration.zero)
                continue;
            InitialCooldown entry;
            entry.spell = cast(ushort) spellId;
            entry.item = cast(ushort) cooldownItem.get(spellId, 0);
            entry.category = cast(ushort) category;
            // In the initial spell list a category's cooldown is in the second number, the spell's in the first.
            if (categoryLeft > Duration.zero)
                entry.categoryMs = cast(uint) categoryLeft.total!"msecs";
            else
                entry.spellMs = cast(uint) spellLeft.total!"msecs";
            list ~= entry;
        }
        return list;
    }

    /// A spell's cooldown cleared: `SMSG_CLEAR_COOLDOWN`, and the spell ready again.
    package void clearCooldownFor(uint spell)
    {
        ByteWriter w;
        w.put(spell);
        w.put(player.guid);
        deliver(Opcode.SMSG_CLEAR_COOLDOWN, w.data);
        spellReadyAt.remove(spell);
        if (const info = context.data.spells.spell(spell))
            if (info.category)
                categoryReadyAt.remove(info.category);
    }

    /// Clears the cooldowns of the spells known of a skill line, but `calledFrom`.
    package void clearCooldownsOnLine(uint skillLine, uint calledFrom)
    {
        foreach (spell; player.spells.dup)
        {
            if (spell == calledFrom)
                continue;
            const abilities = context.client.abilitiesForSpell(spell);
            if (abilities.length && abilities[0].skillId == skillLine)
                clearCooldownFor(spell);
        }
    }

    /// A duration with the modifiers (an aura's that lasts until cancelled stays so).
    int modDuration(const(SpellInfo)* spell, int ms)
    {
        return ms > 0 ? max(0, spellMod(SpellModOp.duration, spell, ms)) : ms;
    }

    /// `value` of `spell`'s property `op`, with this player's spell modifiers (talents).
    T spellMod(T)(SpellModOp op, const(SpellInfo)* spell, T value)
    {
        return applySpellMod(player.auras.list, op, *spell, value);
    }

    /// An effect's value with the modifiers of its own index and of all effects.
    int effectMod(const(SpellInfo)* spell, size_t i, int value)
    {
        return spellMod(SpellModOp.allEffects, spell, spellMod(effectOp(i), spell, value));
    }

    /**
     * Dispelling (spell effect 38): up to `count` (at least one) of the target's auras of the effect's dispel
     * type (its misc value; 7: magic, curses, diseases and poisons), chosen at random, go. Magic is taken
     * only where it hurts: harmful magic off a friend, helpful magic off an enemy. Passive auras stay. The
     * auras removed are told to those around (`SMSG_SPELLDISPELLOG`).
     */
    package void dispelEffect(const(SpellInfo)* spell, size_t i, ulong target, int count)
    {
        import std.algorithm.mutation : remove;
        import std.random : uniform;
        import dmangos.bytes : ByteWriter;
        import dmangos.world.auras : Aura;

        enum uint dispelMagic = 1, dispelAll = 7;
        const type = spell.miscValue[i];
        const uint mask = type == dispelAll ? 0b11110 : type < 32 ? 1u << type : 0;
        Creature creature;
        typeof(this) other;
        bool friendly;
        if (target == 0 || target == player.guid)
        {
            other = this;
            friendly = true;
        }
        else if ((creature = cast(Creature) map.findObject(target)) !is null)
            friendly = !canAttack(relatingNow(), creature.ai.relatingOf(), context.client);
        else
        {
            other = cast(typeof(this)) context.onlinePlayer(target);
            if (other is null || other.player is null || other.map !is map)
                return;
            friendly = enemyPlayer(target) is null;
        }
        Aura[] eligible;
        foreach (aura; creature !is null ? creature.auras.list : other.player.auras.list)
        {
            if (aura.passive || !(mask & (1u << aura.spell.casting.dispel)))
                continue;
            if (aura.spell.casting.dispel == dispelMagic && aura.positive == friendly)
                continue;
            eligible ~= aura;
        }
        Aura[] removed;
        foreach (_; 0 .. count > 0 ? count : 1)
        {
            if (eligible.length == 0)
                break;
            const at = uniform(0, eligible.length, map.random);
            removed ~= eligible[at];
            eligible = eligible.remove(at);
        }
        if (removed.length == 0)
            return;
        ByteWriter w;
        w.putPackedGuid(creature !is null ? creature.guid : other.player.guid);
        w.putPackedGuid(player.guid);
        w.put(cast(uint) removed.length);
        foreach (aura; removed)
            w.put(aura.spell.id);
        map.sendToWatchers(this, Opcode.SMSG_SPELLDISPELLOG, w.data, true);
        foreach (aura; removed)
        {
            if (creature !is null)
                creature.auras.remove(aura, creature.values);
            else
                other.removeAura(aura);
        }
        if (creature !is null)
            map.flushObjectChanges(creature);
    }

    /**
     * A partial resist by a player of `level` with `resistance` (no level bonus, as a creature has): a share
     * of `damage` resisted (taken off it, and returned); a negative resistance adds to it instead.
     */
    package uint partialResist(ref uint damage, int resistance, uint level)
    {
        import std.random : uniform;
        import dmangos.world.combat : effectiveResistPercent, rollPartialResist;

        const percent = effectiveResistPercent(resistance, player.data.level, level, false);
        const share = rollPartialResist(percent, uniform!"[]"(1u, 10000u, map.random));
        if (share > 0)
        {
            const resisted = cast(uint)(damage * share);
            damage -= resisted;
            return resisted;
        }
        if (share < 0)
            damage += cast(uint)(damage * -share);
        return 0;
    }

    /**
     * A resurrection spell at a dead player (or its corpse): it is offered to come back beside this
     * player, with the effect's share (effect 18) or amounts (113: the value its health, the misc value
     * its mana) of health and mana.
     */
    void resurrectEffect(const(SpellInfo)* spell, size_t i, ulong target, int value, const ref Casting c)
    {
        import dmangos.world.corpse : Corpse;
        import dmangos.world.player : DeathState;

        enum uint resurrectNew = 113, noResurrectTimer = 0x00100000; // SPELL_ATTR_EX3_NO_RES_TIMER
        ulong owner = target;
        if (c.targets.corpse)
            if (auto corpse = cast(Corpse) map.findObject(c.targets.corpse))
                owner = corpse.values.get!CORPSE_FIELD_OWNER;
        auto other = owner == player.guid ? null : cast(typeof(this)) context.onlinePlayer(owner);
        if (other is null || other.player is null || other.player.deathState == DeathState.alive)
            return;
        const v = &other.player.values;
        uint health, mana;
        if (spell.effect[i] == resurrectNew)
        {
            health = value > 0 ? value : 0;
            mana = spell.miscValue[i] > 0 ? spell.miscValue[i] : 0;
        }
        else
        {
            const share = value > 0 ? value : 0;
            health = cast(uint)(ulong(v.get!UNIT_FIELD_MAXHEALTH) * share / 100);
            mana = cast(uint)(ulong(v.get!UNIT_FIELD_MAXPOWER1(0)) * share / 100);
        }
        other.resurrectRequested(player.guid, player.data.map, player.position, health, mana,
            !(spell.casting.attributesEx3 & noResurrectTimer));
    }

    /// Percent less often its spells miss (`MOD_SPELL_HIT_CHANCE` auras).
    @property float spellHitBonus()
    {
        import dmangos.world.auras : AuraType;

        return player.auras.total(AuraType.modSpellHitChance);
    }

    /// The crit chance of `spell`: this player's (`spellCrit`) and the spell's modifiers.
    float spellCritOf(const(SpellInfo)* spell)
    {
        import dmangos.world.auras : AuraType;

        // And what auras add: to every spell's crit, and to its school's.
        return spellCrit() + spellMod(SpellModOp.critChance, spell, 0) + player.auras.total(AuraType.modSpellCritChance)
            + player.auras.totalByMiscMask(AuraType.modSpellCritChanceSchool, 1 << spell.casting.school);
    }

    /// The crit chance of this player's spells, from its intellect by class and level.
    float spellCrit()
    {
        static immutable float[3][12] table = [[0, 0, 10], [0, 0, 10], [3.70f, 14.77f, 0.65f], [0, 0, 10],
            [0, 0, 10], [2.97f, 10.03f, 0.82f], [0, 0, 10], [3.54f, 11.51f, 0.80f], [3.70f, 14.77f, 0.65f],
            [3.18f, 11.30f, 0.82f], [0, 0, 10], [3.33f, 12.41f, 0.79f]];
        const row = table[player.data.classId < table.length ? player.data.classId : 0];
        const intellect = player.values.get!UNIT_FIELD_STAT0(Stat.intellect);
        return row[0] + intellect / (row[1] + row[2] * player.data.level);
    }

    /// The player `target`, if this player may attack it (a duel's opponent); null otherwise.
    typeof(this) enemyPlayer(ulong target)
    {
        if (target == player.guid)
            return null;
        auto other = cast(typeof(this)) context.onlinePlayer(target);
        if (other is null || other.player is null || other.map !is map)
            return null;
        return canAttack(relatingNow(), other.relatingNow(), context.client) ? other : null;
    }

    /// Whether effect `i` of the spell picks its targets in an area (around a point, in a cone, the party).
    static bool isAreaTarget(const(SpellInfo)* spell, size_t i)
    {
        import std.algorithm.comparison : among;

        with (ImplicitTarget)
            return spell.implicitTargetA[i].among(enemiesAroundSource, enemiesAroundDest, enemiesInCone,
                partyAroundSource, partyInRange, friendsAroundSource, friendsAroundDest, party) != 0
                || spell.casting.implicitTargetB[i].among(enemiesAroundSource, enemiesAroundDest, enemiesInCone,
                partyAroundSource, partyInRange, friendsAroundSource, friendsAroundDest) != 0;
    }

    /// Whether this player may hurt the creature with an area or chained spell (alive,
    /// attackable, neutral ones too).
    bool spellEnemy(Creature creature)
    {
        return creature.alive && creature.ai !is null && canAttack(relatingNow(), relatingOf(creature), context.client);
    }

    /**
     * The area targets: the enemies (creatures, and players it may fight)
     * within the effect's radius of the caster, of the destination, or in a cone in front (60 degrees
     * to either side); or the party members (and itself) within the radius. Empty for other targets.
     */
    ulong[] areaTargets(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
    {
        import std.math : atan2, PI;

        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        auto kind = b != ImplicitTarget.none && isAreaTargetKind(b) ? b : a;
        if (!isAreaTargetKind(kind))
            return null;
        const r = spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));
        if (r <= 0)
            return null;
        Position center = player.position;
        if ((kind == ImplicitTarget.enemiesAroundDest || kind == ImplicitTarget.friendsAroundDest)
            && (targets.mask & TargetFlags.destLocation))
            center = Position(targets.dest[0], targets.dest[1], targets.dest[2]);
        bool within(Position p)
        {
            if ((p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2 > r * r)
                return false;
            if (kind != ImplicitTarget.enemiesInCone)
                return true;
            double angle = atan2(p.y - center.y, p.x - center.x) - player.position.orientation;
            while (angle > PI)
                angle -= 2 * PI;
            while (angle < -PI)
                angle += 2 * PI;
            return angle >= -PI / 3 && angle <= PI / 3;
        }

        ulong[] found;
        with (ImplicitTarget) if (kind == enemiesAroundSource || kind == enemiesAroundDest || kind == enemiesInCone)
        {
            foreach (creature; map.creaturesNear(center, r))
                if (spellEnemy(creature) && within(creature.position))
                    found ~= creature.guid;
            foreach (who; map.near(center, r))
                if (auto other = enemyPlayer(who.character.guid))
                    if (other.fighter.alive && within(other.player.position))
                        found ~= other.player.guid;
            return found;
        }
        // The party (or every friend, here the party too) within the radius, itself included.
        found ~= player.guid;
        if (auto group = context.groups.of(player.guid))
            foreach (ref slot; group.members)
                if (slot.guid != player.guid)
                    if (auto member = map.find(slot.guid))
                        if (within(member.character.position))
                            found ~= slot.guid;
        return found;
    }

    static bool isAreaTargetKind(uint kind)
    {
        import std.algorithm.comparison : among;

        with (ImplicitTarget)
            return kind.among(enemiesAroundSource, enemiesAroundDest, enemiesInCone, partyAroundSource, partyInRange,
                friendsAroundSource, friendsAroundDest, party) != 0;
    }

    /// Chain targets: from `first`, the nearest enemy within 10 yards of the last, `count` times.
    ulong[] chainTargets(ulong first, uint count)
    {
        enum float jump = 10;
        ulong[] chain;
        bool[ulong] taken = [first: true];
        auto last = cast(Creature) map.findObject(first);
        if (last is null)
            return null;
        Position at = last.position;
        foreach (_; 0 .. count)
        {
            Creature next;
            float best = jump * jump;
            foreach (creature; map.creaturesNear(at, jump))
            {
                if (creature.guid in taken || !spellEnemy(creature))
                    continue;
                const p = creature.position;
                const d = (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2;
                if (d <= best)
                {
                    best = d;
                    next = creature;
                }
            }
            if (next is null)
                break;
            chain ~= next.guid;
            taken[next.guid] = true;
            at = next.position;
        }
        return chain;
    }

    /// A school's damage to a player: a crit is half again; armor for physical.
    package void spellDamageToPlayer(const(SpellInfo)* spell, typeof(this) other, uint damage)
    {
        damage += spellDamageBonus(spell, spell.casting.school); // spell power, as against a creature
        const crit = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(map.random) * 100 < spellCritOf(spell);
        if (crit)
            damage = damage * 3 / 2;
        const school = spell.casting.school;
        uint resisted;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(player.data.level, other.player.fighter.armor, damage);
        else if (school != 1 && !isBinarySpell(*spell))
            resisted = partialResist(damage, cast(int) other.player.values.get!UNIT_FIELD_RESISTANCES(school),
                other.player.data.level);
        const absorbed = other.absorbDamage(school, damage);
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(other.player.guid, player.guid,
            spell.id, damage, school, absorbed, resisted, false, 0, crit), true);
        enterCombatFor(combatLinger);
        import dmangos.world.unit : Blow, dealDamage;

        dealDamage(unit, other.unit, damage, Blow.spell());
        if (other.player !is null && other.player.fighter.alive)
        {
            import dmangos.world.aurahandlers : ProcFlag;

            procAuras(ProcFlag.dealHarmfulSpell, other.unit);
        }
    }

    /// A school's damage: a crit is half again; armor for physical.
    /**
     * The damage bonus of a direct spell: the caster's `SPELL_AURA_MOD_DAMAGE_DONE` for
     * the spell's school (its items' and talents' "damage done by spells"), times the spell's
     * coefficient, its cast time over 3.5 seconds (from 1.5 to 3.5 seconds: instant spells count as
     * 1.5). Physical spells get none.
     */
    uint spellDamageBonus(const(SpellInfo)* spell, uint school)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.spellcast : castTime;

        if (school == 0)
            return 0;
        int done;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modDamageDone && (aura.misc(i) & (1 << school)))
                    done += aura.amount[i];
        if (done <= 0)
            return 0;
        int time = castTime(*spell, context.client, player.data.level);
        time = time < 1500 ? 1500 : time > 3500 ? 3500 : time;
        return cast(uint)(done * time / 3500.0f);
    }

    /// The healing bonus: the caster's `SPELL_AURA_MOD_HEALING_DONE` times the same coefficient.
    uint healingBonus(const(SpellInfo)* spell)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.spellcast : castTime;

        int done;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modHealingDone)
                    done += aura.amount[i];
        if (done <= 0)
            return 0;
        int time = castTime(*spell, context.client, player.data.level);
        time = time < 1500 ? 1500 : time > 3500 ? 3500 : time;
        return cast(uint)(done * time / 3500.0f);
    }

    void spellDamage(const(SpellInfo)* spell, Creature victim, uint damage, uint school)
    {
        damage += spellDamageBonus(spell, school);
        const crit = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(map.random) * 100 < spellCritOf(spell);
        if (crit)
            damage = damage * 3 / 2;
        uint resisted;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(player.data.level, victim.fighter.armor, damage);
        else if (school != 1 && !isBinarySpell(*spell)) // holy: no resistance; a binary spell: all or nothing
        {
            // A partial resist: a share of it resisted.
            import dmangos.world.combat : effectiveResistPercent, rollPartialResist;
            import std.random : uniform;

            const percent = effectiveResistPercent(cast(int) victim.values.get!UNIT_FIELD_RESISTANCES(school),
                player.data.level, victim.values.get!UNIT_FIELD_LEVEL, true);
            const share = rollPartialResist(percent, uniform!"[]"(1u, 10000u, map.random));
            if (share > 0)
            {
                resisted = cast(uint)(damage * share);
                damage -= resisted;
            }
            else if (share < 0)
                damage += cast(uint)(damage * -share);
        }
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.guid, player.guid,
            spell.id, damage, school, 0, resisted, false, 0, crit), true);
        spellAttacked(victim, damage);
        if (victim.alive)
        {
            import dmangos.world.aurahandlers : ProcFlag;

            procAuras(ProcFlag.dealHarmfulSpell, map.unitOf(victim));
        }
    }

    /**
     * Weapon damage: the weapon's damage, plus the effect's bonus (or times its percentage),
     * less armor; a crit is double (the melee crit chance); a block takes off what the shield stops.
     */
    package void weaponSpellDamage(const(SpellInfo)* spell, size_t i, UnitRef victim, int value)
    {
        // Only the first weapon damage effect deals the damage; the others add to it.
        foreach (j; 0 .. i)
            if (spell.effect[j] == 17 || spell.effect[j] == 58 || spell.effect[j] == 121 || spell.effect[j] == 31)
                return;
        const me = player.fighter, it = victim.fighter;
        enum uint spellAttrRanged = 0x2; // SPELL_ATTR_RANGED: the ranged slot's weapon (a wand's Shoot too)
        const type = spell.casting.dmgClass == DamageClass.ranged || (spell.attributes & spellAttrRanged)
            ? AttackType.ranged : AttackType.mainHand;
        float damage = weaponDamage(me, type, map.random);
        float percent = 100;
        foreach (j; i .. 3)
        {
            const v = effectMod(spell, j, effectValue(*spell, j, player.data.level, uniform01(map.random)));
            if (spell.effect[j] == 17 || spell.effect[j] == 58 || spell.effect[j] == 121)
                damage += v;
            else if (spell.effect[j] == 31)
                percent = v;
        }
        damage = damage * percent / 100;
        damage = armorReducedDamage(me.level, it.armor, damage);
        bool crit;
        if (uniform01(map.random) * 100 < critChance(me, it, type))
        {
            crit = true;
            damage *= 2;
        }
        uint blocked;
        if (uniform01(map.random) * 100 < blockChance(it, me, type))
            blocked = 0; // creatures carry no shield values yet
        const total = damage > 0 ? cast(uint) damage : 0;
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.combatGuid, player.guid,
            spell.id, total, 0, 0, 0, false, blocked, crit), true);
        enterCombatFor(combatLinger);
        final switch (victim.kind)
        {
        case UnitKind.none:
            break;
        case UnitKind.creature:
            spellAttacked(victim.creature, total);
            break;
        case UnitKind.player:
            import dmangos.world.unit : Blow, dealDamage;

            if (victim.fighter.alive)
                dealDamage(unit, victim, total, Blow.spell());
            break;
        }
    }

    /// A creature hit (or missed) by this player's spell, or its aura's tick: it fights back, takes the
    /// damage, and may die (`dmangos.world.unit.dealDamage`).
    void spellAttacked(Creature victim, uint damage, bool tick = false)
    {
        import dmangos.world.unit : Blow, dealDamage;

        if (!victim.alive)
            return;
        enterCombatFor(combatLinger);
        dealDamage(unit, map.unitOf(victim), damage, tick ? Blow.periodic() : Blow.spell());
    }

    /// A heal: health back, a crit half again, and the heal log sent.
    void heal(const(SpellInfo)* spell, ulong target, int value)
    {
        if (value <= 0)
            return;
        auto who = target == player.guid ? this : cast(typeof(this)) context.onlinePlayer(target);
        if (who is null || who.player is null || who.map !is map)
            return;
        pvpAssisted(who);
        value += healingBonus(spell);
        const crit = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(map.random) * 100 < spellCritOf(spell);
        uint amount = crit ? value * 3 / 2 : value;
        auto v = &who.player.values;
        const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
        if (health == 0)
            return;
        const healed = health + amount > maxHealth ? maxHealth - health : amount;
        v.set!UNIT_FIELD_HEALTH(health + healed);
        map.sendToWatchers(this, Opcode.SMSG_SPELLHEALLOG, healLog(target, player.guid, spell.id, amount, crit), true);
        if (who !is this)
            who.flushPlayerChanges();
    }

    /// Power given back, of the effect's kind (`EffectMiscValue`).
    void energize(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        if (value <= 0)
            return;
        auto who = target == player.guid ? this : cast(typeof(this)) context.onlinePlayer(target);
        if (who is null || who.player is null)
            return;
        const power = cast(Power) spell.miscValue[i];
        if (power > Power.happiness)
            return;
        who.player.modifyPower(power, value);
        map.sendToWatchers(this, Opcode.SMSG_SPELLENERGIZELOG, energizeLog(target, player.guid, spell.id, power,
            value), true);
        if (who !is this)
            who.flushPlayerChanges();
    }

    /// A teleport: to the home bind (the hearthstone), or where the client chose.
    void teleportUnits(const(SpellInfo)* spell, size_t i, ref Casting c)
    {
        const b = spell.casting.implicitTargetB[i];
        if (b == ImplicitTarget.homeBind || spell.implicitTargetA[i] == ImplicitTarget.homeBind)
        {
            const home = player.data.homeBind;
            commandTeleport(home.map, Position(home.x, home.y, home.z, player.position.orientation));
        }
        else if (c.targets.mask & TargetFlags.destLocation)
            commandTeleport(player.data.map, Position(c.targets.dest[0], c.targets.dest[1], c.targets.dest[2],
                player.position.orientation));
        else
            info!"%s: spell %s teleports to a target not done yet (%s)"(remoteAddress, spell.id, b);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.spells : SpellInfo;

    /// A spell for tests: one effect at one implicit target, instant unless `castIndex` names a cast time.
    SpellInfo testSpell(uint id, uint effect, uint target, int value, uint castIndex = 0)
    {
        SpellInfo s;
        s.id = id;
        s.effect[0] = effect;
        s.implicitTargetA[0] = target;
        s.basePoints[0] = value - 1;
        s.baseDice[0] = 1;
        s.casting.castingTimeIndex = castIndex;
        s.casting.rangeIndex = 1;
        s.casting.dmgClass = 1;
        return s;
    }
}

/**
 * A cast with a cast time: started, gone after it, the damage dealt; moving interrupts the next.
 * A heal on oneself. A spell on the next swing replaces it. An item's spell takes its user home.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid, ClientTeleportAck;
    import dmangos.world.player : HomeBind, Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.bytes : ByteWriter;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0], [2u, 1500, 0, 1500]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint bolt = 90001, mend = 90002, strike = 90003, home = 90004;
    with (context.data.spells)
    {
        spells[bolt] = testSpell(bolt, 2, 6, 10, 2);           // 10 damage at an enemy, 1.5 s
        spells.edit(bolt).casting.interruptFlags = 0x01;
        spells[mend] = testSpell(mend, 10, 1, 20);              // heals oneself 20
        spells[strike] = testSpell(strike, 17, 6, 11);          // next swing: weapon + 11
        spells.edit(strike).attributes = 0x4;
        spells.edit(strike).casting.dmgClass = 2;
        spells[home] = testSpell(home, 5, 1, 0);                // home
        spells.edit(home).casting.implicitTargetB[0] = 9;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= [bolt, mend, strike];
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    // The innkeeper an enemy of 500 health.
    enum uint players = 1, monsters = 8;
    const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, players, 0,
        0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);

    ubyte[] castAt(uint spell, ulong target)
    {
        ByteWriter w;
        w.put(spell);
        auto t = SpellTargets(target ? TargetFlags.unit : TargetFlags.self, target);
        t.write(w);
        return w.data.dup;
    }

    // The bolt: started, then gone 1.5 s later, its damage dealt unless resisted.
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(bolt, keeper.guid));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_SPELL_START]);
    anduin.session.update(1000.msecs);
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO), "not before its time");
    anduin.session.update(600.msecs);
    const gone = opcodesOf(anduin.read());
    assert(gone.canFind(Opcode.SMSG_CAST_RESULT) && gone.canFind(Opcode.SMSG_SPELL_GO));
    assert(gone.canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG) || gone.canFind(Opcode.SMSG_SPELLLOGMISS));
    assert(keeper.ai.inCombat, "attacked by a spell, it fights");
    if (gone.canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
        assert(keeper.values.get!UNIT_FIELD_HEALTH <= 490);

    // Again, but moving interrupts it.
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(bolt, keeper.guid));
    anduin.read();
    anduin.write(Opcode.MSG_MOVE_START_FORWARD, moveTo(Position(-8949.9f, -132.4f, 83.53f, 1.97f), 1));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_FAILURE));
    anduin.write(Opcode.MSG_MOVE_STOP, moveTo(Position(-8949.9f, -132.4f, 83.53f, 1.97f)));
    anduin.read();

    // A heal on oneself.
    me.values.set!UNIT_FIELD_HEALTH(10u);
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(mend, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELLHEALLOG));
    assert(me.values.get!UNIT_FIELD_HEALTH >= 30);

    // The strike waits for the next swing and replaces it.
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(strike, keeper.guid));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_SPELL_START]);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    anduin.read();
    now += 3.seconds;
    anduin.session.update(3000.msecs);
    const swung = opcodesOf(anduin.read());
    assert(swung.canFind(Opcode.SMSG_SPELL_GO) && !swung.canFind(Opcode.SMSG_ATTACKERSTATEUPDATE));

    // An item whose spell goes home.
    anduin.write(Opcode.CMSG_ATTACKSTOP, null);
    me.data.homeBind = HomeBind(0, 12, -9000, -100, 80);
    auto stone = context.data.items.edit(itemHearthstone);
    stone.details.spells[0].id = home;
    stone.details.spells[0].trigger = 0;
    import dmangos.world.defines : nullBag, nullSlot;
    import dmangos.world.inventory : InventoryResult, ItemPosCount;

    ItemPosCount[] dest;
    assert(me.inventory.canStoreNew(nullBag, nullSlot, dest, itemHearthstone, 1) == InventoryResult.ok);
    const carried = me.inventory.storeNew(dest, itemHearthstone);
    assert(carried !is null);
    ByteWriter use;
    use.put(carried.bagSlot);
    use.put(carried.slot);
    use.put(ubyte(1));
    SpellTargets(TargetFlags.self).write(use);
    now += 2.seconds; // the global cooldown is over
    anduin.write(Opcode.CMSG_USE_ITEM, use.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK), "home");
}

/**
 * A channelled spell: `MSG_CHANNEL_START` and the caster's channel fields, `MSG_CHANNEL_UPDATE` when
 * its time is up; moving cuts it short, and its aura on the target goes with it.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : spellCastTimesFormat, spellDurationFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : MovementInfo, Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 3000, 0, 3000]]), "SpellDuration.dbc");
    enum uint drain = 95400;
    context.data.spells.spells[drain] = testSpell(drain, 6, 6, 2); // 2 damage a second, channelled for 3 s
    with (*context.data.spells.spells.edit(drain))
    {
        casting.applyAuraName[0] = AuraType.periodicDamage;
        casting.amplitude[0] = 1000;
        casting.durationIndex = 1;
        casting.dmgClass = 0;
        casting.channelInterruptFlags = 0x08; // moving ends it
        attributesEx = 0x04;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    me.spells ~= drain;
    anduin.read();
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    void cast_()
    {
        ByteWriter w;
        w.put(drain);
        SpellTargets(TargetFlags.unit, keeper.guid).write(w);
        anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    }
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        context.map(0).update(ms.msecs);
    }

    cast_();
    assert(opcodesOf(anduin.read()).canFind(Opcode.MSG_CHANNEL_START));
    assert(me.values.get!UNIT_CHANNEL_SPELL == drain && me.values.get!UNIT_FIELD_CHANNEL_OBJECT == keeper.guid);
    tick(1500);
    tick(1600);
    assert(opcodesOf(anduin.read()).canFind(Opcode.MSG_CHANNEL_UPDATE), "its time is up");
    assert(me.values.get!UNIT_CHANNEL_SPELL == 0);

    // Again, and the player walks away: cut short, its aura gone from the innkeeper.
    now += 3.seconds;
    cast_();
    assert(keeper.auras.find(drain) !is null);
    anduin.read();
    MovementInfo step = me.movement;
    step.flags = 0x1; // forward
    ByteWriter w;
    step.write(w);
    anduin.write(Opcode.MSG_MOVE_START_FORWARD, w.data);
    const cut = opcodesOf(anduin.read());
    assert(cut.canFind(Opcode.MSG_CHANNEL_UPDATE) && keeper.auras.find(drain) is null && me.values.get!UNIT_CHANNEL_SPELL == 0);
}

/**
 * Fishing: the bobber on the water, the channel at it; used before the bite nothing is hooked; after
 * the bite (its splash) a skilled angler's catch is looted from the zone's `fishing_loot_template`.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat, spellDurationFormat, spellRangeFormat;
    import dmangos.world.gameobject : GameObject, GameObjectTemplate, GameObjectType;
    import dmangos.world.loot : lootRow, LootStore;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(10), bits(20), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 20_000, 0, 20_000]]), "SpellDuration.dbc");
    enum uint fishing = 95500, bobberEntry = 9030;
    context.data.spells.spells[fishing] = testSpell(fishing, 50, 1, 0);
    with (*context.data.spells.spells.edit(fishing))
    {
        miscValue[0] = bobberEntry;
        casting.durationIndex = 1;
        casting.dmgClass = 0;
        attributesEx = 0x04; // channelled
    }
    GameObjectTemplate bobberTemplate = {entry: bobberEntry, type: GameObjectType.fishingNode, displayId: 668,
        name: "Fishing Bobber"};
    context.data.gameObjectTemplates[bobberEntry] = bobberTemplate;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    me.spells ~= fishing;
    me.setSkill(356, 100, 150);
    context.data.fishingBaseSkill[me.data.zone] = 1;
    context.data.loot.fishing = new LootStore("fishing_loot_template");
    context.data.loot.fishing.add(me.data.zone, lootRow(itemJerky, 100, 0, 1, 1, 0));
    anduin.read();
    auto map = context.map(0);
    map.waterForTests = 80; // a lake all round
    GameObject bobberNow()
    {
        foreach (o; map.objectsNear(me.position, 30))
            if (auto go = cast(GameObject) o)
                if (go.type == GameObjectType.fishingNode)
                    return go;
        return null;
    }
    void cast_()
    {
        ByteWriter w;
        w.put(fishing);
        SpellTargets(TargetFlags.self, 0).write(w);
        anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    }
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
    }

    // No fishing pole worn: refused (`SPELL_FAILED_EQUIPPED_ITEM_CLASS`, with the class and subclasses wanted).
    context.data.spells.spells.edit(fishing).equippedItemClass = 2;           // a weapon
    context.data.spells.spells.edit(fishing).equippedItemSubClassMask = 1 << 20; // a fishing pole
    cast_();
    assert(bobberNow() is null && opcodesOf(anduin.read()).canFind(Opcode.SMSG_CAST_RESULT), "no pole");
    context.data.spells.spells.edit(fishing).equippedItemClass = -1;

    cast_();
    auto bob = bobberNow();
    assert(bob !is null && bob.owner == me.guid && me.values.get!UNIT_FIELD_CHANNEL_OBJECT == bob.guid, "cast out");
    anduin.read();
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(bob.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_FISH_NOT_HOOKED) && bobberNow() is null, "too soon");

    now += 2000.msecs;
    cast_();
    bob = bobberNow();
    anduin.read();
    bool splashed;
    foreach (_; 0 .. 18) // the bite comes 3 to 17 seconds before the 20 end
    {
        tick(1000);
        if (opcodesOf(anduin.read()).canFind(Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM))
        {
            splashed = true;
            break;
        }
    }
    assert(splashed, "the splash");
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(bob.guid));
    const caught = anduin.read();
    assert(opcodesOf(caught).canFind(Opcode.SMSG_LOOT_RESPONSE), "a catch");

    // A school of fish where the bobber lands: the catch is its own, and it is counted.
    import dmangos.world.gameobject : GameObjectSpawn;

    GameObjectTemplate school = {entry: 9031, type: GameObjectType.fishingHole, displayId: 1, name: "School"};
    school.data[1] = 777; // its loot
    school.data[2] = 2;
    school.data[3] = 2;   // two catches
    context.data.gameObjectTemplates[9031] = school;
    context.data.loot.gameObject.add(777, lootRow(itemSword, 100, 0, 1, 1, 0));
    const at = me.position;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90031, 9031, 0, at.x + 15, at.y, 80, 0, [0, 0, 0, 0], 60);
    auto hole = context.makeGameObject(&context.data.gameObjectSpawns[$ - 1]);
    map.addObject(hole);
    now += 2000.msecs;
    cast_();
    bob = bobberNow();
    anduin.read();
    foreach (_; 0 .. 18)
    {
        tick(1000);
        if (opcodesOf(anduin.read()).canFind(Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM))
            break;
    }
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(bob.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE) && hole.loot !is null && hole.holeMaxCatches == 2,
        "the school's catch");

    // Waters too hard for the angler: the fish escapes; or, if the server gives it, junk (entry 0).
    context.data.fishingBaseSkill[me.data.zone] = 500;
    context.data.loot.fishing.add(0, lootRow(itemShirt, 100, 0, 1, 1, 0));
    auto reelIn()
    {
        now += 2000.msecs;
        cast_();
        bob = bobberNow();
        anduin.read();
        foreach (_; 0 .. 18)
        {
            tick(1000);
            if (opcodesOf(anduin.read()).canFind(Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM))
                break;
        }
        anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(bob.guid));
        return anduin.read();
    }
    assert(opcodesOf(reelIn()).canFind(Opcode.SMSG_FISH_ESCAPED), "it got away");
    context.config.skillFailLootFishing = true;
    assert(opcodesOf(reelIn()).canFind(Opcode.SMSG_LOOT_RESPONSE), "junk");
}

/**
 * Area and chain targets: a spell around the caster (`TARGET_CASTER_COORDINATES` with
 * `TARGET_ALL_ENEMY_IN_AREA`) hits every enemy within its radius, and a chained one jumps from its
 * target to the next enemy within 10 yards.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellRadiusFormat,
        spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
        [[1u, bits(10), 0, 0]]), "SpellRadius.dbc");
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    enum uint players = 1, monsters = 8;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto trainer = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    foreach (c; [keeper, trainer])
    {
        c.factionTemplate = context.client.factionTemplates.lookup(14);
        c.values.set!UNIT_FIELD_FACTIONTEMPLATE(14u);
        c.values.set!UNIT_FIELD_MAXHEALTH(500u);
        c.values.set!UNIT_FIELD_HEALTH(500u);
    }
    enum uint blast = 95600, bolt = 95601;
    context.data.spells.spells[blast] = testSpell(blast, 2, ImplicitTarget.casterSource, 20);
    with (context.data.spells.spells.edit(blast).casting)
    {
        implicitTargetB[0] = ImplicitTarget.enemiesAroundSource;
        radiusIndex[0] = 1;
        dmgClass = 0;
    }
    context.data.spells.spells[bolt] = testSpell(bolt, 2, ImplicitTarget.enemy, 20);
    with (context.data.spells.spells.edit(bolt).casting)
    {
        chainTarget[0] = 2;
        dmgClass = 0;
    }
    me.spells ~= [blast, bolt];
    anduin.read();

    ByteWriter w;
    w.put(blast);
    SpellTargets(TargetFlags.self, 0).write(w);
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    assert(keeper.values.get!UNIT_FIELD_HEALTH < 500 && trainer.values.get!UNIT_FIELD_HEALTH < 500, "both within 10 yards");

    const keeperBefore = keeper.values.get!UNIT_FIELD_HEALTH, trainerBefore = trainer.values.get!UNIT_FIELD_HEALTH;
    anduin.session.inWorld.castTriggeredAt(bolt, keeper.guid); // past the global cooldown
    assert(keeper.values.get!UNIT_FIELD_HEALTH < keeperBefore && trainer.values.get!UNIT_FIELD_HEALTH < trainerBefore,
        "the bolt jumped to the trainer");

    // Spell power: +35 fire damage done (an aura), on an instant fire spell: 35 * 1.5 / 3.5 = 15 more.
    {
        import dmangos.world.auras : AuraType, makeAura;

        enum uint power = 95603, fire = 95604;
        context.data.spells.spells[power] = testSpell(power, 6, ImplicitTarget.caster, 35);
        context.data.spells.spells.edit(power).casting.applyAuraName[0] = AuraType.modDamageDone;
        context.data.spells.spells.edit(power).miscValue[0] = 1 << 2; // fire
        context.data.spells.spells[fire] = testSpell(fire, 2, ImplicitTarget.enemy, 20);
        context.data.spells.spells.edit(fire).casting.school = 2;
        context.data.spells.spells.edit(fire).casting.dmgClass = 0;
        context.data.spells.spells.edit(fire).attributesEx2 |= 0x20000000; // no crit
        auto aura = makeAura((power in context.data.spells.spells), me.guid, 1, -1, true, [35, 0, 0]);
        aura.passive = true;
        anduin.session.inWorld.addAura(aura);
        keeper.values.set!UNIT_FIELD_LEVEL(me.values.get!UNIT_FIELD_LEVEL); // no resist from levels
        const before = keeper.values.get!UNIT_FIELD_HEALTH;
        anduin.session.inWorld.castTriggeredAt(fire, keeper.guid);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == before - 35, "20 and 15 of spell power");

        // Healing power: +35 healing done on an instant heal of 20: 35 more.
        enum uint healing = 95605, mend = 95606;
        context.data.spells.spells[healing] = testSpell(healing, 6, ImplicitTarget.caster, 35);
        context.data.spells.spells.edit(healing).casting.applyAuraName[0] = AuraType.modHealingDone;
        context.data.spells.spells[mend] = testSpell(mend, 10, ImplicitTarget.caster, 20);
        context.data.spells.spells.edit(mend).attributesEx2 |= 0x20000000; // no crit
        auto healAura = makeAura((healing in context.data.spells.spells), me.guid, 1, -1, true, [35, 0, 0]);
        healAura.passive = true;
        anduin.session.inWorld.addAura(healAura);
        me.values.set!UNIT_FIELD_MAXHEALTH(500u);
        me.values.set!UNIT_FIELD_HEALTH(100u);
        anduin.session.inWorld.castTriggeredAt(mend, me.guid);
        assert(me.values.get!UNIT_FIELD_HEALTH == 100 + 20 + 15, "20 and 15 of healing power");
    }

    // A missile at 10 yards a second: nothing on release, its damage when it arrives (about 2.7 yards off).
    import core.time : msecs;

    enum uint missile = 95602;
    context.data.spells.spells[missile] = testSpell(missile, 2, ImplicitTarget.enemy, 20);
    context.data.spells.spells.edit(missile).casting.speed = 10;
    context.data.spells.spells.edit(missile).casting.dmgClass = 0;
    const flying = keeper.values.get!UNIT_FIELD_HEALTH;
    anduin.session.inWorld.castTriggeredAt(missile, keeper.guid);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == flying, "still in flight");
    anduin.session.update(400.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH < flying, "arrived");

    // A sword's chance on hit (100%): a hit with it casts its spell at the victim.
    {
        import dmangos.world.combat : AttackType;
        import dmangos.world.defines : equipmentSlotMainhand, inventorySlotBag0;
        import dmangos.world.packets : ClientItemPos;

        enum uint smite = 95607;
        context.data.spells.spells[smite] = testSpell(smite, 2, ImplicitTarget.enemy, 25);
        context.data.spells.spells.edit(smite).casting.school = 1; // holy: not resisted
        context.data.spells.spells.edit(smite).casting.dmgClass = 0;
        context.data.spells.spells.edit(smite).casting.procChance = 100;
        context.data.spells.spells.edit(smite).attributesEx2 |= 0x20000000; // no crit
        context.data.items.edit(itemSword).details.spells[0].id = smite;
        context.data.items.edit(itemSword).details.spells[0].trigger = 2; // chance on hit
        anduin.session.inWorld.lootStore(itemSword, 1, 0, false);
        anduin.read();
        ubyte slot;
        foreach (s; ubyte(23) .. ubyte(39))
            if (const item = me.inventory[inventorySlotBag0, s])
                if (item.entry == itemSword)
                    slot = s;
        anduin.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
        anduin.read();
        assert(me.inventory.equipped(equipmentSlotMainhand) !is null);
        const struck = keeper.values.get!UNIT_FIELD_HEALTH;
        anduin.session.inWorld.castItemCombatSpells(keeper, AttackType.mainHand);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == struck - 25, "the proc");
        anduin.session.inWorld.castItemCombatSpells(keeper, AttackType.offHand);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == struck - 25, "not for the other hand");

        // An enchantment instead (a poison: its spell 100% of the time, by its amount): it procs too.
        import dmangos.world.enchantments : EnchantmentEffect, EnchantmentType;

        context.data.items.edit(itemSword).details.spells[0].id = 0;
        enum uint poison = 9001;
        context.data.enchantmentEffects[poison] = [EnchantmentEffect(EnchantmentType.combatSpell, 100, smite),
            EnchantmentEffect.init, EnchantmentEffect.init];
        auto sword = me.inventory.equipped(equipmentSlotMainhand);
        anduin.session.inWorld.enchantItem(sword.fullGuid, poison, true, 1800);
        anduin.read();
        const poisoned = keeper.values.get!UNIT_FIELD_HEALTH;
        anduin.session.inWorld.castItemCombatSpells(keeper, AttackType.mainHand);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == poisoned - 25, "the enchantment's proc");
    }
}

/// A persistent area aura: a spot on the ground that hurts the creatures in it every tick, for its duration.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRadiusFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.dynobject : DynamicObject;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
        [[1u, bits(8), 0, 0]]), "SpellRadius.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 3000, 0, 3000]]), "SpellDuration.dbc");
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, 1 | 2, 2, 8, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, 8, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]]),
        "FactionTemplate.dbc");
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    enum uint consecrate = 95700;
    context.data.spells.spells[consecrate] = testSpell(consecrate, 27, ImplicitTarget.caster, 10);
    context.data.spells.spells.edit(consecrate).attributesEx2 |= 0x20000000; // SPELL_ATTR_EX2_CANT_CRIT: even ticks
    with (context.data.spells.spells.edit(consecrate).casting)
    {
        radiusIndex[0] = 1;
        durationIndex = 1;
        amplitude[0] = 1000;
        dmgClass = 0;
    }
    me.spells ~= consecrate;
    anduin.read();
    ByteWriter w;
    w.put(consecrate);
    SpellTargets(TargetFlags.self, 0).write(w);
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    DynamicObject spot;
    foreach (o; map.objectsNear(me.position, 5))
        if (auto d = cast(DynamicObject) o)
            spot = d;
    assert(spot !is null, "the spot on the ground");
    foreach (_; 0 .. 4)
    {
        now += 1000.msecs;
        anduin.session.update(1000.msecs);
    }
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 500 - 3 * 10, "three ticks of 10");
    assert(map.findObject(spot.guid) is null, "gone after its 3 seconds");

    // A ground effect that slows (a frost trap's): those inside are held slowed, not hurt.
    import dmangos.world.auras : AuraType;

    enum uint frostTrap = 95701;
    context.data.spells.spells[frostTrap] = testSpell(frostTrap, 27, ImplicitTarget.caster, -60);
    with (context.data.spells.spells.edit(frostTrap).casting)
    {
        applyAuraName[0] = AuraType.modDecreaseSpeed;
        radiusIndex[0] = 1;
        durationIndex = 1;
        dmgClass = 0;
    }
    me.spells ~= frostTrap;
    ByteWriter w2;
    w2.put(frostTrap);
    SpellTargets(TargetFlags.self, 0).write(w2);
    anduin.write(Opcode.CMSG_CAST_SPELL, w2.data);
    now += 1000.msecs;
    anduin.session.update(1000.msecs);
    assert(keeper.auras.find(frostTrap) !is null, "slowed while inside");
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 500 - 3 * 10, "and not hurt");
}

/// Cooldowns last through a logout: saved, read back at login, and shown in `SMSG_INITIAL_SPELLS`.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteReader;
    import dmangos.serialization : deserialize;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.packets : ClientPlayerLogin, InitialCooldown, ServerInitialSpells;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto shout = SpellInfo(29100);
    shout.effect[0] = 3; // dummy
    shout.implicitTargetA[0] = 1;
    shout.recoveryTime = 60_000;
    context.data.spells.spells[29100] = shout;
    const spell = (29100 in context.data.spells.spells);

    auto hero = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    hero.read();
    assert(hero.session.inWorld.castSpell(spell, SpellTargets(TargetFlags.self, 0), false, 0) == SpellCastResult.ok);
    now += 2.seconds; // past the global cooldown
    assert(hero.session.inWorld.castSpell(spell, SpellTargets(TargetFlags.self, 0), false, 0) == SpellCastResult.notReady);
    hero.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    hero.read();
    assert(db.loadCooldowns(7).length == 1, "saved");

    now += 10.seconds;
    hero.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    InitialCooldown[] shown;
    foreach (p; hero.read())
        if (p.opcode == Opcode.SMSG_INITIAL_SPELLS)
        {
            auto r = ByteReader(p.body_);
            shown = deserialize!ServerInitialSpells(r).cooldowns;
        }
    assert(shown.length == 1 && shown[0].spell == 29100 && shown[0].spellMs > 40_000 && shown[0].spellMs <= 50_000,
        "the client is told: about 48 s left");
    assert(hero.session.inWorld.castSpell(spell, SpellTargets(TargetFlags.self, 0), false, 0) == SpellCastResult.notReady);
    now += 50.seconds;
    assert(hero.session.inWorld.castSpell(spell, SpellTargets(TargetFlags.self, 0), false, 0) == SpellCastResult.ok, "over");
}

/// Talents' spell modifiers in a cast: a percent off the cost of the spells of its mask, not others'.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spellmods : auraAddPctModifier, SpellModOp;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_POWER1;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    SpellInfo blast(uint id, ulong flags)
    {
        auto s = SpellInfo(id);
        s.effect[0] = 3; // dummy
        s.implicitTargetA[0] = 1;
        s.casting.manaCost = 100;
        s.casting.spellFamilyName = 3;
        s.casting.spellFamilyFlags = flags;
        return s;
    }
    context.data.spells.spells[29101] = blast(29101, 0x1);
    context.data.spells.spells[29102] = blast(29102, 0x2);
    auto talent = SpellInfo(29103);
    talent.effect[0] = 6;
    talent.casting.applyAuraName[0] = auraAddPctModifier;
    talent.miscValue[0] = SpellModOp.cost;
    talent.itemType[0] = 0x1;
    talent.casting.spellFamilyName = 3;
    context.data.spells.spells[29103] = talent;

    auto mage = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player, raceOrc);
    mage.read();
    auto me = cast(Player) mage.session.character;
    bool isNew;
    me.auras.apply(makeAura((29103 in context.data.spells.spells), me.guid, 10, -1, true, [-50, 0, 0]), me.values, isNew);
    me.values.set!UNIT_FIELD_POWER1(1000u);
    assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_POWER1 == 950, "half the cost");
    now += 2.seconds;
    assert(mage.session.inWorld.castSpell((29102 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_POWER1 == 850, "not of its mask: the whole cost");
}

/// Struck in melee: a damage shield hurts the attacker; an aura that procs on being struck casts its spell, until out of charges.
unittest
{
    import core.time : MonoTime;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.creature : Creature;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.unit : Blow;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint thorns = 95700, shield = 95701, bolt = 95702;
    with (context.data.spells)
    {
        spells[thorns] = testSpell(thorns, 6, ImplicitTarget.caster, 3);
        spells.edit(thorns).casting.applyAuraName[0] = AuraType.damageShield;
        spells.edit(thorns).casting.school = 3; // nature
        spells[bolt] = testSpell(bolt, 2, ImplicitTarget.enemy, 10);
        spells.edit(bolt).casting.school = 1; // holy: not resisted
        spells.edit(bolt).casting.dmgClass = 0;
        spells.edit(bolt).attributesEx2 |= 0x20000000; // no crit
        spells[shield] = testSpell(shield, 6, ImplicitTarget.caster, 0);
        spells.edit(shield).casting.applyAuraName[0] = AuraType.procTriggerSpell;
        spells.edit(shield).triggerSpell[0] = bolt;
        spells.edit(shield).casting.procFlags = 0x8; // struck in melee
        spells.edit(shield).casting.procChance = 100;
        spells.edit(shield).casting.procCharges = 2;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    anduin.read();
    auto session = anduin.session.inWorld;
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    me.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    me.values.set!UNIT_FIELD_HEALTH(1000u);
    auto attacker = context.map(0).unitOf(keeper);
    MeleeDamage d;
    d.attacker = keeper.guid;
    d.target = me.guid;
    d.damage = 5;
    d.outcome = MeleeHitOutcome.normal;

    session.addAura(makeAura(thorns in context.data.spells.spells, me.guid, 1, -1, true, [3, 0, 0]));
    session.sufferDamage(attacker, 5, Blow.swing(d));
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 497, "thorns");
    d.outcome = MeleeHitOutcome.miss;
    session.sufferDamage(attacker, 0, Blow.swing(d));
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 497, "a miss: nothing");

    session.addAura(makeAura(shield in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));
    d.outcome = MeleeHitOutcome.normal;
    session.sufferDamage(attacker, 5, Blow.swing(d));
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 497 - 3 - 10, "thorns and the shield's bolt");
    session.sufferDamage(attacker, 5, Blow.swing(d));
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 497 - 26, "its second charge");
    assert(!me.auras.has(AuraType.procTriggerSpell), "out of charges: gone");
    session.sufferDamage(attacker, 5, Blow.swing(d));
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 497 - 29, "thorns alone");

    // An aura that procs on a damaging spell: the bolt brings a second bolt, and that one nothing more.
    enum uint echo = 95703;
    context.data.spells.spells[echo] = testSpell(echo, 6, ImplicitTarget.caster, 0);
    with (*context.data.spells.spells.edit(echo))
    {
        casting.applyAuraName[0] = AuraType.procTriggerSpell;
        triggerSpell[0] = bolt;
        casting.procFlags = 0x10000;
        casting.procChance = 100;
    }
    session.addAura(makeAura(echo in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));
    const before = keeper.values.get!UNIT_FIELD_HEALTH;
    session.castTriggeredAt(bolt, keeper.guid);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == before - 20, "two bolts, not more");
}

/// Dispelling: magic only where it hurts, by dispel type, a friend's harmful magic too.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    anduin.read();
    auto session = anduin.session.inWorld;
    enum uint hex = 95800, blessing = 95801, curse = 95802, dispelMagic = 95803, removeCurse = 95804;
    with (context.data.spells)
    {
        foreach (id; [hex, blessing, curse])
        {
            spells[id] = testSpell(id, 6, ImplicitTarget.caster, 1);
            spells.edit(id).casting.applyAuraName[0] = AuraType.modStat;
            spells.edit(id).casting.dispel = id == curse ? 2 : 1;
        }
        spells[dispelMagic] = testSpell(dispelMagic, 38, ImplicitTarget.caster, 2);
        spells.edit(dispelMagic).miscValue[0] = 1;
        spells[removeCurse] = testSpell(removeCurse, 38, ImplicitTarget.caster, 1);
        spells.edit(removeCurse).miscValue[0] = 2;
    }
    const(SpellInfo)* s(uint id) { return id in context.data.spells.spells; }
    session.addAura(makeAura(s(hex), 1, 1, -1, false, [1, 0, 0]));
    session.addAura(makeAura(s(blessing), me.guid, 1, -1, true, [1, 0, 0]));
    session.addAura(makeAura(s(curse), 1, 1, -1, false, [1, 0, 0]));
    anduin.read();
    session.dispelEffect(s(dispelMagic), 0, me.guid, 2);
    assert(me.auras.find(hex) is null && me.auras.find(blessing) !is null && me.auras.find(curse) !is null,
        "harmful magic only");
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELLDISPELLOG));
    session.dispelEffect(s(removeCurse), 0, me.guid, 1);
    assert(me.auras.find(curse) is null && me.auras.find(blessing) !is null, "the curse");

    // A creature it may attack: its harmful magic stays, its helpful magic is purged.
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.auras.list ~= makeAura(s(hex), 1, 1, -1, false, [1, 0, 0]);
    keeper.auras.list ~= makeAura(s(blessing), keeper.guid, 1, -1, true, [1, 0, 0]);
    session.dispelEffect(s(dispelMagic), 0, keeper.guid, 2);
    assert(keeper.auras.find(hex) !is null && keeper.auras.find(blessing) is null);
}

/// A player's resistance takes its share of a spell's damage, as a creature's does (with no level bonus).
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto session = anduin.session.inWorld;
    ulong taken, resisted;
    foreach (_; 0 .. 1000)
    {
        uint damage = 1000;
        resisted += session.partialResist(damage, 300, 60);
        taken += damage;
    }
    assert(taken + resisted == 1_000_000 && resisted > 300_000, "most of it resisted at the most");
    uint none = 1000;
    assert(session.partialResist(none, 0, 60) == 0 && none == 1000, "no resistance: nothing resisted");
}

/// Auto Shot: the first shot half a second after starting, then one each ranged attack time, until cancelled.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(35), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint shot = 97200;
    context.data.spells.spells[shot] = testSpell(shot, 2, ImplicitTarget.enemy, 10);
    with (*context.data.spells.spells.edit(shot))
    {
        attributesEx2 |= 0x20 | 0x20000000; // auto-repeat; no crit
        casting.school = 1;                  // holy: not resisted
        casting.dmgClass = 0;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto me = cast(Player) anduin.session.character;
    me.spells ~= shot;
    anduin.read();
    auto session = anduin.session.inWorld;
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    me.values.set!UNIT_FIELD_TARGET(keeper.guid);
    me.values.set!UNIT_FIELD_RANGEDATTACKTIME(2000u);

    session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 500, "not at once");
    session.updateAutoRepeat(100.msecs); // the wind-up starts
    session.updateAutoRepeat(600.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 490, "the first shot");
    session.updateAutoRepeat(1000.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 490, "not yet");
    session.updateAutoRepeat(1100.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 480, "the second, a weapon's time later");
    anduin.write(Opcode.CMSG_CANCEL_AUTO_REPEAT_SPELL, null);
    session.updateAutoRepeat(5000.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 480, "stopped");

    // An aura that procs on a ranged attack: each shot brings its bolt.
    import dmangos.world.auras : AuraType, makeAura;

    enum uint bolt = 97210, hawk = 97211;
    context.data.spells.spells[bolt] = testSpell(bolt, 2, ImplicitTarget.enemy, 5);
    context.data.spells.spells.edit(bolt).casting.school = 1;
    context.data.spells.spells.edit(bolt).casting.dmgClass = 0;
    context.data.spells.spells.edit(bolt).attributesEx2 |= 0x20000000;
    context.data.spells.spells[hawk] = testSpell(hawk, 6, ImplicitTarget.caster, 0);
    with (*context.data.spells.spells.edit(hawk))
    {
        casting.applyAuraName[0] = AuraType.procTriggerSpell;
        triggerSpell[0] = bolt;
        casting.procFlags = 0x40;
        casting.procChance = 100;
    }
    session.addAura(makeAura(hawk in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));
    session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
    session.updateAutoRepeat(100.msecs);
    session.updateAutoRepeat(2100.msecs); // the weapon's time, which a restart does not cut short
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 480 - 10 - 5, "the shot and its proc");
}

/// Each shot of a bow uses an arrow; out of arrows, the shooting stops ("no ammo").
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(35), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint shot = 97201;
    context.data.spells.spells[shot] = testSpell(shot, 2, ImplicitTarget.enemy, 1);
    with (*context.data.spells.spells.edit(shot))
    {
        attributes |= 0x2;                   // the ranged slot
        attributesEx2 |= 0x20 | 0x20000000; // auto-repeat; no crit
        casting.school = 1;
        casting.dmgClass = 0;
    }
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 1.97f), AccountLevel.player,
        raceOrc);
    auto me = cast(Player) rexxar.session.character;
    me.spells ~= shot;
    rexxar.read();
    import dmangos.world.defines : equipmentSlotRanged;

    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    rexxar.session.inWorld.lootStore(itemBow, 1, 0, false);
    rexxar.session.inWorld.lootStore(itemArrow, 20, 0, false);
    rexxar.read();
    ubyte slot;
    foreach (s; ubyte(23) .. ubyte(39))
        if (const item = me.inventory[inventorySlotBag0, s])
            if (item.entry == itemBow)
                slot = s;
    rexxar.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    rexxar.read();
    me.values.set!PLAYER_AMMO_ID(itemArrow); // the arrows as the ammunition
    assert(me.inventory.equipped(equipmentSlotRanged) !is null && me.inventory.count(itemArrow) > 1, "a bow, arrows");
    auto session = rexxar.session.inWorld;
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(5000u);
    keeper.values.set!UNIT_FIELD_HEALTH(5000u);
    me.values.set!UNIT_FIELD_TARGET(keeper.guid);
    me.values.set!UNIT_FIELD_RANGEDATTACKTIME(2000u);
    const arrows = me.inventory.count(itemArrow);
    session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
    session.updateAutoRepeat(100.msecs);
    session.updateAutoRepeat(600.msecs);
    assert(me.inventory.count(itemArrow) == arrows - 1, "an arrow a shot");

    me.inventory.destroyCount(itemArrow, arrows - 1);
    rexxar.read();
    session.updateAutoRepeat(2100.msecs);
    assert(opcodesOf(rexxar.read()).canFind(Opcode.SMSG_CAST_RESULT), "no ammo");
    const health = keeper.values.get!UNIT_FIELD_HEALTH;
    session.updateAutoRepeat(5000.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == health, "stopped");
}

/// A player's school locked out by an interrupt: its spells of the school are not ready (shown cooling down), others are.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint fire = 97401, frost = 97402;
    context.data.spells.spells[fire] = testSpell(fire, 6, ImplicitTarget.caster, 0);
    context.data.spells.spells.edit(fire).casting.school = 2;
    context.data.spells.spells[frost] = testSpell(frost, 6, ImplicitTarget.caster, 0);
    context.data.spells.spells.edit(frost).casting.school = 4;
    auto jaina = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f));
    jaina.read();
    auto session = jaina.session.inWorld;
    (cast(Player) session.character).spells ~= [fire, frost];
    const self = SpellTargets(TargetFlags.self, 0);

    // What the client hears of casting `spell` at itself: its failure's reason, or 0.
    ubyte castReason(uint spell)
    {
        import dmangos.bytes : ByteWriter;

        ByteWriter w;
        w.put(spell);
        self.write(w);
        jaina.write(Opcode.CMSG_CAST_SPELL, w.data);
        const r = bodyOf(jaina.read(), Opcode.SMSG_CAST_RESULT);
        return r.length >= 6 && r[4] == 2 ? r[5] : 0;
    }

    session.lockOutSchool(2, 4000);
    const shown = bodyOf(jaina.read(), Opcode.SMSG_SPELL_COOLDOWN);
    assert(shown.length == 8 + 8, "its fire spell, cooling down");
    assert(castReason(fire) == SpellCastResult.notReady, "fire locked out");
    assert(castReason(frost) != SpellCastResult.notReady, "frost not");
    now += 4001.msecs;
    assert(castReason(fire) != SpellCastResult.notReady, "the lockout over");
}

// Spell power counts against players too: +35 fire damage done on an instant 20-damage fire spell, 35 in all.
unittest
{
    import core.time : MonoTime;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8948.0f, -132.49f, 83.53f, 3.14159f));
    anduin.read();
    jaina.read();
    auto j = cast(Player) jaina.session.character;
    enum uint power = 95701, fire = 95702;
    with (context.data.spells)
    {
        spells[power] = testSpell(power, 6, ImplicitTarget.caster, 35);
        spells.edit(power).casting.applyAuraName[0] = AuraType.modDamageDone;
        spells.edit(power).miscValue[0] = 1 << 2; // fire
        spells[fire] = testSpell(fire, 2, ImplicitTarget.enemy, 20);
        spells.edit(fire).casting.school = 2;
        spells.edit(fire).casting.dmgClass = 0;
        spells.edit(fire).attributesEx2 |= 0x20000000; // no crit
    }
    auto aura = makeAura((power in context.data.spells.spells), anduin.session.character.guid, 1, -1, true, [35, 0, 0]);
    aura.passive = true;
    anduin.session.inWorld.addAura(aura);
    j.values.set!UNIT_FIELD_MAXHEALTH(500u);
    j.values.set!UNIT_FIELD_HEALTH(500u);
    anduin.session.inWorld.spellDamageToPlayer(fire in context.data.spells.spells, jaina.session.inWorld, 20);
    assert(j.values.get!UNIT_FIELD_HEALTH == 500 - 35, "20 and 15 of spell power");
}

// A weapon strike (Sinister Strike, Mortal Strike: effect 58) hurts a player as it hurts a creature.
unittest
{
    import core.time : MonoTime;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8948.0f, -132.49f, 83.53f, 3.14159f));
    anduin.read();
    jaina.read();
    auto a = cast(Player) anduin.session.character, j = cast(Player) jaina.session.character;
    enum uint strike = 95703;
    context.data.spells.spells[strike] = testSpell(strike, 58, ImplicitTarget.enemy, 10);
    a.values.set!UNIT_FIELD_MINDAMAGE(20.0f);
    a.values.set!UNIT_FIELD_MAXDAMAGE(20.0f);
    j.values.set!UNIT_FIELD_MAXHEALTH(500u);
    j.values.set!UNIT_FIELD_HEALTH(500u);
    auto victim = context.map(0).unit(j.guid);
    assert(victim, "she is a unit on his map");
    anduin.session.inWorld.weaponSpellDamage(strike in context.data.spells.spells, 0, victim, 10);
    assert(j.values.get!UNIT_FIELD_HEALTH < 500, "the strike landed on a player");
}
