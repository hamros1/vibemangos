/**
 * The spell effects of a player's cast beyond damage, healing and auras (`dmangos.world.spellhandlers`
 * keeps those), mixed into `dmangos.world.character.Character`: what a fight is about (threat, taunts,
 * leaving every fight), moving at once (charging, leaping), taking power and health (burns, drains, leeches),
 * extra swings, removing a mechanic's auras, distracting, the hunters' traps, and getting unstuck.
 *
 * Each does what CMaNGOS's `Spell::Effect...` does, and tells the clients as it does: the combat log's
 * `SMSG_SPELLLOGEXECUTE` (`dmangos.world.spellcast.executeLog`), the damage and heal logs, a charge's
 * `SMSG_MONSTER_MOVE`. A creature's half (its threat list, its taunts) is `dmangos.world.creatureai`'s.
 */
module dmangos.world.effecthandlers;

import dmangos.world.movement : Position;

/// `BASE_CHARGE_SPEED`: yards a second of a charge whose spell has no speed of its own.
enum float baseChargeSpeed = 27;

/// How far a leap looks ahead at a time, and the steepest slope it climbs (CMaNGOS's
/// `TARGET_LOCATION_CASTER_FRONT_LEAP`).
enum float leapStep = 2, leapMaxSlope = 50; // yards, degrees

/**
 * Where a leap (Blink) of `distance` yards along `from`'s facing ends: step by step, each step on the ground
 * (`groundAt` near a height; NaN where there is none), clear of what is built (`clear`), and no steeper than
 * `leapMaxSlope`; the last good step is where it lands, `from` itself if the first is not.
 */
Position leapDestination(Position from, float distance, scope float delegate(float x, float y, float z) groundAt,
    scope bool delegate(Position a, Position b) clear)
{
    import std.math : atan, ceil, cos, isNaN, PI, sin;

    if (distance <= 0)
        return from;
    const steps = cast(uint) ceil(distance / leapStep);
    const dx = distance * cos(from.orientation) / steps, dy = distance * sin(from.orientation) / steps;
    const stepLength = distance / steps;
    Position at = from;
    foreach (_; 0 .. steps)
    {
        auto next = Position(at.x + dx, at.y + dy, at.z + 1, from.orientation);
        const ground = groundAt(next.x, next.y, next.z);
        if (isNaN(ground))
            break; // no ground to land on (a cliff's edge, water: CMaNGOS swims on; here it stops)
        next.z = ground;
        if (!clear(at, next))
            break;
        const climb = next.z > at.z ? next.z - at.z : at.z - next.z;
        if (atan(climb / stepLength) > leapMaxSlope * PI / 180)
            break;
        at = next;
    }
    return at;
}

///
unittest
{
    import std.math : isClose, isNaN;

    const start = Position(0, 0, 10, 0); // facing +x
    float flat(float, float, float) { return 10; }
    bool open(Position, Position) { return true; }
    auto end = leapDestination(start, 20, &flat, &open);
    assert(isClose(end.x, 20) && isClose(end.y, 0, 0.0, 1e-4) && end.z == 10, "the whole way on flat ground");

    // A wall at x = 7: the last step before it.
    bool wall(Position a, Position b) { return b.x < 7; }
    end = leapDestination(start, 20, &flat, &wall);
    assert(isClose(end.x, 6), "stopped before the wall");

    // A cliff's edge at x = 9 (no ground after), and a steep rise at x = 13.
    float cliff(float x, float, float) { return x > 9 ? float.nan : 10; }
    assert(isClose(leapDestination(start, 20, &cliff, &open).x, 8));
    float rise(float x, float, float) { return x > 13 ? 20 : 10; }
    assert(isClose(leapDestination(start, 20, &rise, &open).x, 12), "too steep to climb");
}

/// See the module documentation.
mixin template EffectHandlers()
{
    import std.math : atan2, cos, isNaN, sin, sqrt;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.auras : Aura, AuraType;
    import dmangos.world.effecthandlers : baseChargeSpeed;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : executeLog, executeTarget, healLog, energizeLog, SpellCastResult,
        SpellTargets, TargetFlags;
    import dmangos.world.spellids;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.unit : UnitKind, UnitRef;
    import dmangos.world.updatefields;

    /// The combat log's line of effect `i` of `spell` on its target (`targetData`: `executeTarget`).
    private void logExecute(const(SpellInfo)* spell, size_t i, const(ubyte)[] targetData)
    {
        map.sendToWatchers(this, Opcode.SMSG_SPELLLOGEXECUTE, executeLog(player.guid, spell.id,
            cast(uint) spell.effect[i], targetData), true);
    }

    /// The player `guid` on this map: this one, or another online here; null if neither.
    private typeof(this) playerHere(ulong guid)
    {
        if (guid == player.guid)
            return this;
        auto other = cast(typeof(this)) context.onlinePlayer(guid);
        return other !is null && other.player !is null && other.map is map ? other : null;
    }

    /// The living creature `guid` here, with its AI; null if none.
    private Creature livingCreature(ulong guid)
    {
        auto creature = cast(Creature) map.findObject(guid);
        return creature !is null && creature.alive && creature.ai !is null ? creature : null;
    }

    // -----------------------------------------------------------------------
    // Threat and taunts
    // -----------------------------------------------------------------------

    /**
     * `SPELL_EFFECT_THREAT` (Distracting Shot, Cower, Feint): the creature's threat of this player changes by
     * `value`, times the player's threat auras for the spell's school (`MOD_THREAT`). Threat added pulls it into a
     * fight; threat taken never leaves less than none, and a creature not fighting the player is left alone.
     */
    void threatEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        auto creature = livingCreature(target);
        if (creature is null || creature.petOwner || !player.fighter.alive)
            return;
        const school = spell.casting.school;
        const amount = value * (school < 7 ? player.damageMods.threat[school] : 1);
        const had = creature.ai.threatOf(player.guid);
        if (amount > 0)
        {
            creature.ai.attackedBy(unit, map);
            creature.ai.addThreat(unit, amount);
        }
        else if (had > 0)
            creature.ai.addThreat(unit, amount < -had ? -had : amount);
        else
            return;
        map.wake(creature.guid);
        logExecute(spell, i, executeTarget(target));
    }

    /**
     * `SPELL_EFFECT_ATTACK_ME` (Growl, Taunt): the creature takes this player as the one it hates most
     * (`CreatureAI.taunt`); one already attacking it is not taunted again. Its taunt aura (`MOD_TAUNT`, the
     * spell's other effect) then keeps it on the player while it lasts.
     */
    void attackMeEffect(const(SpellInfo)* spell, size_t i, ulong target)
    {
        auto creature = livingCreature(target);
        if (creature is null || creature.petOwner || creature.ai.currentVictim == player.guid)
            return;
        creature.ai.taunt(unit, map);
        logExecute(spell, i, executeTarget(target));
    }

    /**
     * Out of every fight at once (CMaNGOS's `CombatStop`: Vanish, Divine Intervention, a successful Feign
     * Death): the player stops attacking, every creature fighting it forgets it, and it is out of combat.
     */
    package void leaveAllFights()
    {
        stopAttack(false);
        foreach (guid; threatenedBy.keys)
            if (auto creature = livingCreature(guid))
                creature.ai.forget(player.guid, map);
        threatenedBy = null;
        combatUntil = context.clock();
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        if (flags & UnitFlags.inCombat)
        {
            player.values.set!UNIT_FIELD_FLAGS(flags & ~UnitFlags.inCombat);
            pvpLeftCombat();
        }
        flushPlayerChanges();
    }

    /**
     * `SPELL_EFFECT_SANCTUARY` (Vanish, Divine Intervention): the target leaves every fight; Vanish frees its
     * rogue of what roots it as well (CMaNGOS's `EffectSanctuary`).
     */
    void sanctuaryEffect(const(SpellInfo)* spell, size_t i, ulong target)
    {
        enum uint familyRogue = 8;
        enum ulong vanish = 0x800;
        auto who = playerHere(target);
        if (who is null)
            return;
        who.leaveAllFights();
        if (spell.casting.spellFamilyName == familyRogue && (spell.casting.spellFamilyFlags & vanish))
            foreach (aura; who.player.auras.list.dup)
                if (aura.has(AuraType.modRoot))
                    who.removeAura(aura);
        logExecute(spell, i, executeTarget(target));
    }

    /// A successful Feign Death lasts: creatures leave the player alone (`untouchable`).
    package bool feigningDeath;

    /**
     * `SPELL_AURA_FEIGN_DEATH` began (`apply`) or ended (CMaNGOS's `HandleFeignDeath`, `SetFeignDeath`). It may
     * be seen through: the roll of the player's own spell missing the highest-level creature fighting it; then
     * `SMSG_FEIGN_DEATH_RESISTED` and it only stops attacking. Otherwise it leaves every fight, its casts and
     * shots stop, and creatures leave it be until it stands up. Either way it looks dead while the aura lasts
     * (`UNIT_DYNFLAG_DEAD`, `AuraSet`).
     */
    void feignDeathAura(const Aura aura, bool apply)
    {
        import std.random : uniform01;
        import dmangos.world.spellcast : spellMissChance;

        if (!apply)
        {
            if (!player.auras.has(AuraType.feignDeath))
                feigningDeath = false;
            return;
        }
        if (map is null) // loaded with the character: nobody fights it yet
            return cast(void)(feigningDeath = true);
        float resist = 0;
        foreach (guid; threatenedBy.keys)
            if (auto creature = livingCreature(guid))
                if (!creature.petOwner)
                {
                    const chance = spellMissChance(player.data.level, creature.values.get!UNIT_FIELD_LEVEL, false);
                    resist = chance > resist ? chance : resist;
                }
        if (generic.active)
            interruptCast(SpellCastResult.interrupted);
        stopAutoRepeat();
        if (uniform01(map.random) * 100 < resist)
        {
            deliver(Opcode.SMSG_FEIGN_DEATH_RESISTED, null);
            stopAttack(false);
            return;
        }
        feigningDeath = true;
        leaveAllFights();
    }

    private float[ulong] fadedThreat; /// the threat Fade took from each creature, given back as it ends

    /**
     * `SPELL_AURA_MOD_TOTAL_THREAT` (Fade): while it lasts the player has its (negative) amount less threat with
     * every creature fighting it, never below none; as it ends that is given back (CMaNGOS's
     * `threatTemporaryFade`).
     */
    void fadeThreat(const Aura aura, size_t i, bool apply)
    {
        if (player is null || map is null || aura.caster != player.guid)
            return;
        if (apply)
        {
            foreach (guid; threatenedBy.keys)
                if (auto creature = livingCreature(guid))
                {
                    const had = creature.ai.threatOf(player.guid);
                    const want = -float(aura.amount[i]);
                    const take = want < had ? want : had;
                    if (take <= 0)
                        continue;
                    creature.ai.addThreat(unit, -take);
                    fadedThreat[guid] = fadedThreat.get(guid, 0) + take;
                }
            return;
        }
        foreach (guid, took; fadedThreat)
            if (auto creature = livingCreature(guid))
                if ((player.guid in creature.ai.threatList) !is null)
                    creature.ai.addThreat(unit, took);
        fadedThreat = null;
    }

    /**
     * `SPELL_AURA_TRACK_CREATURES` (Track Beasts, Sense Demons), `SPELL_AURA_TRACK_RESOURCES` (Find Herbs, Find
     * Minerals, Find Treasure): the bit of the misc value's type (from 1) in `PLAYER_TRACK_CREATURES` or
     * `PLAYER_TRACK_RESOURCES`, for the minimap (CMaNGOS's `HandleAuraTrackCreatures`).
     */
    void trackingAura(const Aura aura, size_t i, bool apply)
    {
        if (aura.type(i) == AuraType.trackStealthed) // Track Hidden: `PLAYER_FIELD_BYTE_TRACK_STEALTHED`
        {
            enum ubyte trackStealthed = 0x02;
            const bytes = player.values.getByte!PLAYER_FIELD_BYTES(0);
            player.values.setByte!PLAYER_FIELD_BYTES(0, cast(ubyte)(player.auras.has(AuraType.trackStealthed)
                ? bytes | trackStealthed : bytes & ~trackStealthed));
            return;
        }
        const misc = aura.misc(i);
        if (misc < 1 || misc > 32)
            return;
        const bit = 1u << (misc - 1);
        if (aura.type(i) == AuraType.trackCreatures)
        {
            const now = player.values.get!PLAYER_TRACK_CREATURES;
            player.values.set!PLAYER_TRACK_CREATURES(apply ? now | bit : now & ~bit);
        }
        else
        {
            const now = player.values.get!PLAYER_TRACK_RESOURCES;
            player.values.set!PLAYER_TRACK_RESOURCES(apply ? now | bit : now & ~bit);
        }
    }

    /**
     * `SPELL_AURA_MOD_UNATTACKABLE` (Divine Intervention): as it begins the player leaves every fight; while any
     * lasts nothing may target it (`UNIT_FLAG_UNTARGETABLE`; CMaNGOS's `HandleModUnattackable`).
     */
    void unattackableAura(bool apply)
    {
        if (apply && map !is null)
            leaveAllFights();
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        player.values.set!UNIT_FIELD_FLAGS(player.auras.has(AuraType.modUnattackable) ? flags | UnitFlags.untargetable
            : flags & ~UnitFlags.untargetable);
    }

    /// The attack power `victim`'s auras give a ranged attack at it (Hunter's Mark).
    package int rangedAttackerBonus(UnitRef victim)
    {
        final switch (victim.kind)
        {
        case UnitKind.none:
            return 0;
        case UnitKind.player:
            return victim.session.player.auras.total(AuraType.rangedAttackPowerAttackerBonus);
        case UnitKind.creature:
            return victim.creature.auras.total(AuraType.rangedAttackPowerAttackerBonus);
        }
    }

    // -----------------------------------------------------------------------
    // Drains over time
    // -----------------------------------------------------------------------

    /**
     * A tick of this player's `SPELL_AURA_PERIODIC_LEECH` (Drain Life, Siphon Life) on `victim`: its damage,
     * logged as a periodic spell hit (`SMSG_SPELLNONMELEEDAMAGELOG`, as CMaNGOS's leech sends), and the player
     * healed by what it took (at most the victim's health) times the effect's multiplier (`healSelf`).
     */
    package void leechTick(UnitRef victim, Aura aura, size_t i, uint damage)
    {
        import dmangos.world.spellcast : nonMeleeDamageLog;
        import dmangos.world.unit : Blow, dealDamage;

        if (!victim || !victim.fighter.alive)
            return;
        const school = aura.spell.casting.school;
        const absorbed = victim.absorb(school, damage);
        const health = victim.health;
        const dealt = damage < health ? damage : health;
        tellAround(victim.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.combatGuid,
            player.guid, aura.spell.id, damage, school, absorbed, 0, true, 0, false));
        if (victim.kind == UnitKind.creature)
            spellAttacked(victim.creature, damage, true, school);
        else
            dealDamage(unit, victim, damage, Blow.periodic(school));
        const factor = aura.spell.casting.multipleValue[i] > 0 ? aura.spell.casting.multipleValue[i] : 1.0f;
        if (player.fighter.alive)
            healSelf(aura.spell, cast(uint)(dealt * spellMod(SpellModOp.multipleValue, aura.spell, factor)));
    }

    /**
     * A tick of this player's `SPELL_AURA_PERIODIC_MANA_LEECH` (Drain Mana, Viper Sting) on `victim`: up to its
     * amount of the victim's power of the misc value's kind is drained, logged (`SMSG_PERIODICAURALOG` with the
     * gain multiplier), and the player gets it times the multiplier if it has that power at all; a creature
     * drained hates it by half the gain (CMaNGOS's `PERIODIC_MANA_LEECH` tick).
     */
    package void manaLeechTick(UnitRef victim, Aura aura, size_t i, uint amount)
    {
        const kind = aura.misc(i);
        uint now;
        if (!victim || !victim.fighter.alive || !player.fighter.alive || kind < 0 || kind > Power.happiness
                || !powerOf(victim, cast(Power) kind, now))
            return;
        const power = cast(Power) kind;
        const drained = now < amount ? now : amount;
        takePower(victim, power, drained);
        const gainFactor = player.values.get!UNIT_FIELD_MAXPOWER1(power) > 0 ? multiplier(aura.spell, i) : 0.0f;
        periodicLog(victim.combatGuid, aura, i, drained, power, 0, gainFactor);
        const gain = cast(int)(drained * gainFactor);
        if (gain <= 0)
            return;
        player.modifyPower(power, gain);
        flushPlayerChanges();
        if (victim.kind == UnitKind.creature && victim.creature.ai !is null)
            victim.creature.ai.addThreat(unit, gain * 0.5f);
    }

    // -----------------------------------------------------------------------
    // What strikes back and what is shared
    // -----------------------------------------------------------------------

    /**
     * A swing `attacker` struck at this player was blocked: each `SPELL_AURA_PROC_TRIGGER_DAMAGE` aura that procs
     * on being struck (Holy Shield, Blessing of Sanctuary: `spell_proc_event` has them on a block only) rolls its
     * chance and hurts the attacker by its amount in its spell's school (`SMSG_SPELLNONMELEEDAMAGELOG`), a charge
     * used (CMaNGOS's `HandleProcTriggerDamageAuraProc`).
     */
    package void blockDamageProcs(UnitRef attacker)
    {
        import std.random : uniform01;
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.spellcast : nonMeleeDamageLog;
        import dmangos.world.unit : Blow, dealDamage;

        if (!attacker || player is null)
            return;
        Aura[] spent;
        foreach (aura; player.auras.list.dup)
        {
            if (!(aura.spell.casting.procFlags & ProcFlag.takeMeleeSwing))
                continue;
            foreach (i; 0 .. 3)
            {
                if (!(aura.effects & (1 << i)) || aura.type(i) != AuraType.procTriggerDamage || aura.amount[i] <= 0)
                    continue;
                if (uniform01(map.random) * 100 >= aura.spell.casting.procChance || !attacker.fighter.alive)
                    continue;
                const school = aura.spell.casting.school;
                const damage = cast(uint) aura.amount[i];
                tellAround(attacker.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(
                    attacker.combatGuid, player.guid, aura.spell.id, damage, school, 0, 0, false, 0, false));
                dealDamage(unit, attacker, damage, Blow.spell(school));
                if (aura.charges && --aura.charges == 0)
                    spent ~= aura;
            }
        }
        foreach (aura; spent)
            removeAura(aura);
    }

    /**
     * `SPELL_AURA_SPLIT_DAMAGE_FLAT` (Blessing of Sacrifice) on this player: of `damage` of school `school` about
     * to hit it, up to each aura's amount goes to the aura's caster instead, if it is another player here and
     * alive (logged as the protected player's damage to it: CMaNGOS's split damage). Returns what was split off.
     */
    package uint splitDamage(uint school, ref uint damage)
    {
        import dmangos.world.spellcast : nonMeleeDamageLog;
        import dmangos.world.unit : Blow, dealDamage;

        uint split;
        foreach (aura; player.auras.list.dup)
            foreach (i; 0 .. 3)
            {
                if (damage == 0 || !(aura.effects & (1 << i)) || aura.type(i) != AuraType.splitDamageFlat
                        || !(aura.misc(i) & (1 << school)) || aura.amount[i] <= 0 || aura.caster == player.guid)
                    continue;
                auto caster = playerHere(aura.caster);
                if (caster is null || !caster.player.fighter.alive)
                    continue;
                const take = damage < cast(uint) aura.amount[i] ? damage : cast(uint) aura.amount[i];
                damage -= take;
                split += take;
                tellAround(caster.player.guid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(caster.player.guid,
                    player.guid, aura.spell.id, take, school, 0, 0, false, 0, false));
                dealDamage(UnitRef.init, caster.unit, take, Blow.spell(school));
            }
        return split;
    }

    // -----------------------------------------------------------------------
    // Moving at once
    // -----------------------------------------------------------------------

    /**
     * `SPELL_EFFECT_CHARGE` (Charge, Intercept, Feral Charge): the player runs to its target at the spell's
     * speed (27 yards a second if it has none) and stops at its reach, facing it: the clients are shown the run
     * (`SMSG_MONSTER_MOVE` of the player, which its own client follows too), and the player is where it ends.
     * At an enemy it starts attacking (CMaNGOS's `EffectCharge`, `MoveCharge`).
     */
    void chargeEffect(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : nextSplineId;
        import dmangos.world.spline : monsterMove, MoveSpline, SplineFlags;
        import dmangos.world.terrain : invalidHeight;

        auto victim = map.unit(target);
        if (!victim || target == player.guid || !player.fighter.alive)
            return;
        const from = player.position, to = victim.fighter.position;
        const reach = victim.fighter.combatReach;
        const dx = from.x - to.x, dy = from.y - to.y;
        const apart = sqrt(dx * dx + dy * dy);
        Position end = to;
        if (apart > reach)
        {
            end.x = to.x + dx / apart * reach;
            end.y = to.y + dy / apart * reach;
        }
        const ground = map.groundHeight(end.x, end.y, end.z + 2, false);
        if (ground > invalidHeight)
            end.z = ground;
        end.orientation = atan2(to.y - end.y, to.x - end.x);
        if ((end.x - from.x) ^^ 2 + (end.y - from.y) ^^ 2 >= 0.01f)
        {
            auto path = map.pathBetween(Vector3(from.x, from.y, from.z), Vector3(end.x, end.y, end.z));
            if (path.length < 2)
                path = [Vector3(from.x, from.y, from.z), Vector3(end.x, end.y, end.z)];
            path[0] = Vector3(from.x, from.y, from.z);
            const speed = spell.casting.speed > 0 ? spell.casting.speed : baseChargeSpeed;
            auto spline = MoveSpline(path, SplineFlags.runMode | SplineFlags.finalAngle, speed, nextSplineId(),
                end.orientation);
            map.sendToWatchers(this, Opcode.SMSG_MONSTER_MOVE, monsterMove(player.guid, spline), true);
        }
        arriveAt(end);
        if (victim.kind == UnitKind.creature)
            attack(victim.creature);
        else if (auto other = playerHere(target))
            if (canAttack(relatingNow(), other.relatingNow(), context.client))
                attackPlayer(other);
    }

    /// The server moved the player to `at` on its map (a charge): there for the map, and for its movement check.
    private void arriveAt(Position at)
    {
        player.movement.position = at;
        checkpoint = at;
        checkpointTime = context.clock();
        map.relocated(this);
    }

    /**
     * `SPELL_EFFECT_LEAP` (Blink): the player is teleported its radius ahead along its facing, stopping before
     * what is built and where the ground falls away or climbs too steeply (`leapDestination`); without map
     * data the ground is taken as level.
     */
    void leapEffect(const(SpellInfo)* spell, size_t i)
    {
        import dmangos.world.effecthandlers : leapDestination;
        import dmangos.world.spellcast : radius;
        import dmangos.world.terrain : invalidHeight;

        const distance = spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));
        const p = player.position; // no heights where it stands (no map files, tests): level ground
        const level = map.collision is null || !(map.groundHeight(p.x, p.y, p.z + 1, false) > invalidHeight);
        float groundAt(float x, float y, float z)
        {
            if (level)
                return z - 1;
            const h = map.groundHeight(x, y, z, false);
            return h > invalidHeight && h > z - 10 ? h : float.nan;
        }

        bool clear(Position a, Position b)
        {
            return map.inLineOfSight(a, b);
        }

        const end = leapDestination(player.position, distance, &groundAt, &clear);
        commandTeleport(player.data.map, end);
    }

    /**
     * `SPELL_EFFECT_STUCK` (Stuck, from the help menu): a ghost goes to its graveyard; the living hearth home if
     * the Hearthstone is in the bags and ready, else are nudged ten yards ahead (CMaNGOS's `EffectStuck`).
     */
    void stuckEffect()
    {
        import dmangos.world.player : DeathState;

        enum uint hearthstoneSpell = 8690, hearthstoneItem = 6948;
        if (flying)
            return;
        if (player.deathState == DeathState.ghost)
            return repopAtGraveyard();
        if (spellIsReady(hearthstoneSpell) && player.inventory.count(hearthstoneItem) > 0)
            if (const hearth = context.data.spells.spell(hearthstoneSpell))
            {
                castSpell(hearth, SpellTargets(TargetFlags.self, player.guid), true, 0);
                return;
            }
        auto at = player.position;
        at.x += 10 * cos(at.orientation);
        at.y += 10 * sin(at.orientation);
        const ground = map.groundHeight(at.x, at.y, at.z + 5, false);
        import dmangos.world.terrain : invalidHeight;

        if (ground > invalidHeight)
            at.z = ground;
        commandTeleport(player.data.map, at);
    }

    // -----------------------------------------------------------------------
    // Power and health
    // -----------------------------------------------------------------------

    /// A unit's power of `power` now, and whether that is its power at all (a warrior has no mana).
    private bool powerOf(UnitRef who, Power power, out uint now)
    {
        final switch (who.kind)
        {
        case UnitKind.none:
            return false;
        case UnitKind.player:
            now = who.session.player.values.get!UNIT_FIELD_POWER1(power);
            return power == Power.happiness || who.session.player.powerType == power;
        case UnitKind.creature:
            now = who.creature.values.get!UNIT_FIELD_POWER1(power);
            return power == Power.happiness || who.creature.values.getByte!UNIT_FIELD_BYTES_0(3) == power;
        }
    }

    /// Takes `amount` of a unit's `power` (it has as much).
    private void takePower(UnitRef who, Power power, uint amount)
    {
        final switch (who.kind)
        {
        case UnitKind.none:
            return;
        case UnitKind.player:
            who.session.player.modifyPower(power, -cast(int) amount);
            if (who.session !is this)
                who.session.flushPlayerChanges();
            return;
        case UnitKind.creature:
            const now = who.creature.values.get!UNIT_FIELD_POWER1(power);
            who.creature.values.set!UNIT_FIELD_POWER1(power, now > amount ? now - amount : 0);
            map.flushObjectChanges(who.creature);
            return;
        }
    }

    /// The effect's multiplier (`EffectMultipleValue`) as the caster's talents make it (`SPELLMOD_MULTIPLE_VALUE`).
    private float multiplier(const(SpellInfo)* spell, size_t i)
    {
        return spellMod(SpellModOp.multipleValue, spell, spell.casting.multipleValue[i]);
    }

    /**
     * `SPELL_EFFECT_POWER_BURN` (Mana Burn): up to `value` of the target's power of the effect's kind is burned
     * away, and the target takes the burned amount times the effect's multiplier as the spell's damage (with no
     * spell power: CMaNGOS's `EffectPowerBurn`). A target of another power is not touched.
     */
    void powerBurnEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        const kind = spell.miscValue[i];
        auto victim = map.unit(target);
        uint now;
        if (kind < 0 || kind > Power.happiness || value <= 0 || !victim || !victim.fighter.alive
                || !powerOf(victim, cast(Power) kind, now))
            return;
        const burned = now < value ? now : cast(uint) value;
        takePower(victim, cast(Power) kind, burned);
        const damage = cast(uint)(burned * multiplier(spell, i));
        if (victim.kind == UnitKind.creature)
            spellDamage(spell, victim.creature, damage, spell.casting.school, false);
        else if (auto other = enemyPlayer(target))
            spellDamageToPlayer(spell, other, damage, false);
    }

    /**
     * `SPELL_EFFECT_POWER_DRAIN` (Dark Pact, Drain Mana's kind at once): up to `value` of the target's power of the
     * effect's kind goes to the caster, times the effect's multiplier if that is the caster's power too
     * (`SMSG_SPELLENERGIZELOG`), and the combat log says how much was drained (CMaNGOS's `EffectPowerDrain`).
     */
    void powerDrainEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        const kind = spell.miscValue[i];
        auto victim = map.unit(target);
        uint now;
        if (kind < 0 || kind > Power.happiness || value < 0 || !victim || !victim.fighter.alive
                || !powerOf(victim, cast(Power) kind, now))
            return;
        const power = cast(Power) kind;
        const drained = now < value ? now : cast(uint) value;
        takePower(victim, power, drained);
        const gainFactor = player.powerType == power && target != player.guid ? multiplier(spell, i) : 1.0f;
        logExecute(spell, i, executeTarget(target, drained, cast(uint) power, gainFactor));
        if (const gain = cast(int)(drained * gainFactor))
        {
            player.modifyPower(power, gain);
            map.sendToWatchers(this, Opcode.SMSG_SPELLENERGIZELOG, energizeLog(player.guid, player.guid, spell.id,
                power, gain), true);
            flushPlayerChanges();
        }
    }

    /**
     * Health back to this player from its own spell (a leech's), as much as it lacks, and the heal log
     * (CMaNGOS's `DealHeal`): no spell power, no crit; what heals it less (`healingTaken`) does.
     */
    package void healSelf(const(SpellInfo)* spell, uint amount)
    {
        import dmangos.world.spellcast : healLog;

        if (amount == 0 || player.values.get!UNIT_FIELD_HEALTH == 0)
            return;
        amount = player.auras.healingTaken(amount, spell.casting.school);
        const health = player.values.get!UNIT_FIELD_HEALTH, maxHealth = player.values.get!UNIT_FIELD_MAXHEALTH;
        player.values.set!UNIT_FIELD_HEALTH(health + amount > maxHealth ? maxHealth : health + amount);
        map.sendToWatchers(this, Opcode.SMSG_SPELLHEALLOG, healLog(player.guid, player.guid, spell.id, amount, false),
            true);
        flushPlayerChanges();
    }

    /**
     * `SPELL_EFFECT_HEALTH_LEECH` (Death Coil): the spell's damage to the target (at most what health it has),
     * and the caster healed by it times the effect's multiplier (CMaNGOS's `EffectHealthLeech`).
     */
    void healthLeechEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        auto victim = map.unit(target);
        if (value < 0 || !victim || !victim.fighter.alive)
            return;
        const health = victim.health;
        uint dealt;
        if (victim.kind == UnitKind.creature)
            dealt = spellDamage(spell, victim.creature, cast(uint) value, spell.casting.school);
        else if (auto other = enemyPlayer(target))
            dealt = spellDamageToPlayer(spell, other, cast(uint) value);
        if (dealt > health)
            dealt = health;
        if (player.fighter.alive)
            healSelf(spell, cast(uint)(dealt * multiplier(spell, i)));
    }

    /**
     * `SPELL_EFFECT_HEAL_MAX_HEALTH` (Lay on Hands): the target healed by the caster's maximum health, its heal
     * logged (CMaNGOS's `EffectHealMaxHealth`).
     */
    void healMaxHealthEffect(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.spellcast : healLog;

        auto who = playerHere(target);
        if (who is null || who.player.values.get!UNIT_FIELD_HEALTH == 0)
            return;
        const amount = player.values.get!UNIT_FIELD_MAXHEALTH;
        auto v = &who.player.values;
        const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
        v.set!UNIT_FIELD_HEALTH(health + amount > maxHealth ? maxHealth : health + amount);
        if (who !is this)
            pvpAssisted(who);
        map.sendToWatchers(this, Opcode.SMSG_SPELLHEALLOG, healLog(target, player.guid, spell.id, amount, false), true);
        who.flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Extra swings, mechanics, distraction
    // -----------------------------------------------------------------------

    package ubyte extraAttacks;          /// swings owed by Sword Specialization, Reckoning (`updateMeleeAttackingState`)
    package bool extraAttacksExecuting;  /// ... being swung: they grant no more of them

    /**
     * `SPELL_EFFECT_ADD_EXTRA_ATTACKS` (Sword Specialization, Reckoning): `value` more main-hand swings at the
     * player's victim, at most five owed, swung at its next melee update (CMaNGOS's `EffectAddExtraAttacks` and
     * `DoExtraAttacks`); the combat log's "You gain 1 extra attack".
     */
    void addExtraAttacksEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        if (target != player.guid || !player.fighter.alive || value <= 0)
            return;
        extraAttacks = cast(ubyte)(extraAttacks + value > 5 ? 5 : extraAttacks + value);
        logExecute(spell, i, executeTarget(target, cast(uint) value));
    }

    /// Whether the aura is of mechanic `mechanic` (its spell's, or one of its effects').
    private static bool ofMechanic(const Aura aura, uint mechanic)
    {
        if (aura.spell.casting.mechanic == mechanic)
            return true;
        foreach (j; 0 .. 3)
            if ((aura.effects & (1 << j)) && aura.spell.casting.effectMechanic[j] == mechanic)
                return true;
        return false;
    }

    /**
     * `SPELL_EFFECT_DISPEL_MECHANIC` (Escape Artist's roots and snares, Polymorph's mount): up to `value` (at
     * least one) of the target's auras of the effect's mechanic go, picked at random (CMaNGOS's
     * `EffectDispelMechanic`).
     */
    void dispelMechanicEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        import std.random : uniform;

        const mechanic = cast(uint) spell.miscValue[i];
        if (mechanic == 0)
            return;
        auto count = value > 0 ? value : 1;
        if (auto creature = livingCreature(target))
        {
            Aura[] found;
            foreach (aura; creature.auras.list)
                if (ofMechanic(aura, mechanic))
                    found ~= aura;
            for (; count > 0 && found.length; --count)
            {
                const k = uniform(0, found.length, map.random);
                creature.loseAura(found[k], map);
                found = found[0 .. k] ~ found[k + 1 .. $];
            }
            map.flushObjectChanges(creature);
        }
        else if (auto who = playerHere(target))
        {
            Aura[] found;
            foreach (aura; who.player.auras.list)
                if (!aura.passive && ofMechanic(aura, mechanic))
                    found ~= aura;
            for (; count > 0 && found.length; --count)
            {
                const k = uniform(0, found.length, map.random);
                who.removeAura(found[k]);
                found = found[0 .. k] ~ found[k + 1 .. $];
            }
        }
        else
            return;
        logExecute(spell, i, executeTarget(target));
    }

    /**
     * `SPELL_EFFECT_DISTRACT` (Distract): a creature out of combat stops, faces the spot thrown at and stands
     * so for `value` seconds (`CreatureAI.distract`; CMaNGOS's `EffectDistract`).
     */
    void distractEffect(const(SpellInfo)* spell, size_t i, ulong target, int value, const ref SpellTargets targets)
    {
        auto creature = livingCreature(target);
        if (creature is null || creature.ai.inCombat)
            return;
        const at = (targets.mask & TargetFlags.destLocation)
            ? Position(targets.dest[0], targets.dest[1], targets.dest[2]) : player.position;
        creature.ai.distract(at, value * 1000, map);
        logExecute(spell, i, executeTarget(target));
    }

    // -----------------------------------------------------------------------
    // The hunters' traps (`SPELL_EFFECT_SUMMON_OBJECT_SLOT1` .. 4)
    // -----------------------------------------------------------------------

    package ulong[4] trapSlots;   /// this player's traps by slot (fire, frost, nature, ...): their guids
    private int[4] trapTimes;     /// ... and ms each lasts yet

    /**
     * A trap is put down (`SPELL_EFFECT_SUMMON_OBJECT_SLOT1` .. 4: Freezing, Frost, Immolation and Explosive
     * Trap): the game object of the effect's entry at the spot thrown at, else at the player's feet (its
     * radius ahead), owned by the player and of its level, for the spell's duration; the slot's old one goes
     * (CMaNGOS's `EffectSummonObject`). It springs on the first enemy within its radius (`updateTraps`).
     */
    void summonTrapEffect(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
    {
        import dmangos.world.gameobject : GameObjectSpawn;
        import dmangos.world.spellcast : duration, radius;

        const slot = cast(size_t)(spell.effect[i] - SpellEffect.summonObjectSlot1);
        const entry = cast(uint) spell.miscValue[i];
        const t = entry in context.data.gameObjectTemplates;
        if (slot >= trapSlots.length || t is null)
            return;
        removeTrap(slot);
        auto at = player.position;
        if (targets.mask & TargetFlags.destLocation)
            at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
        else if (const r = radius(*spell, i, context.client))
        {
            at.x += r * cos(at.orientation);
            at.y += r * sin(at.orientation);
        }
        GameObjectSpawn spawn = {guid: context.nextTemporaryCounter(), entry: entry, map: map.id, x: at.x, y: at.y,
            z: at.z, orientation: at.orientation, respawnSeconds: -1};
        spawn.rotation = [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)];
        auto go = new GameObject(spawn, t);
        go.owner = player.guid;
        go.instanceId = map.instanceId;
        go.values.set!OBJECT_FIELD_CREATED_BY(player.guid);
        go.values.set!GAMEOBJECT_LEVEL(player.data.level);
        map.addObject(go);
        ByteWriter w;
        w.put(go.guid);
        map.sendToWatchers(this, Opcode.SMSG_GAMEOBJECT_SPAWN_ANIM_OBSOLETE, w.data, true);
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        trapSlots[slot] = go.guid;
        trapTimes[slot] = ms > 0 ? ms : int.max;
    }

    /// The trap of `slot` goes (if any).
    private void removeTrap(size_t slot)
    {
        if (trapSlots[slot] && map !is null)
            map.removeObject(trapSlots[slot]);
        trapSlots[slot] = 0;
    }

    /// The player's traps go (it left the map, or logs out).
    package void removeTraps()
    {
        foreach (slot; 0 .. trapSlots.length)
            removeTrap(slot);
    }

    /**
     * The player's traps, each tick: one whose time is up goes; one ready springs on the first enemy creature
     * or player within its radius (`GameObject.trapRadius`), alive and not evading: its spell is cast by the
     * trap's owner at it, from the trap's place (an area's centre, a ground effect's spot), then the trap waits
     * its cooldown (4 seconds if none) and goes after its charges (CMaNGOS's trap `GameObject::Update` and
     * `Use`).
     */
    package void updateTraps(int diff)
    {
        import dmangos.world.gameobject : GoLootState;

        foreach (slot, guid; trapSlots)
        {
            if (!guid)
                continue;
            auto go = cast(GameObject) map.findObject(guid);
            if (go is null || (trapTimes[slot] != int.max && (trapTimes[slot] -= diff) <= 0))
            {
                removeTrap(slot);
                continue;
            }
            const radius = go.trapRadius;
            const spellId = cast(uint) go.template_.data[3];
            if (radius <= 0 || spellId == 0 || context.unixTime < go.trapReadyAt || go.lootState != GoLootState.ready)
                continue;
            const victim = trapVictim(go.position, radius);
            if (!victim)
                continue;
            go.trapReadyAt = context.unixTime + (go.template_.data[5] > 0 ? go.template_.data[5] : 4);
            springTrap(go, spellId, victim);
            const charges = go.template_.data[4];
            if (charges > 0 && ++go.trapUses >= charges)
                removeTrap(slot);
        }
    }

    /// The first enemy of this player within `radius` of `at`: a creature, else a player; 0 if none.
    private ulong trapVictim(Position at, float radius)
    {
        foreach (creature; map.creaturesNear(at, radius))
            if (creature.alive && creature.ai !is null && !creature.ai.evading && spellEnemy(creature)
                    && (creature.position.x - at.x) ^^ 2 + (creature.position.y - at.y) ^^ 2 <= radius * radius)
                return creature.guid;
        foreach (who; map.near(at, radius))
            if (auto other = enemyPlayer(who.character.guid))
                if (other.fighter.alive)
                    return other.player.guid;
        return 0;
    }

    /// The trap's spell, cast by its owner at `victim` from the trap's place.
    private void springTrap(GameObject go, uint spellId, ulong victim)
    {
        const spell = context.data.spells.spell(spellId);
        if (spell is null)
            return;
        auto targets = SpellTargets(cast(ushort)(TargetFlags.unit | TargetFlags.sourceLocation | TargetFlags.destLocation),
            victim);
        targets.source = targets.dest = [go.position.x, go.position.y, go.position.z];
        castSpell(spell, targets, true, 0);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime;
    import dmangos.world.creature : Creature;
    import dmangos.world.map : Map;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellids;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient : ServerPacketRead, TestClient;

    /**
     * A world for the effects' tests: Anduin, a human warrior of level 60 with 3000 health, beside the innkeeper,
     * made an enemy of level 60 with 5000 health and 1000 mana. Its spells always hit and never crit; the radius
     * index 1 is 20 yards, the duration index 1 ten seconds.
     */
    final class Arena
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.database : MemoryWorldDatabase;

        MemoryWorldDatabase db;
        WorldContext context;
        MonoTime now;
        TestClient hero;
        Player me;
        Creature keeper;
        Map map;

        this()
        {
            import dmangos.dbc : buildDbc;
            import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
                spellRadiusFormat, spellRangeFormat;
            import dmangos.world.objects : HighGuid, makeGuid;
            import dmangos.world.testclient : loggedIn, newCreationContext, newDatabase;
            import dmangos.world.testdata : creatureInnkeeper, innkeeperSpawn;
            import dmangos.world.updatefields;

            db = newDatabase();
            context = newCreationContext(db);
            now = MonoTime.currTime;
            context.clock = () => now;
            static uint bits(float f) { return *cast(uint*) &f; }
            context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
                [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
            context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
                [[1u, bits(0), bits(40), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
            context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
                [[1u, bits(20), 0, 0]]), "SpellRadius.dbc");
            context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
                [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
            hero = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
            hero.read();
            me = cast(Player) hero.session.character;
            map = context.map(0);
            keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
            enum uint players = 1, monsters = 8;
            const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
            context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(
                factionTemplateFormat, [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0],
                [14u, 14, 0, monsters, monsters, players, 0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
            keeper.factionTemplate = context.client.factionTemplates.lookup(14);
            keeper.values.set!UNIT_FIELD_FACTIONTEMPLATE(14u);
            keeper.values.set!UNIT_FIELD_LEVEL(60u);
            keeper.values.set!UNIT_FIELD_MAXHEALTH(5000u);
            keeper.values.set!UNIT_FIELD_HEALTH(5000u);
            keeper.values.setByte!UNIT_FIELD_BYTES_0(3, 0); // mana
            keeper.values.set!UNIT_FIELD_MAXPOWER1(0, 1000u);
            keeper.values.set!UNIT_FIELD_POWER1(0, 1000u);
            me.data.level = 60;
            me.values.set!UNIT_FIELD_LEVEL(60u);
            me.values.set!UNIT_FIELD_MAXHEALTH(3000u);
            me.values.set!UNIT_FIELD_HEALTH(3000u);
        }

        /// A spell of one effect at `target` (an `ImplicitTarget`), that always hits and never crits.
        SpellInfo* spell(uint id, uint effect, uint target, int value)
        {
            import dmangos.world.spellhandlers : testSpell;

            context.data.spells.spells[id] = testSpell(id, effect, target, value);
            auto s = context.data.spells.spells.edit(id);
            s.casting.dmgClass = DamageClass.none;
            s.attributesEx2 |= 0x20000000; // SPELL_ATTR_EX2_CANT_CRIT
            return s;
        }

        /// The spell cast, triggered (no cost, no cooldown), at `target` (none: the player).
        void cast_(uint id, ulong target = 0)
        {
            hero.session.inWorld.castTriggeredAt(id, target);
        }

        /// `ms` pass for the player and its map.
        void tick(int ms)
        {
            import core.time : msecs;

            now += ms.msecs;
            hero.session.update(ms.msecs);
            map.update(ms.msecs);
        }

        /// The bodies of the packets with `opcode` among `packets`.
        static const(ubyte)[][] bodies(const(ServerPacketRead)[] packets, Opcode opcode)
        {
            const(ubyte)[][] found;
            foreach (p; packets)
                if (p.opcode == opcode)
                    found ~= p.body_;
            return found;
        }
    }
}

/// Threat: Distracting Shot's threat pulls the creature and is in its list; Cower's takes some back (never below
/// none); each tells the combat log.
unittest
{
    auto a = new Arena;
    enum uint distracting = 96001, cower = 96002;
    a.spell(distracting, SpellEffect.threat, ImplicitTarget.enemy, 300);
    a.spell(cower, SpellEffect.threat, ImplicitTarget.enemy, -200);
    a.cast_(distracting, a.keeper.guid);
    assert(a.keeper.ai.inCombat && a.keeper.ai.threatOf(a.me.guid) == 300, "pulled, with its threat");
    assert(Arena.bodies(a.hero.read(), Opcode.SMSG_SPELLLOGEXECUTE).length == 1);
    a.cast_(cower, a.keeper.guid);
    assert(a.keeper.ai.threatOf(a.me.guid) == 100);
    a.cast_(cower, a.keeper.guid);
    assert(a.keeper.ai.threatOf(a.me.guid) == 0, "never below none");
}

/// Taunts: a creature fighting another is made to attack the taunter, its threat raised to the top's, and its
/// taunt aura holds it there although the other gains more; a creature already on the taunter is not taunted
/// again.
unittest
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.testclient : loggedIn;

    auto a = new Arena;
    auto other = loggedIn(a.context, a.db, 8, "Varian", Position(-8950.5f, -131.5f, 83.53f, 1.97f));
    other.read();
    auto varian = other.session.inWorld;
    a.keeper.ai.attackedBy(varian.unit, a.map);
    a.keeper.ai.addThreat(varian.unit, 1000);
    a.keeper.ai.addThreat(a.hero.session.inWorld.unit, 10);
    enum uint growl = 96003;
    auto s = a.spell(growl, SpellEffect.attackMe, ImplicitTarget.enemy, 0);
    s.effect[1] = SpellEffect.applyAura;
    s.implicitTargetA[1] = ImplicitTarget.enemy;
    s.casting.applyAuraName[1] = AuraType.modTaunt;
    s.casting.durationIndex = 1;
    a.cast_(growl, a.keeper.guid);
    assert(a.keeper.ai.currentVictim == a.me.guid && a.keeper.ai.threatOf(a.me.guid) == 1000,
        "on the taunter, its threat the top's");
    a.keeper.ai.addThreat(varian.unit, 5000);
    a.tick(100);
    assert(a.keeper.ai.currentVictim == a.me.guid, "held by the taunt while it lasts");
    assert(Arena.bodies(a.hero.read(), Opcode.SMSG_SPELLLOGEXECUTE).length == 1);
    a.cast_(growl, a.keeper.guid);
    assert(Arena.bodies(a.hero.read(), Opcode.SMSG_SPELLLOGEXECUTE).length == 0, "not taunted again");
    a.tick(10_000);
    assert(a.keeper.ai.currentVictim == varian.player.guid, "the taunt over, the most hated again");
}

/// Charge: the player runs to the creature (`SMSG_MONSTER_MOVE` of itself), stands at its reach, and attacks it.
unittest
{
    import std.math : abs, sqrt;
    import dmangos.bytes : ByteReader;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint charge = 96004;
    a.spell(charge, SpellEffect.charge, ImplicitTarget.enemy, 0);
    auto start = a.keeper.position;
    start.x += 15;
    a.me.movement.position = start;
    a.cast_(charge, a.keeper.guid);
    const moves = Arena.bodies(a.hero.read(), Opcode.SMSG_MONSTER_MOVE);
    assert(moves.length == 1);
    auto r = ByteReader(moves[0]);
    assert(r.readPackedGuid == a.me.guid, "its own client runs it");
    const at = a.me.position, to = a.keeper.position;
    const apart = sqrt((at.x - to.x) ^^ 2 + (at.y - to.y) ^^ 2);
    assert(abs(apart - a.keeper.values.get!UNIT_FIELD_COMBATREACH) < 0.01f, "at its reach");
    assert(a.hero.session.inWorld.attacking == a.keeper.guid, "and attacking it");
}

/// Blink: twenty yards ahead (no map data here: level ground), by a near teleport.
unittest
{
    import std.math : abs, cos, sin;

    auto a = new Arena;
    enum uint blink = 96005;
    auto s = a.spell(blink, SpellEffect.leap, ImplicitTarget.caster, 0);
    s.casting.radiusIndex[0] = 1;
    const from = a.me.position;
    a.cast_(blink);
    assert(Arena.bodies(a.hero.read(), Opcode.MSG_MOVE_TELEPORT_ACK).length == 1);
    const to = a.me.position;
    assert(abs(to.x - (from.x + 20 * cos(from.orientation))) < 0.1f
        && abs(to.y - (from.y + 20 * sin(from.orientation))) < 0.1f);
}

/// Mana Burn burns mana and hurts by it times the multiplier; Dark Pact's drain gives the caster what it took
/// (energize and execute logs); Death Coil heals its caster by its damage; Lay on Hands heals the caster's whole
/// health.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.testclient : opcodesOf;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint burn = 96006, pact = 96007, coil = 96008, hands = 96009;
    auto s = a.spell(burn, SpellEffect.powerBurn, ImplicitTarget.enemy, 200);
    s.casting.multipleValue[0] = 0.5f;
    s.casting.school = 6; // arcane
    a.cast_(burn, a.keeper.guid);
    assert(a.keeper.values.get!UNIT_FIELD_POWER1(0) == 800, "200 mana burned");
    const burned = 5000 - a.keeper.values.get!UNIT_FIELD_HEALTH;
    assert(burned > 0 && burned <= 100, "half of it as damage (some resisted at most)");
    assert(opcodesOf(a.hero.read()).canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG));

    // The player a mage for the drain: mana its power too.
    a.me.values.setByte!UNIT_FIELD_BYTES_0(3, 0);
    a.me.values.set!UNIT_FIELD_MAXPOWER1(0, 3000u);
    a.me.values.set!UNIT_FIELD_POWER1(0, 100u);
    s = a.spell(pact, SpellEffect.powerDrain, ImplicitTarget.enemy, 150);
    s.casting.multipleValue[0] = 1;
    a.cast_(pact, a.keeper.guid);
    assert(a.keeper.values.get!UNIT_FIELD_POWER1(0) == 650 && a.me.values.get!UNIT_FIELD_POWER1(0) == 250);
    const drained = opcodesOf(a.hero.read());
    assert(drained.canFind(Opcode.SMSG_SPELLENERGIZELOG) && drained.canFind(Opcode.SMSG_SPELLLOGEXECUTE));

    a.me.values.set!UNIT_FIELD_HEALTH(1000u);
    s = a.spell(coil, SpellEffect.healthLeech, ImplicitTarget.enemy, 300);
    s.casting.multipleValue[0] = 1;
    s.casting.school = 5; // shadow
    const before = a.keeper.values.get!UNIT_FIELD_HEALTH;
    a.cast_(coil, a.keeper.guid);
    const dealt = before - a.keeper.values.get!UNIT_FIELD_HEALTH;
    assert(dealt > 0 && a.me.values.get!UNIT_FIELD_HEALTH == 1000 + dealt, "healed by what it dealt");
    assert(opcodesOf(a.hero.read()).canFind(Opcode.SMSG_SPELLHEALLOG));

    a.spell(hands, SpellEffect.healMaxHealth, ImplicitTarget.caster, 0);
    a.me.values.set!UNIT_FIELD_HEALTH(1u);
    a.cast_(hands);
    assert(a.me.values.get!UNIT_FIELD_HEALTH == 3000);
}

/// Sword Specialization's extra swing: owed, logged, and swung at the victim at the next melee update.
unittest
{
    import dmangos.world.packets : ClientGuid;

    auto a = new Arena;
    enum uint sword = 96010;
    a.spell(sword, SpellEffect.addExtraAttacks, ImplicitTarget.caster, 1);
    a.hero.write(Opcode.CMSG_ATTACKSWING, ClientGuid(a.keeper.guid));
    a.tick(10);
    a.hero.read();
    a.cast_(sword);
    assert(a.hero.session.inWorld.extraAttacks == 1);
    assert(Arena.bodies(a.hero.read(), Opcode.SMSG_SPELLLOGEXECUTE).length == 1);
    a.tick(10);
    assert(a.hero.session.inWorld.extraAttacks == 0);
    assert(Arena.bodies(a.hero.read(), Opcode.SMSG_ATTACKERSTATEUPDATE).length >= 1, "swung");
}

/// Escape Artist frees the player of its rooting auras (by mechanic), not of the others.
unittest
{
    import dmangos.world.auras : AuraType, makeAura;

    auto a = new Arena;
    enum uint net = 96011, buff = 96012, escape = 96013;
    enum uint mechanicRoot = 7;
    auto s = a.spell(net, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.modRoot;
    s.casting.mechanic = mechanicRoot;
    s = a.spell(buff, SpellEffect.applyAura, ImplicitTarget.caster, 5);
    s.casting.applyAuraName[0] = AuraType.modStat;
    s = a.spell(escape, SpellEffect.dispelMechanic, ImplicitTarget.caster, 10);
    s.miscValue[0] = mechanicRoot;
    auto session = a.hero.session.inWorld;
    session.addAura(makeAura((net in a.context.data.spells.spells), a.keeper.guid, 60, 10_000, false, [0, 0, 0]));
    session.addAura(makeAura((buff in a.context.data.spells.spells), a.me.guid, 60, 10_000, true, [5, 0, 0]));
    a.cast_(escape);
    assert(a.me.auras.find(net) is null && a.me.auras.find(buff) !is null);
}

/// Vanish (sanctuary): every creature fighting the player forgets it, and it is out of combat; Fade lowers its
/// threat while it lasts; Feign Death looks dead, and unless seen through leaves the fight.
unittest
{
    import dmangos.world.auras : AuraSet, AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint vanish = 96014, feign = 96015, fade = 96016;
    a.spell(vanish, SpellEffect.sanctuary, ImplicitTarget.caster, 0);
    auto session = a.hero.session.inWorld;
    a.hero.write(Opcode.CMSG_ATTACKSWING, ClientGuid(a.keeper.guid));
    a.tick(10);
    assert(a.keeper.ai.inCombat && (a.me.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat));
    a.cast_(vanish);
    assert((a.me.guid in a.keeper.ai.threatList) is null && !(a.me.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat));
    assert(session.attacking == 0, "it stopped attacking");

    // Fade: 100 threat less while it lasts, back after.
    auto s = a.spell(fade, SpellEffect.applyAura, ImplicitTarget.caster, -100);
    s.casting.applyAuraName[0] = AuraType.modTotalThreat;
    s.casting.durationIndex = 1;
    a.keeper.ai.attackedBy(session.unit, a.map);
    a.keeper.ai.addThreat(session.unit, 300);
    a.cast_(fade);
    assert(a.keeper.ai.threatOf(a.me.guid) == 200);
    a.tick(10_000);
    assert(a.keeper.ai.threatOf(a.me.guid) == 300, "given back");

    // Feign Death against a creature of its own level: seen through 4% of the time.
    s = a.spell(feign, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.feignDeath;
    s.casting.durationIndex = 1;
    a.cast_(feign);
    assert(a.me.values.get!UNIT_DYNAMIC_FLAGS & AuraSet.dynDead, "it looks dead");
    if (session.feigningDeath)
        assert((a.me.guid in a.keeper.ai.threatList) is null && session.unit.untouchable);
    a.tick(10_000);
    assert(!(a.me.values.get!UNIT_DYNAMIC_FLAGS & AuraSet.dynDead) && !session.feigningDeath, "up again");
}

/// Distract: the creature stands facing the spot for the effect's seconds, then moves as before.
unittest
{
    import std.math : abs, atan2;
    import dmangos.world.motion : DistractMovement;

    auto a = new Arena;
    enum uint distract = 96017;
    a.spell(distract, SpellEffect.distract, ImplicitTarget.enemiesAroundDest, 5);
    a.context.data.spells.spells.edit(distract).casting.radiusIndex[0] = 1;
    auto spot = a.keeper.position;
    spot.y += 5;
    auto targets = SpellTargets(TargetFlags.destLocation, 0);
    targets.dest = [spot.x, spot.y, spot.z];
    a.hero.session.inWorld.castSpell((distract in a.context.data.spells.spells), targets, true, 0);
    assert(cast(DistractMovement) a.keeper.generator !is null && !a.keeper.ai.inCombat);
    assert(abs(a.keeper.position.orientation - atan2(5.0f, 0.0f)) < 0.01f, "facing the spot");
    a.tick(5100);
    a.tick(100);
    assert(cast(DistractMovement) a.keeper.generator is null, "over");
}

/// A hunter's trap: put down, it springs on the enemy within its radius (its spell on it, from the trap's owner),
/// and with one charge it is gone; a second of the same slot replaces the first.
unittest
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.gameobject : GameObject, GameObjectTemplate, GameObjectType;

    auto a = new Arena;
    enum uint trapSpell = 96018, freeze = 96019, trapEntry = 96020;
    GameObjectTemplate t = {entry: trapEntry, type: GameObjectType.trap, displayId: 1, name: "Freezing Trap"};
    t.data[0] = 12;   // the hunters' lock: the diameter is the radius
    t.data[2] = 3;
    t.data[3] = freeze;
    t.data[4] = 1;    // one charge
    a.context.data.gameObjectTemplates[trapEntry] = t;
    auto s = a.spell(freeze, SpellEffect.applyAura, ImplicitTarget.enemy, 0);
    s.casting.applyAuraName[0] = AuraType.modStun;
    s.casting.durationIndex = 1;
    s = a.spell(trapSpell, SpellEffect.summonObjectSlot1, ImplicitTarget.caster, 0);
    s.miscValue[0] = trapEntry;
    s.casting.durationIndex = 1;
    auto at = a.keeper.position;
    at.x += 10;
    a.me.movement.position = at;
    a.cast_(trapSpell);
    auto session = a.hero.session.inWorld;
    const first = session.trapSlots[0];
    assert(first && cast(GameObject) a.map.findObject(first) !is null);
    a.cast_(trapSpell);
    assert(session.trapSlots[0] != first && a.map.findObject(first) is null, "the slot's old trap gone");
    a.tick(100);
    assert(a.keeper.auras.find(freeze) is null, "nobody near it yet");
    a.keeper.movement.position = at;
    a.tick(100);
    assert(a.keeper.auras.find(freeze) !is null, "sprung on the creature");
    assert(session.trapSlots[0] == 0, "its one charge used");
}

/// Drains over time: Drain Life's ticks heal the caster by their damage; Drain Mana's give it the mana.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.auras : AuraType;
    import dmangos.world.testclient : opcodesOf;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint life = 96021, mana = 96022;
    auto s = a.spell(life, SpellEffect.applyAura, ImplicitTarget.enemy, 50);
    s.casting.applyAuraName[0] = AuraType.periodicLeech;
    s.casting.amplitude[0] = 1000;
    s.casting.durationIndex = 1;
    s.casting.school = 5;
    a.me.values.set!UNIT_FIELD_HEALTH(1000u);
    a.cast_(life, a.keeper.guid);
    a.hero.read();
    a.tick(1000);
    const took = 5000 - a.keeper.values.get!UNIT_FIELD_HEALTH;
    const read = a.hero.read();
    assert(opcodesOf(read).canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG));
    const heals = Arena.bodies(read, Opcode.SMSG_SPELLHEALLOG);
    assert(heals.length == 1);
    {
        import dmangos.bytes : ByteReader;

        auto r = ByteReader(heals[0]);
        assert(r.readPackedGuid == a.me.guid && r.readPackedGuid == a.me.guid && r.read!uint == life);
        assert(took > 0 && r.read!uint == took, "healed by the tick"); // (the innkeeper's swings hurt meanwhile)
    }

    a.me.values.setByte!UNIT_FIELD_BYTES_0(3, 0);
    a.me.values.set!UNIT_FIELD_MAXPOWER1(0, 3000u);
    a.me.values.set!UNIT_FIELD_POWER1(0, 0u);
    s = a.spell(mana, SpellEffect.applyAura, ImplicitTarget.enemy, 40);
    s.casting.applyAuraName[0] = AuraType.periodicManaLeech;
    s.casting.amplitude[0] = 1000;
    s.casting.durationIndex = 1;
    s.casting.multipleValue[0] = 1;
    a.cast_(mana, a.keeper.guid);
    a.hero.read();
    a.tick(1000);
    assert(a.keeper.values.get!UNIT_FIELD_POWER1(0) == 960 && a.me.values.get!UNIT_FIELD_POWER1(0) >= 40);
    assert(opcodesOf(a.hero.read()).canFind(Opcode.SMSG_PERIODICAURALOG));
}

/// What auras show: tracking bits, Hunter's Mark's flag and its attack power for shots, Aspect of the Beast's
/// untrackable flag, Bestial Wrath's size; all gone with them.
unittest
{
    import std.math : isClose;
    import dmangos.world.auras : AuraSet, AuraType;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint beasts = 96023, herbs = 96024, mark = 96025, aspect = 96026, wrath = 96027;
    auto s = a.spell(beasts, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.trackCreatures;
    s.miscValue[0] = 1;
    s.casting.durationIndex = 1;
    s = a.spell(herbs, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.trackResources;
    s.miscValue[0] = 2;
    s.casting.durationIndex = 1;
    a.cast_(beasts);
    a.cast_(herbs);
    assert(a.me.values.get!PLAYER_TRACK_CREATURES == 1 && a.me.values.get!PLAYER_TRACK_RESOURCES == 2);

    s = a.spell(mark, SpellEffect.applyAura, ImplicitTarget.enemy, 0);
    s.casting.applyAuraName[0] = AuraType.modStalked;
    s.effect[1] = SpellEffect.applyAura;
    s.implicitTargetA[1] = ImplicitTarget.enemy;
    s.casting.applyAuraName[1] = AuraType.rangedAttackPowerAttackerBonus;
    s.basePoints[1] = 139;
    s.baseDice[1] = 1;
    s.casting.durationIndex = 1;
    a.cast_(mark, a.keeper.guid);
    assert(a.keeper.values.get!UNIT_DYNAMIC_FLAGS & AuraSet.dynTrackUnit, "tracked on the minimap");
    assert(a.hero.session.inWorld.rangedAttackerBonus(a.map.unitOf(a.keeper)) == 140);

    s = a.spell(aspect, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.untrackable;
    s.casting.durationIndex = 1;
    s = a.spell(wrath, SpellEffect.applyAura, ImplicitTarget.caster, 10);
    s.casting.applyAuraName[0] = AuraType.modScale;
    s.casting.durationIndex = 1;
    const scale = a.me.values.get!OBJECT_FIELD_SCALE_X;
    a.cast_(aspect);
    a.cast_(wrath);
    assert(a.me.values.getByte!UNIT_FIELD_BYTES_1(3) & AuraSet.visUntrackable);
    assert(isClose(a.me.values.get!OBJECT_FIELD_SCALE_X, scale * 1.1f));
    a.tick(10_000);
    assert(a.me.values.get!PLAYER_TRACK_CREATURES == 0 && a.me.values.get!PLAYER_TRACK_RESOURCES == 0);
    assert(!(a.me.values.getByte!UNIT_FIELD_BYTES_1(3) & AuraSet.visUntrackable));
    assert(isClose(a.me.values.get!OBJECT_FIELD_SCALE_X, scale), "its size back");
    assert(!(a.keeper.values.get!UNIT_DYNAMIC_FLAGS & AuraSet.dynTrackUnit));
}

/// Regeneration's auras: a share in combat, a percentage more out of it, health every second whatever, a power's
/// rate; Bloodrage counts as combat.
unittest
{
    import std.math : isClose;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.defines : Power, Stat;
    import dmangos.world.updatefields;

    auto a = new Arena;
    auto me = a.me;
    me.values.set!UNIT_FIELD_STAT0(Stat.spirit, 100u);
    const base = me.healthRegenNow(1, false);
    assert(base > 0 && me.healthRegenNow(1, true) == 0, "none in combat");
    SpellInfo duringCombat, regen, armor, innervate, bloodrage;
    duringCombat.id = 96030;
    duringCombat.effect[0] = SpellEffect.applyAura;
    duringCombat.casting.applyAuraName[0] = AuraType.modRegenDuringCombat;
    regen = duringCombat;
    regen.id = 96031;
    regen.casting.applyAuraName[0] = AuraType.modHealthRegenPercent;
    armor = duringCombat;
    armor.id = 96032;
    armor.casting.applyAuraName[0] = AuraType.modHealthRegenInCombat;
    innervate = duringCombat;
    innervate.id = 96033;
    innervate.casting.applyAuraName[0] = AuraType.modPowerRegenPercent;
    innervate.miscValue[0] = Power.energy;
    bloodrage = duringCombat;
    bloodrage.id = 29131;
    bloodrage.casting.applyAuraName[0] = AuraType.interruptRegen;
    auto session = a.hero.session.inWorld;
    session.addAura(makeAura(&duringCombat, me.guid, 60, -1, true, [30, 0, 0]));
    assert(isClose(me.healthRegenNow(1, true), base * 0.3f), "30% kept in combat");
    session.addAura(makeAura(&regen, me.guid, 60, -1, true, [100, 0, 0]));
    assert(isClose(me.healthRegenNow(1, false), base * 2), "twice as fast out of combat");
    session.addAura(makeAura(&armor, me.guid, 60, -1, true, [3, 0, 0]));
    assert(isClose(me.healthRegenNow(1, true), base * 0.3f + 3), "and 3 a second always");
    session.addAura(makeAura(&innervate, me.guid, 60, -1, true, [100, 0, 0]));
    assert(me.powerRegenFactor(Power.energy) == 2 && me.powerRegenFactor(Power.mana) == 1);
    assert(!me.regenInterrupted);
    session.addAura(makeAura(&bloodrage, me.guid, 60, -1, true, [0, 0, 0]));
    assert(me.regenInterrupted, "Bloodrage: no regeneration as out of combat");
}

/// Stuck: with no Hearthstone in the bags, a nudge ten yards ahead.
unittest
{
    import std.math : abs, cos;

    auto a = new Arena;
    enum uint stuck = 96034;
    a.spell(stuck, SpellEffect.stuck, ImplicitTarget.caster, 0);
    while (a.me.inventory.count(6948))
        a.me.inventory.destroyCount(6948, 1);
    const from = a.me.position;
    a.cast_(stuck);
    assert(Arena.bodies(a.hero.read(), Opcode.MSG_MOVE_TELEPORT_ACK).length == 1);
    assert(abs(a.me.position.x - (from.x + 10 * cos(from.orientation))) < 0.1f);
}

/// Track Hidden's flag while it lasts; Divine Intervention's untargetable flag, and out of the fight.
unittest
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.updatefields;

    auto a = new Arena;
    enum uint hidden = 96035, intervention = 96036;
    auto s = a.spell(hidden, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.trackStealthed;
    s.casting.durationIndex = 1;
    s = a.spell(intervention, SpellEffect.applyAura, ImplicitTarget.caster, 0);
    s.casting.applyAuraName[0] = AuraType.modUnattackable;
    s.casting.durationIndex = 1;
    a.keeper.ai.attackedBy(a.hero.session.inWorld.unit, a.map);
    a.cast_(hidden);
    a.cast_(intervention);
    assert(a.me.values.getByte!PLAYER_FIELD_BYTES(0) & 0x02);
    assert((a.me.values.get!UNIT_FIELD_FLAGS & UnitFlags.untargetable) && (a.me.guid in a.keeper.ai.threatList) is null);
    a.tick(10_000);
    assert(!(a.me.values.getByte!PLAYER_FIELD_BYTES(0) & 0x02));
    assert(!(a.me.values.get!UNIT_FIELD_FLAGS & UnitFlags.untargetable));
}
