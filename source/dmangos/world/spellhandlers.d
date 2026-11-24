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
 * The effects done here: school damage, weapon damage (with bonus and percentage), heals,
 * energize, teleports (home bind), creating items, learning spells, triggering spells and the rest
 * of the effect switch; auras are `dmangos.world.aurahandlers`'s, threat, taunts, charges, leaps,
 * drains, traps and the like `dmangos.world.effecthandlers`'. Those no player's cast does yet are
 * logged once each.
 */
module dmangos.world.spellhandlers;

import dmangos.world.spellids;

/// See the module documentation.
mixin template SpellHandlers()
{
    import dmangos.world.spellids;
    import dmangos.world.spellmods : applySpellMod, effectOp, SpellModOp;
    import std.algorithm.comparison : max;
    import core.time : Duration, msecs, MonoTime;
    import std.random : uniform, uniform01;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.protocol : AreaDamage, PartyHeal;
    import dmangos.log : info, warning;
    import dmangos.world.combat : AttackType, armorAgainst, armorReducedDamage, creatureTypeHumanoid, blockChance, critChance, dodgeChance, missChance,
        parryChance, weaponDamage;
    import dmangos.world.auras : Aura, AuraInterrupt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.inventory : Item;
    import dmangos.world.creature : Creature;
    import dmangos.world.unit : UnitKind, UnitRef;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.group : Group;
    import dmangos.world.loot : LootItem;
    import dmangos.world.defines : maxPowers, Power, Stat;
    import dmangos.world.movement : MovementFlags, Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : DeathState;
    import dmangos.world.relations : canAttack, isEnemy, isFriend;
    import dmangos.world.replication : Replica;
    import dmangos.world.spellcast;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.updatefields;

private:
    /// A spell being cast or waiting for the next swing (`dmangos.world.spelleffects`).
    alias Casting = imported!"dmangos.world.spelleffects".SpellCast;

    /// A missile's effect on its target, due when it arrives.
    static struct PendingHit
    {
        const(SpellInfo)* spell;
        size_t effect;
        ulong target;
        Casting casting;
        int left;      // ms of flight left
        uint bounce;
    }

    /// A persistent area aura's spot under way (`dmangos.world.spellareas`).
    alias PersistentArea = imported!"dmangos.world.spellareas".PersistentArea;

    Casting generic;                 // the spell being cast (with a cast time), if any

    private static struct CastHandoff
    {
        uint spell, mapId, instance;
        SpellTargets targets;
        int remaining, total;
        uint itemEntry;
        ulong itemGuid;
        int[3] values;
        ubyte which;
        bool alwaysHits, triggered, playerHandoff;
        uint triggeredBy, pushbacks;
    }

    private static struct AuraIdentity
    {
        uint spell;
        ulong caster;
    }

    private static struct MissileHandoff
    {
        static struct AuraMask
        {
            ulong target;
            ubyte mask;
        }

        CastHandoff cast_;
        uint deadline, bounce;
        ulong target;
        ubyte effect, persistentDone;
        Position gameObjectOrigin;
        AuraMask[] auraEffects;
    }

    private static struct FlightHandoff
    {
        static struct Spend
        {
            uint spell;
            bool triggered;
            AuraIdentity[] auras;
        }

        static struct Used
        {
            uint forSpell;
            AuraIdentity aura;
        }

        uint mapId, instance;
        MissileHandoff[] hits;
        Spend[] spends;
        Used[] used;
    }

    const(SpellInfo)* channelSpell;  // the spell being channelled, if any
    ulong channelObject;             // an object the channel is at (a fishing bobber)
    ulong bobber;                    // this angler's fishing bobber, while it floats
    int bobberAge, bobberBite, bobberGone; // ms since cast; when the fish bites; when the bobber goes
    bool bobberLooted;               // the catch is being looted: the bobber stays until then
    bool channelFailed;              // an effect of the spell failed (not fishable): no channel
    PersistentArea[] persistentAreas; // this caster's spots of persistent area auras
    PendingHit[] pendingHits;         // missiles on their way: their effects when they arrive
    MissileSpend[] missileSpends;     // casts whose charged modifiers wait for their missiles to land

    /// Whether a charged modifier changes a spell's effects where they land (its crit, its damage), not its cast.
    static bool changesImpact(const Aura aura)
    {
        import dmangos.world.spellmods : SpellModOp;

        foreach (i; 0 .. 3)
        {
            const type = aura.spell.casting.applyAuraName[i];
            if (type != AuraType.addFlatModifier && type != AuraType.addPctModifier)
                continue;
            switch (aura.misc(i))
            {
            case SpellModOp.damage, SpellModOp.critChance, SpellModOp.critDamageBonus, SpellModOp.allEffects,
                    SpellModOp.effect1, SpellModOp.effect2, SpellModOp.effect3, SpellModOp.dot:
                return true;
            default:
                break;
            }
        }
        return false;
    }

    static struct MissileSpend
    {
        const(SpellInfo)* spell;
        Aura[] hadAtStart;
        bool triggered;
    }
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
        if (npcCharmer)
            return;
        const id = reader.read!uint;
        auto targets = SpellTargets.read(reader);
        const spell = context.data.spells.spell(id);
        // Not known or passive: a cheat, ignored.
        if (spell is null || !player.knowsSpell(id) || spell.isPassive)
            return;
        if (hasPendingPlayerSpell())
            return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(id, SpellCastResult.spellInProgress, spell));
        if (isMindVision(id) && findMindVisionTarget(id, targets))
            return;
        if (spell.hasEffect(SpellEffect.duel))
        {
            if (auto replica = cast(Replica) map.findObject(targets.unit))
                if (replica.fields.type == TypeId.player && context.onlinePlayer(targets.unit) is null)
                {
                    const result = duel is null && !inCombat && !flying
                        ? checkCast(spell, targets, false, 0, true, replica) : SpellCastResult.badTargets;
                    if (result == SpellCastResult.ok
                        && actAtReplica(targets.unit, ArrivalAction(0, id, targets.unit)))
                        return;
                    deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(id,
                        result == SpellCastResult.ok ? SpellCastResult.badTargets : result, spell));
                    return;
                }
            castSpell(spell, targets, false, 0);
            return;
        }
        // The client may name its current selection even though an area cast is centered on the caster.
        if (targets.unit && targets.unit != player.guid && !isCasterCenteredClusterSpell(*spell))
            if (auto replica = cast(Replica) map.findObject(targets.unit))
            {
                if (replica.fields.type == TypeId.player && context.onlinePlayer(targets.unit) is null
                    && isPlayerHandoffSpell(*spell))
                    return handoffPlayerSpell(spell, targets, replica);
                if (remoteLeechTarget(spell, targets.unit) !is null)
                {
                    castSpell(spell, targets, false, 0);
                    return;
                }
                if (actAtReplica(targets.unit, ArrivalAction(0, id, targets.unit)))
                    return;
            }
        // At another node's game object (a lock): opened there.
        if (targets.gameObject && actAtReplica(targets.gameObject, ArrivalAction(0, id, 0, 0, 0, targets.gameObject)))
            return;
        if (const named = namedScriptHandoffTarget(spell, targets))
            if (actAtReplica(named, ArrivalAction(spell: id, namedCreature: named, castTargets: targets)))
                return;
        castSpell(spell, targets, false, 0);
    }

    import dmangos.cluster.protocol : MindVisionTarget;

    private static struct PendingMindVision
    {
        uint spell;
        ushort node;
        MindVisionTarget request;
        MonoTime deadline;
    }

    private PendingMindVision mindVisionAsked;

    private static bool isMindVision(uint spell)
    {
        return spell == 2096 || spell == 10909;
    }

    private bool findMindVisionTarget(uint spell, const ref SpellTargets targets)
    {
        import dmangos.world.objects : HighGuid, highGuidOf;

        if (!targets.unit || highGuidOf(targets.unit) != HighGuid.player || context.sendMindVisionTarget is null
            || context.playerRelay is null || context.onlinePlayer(targets.unit) !is null
            || map.findObject(targets.unit) !is null || !context.canWrite())
            return false;
        const remote = context.remotePlayer(targets.unit);
        if (remote is null || !remote.node)
            return false;
        auto request = MindVisionTarget(player.guid, targets.unit, context.nextGameplaySequence(), map.id, map.instanceId);
        const node = remote.node;
        mindVisionAsked = PendingMindVision(spell, node, request, context.clock() + 2.seconds);
        if (context.sendMindVisionTarget(node, request))
            return true;
        mindVisionAsked = PendingMindVision.init;
        return false;
    }

    package void mindVisionTargetFound(ushort peer, const ref MindVisionTarget message)
    {
        const asked = mindVisionAsked;
        if (!asked.spell || peer != asked.node || message.sequence != asked.request.sequence
            || message.target != asked.request.target || message.map != asked.request.map
            || message.instance != asked.request.instance || player is null || message.caster != player.guid)
            return;
        mindVisionAsked = PendingMindVision.init;
        const spell = context.spellInfo(asked.spell);
        auto result = SpellCastResult.badTargets;
        if (spell !is null && player.knowsSpell(asked.spell) && message.state.length
            && context.clock() < asked.deadline && map.id == message.map && map.instanceId == message.instance)
        {
            auto target = new Replica(message.target, peer, message.state);
            if (target.fields.type == TypeId.player && target.position.isFinite)
            {
                const targets = SpellTargets(TargetFlags.unit, message.target);
                result = checkCast(spell, targets, false, 0, true, target);
                if (result == SpellCastResult.ok)
                {
                    if (actAtOwner(peer, message.target, ArrivalAction(spell: asked.spell, spellTarget: message.target)))
                        return;
                    result = SpellCastResult.badTargets;
                }
            }
        }
        deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(asked.spell, result, spell));
    }

    /// A supported area attack or party heal whose effects are all centered on the caster.
    private static bool isCasterCenteredClusterSpell(const ref SpellInfo spell)
    {
        import std.algorithm.comparison : among;
        import dmangos.world.spelldamage : isHostileAreaEffect, isPartyHealEffect;

        bool area;
        foreach (i, effect; spell.effect)
        {
            if (!effect)
                continue;
            with (ImplicitTarget)
            {
                const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
                const casterTarget = a.among(none, caster, casterSource) != 0;
                if ((casterTarget || a == enemiesAroundSource) && isHostileAreaEffect(spell, i))
                    area = true;
                else if ((casterTarget || a.among(partyInRange, partyAroundSource, party)) && isPartyHealEffect(spell, i))
                    area = true;
                else if (!(a == caster && b == none))
                    return false;
            }
        }
        return area;
    }

    /// A direct heal, buff, damage spell or debuff whose effects all target one named unit.
    static bool isPlayerHandoffSpell(const ref SpellInfo spell)
    {
        import std.algorithm.comparison : among;

        enum uint channels = 0x04 | 0x40;
        if ((spell.attributesEx & channels) || isNextMeleeSwingSpell(spell) || autoRepeats(&spell))
            return false;
        bool friendly, hostile;
        foreach (i, effect; spell.effect)
        {
            if (!effect)
                continue;
            if (spell.casting.implicitTargetB[i] != ImplicitTarget.none || spell.casting.chainTarget[i] > 1)
                return false;
            const target = spell.implicitTargetA[i];
            if (target == ImplicitTarget.enemy)
            {
                if (!effect.among(SpellEffect.schoolDamage, SpellEffect.applyAura, SpellEffect.healthLeech,
                    SpellEffect.weaponDamageNoschool, SpellEffect.weaponPercentDamage, SpellEffect.weaponDamage,
                    SpellEffect.powerDrain, SpellEffect.powerBurn, SpellEffect.interruptCast))
                    return false;
                hostile = true;
                continue;
            }
            const friendlyTarget = target == ImplicitTarget.friend || target == ImplicitTarget.unitRaid
                || target == ImplicitTarget.unitFriendChainHeal;
            if (effect == SpellEffect.heal || effect == SpellEffect.healMaxHealth)
            {
                if (!friendlyTarget && target != ImplicitTarget.unit)
                    return false;
            }
            else if (effect != SpellEffect.applyAura || !friendlyTarget)
                return false;
            friendly = true;
        }
        return friendly != hostile;
    }

    private void handoffPlayerSpell(const(SpellInfo)* spell, const ref SpellTargets targets, const(Replica) replica)
    {
        import std.algorithm.comparison : among;

        SpellCastResult result;
        if (!targets.mask.among(TargetFlags.unit, TargetFlags.unitEnemy, TargetFlags.unit | TargetFlags.unitAlly,
            TargetFlags.unit | TargetFlags.unitEnemy))
            result = SpellCastResult.badTargets;
        else if (inCombat)
            result = SpellCastResult.affectingCombat;
        else if (flying)
            result = SpellCastResult.notOnTaxi;
        else if (channelSpell !is null || nextSwing.active || autoRepeat !is null || pendingHits.length
            || persistentAreas.length)
            result = SpellCastResult.spellInProgress;
        else
        {
            result = checkCast(spell, targets, false, 0, true, replica, true);
            if (result == SpellCastResult.ok)
            {
                if (actAtReplica(targets.unit, ArrivalAction(0, spell.id, targets.unit)))
                    return;
                result = SpellCastResult.tryAgain;
            }
        }
        deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
    }

    /// The client cancels the cast in progress.
    @Handles(Opcode.CMSG_CANCEL_CAST, WorldState.inWorld)
    void handleCancelCast(ref ByteReader reader)
    {
        if (npcCharmer)
            return;
        const id = reader.read!uint;
        if (mindVisionAsked.spell == id && id)
        {
            mindVisionAsked = PendingMindVision.init;
            return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(id, SpellCastResult.interrupted));
        }
        if (cancelPendingPlayerSpell(id))
            return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(id, SpellCastResult.interrupted));
        if (generic.active && generic.spell.id == id)
            interruptCast(SpellCastResult.interrupted);
        else if (nextSwing.active && nextSwing.spell.id == id)
            nextSwing.active = false;
    }

    /// The client uses an item: its on-use spell (food, drink, a hearthstone).
    @Handles(Opcode.CMSG_USE_ITEM, WorldState.inWorld)
    void handleUseItem(ref ByteReader reader)
    {
        if (npcCharmer)
            return;
        const bag = reader.read!ubyte, slot = reader.read!ubyte;
        reader.read!ubyte; // spell count
        auto targets = SpellTargets.read(reader);
        useInventoryItem(player.inventory[bag, slot], targets, true);
    }

    private enum uint dominionOfSoul = 16053; // Orb of Draconic Energy

    private void useInventoryItem(Item item, const ref SpellTargets targets, bool handoff, ulong namedCreature = 0)
    {
        if (npcCharmer)
            return;
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        const proto = item.proto;
        if (proto.requiredLevel > player.data.level)
            return sendEquipError(InventoryResult.cantEquipLevel, item);
        if (const error = useItemError(item))
            return sendEquipError(error);
        enum uint triggerOnUse = 0;
        const(SpellInfo)* spell;
        foreach (ref use; proto.details.spells)
            if (use.id && use.trigger == triggerOnUse)
                if ((spell = context.data.spells.spell(use.id)) !is null)
                    break;

        if (spell !is null && handoff && hasChargesLeft(item))
        {
            if (const named = namedScriptHandoffTarget(spell, targets))
                if (actAtReplica(named, ArrivalAction(useItem: item.fullGuid, namedCreature: named, castTargets: targets)))
                    return;
            const target = spell.id == dominionOfSoul ? 0 : explicitItemTarget(*spell, targets);
            if (auto replica = cast(Replica) map.findObject(target))
                if (replica.fieldsOf.type != TypeId.player || (!inCombat && !flying && isPlayerHandoffSpell(*spell)
                    && checkCast(spell, targets, false, proto.entry, true, replica, true) == SpellCastResult.ok))
                    if (actAtReplica(target, ArrivalAction(useItem: item.fullGuid, castTargets: targets)))
                        return;
        }
        if (namedCreature && (spell is null || !resumeNamedScriptCast(spell, namedCreature)))
            return;
        bindOnUse(item);
        if (spell is null)
            return;
        auto actual = cast(SpellTargets) targets;
        if (spell.id == dominionOfSoul)
        {
            // Dominion's possession and haste affect the same named dragon, even if the client sent no unit.
            auto dragon = singleNamedScriptTarget(spell, false);
            if (!dragon)
                return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.badTargets, spell));
            actual = SpellTargets(TargetFlags.unit, dragon.combatGuid);
        }
        // Resolve the item's script once, where its target is authoritative.
        if (itemScript(proto.entry, actual.unit ? actual.unit : actual.gameObject))
            return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.dontReport, spell));
        if (!hasChargesLeft(item))
            return deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.noChargesRemain, spell));
        usingItemGuid = item.fullGuid; // its charges are taken when the cast goes
        scope (exit) usingItemGuid = 0;
        castSpell(spell, actual, false, proto.entry);
    }

    private static ulong explicitItemTarget(const ref SpellInfo spell, const ref SpellTargets targets)
    {
        import std.algorithm.comparison : among;

        if (targets.mask & (TargetFlags.sourceLocation | TargetFlags.destLocation))
            return 0;
        foreach (i, effect; spell.effect)
            if (effect != SpellEffect.none)
            {
                const shape = spell.implicitTargetA[i];
                if (targets.unit && shape.among(ImplicitTarget.unit, ImplicitTarget.enemy, ImplicitTarget.friend,
                    ImplicitTarget.unitRaid, ImplicitTarget.unitFriendChainHeal))
                    return targets.unit;
                if (targets.gameObject && shape.among(ImplicitTarget.gameObject, ImplicitTarget.gameObjectItem))
                    return targets.gameObject;
            }
        return 0;
    }

    /// Scripts that need the caster and one nearby creature can start with both on the target's node.
    private ulong namedScriptHandoffTarget(const(SpellInfo)* spell, const ref SpellTargets targets)
    {
        if (context.playerRelay is null || (targets.mask != TargetFlags.self && spell.id != dominionOfSoul)
            || generic.active || channelSpell !is null)
            return 0;
        if (context.sendAreaDamage !is null && (context.namedCreatureRouting(spell) != size_t.max
                || context.namedCreatureChannel(spell) != size_t.max))
            return 0;
        auto chosen = singleNamedScriptTarget(spell, true);
        return chosen.replica !is null && map.inLineOfSight(player.position, chosen.position) ? chosen.combatGuid : 0;
    }

    private bool resumeNamedScriptCast(const(SpellInfo)* spell, ulong target)
    {
        auto chosen = singleNamedScriptTarget(spell, false);
        if (chosen && chosen.combatGuid == target && map.inLineOfSight(player.position, chosen.position))
            return true;
        deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.badTargets, spell));
        return false;
    }

    private UnitRef singleNamedScriptTarget(const(SpellInfo)* spell, bool acrossNodes)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.spelldamage : databaseSpellEffect;
        import std.algorithm.searching : any;

        const(uint)[] entries;
        foreach (i, effect; spell.effect)
        {
            if (effect == SpellEffect.none)
                continue;
            if (spell.casting.implicitTargetB[i] != ImplicitTarget.none)
                return UnitRef.init;
            const shape = spell.implicitTargetA[i];
            if (shape == ImplicitTarget.caster || (shape == ImplicitTarget.locationCasterDest
                && effect == SpellEffect.summonObjectWild)
                || (spell.id == dominionOfSoul && shape == ImplicitTarget.enemy && effect == SpellEffect.applyAura))
                continue;
            if (shape != ImplicitTarget.unitScriptNearCaster || spell.casting.chainTarget[i] > 1)
                return UnitRef.init;
            const allowed = context.spellScriptTargets(spell.id, i);
            if (!allowed.length && databaseSpellEffect(effect)
                && context.data.dbScripts.steps(DbScriptType.spell, spell.id).length
                && context.data.spellScriptObjects.get(spell.id, null)
                    .any!(object => !(object.inverseEffectMask & (1u << i))))
                continue; // The eligible creature's database script resolves its associated objects.
            if (!allowed.length || (entries.length && entries != allowed))
                return UnitRef.init;
            entries = allowed;
        }
        return entries.length ? scriptTargetNear(spell, entries, acrossNodes) : UnitRef.init;
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
    private enum AutoRepeatPhase { cycling, starting, moving, retrying }
    private AutoRepeatPhase autoRepeatPhase;

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
        else if (spell.attributes & 0x2) // a thrown weapon that does not stack wears instead (`Spell::TakeAmmo`)
        {
            import dmangos.world.defines : equipmentSlotRanged, InventoryType;

            const weapon = player.inventory.equipped(equipmentSlotRanged);
            if (weapon !is null && weapon.proto.inventoryType == InventoryType.thrown && weapon.proto.stackable <= 1)
                loseDurability(equipmentSlotRanged, 1);
        }
    }

    /// Whether `spell` is off its cooldown: its own, and its category's (Ice Block's, the Hearthstone's).
    package bool spellIsReady(uint spell)
    {
        const now = context.clock();
        if (auto at = spell in spellReadyAt)
            if (now < *at)
                return false;
        if (const info = context.data.spells.spell(spell))
            if (info.category)
                if (auto at = info.category in categoryReadyAt)
                    if (now < *at)
                        return false;
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

    /// The cooldowns of `spell`, not cast from an item, start now: its own and its category's (Reincarnation has
    /// only its category's hour), with the talents' (Improved Reincarnation).
    package void startCooldown(const(SpellInfo)* spell)
    {
        if (startCooldown(spell, 0, context.clock()))
            checkpointCooldowns();
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
        if (autoRepeat !is spell || autoRepeatPhase == AutoRepeatPhase.cycling)
            autoRepeatPhase = AutoRepeatPhase.starting;
        autoRepeat = spell;
        return SpellCastResult.ok;
    }

    /// The server stops the shooting: the client is told (`SMSG_CANCEL_AUTO_REPEAT`), or its button stays lit.
    package void stopAutoRepeat()
    {
        if (autoRepeat is null)
            return;
        autoRepeat = null;
        deliver(Opcode.SMSG_CANCEL_AUTO_REPEAT, null);
    }

    /// The client stops shooting.
    @Handles(Opcode.CMSG_CANCEL_AUTO_REPEAT_SPELL, WorldState.inWorld)
    void handleCancelAutoRepeat()
    {
        autoRepeat = null;
    }

    /**
     * Each tick: the auto-repeating spell shoots at the player's current target whenever its time comes
     * (the ranged weapon's attack time). If movement blocks the shot when due, retry every half
     * second. Wands cancel on movement. A failed cast check also ends the repeat.
     */
    package void updateAutoRepeat(Duration elapsed)
    {
        if (autoRepeat is null || player is null)
            return;
        enum uint movingCancels = 0x08; // AURA_INTERRUPT_FLAG_MOVING
        enum int windUpMs = 500, retryMs = 500;
        import dmangos.world.movement : MovementFlags;

        enum uint moving = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
            | MovementFlags.strafeRight | MovementFlags.fallingFar; // not just turning
        const elapsedMs = cast(int) elapsed.total!"msecs";
        if (player.movement.flags & moving)
        {
            if (autoRepeat.casting.channelInterruptFlags & movingCancels)
                return stopAutoRepeat();
            autoRepeatMs -= elapsedMs;
            if (autoRepeatMs <= 0)
            {
                // Keep the next retry aligned with the original due time even when a tick spans it.
                autoRepeatMs = retryMs + autoRepeatMs % retryMs;
                autoRepeatPhase = AutoRepeatPhase.retrying;
            }
            else if (autoRepeatPhase != AutoRepeatPhase.retrying)
                autoRepeatPhase = AutoRepeatPhase.moving;
            return;
        }

        if (autoRepeatPhase == AutoRepeatPhase.starting || autoRepeatPhase == AutoRepeatPhase.moving)
        {
            // A stop before the first retry lets the wind-up overlap the remaining weapon time.
            if (autoRepeatPhase == AutoRepeatPhase.moving)
                autoRepeatMs -= elapsedMs;
            if (autoRepeatMs < windUpMs)
                autoRepeatMs = windUpMs;
            autoRepeatPhase = AutoRepeatPhase.cycling;
            return;
        }
        autoRepeatMs -= elapsedMs;
        if (autoRepeatMs > 0)
            return;
        if (autoRepeatPhase == AutoRepeatPhase.retrying)
        {
            autoRepeatPhase = AutoRepeatPhase.cycling;
            autoRepeatMs = windUpMs;
            return;
        }
        const target = player.values.get!UNIT_FIELD_TARGET;
        if (!target)
            return stopAutoRepeat();
        auto targets = SpellTargets(TargetFlags.unit, target);
        const result = checkCast(autoRepeat, targets, false, 0, false);
        if (result != SpellCastResult.ok)
        {
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(autoRepeat.id, result, autoRepeat));
            return stopAutoRepeat();
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
        // A ranged attack that went: the target's auras that proc on it if a player (the shooter's procced as it
        // struck: `spellHitProcs`).
        {
            import dmangos.world.aurahandlers : ProcFlag;

            if (auto other = playerOnMap(target))
                other.procAuras(ProcFlag.takeRangedAttack, unit);
        }
        autoRepeatMs = cast(int) player.values.get!UNIT_FIELD_RANGEDATTACKTIME + cast(int) spell.recoveryTime;
    }

    package SpellCastResult castSpell(const(SpellInfo)* spell, SpellTargets targets, bool triggered, uint itemEntry,
        bool playerHandoff = false)
    {
        // Auto Shot and the like: from now on, at each of their times.
        if (!triggered && autoRepeats(spell))
            return startAutoRepeat(spell, targets);
        if (targets.mask == TargetFlags.self)
            targets.unit = player.guid;
        auto drain = !triggered ? remoteLeechTarget(spell, targets.unit) : null;
        const result = checkCast(spell, targets, triggered, itemEntry, true, drain, playerHandoff || drain !is null);
        if (result != SpellCastResult.ok)
        {
            if (!triggered)
                deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
            return result;
        }
        auto c = Casting(spell, targets, 0, itemEntry, triggered, true);
        c.playerHandoff = playerHandoff;
        c.castItemGuid = itemEntry ? usingItemGuid : 0;
        c.custom = pendingCustom; // a cast with amounts of its own (`castCustom`)
        pendingCustom = typeof(pendingCustom).init;
        // What a cast ends as it starts (`Spell::Prepare`): an item's use, then any action; not a triggered spell's,
        // nor one that is not an action (`SPELL_ATTR_EX2_NOT_AN_ACTION`).
        enum uint notAnAction = 0x10000000;
        if (!triggered && !(spell.attributesEx2 & notAnAction))
        {
            if (itemEntry)
                interruptAurasOnCast(AuraInterrupt.itemUse, spell);
            interruptAurasOnCast(AuraInterrupt.action, spell);
        }
        // The cast began: the spell's script hears of it before anything of it happens (`OnSuccessfulStart`).
        {
            import dmangos.script.api : CastStarted, EntityRef;

            spellScriptEvent(spell, CastStarted(EntityRef(player.guid), EntityRef(targets.unit)));
        }
        if (!triggered)
        {
            c.timer = castTimeCheat || tradeSpellCompleting ? 0 : max(0, cast(int)(spellMod(SpellModOp.castingTime, spell,
                castTime(*spell, context.client, player.data.level)) * player.auras.castTimeFactor()));
            c.castTime = c.timer;
            pushbacks = 0;
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
        checkpointSummons(true);
        return SpellCastResult.ok;
    }

    private Replica remoteLeechTarget(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.spelldamage : isRemoteLeechChannel;

        if (context.sendAreaDamage is null || !target || map.unit(target) || !isRemoteLeechChannel(*spell))
            return null;
        auto copy = cast(Replica) map.findObject(target);
        return copy !is null && (copy.fields.type == TypeId.player || copy.fields.type == TypeId.unit) ? copy : null;
    }

    private Replica remoteChannelTarget(const(SpellInfo)* spell, ulong target)
    {
        if (context.namedCreatureChannel(spell) != size_t.max)
        {
            auto copy = cast(Replica) map.findObject(target);
            return copy !is null && copy.fields.type == TypeId.unit ? copy : null;
        }
        return remoteLeechTarget(spell, target);
    }

    /// The countdown of a cast in progress: it goes when its time is up.
    void updateSpells(Duration elapsed)
    {
        if (mindVisionAsked.spell && context.clock() >= mindVisionAsked.deadline)
        {
            const spell = mindVisionAsked.spell;
            mindVisionAsked = PendingMindVision.init;
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell, SpellCastResult.badTargets));
        }
        if (bobber)
            updateBobber(cast(int) elapsed.total!"msecs");
        if (persistentAreas.length)
            updatePersistentAreas(cast(int) elapsed.total!"msecs");
        updateTraps(cast(int) elapsed.total!"msecs");
        if (pendingHits.length)
        {
            import dmangos.world.spelldamage : isTargetedProcEffect;

            // The missiles that arrive now (a copy: an effect may cast another).
            const diff = cast(int) elapsed.total!"msecs";
            PendingHit[] due;
            PendingHit[] still;
            foreach (hit; pendingHits)
            {
                hit.left -= diff;
                const waiting = hit.left <= 0 && hit.left > -2_000 && context.sendAreaDamage !is null
                    && isTargetedProcEffect(*hit.spell, hit.effect) && map.findObject(hit.target) is null
                    && !map.unit(hit.target);
                (hit.left > 0 || waiting ? still : due) ~= hit;
            }
            pendingHits = still;
            if (due.length && !checkpointSummons(true))
            {
                foreach (ref hit; due)
                    hit.left = 1000;
                pendingHits ~= due;
                return;
            }
            PendingHit[] local;
            foreach (hit; due)
            {
                if (context.sendAreaDamage !is null && isTargetedProcEffect(*hit.spell, hit.effect))
                    if (auto copy = cast(Replica) map.findObject(hit.target))
                    {
                        auto remote = RemoteAreaDamage(copy.owner, AreaDamage(caster: player.guid, target: hit.target,
                            spell: hit.spell.id, effect: cast(ubyte) hit.effect, map: map.id, instance: map.instanceId,
                            triggered: hit.casting.triggered, playerProjectile: true), hit.bounce);
                        sendRolledReplicaEffect(hit.spell, hit.casting, remote);
                        continue;
                    }
                doEffect(hit.spell, hit.effect, hit.target, hit.casting, hit.bounce);
                local ~= hit;
            }
            // The charged modifiers of casts whose missiles have all landed.
            if (missileSpends.length)
            {
                import std.algorithm.searching : any;

                MissileSpend[] waiting;
                foreach (m; missileSpends)
                    if (pendingHits.any!(h => h.spell is m.spell))
                        waiting ~= m;
                    else
                        spendChargedMods(m.spell, m.hadAtStart, m.triggered);
                missileSpends = waiting;
            }
            // A missile's last effect on a target landed: what lands with it (Frostbite's freeze after Frostbolt's
            // damage, not before it).
            foreach (k, hit; local)
            {
                bool last = !missileOnTheWay(hit.spell, hit.target);
                foreach (other; local[k + 1 .. $])
                    last &= !(other.spell is hit.spell && other.target == hit.target);
                if (last)
                    targetTriggers(hit.spell, [hit.target]);
            }
            if (due.length)
                flushPlayerChanges();
        }
        const channelElapsed = cast(int) elapsed.total!"msecs";
        if (channelSpell !is null && followingNamedCreature)
            followNamedChannelTarget(channelElapsed);
        if (channelSpell !is null)
            payChannelCost(channelElapsed);
        if (channelSpell !is null && (channelTimer -= channelElapsed) <= 0)
            endChannel(false);
        if (!generic.active)
            return;
        generic.timer -= cast(int) elapsed.total!"msecs";
        if (generic.timer > 0)
            return;
        auto c = generic;
        generic.active = false;
        if (!checkpointSummons(true))
        {
            generic = c;
            generic.timer = 1000;
            return;
        }
        go(c);
    }

    /// Whether an effect of `spell` is still flying at `target` (`pendingHits`).
    package bool missileOnTheWay(const(SpellInfo)* spell, ulong target)
    {
        foreach (ref hit; pendingHits)
            if (hit.spell is spell && hit.target == target)
                return true;
        return false;
    }

    private uint pushbacks; // of the cast or channel under way: each pushes back less (1000 ms, 800, ..., 200)

    /**
     * Hurt while casting (CMaNGOS's `Unit::InterruptOrDelaySpell`): a cast that damage cancels stops, one with
     * pushback goes back by 1000, 800, 600, 400 and then 200 milliseconds a blow, never past its whole time
     * (`SMSG_SPELL_DELAYED`); a channel that damage shortens is shortened by as much, its auras too
     * (`MSG_CHANNEL_UPDATE`), one that damage breaks breaks. Damage over time pushes nothing back; talents and
     * `RESIST_PUSHBACK` give a chance to lose nothing (Concentration Aura).
     */
    package void damagedWhileCasting(bool periodic, bool bySelf)
    {
        import std.random : uniform;

        enum uint interruptPushback = 0x02, interruptDamageCancels = 0x10; // SPELL_INTERRUPT_FLAG_*
        enum uint channelDamage = 0x02, channelDamageDuration = 0x4000;   // AURA_INTERRUPT_FLAG_* of a channel
        bool resisted(const(SpellInfo)* spell)
        {
            const chance = spellMod(SpellModOp.notLoseCastingTime, spell, 100) - 100
                + player.auras.total(AuraType.resistPushback);
            return chance > 0 && uniform(0, 100, map.random) < chance;
        }
        int nextDelay()
        {
            return pushbacks < 5 ? 1000 - 200 * pushbacks++ : 200;
        }
        if (!periodic && generic.active && generic.timer > 0)
        {
            const spell = generic.spell;
            if (spell.casting.interruptFlags & interruptDamageCancels)
                interruptCast(SpellCastResult.interrupted);
            else if ((spell.casting.interruptFlags & interruptPushback) && !resisted(spell))
            {
                int delay = nextDelay();
                if (generic.timer + delay > generic.castTime)
                    delay = generic.castTime - generic.timer;
                generic.timer += delay;
                if (delay)
                    checkpointSummons();
                ByteWriter w;
                w.put(player.guid);
                w.put(cast(uint) delay);
                deliver(Opcode.SMSG_SPELL_DELAYED, w.data);
            }
        }
        if (channelSpell is null)
            return;
        const flags = channelSpell.casting.channelInterruptFlags;
        if (!periodic && (flags & channelDamageDuration))
        {
            if (bySelf || resisted(channelSpell))
                return;
            int delay = nextDelay();
            if (channelTimer < delay)
                delay = channelTimer;
            channelTimer -= delay;
            shortenChannelAuras(delay);
            if (activeRecoveryChannelAura() !is null)
                checkpointSummons();
            ByteWriter w;
            w.put(cast(uint) channelTimer);
            deliver(Opcode.MSG_CHANNEL_UPDATE, w.data);
        }
        else if (flags & channelDamage)
            endChannel(true);
    }

    /// The channel's auras on its target (and on the player) last `delay` milliseconds less, as it does.
    private void shortenChannelAuras(int delay)
    {
        const spell = channelSpell;
        if (auto copy = remoteChannelTarget(spell, channelTarget))
            return updateReplicaChannel(spell, copy, max(1, channelTimer), namedChannelSequence);
        if (auto creature = cast(Creature) map.findObject(channelTarget))
        {
            if (auto aura = creature.auras.find(spell.id, player.guid))
                if (aura.duration > 0 && (!namedChannelSequence || aura.channelToken == namedChannelSequence))
                    aura.duration = aura.duration > delay ? aura.duration - delay : 1;
        }
        else if (auto other = channelTarget == player.guid ? this : playerOnMap(channelTarget))
            if (other.player !is null)
                    if (auto aura = other.player.auras.find(spell.id, player.guid))
                    if (aura.duration > 0)
                    {
                        aura.duration = aura.duration > delay ? aura.duration - delay : 1;
                        other.sendAuraDuration(aura);
                    }
    }

    /// The cast in progress stops; the player and everyone around are told.
    void interruptCast(SpellCastResult reason)
    {
        if (!generic.active)
            return;
        const id = generic.spell.id;
        generic.active = false;
        checkpointSummons(true);
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
        channelCreditPeer = 0;
        followingNamedCreature = context.namedCreatureChannel(spell) != size_t.max;
        namedChannelSequence = followingNamedCreature ? context.nextGameplaySequence() : 0;
        namedChannelConfirmed = false;
        namedChannelPeer = 0;
        missingNamedChannelTarget = 0;
        // Eyes of the Beast also applies an aura to the hunter. The channel follows the pet it controls.
        if (spell.id == imported!"dmangos.world.pethandlers".spellEyesOfTheBeast && charmed !is null && charmed is ownPet)
            target = charmed.guid;
        channelTarget = channelObject ? channelObject : target ? target : player.guid;
        channelObject = 0;
        channelTimer = ms;
        channelCostTimer = 1000;
        ritualChannelOwner = currentRitualOwner();
        if ((bobber && bobber == channelTarget) || (persistentAreas.length && spell.hasEffect(SpellEffect.persistentAreaAura))
            || activeRecoveryChannelAura() !is null || ritualChannelOwner)
            checkpointSummons(true);
        showChannelStart();
        // Mind Vision (`SPELL_AURA_BIND_SIGHT`): the player sees through the channel's target while it lasts.
        import dmangos.world.spellids : AuraType;

        foreach (j; 0 .. 3)
            if (spell.effect[j] == SpellEffect.applyAura && spell.casting.applyAuraName[j] == AuraType.bindSight
                    && channelTarget != player.guid)
                seeFrom(channelTarget);
        if (cameraChannel())
            checkpointSummons(true);
    }

    private void showChannelStart()
    {
        ByteWriter w;
        w.put(channelSpell.id);
        w.put(cast(uint) channelTimer);
        deliver(Opcode.MSG_CHANNEL_START, w.data);
        player.values.set!UNIT_CHANNEL_SPELL(channelSpell.id);
        player.values.set!UNIT_FIELD_CHANNEL_OBJECT(channelTarget);
        flushPlayerChanges();
    }

    private int channelCostTimer; // ms to the channel's next second's cost

    /**
     * What this player channels (or last channelled) `spell` at; 0 if it is not that channel's. A channel's last
     * tick comes as it ends (Arcane Missiles' third missile): its target is still known.
     */
    package ulong channelledAt(const(SpellInfo)* spell)
    {
        return spell !is null && (channelSpell is spell || lastChannelSpell is spell) ? channelTarget : 0;
    }

    package bool channelActiveAt(const(SpellInfo)* spell, ulong target)
    {
        return channelSpell is spell && channelTarget == target;
    }

    package void remoteChannelAccepted(const(SpellInfo)* spell, ulong target, ushort peer)
    {
        if (channelActiveAt(spell, target) && namedChannelPeer == peer)
        {
            channelCreditPeer = peer;
            namedChannelConfirmed = true;
        }
    }

    package bool namedChannelActiveAt(const(SpellInfo)* spell, ulong target, ulong sequence)
    {
        return sequence && sequence == namedChannelSequence && channelActiveAt(spell, target);
    }

    private ushort channelCreditPeer;
    private ulong namedChannelSequence;
    private bool followingNamedCreature;
    private bool namedChannelConfirmed;
    private ushort namedChannelPeer;
    private int missingNamedChannelTarget;
    private const(SpellInfo)* lastChannelSpell; // the channel that ended last (`channelledAt`)

    private void followNamedChannelTarget(int diff)
    {
        import dmangos.world.spellselection : namedCreatureRange;

        auto target = map.unit(channelTarget);
        if (!target)
            if (auto copy = remoteChannelTarget(channelSpell, channelTarget))
                target = UnitRef.observed(copy, map);
        if (!target)
        {
            // Region handoffs briefly remove a replica before replacing it with the new owner's.
            if ((missingNamedChannelTarget += diff) >= 1000)
                endChannel(true);
            return;
        }
        missingNamedChannelTarget = 0;
        const at = target.position, from = player.position;
        const reach = namedCreatureRange(*channelSpell, context.client) + player.fighter.combatReach
            + target.fighter.combatReach;
        if (!target.alive || (at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2 > reach * reach
            || !map.inLineOfSight(from, at))
            return endChannel(true);
        const ushort peer = target.replica is null ? 0 : target.replica.owner;
        if (peer == namedChannelPeer)
            return;
        namedChannelPeer = peer;
        channelCreditPeer = 0;
        namedChannelConfirmed = false;
        if (target.replica !is null)
            updateReplicaChannel(channelSpell, target.replica, channelTimer, namedChannelSequence);
        else if (target.creature !is null)
            if (auto aura = target.creature.auras.find(channelSpell.id, player.guid))
                namedChannelConfirmed = aura.channelToken == namedChannelSequence;
    }

    /**
     * A channel's cost each second (`ManaPerSecond`: Health Funnel's health), the caster's; one that costs health
     * the caster has no more of ends (CMaNGOS's `SpellAuraHolder::UpdateHolder`).
     */
    private void payChannelCost(int ms)
    {
        const spell = channelSpell;
        const perSecond = cast(int)(spell.casting.manaPerSecond + spell.casting.manaPerSecondPerLevel * player.data.level);
        if (perSecond <= 0)
            return;
        for (channelCostTimer -= ms; channelCostTimer <= 0; channelCostTimer += 1000)
        {
            if (spell.casting.powerType == powerHealth)
            {
                const health = player.values.get!UNIT_FIELD_HEALTH;
                if (health <= perSecond)
                {
                    endChannel(true);
                    break;
                }
                player.values.set!UNIT_FIELD_HEALTH(health - perSecond);
            }
            else if (spell.casting.powerType < maxPowers)
                player.modifyPower(cast(Power) spell.casting.powerType, -perSecond);
        }
        flushPlayerChanges();
    }

    /// Far Sight's spot (`SPELL_EFFECT_ADD_FARSIGHT`): a dynamic object at the spell's destination, seen from
    /// until the channel ends (it is the channel's object).
    package void makeFarSightSpot(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
    {
        import dmangos.world.dynobject : DynamicObject;
        import dmangos.world.spellcast : radius;

        Position at = player.position;
        if (targets.mask & TargetFlags.destLocation)
            at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
        removeFarSightSpot();
        auto spot = new DynamicObject(context.nextTemporaryCounter(), player.guid, spell.id, i,
            radius(*spell, i, context.client), at);
        map.addObject(spot);
        farSightSpot = spot.guid;
        channelObject = spot.guid;
        seeFrom(spot.guid);
    }

    /**
     * The player sees from `eye` (an object or unit on its map: `Map.eyeOf`), or from where it stands again (0):
     * `PLAYER_FARSIGHT`, which the client moves its camera to, and the map's sight worked out from there.
     */
    void seeFrom(ulong eye)
    {
        import dmangos.world.updatefields : PLAYER_FARSIGHT;

        if (player.values.get!PLAYER_FARSIGHT == eye)
            return;
        player.values.set!PLAYER_FARSIGHT(eye);
        if (map !is null)
            map.refreshVisibility(this); // the eye's surroundings (and the spot itself) before the camera moves
        flushPlayerChanges();
    }

    private void removeFarSightSpot()
    {
        if (farSightSpot && map !is null)
            map.removeObject(farSightSpot);
        farSightSpot = 0;
    }

    /**
     * The channel ends, at its time or cut short (`cancelled`: moving,
     * `CMSG_CANCEL_CHANNELLING`, another cast), when its auras on the target go with it.
     */
    package void endChannel(bool cancelled)
    {
        if (channelSpell is null)
            return;
        const spell = channelSpell;
        const checkpointedChannel = activeRecoveryChannelAura() !is null || ritualChannelOwner || cameraChannel();
        channelSpell = null;
        ritualChannelOwner = 0;
        if (checkpointedChannel)
            checkpointSummons(true);
        const canCredit = !followingNamedCreature || namedChannelConfirmed;
        followingNamedCreature = false;
        namedChannelConfirmed = false;
        const creditPeer = channelCreditPeer;
        channelCreditPeer = 0;
        const channelToken = namedChannelSequence;
        namedChannelSequence = 0;
        lastChannelSpell = cancelled ? null : spell;
        // At its end, a creature it charms is let go (a charmed creature's own time does not run: Mind Control's);
        // its other auras end as their time does (the last tick of Arcane Missiles, of Drain Life, with them).
        if (!cancelled)
            if (auto creature = cast(Creature) map.findObject(channelTarget))
                if (creature is charmed)
                    if (auto aura = creature.auras.find(spell.id))
                        if (aura.caster == player.guid)
                        {
                            creature.loseAura(aura, map);
                            map.flushCreature(creature);
                        }
        if (cancelled)
        {
            if (auto copy = remoteChannelTarget(spell, channelTarget))
                updateReplicaChannel(spell, copy, 0, channelToken);
            if (auto creature = cast(Creature) map.findObject(channelTarget))
            {
                if (auto aura = creature.auras.find(spell.id, player.guid))
                    if (!channelToken || aura.channelToken == channelToken)
                    {
                        creature.loseAura(aura, map);
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
            // Its effects on the caster (Arcane Missiles' trigger, Mind Control's) go with it.
            if (channelTarget != player.guid)
                if (auto aura = player.auras.find(spell.id))
                    if (aura.caster == player.guid)
                        removeAura(aura);
            map.sendToWatchers(this, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(player.guid, spell.id, SpellCastResult.interrupted), true);
        }
        if (bobber && !bobberLooted)
            removeBobber();
        closeRitualPortal(); // a ritual's portal goes with its caster's channel
        // Tame Beast's twenty seconds are up: the beast is tamed.
        if (!cancelled && spell.id == imported!"dmangos.world.pethandlers".spellTameBeast)
            tameBeastChannelDone(channelTarget);
        if (!cancelled && channelTarget && canCredit)
            rewardPlayerAndGroupAtCast(channelTarget, spell.id, creditPeer); // a channel at a quest's creature or object
        // A channel cancelled: its spots go with it.
        if (cancelled && persistentAreas.length)
        {
            import dmangos.world.caster : Caster;
            import dmangos.world.spellareas : endPersistentAreas;

            auto me = Caster.of(this);
            const count = persistentAreas.length;
            endPersistentAreas(me, persistentAreas, spell);
            if (count != persistentAreas.length)
                checkpointSummons(true);
        }
        // Far Sight, Eagle Eye, Mind Vision: the camera comes back, the spot goes.
        seeFrom(0);
        removeFarSightSpot();
        ByteWriter w;
        w.put(0u);
        deliver(Opcode.MSG_CHANNEL_UPDATE, w.data);
        player.values.set!UNIT_CHANNEL_SPELL(0u);
        player.values.set!UNIT_FIELD_CHANNEL_OBJECT(0UL);
        flushPlayerChanges();
        if (!cancelled && channelToken)
            context.completeNamedChannel(map, map.unit(player.guid), channelTarget, spell, channelToken);
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
    /// Whether `t` is a fishing bobber's template.
    package static bool isFishingBobber(const(imported!"dmangos.world.gameobject".GameObjectTemplate)* t)
    {
        return t !is null && t.type == imported!"dmangos.world.gameobject".GameObjectType.fishingNode;
    }

    /**
     * `SPELL_EFFECT_TRANS_DOOR` of an object that is no bobber nor ritual (CMaNGOS's `EffectTransmitted`): a mage's
     * portal, a Lightwell, at the spot thrown at, else its radius ahead, else somewhere in its range ahead; the
     * caster's, of its level, for the spell's duration.
     */
    package void transmitObject(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
    {
        import std.math : cos, sin;
        import std.random : uniform01;
        import dmangos.world.spellcast : duration, radius, range;

        const entry = cast(uint) spell.miscValue[i];
        if (entry !in context.data.gameObjectTemplates)
            return;
        auto at = player.position;
        if (targets.mask & TargetFlags.destLocation)
            at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
        else
        {
            const r = range(*spell, context.client);
            const distance = spell.casting.radiusIndex[i] && spell.casting.speed == 0 ? radius(*spell, i, context.client)
                : uniform01(map.random) * (r[1] - r[0]) + r[0];
            at.x += distance * cos(at.orientation);
            at.y += distance * sin(at.orientation);
        }
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        auto go = context.summonWildGameObject(map, entry, at, ms > 0 ? cast(uint)(ms / 1000) : 0);
        if (go is null)
            return;
        go.owner = player.guid;
        go.values.set!OBJECT_FIELD_CREATED_BY(player.guid);
        go.values.set!GAMEOBJECT_LEVEL(player.data.level);
        map.flushGameObject(go);
    }

    package void castBobber(const(SpellInfo)* spell, size_t i)
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
            bobberSplash(go);
        }
        if (!bobberLooted && bobberAge >= bobberGone)
        {
            deliver(Opcode.SMSG_FISH_NOT_HOOKED, null);
            endChannel(false);
        }
    }

    private void bobberSplash(GameObject go)
    {
        import dmangos.world.gameobject : gameObjectAnimation;

        go.values.set!GAMEOBJECT_STATE(0u); // GO_STATE_ACTIVE
        map.flushGameObject(go);
        map.sendToObservers(go.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, gameObjectAnimation(go.guid, 0));
    }

    /// A persistent area aura's spot (`dmangos.world.spellareas.makePersistentArea`).
    package void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spellareas;

        auto me = Caster.of(this);
        const count = persistentAreas.length;
        dmangos.world.spellareas.makePersistentArea(me, persistentAreas, spell, i, targets, value);
        if (count != persistentAreas.length)
            checkpointSummons(true);
    }



    /// The spots' ticks and ends (`dmangos.world.spellareas.updatePersistentAreas`).
    void updatePersistentAreas(int diff)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spellareas;

        auto me = Caster.of(this);
        const count = persistentAreas.length;
        dmangos.world.spellareas.updatePersistentAreas(me, persistentAreas, diff);
        if (count != persistentAreas.length)
            checkpointSummons(true);
    }


    /// A missile's flight time, in milliseconds: to `target` at the spell's speed (yards a second); 0: at once.
    int flightTime(const(SpellInfo)* spell, ulong target)
    {
        if (spell.casting.speed <= 0 || (spell.attributesEx & (0x04 | 0x40)) || target == player.guid)
            return 0;
        Position to;
        if (auto creature = cast(Creature) map.findObject(target))
            to = creature.position;
        else if (auto who = map.find(target))
            to = who.character.position;
        else
            return 0;
        return flightTimeTo(spell, to);
    }

    private int flightTimeTo(const(SpellInfo)* spell, Position to)
    {
        import std.math : sqrt;

        if (spell.casting.speed <= 0)
            return 0;
        const at = player.position;
        const distance = sqrt((to.x - at.x) ^^ 2 + (to.y - at.y) ^^ 2 + (to.z - at.z) ^^ 2);
        return cast(int)(distance / spell.casting.speed * 1000);
    }

    /// The bobber goes.
    void removeBobber(bool departing = false)
    {
        const removed = bobber;
        if (!removed)
            return;
        map.removeObject(removed);
        bobber = 0;
        bobberLooted = false;
        if (!departing)
            checkpointSummons(true, removed);
    }

    /**
     * The angler uses its own bobber: before the bite nothing is hooked; in the bite's
     * 5 seconds the catch depends on the fishing skill against the area's (or zone's)
     * `skill_fishing_base_level` (5% at that skill, more above it; a pole's and a lure's bonus count), and a
     * catch may raise the skill (`professions.fishingSkillUpChance`; a fish that got away gives none, docs/FORMULAS.md
     * "Fishing"); a catch is looted from `fishing_loot_template`, else the fish escaped.
     */
    package void useBobber(GameObject go)
    {
        import std.random : uniform;
        import dmangos.world.professions : fishingSkillUpChance;

        enum uint skillFishing = 356;
        if (go.owner != player.guid || go.guid != bobber || bobberLooted)
            return;
        if (bobberAge < bobberBite)
        {
            deliver(Opcode.SMSG_FISH_NOT_HOOKED, null);
            return endChannel(false);
        }
        if (!checkpointSummons(true, go.guid))
            return;
        bool allowsCatch(ulong guid, const LootItem item)
        {
            return (!item.quest || hasQuestForItem(item.itemId)) && (item.condition == 0 || conditionMet(item.condition));
        }
        const area = player.area, zone = player.data.zone;
        int zoneSkill = context.data.fishingBaseSkill.get(area, 0);
        if (!zoneSkill)
            zoneSkill = context.data.fishingBaseSkill.get(zone, 0);
        const skill = cast(int) player.skillWithBonus(skillFishing);
        const chance = skill - zoneSkill + 5;
        const success = skill >= zoneSkill && chance >= uniform!"[]"(1, 100, map.random);
        if (success)
            updateSkillPro(skillFishing, fishingSkillUpChance(player.skillValue(skillFishing)[0]), 1);
        else
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
                &allowsCatch);
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

            loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowsCatch);
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
    void spellsOnLeave(bool leavingMap = true)
    {
        areaAurasOnLeave();
        if (generic.active)
            interruptCast(SpellCastResult.interrupted);
        endChannel(true);
        endGroundCasts();
        removeTraps();
        if (leavingMap && (context.discardReplicaImpacts(player.guid) || pendingHits.length))
        {
            pendingHits = null;
            missileSpends = null;
            checkpointSummons(true);
        }
        nextSwing.active = false;
    }

    /// Ground casts end when the caster leaves this map or logs out.
    package void endGroundCasts()
    {
        if (channelSpell !is null && channelSpell.hasEffect(SpellEffect.persistentAreaAura))
            endChannel(true);
        if (persistentAreas.length)
        {
            import dmangos.world.caster : Caster;
            import dmangos.world.spellareas : endPersistentAreas;

            auto me = Caster.of(this);
            endPersistentAreas(me, persistentAreas);
            checkpointSummons(true);
        }
    }

    private static struct CameraHandoff
    {
        ulong guid;
        Position at;
        bool owned;
    }

    private bool cameraChannel()
    {
        import std.algorithm.searching : canFind;

        return channelSpell !is null && channelTarget && player.values.get!PLAYER_FARSIGHT == channelTarget
            && (farSightSpot == channelTarget || channelSpell.hasEffect(SpellEffect.bindSight)
                || channelSpell.casting.applyAuraName[].canFind(AuraType.bindSight));
    }

    private CameraHandoff takeCameraHandoff()
    {
        const camera = cameraHandoffState();
        if (camera.owned)
            removeFarSightSpot();
        return camera;
    }

    private CameraHandoff cameraHandoffState()
    {
        if (!cameraChannel())
            return CameraHandoff.init;
        bool watching;
        const at = map.eyeOf(this, watching);
        return watching ? CameraHandoff(channelTarget, at, farSightSpot != 0) : CameraHandoff.init;
    }

    private void restoreCameraHandoff(ref ByteReader reader)
    {
        import dmangos.serialization : deserialize;
        import dmangos.world.dynobject : DynamicObject;
        import dmangos.world.objects : counterOf, highGuidOf, HighGuid, temporaryCounterStart;
        import dmangos.world.spellcast : radius;

        const camera = deserialize!CameraHandoff(reader);
        const at = camera.at;
        if (!camera.guid || channelSpell is null || camera.guid != channelTarget
            || !context.client.isValidMapCoord(map.id, at.x, at.y, at.z, at.orientation))
            return;
        if (camera.owned)
        {
            const counter = counterOf(camera.guid);
            if (highGuidOf(camera.guid) != HighGuid.dynamicObject || counter < temporaryCounterStart)
                return;
            foreach (effect, command; channelSpell.effect)
                if (command == SpellEffect.addFarsight)
                {
                    auto spot = new DynamicObject(counter, player.guid, channelSpell.id, effect,
                        radius(*channelSpell, effect, context.client), at);
                    map.addObject(spot);
                    farSightSpot = spot.guid;
                    seeFrom(spot.guid);
                    return;
                }
            return;
        }
        map.retainEye(player.guid, camera.guid, at);
        seeFrom(camera.guid);
    }

    private bool carriesChannelOnHandoff()
    {
        import dmangos.world.objects : highGuidOf, HighGuid;
        import std.algorithm.comparison : among;
        import std.algorithm.searching : any;

        if (channelSpell is null || channelSpell.casting.applyAuraName[].any!(a =>
            a.among(AuraType.modCharm, AuraType.modPossess, AuraType.modPossessPet)))
            return false;
        if (followingNamedCreature || carriesRitualChannel() || cameraChannel())
            return true;
        if (channelSpell.hasEffect(SpellEffect.persistentAreaAura))
            return persistentAreas.length != 0;
        if (bobber && channelTarget == bobber && !bobberLooted)
            if (auto go = map.gameObjectAt(bobber))
                return go.owner == player.guid;
        if (player.values.get!PLAYER_FARSIGHT || channelSpell.hasEffect(SpellEffect.bindSight)
            || !highGuidOf(channelTarget).among(HighGuid.player, HighGuid.unit, HighGuid.pet))
            return false;
        return !channelSpell.casting.applyAuraName[].any!(a => a == AuraType.bindSight);
    }

    private const(ubyte)[] fishingHandoffState()
    {
        import dmangos.serialization : serialize;

        auto go = map.gameObjectAt(bobber);
        if (go is null || go.owner != player.guid || bobberLooted || channelSpell is null || channelTarget != bobber)
            return null;
        ByteWriter state;
        serialize(state, go.spawn);
        state.put(bobberAge);
        state.put(bobberBite);
        state.put(bobberGone);
        go.saveState(state, context.transportNow());
        return state.data;
    }

    private const(ubyte)[] takeFishingHandoff()
    {
        const state = fishingHandoffState();
        if (state.length)
            removeBobber(true); // the destination sends the original bobber's create block
        return state;
    }

    private void restoreFishingHandoff(ref ByteReader reader)
    {
        auto state = ByteReader(reader.readBytes(reader.read!uint));
        if (channelSpell !is null)
            restoreFishingState(state, channelTarget);
    }

    private const(ubyte)[] fishingRecoveryState()
    {
        const fishing = fishingHandoffState();
        if (!fishing.length)
            return null;
        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(context.transportNow());
        state.put(channelSpell.id);
        state.put(channelTarget);
        state.put(channelTimer);
        state.putBytes(fishing);
        return state.data;
    }

    private void restoreFishingRecovery(ref ByteReader state)
    {
        import std.algorithm.comparison : max;

        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = max(0, cast(int)(context.transportNow() - state.read!uint));
        const spell = context.spellInfo(state.read!uint);
        const target = state.read!ulong;
        const remaining = state.read!int - elapsed;
        if (spell is null || channelSpell !is null || remaining <= 0 || !restoreFishingState(state, target, elapsed))
            return;
        channelSpell = spell;
        channelTarget = target;
        channelTimer = remaining;
        channelCostTimer = 1000;
        showChannelStart();
    }

    private bool restoreFishingState(ref ByteReader state, ulong target, int elapsed = 0)
    {
        import dmangos.serialization : deserialize;
        import dmangos.world.gameobject : GameObjectSpawn, GameObjectType;
        import dmangos.world.objects : temporaryCounterStart;

        if (state.empty)
            return false;
        const spawn = deserialize!GameObjectSpawn(state);
        const proto = spawn.entry in context.data.gameObjectTemplates;
        if (proto is null || proto.type != GameObjectType.fishingNode || spawn.guid < temporaryCounterStart
            || spawn.guid > 0xFF_FFFF || spawn.map != map.id
            || !context.client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z, spawn.orientation))
            return false;
        auto go = new GameObject(spawn, proto);
        const age = state.read!int, bite = state.read!int, gone = state.read!int;
        if (go.guid != target || age + elapsed >= gone)
            return false;
        bobberAge = age + elapsed;
        bobberBite = bite;
        bobberGone = gone;
        bobber = go.guid;
        go.owner = player.guid;
        go.instanceId = map.instanceId;
        go.loadState(state, context.transportNow());
        map.addObject(go);
        if (age < bite && bobberAge >= bite)
            bobberSplash(go);
        return true;
    }

    private const(ubyte)[] groundRecoveryState()
    {
        import dmangos.world.spellareas : writeGroundAreas;
        import std.algorithm.searching : any;

        const channel = channelSpell !is null && persistentAreas.any!(area => area.spell is channelSpell);
        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(context.transportNow());
        state.put(channel ? channelSpell.id : 0u);
        if (channel)
        {
            state.put(channelTarget);
            state.put(channelTimer);
            state.put(channelCostTimer);
        }
        writeGroundAreas(persistentAreas, state);
        return state.data;
    }

    private void restoreGroundRecovery(ref ByteReader state)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellareas : readGroundAreas;
        import std.algorithm.comparison : max;
        import std.algorithm.searching : any;

        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = max(0, cast(int)(context.transportNow() - state.read!uint));
        const id = state.read!uint;
        ulong target;
        int remaining, nextCost;
        if (id)
        {
            target = state.read!ulong;
            remaining = state.read!int - elapsed;
            nextCost = state.read!int;
        }
        auto caster = Caster.of(this);
        persistentAreas = readGroundAreas(caster, state, elapsed);
        if (remaining > 0 && channelSpell is null)
            if (const spell = context.spellInfo(id))
                if (persistentAreas.any!(area => area.spell is spell))
                {
                    channelSpell = spell;
                    channelTarget = target;
                    channelTimer = remaining;
                    channelCostTimer = elapsed < nextCost ? nextCost - elapsed : 1000 - (elapsed - nextCost) % 1000;
                    showChannelStart();
                }
    }

    private void writeChannelAndGroundHandoff(ref ByteWriter writer)
    {
        import dmangos.world.spellareas : detachGroundAreas, writeGroundAreas;

        const active = channelSpell !is null;
        if (!persistentAreas.length && !active)
        {
            writer.put(0u);
            return;
        }
        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(active ? channelSpell.id : 0u);
        if (active)
        {
            state.put(channelTarget);
            state.put(channelTimer);
            state.put(channelCostTimer);
            state.put(pushbacks);
            state.put(namedChannelSequence);
            if (namedChannelSequence)
            {
                state.put(namedChannelPeer);
                state.put(namedChannelConfirmed);
                state.put(channelCreditPeer);
            }
        }
        writeGroundAreas(persistentAreas, state);
        state.put(ritualChannelOwner);
        detachGroundAreas(map, persistentAreas);
        writer.put(cast(uint) state.data.length);
        writer.putBytes(state.data);
    }

    private void readChannelAndGroundHandoff(ref ByteReader reader)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellareas : readGroundAreas;

        auto state = ByteReader(reader.readBytes(reader.read!uint));
        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        if (const id = state.read!uint)
        {
            channelSpell = context.spellInfo(id);
            channelTarget = state.read!ulong;
            channelTimer = state.read!int;
            channelCostTimer = state.read!int;
            pushbacks = state.read!uint;
            namedChannelSequence = state.read!ulong;
            followingNamedCreature = namedChannelSequence != 0;
            if (followingNamedCreature)
            {
                namedChannelPeer = state.read!ushort;
                namedChannelConfirmed = state.read!bool;
                channelCreditPeer = state.read!ushort;
            }
        }
        auto caster = Caster.of(this);
        persistentAreas = readGroundAreas(caster, state);
        if (!state.empty)
            ritualChannelOwner = state.read!ulong;
        if (channelSpell !is null)
        {
            player.values.set!UNIT_CHANNEL_SPELL(channelSpell.id);
            player.values.set!UNIT_FIELD_CHANNEL_OBJECT(channelTarget);
            flushPlayerChanges();
            if (followingNamedCreature && namedChannelPeer)
                map.holdCasterReplica(player.guid, namedChannelPeer, cast(uint) channelTimer + 5_000, true);
            else if (auto target = cast(Replica) map.findObject(channelTarget))
                map.holdCasterReplica(player.guid, target.owner, cast(uint) channelTimer + 5_000, true);
        }
    }

    private void writeCastHandoff(ref ByteWriter writer)
    {
        import std.algorithm.comparison : max;
        import dmangos.plaindata : encode;

        const now = context.clock();
        writer.put(cast(int) max(0L, (gcdReadyAt - now).total!"msecs"));
        foreach (deadline; schoolLockedUntil)
            writer.put(cast(int) max(0L, (deadline - now).total!"msecs"));
        ubyte[] state;
        if (generic.active)
        {
            const snapshot = snapshotCast(generic);
            encode(state, snapshot);
        }
        writer.put(cast(uint) state.length);
        writer.putBytes(state);
    }

    private void readCastHandoff(ref ByteReader reader, int elapsed = 0)
    {
        import dmangos.plaindata : decode;

        const now = context.clock();
        gcdReadyAt = now + (reader.read!int - elapsed).msecs;
        foreach (ref deadline; schoolLockedUntil)
            deadline = now + (reader.read!int - elapsed).msecs;
        auto state = reader.readBytes(reader.read!uint);
        if (!state.length)
            return;
        CastHandoff snapshot;
        decode(state, snapshot);
        snapshot.remaining -= elapsed;
        generic = restoreCast(snapshot);
        if (generic.active)
            pushbacks = snapshot.pushbacks;
    }

    private const(ubyte)[] castRecoveryState()
    {
        import dmangos.serialization : serialize;

        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(context.transportNow());
        writeCastHandoff(state);
        writeFlightHandoff(state);
        context.writeReplicaImpacts(player.guid, state, false);
        auto aura = activeRecoveryChannelAura();
        state.put(aura !is null);
        if (aura !is null)
        {
            state.put(channelTarget);
            state.put(channelTimer);
            state.put(channelCostTimer);
            state.put(pushbacks);
            aura.saveState(state);
        }
        state.put(ritualChannelOwner != 0);
        if (ritualChannelOwner)
            writeRitualRecovery(state);
        const camera = cameraHandoffState();
        if (camera.guid)
        {
            state.put(channelSpell.id);
            state.put(channelTimer);
            state.put(channelCostTimer);
            state.put(pushbacks);
            state.put(camera.guid);
            serialize(state, camera);
        }
        return state.data;
    }

    private void restoreCastRecovery(ref ByteReader state, bool cameraFormat)
    {
        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = max(0, cast(int)(context.transportNow() - state.read!uint));
        readCastHandoff(state, elapsed);
        if (!state.empty)
            readFlightHandoff(state);
        if (!state.empty)
            context.readReplicaImpacts(player.guid, map.id, map.instanceId, state);
        if (!state.empty && state.read!bool)
            restorePeriodicChannel(state, elapsed);
        if (!state.empty && (!cameraFormat || state.read!bool))
            readRitualRecovery(state, elapsed);
        if (cameraFormat && !state.empty)
            readCameraRecovery(state, elapsed);
        if (generic.active)
            map.sendToWatchers(this, Opcode.SMSG_SPELL_START, spellStartPacket(player.guid, generic.spell.id,
                cast(uint) max(0, generic.timer), generic.targets), true);
    }

    private void readCameraRecovery(ref ByteReader state, int elapsed)
    {
        const spell = context.spellInfo(state.read!uint);
        const remaining = state.read!int - elapsed;
        const nextCost = state.read!int;
        const delays = state.read!uint;
        const target = state.read!ulong;
        if (spell is null || !target || remaining <= 0 || channelSpell !is null)
            return;
        channelSpell = spell;
        channelTarget = target;
        restoreCameraHandoff(state);
        if (!cameraChannel())
        {
            channelSpell = null;
            return;
        }
        channelTimer = remaining;
        channelCostTimer = elapsed < nextCost ? nextCost - elapsed : 1000 - (elapsed - nextCost) % 1000;
        pushbacks = delays;
        showChannelStart();
    }

    private void writeRitualRecovery(ref ByteWriter state)
    {
        state.put(ritualChannelOwner);
        state.put(channelSpell.id);
        state.put(channelTarget);
        state.put(channelTimer);
        state.put(channelCostTimer);
        state.put(pushbacks);
        state.putBytes(ritualPortalState());
    }

    private void readRitualRecovery(ref ByteReader state, int elapsed)
    {
        const owner = state.read!ulong;
        const spell = context.spellInfo(state.read!uint);
        const target = state.read!ulong;
        const remaining = state.read!int - elapsed;
        const nextCost = state.read!int;
        const delays = state.read!uint;
        if (!owner || spell is null || !target || remaining <= 0 || channelSpell !is null)
            return;
        channelSpell = spell;
        channelTarget = target;
        if (owner == player.guid && !restoreRitualPortal(state))
        {
            channelSpell = null;
            return;
        }
        ritualChannelOwner = owner;
        channelTimer = remaining;
        channelCostTimer = elapsed < nextCost ? nextCost - elapsed : 1000 - (elapsed - nextCost) % 1000;
        pushbacks = delays;
        showChannelStart();
    }

    /// Channels whose timed effect runs on the caster can recover their periodic aura with the cast.
    private bool recoverableChannelAura(const ref SpellInfo spell)
    {
        import std.algorithm.comparison : among;

        enum uint channeled = 0x04, selfChanneled = 0x40;
        if (!(spell.attributesEx & (channeled | selfChanneled)))
            return false;
        foreach (i, effect; spell.effect)
            if (effect == SpellEffect.applyAura && spell.implicitTargetA[i] == ImplicitTarget.caster
                && (cast(AuraType) spell.casting.applyAuraName[i]).among(AuraType.periodicTriggerSpell,
                    AuraType.periodicEnergize, AuraType.obsModMana, AuraType.periodicHeal))
                return true;
        return false;
    }

    private Aura activeRecoveryChannelAura()
    {
        if (channelSpell is null || !recoverableChannelAura(*channelSpell))
            return null;
        return player.auras.find(channelSpell.id, player.guid);
    }

    private void restorePeriodicChannel(ref ByteReader state, int elapsed)
    {
        const target = state.read!ulong;
        const remaining = state.read!int - elapsed;
        const nextCost = state.read!int;
        const delays = state.read!uint;
        auto aura = Aura.loadState(state, &context.spellInfo);
        if (remaining <= 0 || aura.duration <= elapsed || channelSpell !is null || aura.spell is null
            || aura.caster != player.guid || !recoverableChannelAura(*aura.spell))
            return;
        aura.duration -= elapsed;
        foreach (i, period; aura.period)
            if (period > 0)
            {
                const next = aura.periodTimer[i] - elapsed;
                aura.periodTimer[i] = next > 0 ? next : period - (-next % period);
            }
        channelSpell = aura.spell;
        channelTarget = target;
        channelTimer = remaining;
        channelCostTimer = elapsed < nextCost ? nextCost - elapsed : 1000 - (elapsed - nextCost) % 1000;
        pushbacks = delays;
        if (!addAura(aura))
        {
            channelSpell = null;
            return;
        }
        showChannelStart();
    }

    private CastHandoff snapshotCast(const ref Casting c)
    {
        return CastHandoff(c.spell.id, map.id, map.instanceId, c.targets, c.timer, c.castTime,
            c.castItemEntry, c.castItemGuid, c.custom.values, c.custom.which, c.custom.alwaysHits,
            c.triggered, c.playerHandoff, c.custom.by is null ? 0 : c.custom.by.id, pushbacks);
    }

    private Casting restoreCast(const ref CastHandoff snapshot)
    {
        const spell = context.spellInfo(snapshot.spell);
        if (spell is null || snapshot.mapId != map.id || snapshot.instance != map.instanceId)
            return Casting.init;
        auto c = Casting(spell, snapshot.targets, snapshot.remaining, snapshot.itemEntry, snapshot.triggered, true);
        c.castItemGuid = snapshot.itemGuid;
        c.castTime = snapshot.total;
        c.playerHandoff = snapshot.playerHandoff;
        c.custom = CustomValues(snapshot.values, snapshot.which, snapshot.alwaysHits,
            context.spellInfo(snapshot.triggeredBy));
        return c;
    }

    private void writeFlightHandoff(ref ByteWriter writer)
    {
        import dmangos.plaindata : encode;
        import std.algorithm.searching : canFind;

        ubyte[] bytes;
        if (pendingHits.length || missileSpends.length || chargedModsUsed.length)
        {
            FlightHandoff state;
            state.mapId = map.id;
            state.instance = map.instanceId;
            const now = context.transportNow();
            foreach (ref hit; pendingHits)
            {
                auto saved = MissileHandoff(snapshotCast(hit.casting), now + cast(uint) hit.left, hit.bounce,
                    hit.target, cast(ubyte) hit.effect, hit.casting.persistentDone, hit.casting.gameObjectOrigin);
                foreach (target, mask; hit.casting.auraEffects)
                    saved.auraEffects ~= MissileHandoff.AuraMask(target, mask);
                state.hits ~= saved;
            }
            foreach (ref m; missileSpends)
            {
                auto saved = FlightHandoff.Spend(m.spell.id, m.triggered, null);
                foreach (aura; m.hadAtStart)
                    if (player.auras.list.canFind!(present => present is aura))
                        saved.auras ~= AuraIdentity(aura.spell.id, aura.caster);
                state.spends ~= saved;
            }
            foreach (ref used; chargedModsUsed)
                if (player.auras.list.canFind!(present => present is used.aura))
                    state.used ~= FlightHandoff.Used(used.spell, AuraIdentity(used.aura.spell.id, used.aura.caster));
            encode(bytes, state);
        }
        writer.put(cast(uint) bytes.length);
        writer.putBytes(bytes);
    }

    private void readFlightHandoff(ref ByteReader reader)
    {
        import dmangos.plaindata : decode;

        auto bytes = reader.readBytes(reader.read!uint);
        if (!bytes.length)
            return;
        FlightHandoff state;
        decode(bytes, state);
        if (state.mapId != map.id || state.instance != map.instanceId)
            return;
        const now = context.transportNow();
        foreach (ref saved; state.hits)
        {
            auto c = restoreCast(saved.cast_);
            if (c.spell is null || saved.effect >= c.spell.effect.length)
                continue;
            c.active = false;
            c.persistentDone = saved.persistentDone;
            c.gameObjectOrigin = saved.gameObjectOrigin;
            foreach (ref aura; saved.auraEffects)
                c.auraEffects[aura.target] = aura.mask;
            const remaining = cast(int)(saved.deadline - now);
            pendingHits ~= PendingHit(c.spell, saved.effect, saved.target, c, remaining, saved.bounce);
        }
        foreach (ref saved; state.spends)
            if (const spell = context.spellInfo(saved.spell))
            {
                Aura[] held;
                foreach (ref identity; saved.auras)
                    if (auto aura = player.auras.find(identity.spell, identity.caster))
                        held ~= aura;
                missileSpends ~= MissileSpend(spell, held, saved.triggered);
            }
        foreach (ref used; state.used)
            if (auto aura = player.auras.find(used.aura.spell, used.aura.caster))
                chargedModsUsed ~= ChargedModUse(aura, used.forSpell);
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
        bool start, const(Replica) targetReplica = null, bool playerHandoff = false)
    {
        enum uint castableWhileSitting = 0x08000000; // SPELL_ATTR_CASTABLE_WHILE_SITTING
        const now = context.clock();
        const preflight = playerHandoff && targetReplica !is null;
        // A finishing move needs combo points on its target (Slice and Dice, cast on oneself: on anyone).
        if (!triggered && usesComboPoints(*spell)
                && (comboPoints == 0 || (targets.unit && targets.unit != player.guid && targets.unit != comboTarget)))
            return player.data.classId == 1 ? SpellCastResult.casterAuraState : SpellCastResult.noComboPoints; // a warrior's Overpower
        import dmangos.world.aurastate : AuraState;

        // What its caster needs of itself (`CasterAuraState`: Revenge, Riposte, Mongoose Bite after a block, a dodge
        // or a parry) and of its target (`TargetAuraState`: Execute under a fifth of its health).
        if (!triggered && spell.casterAuraState && !hasAuraState(cast(AuraState) spell.casterAuraState))
            return SpellCastResult.casterAuraState;
        if (!triggered && spell.casting.targetAuraState && targets.unit && targets.unit != player.guid)
            if (auto other = map.unit(targets.unit))
            {
                import dmangos.world.aurastate : auraStateFlag;

                const values = other.kind == UnitKind.creature ? &other.creature.values : &other.session.player.values;
                if (!(values.get!UNIT_FIELD_AURASTATE & auraStateFlag(cast(AuraState) spell.casting.targetAuraState)))
                    return SpellCastResult.targetAuraState;
            }
        if (player.deathState != DeathState.alive && !(spell.attributes & spellAttrCastableWhileDead))
            return player.deathState == DeathState.ghost ? SpellCastResult.notWhileGhost : SpellCastResult.casterDead;
        if (!triggered)
        {
            const refused = crowdControlRefusal(spell);
            if (refused != SpellCastResult.ok)
                return refused;
            const riding = mountedCastRefusal(spell, triggered); // "You are mounted" (`dmangos.world.mounting`)
            if (riding != SpellCastResult.ok)
                return riding;
        }
        if (start && !triggered)
        {
            if (generic.active)
                return SpellCastResult.spellInProgress;
            if (!cooldownCheat)
                if (const at = spell.id in spellReadyAt)
                    if (*at > now)
                        return SpellCastResult.notReady;
            // The category of a cast from an item is the item's if it names one (a Swiftness Potion's is the
            // healing potions' 4, though its spell has none: `Player::IsSpellReady` with the item).
            if (const category = cooldownCategoryOf(spell, itemEntry))
                if (const at = category in categoryReadyAt)
                    if (*at > now && !cooldownCheat)
                        return SpellCastResult.notReady;
            if (spell.casting.startRecoveryCategory == 133 && gcdReadyAt > now && !cooldownCheat)
                return SpellCastResult.notReady;
            // Its school locked out by an interrupt: only a spell that silence stops (`PreventionType`), not
            // Arcane Shot or a Serpent Sting (`WorldObject::IsSpellReady`).
            if (spell.casting.preventionType == 1 && spell.casting.school < schoolLockedUntil.length
                    && schoolLockedUntil[spell.casting.school] > now && !cooldownCheat)
                return SpellCastResult.notReady;
            if ((spell.attributes & spellAttrNotInCombat) && inCombat)
                return SpellCastResult.affectingCombat;
            if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0 && !(spell.attributes & castableWhileSitting))
                return SpellCastResult.notStanding;
            // The item the spell needs worn (a fishing pole, a ranged weapon to shoot).
            if (spell.equippedItemClass >= 0 && !hasItemFitToSpell(spell))
                return SpellCastResult.equippedItemClass;
            const attributeResult = checkCastAttributes(spell, targets);
            if (attributeResult != SpellCastResult.ok)
                return attributeResult;
        }
        if (start && !triggered)
        {
            const petResult = petCastCheck(spell, targets);
            if (petResult != SpellCastResult.ok)
                return petResult;
        }
        // The target the effects need (a triggered spell's at any range: the range check is not for it).
        const result = checkTarget(spell, targets, triggered, targetReplica, playerHandoff);
        if (result != SpellCastResult.ok)
            return result;
        if (!triggered && !preflight)
        {
            const classResult = classCastCheck(spell, targets); // `dmangos.world.classspells`
            if (classResult != SpellCastResult.ok)
                return classResult;
        }
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
        // An item: disenchanted, its lock picked (`dmangos.world.professions`).
        const itemResult = checkItemTarget(spell, targets, itemEntry, start);
        if (itemResult != SpellCastResult.ok)
            return itemResult;
        // Its spell focus near (an anvil, a forge, a fire), then reagents, then tools in the bags.
        const focusResult = checkSpellFocus(spell);
        if (focusResult != SpellCastResult.ok)
            return focusResult;
        if (!triggered && itemEntry == 0)
        {
            const cost = costOf(*spell);
            // Health as the power (Bloodrage, Health Funnel): more than it costs, or `CASTER_AURASTATE`.
            if (spell.casting.powerType == powerHealth)
            {
                if (cost > 0 && player.values.get!UNIT_FIELD_HEALTH <= cost)
                    return SpellCastResult.casterAuraState;
            }
            else if (cost > 0 && (spell.casting.powerType >= maxPowers
                    || player.values.get!UNIT_FIELD_POWER1(cast(Power) spell.casting.powerType) < cost))
                return SpellCastResult.noPower;
            foreach (i, reagent; spell.reagents)
                if (reagent > 0 && player.inventory.count(reagent) < spell.casting.reagentCount[i])
                    return SpellCastResult.reagents;
            if (!hasAmmoFor(spell))
                return SpellCastResult.noAmmo;
        }
        if (!triggered)
        {
            const toolResult = checkTools(spell);
            if (toolResult != SpellCastResult.ok)
                return toolResult;
        }
        // The spell's script needs the authoritative target and runs on its node after the handoff.
        if (preflight)
            return SpellCastResult.ok;
        // Last, the spell's script may refuse it (CMaNGOS's `OnCheckCast`): a capture's creature, a camera's turtle.
        {
            import dmangos.script.api : CastChecked, CastRefusal, EntityRef;

            CastRefusal refusal;
            if (spellScriptEvent(spell, CastChecked(EntityRef(player.guid), EntityRef(targets.unit)), refusal))
                return cast(SpellCastResult) refusal;
        }
        // At the trade window's "will not be traded" item: kept for the trade's end (`dmangos.world.tradehandlers`).
        if (targets.mask & TargetFlags.tradeItem)
            return tradeSpellCheck(spell, targets, itemEntry);
        return SpellCastResult.ok;
    }

    /**
     * What the caster's state refuses (CMaNGOS's `CheckCasterAuras`): nothing while stunned, feared or disoriented,
     * no silence-type spell silenced, no pacify-type ability pacified; but a spell that frees from it (Will of the
     * Forsaken, Escape Artist, the insignia: an immunity to a mechanic, or its dispel) may be cast.
     */
    SpellCastResult crowdControlRefusal(const(SpellInfo)* spell)
    {
        enum uint states = UnitFlags.stunned | UnitFlags.silenced | UnitFlags.pacified | UnitFlags.fleeing
            | UnitFlags.confused;
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        if (!(flags & states))
            return SpellCastResult.ok;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.dispelMechanic
                    || (spell.effect[i] == SpellEffect.applyAura
                        && (spell.casting.applyAuraName[i] == AuraType.mechanicImmunity
                            || spell.casting.applyAuraName[i] == AuraType.mechanicImmunityMask)))
                return SpellCastResult.ok;
        import dmangos.world.spellcast : preventionPacify, preventionSilence;

        if (flags & UnitFlags.stunned)
            return SpellCastResult.stunned;
        if ((flags & UnitFlags.silenced) && spell.casting.preventionType == preventionSilence)
            return SpellCastResult.silenced;
        if ((flags & UnitFlags.pacified) && spell.casting.preventionType == preventionPacify)
            return SpellCastResult.pacified;
        if (flags & UnitFlags.fleeing)
            return SpellCastResult.fleeing;
        if (flags & UnitFlags.confused)
            return SpellCastResult.confused;
        return SpellCastResult.ok;
    }

    /**
     * What a spell's attributes ask of the caster and its target as the cast starts (CMaNGOS's `Spell::CheckCast`
     * and `GetErrorAtShapeshiftedCast`): its form, outdoors, stealth, a weapon in the main hand; behind the
     * target (Backstab), facing it, a target out of combat (Sap).
     */
    SpellCastResult checkCastAttributes(const(SpellInfo)* spell, const ref SpellTargets targets)
    {
        import dmangos.world.clientdata : actsAsShapeshifted;
        import dmangos.world.combat : hasInArc;
        import dmangos.world.defines : equipmentSlotMainhand;
        import dmangos.world.player : PlayerFlags;

        enum : uint
        {
            isAbility = 0x10, onlyOutdoors = 0x8000, notShapeshift = 0x10000, onlyStealthed = 0x20000,
            doNotSheath = 0x40000, cancelsAutoAttack = 0x100000,                       // Attributes
            initiatesCombat = 0x200, onlyPeacefulTargets = 0x100,                      // AttributesEx
            allowWhileNotShapeshifted = 0x00080000, initiateCombatPostCast = 0x100000, // AttributesEx2
            requiresMainHand = 0x400,                                                  // AttributesEx3
        }
        // Its form: a stance (or Stealth, Shadowform) is cast as unshifted; Cat or Bear Form are not.
        const form = player.values.getByte!UNIT_FIELD_BYTES_1(2);
        const formMask = form ? 1u << (form - 1) : 0;
        if (formMask & spell.casting.stancesNot)
            return SpellCastResult.notShapeshift;
        if (!(formMask & spell.stances))
        {
            if (actsAsShapeshifted(context.client, form))
            {
                if (spell.attributes & notShapeshift)
                    return SpellCastResult.notShapeshift;
                if (spell.stances)
                    return SpellCastResult.onlyShapeshift;
            }
            else if (spell.stances && !(spell.attributesEx2 & allowWhileNotShapeshifted))
                return SpellCastResult.onlyShapeshift;
        }
        if ((spell.attributes & onlyOutdoors) && !player.hasFlag(PlayerFlags.gm))
            if (auto terrain = map.collision)
                if (terrain.hasVmaps)
                {
                    const p = player.position;
                    if (!terrain.isOutdoors(p.x, p.y, p.z + 2.0f))
                        return SpellCastResult.onlyOutdoors;
                }
        if ((spell.attributes & onlyStealthed) && !player.auras.hasType(AuraType.modStealth))
            return SpellCastResult.onlyStealthed;
        if (spell.casting.attributesEx3 & requiresMainHand)
        {
            const weapon = player.inventory.equipped(equipmentSlotMainhand);
            if (weapon is null || weapon.proto.itemClass != 2 || weapon.durability == 0 && weapon.maxDurability
                    || (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.disarmed))
                return SpellCastResult.equippedItemClassMainhand;
        }
        // Its target: where it stands to the caster, and whether it fights.
        if (targets.unit == 0 || targets.unit == player.guid)
            return SpellCastResult.ok;
        auto other = map.unit(targets.unit);
        if (!other)
            return SpellCastResult.ok;
        const me = player.position, it = other.position;
        enum ulong pounce = 0x20000;
        enum uint familyDruid = 7;
        if ((spell.attributesEx & initiatesCombat) && (spell.attributesEx2 & initiateCombatPostCast)
                && !(spell.casting.spellFamilyName == familyDruid && (spell.casting.spellFamilyFlags & pounce)))
            if (hasInArc(it, me) || !hasInArc(me, it)) // seen by it, or not facing it: not at its back
                return SpellCastResult.notBehind;
        if (spell.attributes == (isAbility | notShapeshift | doNotSheath | cancelsAutoAttack) && !hasInArc(me, it))
            return SpellCastResult.notInfront; // Gouge
        if ((spell.id in context.data.spellFacing) && !hasInArc(me, it))
            return SpellCastResult.unitNotInfront;
        if ((spell.attributesEx & onlyPeacefulTargets) && (other.unitFlags & UnitFlags.inCombat))
            return SpellCastResult.targetAffectingCombat; // Sap, Distract
        return SpellCastResult.ok;
    }

    /**
     * Whether `target` may be skinned by this player: a creature, dead, looted, with its skin on, and
     * the player's skill high enough for its level (`professions.skinningSkillFor`).
     */
    SpellCastResult checkSkinning(ulong target)
    {
        import dmangos.world.professions : skinningSkillFor;

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
        if (skinningSkillFor(level) > value)
            return SpellCastResult.lowCastLevel;
        return SpellCastResult.ok;
    }

    /**
     * The skinning effect: the creature's skin as loot for this player alone (`skinning_loot_template`),
     * a chance to improve the skill (twice for elites), and the corpse no longer skinnable; once the
     * skin is all taken, the corpse goes.
     */
    package void skinCreature(ulong target)
    {
        import dmangos.world.loot : ClientLootType, Loot, LootRule;
        import dmangos.world.loothandlers : bindCreatureLoot;
        import dmangos.world.professions : skinningSkillFor;

        auto creature = cast(Creature) map.findObject(target);
        if (creature is null || !creature.skinnable)
            return;
        const t = creature.template_;
        auto loot = new Loot(creature.guid, null);
        loot.clientType = ClientLootType.pickpocketing; // the window a skin's loot opens in
        loot.owners[player.guid] = true;
        loot.currentLooter = player.guid;
        loot.rule = LootRule.notGroup;
        if (const template_ = context.data.loot.skinning[t.skinningLootId])
            loot.fill(template_, context.data.loot, context.data.items, map.random, (uint condition) => conditionMet(condition),
                (ulong, const LootItem item) => item.condition == 0 || conditionMet(item.condition));
        // The skill: a chance to rise by the level's requirement, the one `checkSkinning` asked for.
        const required = skinningSkillFor(cast(int) creature.values.get!UNIT_FIELD_LEVEL);
        const skill = creature.skinningSkill;
        enum uint rankNormal = 0, rankRare = 4;
        updateGatherSkill(skill, player.skillValue(skill)[0], required,
            t.rank != rankNormal && t.rank != rankRare ? 2 : 1);
        creature.values.set!UNIT_FIELD_FLAGS(creature.values.get!UNIT_FIELD_FLAGS & ~Creature.unitFlagSkinnable);
        creature.skinned = true;
        creature.loot = loot;
        bindCreatureLoot(context, map, creature, loot);
        context.saveCorpseLoot(creature);
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
    package void pickPocket(ulong target)
    {
        import std.random : uniform;
        import dmangos.world.loot : ClientLootType, Loot, LootRule;
        import dmangos.world.loothandlers : bindCreatureLoot;

        auto creature = cast(Creature) map.findObject(target);
        if (creature is null || !creature.alive || !creature.template_.pickpocketLootId)
            return;
        if (creature.loot is null)
            context.restorePickpocket(map, creature);
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
            creature.pocketsRestockAt = 0;
        }
        if (creature.loot is null)
        {
            auto loot = new Loot(creature.guid, null);
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
            bindCreatureLoot(context, map, creature, loot);
        }
        if (creature.loot.checkpoint !is null && !creature.loot.checkpoint())
            return;
        if (lootTarget && lootTarget != creature.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        creature.loot.showContentTo(this);
    }

    /// The power `spell` costs this player.
    package int costOf(const ref SpellInfo spell)
    {
        if (powerCheat)
            return 0;
        const level = player.data.level;
        const createMana = player.stats.baseMana, createHealth = player.stats.baseHealth;
        const maxPower = spell.casting.powerType < maxPowers
            ? player.values.get!UNIT_FIELD_MAXPOWER1(cast(Power) spell.casting.powerType) : 0;
        enum uint drainAllPower = 0x2; // SPELL_ATTR_EX_DRAIN_ALL_POWER: Lay on Hands takes all the mana
        if ((spell.attributesEx & drainAllPower) && spell.casting.powerType < maxPowers)
            return cast(int) player.values.get!UNIT_FIELD_POWER1(cast(Power) spell.casting.powerType);
        int cost = spellMod(SpellModOp.cost, &spell, powerCost(spell, level, createMana, createHealth, maxPower));
        // `MOD_POWER_COST_SCHOOL_PCT` of its school (the Spirit of Redemption's holy spells free).
        if (spell.casting.school < 7)
            if (const percent = player.auras.totalByMiscMask(AuraType.modPowerCostSchoolPct, 1 << spell.casting.school))
                cost = cost * (100 + percent) / 100;
        return max(0, cost);
    }

    /// Whether the effects' implicit targets have what they need: an enemy, a friend, any unit, in range and sight.
    SpellCastResult checkTarget(const(SpellInfo)* spell, const ref SpellTargets targets, bool triggered = false,
        const(Replica) targetReplica = null, bool playerHandoff = false)
    {
        bool needsEnemy, needsUnit;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == 0)
                continue;
            const a = spell.implicitTargetA[i];
            if (a == ImplicitTarget.enemy)
                needsEnemy = true;
            else if (a == ImplicitTarget.unit || a == ImplicitTarget.friend || a == ImplicitTarget.unitRaid
                    || a == ImplicitTarget.unitFriendChainHeal)
                needsUnit = true;
        }
        if (!needsEnemy && !needsUnit)
            return SpellCastResult.ok;
        // A resurrection: at a dead player (or its corpse, which stands for it), never the living.
        const raising = spell.hasEffect(SpellEffect.resurrect) || spell.hasEffect(SpellEffect.resurrectNew);
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
        if (!map.questSpawnVisible(player, guid))
            return SpellCastResult.badTargets;
        auto creature = cast(Creature) map.findObject(guid);
        Position at;
        float reach;
        if (creature !is null)
        {
            if (playerHandoff)
                return SpellCastResult.badTargets;
            if (!creature.alive && !spell.hasEffect(SpellEffect.skinning))
                return SpellCastResult.targetsDead;
            if (needsEnemy && !canAttack(relatingNow(), creature.ai.relatingOf(), context.client))
                return SpellCastResult.targetFriendly;
            at = creature.position;
            reach = creature.values.get!UNIT_FIELD_COMBATREACH;
        }
        else if (auto other = playerOnMap(guid))
        {
            if (playerHandoff)
            {
                if (other.transferring)
                    return SpellCastResult.badTargets;
                if (!needsEnemy && !isFriend(relatingNow(), other.relatingNow(), context.client))
                    return SpellCastResult.targetEnemy;
            }
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
        else if (targetReplica !is null)
        {
            const fields = &targetReplica.fieldsOf();
            if (!fields.get!UNIT_FIELD_HEALTH)
                return playerHandoff ? SpellCastResult.targetsDead : SpellCastResult.badTargets;
            if (playerHandoff)
            {
                const other = targetReplica.playerRelations(context.client);
                if (needsEnemy && !canAttack(relatingNow(), other, context.client))
                    return SpellCastResult.targetFriendly;
                if (!needsEnemy && !isFriend(relatingNow(), other, context.client))
                    return SpellCastResult.targetEnemy;
            }
            else if (fields.get!PLAYER_DUEL_ARBITER)
                return SpellCastResult.badTargets;
            at = targetReplica.position;
            reach = fields.get!UNIT_FIELD_COMBATREACH;
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
        import dmangos.world.spelldamage : isChainHealEffect, isHostileAreaEffect, isHostileChainEffect, spellJumpRadius;
        import dmangos.world.spellselection : namedCreatureEntry, namedCreatureRange;

        // `TARGET_FLAG_UNIT`, `_UNIT_ENEMY`, `_UNIT_ALLY`, `_CORPSE_ENEMY`, `_UNIT_DEAD`, `_CORPSE_ALLY`: a spell's
        // `Targets` that let the client name a unit.
        enum uint unitTargetFlags = 0x0002 | 0x0080 | 0x0100 | 0x0200 | 0x0400 | 0x8000;
        const spell = c.spell;
        auto drain = !c.triggered ? remoteLeechTarget(spell, c.targets.unit) : null;
        const namedChannel = c.triggered ? size_t.max : context.namedCreatureChannel(spell);
        auto recipient = namedChannel == size_t.max ? UnitRef.init
            : scriptTargetNear(spell, context.namedCreatureEntries(spell, namedChannel), context.sendAreaDamage !is null);
        const recipientEntry = recipient ? namedCreatureEntry(recipient) : 0;
        const channelExclusions = recipient ? context.scriptTargetExclusions(spell.id, recipientEntry) : 0;
        auto remoteChannel = recipient.replica is null ? drain : recipient.replica;
        auto result = checkCast(spell, c.targets, c.triggered, c.castItemEntry, false, drain,
            c.playerHandoff || drain !is null);
        if (result == SpellCastResult.ok && namedChannel != size_t.max)
        {
            if (!recipient)
                result = SpellCastResult.badTargets;
            else if (!map.inLineOfSight(player.position, recipient.position))
                result = SpellCastResult.lineOfSight;
        }
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
        int paid; // the power it cost: most of it back for each target it missed (`DISCOUNT_POWER_ON_MISS`)
        bool cooldownStarted;
        if (!c.triggered)
        {
            // The cooldowns start: the item's, else the spell's; one that starts on an event (Presence of Mind,
            // Nature's Swiftness: `SPELL_ATTR_COOLDOWN_ON_EVENT`) when its aura ends (`cooldownEvent`), the spell
            // held in use until then.
            enum uint cooldownOnEvent = 0x02000000;
            if (spell.attributes & cooldownOnEvent && !cooldownCheat)
            {
                eventCooldowns[spell.id] = c.castItemEntry;
                spellReadyAt[spell.id] = MonoTime.max;
            }
            else
                cooldownStarted = startCooldown(spell, c.castItemEntry, now);
            // The power and reagents taken, and an item used up (`spellcharges` -1: one use).
            if (c.castItemEntry == 0)
            {
                const cost = costOf(*spell);
                paid = cost;
                if (cost > 0 && spell.casting.powerType == powerHealth)
                {
                    // Health as the power: taken as it is, no damage (`Spell::TakePower`); there was more.
                    const health = player.values.get!UNIT_FIELD_HEALTH;
                    player.values.set!UNIT_FIELD_HEALTH(health > cost ? health - cost : 1);
                    paid = 0;
                }
                else if (cost > 0 && spell.casting.powerType < maxPowers)
                {
                    player.modifyPower(cast(Power) spell.casting.powerType, -cost);
                    if (spell.casting.powerType == Power.mana)
                        player.manaSpent(); // the five-second rule
                }
                foreach (i, reagent; spell.reagents)
                    if (reagent > 0 && spell.casting.reagentCount[i])
                        player.inventory.destroyCount(reagent, spell.casting.reagentCount[i]);
            }
            else
                takeCastItem(c.castItemEntry, c.castItemGuid); // its charges, and the item if used up
            flushInventory();
        }

        // The targets of each effect, and whether each hostile one is hit.
        TargetResult[] results;
        RemotePartyHeal[] remoteHeals;
        RemoteAreaDamage[] remoteDamage;
        import dmangos.world.spelldamage : databaseSpellEffect, namedCreatureShape;
        import dmangos.world.spellselection : namedCreatureCenter, namedCreatureCone, namedCreatureRadius,
            namedCreatureEntry, namedCreaturesInArea, nearestNamedCreature;

        const namedEffect = context.namedCreatureRouting(spell);
        const entries = context.namedCreatureEntries(spell, namedEffect);
        c.gameObjectOrigin = player.position;
        const namedShape = namedEffect != size_t.max ? namedCreatureShape(*spell, namedEffect) : ImplicitTarget.none;
        const namedRange = namedEffect != size_t.max ? namedCreatureRadius(*spell, namedEffect, context.client) : 0;
        const routeNamed = context.sendAreaDamage !is null;
        Position namedCenter;
        bool hasNamedCenter;
        UnitRef[] scripted;
        bool visible(ulong guid) { return map.questSpawnVisible(player, guid); }
        if (namedShape == ImplicitTarget.unitScriptNearCaster)
        {
            namedCenter = player.position;
            if (auto near = nearestNamedCreature(map, namedCenter, namedRange, entries, 0, routeNamed, &visible))
                scripted = [near];
        }
        else if (namedShape != ImplicitTarget.none)
        {
            hasNamedCenter = namedCreatureCenter(*spell, namedEffect, context.client, map.id,
                player.position, spell.id in context.data.spellTargets, &c.targets, namedCenter);
            if (hasNamedCenter)
                scripted = namedCreaturesInArea(map, namedCenter, namedRange, entries, routeNamed,
                    spell.casting.maxAffectedTargets, namedShape, namedCreatureCone(context.data, spell.id), &visible);
        }
        const namedDestination = namedShape == ImplicitTarget.enumUnitsScriptAoeAtDestLoc && hasNamedCenter;
        const(SpellJump)[] spellChain;
        uint[ulong] bounceOf;
        SpellMissInfo[ulong] missOf;
        ulong[][3] effectTargets;
        Position objectDestination;
        bool hasObjectDestination;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == 0)
                continue;
            if (remoteChannel !is null)
                continue; // The channel's aura is installed on its target after the caster starts the channel.
            const a = spell.implicitTargetA[i];
            const objectShape = context.namedGameObjectRouting(spell, i);
            ulong[] targets;
            const remoteArea = !c.castTime && context.sendAreaDamage !is null
                && !(c.targets.mask & TargetFlags.sourceLocation) && isHostileAreaEffect(*spell, i);
            const area = spell.effect[i] == SpellEffect.persistentAreaAura ? null
                : areaTargets(spell, i, c.targets, remoteArea);
            if (spell.effect[i] == SpellEffect.persistentAreaAura) // SPELL_EFFECT_PERSISTENT_AREA_AURA: once, whoever stands there
                targets = [player.guid];
            else if (namedChannel != size_t.max)
            {
                if (!(channelExclusions & (1u << i)))
                    targets = [recipient.combatGuid];
            }
            else if (objectShape != ImplicitTarget.none)
            {
                Position center;
                targets = context.namedGameObjectTargets(map, spell, i, objectShape, c.gameObjectOrigin, center, &visible);
                if (objectShape == ImplicitTarget.enumGameobjectsScriptAoeAtDestLoc && targets.length)
                {
                    objectDestination = center;
                    hasObjectDestination = true;
                }
            }
            else if (area.length || isAreaTarget(spell, i))
                targets = area.dup; // an area, a cone, the party
            else if (a == ImplicitTarget.none && spell.casting.implicitTargetB[i] == ImplicitTarget.none
                    && c.targets.unit && (spell.casting.targets & unitTargetFlags))
                targets = [c.targets.unit]; // no implicit target: the one the client named, as its `Targets` let it
                                            // (CMaNGOS's `FillFromTargetFlags`: a resurrection at a dead player)
            else if (a == ImplicitTarget.caster || a == ImplicitTarget.none)
                targets = [player.guid];
            else if (a == ImplicitTarget.unitCasterPet) // TARGET_UNIT_CASTER_PET: Mend Pet, Health Funnel, Dark Pact
            {
                if (ownPet is null || !ownPet.alive)
                    continue;
                targets = [ownPet.guid];
            }
            else if (a == ImplicitTarget.enemy || a == ImplicitTarget.unit || a == ImplicitTarget.friend)
            {
                targets = [c.targets.unit ? c.targets.unit : player.guid];
                if (spell.casting.chainTarget[i] > 1 && a == ImplicitTarget.enemy)
                {
                    const chainDamage = isHostileChainEffect(*spell, i);
                    const chain = chainTargets(targets[0], spell.casting.chainTarget[i] - 1, chainDamage);
                    if (chainDamage)
                        spellChain = chain;
                    foreach (j; 1 .. chain.length)
                    {
                        const bounce = chain[j];
                        if (!bounce.peer)
                        {
                            targets ~= bounce.target;
                            if (chainDamage)
                                bounceOf[bounce.target] = cast(uint) j;
                            continue;
                        }
                        const previous = chain[j - 1];
                        const at = previous.position;
                        auto hit = AreaDamage(caster: player.guid, target: bounce.target, spell: spell.id,
                            effect: cast(ubyte) i, map: map.id, instance: map.instanceId, previous: previous.target,
                            x: at.x, y: at.y, z: at.z, radius: spellJumpRadius);
                        remoteDamage ~= RemoteAreaDamage(bounce.peer, hit, cast(uint) j);
                    }
                }
            }
            else if (a == ImplicitTarget.unitRaid || a == ImplicitTarget.unitFriendChainHeal)
            {
                // TARGET_UNIT_RAID, TARGET_UNIT_FRIEND_CHAIN_HEAL: the target if it may be helped, grouped or not
                // (CMaNGOS's `CanAssistSpell`: Power Word: Shield, Healing Wave at any friend); Chain Heal jumps on
                // to the most hurt friends near.
                const target = c.targets.unit ? c.targets.unit : player.guid;
                if (target != player.guid && !assistable(target))
                    continue;
                targets = [target];
                if (a == ImplicitTarget.unitFriendChainHeal && spell.casting.chainTarget[i] > 1)
                {
                    const chainHeal = isChainHealEffect(*spell, i);
                    auto group = chainHeal ? context.groups.of(player.guid) : null;
                    if (group !is null && !group.isMember(target))
                        group = null;
                    const chain = friendlyChainTargets(target, spell.casting.chainTarget[i] - 1, group);
                    if (chainHeal)
                        spellChain = chain;
                    foreach (j; 1 .. chain.length)
                    {
                        const bounce = chain[j];
                        if (!bounce.peer)
                        {
                            targets ~= bounce.target;
                            if (chainHeal)
                                bounceOf[bounce.target] = cast(uint) j;
                            continue;
                        }
                        const previous = chain[j - 1];
                        const at = previous.position;
                        const heal = PartyHeal(caster: player.guid, target: bounce.target, spell: spell.id,
                            effect: cast(ubyte) i, map: map.id, instance: map.instanceId, group: group.id,
                            previous: previous.target, x: at.x, y: at.y, z: at.z, radius: spellJumpRadius);
                        remoteHeals ~= RemotePartyHeal(bounce.peer, heal, cast(uint) j);
                    }
                }
            }
            else if (a == ImplicitTarget.gameObject || a == ImplicitTarget.gameObjectItem)
            {
                if (!c.targets.gameObject && !(a == ImplicitTarget.gameObjectItem && c.targets.item))
                    continue;
                targets = [c.targets.gameObject ? c.targets.gameObject : player.guid]; // an item: the caster's own
            }
            else if (namedShape != ImplicitTarget.none && namedCreatureShape(*spell, i) == namedShape)
            {
                foreach (creature; scripted)
                {
                    const entry = namedCreatureEntry(creature);
                    if (context.scriptTargetExclusions(spell.id, entry) & (1u << i))
                        continue;
                    if (creature.replica is null)
                        targets ~= creature.combatGuid;
                    else if (i == context.namedCreatureEffectFor(spell, namedEffect, entry))
                    {
                        auto hit = AreaDamage(caster: player.guid, target: creature.combatGuid, spell: spell.id,
                            effect: cast(ubyte) i, map: map.id, instance: map.instanceId,
                            x: namedCenter.x, y: namedCenter.y, z: namedCenter.z,
                            radius: namedRange, facing: namedCenter.orientation, namedCreature: true, triggered: c.triggered);
                        remoteDamage ~= RemoteAreaDamage(creature.replica.owner, hit);
                    }
                }
                if (!scripted.length && entries.length && namedShape == ImplicitTarget.unitScriptNearCaster
                    && !databaseSpellEffect(spell.effect[namedEffect]))
                    targets = [player.guid];
            }
            else if (a == ImplicitTarget.unitScriptNearCaster)
            {
                const near = scriptTargetNear(spell, context.spellScriptTargets(spell.id, i), false).combatGuid;
                if (!near && context.spellScriptTargets(spell.id).length && !context.spellScriptTargets(spell.id, i).length)
                    continue;
                targets = [near ? near : player.guid];
            }
            else
                targets = [player.guid]; // other targets: not yet; the caster stands in
            foreach (target; targets)
            {
                if (!visible(target))
                    continue;
                if (remoteArea)
                    if (auto replica = cast(Replica) map.findObject(target))
                    {
                        const center = player.position;
                        auto hit = AreaDamage(caster: player.guid, target: target, spell: spell.id,
                            effect: cast(ubyte) i, map: map.id, instance: map.instanceId, x: center.x, y: center.y,
                            z: center.z, radius: spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)));
                        remoteDamage ~= RemoteAreaDamage(replica.owner, hit);
                        continue;
                    }
                effectTargets[i] ~= target;
                if (target !in missOf)
                {
                    missOf[target] = c.custom.alwaysHits ? SpellMissInfo.none : rollHit(*spell, target);
                    results ~= TargetResult(target, missOf[target]);
                }
            }
            if (context.sendPartyHeal !is null)
                collectPartyHeals(spell, i, remoteHeals);
        }
        // The ammunition (or the thrown weapon) goes once the hits are rolled, as CMaNGOS's `Spell::cast` takes
        // it after `FillTargetMap`: the last throwing knife is thrown with the skill of the hand that held it.
        // An auto-repeating shot's is taken as it shoots.
        if (!c.triggered && c.castItemEntry == 0 && !autoRepeats(spell))
        {
            takeAmmo(spell);
            flushInventory();
        }
        enum uint notAnAction = 0x10000000; // SPELL_ATTR_EX2_NOT_AN_ACTION
        if (!c.triggered)
        {
            if (!(spell.attributesEx2 & notAnAction))
                interruptAurasOnCast(AuraInterrupt.actionLate, spell); // what a cast ends as it completes
            if (cooldownStarted)
                checkpointCooldowns();
            deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, SpellCastResult.ok));
        }
        auto displayedResults = results;
        if (remoteChannel !is null)
            displayedResults ~= TargetResult(remoteChannel.guid, SpellMissInfo.none);
        foreach (ref remote; remoteDamage)
            if (remote.hit.namedCreature)
                displayedResults ~= TargetResult(remote.hit.target, SpellMissInfo.none);
        if (spellChain.length && (remoteHeals.length || remoteDamage.length))
        {
            displayedResults = null;
            foreach (ref bounce; spellChain)
                displayedResults ~= TargetResult(bounce.target, missOf.get(bounce.target, SpellMissInfo.none));
        }
        else
            foreach (ref remote; remoteHeals)
                if (remote.heal.target !in missOf)
                {
                    missOf[remote.heal.target] = SpellMissInfo.none;
                    displayedResults ~= TargetResult(remote.heal.target, SpellMissInfo.none);
                }
        auto displayTargets = c.targets;
        if (namedDestination)
        {
            displayTargets.mask |= TargetFlags.destLocation;
            displayTargets.dest = [namedCenter.x, namedCenter.y, namedCenter.z];
        }
        else if (hasObjectDestination)
        {
            displayTargets.mask |= TargetFlags.destLocation;
            displayTargets.dest = [objectDestination.x, objectDestination.y, objectDestination.z];
        }
        map.sendToWatchers(this, Opcode.SMSG_SPELL_GO, spellGoPacket(player.guid, spell.id, displayedResults, displayTargets),
            true);
        spellCastScript(spell, c.targets.unit ? c.targets.unit : player.guid); // `OnCast`
        // A hostile spell landed on another player (a duel, world PvP): what that ends (`HOSTILE_ACTION`).
        foreach (r; results)
            if (r.miss == SpellMissInfo.none && r.guid != player.guid)
                if (auto other = playerOnMap(r.guid))
                    if (canAttack(relatingNow(), other.relatingNow(), context.client))
                        other.interruptAuras(AuraInterrupt.hostileAction);
        foreach (r; results)
            if (r.miss != SpellMissInfo.none)
            {
                map.sendToWatchers(this, Opcode.SMSG_SPELLLOGMISS, spellMissLog(spell.id, player.guid, r.guid, r.miss),
                    true);
                if (auto creature = cast(Creature) map.findObject(r.guid))
                    spellAttacked(creature, 0);
            }
        // A finishing move uses the combo points (its values, its duration), spent once it is done unless it
        // missed an enemy (CMaNGOS's `Spell::finish`).
        // (a cast within it, a proc's, leaves the finisher's as it was)
        const outerCombo = castCombo;
        castCombo = !c.triggered && usesComboPoints(*spell) ? comboPoints : 0;
        scope (exit)
            castCombo = outerCombo;
        // The modifiers with charges it has now: those that may be spent by it (`spendChargedMods`).
        Aura[] chargedAtStart;
        foreach (aura; player.auras.list)
            if (aura.charges)
                chargedAtStart ~= aura;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == SpellEffect.applyAreaAuraParty || spell.effect[i] == SpellEffect.applyAreaAuraPet) // on the caster, whoever else it reaches
                c.auraEffects[player.guid] |= cast(ubyte)(1 << i);
            else if (spell.effect[i] == SpellEffect.applyAura)
                foreach (target; effectTargets[i])
                    c.auraEffects[target] |= cast(ubyte)(1 << i);
        }
        // A missile (`speed`) reaches each target after its flight: the effects then.
        const pendingBefore = pendingHits.length;
        foreach (i; 0 .. 3)
            foreach (target; effectTargets[i])
                if (missOf[target] == SpellMissInfo.none)
                {
                    const flight = namedDestination && namedCreatureShape(*spell, i) == namedShape
                        ? flightTimeTo(spell, namedCenter) : flightTime(spell, target);
                    if (flight > 0)
                        pendingHits ~= PendingHit(spell, i, target, c, flight, bounceOf.get(target, 0));
                    else
                        doEffect(spell, i, target, c, bounceOf.get(target, 0));
                }
        foreach (ref remote; remoteHeals)
            sendRolledPartyHeal(spell, c, remote);
        foreach (ref remote; remoteDamage)
            sendRolledReplicaEffect(spell, c, remote);
        // A channelled spell goes on (`SPELL_ATTR_EX_IS_CHANNELED`, `_IS_SELF_CHANNELED`).
        enum uint channeled = 0x04, selfChanneled = 0x40;
        if ((spell.attributesEx & (channeled | selfChanneled)) && !c.triggered && !channelFailed)
        {
            startChannel(spell, recipient ? recipient.combatGuid : c.targets.unit ? c.targets.unit
                : results.length ? results[0].guid : 0); // (what it is
                // aimed at: Arcane Missiles' aura is on its caster)
            if (paid > 0 && spell.casting.powerType == Power.mana && channelSpell is spell)
                player.manaSpent(channelTimer); // the five-second rule: as long as the channel, if longer
            if (recipient.replica !is null && channelSpell is spell)
            {
                const at = player.position;
                namedChannelPeer = recipient.replica.owner;
                const first = context.namedCreatureEffectFor(spell, namedChannel, recipientEntry);
                auto hit = AreaDamage(channelToken: namedChannelSequence, caster: player.guid,
                    target: recipient.combatGuid, spell: spell.id,
                    effect: cast(ubyte) first, map: map.id, instance: map.instanceId,
                    x: at.x, y: at.y, z: at.z, radius: namedCreatureRange(*spell, context.client),
                    namedCreature: true, channelled: true);
                auto remote = RemoteAreaDamage(recipient.replica.owner, hit);
                if (!sendRolledReplicaEffect(spell, c, remote))
                    endChannel(true);
            }
            else if (recipient.creature !is null && channelSpell is spell)
            {
                if (auto aura = recipient.creature.auras.find(spell.id, player.guid))
                {
                    aura.channelToken = namedChannelSequence;
                    namedChannelConfirmed = true;
                }
                else
                    endChannel(true);
            }
            else if (drain !is null && channelSpell is spell)
                castProcAtReplica(spell, drain, c.custom, true);
        }
        channelFailed = false;
        // `SpellHit` for the creatures hit (their scripts).
        foreach (r; results)
            if (r.miss == SpellMissInfo.none)
                if (auto creature = cast(Creature) map.findObject(r.guid))
                    if (creature.alive && creature.ai !is null)
                        creature.ai.spellHitBy(player.guid, spell.id, 1u << spell.casting.school, map);
        // Quest objectives for a spell cast at a creature or game object (`ReqSpellCast`), a channel's when it ends.
        if (!(spell.attributesEx & (channeled | selfChanneled)) && !autoRepeats(spell) && !isNextMeleeSwingSpell(*spell))
            foreach (r; results)
                if (r.miss == SpellMissInfo.none)
                    rewardPlayerAndGroupAtCast(r.guid, spell.id);
        // The cast is over: the procs that wait for that (`PROC_EX_CAST_END`: Elemental Focus), on a harmful spell at an
        // enemy as such, else as a helpful one.
        if (!c.triggered && results.length)
        {
            import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

            bool harmful;
            UnitRef first;
            foreach (r; results)
                if (r.guid != player.guid)
                    if (auto u = map.unit(r.guid))
                    {
                        harmful |= canAttack(relatingNow(), u.relating, context.client);
                        if (!first)
                            first = u;
                    }
            procAuras(spellProcFlags(*spell, !harmful, false), first, ProcHit(spell, ProcEx.castEnd, 0, 0, harmful));
        }
        // A missile's that change what it does where it lands (Elemental Mastery's crit) are spent as it lands; the
        // others (Presence of Mind's cast time) now.
        import std.algorithm.iteration : filter;
        import std.algorithm.searching : any;
        import std.array : array;

        if (pendingHits.any!(h => h.spell is spell))
        {
            missileSpends ~= MissileSpend(spell, chargedAtStart.filter!(a => changesImpact(a)).array, c.triggered);
            spendChargedMods(spell, chargedAtStart.filter!(a => !changesImpact(a)).array, c.triggered);
        }
        else
            spendChargedMods(spell, chargedAtStart, c.triggered);
        // A rage or energy ability that missed, was dodged or parried costs a fifth (CMaNGOS's `Spell::finish`).
        enum uint discountPowerOnMiss = 0x08000000; // SPELL_ATTR_EX_DISCOUNT_POWER_ON_MISS
        if ((spell.attributesEx & discountPowerOnMiss) && paid > 0)
            foreach (r; results)
                if (r.miss == SpellMissInfo.miss || r.miss == SpellMissInfo.dodge || r.miss == SpellMissInfo.parry
                        || r.miss == SpellMissInfo.deflect)
                    player.modifyPower(cast(Power) spell.casting.powerType, cast(int)(paid * 0.8f));
        // What stops the caster's own attack (Gouge, Sap, Blind, Polymorph, Scatter Shot): its swings, its shots.
        enum uint cancelsAutoAttack = 0x00100000; // SPELL_ATTR_CANCELS_AUTO_ATTACK_COMBAT
        if (spell.attributes & cancelsAutoAttack)
        {
            if (spell.casting.dmgClass == DamageClass.ranged)
                stopAutoRepeat();
            stopAttack(false);
        }
        if (castCombo)
        {
            bool missedEnemy;
            foreach (r; results)
                missedEnemy |= r.miss != SpellMissInfo.none && r.guid != player.guid;
            if (!missedEnemy)
                clearComboPoints();
        }
        // Its scripts hear where it landed (`OnHit`), and the class rules do what follows it.
        ulong[] landed, dodgedBy;
        foreach (r; results)
        {
            spellLandedScript(spell, r.guid, r.miss != SpellMissInfo.none);
            if (r.miss == SpellMissInfo.none)
                landed ~= r.guid;
            else if (r.miss == SpellMissInfo.dodge && spell.casting.dmgClass == DamageClass.melee)
                dodgedBy ~= r.guid;
        }
        landedWithoutDamageProcs(spell, c.triggered, landed);
        trapEffectLanded(spell, landed); // Entrapment (dmangos.world.physicalclasses)
        classAfterEffects(spell, landed, dodgedBy);
        harmlessHitProcs(spell, landed);
        flushPlayerChanges();
        if (pendingHits.length > pendingBefore)
            checkpointSummons(true);
        return SpellCastResult.ok;
    }

    /// The hit roll at `target` (`dmangos.world.spelleffects.rollHit`).
    SpellMissInfo rollHit(const ref SpellInfo spell, ulong target)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spelleffects;

        auto me = Caster.of(this);
        return dmangos.world.spelleffects.rollHit(me, &spell, target == player.guid ? UnitRef.init : map.unit(target));
    }

    // -----------------------------------------------------------------------
    // Effects
    // -----------------------------------------------------------------------

    private static struct RemotePartyHeal
    {
        ushort peer;
        PartyHeal heal;
        uint bounce;
    }

    private static struct RemoteAreaDamage
    {
        ushort peer;
        AreaDamage hit;
        uint bounce;
    }

    private void rollAreaDamage(const(SpellInfo)* spell, const ref Casting c, ref RemoteAreaDamage remote)
    {
        import dmangos.world.combat : creatureTypes;
        import dmangos.world.spelldamage : SpellBounce;

        const school = spell.casting.school;
        auto hit = &remote.hit;
        const value = classSchoolDamage(spell, hit.effect, hit.target, effectAmount(spell, hit.effect));
        const base = max(0, value) + spellDamageBonus(spell, school);
        const damage = SpellBounce(spell.casting.dmgMultiplier[hit.effect], remote.bounce)
            .scale(spellMod(SpellModOp.damage, spell, base));
        uint creatureType = creatureTypeHumanoid;
        if (auto copy = cast(Replica) map.findObject(hit.target))
            if (copy.fields.type == TypeId.unit)
                if (const proto = copy.fields.get!OBJECT_FIELD_ENTRY in context.data.creatureTemplates)
                    creatureType = proto.creatureType;
        const versus = creatureType < creatureTypes ? player.damageMods.versus[creatureType] : 1;
        hit.amount = damage * player.damageMods.school[school] * versus;
        hit.threatFactor = player.damageMods.threat[school] * spellMod(SpellModOp.threat, spell, 1.0f);
        hit.critChance = spellCritOf(spell);
        hit.frozenCritBonus = frozenTargetCritBonus(spell);
        hit.resistanceModifier = player.auras.totalByMiscMask(AuraType.modTargetResistance, 1 << school);
        hit.suppressProcs = c.custom.by !is null;
        hit.critBonusFlat = spellMod(SpellModOp.critDamageBonus, spell, 0.0f);
        hit.critBonusFactor = spellMod(SpellModOp.critDamageBonus, spell, 1.0f) - hit.critBonusFlat;
    }

    private bool sendRolledReplicaEffect(const(SpellInfo)* spell, const ref Casting c, ref RemoteAreaDamage remote)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellauras : auraCast;
        import dmangos.world.spelldamage : crystalPrison, remoteTargetAuraEffects, rollHealing;

        auto hit = &remote.hit;
        const i = hit.effect;
        const outer = effectCustom;
        effectCustom = c.custom;
        scope (exit)
            effectCustom = outer;
        auto me = Caster.of(this);
        hit.casterLevel = player.data.level;
        hit.hitBonus = spellHitBonusOf(spell);
        hit.alwaysHits = hit.playerProjectile || c.custom.alwaysHits;
        const damage = spell.effect[i] == SpellEffect.schoolDamage;
        if (damage)
            rollAreaDamage(spell, c, remote);
        if (hit.channelled && spell.id == crystalPrison)
        {
            const school = spell.casting.school;
            hit.amount = cast(int) (effectAmount(spell, 0) * (school < 7 ? player.damageMods.threat[school] : 1));
        }
        const mask = spell.effect[i] == SpellEffect.applyAura || (damage && hit.namedCreature)
            ? remoteTargetAuraEffects(*spell, i) : 0;
        if (mask)
        {
            const aura = auraCast(me, spell, mask);
            hit.auraMs = aura.ms;
            hit.auraValues = aura.values;
            const school = spell.casting.school;
            foreach (j, type; spell.casting.applyAuraName)
                if ((mask & (1 << j)) && (type == AuraType.periodicDamage || type == AuraType.periodicLeech)
                    && school < 7)
                {
                    hit.threatFactor = player.damageMods.threat[school] * spellMod(SpellModOp.threat, spell, 1.0f);
                    hit.resistanceModifier = player.auras.totalByMiscMask(AuraType.modTargetResistance, 1 << school);
                    break;
                }
        }
        else if (!damage && spell.effect[i] == SpellEffect.heal)
        {
            const amount = spellMod(SpellModOp.damage, spell, effectAmount(spell, i));
            hit.amount = amount > 0 ? rollHealing(me, spell, amount, hit.critical) : 0;
        }
        return context.sendReplicaSpell(map, remote.peer, spell, *hit);
    }

    /// A proc's effects on a named target are applied where that target is simulated.
    package void castProcAtReplica(const(SpellInfo)* spell, Replica target,
        imported!"dmangos.world.classspells".CustomValues custom, bool channelled = false)
    {
        import dmangos.world.spelldamage : isTargetedProcEffect;

        if (context.sendAreaDamage is null || target.owner == context.nodeId)
            return;
        const at = player.position;
        Casting local;
        local.spell = spell;
        local.custom = custom;
        local.triggered = true;
        local.targets = SpellTargets(TargetFlags.unit, player.guid);
        foreach (i, effect; spell.effect)
            if (effect == SpellEffect.applyAura && spell.implicitTargetA[i] == ImplicitTarget.caster
                && spell.casting.implicitTargetB[i] == ImplicitTarget.none)
                local.auraEffects[player.guid] |= cast(ubyte)(1 << i);
        foreach (i, effect; spell.effect)
        {
            if (effect && spell.implicitTargetA[i] == ImplicitTarget.caster
                && spell.casting.implicitTargetB[i] == ImplicitTarget.none)
            {
                doEffect(spell, i, player.guid, local);
                continue;
            }
            if (!isTargetedProcEffect(*spell, i))
                continue;
            const within = spellMod(SpellModOp.range, spell, range(*spell, context.client)[1]);
            auto hit = AreaDamage(caster: player.guid, target: target.guid, spell: spell.id, effect: cast(ubyte) i,
                map: map.id, instance: map.instanceId, x: at.x, y: at.y, z: at.z,
                radius: within > 0 ? within : context.config.visibilityDistance, triggered: !channelled,
                channelled: channelled);
            auto remote = RemoteAreaDamage(target.owner, hit);
            sendRolledReplicaEffect(spell, local, remote);
        }
    }

    private void updateReplicaChannel(const(SpellInfo)* spell, Replica target, int remaining, ulong namedToken)
    {
        auto hit = AreaDamage(caster: player.guid, target: target.guid, spell: spell.id, map: map.id,
            instance: map.instanceId, namedCreature: namedToken != 0, channelled: true,
            channelUpdate: true, auraMs: remaining, channelToken: namedToken);
        context.sendReplicaSpell(map, target.owner, spell, hit);
    }

    private void collectPartyHeals(const(SpellInfo)* spell, size_t i, ref RemotePartyHeal[] found)
    {
        import dmangos.world.spelldamage : isPartyHealEffect, withinPartyHealRadius;

        if (!isPartyHealEffect(*spell, i))
            return;
        const group = context.groups.of(player.guid);
        if (group is null)
            return;
        const center = player.position;
        PartyHeal heal = {caster: player.guid, spell: spell.id, effect: cast(ubyte) i,
            map: map.id, instance: map.instanceId, group: group.id, x: center.x, y: center.y, z: center.z,
            radius: spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client))};
        const subGroup = group.subGroupOf(player.guid);
        foreach (ref member; group.members)
            if (member.subGroup == subGroup && context.onlinePlayer(member.guid) is null)
                if (auto replica = cast(Replica) map.findObject(member.guid))
                    if (replica.fields.type == TypeId.player && replica.owner != context.nodeId
                        && replica.fields.get!UNIT_FIELD_HEALTH && withinPartyHealRadius(heal, replica.position))
                    {
                        heal.target = member.guid;
                        found ~= RemotePartyHeal(replica.owner, heal);
                    }
    }

    private void sendRolledPartyHeal(const(SpellInfo)* spell, const ref Casting c, ref RemotePartyHeal remote)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spelldamage : rollHealing, SpellBounce;

        effectCustom = c.custom;
        scope (exit)
            effectCustom = typeof(effectCustom).init;
        const value = spellMod(SpellModOp.damage, spell, effectAmount(spell, remote.heal.effect));
        if (value > 0)
        {
            auto healer = Caster.of(this);
            remote.heal.amount = rollHealing(healer, spell, value, remote.heal.critical,
                SpellBounce(spell.casting.dmgMultiplier[remote.heal.effect], remote.bounce));
            remote.heal.threatFlat = spellMod(SpellModOp.threat, spell, 0.0f);
            remote.heal.threatFactor = spellMod(SpellModOp.threat, spell, 1.0f) - remote.heal.threatFlat;
            remote.heal.suppressProcs = c.custom.by !is null;
            remote.heal.sequence = context.nextGameplaySequence();
            context.sendPartyHeal(remote.peer, remote.heal);
        }
    }

    /// Effect `i` of the cast `c` on `target`: the effect stage every caster shares (`dmangos.world.spelleffects`).
    void doEffect(const(SpellInfo)* spell, size_t i, ulong target, ref Casting c, uint bounce = 0)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spelleffects : applyEffect;

        auto me = Caster.of(this);
        applyEffect(me, spell, i, target, c, bounce);
    }

    /**
     * The amount of effect `i` of `spell` as this player casts it: the cast's own (`effectCustom`) or rolled, more
     * for each combo point of a finishing move (`EffectPointsPerComboPoint`; Eviscerate 3% of the attack power a
     * point too: CMaNGOS's `EffectSchoolDMG`), with its modifiers (`effectMod`).
     */
    package int effectAmount(const(SpellInfo)* spell, size_t i)
    {
        int base = effectCustom.has(i) ? effectCustom.values[i] : effectValue(*spell, i, player.data.level, uniform01(map.random));
        if (castCombo)
        {
            base += cast(int)(spell.casting.pointsPerComboPoint[i] * castCombo);
            enum ulong eviscerate = 0x00020000;
            enum uint familyRogue = 8;
            if (spell.effect[i] == SpellEffect.schoolDamage && spell.casting.spellFamilyName == familyRogue
                    && (spell.casting.spellFamilyFlags & eviscerate))
                base += cast(int)(player.stats.attackPower * castCombo * 0.03f);
        }
        return effectMod(spell, i, base);
    }

    /**
     * `SPELL_EFFECT_SKIN_PLAYER_CORPSE` (Remove Insignia): a dead enemy's corpse (`TARGET_FLAG_PVP_CORPSE`), or its
     * body not yet released, within reach and marked for it.
     */
    package void removeInsigniaEffect(const ref SpellTargets targets)
    {
        import dmangos.world.corpse : Corpse, CorpseFlags;
        import dmangos.world.defines : UnitFlags;

        ulong owner = targets.unit;
        Position at;
        bool marked;
        if (auto body_ = targets.corpse ? cast(Corpse) map.findObject(targets.corpse) : null)
        {
            owner = body_.values.get!CORPSE_FIELD_OWNER;
            at = body_.position;
            marked = (body_.values.get!CORPSE_FIELD_FLAGS & CorpseFlags.lootable) != 0;
        }
        auto victim = owner ? playerOnMap(owner) : null;
        if (victim is null || victim is this
                || victim.player.deathState == DeathState.alive || victim.teamId == teamId)
            return;
        if (!targets.corpse)
        {
            at = victim.player.position;
            marked = (victim.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.skinnable) != 0;
        }
        const p = player.position;
        if (marked && (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 <= 10.0f ^^ 2)
            victim.removedInsignia(this);
    }

    /// An instant kill: `SMSG_SPELLINSTAKILLLOG` around, and damage of all the target's health.
    package void instakill(const(SpellInfo)* spell, ulong target)
    {
        ByteWriter w;
        w.put(target);
        w.put(spell.id);
        if (auto creature = cast(Creature) map.findObject(target))
        {
            if (!creature.alive)
                return;
            map.sendToWatchers(this, Opcode.SMSG_SPELLINSTAKILLLOG, w.data, true);
            const given = petSacrificed(spell, creature); // Demonic Sacrifice (dmangos.world.petauras)
            spellAttacked(creature, creature.values.get!UNIT_FIELD_HEALTH);
            if (given)
                if (const aura = context.data.spells.spell(given))
                    castSpell(aura, SpellTargets(TargetFlags.self, player.guid), true, 0);
            return;
        }
        auto other = target == player.guid ? this : playerOnMap(target);
        if (other is null || other.player.deathState != DeathState.alive)
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
            if (spellId in eventCooldowns)
                continue;
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
        // Held in use until an aura ends (CMaNGOS's permanent cooldown: 1, and the category's high bit).
        foreach (spellId, item; eventCooldowns)
        {
            InitialCooldown entry;
            entry.spell = cast(ushort) spellId;
            entry.item = cast(ushort) item;
            if (const info = context.data.spells.spell(spellId))
                entry.category = cast(ushort) cooldownCategoryOf(info, item);
            entry.spellMs = 1;
            entry.categoryMs = 0x80000000;
            list ~= entry;
        }
        return list;
    }

    /// A spell's cooldown cleared: `SMSG_CLEAR_COOLDOWN`, and the spell ready again.
    package void clearCooldownFor(uint spell)
    {
        bool changed = spellReadyAt.remove(spell);
        // The category it started (an item's own, as a potion's), else the spell's.
        if (const category = cooldownCategory.get(spell, 0))
            changed |= categoryReadyAt.remove(category);
        if (const info = context.data.spells.spell(spell))
            if (info.category)
                changed |= categoryReadyAt.remove(info.category);
        if (changed)
            checkpointCooldowns();
        ByteWriter w;
        w.put(spell);
        w.put(player.guid);
        deliver(Opcode.SMSG_CLEAR_COOLDOWN, w.data);
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
    package int modDuration(const(SpellInfo)* spell, int ms)
    {
        if (castCombo)
            if (const entry = context.client.spellDurations.lookup(spell.casting.durationIndex))
                ms = comboDuration(ms, entry.maximum, castCombo);
        return ms > 0 ? max(0, spellMod(SpellModOp.duration, spell, ms)) : ms;
    }

    /// The cooldowns of a cast of `spell` (from the item `itemEntry`, 0: none) start at `now`: the item's, else the spell's.
    private bool startCooldown(const(SpellInfo)* spell, uint itemEntry, MonoTime now)
    {
        int recovery = spell.recoveryTime, categoryRecovery = spell.categoryRecoveryTime;
        const category = cooldownCategoryOf(spell, itemEntry);
        if (itemEntry)
            if (const proto = itemEntry in context.data.items)
                foreach (i, ref use; proto.details.spells)
                    if (use.id == spell.id)
                    {
                        if (use.cooldown >= 0)
                            recovery = use.cooldown;
                        if (use.categoryCooldown >= 0)
                            categoryRecovery = use.categoryCooldown;
                        break;
                    }
        recovery = spellMod(SpellModOp.cooldown, spell, recovery);
        categoryRecovery = spellMod(SpellModOp.cooldown, spell, categoryRecovery);
        if (cooldownCheat || (recovery <= 0 && (!category || categoryRecovery <= 0)))
            return false;
        if (recovery > 0)
            spellReadyAt[spell.id] = now + recovery.msecs;
        if (category && categoryRecovery > 0)
            categoryReadyAt[category] = now + categoryRecovery.msecs;
        cooldownCategory[spell.id] = category && categoryRecovery > 0 ? category : 0;
        cooldownItem[spell.id] = itemEntry;
        return true;
    }

    private void checkpointCooldowns()
    {
        if (connection.gatewayHome.node && context.canWrite())
        {
            saveCooldowns();
            context.settleWrites();
        }
    }

    // -----------------------------------------------------------------------
    // Combo points
    // -----------------------------------------------------------------------

    /// The combo points (0 to 5) on `comboTarget`, built by Sinister Strike and the like, spent by finishing moves.
    package ubyte comboPoints;
    package ulong comboTarget;     /// ditto: whom they are on
    private ubyte castCombo; // the points the finishing move being cast uses (its value, its duration)

    /// A finishing move: it uses the combo points (`SPELL_ATTR_EX_FINISHING_MOVE_DAMAGE`, `_DURATION`).
    package static bool usesComboPoints(const ref SpellInfo spell) pure nothrow @nogc @safe
    {
        enum uint finishingDamage = 0x00100000, finishingDuration = 0x00400000;
        return (spell.attributesEx & (finishingDamage | finishingDuration)) != 0;
    }

    /// `count` combo points on `target` (CMaNGOS's `Unit::AddComboPoints`): added on the same target, else they
    /// start again on it; at most five.
    package void addComboPoints(ulong target, int count)
    {
        if (count == 0 || target == 0)
            return;
        dropRetainedComboPoints();
        const now = target == comboTarget ? comboPoints + count : count;
        comboTarget = target;
        comboPoints = cast(ubyte)(now < 0 ? 0 : now > 5 ? 5 : now);
        sendComboPoints();
    }

    /// The combo points are spent (or lost).
    package void clearComboPoints()
    {
        if (comboTarget == 0)
            return;
        dropRetainedComboPoints();
        comboPoints = 0;
        sendComboPoints();
        comboTarget = 0;
    }

    private bool droppingRetained; // the retaining auras go because the points changed: they keep their points

    /**
     * Premeditation's points (`SPELL_AURA_RETAIN_COMBO_POINTS`) are kept once others are added or they are spent:
     * its aura goes then without taking them back (CMaNGOS's `Unit::AddComboPoints`); expired, it takes them.
     */
    private void dropRetainedComboPoints()
    {
        droppingRetained = true;
        scope (exit)
            droppingRetained = false;
        foreach (aura; player.auras.list.dup)
            if (aura.has(AuraType.retainComboPoints))
                removeAura(aura);
    }

    /// A retaining aura ran out (`AURA_REMOVE_BY_EXPIRE`): its points go.
    package void retainedComboPointsExpired(int points)
    {
        if (!droppingRetained && comboTarget && points > 0)
            addComboPoints(comboTarget, -points);
    }

    private void sendComboPoints()
    {
        player.values.set!PLAYER__FIELD_COMBO_TARGET(comboTarget);
        player.values.setByte!PLAYER_FIELD_BYTES(1, comboPoints);
        flushPlayerChanges();
    }

    /// `spell` held in use until its aura ends (`cooldownEvent`), as after a login with the aura on.
    package void holdForCooldownEvent(const(SpellInfo)* spell)
    {
        if (spell.id !in eventCooldowns)
            eventCooldowns[spell.id] = 0;
        spellReadyAt[spell.id] = MonoTime.max;
    }

    /// The spells whose cooldown waits for their aura to end, with the item each was cast from.
    private uint[uint] eventCooldowns;

    /**
     * The aura of a spell whose cooldown starts on an event ended: its cooldown starts now, and the client's
     * (`SMSG_COOLDOWN_EVENT`, CMaNGOS's `SendCooldownEvent`).
     */
    package void cooldownEvent(const(SpellInfo)* spell)
    {
        const item = spell.id in eventCooldowns;
        if (item is null)
            return;
        const itemEntry = *item;
        eventCooldowns.remove(spell.id);
        spellReadyAt.remove(spell.id);
        if (startCooldown(spell, itemEntry, context.clock()))
            checkpointCooldowns();
        ByteWriter w;
        w.put(spell.id);
        w.put(player.guid);
        deliver(Opcode.SMSG_COOLDOWN_EVENT, w.data);
    }

    /// `value` of `spell`'s property `op`, with this player's spell modifiers (talents).
    package T spellMod(T)(SpellModOp op, const(SpellInfo)* spell, T value)
    {
        const modified = applySpellMod(player.auras.list, op, *spell, value);
        if (modified != value)
            noteChargedMods(op, spell);
        return modified;
    }

    /// The modifiers with charges (Clearcasting, Presence of Mind, Nature's Swiftness) that changed a cast of a
    /// spell, by spell: spent when that cast completes (`spendChargedMods`).
    private ChargedModUse[] chargedModsUsed;

    private struct ChargedModUse
    {
        Aura aura;
        uint spell;
    }

    private void noteChargedMods(SpellModOp op, const(SpellInfo)* spell)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.spellmods : affects;

        foreach (aura; player.auras.list)
        {
            if (aura.charges == 0 || aura.spell.id == spell.id)
                continue;
            foreach (i; 0 .. 3)
            {
                const type = aura.spell.casting.applyAuraName[i];
                if ((type == AuraType.addFlatModifier || type == AuraType.addPctModifier) && aura.misc(i) == op
                        && (aura.effects & (1 << i)) && affects(aura, i, *spell))
                {
                    // (a spell a dummy effect casts is its caster's: Holy Light's heal spends Divine Favor)
                    const owner = castingFor !is null ? castingFor.id : spell.id;
                    if (!chargedModsUsed.canFind!(u => u.aura is aura && u.spell == owner))
                        chargedModsUsed ~= ChargedModUse(aura, owner);
                    break;
                }
            }
        }
    }

    /**
     * A cast of `spell` completed: each modifier with charges that changed it loses one, and goes with its last
     * (CMaNGOS's `RemoveSpellMods`); only those it had as its effects began (not a Clearcasting it set off). A
     * triggered cast spends none.
     */
    private void spendChargedMods(const(SpellInfo)* spell, const(Aura)[] hadAtStart, bool triggered)
    {
        import std.algorithm.searching : canFind;

        auto used = chargedModsUsed;
        chargedModsUsed = null;
        foreach (u; used)
        {
            if (u.spell != spell.id)
            {
                chargedModsUsed ~= u; // another cast's, still going
                continue;
            }
            if (triggered || !hadAtStart.canFind!(a => a is u.aura) || !player.auras.list.canFind!(a => a is u.aura))
                continue;
            if (u.aura.charges > 1)
                --u.aura.charges;
            else
                removeAura(u.aura);
        }
    }

    /// An effect's value with the modifiers of its own index and of all effects (and the class rules': Permafrost).
    package int effectMod(const(SpellInfo)* spell, size_t i, int value)
    {
        return spellMod(SpellModOp.allEffects, spell, classEffectMod(spell, i, spellMod(effectOp(i), spell, value)));
    }

    /// `SPELL_EFFECT_DISPEL` by this player at `target` (0: itself) (`dmangos.world.spellauras.dispel`).
    package void dispelEffect(const(SpellInfo)* spell, size_t i, ulong target, int count)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellauras : dispel;

        auto me = Caster.of(this);
        dispel(me, spell, i, target == 0 ? unit : map.unit(target), count);
    }

    /**
     * A partial resist by a player of `level` with `resistance` (no level bonus, as a creature has): a share
     * of `damage` resisted (taken off it, and returned); a negative resistance adds to it instead.
     */
    package uint partialResist(ref uint damage, int resistance, uint level)
    {
        import std.random : uniform;
        import dmangos.world.combat : Fighter, partiallyResisted;

        Fighter victim;
        victim.player = true;
        victim.level = level;
        const r = partiallyResisted(damage, resistance, player.data.level, victim, false,
            uniform!"[]"(1u, 10000u, map.random));
        damage = r.damage;
        return r.resisted;
    }

    /**
     * A resurrection spell at a dead player (or its corpse): it is offered to come back beside this
     * player, with the effect's share (effect 18) or amounts (113: the value its health, the misc value
     * its mana) of health and mana.
     */
    package void resurrectEffect(const(SpellInfo)* spell, size_t i, ulong target, int value, const ref Casting c)
    {
        import dmangos.world.corpse : Corpse;
        import dmangos.world.player : DeathState;

        enum uint noResurrectTimer = 0x00000010; // SPELL_ATTR_EX3_NO_RES_TIMER
        ulong owner = target;
        if (c.targets.corpse)
            if (auto corpse = cast(Corpse) map.findObject(c.targets.corpse))
                owner = corpse.values.get!CORPSE_FIELD_OWNER;
        auto other = owner == player.guid ? null : playerOnMap(owner);
        if (other is null || other.player.deathState == DeathState.alive)
            return;
        const v = &other.player.values;
        uint health, mana;
        if (spell.effect[i] == SpellEffect.resurrectNew)
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

    /// ditto, for `spell`: and its modifiers' (`SPELLMOD_RESIST_MISS_CHANCE`: Arcane Focus, Suppression, Shadow Focus).
    package float spellHitBonusOf(const(SpellInfo)* spell)
    {
        return spellHitBonus + spellMod(SpellModOp.resistMissChance, spell, 0);
    }

    /// The crit chance of `spell`: this player's (`spellCrit`) and the spell's modifiers.
    /**
     * The crit chance of `spell` at `victim` (`Unit::RollSpellCritOutcome`): a melee or ranged ability's is its
     * weapon's, a spell's the spell crit; and what the class rules add (Shatter).
     */
    package float critChanceOf(const(SpellInfo)* spell, UnitRef victim)
    {
        float chance = spellCritOf(spell);
        if (victim && (spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged))
            chance = critChance(player.fighter, victim.fighter, spell.casting.dmgClass == DamageClass.ranged
                ? AttackType.ranged : AttackType.mainHand) + spellMod(SpellModOp.critChance, spell, 0);
        return chance + classCritBonus(spell, victim);
    }

    /// Whether `spell` is a melee or ranged ability: it crits as its weapon does.
    static bool weaponCrit(const(SpellInfo)* spell)
    {
        return spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged;
    }

    /// A crit's damage (`Caster.critDamage`).
    package uint critDamage(const(SpellInfo)* spell, uint damage)
    {
        import dmangos.world.caster : Caster;

        return Caster.of(this).critDamage(spell, damage);
    }

    package float spellCritOf(const(SpellInfo)* spell)
    {
        import dmangos.world.auras : AuraType;

        // And what auras add: to every spell's crit, and to its school's.
        return spellCrit() + spellMod(SpellModOp.critChance, spell, 0) + player.auras.total(AuraType.modSpellCritChance)
            + player.auras.totalByMiscMask(AuraType.modSpellCritChanceSchool, 1 << spell.casting.school);
    }

    /// The crit chance of this player's spells, from its intellect by class and level.
    float spellCrit()
    {
        // Intellect per percent at level 60 (14.77 + 60 × 0.65 = 53.77 a paladin's, 59.5 a mage's, 59.2 a priest's,
        // 59.5 a shaman's, 60.6 a warlock's, 60.0 a druid's) is Blizzard's (Tseric, docs/FORMULAS.md "Spell crit
        // from intellect"); the base and the slope by level are CMaNGOS's fit.
        static immutable float[3][12] table = [[0, 0, 10], [0, 0, 10], [3.70f, 14.77f, 0.65f], [0, 0, 10],
            [0, 0, 10], [2.97f, 10.03f, 0.82f], [0, 0, 10], [3.54f, 11.51f, 0.80f], [3.70f, 14.673f, 0.7471f],
            [3.18f, 11.30f, 0.82f], [0, 0, 10], [3.33f, 12.41f, 0.79f]];
        const row = table[player.data.classId < table.length ? player.data.classId : 0];
        const intellect = player.values.get!UNIT_FIELD_STAT0(Stat.intellect);
        return row[0] + intellect / (row[1] + row[2] * player.data.level);
    }

    /// The player `target`, if this player may attack it (a duel's opponent); null otherwise.
    package typeof(this) enemyPlayer(ulong target)
    {
        if (target == player.guid)
            return null;
        auto other = playerOnMap(target);
        if (other is null)
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

    /// Instance round 2: the nearest living creature within the spell's range (at least 5 yards) of an entry
    /// `spell_script_target` gives the spell; 0 if none.
    private UnitRef scriptTargetNear(const(SpellInfo)* spell, const(uint)[] entries, bool acrossNodes)
    {
        import dmangos.world.spellselection : namedCreatureRange, nearestNamedCreature;

        return nearestNamedCreature(map, player.position, namedCreatureRange(*spell, context.client),
            entries, 0, acrossNodes, (ulong guid) => map.questSpawnVisible(player, guid));
    }

    /**
     * The area targets: the enemies (creatures, and players it may fight)
     * within the effect's radius of the caster, of the destination, or in a cone in front (60 degrees
     * to either side); or the party members (and itself) within the radius. Empty for other targets.
     */
    ulong[] areaTargets(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, bool remoteEnemies = false)
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
        else if (kind == ImplicitTarget.enemiesAroundSource && (targets.mask & TargetFlags.sourceLocation))
            center = Position(targets.source[0], targets.source[1], targets.source[2]); // a trap's place
        // The target and its party (Prayer of Fortitude, Arcane Brilliance, Gift of the Wild: `TARGET_UNIT_FRIEND_AND_PARTY`),
        // around it.
        ulong partyOf = player.guid;
        if (kind == ImplicitTarget.unitFriendAndParty && targets.unit && targets.unit != player.guid)
            if (auto friend = map.find(targets.unit))
            {
                partyOf = targets.unit;
                center = friend.character.position;
            }
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
                    if (other.player !is null && other.player.alive && within(other.player.position))
                        found ~= other.player.guid;
            if (remoteEnemies)
                foreach (object; map.objectsNear(center, r))
                {
                    auto replica = cast(Replica) object;
                    if (remoteEnemy(replica) && within(replica.position))
                        found ~= replica.guid;
                }
            // At most `MaxAffectedTargets` ("Up to 5 total nearby enemies", Thunder Clap's "up to 4 targets"): the one
            // aimed at among them, then the nearest (the same for each of its effects).
            const most = spell.casting.maxAffectedTargets;
            if (most && found.length > most)
            {
                import std.algorithm.sorting : sort;

                double away(ulong guid)
                {
                    if (guid == targets.unit)
                        return -1;
                    const u = map.unit(guid);
                    const p = u ? u.position : map.findObject(guid).position;
                    return (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2;
                }
                found.sort!((x, y) => away(x) < away(y) || (away(x) == away(y) && x < y));
                found = found[0 .. most];
            }
            return found;
        }
        // The party (or every friend, here the party too) within the radius, itself included: in a raid, its own
        // subgroup's (`Spell::SetTargetMap`'s party targets).
        found ~= partyOf;
        if (auto group = context.groups.of(partyOf))
        {
            const subGroup = group.subGroupOf(partyOf);
            foreach (ref slot; group.members)
                if (slot.guid != partyOf && slot.subGroup == subGroup)
                    if (auto member = map.find(slot.guid))
                        if (within(member.character.position))
                            found ~= slot.guid;
        }
        return found;
    }

    static bool isAreaTargetKind(uint kind)
    {
        import std.algorithm.comparison : among;

        with (ImplicitTarget)
            return kind.among(enemiesAroundSource, enemiesAroundDest, enemiesInCone, partyAroundSource, partyInRange,
                friendsAroundSource, friendsAroundDest, party, unitFriendAndParty) != 0;
    }

    /// Whether this player may help `guid` with a spell: a unit here it may not attack.
    private bool assistable(ulong guid)
    {
        auto unit = map.unit(guid);
        return unit && unit.alive && !canAttack(relatingNow(), unit.relating(), context.client);
    }

    private bool remoteEnemy(Replica target)
    {
        if (target is null || target.owner == context.nodeId
            || (target.fields.type != TypeId.player && target.fields.type != TypeId.unit))
            return false;
        if (target.fields.type == TypeId.player && (context.onlinePlayer(target.guid) !is null || duelingWith(target.guid)))
            return false;
        const other = target.unitRelations(context.client);
        return other.alive && canAttack(relatingNow(), other, context.client);
    }

    private static struct SpellJump
    {
        ulong target;
        Position position;
        ushort peer;
    }

    /// From `first`, jump to the most injured eligible player within reach of the previous target.
    SpellJump[] friendlyChainTargets(ulong first, uint count, Group group)
    {
        import dmangos.world.spelldamage : spellJumpRadius;

        const initial = map.unit(first);
        if (!initial)
            return null;
        SpellJump[] chain = [SpellJump(first, initial.position)];
        bool[ulong] taken = [first: true];
        const caster = relatingNow();
        foreach (_; 0 .. count)
        {
            const at = chain[$ - 1].position;
            SpellJump next;
            uint largestDeficit;
            void consider(SpellJump candidate, uint deficit)
            {
                if (deficit > largestDeficit)
                {
                    largestDeficit = deficit;
                    next = candidate;
                }
            }
            foreach (other; map.playersNear(at, spellJumpRadius))
            {
                const guid = other.combatGuid;
                if (guid in taken || (group !is null && !group.isMember(guid)) || !assistable(guid))
                    continue;
                consider(SpellJump(guid, other.position), other.session.player.missingHealth);
            }
            if (group !is null && context.sendPartyHeal !is null)
                foreach (object; map.objectsNear(at, spellJumpRadius))
                {
                    auto replica = cast(Replica) object;
                    if (replica is null || replica.owner == context.nodeId || replica.fields.type != TypeId.player)
                        continue;
                    const guid = replica.guid;
                    if (guid in taken || !group.isMember(guid) || context.onlinePlayer(guid) !is null || duelingWith(guid))
                        continue;
                    if (!canAttack(caster, replica.playerRelations(context.client), context.client))
                        consider(SpellJump(guid, replica.position, replica.owner), replica.missingHealth);
                }
            if (!next.target)
                break;
            chain ~= next;
            taken[next.target] = true;
        }
        return chain;
    }

    /// Pick the closest eligible enemy to the last target, sharing the count across nodes.
    SpellJump[] chainTargets(ulong first, uint count, bool includePlayers)
    {
        import dmangos.world.spelldamage : spellJumpRadius;

        const initial = map.unit(first);
        if (!initial || (!includePlayers && initial.kind != UnitKind.creature))
            return null;
        SpellJump[] chain = [SpellJump(first, initial.position)];
        bool[ulong] taken = [first: true];
        foreach (_; 0 .. count)
        {
            const at = chain[$ - 1].position;
            SpellJump next;
            float best = spellJumpRadius ^^ 2;
            void consider(ulong guid, Position p, ushort peer = 0)
            {
                const d = (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2;
                if (d <= best && guid !in taken)
                {
                    best = d;
                    next = SpellJump(guid, p, peer);
                }
            }
            foreach (creature; map.creaturesNear(at, spellJumpRadius))
                if (spellEnemy(creature))
                    consider(creature.guid, creature.position);
            if (includePlayers)
            {
                foreach (other; map.playersNear(at, spellJumpRadius))
                    if (other.alive && !other.session.transferring && enemyPlayer(other.combatGuid) !is null)
                        consider(other.combatGuid, other.position);
                if (context.sendAreaDamage !is null)
                    foreach (object; map.objectsNear(at, spellJumpRadius))
                    {
                        auto replica = cast(Replica) object;
                        if (remoteEnemy(replica))
                            consider(replica.guid, replica.position, replica.owner);
                    }
            }
            if (!next.target)
                break;
            chain ~= next;
            taken[next.target] = true;
        }
        return chain;
    }

    /// A school's damage to a player (`dmangos.world.spelldamage.spellDamage`). Returns the damage dealt.
    package uint spellDamageToPlayer(const(SpellInfo)* spell, typeof(this) other, uint damage, bool withBonus = true,
        int modOp = -1)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spelldamage : SpellDamage;
        static import dmangos.world.spelldamage;

        auto me = Caster.of(this);
        return dmangos.world.spelldamage.spellDamage(me, spell, other.unit, damage, spell.casting.school,
            SpellDamage(withBonus, modOp));
    }

    /// The damage bonus of a direct spell (`dmangos.world.spelldamage.spellDamageBonus`).
    package uint spellDamageBonus(const(SpellInfo)* spell, uint school)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spelldamage;

        auto me = Caster.of(this);
        return dmangos.world.spelldamage.spellDamageBonus(me, spell, school);
    }


    /**
     * The caster's spell power for spells of the schools in `schoolMask` (`SpellBaseDamageBonusDone`): its
     * `MOD_DAMAGE_DONE` auras (each stack's: Unstable Power's twelve) and spirit's share (Spiritual Guidance).
     */
    package int spellPower(uint schoolMask)
    {
        import dmangos.world.auras : AuraType;

        return player.auras.totalByMiscMask(AuraType.modDamageDone, cast(int) schoolMask)
            + spellPowerFromSpirit(AuraType.modSpellDamageOfStatPercent, cast(int) schoolMask);
    }

    /// The caster's healing power: its `MOD_HEALING_DONE` auras (each stack's) and spirit's share.
    package int healingPower()
    {
        import dmangos.world.auras : AuraType;

        return player.auras.total(AuraType.modHealingDone) + spellPowerFromSpirit(AuraType.modSpellHealingOfStatPercent, -1);
    }

    /**
     * Spell power from a share of spirit (`MOD_SPELL_DAMAGE_OF_STAT_PERCENT` for the schools in `schoolMask`,
     * `MOD_SPELL_HEALING_OF_STAT_PERCENT`): Spiritual Guidance. 1.12's data names no stat; it is spirit, as
     * CMaNGOS has it.
     */
    int spellPowerFromSpirit(AuraType type, int schoolMask)
    {
        import dmangos.world.updatefields : UNIT_FIELD_STAT0;

        const percent = schoolMask == -1 ? player.auras.total(type) : player.auras.totalByMiscMask(type, schoolMask);
        if (percent <= 0)
            return 0;
        return cast(int)(player.values.get!UNIT_FIELD_STAT0(Stat.spirit) * percent / 100.0f);
    }

    /// A target's resistance to `school` as this caster's spells meet it (`Caster.targetResistance`).
    package int targetResistance(int resistance, uint school)
    {
        import dmangos.world.caster : Caster;

        return Caster.of(this).targetResistance(resistance, school);
    }

    /// The healing bonus (`dmangos.world.spelldamage.healingBonus`).
    package uint healingBonus(const(SpellInfo)* spell)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spelldamage;

        auto me = Caster.of(this);
        return dmangos.world.spelldamage.healingBonus(me, spell);
    }

    /**
     * `damage` with what auras make of it: the caster's for its school and the victim's creature type
     * (`MOD_DAMAGE_PERCENT_DONE`, `MOD_DAMAGE_DONE_VERSUS`), the victim's for the school (`taken`).
     */
    package uint spellDamageFactors(uint damage, uint school, uint victimType, const ref float[7] taken,
        const ref int[7] takenFlat)
    {
        import dmangos.world.combat : creatureTypes;

        if (school >= 7)
            return damage;
        const mods = &player.damageMods;
        const versus = victimType < creatureTypes ? mods.versus[victimType] : 1;
        const total = (damage * mods.school[school] * versus + takenFlat[school]) * taken[school];
        return total > 0 ? cast(uint) total : 0;
    }

    /// The crit chance more of a spell of `school` at the bearer of `auras` (`dmangos.world.spelldamage.spellCritTaken`).
    package static float spellCritTaken(A)(const ref A auras, uint school)
    {
        static import dmangos.world.spelldamage;

        return dmangos.world.spelldamage.spellCritTaken(auras, school);
    }

    /// A school's damage to a creature (`dmangos.world.spelldamage.spellDamage`; `periodic`: a persistent area's
    /// tick). Returns the damage dealt.
    package uint spellDamage(const(SpellInfo)* spell, Creature victim, uint damage, uint school, bool withBonus = true,
        int modOp = -1, bool periodic = false)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spelldamage : SpellDamage;
        static import dmangos.world.spelldamage;

        auto me = Caster.of(this);
        return dmangos.world.spelldamage.spellDamage(me, spell, map.unitOf(victim), damage, school,
            SpellDamage(withBonus, modOp, periodic));
    }

    /**
     * Weapon damage: the weapon's damage, plus the effect's bonus (or times its percentage),
     * less armor; a crit is double (the melee crit chance); a block takes off what the shield stops.
     */
    package void weaponSpellDamage(const(SpellInfo)* spell, size_t i, UnitRef victim, int value)
    {
        // Only the first weapon damage effect deals the damage; the others add to it.
        foreach (j; 0 .. i)
            if (spell.effect[j] == SpellEffect.weaponDamageNoschool || spell.effect[j] == SpellEffect.weaponDamage || spell.effect[j] == SpellEffect.normalizedWeaponDmg || spell.effect[j] == SpellEffect.weaponPercentDamage)
                return;
        const me = player.fighter, it = victim.fighter;
        enum uint spellAttrRanged = 0x2; // SPELL_ATTR_RANGED: the ranged slot's weapon (a wand's Shoot too)
        const type = spell.casting.dmgClass == DamageClass.ranged || (spell.attributes & spellAttrRanged)
            ? AttackType.ranged : AttackType.mainHand;
        float damage = weaponDamage(me, type, map.random);
        // A ranged attack's attack power against a marked victim (Hunter's Mark: `RANGED_ATTACK_POWER_ATTACKER_BONUS`),
        // at the weapon's speed as attack power counts (CMaNGOS's `MeleeDamageBonusDone`).
        if (type == AttackType.ranged)
            damage += rangedAttackerBonus(victim) / 14.0f * player.stats.attackTime[AttackType.ranged] / 1000;
        float percent = 100, fixed = 0;
        foreach (j; i .. 3)
        {
            const v = j == i ? value : effectMod(spell, j, effectValue(*spell, j, player.data.level, uniform01(map.random)));
            if (spell.effect[j] == SpellEffect.weaponDamageNoschool || spell.effect[j] == SpellEffect.weaponDamage || spell.effect[j] == SpellEffect.normalizedWeaponDmg)
                fixed += v;
            else if (spell.effect[j] == SpellEffect.weaponPercentDamage)
                percent = v;
        }
        // The fixed bonus is by the weapon percentage too, but Ambush's by its own (`EffectWeaponDmg`).
        const bonusFactor = classWeaponBonusFactor(spell);
        damage = damage * percent / 100 + fixed * (bonusFactor ? bonusFactor : percent / 100);
        // The ability's damage modifiers (Aggression, Opportunity: "increases the damage of your Sinister Strike"),
        // then what the auras of both make of a blow of its school, as of a swing (Enrage's more, Hemorrhage's).
        const school = spell.casting.school;
        damage = spellMod(SpellModOp.damage, spell, damage);
        {
            import dmangos.world.combat : damageFactor;

            damage *= damageFactor(me, it, type, school);
            if (school < 7 && it.damageTakenFlat[school])
                damage = max(0.0f, damage + it.damageTakenFlat[school] * it.damageTaken[school]);
        }
        // Armor takes off a physical strike's, not a holy one's (Seal of Command's: its spell's school).
        if (school == 0)
            damage = armorReducedDamage(me.level, armorAgainst(me, it), damage);
        // Its crit chance with the ability's modifiers (Improved Backstab, Cold Blood), its bonus with theirs (Impale).
        bool crit;
        if (uniform01(map.random) * 100 < critChanceOf(spell, victim))
        {
            crit = true;
            damage = critDamage(spell, cast(uint) damage);
        }
        uint blocked;
        if (uniform01(map.random) * 100 < blockChance(it, me, type))
            blocked = 0; // creatures carry no shield values yet
        uint total = damage > 0 ? cast(uint) damage : 0;
        const absorbed = victim.absorb(school, total);
        map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(target: victim.combatGuid, attacker: player.guid,
            spell.id, total, school, absorbed, 0, false, blocked, crit), true);
        enterCombatFor(combatLinger);
        final switch (victim.kind)
        {
        case UnitKind.none:
            break;
        case UnitKind.creature:
            spellAttacked(victim.creature, total, false, school);
            break;
        case UnitKind.player:
            import dmangos.world.unit : Blow, dealDamage;

            if (victim.alive)
                dealDamage(unit, victim, total, Blow.spell(school, crit));
            break;
        }
        spellHitProcs(spell, victim, crit, total, cast(ubyte) type);
    }

    /**
     * A harmful spell that deals no damage of its own (Counterspell, Polymorph, a curse, a damage over time as it
     * lands) reached the enemies `landed`: its caster's procs on each (Improved Counterspell's silence, Blackout); a
     * damaging one's are its hits' (`spellHitProcs`). They proc as on no damage (`ProcHit.damaging`).
     */
    private void harmlessHitProcs(const(SpellInfo)* spell, const(ulong)[] landed)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

        foreach (i; 0 .. 3)
            switch (spell.effect[i])
            {
            case SpellEffect.schoolDamage, SpellEffect.weaponDamage, SpellEffect.weaponDamageNoschool,
                    SpellEffect.normalizedWeaponDmg, SpellEffect.weaponPercentDamage, SpellEffect.healthLeech,
                    SpellEffect.powerBurn:
                return;
            default:
                break;
            }
        foreach (guid; landed)
        {
            if (guid == player.guid)
                continue;
            auto victim = map.unit(guid);
            if (!victim || !victim.alive || !hostileTo(victim))
                continue;
            procAuras(spellProcFlags(*spell, false, false), victim, ProcHit(spell, ProcEx.normalHit, 0, 0, false));
        }
    }

    /// This player's damaging spell (`spell`) hit `victim` for `damage`: its procs and the victim's
    /// (`dmangos.world.procs`, `victimAuraProcs`).
    package void spellHitProcs(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, ubyte hand = 0)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

        if (!victim || !victim.alive)
            return;
        const hit = ProcHit(spell, crit ? ProcEx.criticalHit : ProcEx.normalHit, damage, hand, damage != 0);
        const flags = spellProcFlags(*spell, false, false);
        procAuras(flags, victim, hit);
        if (victim.alive)
            victimAuraProcs(victim, flags, hit);
    }

    /**
     * This player's helpful `spell`, which deals no damage nor healing (a buff, a stance: Berserker Rage), landed on
     * `landed`: its procs of its kind as a hit of nothing (Improved Berserker Rage's rage). Those that ask for damage
     * do not take it (`effectProcsOn`); a harmful one's are `harmlessHitProcs`, a damaging one's its hits'.
     */
    private void landedWithoutDamageProcs(const(SpellInfo)* spell, bool triggered, const(ulong)[] landed)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

        if (triggered)
            return;
        foreach (e; [SpellEffect.schoolDamage, SpellEffect.weaponDamageNoschool, SpellEffect.weaponDamage,
                SpellEffect.normalizedWeaponDmg, SpellEffect.weaponPercentDamage, SpellEffect.heal,
                SpellEffect.healthLeech, SpellEffect.environmentalDamage])
            if (spell.hasEffect(e))
                return;
        foreach (target; landed)
        {
            auto other = target == player.guid ? unit : map.unit(target);
            if (target != player.guid && other && hostileTo(other))
                continue; // a harmful one's: `harmlessHitProcs`
            procAuras(spellProcFlags(*spell, true, false), other, ProcHit(spell, ProcEx.normalHit, 0, 0, false));
        }
    }

    /// A creature hit (or missed) by this player's spell, or its aura's tick: it fights back, takes the
    /// damage, and may die (`dmangos.world.unit.dealDamage`). The threat is less or more by `spell`'s modifiers
    /// (`SPELLMOD_THREAT`: Shadow Affinity).
    void spellAttacked(Creature victim, uint damage, bool tick = false, uint school = 0, const(SpellInfo)* spell = null)
    {
        import dmangos.world.unit : Blow, dealDamage;

        if (!victim.alive)
            return;
        enterCombatFor(combatLinger);
        auto blow = tick ? Blow.periodic(school) : Blow.spell(school);
        if (spell !is null)
            blow.threat = spellMod(SpellModOp.threat, spell, 1.0f);
        dealDamage(unit, map.unitOf(victim), damage, blow);
    }

    /// A heal of `target` (`dmangos.world.spelldamage.spellHeal`).
    package void heal(const(SpellInfo)* spell, ulong target, int value)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spelldamage : spellHeal;

        auto me = Caster.of(this);
        spellHeal(me, spell, map.unit(target), value);
    }


    /// The player's companion (a mini-pet: `SUMMON_CRITTER`), if out; 0 if none.
    package ulong companion;
    /// Far Sight's or Eagle Eye's spot, while the player sees from it; 0 if none.
    ulong farSightSpot;

    /**
     * `SUMMON_CRITTER` (CMaNGOS's `EffectSummonCritter`): the effect's creature beside the player, of its faction,
     * passive, immune to players and creatures, following it, for the spell's time (none: until sent away). The
     * same companion again sends it away; another takes its place.
     */
    package void summonCompanion(const(SpellInfo)* spell, size_t i)
    {
        import std.math : PI;
        import dmangos.script.api : EntityRef, Reaction;
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.movement : Position;
        import dmangos.world.spellcast : duration;
        import dmangos.world.updatefields;

        const entry = cast(uint) spell.miscValue[i];
        if (entry == 0)
            return;
        if (auto old = companion ? cast(Creature) map.findObject(companion) : null)
        {
            const same = old.template_.entry == entry;
            dismissCompanion();
            if (same)
                return;
        }
        const ms = duration(*spell, context.client, player.data.level);
        auto critter = context.summonCreature(map, entry, Position.init, ms > 0 ? TempSpawnType.timed : TempSpawnType.manual,
            ms > 0 ? ms : 0, player.guid);
        if (critter is null)
            return;
        companion = critter.guid;
        const faction = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        critter.factionTemplate = context.client.factionTemplates.lookup(faction);
        critter.values.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
        critter.values.set!UNIT_FIELD_SUMMONEDBY(player.guid);
        critter.values.set!UNIT_FIELD_CREATEDBY(player.guid);
        critter.values.set!UNIT_CREATED_BY_SPELL(spell.id);
        critter.values.set!UNIT_FIELD_FLAGS(critter.values.get!UNIT_FIELD_FLAGS | UnitFlags.immuneToPlayer
            | UnitFlags.immuneToNpc);
        critter.ai.bind(map);
        critter.ai.hostReactState(Reaction.passive);
        critter.ai.hostFollow(EntityRef(player.guid), 2, PI / 2);
        map.flushCreature(critter);
    }

    /// The companion goes (sent away, or its owner left the map or the world).
    package void dismissCompanion()
    {
        if (companion == 0)
            return;
        if (map !is null && map.findObject(companion) !is null)
            map.removeObject(companion);
        companion = 0;
    }

    /// A teleport: to the home bind (the hearthstone), or where the client chose.
    package void teleportUnits(const(SpellInfo)* spell, size_t i, ref Casting c)
    {
        const b = spell.casting.implicitTargetB[i];
        if (b == ImplicitTarget.homeBind || spell.implicitTargetA[i] == ImplicitTarget.homeBind)
        {
            const home = player.data.homeBind;
            commandTeleport(home.map, Position(home.x, home.y, home.z, player.position.orientation));
        }
        else if (b == ImplicitTarget.database || spell.implicitTargetA[i] == ImplicitTarget.database)
        {
            // The spell's own place (`spell_target_position`): a mage's teleports, a portal's.
            if (const to = spell.id in context.data.spellTargets)
                commandTeleport(to.map, to.at);
            else
                info!"%s: spell %s teleports to a place `spell_target_position` does not have"(remoteAddress, spell.id);
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
        s.effect[0] = cast(SpellEffect) effect; // the tests give raw ids, as the data does
        s.implicitTargetA[0] = cast(ImplicitTarget) target;
        s.basePoints[0] = value - 1;
        s.baseDice[0] = 1;
        s.casting.castingTimeIndex = castIndex;
        s.casting.rangeIndex = 1;
        s.casting.dmgClass = DamageClass.magic;
        return s;
    }
}

// Instant area damage shares its target cap across nodes and validates each remote hit at delivery.
unittest
{
    import core.time : MonoTime;
    import std.algorithm.searching : count;
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : makeAura;
    import dmangos.world.clientdata : chrRacesFormat, factionTemplateFormat, spellRadiusFormat;
    import dmangos.world.defines : Power;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.pvp : pvpFlagMs;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto origin = newCreationContext(db), owner = newCreationContext(db);
    origin.nodeId = 1;
    owner.nodeId = 2;
    auto now = MonoTime.currTime;
    origin.clock = owner.clock = () => now;
    enum uint blast = 55008, protection = 55009, shield = 55010, school = 6, cost = 12;
    uint[chrRacesFormat.length] human, orc;
    human[0] = raceHuman;
    human[2] = human[8] = 7; // faction template and team
    orc[0] = raceOrc;
    orc[2] = orc[8] = 1;
    foreach (node; [origin, owner])
    {
        node.client.races = typeof(node.client.races).parse(buildDbc(chrRacesFormat, [human[], orc[]]), "ChrRaces.dbc");
        node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[7u, 1, 0, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0], [1u, 2, 0, 4, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0]]),
            "FactionTemplate.dbc");
        const float radius = 20;
        uint[spellRadiusFormat.length] radiusRow;
        radiusRow[0] = 1;
        radiusRow[1] = *cast(const uint*) &radius;
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat, [radiusRow[]]),
            "SpellRadius.dbc");
        auto attack = testSpell(blast, SpellEffect.schoolDamage, ImplicitTarget.casterSource, 30);
        attack.casting.implicitTargetB[0] = ImplicitTarget.enemiesAroundSource;
        attack.casting.radiusIndex[0] = 1;
        attack.casting.maxAffectedTargets = 6;
        attack.casting.powerType = Power.mana;
        attack.casting.manaCost = cost;
        attack.casting.school = school;
        attack.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        attack.attributesEx2 |= spellAttrEx2CantCrit;
        attack.recoveryTime = 5_000;
        node.data.spells.spells[blast] = attack;
        auto penalty = testSpell(protection, SpellEffect.applyAura, ImplicitTarget.caster, -50);
        penalty.casting.applyAuraName[0] = AuraType.modDamagePercentTaken;
        penalty.miscValue[0] = 1 << school;
        node.data.spells.spells[protection] = penalty;
        auto immunity = testSpell(shield, SpellEffect.applyAura, ImplicitTarget.caster, 0);
        immunity.casting.applyAuraName[0] = AuraType.schoolImmunity;
        immunity.miscValue[0] = 1 << school;
        node.data.spells.spells[shield] = immunity;
    }
    const center = Position(100, 100, 40);
    auto caster = loggedIn(origin, db, 7, "Anduin", center, characterLevel: 20, setup: (ref c) {
        c.classId = classMage;
        c.power[Power.mana] = 80;
        c.spells = [NewSpell(blast, true)];
    });
    auto mage = cast(Player) caster.session.character;
    owner.map(0).replicaCreated(1, cellKeyAt(center.x, center.y), mage.guid, encodePlayerState(mage, 0));
    auto local_ = loggedIn(origin, db, 8, "Thrall", Position(center.x + 8, center.y, center.z),
        race: raceOrc, characterLevel: 20);
    auto localPlayer = cast(Player) local_.session.character;
    localPlayer.values.set!UNIT_FIELD_MAXHEALTH(100u);
    localPlayer.values.set!UNIT_FIELD_HEALTH(80u);
    local_.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);

    TestClient[ulong] targets;
    const string[] names = ["Durotan", "Orgrim", "Garrosh", "Eitrigg", "Nazgrel", "Rexxar", "Grom", "Jaina", "Saurfang"];
    foreach (i, float distance; [2, 3, 4, 5, 6, 12, 30, 1, 1])
    {
        const guid = cast(uint)(i + 9);
        const p = Position(center.x + distance, center.y, center.z);
        auto target = loggedIn(owner, db, guid, names[i], p, race: guid == 16 ? raceHuman : raceOrc,
            characterLevel: 20);
        auto player = cast(Player) target.session.character;
        player.values.set!UNIT_FIELD_MAXHEALTH(100u);
        player.values.set!UNIT_FIELD_HEALTH(guid == 10 ? 20u : 80u);
        if (guid != 17)
            target.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
        origin.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), guid, encodePlayerState(player, 0));
        targets[guid] = target;
    }
    auto protectedTarget = targets[9].session.inWorld;
    protectedTarget.addAura(makeAura(protection in owner.data.spells.spells, 9, 20, -1, true, [-50, 0, 0]));
    caster.read();

    AreaDamage[] requests, replies;
    origin.sendAreaDamage = (ushort peer, const ref AreaDamage hit) {
        assert(peer == 2 && !hit.reply);
        requests ~= cast(AreaDamage) hit;
        return true;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage result) {
        assert(peer == 1 && result.reply);
        replies ~= cast(AreaDamage) result;
        return true;
    };
    ByteWriter request;
    request.put(blast);
    request.put(cast(ushort) TargetFlags.self);
    const mana = mage.values.get!UNIT_FIELD_POWER1(Power.mana);
    caster.write(Opcode.CMSG_CAST_SPELL, request.data);
    assert(origin.onlinePlayer(7) is caster.session.inWorld);
    assert(mage.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost);
    assert(localPlayer.values.get!UNIT_FIELD_HEALTH == 50u);
    assert(requests.length == 5);
    foreach (i, ref hit; requests)
        assert(hit.target == i + 9, "near eligible targets win the shared cap");
    assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_GO) == 1);

    targets[11].write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
    targets[11].session.inWorld.updatePvPTimers(pvpFlagMs);
    targets[12].session.inWorld.addAura(makeAura(shield in owner.data.spells.spells, 12, 20, -1, true, [0, 0, 0]));
    auto moving = cast(Player) targets[13].session.character;
    moving.movement.position = Position(center.x + 40, center.y, center.z);
    owner.map(0).relocated(targets[13].session.inWorld);
    foreach (ref hit; requests)
    {
        owner.areaDamageArrived(1, hit);
        owner.areaDamageArrived(1, hit);
    }
    assert(targets[9].session.character.values.get!UNIT_FIELD_HEALTH == 65u, "the remote modifier is applied once");
    assert(targets[10].session.character.values.get!UNIT_FIELD_HEALTH == 0u, "a remote hit can kill");
    foreach (guid; 11 .. 18)
        assert(targets[guid].session.character.values.get!UNIT_FIELD_HEALTH == 80u);
    assert(replies.length == 3 && replies[0].damage == 15 && replies[1].killed
        && replies[2].miss == SpellMissInfo.immune);
    targets[11].write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
    owner.areaDamageArrived(1, requests[2]);
    moving.movement.position = Position(center.x + 6, center.y, center.z);
    owner.map(0).relocated(targets[13].session.inWorld);
    owner.areaDamageArrived(1, requests[4]);
    assert(targets[11].session.character.values.get!UNIT_FIELD_HEALTH == 80u
        && moving.values.get!UNIT_FIELD_HEALTH == 80u && replies.length == 3);

    foreach (ref result; replies)
    {
        origin.areaDamageArrived(2, result);
        origin.areaDamageArrived(2, result);
    }
    const packets = opcodesOf(caster.read());
    assert(packets.count(Opcode.SMSG_SPELLNONMELEEDAMAGELOG) == 2 && packets.count(Opcode.SMSG_SPELLLOGMISS) == 1);
    assert(packets.count(Opcode.SMSG_PVP_CREDIT) == 1, "remote kill attribution is credited once");
    assert(caster.session.inWorld.initialCooldowns().length == 1);
    caster.write(Opcode.CMSG_CAST_SPELL, request.data);
    assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(blast, SpellCastResult.notReady));
    assert(mage.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost && requests.length == 5);
}

// Chain Lightning shares its path, damage falloff and target cap between local and remote players.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : count;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.protocol : AreaDamage, decode, FrameHeader, MessageType, putMessage, takeFrame;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : makeAura;
    import dmangos.world.clientdata : chrRacesFormat, factionTemplateFormat, spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.defines : Power;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.pvp : pvpFlagMs;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    AreaDamage roundTrip(const ref AreaDamage hit)
    {
        ByteWriter w;
        putMessage(w, 1, hit);
        const(ubyte)[] bytes = w.data, payload;
        FrameHeader header;
        assert(takeFrame(bytes, header, payload) && header.type == MessageType.areaDamage && !bytes.length);
        return decode!AreaDamage(payload);
    }

    enum Scenario { bothRemote, lastLocal, movedAndUnflagged, immune }
    foreach (scenario; [Scenario.bothRemote, Scenario.lastLocal, Scenario.movedAndUnflagged, Scenario.immune])
    {
        auto db = newDatabase();
        auto origin = newCreationContext(db), owner = newCreationContext(db);
        origin.nodeId = 1;
        owner.nodeId = 2;
        auto now = MonoTime.currTime;
        origin.clock = owner.clock = () => now;
        enum uint chain = 421, shield = 55012, school = 3, cost = 12, castMs = 2_500;
        uint[chrRacesFormat.length] human, orc;
        human[0] = raceHuman;
        human[2] = human[8] = 7;
        orc[0] = raceOrc;
        orc[2] = orc[8] = 1;
        foreach (node; [origin, owner])
        {
            node.client.races = typeof(node.client.races).parse(buildDbc(chrRacesFormat, [human[], orc[]]), "ChrRaces.dbc");
            node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
                [[7u, 1, 0, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0], [1u, 2, 0, 4, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0]]),
                "FactionTemplate.dbc");
            node.client.spellCastTimes = typeof(node.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
                [[1u, castMs, 0, castMs]]), "SpellCastTimes.dbc");
            uint[spellRangeFormat.length] rangeRow;
            rangeRow[0] = 1;
            const float range = 30;
            rangeRow[2] = *cast(const uint*) &range;
            node.client.spellRanges = typeof(node.client.spellRanges).parse(buildDbc(spellRangeFormat, [rangeRow[]]),
                "SpellRange.dbc");
            auto attack = testSpell(chain, SpellEffect.schoolDamage, ImplicitTarget.enemy, 100, 1);
            attack.casting.rangeIndex = 1;
            attack.casting.chainTarget[0] = 3;
            attack.casting.dmgMultiplier[0] = 0.7f;
            attack.casting.school = school;
            attack.casting.powerType = Power.mana;
            attack.casting.manaCost = cost;
            attack.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
            attack.attributesEx2 |= spellAttrEx2CantCrit;
            attack.recoveryTime = 5_000;
            node.data.spells.spells[chain] = attack;
            auto immunity = testSpell(shield, SpellEffect.applyAura, ImplicitTarget.caster, 0);
            immunity.casting.applyAuraName[0] = AuraType.schoolImmunity;
            immunity.miscValue[0] = 1 << school;
            node.data.spells.spells[shield] = immunity;
        }

        const start = Position(100, 100, 40);
        auto caster = loggedIn(origin, db, 7, "Jaina", start, characterLevel: 40, setup: (ref c) {
            c.classId = classMage;
            c.power[Power.mana] = 80;
            c.spells = [NewSpell(chain, true)];
        });
        auto mage = cast(Player) caster.session.character;
        mage.values.set!UNIT_FIELD_POWER1(Power.mana, mage.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
        owner.map(0).replicaCreated(1, cellKeyAt(start.x, start.y), 7, encodePlayerState(mage, 0));
        TestClient target(uint guid, string name, float x, uint health, bool remote,
            ubyte race = raceOrc, bool flagged = true)
        {
            const p = Position(start.x + x, start.y, start.z);
            auto client = loggedIn(remote ? owner : origin, db, guid, name, p, race: race, characterLevel: 40);
            auto player = cast(Player) client.session.character;
            player.values.set!UNIT_FIELD_MAXHEALTH(300u);
            player.values.set!UNIT_FIELD_HEALTH(health);
            if (flagged)
                client.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
            if (remote)
                origin.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), guid, encodePlayerState(player, 0));
            return client;
        }
        auto first = target(8, "Thrall", 20, 260, false);
        auto second = target(9, "Durotan", 28, 60, true);
        auto third = target(10, "Orgrim", 36, 200, scenario != Scenario.lastLocal);
        auto fourth = target(11, "Garrosh", 44, 200, true);
        auto alternate = target(12, "Rexxar", 11, 200, false);
        auto friend = target(13, "Varian", 21, 200, true, raceHuman);
        auto unflagged = target(14, "Nazgrel", 22, 200, true, raceOrc, false);
        caster.read();

        AreaDamage[] requests, replies;
        origin.sendAreaDamage = (ushort peer, const ref AreaDamage hit) {
            assert(peer == 2 && !hit.reply);
            requests ~= roundTrip(hit);
            return true;
        };
        owner.sendAreaDamage = (ushort peer, const ref AreaDamage hit) {
            assert(peer == 1 && hit.reply);
            replies ~= roundTrip(hit);
            return true;
        };
        ByteWriter request;
        request.put(chain);
        request.put(cast(ushort) TargetFlags.unitEnemy);
        request.putPackedGuid(8);
        const mana = mage.values.get!UNIT_FIELD_POWER1(Power.mana);
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_START) == 1);
        now += (castMs - 1).msecs;
        caster.session.update((castMs - 1).msecs);
        assert(!requests.length && mage.values.get!UNIT_FIELD_POWER1(Power.mana) == mana);
        now += 1.msecs;
        caster.session.update(1.msecs);
        assert(mage.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost && origin.onlinePlayer(7) is caster.session.inWorld);
        assert(first.session.character.values.get!UNIT_FIELD_HEALTH == 160u);
        assert(requests.length == (scenario == Scenario.lastLocal ? 1 : 2));
        assert(requests[0].target == 9 && requests[0].previous == 8 && requests[0].x == start.x + 20 && requests[0].amount == 70);
        if (requests.length > 1)
            assert(requests[1].target == 10 && requests[1].previous == 9 && requests[1].x == start.x + 28
                && requests[1].amount == 49 && requests[1].sequence > requests[0].sequence);
        auto go = ByteReader(bodyOf(caster.read(), Opcode.SMSG_SPELL_GO));
        assert(go.readPackedGuid() == 7 && go.readPackedGuid() == 7 && go.read!uint == chain);
        go.read!ushort;
        assert(go.read!ubyte == 3 && go.read!ulong == 8 && go.read!ulong == 9 && go.read!ulong == 10);

        auto moving = cast(Player) second.session.character;
        const before = moving.position;
        if (scenario == Scenario.movedAndUnflagged)
        {
            third.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
            third.session.inWorld.updatePvPTimers(pvpFlagMs);
            moving.movement.position.x += 50;
            owner.map(0).relocated(second.session.inWorld);
        }
        if (scenario == Scenario.immune)
            third.session.inWorld.addAura(makeAura(shield in owner.data.spells.spells, 10, 40, -1, true, [0, 0, 0]));
        foreach (ref hit; requests)
        {
            owner.areaDamageArrived(1, hit);
            owner.areaDamageArrived(1, hit);
        }
        if (scenario == Scenario.movedAndUnflagged)
        {
            moving.movement.position = before;
            owner.map(0).relocated(second.session.inWorld);
            third.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
            foreach (ref hit; requests)
                owner.areaDamageArrived(1, hit);
            assert(!replies.length && moving.values.get!UNIT_FIELD_HEALTH == 60u
                && third.session.character.values.get!UNIT_FIELD_HEALTH == 200u);
            continue;
        }

        assert(replies.length == requests.length && replies[0].damage == 70 && replies[0].killed);
        if (scenario == Scenario.immune)
            assert(replies[1].miss == SpellMissInfo.immune);
        foreach (ref hit; replies)
        {
            origin.areaDamageArrived(2, hit);
            origin.areaDamageArrived(2, hit);
        }
        const packets = opcodesOf(caster.read());
        assert(packets.count(Opcode.SMSG_PVP_CREDIT) == 1);
        assert(packets.count(Opcode.SMSG_SPELLNONMELEEDAMAGELOG) == (scenario == Scenario.bothRemote ? 2 : 1));
        assert(packets.count(Opcode.SMSG_SPELLLOGMISS) == (scenario == Scenario.immune ? 1 : 0));
        assert(moving.values.get!UNIT_FIELD_HEALTH == 0u);
        assert(third.session.character.values.get!UNIT_FIELD_HEALTH == (scenario == Scenario.immune ? 200u : 151u));
        foreach (untouched; [fourth, alternate, friend, unflagged])
            assert(untouched.session.character.values.get!UNIT_FIELD_HEALTH == 200u);
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(chain, SpellCastResult.notReady));
    }
}

// Chain Heal follows one ordered path even when a bounce changes nodes.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : count;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.protocol : decode, FrameHeader, MessageType, PartyHeal, putMessage, takeFrame;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : makeAura;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.defines : Power;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : RemoveMethod;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    PartyHeal roundTrip(const ref PartyHeal heal)
    {
        ByteWriter w;
        putMessage(w, 1, heal);
        const(ubyte)[] bytes = w.data, payload;
        FrameHeader header;
        assert(takeFrame(bytes, header, payload) && header.type == MessageType.partyHeal && !bytes.length);
        return decode!PartyHeal(payload);
    }

    foreach (lastIsLocal; [false, true])
    {
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Thrall";
        party.members = [GroupMemberRecord(7, "Thrall"), GroupMemberRecord(8, "Durotan"),
            GroupMemberRecord(9, "Orgrim"), GroupMemberRecord(10, "Garrosh"), GroupMemberRecord(11, "Eitrigg")];
        db.groups[party.id] = party;
        auto origin = newCreationContext(db), owner = newCreationContext(db);
        origin.nodeId = 1;
        owner.nodeId = 2;
        auto now = MonoTime.currTime;
        origin.clock = owner.clock = () => now;
        enum uint chain = 1064, reduced = 55011, cost = 12, castMs = 2_500, cooldownMs = 5_000;
        foreach (node; [origin, owner])
        {
            node.client.spellCastTimes = typeof(node.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
                [[1u, castMs, 0, castMs]]), "SpellCastTimes.dbc");
            uint[spellRangeFormat.length] rangeRow;
            rangeRow[0] = 1;
            const float range = 40;
            rangeRow[2] = *cast(const uint*) &range;
            node.client.spellRanges = typeof(node.client.spellRanges).parse(buildDbc(spellRangeFormat, [rangeRow[]]),
                "SpellRange.dbc");
            auto heal = testSpell(chain, SpellEffect.heal, ImplicitTarget.unitFriendChainHeal, 80, 1);
            heal.casting.rangeIndex = 1;
            heal.casting.chainTarget[0] = 3;
            heal.casting.dmgMultiplier[0] = 0.5f;
            heal.casting.manaCost = cost;
            heal.casting.powerType = Power.mana;
            heal.recoveryTime = cooldownMs;
            heal.attributesEx2 |= spellAttrEx2CantCrit;
            node.data.spells.spells[chain] = heal;
            auto penalty = testSpell(reduced, SpellEffect.applyAura, ImplicitTarget.caster, -50);
            penalty.casting.applyAuraName[0] = AuraType.modHealingPct;
            node.data.spells.spells[reduced] = penalty;
        }

        const start = Position(100, 100, 40);
        auto caster = loggedIn(origin, db, 7, "Thrall", start, characterLevel: 40, setup: (ref c) {
            c.classId = classMage;
            c.power[Power.mana] = 80;
            c.spells = [NewSpell(chain, true)];
        });
        auto healer = cast(Player) caster.session.character;
        healer.values.set!UNIT_FIELD_MAXHEALTH(200u);
        healer.values.set!UNIT_FIELD_HEALTH(150u);
        healer.values.set!UNIT_FIELD_POWER1(Power.mana, healer.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
        TestClient recipient(uint guid, string name, float x, uint health, bool remote)
        {
            const p = Position(start.x + x, start.y, start.z);
            auto client = loggedIn(remote ? owner : origin, db, guid, name, p, characterLevel: 40);
            auto player = cast(Player) client.session.character;
            player.values.set!UNIT_FIELD_MAXHEALTH(200u);
            player.values.set!UNIT_FIELD_HEALTH(health);
            if (remote)
                origin.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), guid, encodePlayerState(player, 0));
            return client;
        }
        auto first = recipient(8, "Durotan", 8, 20, false);
        auto second = recipient(9, "Orgrim", 16, 35, true);
        auto third = recipient(10, "Garrosh", 24, 45, !lastIsLocal);
        auto alternate = recipient(11, "Eitrigg", 15, 5, false);
        // Lower health percentage than either bounce recipient, but fewer missing hit points.
        (cast(Player) alternate.session.character).values.set!UNIT_FIELD_MAXHEALTH(100u);
        auto stranger = recipient(12, "Nazgrel", 9, 2, false);
        auto remoteStranger = recipient(13, "Rexxar", 17, 1, true);
        second.session.inWorld.addAura(makeAura(reduced in owner.data.spells.spells, 9, 40, -1, false, [-50, 0, 0]));
        caster.read();

        PartyHeal[] requests, replies;
        origin.sendPartyHeal = (ushort peer, const ref PartyHeal heal) {
            assert(peer == 2 && !heal.landed);
            requests ~= roundTrip(heal);
            return true;
        };
        owner.sendPartyHeal = (ushort peer, const ref PartyHeal heal) {
            assert(peer == 1 && heal.landed);
            replies ~= roundTrip(heal);
            return true;
        };
        ByteWriter request;
        request.put(chain);
        request.put(cast(ushort) TargetFlags.unit);
        request.putPackedGuid(8);
        const mana = healer.values.get!UNIT_FIELD_POWER1(Power.mana);
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_START) == 1);
        now += (castMs - 1).msecs;
        caster.session.update((castMs - 1).msecs);
        assert(!requests.length && healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana);
        now += 1.msecs;
        caster.session.update(1.msecs);
        assert(healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost && origin.onlinePlayer(7) is caster.session.inWorld);
        assert(first.session.character.values.get!UNIT_FIELD_HEALTH == 100u);
        assert(requests.length == (lastIsLocal ? 1 : 2));
        assert(requests[0].target == 9 && requests[0].previous == 8 && requests[0].x == start.x + 8 && requests[0].amount == 40);
        if (!lastIsLocal)
            assert(requests[1].target == 10 && requests[1].previous == 9 && requests[1].x == start.x + 16
                && requests[1].amount == 20 && requests[1].sequence > requests[0].sequence);
        const packets = caster.read();
        auto go = ByteReader(bodyOf(packets, Opcode.SMSG_SPELL_GO));
        assert(go.readPackedGuid() == 7 && go.readPackedGuid() == 7 && go.read!uint == chain);
        go.read!ushort;
        assert(go.read!ubyte == 3 && go.read!ulong == 8 && go.read!ulong == 9 && go.read!ulong == 10);

        foreach (ref heal; requests)
        {
            owner.partyHealArrived(1, heal);
            owner.partyHealArrived(1, heal);
        }
        foreach (ref heal; replies)
        {
            origin.partyHealArrived(2, heal);
            origin.partyHealArrived(2, heal);
        }
        assert(replies.length == requests.length && opcodesOf(caster.read()).count(Opcode.SMSG_SPELLHEALLOG) == replies.length);
        assert(second.session.character.values.get!UNIT_FIELD_HEALTH == 55u, "the remote recipient applies its own modifier once");
        assert(third.session.character.values.get!UNIT_FIELD_HEALTH == 65u, "the second bounce uses a quarter heal on either node");
        assert(alternate.session.character.values.get!UNIT_FIELD_HEALTH == 5u
            && stranger.session.character.values.get!UNIT_FIELD_HEALTH == 2u
            && remoteStranger.session.character.values.get!UNIT_FIELD_HEALTH == 1u);
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(chain, SpellCastResult.notReady));
        if (lastIsLocal)
            continue;

        now += cooldownMs.msecs;
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        now += castMs.msecs;
        caster.session.update(castMs.msecs);
        assert(requests.length == 4 && requests[2].target == 9 && requests[3].target == 10);
        auto moving = cast(Player) second.session.character;
        const before = moving.position;
        moving.movement.position.x += 50;
        owner.map(0).relocated(second.session.inWorld);
        owner.partyHealArrived(1, requests[2]);
        moving.movement.position = before;
        owner.map(0).relocated(second.session.inWorld);
        owner.partyHealArrived(1, requests[2]);
        owner.groups.of(7).removeMember(10, RemoveMethod.leave);
        owner.partyHealArrived(1, requests[3]);
        assert(replies.length == 2 && moving.values.get!UNIT_FIELD_HEALTH == 55u
            && third.session.character.values.get!UNIT_FIELD_HEALTH == 65u);
    }
}

// A cast-time heal, hostile area damage and resulting procs use the target node's combat state.
unittest
{
    import core.time : MonoTime, msecs;
    import std.format : format;
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage, KillShare, PartyHeal;
    import dmangos.dbc : buildDbc;
    import dmangos.world.aurahandlers : ProcFlag;
    import dmangos.world.auras : makeAura;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRadiusFormat;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.defines : Power;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : RemoveMethod;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellcast;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    GroupRecord party;
    party.id = 1;
    party.leader = 7;
    party.leaderName = "Anduin";
    party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina")];
    db.groups[party.id] = party;
    auto origin = newCreationContext(db), owner = newCreationContext(db);
    auto relay = new TestPlayerRelay(origin, owner);
    auto now = MonoTime.currTime;
    origin.clock = owner.clock = () => now;
    enum uint prayer = 596, blast = 55013, echo = 55014, bolt = 55015, healProc = 55016, buff = 55017,
        retaliation = 55018;
    enum uint cost = 12, school = 3, castMs = 1_500;
    foreach (node; [origin, owner])
    {
        node.client.spellCastTimes = typeof(node.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
            [[1u, castMs, 0, castMs]]), "SpellCastTimes.dbc");
        uint[spellRadiusFormat.length] radiusRow;
        radiusRow[0] = 1;
        const float radius = 20;
        radiusRow[1] = *cast(const uint*) &radius;
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat, [radiusRow[]]),
            "SpellRadius.dbc");
        auto heal = testSpell(prayer, SpellEffect.heal, ImplicitTarget.partyInRange, 60, 1);
        heal.casting.radiusIndex[0] = 1;
        heal.casting.manaCost = cost;
        heal.casting.powerType = Power.mana;
        heal.attributesEx2 |= spellAttrEx2CantCrit;
        node.data.spells.spells[prayer] = heal;
        auto attack = testSpell(blast, SpellEffect.schoolDamage, ImplicitTarget.casterSource, 30);
        attack.casting.radiusIndex[0] = 1;
        attack.casting.implicitTargetB[0] = ImplicitTarget.enemiesAroundSource;
        attack.casting.school = school;
        attack.attributesEx2 |= spellAttrEx2CantCrit;
        attack.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        node.data.spells.spells[blast] = attack;
        auto trigger = testSpell(bolt, SpellEffect.schoolDamage, ImplicitTarget.enemy, 25);
        trigger.casting.school = school;
        trigger.attributesEx2 |= spellAttrEx2CantCrit;
        trigger.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        node.data.spells.spells[bolt] = trigger;
        auto sign = testSpell(buff, SpellEffect.applyAura, ImplicitTarget.caster, 1);
        sign.casting.applyAuraName[0] = AuraType.modStat;
        node.data.spells.spells[buff] = sign;
        foreach (id, event; [echo: ProcFlag.dealHarmfulSpell, healProc: ProcFlag.dealHelpfulSpell,
            retaliation: ProcFlag.takeHarmfulSpell])
        {
            auto aura = testSpell(id, SpellEffect.applyAura, ImplicitTarget.caster, 0);
            aura.casting.applyAuraName[0] = AuraType.procTriggerSpell;
            aura.casting.procFlags = event;
            aura.casting.procChance = 100;
            aura.casting.procCharges = 1;
            aura.triggerSpell[0] = id == healProc ? buff : bolt;
            node.data.spells.spells[id] = aura;
        }
    }

    const at = Position(100, 100, 40);
    auto caster = loggedIn(origin, db, 7, "Anduin", at, characterLevel: 20, setup: (ref c) {
        c.classId = classMage;
        c.power[Power.mana] = 80;
        c.spells = [NewSpell(prayer, true), NewSpell(blast, true)];
    });
    const near = Position(at.x + 6, at.y, at.z);
    auto target = loggedIn(owner, db, 8, "Jaina", near, characterLevel: 20);
    auto healer = cast(Player) caster.session.character;
    auto healed = cast(Player) target.session.character;
    healer.values.set!UNIT_FIELD_POWER1(Power.mana, healer.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
    healer.values.set!UNIT_FIELD_MAXHEALTH(200u);
    healer.values.set!UNIT_FIELD_HEALTH(200u);
    healed.values.set!UNIT_FIELD_MAXHEALTH(100u);
    healed.values.set!UNIT_FIELD_HEALTH(80u);
    owner.map(0).replicaCreated(1, cellKeyAt(at.x, at.y), 7, encodePlayerState(healer, 0));
    healed.movement.position.x += 40;
    origin.map(0).replicaCreated(2, cellKeyAt(healed.position.x, near.y), 8, encodePlayerState(healed, 0));
    healed.movement.position = near;
    auto proto = owner.data.creatureTemplates.edit(creatureInnkeeper);
    proto.minLootGold = proto.maxLootGold = 1;
    auto spawn = CreatureSpawn(91_000, creatureInnkeeper, 0, near.x + 2, near.y, near.z);
    auto mob = owner.makeCreature(&spawn);
    owner.map(0).addObject(mob);
    mob.values.set!UNIT_FIELD_LEVEL(20u);
    mob.values.set!UNIT_FIELD_RESISTANCES(school, 0u);
    mob.values.set!UNIT_FIELD_MAXHEALTH(100u);
    mob.values.set!UNIT_FIELD_HEALTH(50u);
    mob.ai.attackedBy(target.session.inWorld.unit, owner.map(0));
    origin.map(0).replicaCreated(2, cellKeyAt(mob.position.x, mob.position.y), mob.guid, encodeState(mob, 0));

    PartyHeal[] heals, receipts;
    origin.sendPartyHeal = (ushort peer, const ref PartyHeal value) { heals ~= value; return peer == 2; };
    owner.sendPartyHeal = (ushort peer, const ref PartyHeal value) { receipts ~= value; return peer == 1; };
    ByteWriter castPrayer;
    castPrayer.put(prayer);
    castPrayer.put(cast(ushort) TargetFlags.unit);
    castPrayer.putPackedGuid(healed.guid); // the client's selected unit is on the other node
    ByteWriter cancel;
    cancel.put(prayer);
    const mana = healer.values.get!UNIT_FIELD_POWER1(Power.mana);
    caster.write(Opcode.CMSG_CAST_SPELL, castPrayer.data);
    assert(relay.remote is null, "a caster-centered party heal stays here even with a remote unit selected");
    caster.write(Opcode.CMSG_CANCEL_CAST, cancel.data);
    caster.session.update(castMs.msecs);
    assert(!heals.length && healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana);
    caster.write(Opcode.CMSG_CAST_SPELL, castPrayer.data);
    assert(!heals.length);
    origin.map(0).replicaCreated(2, cellKeyAt(near.x, near.y), 8, encodePlayerState(healed, 0));
    now += castMs.msecs;
    caster.session.update(castMs.msecs);
    assert(heals.length == 1 && healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost);
    caster.session.inWorld.addAura(makeAura(healProc in origin.data.spells.spells, 7, 20, -1, true, [0, 0, 0]));
    owner.partyHealArrived(1, heals[0]);
    owner.partyHealArrived(1, heals[0]);
    assert(receipts.length == 1 && healed.values.get!UNIT_FIELD_HEALTH == 100u);
    assert(mob.ai.threatOf(7) == 10, "threat uses restored health rather than overhealing");
    origin.partyHealArrived(2, receipts[0]);
    origin.partyHealArrived(2, receipts[0]);
    assert(caster.session.inWorld.hasAuraOf(buff) && !caster.session.inWorld.hasAuraOf(healProc));

    origin.groups.of(7).removeMember(8, RemoveMethod.leave);
    owner.groups.of(7).removeMember(8, RemoveMethod.leave);
    owner.sendQuestLootCheck = (ushort peer, const ref imported!"dmangos.cluster.protocol".QuestLootCheck check) => peer == 1;
    AreaDamage[] hits, replies, counterattacks;
    KillShare[] shares;
    origin.sendAreaDamage = (ushort peer, const ref AreaDamage value) {
        if (!value.reply)
            hits ~= cast(AreaDamage) value;
        return peer == 2;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage value) {
        if (value.reply)
            replies ~= cast(AreaDamage) value;
        else
            counterattacks ~= cast(AreaDamage) value;
        return peer == 1;
    };
    owner.killShareElsewhere = (ushort node, const ref KillShare share) { assert(node == 1); shares ~= share; };
    caster.session.inWorld.addAura(makeAura(echo in origin.data.spells.spells, 7, 20, -1, true, [0, 0, 0]));
    bool added;
    mob.receiveAura(makeAura(retaliation in owner.data.spells.spells, mob.guid, 20, -1, true, [0, 0, 0]),
        owner.map(0), added);
    ByteWriter attack;
    attack.put(blast);
    attack.put(cast(ushort) TargetFlags.unit);
    attack.putPackedGuid(mob.guid);
    caster.write(Opcode.CMSG_CAST_SPELL, attack.data);
    assert(relay.remote is null, "a caster-centered attack stays here even with a remote unit selected");
    assert(hits.length == 1 && hits[0].target == mob.guid);
    owner.areaDamageArrived(1, hits[0]);
    owner.areaDamageArrived(1, hits[0]);
    assert(mob.values.get!UNIT_FIELD_HEALTH == 20u && mob.lootRecipient == 7 && mob.ai.threatOf(7) == 40,
        format!"health %s, tapper %s, threat %s, hit %s, replies %s"(mob.values.get!UNIT_FIELD_HEALTH,
            mob.lootRecipient, mob.ai.threatOf(7), hits[0].amount, replies));
    assert(replies.length == 1);
    assert(counterattacks.length == 1 && counterattacks[0].triggered && counterattacks[0].caster == mob.guid);
    origin.areaDamageArrived(2, counterattacks[0]);
    const after = healer.values.get!UNIT_FIELD_HEALTH;
    assert(after < 200, "the creature's proc struck a player on another node");
    origin.areaDamageArrived(2, counterattacks[0]);
    assert(healer.values.get!UNIT_FIELD_HEALTH == after);
    origin.areaDamageArrived(2, replies[0]);
    origin.areaDamageArrived(2, replies[0]);
    assert(hits.length == 2 && hits[1].triggered && hits[1].spell == bolt);
    owner.areaDamageArrived(1, hits[1]);
    owner.areaDamageArrived(1, hits[1]);
    assert(!mob.alive && mob.loot !is null && 7UL in mob.loot.owners);
    assert(mob.loot.canLoot(7) && mob.loot.replicaLooters() == [7UL]);
    assert(mob.loot.remoteMembers.get(7, 0) == 1, "the solo tapper can also receive quest-loot eligibility checks");
    assert(shares.length == 1 && shares[0].target == 7 && shares[0].victim == mob.guid);
}

// An instant party heal uses one cast and reaches each eligible local or remote member once.
unittest
{
    import core.time : MonoTime;
    import std.algorithm.searching : count;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.protocol : PartyHeal;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : makeAura;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.clientdata : spellRadiusFormat;
    import dmangos.world.defines : Power;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    GroupRecord party;
    party.id = 1;
    party.leader = 7;
    party.leaderName = "Anduin";
    party.isRaid = true;
    party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina"),
        GroupMemberRecord(9, "Varian"), GroupMemberRecord(10, "Khadgar"), GroupMemberRecord(11, "Uther"),
        GroupMemberRecord(12, "Medivh", false, 1)];
    db.groups[party.id] = party;
    auto origin = newCreationContext(db), owner = newCreationContext(db);
    origin.nodeId = 1;
    owner.nodeId = 2;
    owner.ownsCell = (uint, ulong) => false;
    auto now = MonoTime.currTime;
    origin.clock = owner.clock = () => now;
    enum uint heal = 55005, healerAura = 55006, reduced = 55007, cost = 12;
    const float area = 20;
    const areaBits = *cast(const uint*) &area;
    foreach (node; [origin, owner])
    {
        uint[spellRadiusFormat.length] radiusRow;
        radiusRow[0] = 1;
        radiusRow[1] = areaBits;
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat, [radiusRow[]]),
            "SpellRadius.dbc");
        auto partyHeal = testSpell(heal, SpellEffect.heal, ImplicitTarget.partyInRange, 20);
        partyHeal.casting.radiusIndex[0] = 1;
        partyHeal.casting.powerType = Power.mana;
        partyHeal.casting.manaCost = cost;
        partyHeal.recoveryTime = 5_000;
        partyHeal.attributesEx2 |= spellAttrEx2CantCrit;
        node.data.spells.spells[heal] = partyHeal;
        auto bonus = testSpell(healerAura, SpellEffect.applyAura, ImplicitTarget.caster, 50);
        bonus.casting.applyAuraName[0] = AuraType.modHealingDonePercent;
        node.data.spells.spells[healerAura] = bonus;
        auto penalty = testSpell(reduced, SpellEffect.applyAura, ImplicitTarget.caster, -50);
        penalty.casting.applyAuraName[0] = AuraType.modHealingPct;
        node.data.spells.spells[reduced] = penalty;
    }

    const start = Position(-8949.95f, -132.49f, 83.53f);
    const near = Position(start.x + 5, start.y, start.z), far = Position(start.x + 35, start.y, start.z);
    auto caster = loggedIn(origin, db, 7, "Anduin", start, setup: (ref c) {
        c.classId = classMage;
        c.power[Power.mana] = 80;
        c.spells = [NewSpell(heal, true)];
    });
    auto local_ = loggedIn(origin, db, 8, "Jaina", near);
    auto remote = loggedIn(owner, db, 9, "Varian", near);
    auto distant = loggedIn(owner, db, 10, "Khadgar", far);
    auto moving = loggedIn(owner, db, 11, "Uther", near);
    auto otherSubgroup = loggedIn(owner, db, 12, "Medivh", near);
    auto healer = cast(Player) caster.session.character;
    auto other = cast(Player) remote.session.character;
    foreach (session; [caster.session, local_.session, remote.session, distant.session, moving.session,
        otherSubgroup.session])
    {
        auto player = cast(Player) session.character;
        player.values.set!UNIT_FIELD_MAXHEALTH(100u);
        player.values.set!UNIT_FIELD_HEALTH(20u);
        if (player.guid >= 9)
        {
            const p = player.position;
            origin.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), player.guid, encodePlayerState(player, 0));
        }
    }
    caster.session.inWorld.addAura(makeAura(healerAura in origin.data.spells.spells, healer.guid, 1, -1, true, [50, 0, 0]));
    remote.session.inWorld.addAura(makeAura(reduced in owner.data.spells.spells, other.guid, 1, -1, false, [-50, 0, 0]));
    remote.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
    caster.read();

    PartyHeal[] requests, replies;
    origin.sendPartyHeal = (ushort peer, const ref PartyHeal message) {
        assert(peer == 2 && !message.landed);
        requests ~= message;
        return true;
    };
    owner.sendPartyHeal = (ushort peer, const ref PartyHeal message) {
        assert(peer == 1 && message.landed);
        replies ~= message;
        return true;
    };
    const mana = healer.values.get!UNIT_FIELD_POWER1(Power.mana);
    ByteWriter request;
    request.put(heal);
    request.put(cast(ushort) TargetFlags.self);
    caster.write(Opcode.CMSG_CAST_SPELL, request.data);
    assert(healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost);
    assert(healer.values.get!UNIT_FIELD_HEALTH == 50u && local_.session.character.values.get!UNIT_FIELD_HEALTH == 50u);
    assert(other.values.get!UNIT_FIELD_HEALTH == 20u && requests.length == 2);
    assert(requests[0].target == 9 && requests[1].target == 11, "distance and raid subgroup filter the remote targets");
    assert(requests[0].amount == 30 && requests[1].sequence > requests[0].sequence);
    auto castResult = ByteReader(bodyOf(caster.read(), Opcode.SMSG_SPELL_GO));
    assert(castResult.readPackedGuid() == 7 && castResult.readPackedGuid() == 7 && castResult.read!uint == heal);
    castResult.read!ushort;
    assert(castResult.read!ubyte == 4, "the cast packet lists both the local and remote targets");
    assert(castResult.read!ulong == 7 && castResult.read!ulong == 8
        && castResult.read!ulong == 9 && castResult.read!ulong == 11);

    auto movingPlayer = cast(Player) moving.session.character;
    movingPlayer.movement.position = far;
    owner.map(0).relocated(moving.session.inWorld);
    owner.partyHealArrived(1, requests[0]);
    owner.partyHealArrived(1, requests[0]);
    owner.partyHealArrived(1, requests[1]);
    movingPlayer.movement.position = near;
    owner.map(0).relocated(moving.session.inWorld);
    owner.partyHealArrived(1, requests[1]);

    assert(other.values.get!UNIT_FIELD_HEALTH == 35u, "only the target node applies its healing penalty, once");
    assert(distant.session.character.values.get!UNIT_FIELD_HEALTH == 20u
        && otherSubgroup.session.character.values.get!UNIT_FIELD_HEALTH == 20u
        && movingPlayer.values.get!UNIT_FIELD_HEALTH == 20u);
    assert(replies.length == 1 && replies[0].amount == 15);
    assert(!caster.session.inWorld.isPvP);
    origin.partyHealArrived(2, replies[0]);
    origin.partyHealArrived(2, replies[0]);
    const logged = caster.read();
    assert(opcodesOf(logged).count(Opcode.SMSG_SPELLHEALLOG) == 1);
    assert(bodyOf(logged, Opcode.SMSG_SPELLHEALLOG) == healLog(9, 7, heal, 15, false));
    assert(caster.session.inWorld.isPvP, "helping a flagged member flags the caster only after the heal lands");
    const cooldowns = caster.session.inWorld.initialCooldowns();
    assert(cooldowns.length == 1 && cooldowns[0].spell == heal);
    caster.write(Opcode.CMSG_CAST_SPELL, request.data);
    assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(heal, SpellCastResult.notReady));
    assert(healer.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost && requests.length == 2);
}

// Cross-node player spells validate on both nodes and use the normal cast, cost and cooldown once.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : count;
    import std.file : rmdirRecurse, tempDir;
    import std.format : format;
    import std.path : buildPath;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.vmap.maptree : toInternal;
    import dmangos.world.clientdata : chrRacesFormat, factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRangeFormat;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.pvp : pvpFlagMs;
    import dmangos.world.relations : PlayerFlagsPvP;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast;
    import dmangos.world.terrain : writeTestHouseVmaps;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.world.grid : cellKeyAt;

    const directory = buildPath(tempDir, "dmangos-spell-handoff-test");
    writeTestHouseVmaps(directory);
    scope (exit)
        rmdirRecurse(directory);
    Position insideHouse(float x, float y)
    {
        const point = toInternal(x, y, 50);
        return Position(point.x, point.y, point.z);
    }
    import dmangos.bytes : bits = floatBits;
    enum Scenario
    {
        heal, buff, farBefore, wallBefore, enemy, combat, farOnArrival, wallOnArrival, wallDuringCast, cancel,
        damage, debuff, unflagged, friendly, flagExpiresOnArrival, immuneDuringCast, hostileWallOnArrival, freeForAll,
        hostileCancel
    }
    import std.traits : EnumMembers;

    foreach (scenario; [EnumMembers!Scenario])
    {
        auto db = newDatabase();
        void configure(ref WorldConfig config)
        {
            config.dataDir = directory;
            config.rateHealth = config.rateMana = 0;
            if (scenario == Scenario.freeForAll)
                config.gameType = 16;
        }
        auto origin = newCreationContext(db, &configure), owner = newCreationContext(db, &configure);
        auto relay = new TestPlayerRelay(origin, owner);
        auto now = MonoTime.currTime;
        origin.clock = owner.clock = () => now;
        enum uint heal = 55001, buff = 55002, damage = 55003, debuff = 55004, cost = 12, recovery = 4_000;
        const hostile = scenario.among(Scenario.damage, Scenario.debuff, Scenario.unflagged, Scenario.friendly,
            Scenario.flagExpiresOnArrival, Scenario.immuneDuringCast, Scenario.hostileWallOnArrival, Scenario.freeForAll,
            Scenario.hostileCancel) != 0;
        const otherFaction = scenario == Scenario.enemy
            || (hostile && scenario != Scenario.friendly && scenario != Scenario.freeForAll);
        uint[chrRacesFormat.length] human, orc;
        human[0] = raceHuman;
        human[2] = human[8] = 7; // faction template and team
        orc[0] = raceOrc;
        orc[2] = orc[8] = 1;
        foreach (node; [origin, owner])
        {
            node.client.races = typeof(node.client.races).parse(buildDbc(chrRacesFormat, [human[], orc[]]),
                "ChrRaces.dbc");
            node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
                [[7u, 1, 0, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0], [1u, 2, 0, 4, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0]]),
                "FactionTemplate.dbc");
            node.client.spellCastTimes = typeof(node.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
                [[1u, 1_500, 0, 1_500]]), "SpellCastTimes.dbc");
            uint[spellRangeFormat.length] rangeRow;
            rangeRow[0] = 1;
            rangeRow[2] = bits(30);
            node.client.spellRanges = typeof(node.client.spellRanges).parse(buildDbc(spellRangeFormat,
                [rangeRow[]]), "SpellRange.dbc");
            node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
                [[1u, 60_000, 0, 60_000]]), "SpellDuration.dbc");
            auto directHeal = testSpell(heal, SpellEffect.heal, ImplicitTarget.friend, 20, 1);
            directHeal.attributesEx2 |= spellAttrEx2CantCrit;
            auto statBuff = testSpell(buff, SpellEffect.applyAura, ImplicitTarget.unitRaid, 5);
            statBuff.casting.applyAuraName[0] = AuraType.modStat;
            statBuff.casting.durationIndex = 1;
            auto firebolt = testSpell(damage, SpellEffect.schoolDamage, ImplicitTarget.enemy, 20, 1);
            firebolt.attributesEx2 |= spellAttrEx2CantCrit;
            firebolt.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
            firebolt.casting.school = 2;
            auto slow = testSpell(debuff, SpellEffect.applyAura, ImplicitTarget.enemy, -30);
            slow.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
            slow.casting.applyAuraName[0] = AuraType.modDecreaseSpeed;
            slow.casting.durationIndex = 1;
            foreach (spell; [directHeal, statBuff, firebolt, slow])
            {
                spell.casting.manaCost = cost;
                spell.casting.powerType = Power.mana;
                spell.casting.startRecoveryTime = 1_500;
                spell.casting.startRecoveryCategory = 133;
                spell.recoveryTime = recovery;
                node.data.spells.spells[spell.id] = spell;
            }
        }

        const casterAt = insideHouse(16002, 16105);
        const near = insideHouse(16002, 16108), behindWall = insideHouse(16008, 16105);
        const far = insideHouse(16002, 16165);
        const targetAt = scenario == Scenario.farBefore ? far : scenario == Scenario.wallBefore ? behindWall : near;
        auto caster = loggedIn(origin, db, 7, "Anduin", casterAt, setup: (ref c) {
            c.classId = classMage;
            c.power[Power.mana] = 80;
            c.spells = [NewSpell(heal, true), NewSpell(buff, true), NewSpell(damage, true), NewSpell(debuff, true)];
        });
        if (scenario == Scenario.heal)
        {
            caster.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
            caster.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
            caster.session.inWorld.updatePvPTimers(pvpFlagMs - 500);
        }
        auto target = loggedIn(owner, db, 8, "Jaina", targetAt, race: otherFaction ? raceOrc : raceHuman);
        if (scenario == Scenario.combat)
        {
            auto me = cast(Player) caster.session.character;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.inCombat);
        }
        auto recipient = cast(Player) target.session.character;
        const startingHealth = hostile ? 40u : 10u;
        recipient.values.set!UNIT_FIELD_HEALTH(startingHealth);
        if (scenario == Scenario.freeForAll)
        {
            auto me = cast(Player) caster.session.character;
            me.values.set!PLAYER_FLAGS(me.values.get!PLAYER_FLAGS | PlayerFlagsPvP.freeForAll);
            recipient.values.set!PLAYER_FLAGS(recipient.values.get!PLAYER_FLAGS | PlayerFlagsPvP.freeForAll);
        }
        else if (hostile && scenario != Scenario.unflagged)
            target.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
        const mana = caster.session.character.values.get!UNIT_FIELD_POWER1(Power.mana);
        assert(mana >= cost);
        const targetCell = cellKeyAt(targetAt.x, targetAt.y);
        origin.map(0).replicaCreated(2, targetCell, recipient.guid, encodePlayerState(recipient, 0));
        assert(origin.map(0).inLineOfSight(casterAt, targetAt) == (scenario != Scenario.wallBefore));

        const id = hostile ? (scenario == Scenario.debuff ? debuff : damage) : (scenario == Scenario.buff ? buff : heal);
        ByteWriter request;
        request.put(id);
        request.put(cast(ushort)(hostile ? TargetFlags.unitEnemy : TargetFlags.unit));
        request.putPackedGuid(recipient.guid);
        caster.write(Opcode.CMSG_CAST_SPELL, request.data);
        const initialPackets = caster.read();
        const refusedAtSource = scenario == Scenario.farBefore || scenario == Scenario.wallBefore
            || scenario == Scenario.enemy || scenario == Scenario.combat || scenario == Scenario.friendly
            || scenario == Scenario.unflagged;
        if (refusedAtSource)
        {
            const result = scenario == Scenario.farBefore ? SpellCastResult.outOfRange
                : scenario == Scenario.wallBefore ? SpellCastResult.lineOfSight
                : scenario == Scenario.enemy ? SpellCastResult.targetEnemy
                : scenario == Scenario.combat ? SpellCastResult.affectingCombat : SpellCastResult.targetFriendly;
            assert(relay.remote is null && caster.session.inWorld !is null);
            assert(bodyOf(initialPackets, Opcode.SMSG_CAST_RESULT) == castResultPacket(id, result));
            assert(caster.session.character.values.get!UNIT_FIELD_POWER1(Power.mana) == mana);
            assert(recipient.values.get!UNIT_FIELD_HEALTH == startingHealth);
            continue;
        }

        assert(relay.remote !is null && caster.session.inWorld is null,
            format!"%s did not hand off: %s"(scenario, bodyOf(initialPackets, Opcode.SMSG_CAST_RESULT)));
        assert(relay.remote.character.values.get!UNIT_FIELD_POWER1(Power.mana) == mana);
        if (scenario == Scenario.heal)
            assert(relay.remote.character.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp,
                "the caster keeps their timed PvP flag during handoff");
        if (scenario == Scenario.freeForAll)
            assert(relay.remote.character.values.get!PLAYER_FLAGS & PlayerFlagsPvP.freeForAll,
                "the caster keeps their free-for-all eligibility");
        if (scenario == Scenario.farOnArrival || scenario == Scenario.wallOnArrival || scenario == Scenario.hostileWallOnArrival)
        {
            recipient.movement.position = scenario == Scenario.farOnArrival ? far : behindWall;
            owner.map(0).relocated(target.session.inWorld);
        }
        if (scenario == Scenario.flagExpiresOnArrival)
        {
            target.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
            target.session.inWorld.updatePvPTimers(pvpFlagMs);
            assert(!(recipient.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp));
        }
        if (scenario == Scenario.cancel || scenario == Scenario.hostileCancel)
        {
            ByteWriter cancel;
            cancel.put(id);
            caster.write(Opcode.CMSG_CANCEL_CAST, cancel.data);
            assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(id, SpellCastResult.interrupted));
        }
        if (scenario == Scenario.heal || scenario == Scenario.damage)
        {
            caster.write(Opcode.CMSG_CAST_SPELL, request.data);
            assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(id, SpellCastResult.spellInProgress));
        }
        relay.remote.update(50.msecs);
        if (scenario == Scenario.wallDuringCast)
        {
            assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_START) == 1);
            recipient.movement.position = behindWall;
            owner.map(0).relocated(target.session.inWorld);
        }
        if (scenario == Scenario.immuneDuringCast)
        {
            assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_START) == 1);
            recipient.values.set!UNIT_FIELD_FLAGS(recipient.values.get!UNIT_FIELD_FLAGS | UnitFlags.immuneToPlayer);
        }
        now += 1_500.msecs;
        relay.remote.update(1_500.msecs);
        const packets = caster.read();
        const damaged = scenario == Scenario.damage || scenario == Scenario.freeForAll;
        const succeeded = scenario == Scenario.heal || scenario == Scenario.buff || damaged || scenario == Scenario.debuff;
        assert(opcodesOf(packets).count(Opcode.SMSG_SPELL_GO) == (succeeded ? 1 : 0));
        if (!succeeded && scenario != Scenario.cancel && scenario != Scenario.hostileCancel)
        {
            const result = scenario == Scenario.farOnArrival ? SpellCastResult.outOfRange
                : scenario == Scenario.flagExpiresOnArrival || scenario == Scenario.immuneDuringCast
                    ? SpellCastResult.targetFriendly : SpellCastResult.lineOfSight;
            assert(bodyOf(packets, Opcode.SMSG_CAST_RESULT) == castResultPacket(id, result));
        }
        const expectedHealth = scenario == Scenario.heal ? startingHealth + 20 : damaged ? startingHealth - 20 : startingHealth;
        assert(recipient.values.get!UNIT_FIELD_HEALTH == expectedHealth);
        if (scenario == Scenario.heal)
            assert(!(relay.remote.character.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp),
                "the flag expires when its remaining time runs out");
        assert((recipient.auras.find(buff) !is null) == (scenario == Scenario.buff));
        auto slow = recipient.auras.find(debuff);
        assert((slow !is null) == (scenario == Scenario.debuff));
        if (slow !is null)
            assert(!slow.positive && slow.amount[0] == -30);
        assert(relay.remote.character.values.get!UNIT_FIELD_POWER1(Power.mana) == (succeeded ? mana - cost : mana));
        const cooldowns = relay.remote.inWorld.initialCooldowns();
        assert(cooldowns.length == (succeeded ? 1 : 0));
        if (succeeded)
        {
            assert(cooldowns[0].spell == id);
            caster.write(Opcode.CMSG_CAST_SPELL, request.data);
            assert(bodyOf(caster.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(id, SpellCastResult.notReady));
            relay.remote.update(50.msecs);
            assert(relay.remote.character.values.get!UNIT_FIELD_POWER1(Power.mana) == mana - cost);
            assert(opcodesOf(caster.read()).count(Opcode.SMSG_SPELL_GO) == 0);
        }
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
    import dmangos.bytes : bits = floatBits;
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
        spells.edit(strike).casting.dmgClass = DamageClass.melee;
        spells[home] = testSpell(home, 5, 1, 0);                // home
        spells.edit(home).casting.implicitTargetB[0] = ImplicitTarget.homeBind;
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

    // Combo points: a builder puts them on its target (at most five); a finishing move uses them (more damage
    // a point) and spends them, unless it missed.
    {
        import dmangos.world.spellcast : SpellCastResult;

        enum uint builder = 90011, finisher = 90012;
        with (context.data.spells)
        {
            spells[builder] = testSpell(builder, 80, 6, 1);    // SPELL_EFFECT_ADD_COMBO_POINTS, 1 point
            spells[finisher] = testSpell(finisher, 2, 6, 10);  // 10 damage
            spells.edit(finisher).attributesEx = 0x00100000;   // a finishing move
            spells.edit(finisher).casting.pointsPerComboPoint[0] = 50;
        }
        auto session = anduin.session.inWorld;
        assert(session.castSpell((finisher in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid),
            false, 0) == SpellCastResult.casterAuraState, "none yet (a warrior is told of Overpower's state)");
        foreach (_; 0 .. 40)
        {
            if (session.comboPoints >= 2)
                break;
            now += 2.seconds;
            session.castSpell((builder in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
        }
        assert(session.comboPoints == 2 && session.comboTarget == keeper.guid);
        assert(me.values.getByte!PLAYER_FIELD_BYTES(1) == 2 && me.values.get!PLAYER__FIELD_COMBO_TARGET == keeper.guid,
            "the client sees them");
        foreach (_; 0 .. 10)
            session.castSpell((builder in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
        assert(session.comboPoints <= 5);
        const pointsBefore = session.comboPoints;
        const before = keeper.values.get!UNIT_FIELD_HEALTH;
        now += 2.seconds;
        assert(session.castSpell((finisher in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid),
            false, 0) == SpellCastResult.ok);
        const dealt = before - keeper.values.get!UNIT_FIELD_HEALTH;
        if (session.comboPoints == 0)
            assert(dealt > 10 && dealt >= (10 + 50 * pointsBefore) / 4, "a hit: more a point (a partial resist at most 75%), and they are spent");
        else
            assert(dealt == 0 && session.comboPoints == pointsBefore, "a miss: they stay");
        keeper.values.set!UNIT_FIELD_HEALTH(500u);
        now += 2.seconds; // past the global cooldown
        anduin.read();
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

    // A teleport to the spell's own place (`spell_target_position`): a mage's Teleport: Stormwind.
    {
        import dmangos.world.packets : ClientTeleportAck;
        import dmangos.world.worlddata : SpellTarget;

        anduin.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.guid, 0, 0));
        anduin.read();
        enum uint teleport = 90005;
        context.data.spells.spells[teleport] = testSpell(teleport, 5, 1, 0);
        context.data.spells.spells.edit(teleport).casting.implicitTargetB[0] = ImplicitTarget.database;
        context.data.spellTargets[teleport] = SpellTarget(0, Position(-8900, -120, 85, 1));
        me.spells ~= teleport;
        now += 2.seconds;
        anduin.write(Opcode.CMSG_CAST_SPELL, castAt(teleport, 0));
        assert(opcodesOf(anduin.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK));
        anduin.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.guid, 0, 0));
        anduin.read();
        assert(me.position.x == -8900 && me.position.y == -120);
    }
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
    import dmangos.bytes : bits = floatBits;
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
        casting.dmgClass = DamageClass.none;
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
    import dmangos.bytes : bits = floatBits;
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
        casting.dmgClass = DamageClass.none;
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
    auto hole = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
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

    import dmangos.world.context : WorldContext;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodeState;

    now += 2000.msecs;
    cast_();
    bob = bobberNow();
    assert(bob !is null);
    const originalBobber = bob.guid;
    tick(1500);
    auto destination = new WorldContext(context.config, db, context.data, context.client);
    destination.clock = () => now;
    auto relay = new TestPlayerRelay(context, destination);
    auto nextMap = destination.map(0);
    auto anchor = destination.spawnGameObjectAt(nextMap, school.entry, at, false);
    map.replicaCreated(2, cellKeyAt(at.x, at.y), anchor.guid, encodeState(anchor, 0));
    assert(anduin.session.inWorld.actAtReplica(anchor.guid, ArrivalAction.init));
    assert(relay.remote !is null && map.gameObjectAt(originalBobber) is null);
    auto moved = nextMap.gameObjectAt(originalBobber);
    assert(moved !is null && moved.owner == me.guid && moved.position == bob.position);
    assert(relay.remote.character.values.get!UNIT_FIELD_CHANNEL_OBJECT == originalBobber);
    anduin.read();
    bool movedSplash;
    foreach (_; 0 .. 16)
    {
        now += 1000.msecs;
        relay.remote.update(1000.msecs);
        if (opcodesOf(anduin.read()).canFind(Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM))
        {
            movedSplash = true;
            break;
        }
    }
    assert(movedSplash, "the original bobber splashes on the new owner");
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(originalBobber));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
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
    import dmangos.bytes : bits = floatBits;
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
        dmgClass = DamageClass.none;
    }
    context.data.spells.spells[bolt] = testSpell(bolt, 2, ImplicitTarget.enemy, 20);
    with (context.data.spells.spells.edit(bolt).casting)
    {
        chainTarget[0] = 2;
        dmgClass = DamageClass.none;
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
        context.data.spells.spells.edit(fire).casting.dmgClass = DamageClass.none;
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
    context.data.spells.spells.edit(missile).casting.dmgClass = DamageClass.none;
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
        context.data.spells.spells.edit(smite).casting.dmgClass = DamageClass.none;
        context.data.spells.spells.edit(smite).casting.procChance = 100;
        context.data.spells.spells.edit(smite).attributesEx2 |= 0x20000000; // no crit
        context.data.items.edit(itemSword).details.spells[0].id = smite;
        context.data.items.edit(itemSword).details.spells[0].trigger = 2; // chance on hit
        anduin.session.inWorld.storeLoot(itemSword, 1, 0, false);
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
    import dmangos.bytes : bits = floatBits;
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
        dmgClass = DamageClass.none;
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
        dmgClass = DamageClass.none;
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
    shout.effect[0] = SpellEffect.dummy; // dummy
    shout.implicitTargetA[0] = ImplicitTarget.caster;
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
    import dmangos.world.spellmods : SpellModOp;
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
        s.effect[0] = SpellEffect.dummy; // dummy
        s.implicitTargetA[0] = ImplicitTarget.caster;
        s.casting.manaCost = 100;
        s.casting.spellFamilyName = 3;
        s.casting.spellFamilyFlags = flags;
        return s;
    }
    context.data.spells.spells[29101] = blast(29101, 0x1);
    context.data.spells.spells[29102] = blast(29102, 0x2);
    auto talent = SpellInfo(29103);
    talent.effect[0] = SpellEffect.applyAura;
    talent.casting.applyAuraName[0] = AuraType.addPctModifier;
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

    // With a charge (Clearcasting): spent by the first spell it changes, not by one it does not; then gone.
    me.auras.remove(me.auras.find(29103), me.values);
    auto charged = makeAura((29103 in context.data.spells.spells), me.guid, 10, -1, true, [-50, 0, 0]);
    charged.charges = 1;
    me.auras.apply(charged, me.values, isNew);
    now += 2.seconds;
    assert(mage.session.inWorld.castSpell((29102 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.auras.find(29103) !is null, "not spent by a spell it did not change");
    now += 2.seconds;
    assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_POWER1 == 700, "half the cost, once");
    assert(me.auras.find(29103) is null, "its charge spent: gone");
    now += 2.seconds;
    assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_POWER1 == 600, "the whole cost again");
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
    import dmangos.bytes : bits = floatBits;
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
        spells.edit(bolt).casting.dmgClass = DamageClass.none;
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
    import dmangos.bytes : bits = floatBits;
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
        casting.dmgClass = DamageClass.none;
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
    context.data.spells.spells.edit(bolt).casting.dmgClass = DamageClass.none;
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
    import dmangos.bytes : bits = floatBits;
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
        casting.dmgClass = DamageClass.none;
    }
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 1.97f), AccountLevel.player,
        raceOrc);
    auto me = cast(Player) rexxar.session.character;
    me.spells ~= shot;
    rexxar.read();
    import dmangos.world.defines : equipmentSlotRanged;

    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    rexxar.session.inWorld.storeLoot(itemBow, 1, 0, false);
    rexxar.session.inWorld.storeLoot(itemArrow, 20, 0, false);
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
    // As spell_template has them (instant, at the caster here): a fire spell and a frost one that silence stops
    // (Fireball 133, Frostbolt 116: PreventionType 1), and Arcane Shot (3044), arcane but pacify's (PreventionType 2):
    // an interrupt's lockout does not reach it.
    enum uint fire = 133, frost = 116, arcaneShot = 3044;
    foreach (row; [[fire, 2, 1], [frost, 4, 1], [arcaneShot, 6, 2]])
    {
        context.data.spells.spells[row[0]] = testSpell(row[0], 6, ImplicitTarget.caster, 0);
        context.data.spells.spells.edit(row[0]).casting.school = row[1];
        context.data.spells.spells.edit(row[0]).casting.preventionType = row[2];
    }
    auto jaina = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f));
    jaina.read();
    auto session = jaina.session.inWorld;
    (cast(Player) session.character).spells ~= [fire, frost, arcaneShot];
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
    session.lockOutSchool(6, 4000);
    jaina.read();
    now += 2000.msecs; // past the global cooldown
    assert(castReason(arcaneShot) != SpellCastResult.notReady, "Arcane Shot is not a spell an interrupt locks out");
}

/**
 * An interrupt (Kick, Pummel, Counterspell: `castInterruptedBy`) stops a channel as it does a cast, and locks out its
 * school; but not a cast that may not be interrupted (`Spell::IsInterruptible`): Aimed Shot is pacify's.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat, spellDurationFormat;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : ImplicitTarget, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0], [14u, 3000, 0, 3000], [16u, 1500, 0, 1500]]), "SpellCastTimes.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[27u, 3000, 0, 3000]]), "SpellDuration.dbc");
    // As spell_template has them: Arcane Missiles (5143) channelled, arcane, InterruptFlags 15, PreventionType 1,
    // DurationIndex 27; Aimed Shot (19434) physical, a 3 s cast (CastingTimeIndex 14), InterruptFlags 15,
    // PreventionType 2; Frostbolt (116) frost, 1.5 s here, InterruptFlags 15, PreventionType 1.
    enum uint missiles = 5143, aimed = 19434, frostbolt = 116;
    with (context.data.spells)
    {
        spells[missiles] = testSpell(missiles, 6, ImplicitTarget.caster, 0);
        spells.edit(missiles).attributesEx = 268453004;
        spells.edit(missiles).casting.school = 6;
        spells.edit(missiles).casting.interruptFlags = 15;
        spells.edit(missiles).casting.preventionType = 1;
        spells.edit(missiles).casting.durationIndex = 27;
        spells[aimed] = testSpell(aimed, 2, ImplicitTarget.caster, 0, 14);
        spells.edit(aimed).casting.interruptFlags = 15;
        spells.edit(aimed).casting.preventionType = 2;
        spells[frostbolt] = testSpell(frostbolt, 2, ImplicitTarget.caster, 0, 16);
        spells.edit(frostbolt).casting.school = 4;
        spells.edit(frostbolt).casting.interruptFlags = 15;
        spells.edit(frostbolt).casting.preventionType = 1;
    }
    auto jaina = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f));
    jaina.read();
    auto session = jaina.session.inWorld;
    auto me = cast(Player) session.character;
    me.spells ~= [missiles, aimed, frostbolt];

    const self = SpellTargets(TargetFlags.self, me.guid);
    assert(session.castSpell(missiles in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);
    assert(me.values.get!UNIT_CHANNEL_SPELL == missiles, "channelling");
    session.castInterruptedBy(0, 4000);
    assert(me.values.get!UNIT_CHANNEL_SPELL == 0, "the channel interrupted");
    assert(session.castSpell(missiles in context.data.spells.spells, self, false, 0) == SpellCastResult.notReady,
        "arcane locked out");
    now += 4001.msecs;
    assert(session.castSpell(aimed in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);
    session.castInterruptedBy(0, 4000);
    assert(session.castingSpell, "Aimed Shot goes on");
    {
        import dmangos.bytes : ByteWriter;

        ByteWriter w;
        w.put(aimed);
        jaina.write(Opcode.CMSG_CANCEL_CAST, w.data);
    }
    assert(!session.castingSpell);
    assert(session.castSpell(frostbolt in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);
    session.castInterruptedBy(0, 4000);
    assert(!session.castingSpell, "Frostbolt interrupted");
}

/**
 * Reincarnation used: its hour starts, which is its category's (it has no cooldown of its own), less Improved
 * Reincarnation's ten minutes; it is not offered again until then.
 */
unittest
{
    import core.time : MonoTime, minutes;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint passive = 20608, reincarnation = 21169, improved = 16184, ankh = 17030;
    with (context.data.spells)
    {
        // As spell_template has them: Reincarnation (21169) SPELL_EFFECT_SELF_RESURRECT 20%, an Ankh, RecoveryTime 0,
        // Category 1161, CategoryRecoveryTime 3600000, shaman family flags 0x200; Improved Reincarnation (16184) a
        // flat cooldown modifier of -600000 on that mask (`spell_affect`).
        spells[passive] = testSpell(passive, 6, ImplicitTarget.caster, 0);
        spells[reincarnation] = testSpell(reincarnation, 94, 0, 20);
        spells.edit(reincarnation).reagents[0] = ankh;
        spells.edit(reincarnation).casting.reagentCount[0] = 1;
        spells.edit(reincarnation).category = 1161;
        spells.edit(reincarnation).categoryRecoveryTime = 3_600_000;
        spells.edit(reincarnation).casting.spellFamilyName = 11;
        spells.edit(reincarnation).casting.spellFamilyFlags = 0x200;
        spells[improved] = testSpell(improved, 6, ImplicitTarget.caster, 0);
        spells.edit(improved).attributes = 464; // passive: it stays through death
        spells.edit(improved).casting.applyAuraName[0] = AuraType.addFlatModifier;
        spells.edit(improved).miscValue[0] = SpellModOp.cooldown;
        spells.edit(improved).casting.spellFamilyName = 11;
        spells.edit(improved).casting.affectMask[0] = 0x200;
    }
    context.data.items[ankh] = context.data.items[itemJerky];
    context.data.items.edit(ankh).entry = ankh;
    auto thrall = loggedIn(context, db, 7, "Thrall", Position(-8949.95f, -132.49f, 83.53f));
    auto session = thrall.session.inWorld;
    auto me = cast(Player) session.character;
    me.spells ~= passive;
    session.addAura(makeAura(improved in context.data.spells.spells, me.guid, 1, -1, true, [-600_000, 0, 0]));
    session.storeLoot(ankh, 2, 0, false);
    thrall.read();

    session.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(me.values.get!PLAYER_SELF_RES_SPELL == reincarnation, "offered");
    thrall.write(Opcode.CMSG_SELF_RES, null);
    assert(me.deathState == DeathState.alive && me.inventory.count(ankh) == 1);
    assert(!session.spellIsReady(reincarnation), "its category's cooldown");
    now += 49.minutes;
    assert(!session.spellIsReady(reincarnation), "fifty minutes with the talent");
    now += 2.minutes;
    assert(session.spellIsReady(reincarnation));
}

/**
 * A spell that costs health (`PowerType` -2): Bloodrage takes a fifth of the base health, as health, not some
 * power; with no more health than that it is refused (`CASTER_AURASTATE`).
 */
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, powerHealth, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // Bloodrage (2687) as spell_template has it: PowerType -2, ManaCost 0, ManaCostPercentage 20 (here a dummy).
    enum uint bloodrage = 2687;
    context.data.spells.spells[bloodrage] = testSpell(bloodrage, 3, ImplicitTarget.caster, 0);
    context.data.spells.spells.edit(bloodrage).casting.powerType = powerHealth;
    context.data.spells.spells.edit(bloodrage).casting.manaCostPercentage = 20;
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f));
    varian.read();
    auto session = varian.session.inWorld;
    auto me = cast(Player) session.character;
    me.spells ~= bloodrage;
    const cost = me.stats.baseHealth / 5, health = me.values.get!UNIT_FIELD_HEALTH;
    assert(cost > 0 && health > cost);
    const self = SpellTargets(TargetFlags.self, me.guid);
    assert(session.castSpell(bloodrage in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_HEALTH == health - cost, "a fifth of the base health");
    me.values.set!UNIT_FIELD_HEALTH(cost);
    assert(session.castSpell(bloodrage in context.data.spells.spells, self, false, 0)
        == SpellCastResult.casterAuraState);
}

/**
 * A channel that costs every second (`ManaPerSecond`): Health Funnel takes its caster's health as it goes, and
 * ends when there is no more to take.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget, powerHealth, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    import dmangos.world.config : WorldConfig;

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig c) { c.rateHealth = 0; }); // no regeneration to blur it
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
    // Health Funnel rank 1 (755) as spell_template has it: channelled (AttributesEx 16388), PowerType -2, ManaCost 11,
    // ManaPerSecond 5, DurationIndex 1 (10 s); at the caster here, not at a pet.
    enum uint funnel = 755;
    context.data.spells.spells[funnel] = testSpell(funnel, 6, ImplicitTarget.caster, 0);
    with (context.data.spells.spells)
    {
        edit(funnel).attributesEx = 16388;
        edit(funnel).casting.powerType = powerHealth;
        edit(funnel).casting.manaCost = 11;
        edit(funnel).casting.manaPerSecond = 5;
        edit(funnel).casting.durationIndex = 1;
    }
    auto gul = loggedIn(context, db, 7, "Guldan", Position(-8949.95f, -132.49f, 83.53f));
    gul.read();
    auto session = gul.session.inWorld;
    auto me = cast(Player) session.character;
    me.spells ~= funnel;
    const health = me.values.get!UNIT_FIELD_HEALTH;
    assert(health > 30);
    assert(session.castSpell(funnel in context.data.spells.spells, SpellTargets(TargetFlags.self, me.guid), false, 0)
        == SpellCastResult.ok);
    assert(me.values.get!UNIT_FIELD_HEALTH == health - 11 && me.values.get!UNIT_CHANNEL_SPELL == funnel);
    foreach (_; 0 .. 3)
    {
        now += 1000.msecs;
        gul.session.update(1000.msecs);
    }
    assert(me.values.get!UNIT_FIELD_HEALTH == health - 11 - 3 * 5, "5 a second");
    me.values.set!UNIT_FIELD_HEALTH(5u);
    now += 1000.msecs;
    gul.session.update(1000.msecs);
    assert(me.values.get!UNIT_CHANNEL_SPELL == 0 && me.values.get!UNIT_FIELD_HEALTH == 5, "no more to take: it ends");
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
        spells.edit(fire).casting.dmgClass = DamageClass.none;
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

// A companion (SUMMON_CRITTER): out beside its owner, of its faction and following it; the same spell again sends it
// away; it does not outlast its owner's leaving the world.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    import dmangos.bytes : bits = floatBits;
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint whistle = 90801;
    context.data.spells.spells[whistle] = testSpell(whistle, SpellEffect.summonCritter, ImplicitTarget.caster, 0);
    context.data.spells.spells.edit(whistle).miscValue[0] = creatureTrainer; // the companion
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= whistle;
    void cast_()
    {
        ByteWriter w;
        w.put(whistle);
        SpellTargets(TargetFlags.self).write(w);
        anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
        anduin.read();
    }
    cast_();
    const pet = anduin.session.inWorld.companion;
    auto critter = cast(Creature) context.map(0).findObject(pet);
    assert(pet && critter !is null && critter.values.get!UNIT_FIELD_SUMMONEDBY == me.guid);
    assert(critter.values.get!UNIT_FIELD_FACTIONTEMPLATE == me.values.get!UNIT_FIELD_FACTIONTEMPLATE);
    cast_();
    assert(anduin.session.inWorld.companion == 0 && context.map(0).findObject(pet) is null, "sent away");
    cast_();
    const again = anduin.session.inWorld.companion;
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null); // a game master's account: at once
    assert(context.map(0).findObject(again) is null, "gone with its owner");
}

/// Casting ends what ends with an action (Stealth), but not for a spell allowed while stealthed (Pick Pocket).
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : AuraInterrupt, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto stealth = SpellInfo(1784);
    stealth.effect[0] = SpellEffect.applyAura;
    stealth.casting.applyAuraName[0] = AuraType.modStealth;
    stealth.casting.dispel = 5; // DISPEL_STEALTH
    stealth.casting.auraInterruptFlags = AuraInterrupt.action | AuraInterrupt.damage;
    context.data.spells.spells[1784] = stealth;
    foreach (id, attributesEx; [921u: 0x20u, 29104u: 0u]) // Pick Pocket (allowed while stealthed), another
    {
        auto s = SpellInfo(id);
        s.effect[0] = SpellEffect.dummy;
        s.implicitTargetA[0] = ImplicitTarget.caster;
        s.attributesEx = attributesEx;
        context.data.spells.spells[id] = s;
    }

    auto rogue = loggedIn(context, db, 7, "Valeera", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    rogue.read();
    auto me = cast(Player) rogue.session.character;
    bool isNew;
    me.auras.apply(makeAura((1784 in context.data.spells.spells), me.guid, 10, -1, true, [0, 0, 0]), me.values, isNew);
    assert(rogue.session.inWorld.castSpell((921 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.auras.find(1784) !is null, "still stealthed");
    now += 2.seconds;
    assert(rogue.session.inWorld.castSpell((29104 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    assert(me.auras.find(1784) is null, "another cast ends it");
}

/// A cooldown that starts on an event (Presence of Mind): held while its aura lasts, started as it ends.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto presence = SpellInfo(12043);
    presence.effect[0] = SpellEffect.dummy;
    presence.implicitTargetA[0] = ImplicitTarget.caster;
    presence.attributes = 0x02000000; // SPELL_ATTR_COOLDOWN_ON_EVENT
    presence.recoveryTime = 180_000;
    context.data.spells.spells[12043] = presence;
    const spell = 12043 in context.data.spells.spells;

    auto mage = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    mage.read();
    auto me = cast(Player) mage.session.character;
    assert(mage.session.inWorld.castSpell(spell, SpellTargets(TargetFlags.self, 0), false, 0) == SpellCastResult.ok);
    bool isNew;
    auto aura = me.auras.apply(makeAura(spell, me.guid, 10, -1, true, [0, 0, 0]), me.values, isNew);
    now += 600.seconds;
    assert(!mage.session.inWorld.spellIsReady(12043), "held while its aura lasts");
    mage.read();
    mage.session.inWorld.removeAura(aura);
    bool told;
    foreach (p; mage.read())
        told |= p.opcode == Opcode.SMSG_COOLDOWN_EVENT;
    assert(told, "the client's cooldown starts");
    now += 170.seconds;
    assert(!mage.session.inWorld.spellIsReady(12043), "three minutes from the aura's end");
    now += 11.seconds;
    assert(mage.session.inWorld.spellIsReady(12043));
}

/// A talent's modifier tells the client its new total for each bit of its mask (`SMSG_SET_PCT_SPELL_MODIFIER`).
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto talent = SpellInfo(29103);
    talent.effect[0] = SpellEffect.applyAura;
    talent.casting.applyAuraName[0] = AuraType.addPctModifier;
    talent.miscValue[0] = SpellModOp.cost;
    talent.itemType[0] = 0x5; // bits 0 and 2
    context.data.spells.spells[29103] = talent;

    auto mage = loggedIn(context, db, 7, "Jaina", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    mage.read();
    auto session = mage.session.inWorld;
    session.addAura(makeAura((29103 in context.data.spells.spells), 7, 10, -1, true, [-10, 0, 0]));
    ubyte[][] mods;
    foreach (p; mage.read())
        if (p.opcode == Opcode.SMSG_SET_PCT_SPELL_MODIFIER)
            mods ~= p.body_.dup;
    assert(mods.length == 2, "one for each bit of its mask");
    assert(mods[0][0] == 0 && mods[0][1] == SpellModOp.cost && *cast(int*) &mods[0][2] == -10);
    assert(mods[1][0] == 2);
}

/// Pushback: a cast with SPELL_INTERRUPT_FLAG_DAMAGE_PUSHBACK goes back 1000 ms, then 800, as damage lands.
unittest
{
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0], [3u, 3000, 0, 3000]]), "SpellCastTimes.dbc");
    auto heal = SpellInfo(2050);
    heal.effect[0] = SpellEffect.dummy;
    heal.implicitTargetA[0] = ImplicitTarget.caster;
    heal.casting.castingTimeIndex = 3;
    heal.casting.interruptFlags = 0x02; // pushback
    context.data.spells.spells[2050] = heal;

    auto priest = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    priest.read();
    auto session = priest.session.inWorld;
    assert(session.castSpell((2050 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.ok);
    priest.session.update(1500.msecs); // half way
    priest.read();
    session.unit.spellHitBy(0, 10);
    session.unit.spellHitBy(0, 10);
    const got = priest.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_SPELL_DELAYED), "the client's cast bar goes back");
    priest.session.update(1600.msecs); // 1500 left, plus 1000 and 800 pushed back: not yet
    assert(!opcodesOf(priest.read()).canFind(Opcode.SMSG_SPELL_GO), "pushed back");
    priest.session.update(1800.msecs);
    assert(opcodesOf(priest.read()).canFind(Opcode.SMSG_SPELL_GO), "then it goes");
}

/// An invisible creature is not seen until the player sees through its invisibility (Detect Invisibility).
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : makeAura;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto unseen = SpellInfo(90071);
    unseen.effect[0] = SpellEffect.applyAura;
    unseen.casting.applyAuraName[0] = AuraType.modInvisibility;
    unseen.miscValue[0] = 0;
    auto detect = SpellInfo(90072);
    detect.effect[0] = SpellEffect.applyAura;
    detect.casting.applyAuraName[0] = AuraType.modInvisibilityDetection;
    detect.miscValue[0] = 0;
    context.data.spells.spells[90071] = unseen;
    context.data.spells.spells[90072] = detect;

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    anduin.read();
    auto session = anduin.session.inWorld;
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    assert(map.seesObject(7, keeper.guid));
    bool isNew;
    keeper.auras.apply(makeAura((90071 in context.data.spells.spells), 0, 60, -1, true, [300, 0, 0]), keeper.values, isNew);
    map.refreshVisibility(session);
    assert(!map.seesObject(7, keeper.guid), "invisible: gone from the player's sight");
    session.addAura(makeAura((90072 in context.data.spells.spells), 7, 60, 60_000, true, [300, 0, 0]));
    assert(map.seesObject(7, keeper.guid), "seen through it");
}

/// A charm (Enslave Demon): the creature is the player's pet while the aura lasts, then its own again.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_CHARMEDBY, UNIT_FIELD_FACTIONTEMPLATE;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto enslave = SpellInfo(1098);
    enslave.effect[0] = SpellEffect.applyAura;
    enslave.implicitTargetA[0] = ImplicitTarget.enemy;
    enslave.casting.applyAuraName[0] = AuraType.modCharm;
    enslave.casting.durationIndex = 0; // until cancelled
    enslave.casting.rangeIndex = 0;
    context.data.spells.spells[1098] = enslave;

    auto warlock = loggedIn(context, db, 7, "Gul", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    warlock.read();
    auto session = warlock.session.inWorld;
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    const ownFaction = keeper.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    session.applyAuraEffect((1098 in context.data.spells.spells), 0, keeper.guid);
    assert(session.charmed is keeper && keeper.petOwner == 7, "the player's");
    assert(keeper.values.get!UNIT_FIELD_CHARMEDBY == 7);
    assert(keeper.values.get!UNIT_FIELD_FACTIONTEMPLATE == session.player.values.get!UNIT_FIELD_FACTIONTEMPLATE);
    assert(opcodesOf(warlock.read()).canFind(Opcode.SMSG_PET_SPELLS), "its pet bar");

    keeper.loseAura(keeper.auras.find(1098), map);
    assert(session.charmed is null && keeper.petOwner == 0 && keeper.petData is null, "its own again");
    assert(keeper.values.get!UNIT_FIELD_FACTIONTEMPLATE == ownFaction);
}
