/**
 * Casting spells (CMaNGOS `SpellHandler.cpp`, `Spells/Spell.cpp`'s `SpellStart`, `Prepare`,
 * `update`, `cast`, `CheckCast`, `TakePower`, and `SpellEffects.cpp`'s effects), mixed into
 * `dmangos.world.session.WorldSession`.
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
    import core.time : Duration, msecs, MonoTime;
    import std.random : uniform, uniform01;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info, warning;
    import dmangos.world.combat : AttackType, armorReducedDamage, blockChance, critChance, dodgeChance, missChance,
        parryChance, weaponDamage;
    import dmangos.world.auras : AuraInterrupt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.creature : Creature;
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
    /// A spell being cast or waiting for the next swing (`Spell` in `m_currentSpells`).
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

    Casting generic;                 // `CURRENT_GENERIC_SPELL`
    const(SpellInfo)* channelSpell;  // `CURRENT_CHANNELED_SPELL`: the spell being channelled, if any
    ulong channelObject;             // an object the channel is at (a fishing bobber)
    ulong bobber;                    // this angler's fishing bobber, while it floats
    int bobberAge, bobberBite, bobberGone; // ms since cast; when the fish bites; when the bobber goes
    bool bobberLooted;               // the catch is being looted: the bobber stays until then
    bool channelFailed;              // an effect of the spell failed (not fishable): no channel
    PersistentArea[] persistentAreas; // this caster's spots of persistent area auras
    PendingHit[] pendingHits;         // missiles on their way: their effects when they arrive
    ulong channelTarget;             // ... at whom
    int channelTimer;                // ... for so many more milliseconds
    Casting nextSwing;               // `CURRENT_MELEE_SPELL`
    MonoTime[uint] spellReadyAt;     // `m_cooldownMap` by spell
    MonoTime[uint] categoryReadyAt;  // ... and by category
    MonoTime gcdReadyAt;             // `AddGCD`: category 133's global cooldown

    // -----------------------------------------------------------------------
    // The opcodes
    // -----------------------------------------------------------------------

    /// `HandleCastSpellOpcode`: a spell the player knows, at what it chose.
    @Handles(Opcode.CMSG_CAST_SPELL, WorldState.inWorld)
    void handleCastSpell(ref ByteReader reader)
    {
        const id = reader.read!uint;
        auto targets = SpellTargets.read(reader);
        const spell = context.data.spells.spell(id);
        // Not known or passive: a cheat, ignored (as CMaNGOS does).
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

    /// `HandleCancelCastOpcode`
    @Handles(Opcode.CMSG_CANCEL_CAST, WorldState.inWorld)
    void handleCancelCast(ref ByteReader reader)
    {
        const id = reader.read!uint;
        if (generic.active && generic.spell.id == id)
            interruptCast(SpellCastResult.interrupted);
        else if (nextSwing.active && nextSwing.spell.id == id)
            nextSwing.active = false;
    }

    /// `HandleUseItemOpcode`: an item's on-use spell (food, drink, a hearthstone).
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
     * `Spell::SpellStart` and `Prepare`: checked, shown, and either cast now (instant), kept for the
     * next swing, or counted down.
     */
    /// A spell a script casts for the player (`TRIGGERED_OLD_TRIGGERED`): at `target` (a unit), or itself.
    package void castTriggeredAt(uint spellId, ulong target)
    {
        const spell = context.data.spells.spell(spellId);
        if (spell is null || player is null)
            return;
        castSpell(spell, SpellTargets(TargetFlags.unit, target ? target : player.guid), true, 0);
    }

    package SpellCastResult castSpell(const(SpellInfo)* spell, SpellTargets targets, bool triggered, uint itemEntry)
    {
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
            c.timer = castTimeCheat ? 0 : castTime(*spell, context.client, player.data.level);
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

    /// The countdown of a cast in progress (`Spell::update`): it goes when its time is up.
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

    /// `Spell::cancel`: the cast in progress stops; the player and everyone around are told.
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
     * `Spell::SendChannelStart`: a channelled spell (`SPELL_ATTR_EX_IS_CHANNELED`, `_IS_SELF_CHANNELED`)
     * goes on for its duration: `MSG_CHANNEL_START`, and the caster's channel fields for everyone.
     */
    void startChannel(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.spellcast : duration;

        const ms = duration(*spell, context.client, player.data.level);
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
     * `Spell::SendChannelUpdate(0)`: the channel ends, at its time or cut short (`cancelled`: moving,
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
            else if (auto other = map.combatant(channelTarget))
                other.auraRemovedBy(spell.id);
            map.sendToWatchers(this, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(player.guid, spell.id, SpellCastResult.interrupted), true);
        }
        if (bobber && !bobberLooted)
            removeBobber();
        // `Spell::cancel` of a channel: its spots go with it.
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

    /// `HandleCancelChanneling`: the player stops channelling.
    @Handles(Opcode.CMSG_CANCEL_CHANNELLING, WorldState.inWorld)
    void handleCancelChanneling(ref ByteReader reader)
    {
        const id = reader.read!uint;
        if (channelSpell !is null && channelSpell.id == id)
            endChannel(true);
    }

    /**
     * `Spell::EffectTransmitted` for a fishing bobber: between the spell's least and greatest range in
     * front of the angler, a little to either side, on the water there (or the cast fails: not
     * fishable). The fish bites 3, 7, 13 or 17 seconds before the channel would end, and the bobber
     * waits 5 seconds more for the angler (`FISHING_BOBBER_READY_TIME`).
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
        const r = range(*spell, context.client);
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
        const ms = duration(*spell, context.client, player.data.level);
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
     * `Spell::EffectPersistentAA`: a dynamic object at the destination (or the caster) of the effect's
     * radius, lasting the spell's duration; every amplitude it hurts the creatures the caster may
     * attack within it (`SPELL_AURA_PERIODIC_DAMAGE`'s ticks).
     */
    void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)
    {
        import dmangos.world.dynobject : DynamicObject;
        import dmangos.world.spellcast : duration, radius;

        const r = radius(*spell, i, context.client), ms = duration(*spell, context.client, player.data.level);
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

    /// The spots' ticks and ends.
    void updatePersistentAreas(int diff)
    {
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
                foreach (creature; map.creaturesNear(at, r))
                {
                    const p = creature.position;
                    if ((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 > r * r || !spellEnemy(creature))
                        continue;
                    spellDamage(area.spell, creature, area.value, area.spell.casting.school);
                }
            }
            if (area.left <= 0)
            {
                map.removeObject(area.spot.guid);
                persistentAreas = persistentAreas[0 .. k] ~ persistentAreas[k + 1 .. $];
            }
        }
    }

    /// `Spell::m_delayMoment` for a missile: its flight to `target` at the spell's speed (yards a second); 0: at once.
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
     * `GameObject::Use` of the angler's own bobber: before the bite nothing is hooked; in the bite's
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
        // `Player::UpdateFishingSkill`
        const pure_ = player.skillValue(skillFishing)[0];
        updateSkillPro(skillFishing, (pure_ < 75 ? 100 : 2500 / (pure_ - 50)) * 10, 1);
        if (!success)
        {
            deliver(Opcode.SMSG_FISH_ESCAPED, null);
            return endChannel(false);
        }
        // `LookupFishingHoleAround`: a school of fish within 20 yards of the bobber gives the catch, from
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
        if (generic.active)
            interruptCast(SpellCastResult.interrupted);
        endChannel(true);
        foreach (ref area; persistentAreas)
            map.removeObject(area.spot.guid);
        persistentAreas = null;
        nextSwing.active = false;
    }

    /// `Unit::AttackerStateUpdate`'s melee spell: a spell waiting for the next main-hand swing is cast
    /// instead of it. False if there was none (or it cannot be cast now): the swing goes as usual.
    bool swingSpell(Creature victim)
    {
        if (!nextSwing.active)
            return false;
        auto c = nextSwing;
        nextSwing.active = false;
        if (c.targets.unit == 0 || c.targets.unit == player.guid)
            c.targets.unit = victim.guid;
        if (checkCast(c.spell, c.targets, true, 0, false) != SpellCastResult.ok)
            return false;
        go(c);
        return true;
    }

    /**
     * `Spell::CheckCast`: whether the cast may go, and if not, why. `start`: also what only matters
     * when it starts (cooldowns, a cast in progress, standing, moving).
     */
    /**
     * `Player::HasItemFitToSpellReqirements`: a worn item of the spell's class and subclass, not broken:
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
            if ((spell.attributes & spellAttrNotInCombat) && inCombat)
                return SpellCastResult.affectingCombat;
            if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0 && !(spell.attributes & castableWhileSitting))
                return SpellCastResult.notStanding;
            // `Spell::CheckItems`: the item the spell needs worn (a fishing pole, a ranged weapon to shoot).
            if (spell.equippedItemClass >= 0 && !hasItemFitToSpell(spell))
                return SpellCastResult.equippedItemClass;
            // `GetErrorAtShapeshiftedCast`: a spell for some stances (or forms) only in one of them.
            enum uint allowWhileNotShapeshifted = 0x00080000; // SPELL_ATTR_EX2_ALLOW_WHILE_NOT_SHAPESHIFTED
            enum SpellCastResult onlyShapeshift = cast(SpellCastResult) 0x56;
            const form = player.values.getByte!UNIT_FIELD_BYTES_1(2);
            if (form == 0 && spell.stances && !(spell.attributesEx2 & allowWhileNotShapeshifted))
                return onlyShapeshift;
            if (form != 0 && spell.stances && !(spell.stances & (1u << (form - 1))))
                return onlyShapeshift;
        }
        // The target the effects need (a triggered spell's at any range: `CheckRange` is not for it).
        const result = checkTarget(spell, targets, triggered);
        if (result != SpellCastResult.ok)
            return result;
        // A game object: near, free, its lock opened (`CanOpenLock`).
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
        }
        return SpellCastResult.ok;
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
        return powerCost(spell, level, createMana, createHealth, maxPower);
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
        const guid = targets.unit ? targets.unit : player.guid;
        if (guid == player.guid)
            return needsEnemy ? SpellCastResult.badTargets : SpellCastResult.ok;
        auto creature = cast(Creature) map.findObject(guid);
        Position at;
        float reach;
        if (creature !is null)
        {
            if (!creature.alive)
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
            if (other.player.deathState != DeathState.alive)
                return SpellCastResult.targetsDead;
            at = other.player.position;
            reach = other.player.values.get!UNIT_FIELD_COMBATREACH;
        }
        else
            return SpellCastResult.badTargets;
        if (triggered)
            return SpellCastResult.ok;
        // `CheckRange`: within the spell's range, reaches included; `IsWithinLOSInMap`.
        const r = range(*spell, context.client);
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
     * `Spell::cast`: checked again, its cooldowns started, its cost taken, the hits rolled, everyone
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
            // `AddCooldown`: the item's cooldowns, else the spell's.
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
            if (recovery > 0 && !cooldownCheat)
                spellReadyAt[spell.id] = now + recovery.msecs;
            if (category && categoryRecovery > 0 && !cooldownCheat)
                categoryReadyAt[category] = now + categoryRecovery.msecs;
            // `TakePower`, `TakeReagents`, and an item used up (`spellcharges` -1: one use).
            if (c.castItemEntry == 0)
            {
                const cost = costOf(*spell);
                if (cost > 0)
                    player.modifyPower(cast(Power) spell.casting.powerType, -cost);
                foreach (i, reagent; spell.reagents)
                    if (reagent > 0 && spell.casting.reagentCount[i])
                        player.inventory.destroyCount(reagent, spell.casting.reagentCount[i]);
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
                targets = area.dup; // `SetTargetMap` for an area, a cone, the party
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
            interruptAuras(AuraInterrupt.action); // `RemoveAurasOnCast`
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
        // A missile (`speed`) reaches each target after its flight (`m_delayMoment`): the effects then.
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
     * `Unit::SpellHitResult` against a creature: a magic spell misses (resisted) by
     * `CalculateSpellMissChance`; a melee one by the attack table (miss, dodge, parry, block).
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
                return SpellMissInfo.none; // `SpellHitResult`: no damage class, no roll
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
            return roll < spellMissChance(player.data.level, other.player.data.level, true) ? SpellMissInfo.resist
                : SpellMissInfo.none;
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
        return roll < spellMissChance(player.data.level, level, false) ? SpellMissInfo.resist : SpellMissInfo.none;
    }

    // -----------------------------------------------------------------------
    // Effects (`SpellEffects.cpp`)
    // -----------------------------------------------------------------------

    void doEffect(const(SpellInfo)* spell, size_t i, ulong target, ref Casting c)
    {
        const value = effectValue(*spell, i, player.data.level, uniform01(map.random));
        switch (spell.effect[i])
        {
        case 2: // SPELL_EFFECT_SCHOOL_DAMAGE
            if (auto creature = cast(Creature) map.findObject(target))
                spellDamage(spell, creature, value > 0 ? value : 0, spell.casting.school);
            else if (auto other = enemyPlayer(target))
                spellDamageToPlayer(spell, other, value > 0 ? value : 0);
            break;
        case 3, 77: // SPELL_EFFECT_DUMMY, SPELL_EFFECT_SCRIPT_EFFECT: the spell's database script, if it has one
        {
            import dmangos.world.dbscripts : DbScriptType;

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
            const ms = duration(*spell, context.client, player.data.level);
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
        case 1: // SPELL_EFFECT_INSTAKILL
            instakill(spell, target);
            break;
        case 33: // SPELL_EFFECT_OPEN_LOCK
            openLock(spell, i, target, c.castItemEntry);
            break;
        case 68: // SPELL_EFFECT_INTERRUPT_CAST: the target's cast ends (its school's lockout: not yet)
            if (auto creature = cast(Creature) map.findObject(target))
                creature.ai.interruptCast();
            else if (auto other = enemyPlayer(target))
                other.interruptCast(SpellCastResult.interrupted);
            break;
        case 17: // SPELL_EFFECT_WEAPON_DAMAGE_NOSCHOOL
        case 58: // SPELL_EFFECT_WEAPON_DAMAGE
        case 121: // SPELL_EFFECT_NORMALIZED_WEAPON_DMG
        case 31: // SPELL_EFFECT_WEAPON_PERCENT_DAMAGE
            if (auto creature = cast(Creature) map.findObject(target))
                weaponSpellDamage(spell, i, creature, value);
            break;
        case 10: // SPELL_EFFECT_HEAL
            heal(spell, target, value);
            break;
        case 30: // SPELL_EFFECT_ENERGIZE
            energize(spell, i, target, value);
            break;
        case 5: // SPELL_EFFECT_TELEPORT_UNITS
            teleportUnits(spell, i, c);
            break;
        case SpellEffect.createItem:
            if (spell.itemType[i])
                giveItem(spell.itemType[i], value > 0 ? value : 1);
            break;
        case SpellEffect.learnSpell:
            if (spell.triggerSpell[i])
                learn(spell.triggerSpell[i]);
            break;
        case 64: // SPELL_EFFECT_TRIGGER_SPELL
            if (const triggered = context.data.spells.spell(spell.triggerSpell[i]))
                castSpell(triggered, c.targets, true, 0);
            break;
        case 6: // SPELL_EFFECT_APPLY_AURA
            applyAuraEffect(spell, i, target);
            break;
        case 78: // SPELL_EFFECT_ATTACK
            break;
        default:
            info!"%s: spell %s effect %s (%s) is not done yet"(remoteAddress, spell.id, i, spell.effect[i]);
            break;
        }
    }

    /// `Spell::EffectInstaKill`: `SMSG_SPELLINSTAKILLLOG` around, and damage of all the target's health.
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
        other.takeDamageFrom(player.guid, other.player.values.get!UNIT_FIELD_HEALTH);
    }

    /// `Player::ClearCooldownForSpell`: `SMSG_CLEAR_COOLDOWN`, and the spell ready again.
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

    /// `Player::ClearCooldownsOnLine`: the cooldowns of the spells known of a skill line, but `calledFrom`.
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

    /// The crit chance of this player's spells: `GetSpellCritFromIntellect`.
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

    /// Whether this player may hurt the creature with an area or chained spell (`CanAttackSpell`: alive,
    /// attackable, neutral ones too).
    bool spellEnemy(Creature creature)
    {
        return creature.alive && creature.ai !is null && canAttack(relatingNow(), relatingOf(creature), context.client);
    }

    /**
     * `Spell::SetTargetMap` for the area targets: the enemies (creatures, and players it may fight)
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
        const r = radius(*spell, i, context.client);
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

    /// Chain targets (`EffectChainTarget`): from `first`, the nearest enemy within 10 yards of the last, `count` times.
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

    /// A school's damage to a player (`DealSpellDamage`): a crit is half again; armor for physical.
    void spellDamageToPlayer(const(SpellInfo)* spell, typeof(this) other, uint damage)
    {
        const crit = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(map.random) * 100 < spellCrit();
        if (crit)
            damage = damage * 3 / 2;
        if (spell.casting.school == 0)
            damage = cast(uint) armorReducedDamage(player.data.level, other.player.fighter.armor, damage);
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(other.player.guid, player.guid,
            spell.id, damage, spell.casting.school, 0, 0, false, 0, crit), true);
        enterCombatFor(combatLinger);
        other.takeDamageFrom(player.guid, damage);
    }

    /// `Unit::CalculateSpellDamage` and `DealSpellDamage` for a school's damage: a crit is half again; armor for physical.
    void spellDamage(const(SpellInfo)* spell, Creature victim, uint damage, uint school)
    {
        const crit = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(map.random) * 100 < spellCrit();
        if (crit)
            damage = damage * 3 / 2;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(player.data.level, victim.fighter.armor, damage);
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.guid, player.guid,
            spell.id, damage, school, 0, 0, false, 0, crit), true);
        spellAttacked(victim, damage);
    }

    /**
     * `Spell::EffectWeaponDmg`: the weapon's damage, plus the effect's bonus (or times its percentage),
     * less armor; a crit is double (the melee crit chance); a block takes off what the shield stops.
     */
    void weaponSpellDamage(const(SpellInfo)* spell, size_t i, Creature victim, int value)
    {
        // Only the first weapon damage effect deals the damage; the others add to it (`EffectWeaponDmg`).
        foreach (j; 0 .. i)
            if (spell.effect[j] == 17 || spell.effect[j] == 58 || spell.effect[j] == 121 || spell.effect[j] == 31)
                return;
        const me = player.fighter, it = victim.fighter;
        const type = spell.casting.dmgClass == DamageClass.ranged ? AttackType.ranged : AttackType.mainHand;
        float damage = weaponDamage(me, type, map.random);
        float percent = 100;
        foreach (j; i .. 3)
        {
            const v = effectValue(*spell, j, player.data.level, uniform01(map.random));
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
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.guid, player.guid,
            spell.id, total, 0, 0, 0, false, blocked, crit), true);
        enterCombatFor(combatLinger);
        spellAttacked(victim, total);
    }

    /// A creature hit (or missed) by this player's spell: it fights back, takes the damage, and may die.
    void spellAttacked(Creature victim, uint damage)
    {
        if (!victim.alive)
            return;
        enterCombatFor(combatLinger);
        victim.ai.attackedBy(this, map);
        victim.ai.damageTaken(this, damage);
        map.wake(victim.guid);
        if (damage == 0)
            return;
        tap(victim);
        const killed = victim.takeDamage(damage);
        map.flushObjectChanges(victim);
        if (killed)
            creatureKilled(victim);
    }

    /// `Spell::EffectHeal`: health back, a crit half again (`DealHeal`, `SendHealSpellLog`).
    void heal(const(SpellInfo)* spell, ulong target, int value)
    {
        if (value <= 0)
            return;
        auto who = target == player.guid ? this : cast(typeof(this)) context.onlinePlayer(target);
        if (who is null || who.player is null || who.map !is map)
            return;
        const crit = uniform01(map.random) * 100 < spellCrit();
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

    /// `Spell::EffectEnergize`: power of the effect's kind (`EffectMiscValue`).
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

    /// `Spell::EffectTeleportUnits`: to the home bind (the hearthstone), or where the client chose.
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
        spells[bolt].casting.interruptFlags = 0x01;
        spells[mend] = testSpell(mend, 10, 1, 20);              // heals oneself 20
        spells[strike] = testSpell(strike, 17, 6, 11);          // next swing: weapon + 11
        spells[strike].attributes = 0x4;
        spells[strike].casting.dmgClass = 2;
        spells[home] = testSpell(home, 5, 1, 0);                // home
        spells[home].casting.implicitTargetB[0] = 9;
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
    auto stone = &context.data.items[itemHearthstone];
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
    with (context.data.spells.spells[drain])
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
    with (context.data.spells.spells[fishing])
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
    context.data.spells.spells[fishing].equippedItemClass = 2;           // a weapon
    context.data.spells.spells[fishing].equippedItemSubClassMask = 1 << 20; // a fishing pole
    cast_();
    assert(bobberNow() is null && opcodesOf(anduin.read()).canFind(Opcode.SMSG_CAST_RESULT), "no pole");
    context.data.spells.spells[fishing].equippedItemClass = -1;

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
    with (context.data.spells.spells[blast].casting)
    {
        implicitTargetB[0] = ImplicitTarget.enemiesAroundSource;
        radiusIndex[0] = 1;
        dmgClass = 0;
    }
    context.data.spells.spells[bolt] = testSpell(bolt, 2, ImplicitTarget.enemy, 20);
    with (context.data.spells.spells[bolt].casting)
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
    anduin.session.castTriggeredAt(bolt, keeper.guid); // past the global cooldown
    assert(keeper.values.get!UNIT_FIELD_HEALTH < keeperBefore && trainer.values.get!UNIT_FIELD_HEALTH < trainerBefore,
        "the bolt jumped to the trainer");

    // A missile at 10 yards a second: nothing on release, its damage when it arrives (about 2.7 yards off).
    import core.time : msecs;

    enum uint missile = 95602;
    context.data.spells.spells[missile] = testSpell(missile, 2, ImplicitTarget.enemy, 20);
    context.data.spells.spells[missile].casting.speed = 10;
    context.data.spells.spells[missile].casting.dmgClass = 0;
    const flying = keeper.values.get!UNIT_FIELD_HEALTH;
    anduin.session.castTriggeredAt(missile, keeper.guid);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == flying, "still in flight");
    anduin.session.update(400.msecs);
    assert(keeper.values.get!UNIT_FIELD_HEALTH < flying, "arrived");
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
    with (context.data.spells.spells[consecrate].casting)
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
}
