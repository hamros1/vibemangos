/**
 * Melee from the player's side: CMaNGOS's `Combat/CombatHandler.cpp` (`CMSG_ATTACKSWING`,
 * `CMSG_ATTACKSTOP`, `CMSG_SETSHEATHED`) and the player's half of `Unit`'s melee: `Attack`,
 * `AttackStop`, the swing loop (`UpdateMeleeAttackingState`), and a swing's damage
 * (`AttackerStateUpdate`, `DealMeleeDamage`, `DealDamage`), mixed into
 * `dmangos.world.character.Character`. The formulas are in `dmangos.world.combat`.
 *
 * Players fight creatures this node simulates, which fight back (`dmangos.world.creatureai`), and
 * each other in duels. Damage goes through `dmangos.world.unit.dealDamage`, the rules every unit
 * shares; `takeBlow` is the player's side of it.
 */
module dmangos.world.combathandlers;

/// See the module documentation.
mixin template CombatHandlers()
{
    import core.time : MonoTime, msecs, seconds;
    import std.math : PI;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.combat;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.relations : canAttack, canAttackNow, Relating;
    import dmangos.world.playercreate : NewSkill;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.updatefields;
    import dmangos.world.unit : Blow, BlowKind, dealDamage, UnitKind, UnitRef;

    // -----------------------------------------------------------------------
    // The player as creatures and the rules of units see it (`dmangos.world.unit`)
    // -----------------------------------------------------------------------

    /// How the relations see this player.
    package Relating relatingNow()
    {
        const v = &player.values;
        return Relating(v.get!UNIT_FIELD_FLAGS, context.client.factionTemplates.lookup(v.get!UNIT_FIELD_FACTIONTEMPLATE),
            true, 1u << (player.data.race - 1), 1u << (player.data.classId - 1), v.get!UNIT_FIELD_HEALTH > 0,
            v.get!PLAYER_DUEL_ARBITER, v.get!PLAYER_DUEL_TEAM, player.reputation, v.get!PLAYER_FLAGS);
    }

    /**
     * `Unit::DealDamage` to the player (`dmangos.world.unit.dealDamage`), from a creature, a player or
     * nothing, by a swing, a spell or an aura's tick. Unless it was a tick, a sitting player stands
     * up. A warrior gets rage from what hit it (a swing's damage before blocks; dodges, parries and
     * misses give none). A critical swing shows a wound. The player is in combat, its auras that
     * damage breaks end, and a creature's swing trains its defense. A duel's opponent never kills: a
     * blow that would leaves 1 health and ends the duel. At no health left it dies.
     */
    package void takeBlow(UnitRef attacker, uint damage, const Blow blow)
    {
        if (player is null || player.values.get!UNIT_FIELD_HEALTH == 0 || godModeCheat)
            return;
        const swing = blow.kind == BlowKind.melee;
        if (swing && blow.melee.outcome == MeleeHitOutcome.evade)
            return;
        // Between players (a pet for its owner): the PvP flags (`dmangos.world.pvp`).
        if (attacker.kind == UnitKind.player)
            pvpHitBy(attacker.session, attacker.session.isPvP);
        else if (attacker.kind == UnitKind.creature && attacker.creature.petOwner)
            pvpHitBy(cast(typeof(this)) context.onlinePlayer(attacker.creature.petOwner),
                (attacker.creature.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0);
        if (blow.kind != BlowKind.periodic && player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0)
        {
            player.values.setByte!UNIT_FIELD_BYTES_1(0, 0);
            deliver(Opcode.SMSG_STANDSTATE_UPDATE, [ubyte(0)]);
        }
        if (player.powerType == Power.rage)
        {
            const d = &blow.melee;
            if (!swing && damage)
                player.modifyPower(Power.rage, rageReward(player.data.level, damage, false));
            else if (swing && d.cleanDamage && d.outcome != MeleeHitOutcome.dodge
                && d.outcome != MeleeHitOutcome.parry && d.outcome != MeleeHitOutcome.miss)
                player.modifyPower(Power.rage, rageReward(player.data.level, d.cleanDamage, false));
        }
        if (swing && (blow.melee.hitInfo & HitInfo.criticalHit))
        {
            enum uint emoteWoundCritical = 34; // EMOTE_ONESHOT_WOUNDCRITICAL
            ByteWriter emote;
            emote.put(emoteWoundCritical);
            emote.put(player.guid);
            map.sendToWatchers(this, Opcode.SMSG_EMOTE, emote.data, true);
        }
        enterCombatFor(combatLinger);
        if (swing && attacker.kind == UnitKind.creature)
            updateCombatSkills(attacker.creature, AttackType.mainHand, true);
        if (damage)
            interruptAuras(0x2 | 0x01000000); // AURA_INTERRUPT_FLAG_DAMAGE, _NON_PERIODIC_DAMAGE
        const health = player.values.get!UNIT_FIELD_HEALTH;
        if (damage >= health && attacker.kind == UnitKind.player && duelingWith(attacker.combatGuid))
        {
            flushPlayerChanges();
            return duelLost();
        }
        const died = damage && damage >= health;
        if (damage)
            player.values.set!UNIT_FIELD_HEALTH(died ? 0 : health - damage);
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.currentHealth | GroupUpdate.currentPower);
        if (died)
        {
            // `Unit::Kill`: honor to the player who killed (or whose pet did), and its group.
            typeof(this) killer;
            if (attacker.kind == UnitKind.player)
                killer = attacker.session;
            else if (attacker.kind == UnitKind.creature && attacker.creature.petOwner)
                killer = cast(typeof(this)) context.onlinePlayer(attacker.creature.petOwner);
            if (killer !is null && killer !is this)
                killer.playerKilledByMe(this);
            if (auto copy = currentBattleground()) // `BattleGround::HandleKillPlayer`
                copy.playerKilled(player.guid, killer !is null && killer !is this ? killer.player.guid : 0);
            playerDied(attacker.kind != UnitKind.player); // only a player's kill costs no durability
        }
    }

    /// See `UnitRef.threatAdded`: a creature fights this player; it is in combat while any does.
    package void addThreatener(ulong creature)
    {
        threatenedBy[creature] = true;
        enterCombatFor(combatLinger);
    }

    /// ditto
    package void removeThreatener(ulong creature)
    {
        threatenedBy.remove(creature);
    }

private:
    bool[ulong] threatenedBy;      // `HostileRefManager`: the creatures that have this player in their threat list

    /// In combat (`UNIT_FLAG_IN_COMBAT`) at least for `linger` more.
    void enterCombatFor(Duration linger)
    {
        const until = context.clock() + linger;
        if (until > combatUntil)
            combatUntil = until;
        if (!(player.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat))
            player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS | UnitFlags.inCombat);
    }

    /**
     * `Unit::Kill` of the player, as far as there is death yet: it stops attacking, and the creatures
     * fighting it let it be. Releasing the spirit and coming back to life come with death proper; a
     * login brings it back with full health.
     */
    void playerKilled()
    {
        playerDied(true);
    }
    package ulong attacking;       // `m_attacking`: the creature attacked
    bool meleeAttacking;           // `UNIT_STAT_MELEE_ATTACKING`
    uint[2] attackTimer;           // main hand, off hand: milliseconds until the next swing may go
    SwingError lastSwingError;     // `LastSwingErrorMsg`: an error is told once until it changes
    MonoTime combatUntil;          // in combat (`UNIT_FLAG_IN_COMBAT`) until then

    /// How long a player stays in combat after its last swing.
    enum combatLinger = 5.seconds;

    /// `HandleAttackSwingOpcode`
    @Handles(Opcode.CMSG_ATTACKSWING, WorldState.inWorld)
    void handleAttackSwing(const ClientGuid request)
    {
        auto enemy = cast(Creature) map.findObject(request.guid);
        if (enemy is null)
        {
            // A player here (a duel's opponent, an enemy flagged for PvP)?
            auto other = cast(typeof(this)) context.onlinePlayer(request.guid);
            if (other !is null && other !is this && other.player !is null && other.map is map)
            {
                if (!canAttackNow(relatingNow, other.relatingNow, context.client))
                    return map.sendToWatchers(this, Opcode.SMSG_ATTACKSTOP, attackStop(player.guid, other.player.guid,
                        false), true);
                attackPlayer(other);
                lastSwingError = SwingError.none;
                return;
            }
            // Another node's creature: the fight is there.
            actAtReplica(request.guid, ArrivalAction(request.guid));
            return;
        }
        if (!canAttackNow(relatingNow, relatingOf(enemy), context.client))
        {
            // Stop the attack state at the client.
            map.sendToWatchers(this, Opcode.SMSG_ATTACKSTOP, attackStop(player.guid, enemy.guid, false), true);
            return;
        }
        attack(enemy);
        lastSwingError = SwingError.none; // each new attack shows its swing error again
    }

    /// `HandleAttackStopOpcode`: the client keeps swinging until an `SMSG_ATTACKSTOP` names it.
    @Handles(Opcode.CMSG_ATTACKSTOP, WorldState.inWorld)
    void handleAttackStop()
    {
        const meleeOn = meleeAttacking && attacking != 0;
        stopAttack(true);
        if (!meleeOn)
            map.sendToWatchers(this, Opcode.SMSG_ATTACKSTOP, attackStop(player.guid, 0, false), true);
    }

    /// `HandleSetSheathedOpcode`
    @Handles(Opcode.CMSG_SETSHEATHED, WorldState.inWorld)
    void handleSetSheathed(ref ByteReader reader)
    {
        enum maxSheathState = 3;
        const sheathed = reader.read!uint;
        if (sheathed >= maxSheathState)
            return;
        player.values.setByte!UNIT_FIELD_BYTES_2(0, cast(ubyte) sheathed);
        flushPlayerChanges();
    }

    /// How the relations see a creature.
    Relating relatingOf(const Creature creature)
    {
        return Relating(creature.values.get!UNIT_FIELD_FLAGS,
            context.client.factionTemplates.lookup(creature.values.get!UNIT_FIELD_FACTIONTEMPLATE), false, 0, 0,
            creature.alive);
    }

    /// `Unit::Attack(victim, true)`: attacks `victim` in melee; false if it cannot.
    bool attack(Creature victim)
    {
        if (!player.fighter.alive || !victim.alive || victim.ai.runningHome)
            return false;
        if (attacking)
        {
            if (attacking == victim.guid)
            {
                meleeAttackStart(victim);
                return true;
            }
            stopAttack(false, true);
        }
        attacking = victim.guid;
        victim.attackers[player.guid] = true;
        // The off hand starts half a swing late.
        if (player.fighter.dualWield)
            attackTimer[AttackType.offHand] = player.stats.attackTime[AttackType.offHand] / 2;
        meleeAttackStart(victim);
        petAssistAgainst(victim.guid); // `OwnerAttacked`
        return true;
    }

    /// `MeleeAttackStart`
    void meleeAttackStart(Creature victim)
    {
        meleeAttackStartAt(victim.guid);
    }

    /// ditto, by guid (a creature or a player)
    void meleeAttackStartAt(ulong victim)
    {
        if (meleeAttacking)
            return;
        interruptAuras(0x00001000); // AURA_INTERRUPT_FLAG_ATTACKING
        meleeAttacking = true;
        map.sendToWatchers(this, Opcode.SMSG_ATTACKSTART, attackStart(player.guid, victim), true);
    }

    /// `Unit::Attack` of a player (a duel's opponent).
    void attackPlayer(typeof(this) other)
    {
        if (!player.fighter.alive)
            return;
        if (attacking && attacking != other.player.guid)
            stopAttack(false, true);
        attacking = other.player.guid;
        if (player.fighter.dualWield)
            attackTimer[AttackType.offHand] = player.stats.attackTime[AttackType.offHand] / 2;
        meleeAttackStartAt(other.player.guid);
    }

    /// A melee swing at a player (`AttackerStateUpdate` against a player victim).
    void swingAtPlayer(typeof(this) other, AttackType type)
    {
        auto d = calculateMeleeDamage(player.fighter, other.player.fighter, type, map.random);
        map.sendToWatchers(this, Opcode.SMSG_ATTACKERSTATEUPDATE, attackerStateUpdate(d), true);
        enterCombatFor(combatLinger);
        if (player.powerType == Power.rage && type != AttackType.ranged)
            player.modifyPower(Power.rage, rageReward(player.data.level, d.damage, true));
        flushPlayerChanges();
        dealDamage(unit, other.unit, d.damage, Blow.swing(d));
    }

    /**
     * `Unit::AttackStop`: stops attacking. Unless the client asked, it is told to stop swinging
     * (`SMSG_CANCEL_COMBAT`); `targetSwitch` is set when another target follows at once.
     */
    package void stopAttack(bool clientInitiated, bool targetSwitch = false)
    {
        if (player is null)
            return;
        if (!clientInitiated)
            deliver(Opcode.SMSG_CANCEL_COMBAT, null); // `SendAttackSwingCancelAttack`
        if (meleeAttacking)
        {
            meleeAttacking = false;
            map.sendToWatchers(this, Opcode.SMSG_ATTACKSTOP, attackStop(player.guid, attacking, false), true);
        }
        if (attacking)
        {
            if (auto victim = cast(Creature) map.findObject(attacking))
                victim.attackers.remove(player.guid);
            attacking = 0;
        }
    }

    /**
     * `Unit::Update`'s attack timers and `Player::Update`'s `UpdateMeleeAttackingState`: swings when a
     * weapon is ready, or tells the client why it cannot (once, until the reason changes); and the
     * combat state, which lasts `combatLinger` after the last swing.
     */
    void updateMelee(Duration elapsed)
    {
        const ms = cast(uint) elapsed.total!"msecs";
        foreach (ref timer; attackTimer)
            timer = ms >= timer ? 0 : timer - ms;
        if (meleeAttacking)
            updateMeleeAttackingState();
        if (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat && threatenedBy.length == 0
            && context.clock() >= combatUntil)
        {
            player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
            pvpLeftCombat();
            flushPlayerChanges();
        }
    }

    /// Whether the player is in combat (`IsInCombat`).
    @property bool inCombat() const
    {
        return player !is null && (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat) != 0;
    }

    /// `updateMeleeAttackingState` against a player: the same checks, the main hand only.
    void updateMeleeAgainstPlayer(typeof(this) other)
    {
        if (attackTimer[AttackType.mainHand])
            return;
        const self = player.fighter, target = other.player.fighter;
        SwingError error;
        if (!canReachWithMelee(self, target))
            error = SwingError.notInRange;
        else if (!hasInArc(self.position, target.position, 2 * PI / 3))
            error = SwingError.badFacing;
        else if (!target.alive)
            error = SwingError.targetNotAlive;
        else if (!canAttack(relatingNow, other.relatingNow, context.client))
            return stopAttack(false); // the duel is over
        else
        {
            swingAtPlayer(other, AttackType.mainHand);
            attackTimer[AttackType.mainHand] = player.stats.attackTime[AttackType.mainHand];
        }
        if (error != SwingError.none)
            attackTimer[AttackType.mainHand] = 100;
        if (error != lastSwingError)
        {
            if (error == SwingError.notInRange)
                deliver(Opcode.SMSG_ATTACKSWING_NOTINRANGE, null);
            else if (error == SwingError.badFacing)
                deliver(Opcode.SMSG_ATTACKSWING_BADFACING, null);
            else if (error == SwingError.targetNotAlive)
                deliver(Opcode.SMSG_ATTACKSWING_DEADTARGET, null);
            lastSwingError = error;
        }
    }

    /// See `updateMelee`.
    void updateMeleeAttackingState()
    {
        auto victim = cast(Creature) map.findObject(attacking);
        if (victim is null)
        {
            auto other = cast(typeof(this)) context.onlinePlayer(attacking);
            if (other is null || other.player is null || other.map !is map)
                return stopAttack(false);
            return updateMeleeAgainstPlayer(other);
        }
        const self = player.fighter;
        const dualWield = self.dualWield;
        if (attackTimer[AttackType.mainHand] && !(dualWield && attackTimer[AttackType.offHand] == 0))
            return;
        const target = victim.fighter;
        SwingError error;
        if (!canReachWithMelee(self, target))
            error = SwingError.notInRange;
        else if (!hasInArc(self.position, target.position, 2 * PI / 3))
            error = SwingError.badFacing;
        else if (!victim.alive)
            error = SwingError.targetNotAlive;
        else if (!canAttack(relatingNow, relatingOf(victim), context.client))
            error = SwingError.cantAttack;
        else
        {
            if (attackTimer[AttackType.mainHand] == 0)
            {
                // A main hand and an off hand swing are at least 0.2 s apart.
                if (dualWield && attackTimer[AttackType.offHand] < attackDisplayDelay)
                    attackTimer[AttackType.offHand] = attackDisplayDelay;
                swing(victim, AttackType.mainHand);
                attackTimer[AttackType.mainHand] = player.stats.attackTime[AttackType.mainHand];
            }
            if (dualWield && attackTimer[AttackType.offHand] == 0 && victim.alive)
            {
                if (attackTimer[AttackType.mainHand] < attackDisplayDelay)
                    attackTimer[AttackType.mainHand] = attackDisplayDelay;
                swing(victim, AttackType.offHand);
                attackTimer[AttackType.offHand] = player.stats.attackTime[AttackType.offHand];
            }
        }
        if (error != SwingError.none)
        {
            // Delaying a weapon that is not ready would make it ready sooner.
            if (attackTimer[AttackType.mainHand] == 0)
                attackTimer[AttackType.mainHand] = 100;
            if (dualWield && attackTimer[AttackType.offHand] == 0)
                attackTimer[AttackType.offHand] = 100;
        }
        if (error != lastSwingError)
        {
            final switch (error)
            {
            case SwingError.none:
                break;
            case SwingError.notInRange:
                deliver(Opcode.SMSG_ATTACKSWING_NOTINRANGE, null);
                break;
            case SwingError.badFacing:
                deliver(Opcode.SMSG_ATTACKSWING_BADFACING, null);
                break;
            case SwingError.targetNotAlive:
                deliver(Opcode.SMSG_ATTACKSWING_DEADTARGET, null);
                break;
            case SwingError.cantAttack:
                deliver(Opcode.SMSG_ATTACKSWING_CANT_ATTACK, null);
                break;
            }
            lastSwingError = error;
        }
    }

    /**
     * `AttackerStateUpdate` and `DealMeleeDamage`: one swing at `victim`, shown to everyone who sees
     * the player; then its damage, the rage it earns, and the victim's death if it kills.
     */
    void swing(Creature victim, AttackType type)
    {
        // `AttackerStateUpdate`: a spell for the next swing (Heroic Strike) is cast instead of it.
        if (type == AttackType.mainHand && swingSpell(victim))
            return;
        auto d = calculateMeleeDamage(player.fighter, victim.fighter, type, map.random);
        map.sendToWatchers(this, Opcode.SMSG_ATTACKERSTATEUPDATE, attackerStateUpdate(d), true);

        // In combat from the first swing, until a while after the last.
        enterCombatFor(combatLinger);

        if (d.targetState == VictimState.evades)
            return flushPlayerChanges();
        updateCombatSkills(victim, type, false);
        if (d.hitInfo & HitInfo.criticalHit)
        {
            enum uint emoteWoundCritical = 34; // EMOTE_ONESHOT_WOUNDCRITICAL
            ByteWriter emote;
            emote.put(emoteWoundCritical);
            emote.put(victim.guid);
            map.sendToObservers(victim.guid, Opcode.SMSG_EMOTE, emote.data);
        }
        // `DealDamage`: rage from weapon damage dealt, then the damage.
        if (player.powerType == Power.rage && type != AttackType.ranged)
            player.modifyPower(Power.rage, rageReward(player.data.level, d.damage, true));
        flushPlayerChanges();
        // `DealMeleeDamage`: the creature fights back, takes it as threat, and may die of it.
        dealDamage(unit, map.unitOf(victim), d.damage, Blow.swing(d));
        if (d.damage && victim.alive)
            castItemCombatSpells(victim, type);
    }

    /**
     * `Player::CastItemCombatSpell` after a hit: each chance-on-hit spell of the unbroken items worn
     * (a weapon only for its own hand's swings) is cast, by its procs a minute at the weapon's speed
     * (`GetPPMProcChance`: speed * rate / 600 percent) or else the spell's own chance.
     */
    package void castItemCombatSpells(Creature victim, AttackType type)
    {
        import std.random : uniform01;
        import dmangos.world.defines : equipmentSlotEnd, equipmentSlotMainhand, equipmentSlotOffhand,
            equipmentSlotRanged;

        enum uint chanceOnHit = 2;
        uint[] procs;
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
        {
            const item = player.inventory.equipped(slot);
            if (item is null || item.proto is null || (item.maxDurability && item.durability == 0))
                continue;
            const weaponSlot = slot == equipmentSlotMainhand || slot == equipmentSlotOffhand || slot == equipmentSlotRanged;
            const own = type == AttackType.mainHand ? equipmentSlotMainhand
                : type == AttackType.offHand ? equipmentSlotOffhand : equipmentSlotRanged;
            if (weaponSlot && slot != own)
                continue;
            foreach (ref s; item.proto.details.spells)
            {
                if (s.id == 0 || s.trigger != chanceOnHit)
                    continue;
                const spell = context.data.spells.spell(s.id);
                if (spell is null)
                    continue;
                const speed = player.values.get!UNIT_FIELD_BASEATTACKTIME(type == AttackType.offHand ? 1 : 0);
                const chance = s.ppmRate > 0 ? speed * s.ppmRate / 600.0f : float(spell.casting.procChance);
                if (uniform01(map.random) * 100 < chance)
                    procs ~= s.id;
            }
        }
        foreach (id; procs)
            if (victim.alive)
                castTriggeredAt(id, victim.guid);
    }

    /**
     * `ProcSkillsAndReactives` and `Player::UpdateCombatSkills`: a swing at a creature (not a critter),
     * or one of its at the player, may raise the weapon skill or defense, more likely the farther it
     * is below its maximum (intellect helps weapon skills); then `UpdateSkill`'s own roll.
     */
    void updateCombatSkills(Creature target, AttackType type, bool defence)
    {
        import std.algorithm.comparison : min;
        import std.random : uniform, uniform01;
        import dmangos.world.defines : Stat;

        enum uint critter = 8, skillDefense = 95;
        if (target.template_.creatureType == critter)
            return;
        const skillId = defence ? skillDefense : player.weaponSkillFor(type);
        if (skillId == 0)
            return;
        const pair = player.skillValue(skillId);
        const skill = pair[0], cap = pair[1];
        const room = int(cap) - int(skill);
        if (room <= 0 || skill == 0)
            return;
        float chance = float(room / 5 > 1 ? room / 5 : 1) / (cap / 5.0f) * 100;
        if (!defence)
            chance += chance * 0.02f * player.values.get!UNIT_FIELD_STAT0(Stat.intellect);
        if (uniform01(map.random) * 100 >= chance)
            return;
        // `UpdateSkill`: the nearer the maximum, the less likely.
        if (skill * 512 >= cap * uniform!"[]"(0, 512, map.random))
            return;
        const raised = cast(ushort) min(skill + 1, cap);
        player.setSkill(skillId, raised, cap);
        player.recordSkillRow(NewSkill(skillId, raised, cap));
        context.database.saveSkill(player.data.guid, skillId, raised, cap);
        player.refreshChances(context.data);
        flushPlayerChanges();
    }

    /// `Unit::Kill` of a creature, as far as there is death yet: everyone attacking it stops.
    void creatureKilled(Creature victim)
    {
        import dmangos.world.character : Character;

        foreach (guid, _; victim.attackers)
            if (auto other = cast(Character) context.onlinePlayer(guid))
                if (other !is this)
                    other.stopAttack(false);
        stopAttack(false);
        if (victim.petOwner)
        {
            // Another's pet (a kill by a spell or a GM): dead for its owner, no reward.
            map.creatureDeath(victim);
            if (auto owner = cast(typeof(this)) map.find(victim.petOwner))
                owner.ownPetDied();
            return;
        }
        victim.die(map, context.unixTime);
        map.creatureDeaths.put(victim); // its dungeon's script and its respawn: the tick's deaths phase
        rewardKill(victim);
        // `JustDied`'s database script (`dbscripts_on_creature_death`, by entry): the creature the source, the killer the target.
        {
            import dmangos.world.dbscripts : DbScriptType;

            context.startScript(DbScriptType.creatureDeath, victim.template_.entry, map, victim.guid, player.guid);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * Melee against a creature: the attack starts, swings come at the weapon's speed, each shown to the
 * player, the creature's health falls until it dies; out of reach the client is told once; the
 * player is in combat until five seconds after its last swing.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind, count;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // Facing the innkeeper, three yards away.
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto victim = cast(Creature) context.map(0).findObject(innkeeper);
    assert(victim !is null && victim.alive);

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ATTACKSTART]);

    // The first swing goes at once; then one every swing time (unarmed: 2 s).
    anduin.session.update(50.msecs);
    auto swings = opcodesOf(anduin.read());
    assert(swings.canFind(Opcode.SMSG_ATTACKERSTATEUPDATE));
    assert(anduin.session.character.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat, "in combat");
    anduin.session.update(1000.msecs);
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_ATTACKERSTATEUPDATE), "not before the weapon is ready");

    // Swing until the innkeeper dies (it fights back, but it has 30 health to go). At its own
    // level 30 a level 1 player misses or glances for nothing nearly every time, so it is brought down to 1.
    victim.values.set!UNIT_FIELD_LEVEL(1u);
    victim.values.set!UNIT_FIELD_HEALTH(30u);
    ushort[] seen;
    foreach (_; 0 .. 200)
    {
        now += 2.seconds;
        anduin.session.update(2000.msecs);
        seen ~= opcodesOf(anduin.read());
        if (!victim.alive)
            break;
    }
    assert(!victim.alive && victim.values.get!UNIT_FIELD_HEALTH == 0);
    assert(seen.canFind(Opcode.SMSG_CANCEL_COMBAT) && seen.canFind(Opcode.SMSG_ATTACKSTOP), "the attack ends with it");
    const before = seen.count(Opcode.SMSG_ATTACKERSTATEUPDATE);
    anduin.session.update(2000.msecs);
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_ATTACKERSTATEUPDATE) && before > 0);

    // Five seconds after the last swing, out of combat.
    now += 6.seconds;
    anduin.session.update(50.msecs);
    assert(!(anduin.session.character.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat));

    // A dead creature cannot be attacked: the client is told to stop.
    anduin.read();
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ATTACKSTOP]);

    // Out of reach: told once, however long it lasts; stopping is answered.
    victim.values.set!UNIT_FIELD_HEALTH(100u);
    victim.movement.position = Position(-8951, -121, 83.5f, 0); // nine yards on
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    anduin.read();
    ushort[] far;
    foreach (_; 0 .. 5)
    {
        anduin.session.update(500.msecs);
        far ~= opcodesOf(anduin.read());
    }
    assert(far.count(Opcode.SMSG_ATTACKSWING_NOTINRANGE) == 1 && !far.canFind(Opcode.SMSG_ATTACKERSTATEUPDATE));
    anduin.write(Opcode.CMSG_ATTACKSTOP, null);
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ATTACKSTOP]);
}

/// A kill's respawn time is set in the tick's deaths phase (docs/DESIGN.md, step 4), not where it dies.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.unit : Blow, dealDamage;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    foreach (ref spawn; context.data.creatureSpawns)
        if (spawn.guid == innkeeperSpawn)
            spawn.respawnSeconds = 300; // not back within the test's tick
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    dealDamage(anduin.session.inWorld.unit, map.unitOf(keeper), keeper.values.get!UNIT_FIELD_HEALTH, Blow.spell());
    assert(!keeper.alive && innkeeperSpawn !in db.creatureRespawns, "dead; the world has not looked yet");
    now += 50.msecs;
    context.update(now);
    assert(innkeeperSpawn in db.creatureRespawns, "its respawn time, from the deaths phase");
}
