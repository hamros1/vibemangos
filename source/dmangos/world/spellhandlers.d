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
    }

    Casting generic;                 // `CURRENT_GENERIC_SPELL`
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

    /// Moving interrupts a cast that moving interrupts (`SPELL_INTERRUPT_FLAG_MOVEMENT`).
    void spellsOnMovement(uint movementFlags)
    {
        enum uint moving = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
            | MovementFlags.strafeRight | MovementFlags.jumping | MovementFlags.fallingFar;
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
            ulong target;
            if (a == ImplicitTarget.caster || a == ImplicitTarget.none)
                target = player.guid;
            else if (a == ImplicitTarget.enemy || a == ImplicitTarget.unit || a == ImplicitTarget.friend)
                target = c.targets.unit ? c.targets.unit : player.guid;
            else if (a == ImplicitTarget.gameObject || a == ImplicitTarget.gameObjectItem)
            {
                if (!c.targets.gameObject)
                    continue; // an item's lock: not yet
                target = c.targets.gameObject;
            }
            else
                target = player.guid; // area and other targets: not yet; the caster stands in
            effectTargets[i] ~= target;
            if (target !in missOf)
            {
                missOf[target] = rollHit(*spell, target);
                results ~= TargetResult(target, missOf[target]);
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
        foreach (i; 0 .. 3)
            foreach (target; effectTargets[i])
                if (missOf[target] == SpellMissInfo.none)
                    doEffect(spell, i, target, c);
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
        case 3: // SPELL_EFFECT_DUMMY: scripts
        case 77: // SPELL_EFFECT_SCRIPT_EFFECT
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
