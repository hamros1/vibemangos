/**
 * A creature's spells and script: the creature as a caster, and the script's side of its AI, mixed
 * into `dmangos.world.creatureai.CreatureAI`.
 *
 * A spell is cast at itself or at a player: refused while it casts another (unless the flags say
 * otherwise), out of range or mana, or on one that has its aura already when asked. A cast with a
 * cast time stops it where it is and keeps it from swinging until the spell goes off; a spell on
 * the next swing waits for the swing. Then, at its targets (the one chosen, itself, or the enemies
 * in its area or cone): school damage (less armor for physical; a magic spell may miss by the
 * level difference), weapon damage (a melee roll with the effect's bonus), an aura (a debuff on a
 * player, a buff on itself), a heal of itself, a triggered spell.
 *
 * The script (`dmangos.world.eventai`) calls back here for what its actions do: texts (said,
 * yelled, emoted, whispered), emotes, fleeing, calls for help, combat movement, ranged mode.
 */
module dmangos.world.creaturecasting;

/// See the module documentation.
mixin template CreatureCasting()
{
    import std.math : PI, sqrt;
    import std.random : uniform, uniform01;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.auras : makeAura;
    import dmangos.world.combat : AttackType, armorReducedDamage, calculateMeleeDamage, hasInArc, MeleeDamage,
        MeleeHitOutcome;
    import dmangos.world.eventai;
    import dmangos.world.motion : launch, stopMoving;
    import dmangos.world.opcodes : ChatType, Language, Opcode;
    import dmangos.world.queries : monsterChatMessage;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellcast : castTime, duration, effectValue, healLog, isNextMeleeSwingSpell, nonMeleeDamageLog,
        powerCost, radius, range, spellGoPacket, spellMissChance, spellStartPacket, SpellMissInfo, SpellTargets,
        TargetFlags, TargetResult;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;
    import dmangos.world.npcdata : BroadcastText;
    import dmangos.script.api : EntityRef, KilledUnit, SpellHit;

    private
    {
        CombatWorld world_;            // the map, while the AI acts
        EventAI script;                // its `creature_ai_scripts`; null if it has none
        CreatureLore lore;
        const(SpellInfo)* casting_;    // the spell being cast
        ulong castTarget;
        int castTimer;                 // until it goes off
        const(SpellInfo)* nextSwing;   // a spell on its next swing
        bool combatMovement_ = true;   // it chases its victim
        bool rangedModeSet;            // its script keeps it at a distance to cast
        bool rangedMode_;              // and it does now (not out of mana)
        float chaseDistance_ = 0;      // how far from its victim it keeps
        int fleeTimer;                 // running in fear, for so long yet
        int despawnTimer;              // gone in so long (0: not)
        bool meleeEnabled = true;      // it swings at its victim
    }

    bool deathPrevention;              /// damage leaves it at 1 health

    /// What its casts and texts need of the world's data (every creature made in the world has it).
    void setLore(CreatureLore lore)
    {
        this.lore = lore;
    }

    /// The creature runs `events` (from `data`) as its script.
    void setScript(const(EventAiEvent)[] events, const EventAiData data)
    {
        this.script = new EventAI(events, data);
    }

    /// A player's spell hit it (its script hears of it).
    void spellHitBy(ulong caster, uint spell, uint schoolMask, CombatWorld world)
    {
        world_ = world;
        raiseScript(SpellHit(EntityRef(caster), spell));
        if (script is null)
            return;
        script.spellHit(this, caster, spell, schoolMask);
    }

    /// A player's text emote at it.
    void receivedEmote(ulong player, uint textEmote, CombatWorld world)
    {
        if (script is null)
            return;
        world_ = world;
        script.receivedEmote(this, player, textEmote);
    }

    /// `.castself` on a creature: it casts `spell` at itself.
    void castFromCommand(const(SpellInfo)* spell, CombatWorld world)
    {
        world_ = world;
        castSpell(spell, me.guid, 0);
        world.wake(me.guid);
    }

    /// Whether it is casting a spell now.
    @property bool castingNow() const
    {
        return casting_ !is null;
    }

    /// Whether its script wants ticks out of combat (timers, or its spawn events still to run).
    private @property bool scriptWantsTicks()
    {
        return script !is null && script.wantsTicks;
    }

    // -----------------------------------------------------------------------
    // Casting
    // -----------------------------------------------------------------------

    /**
     * Casts `spell` at `target` (itself, or a player) as `flags`
     * (`castTriggered`, ...) allow; false if it could not.
     */
    bool castSpell(const(SpellInfo)* spell, ulong target, uint flags)
    {
        if (spell is null || lore is null || !me.alive || world_ is null)
            return false;
        const triggered = (flags & castTriggered) != 0;
        if (evadingHome && !triggered)
            return false;
        if (casting_ !is null && !(flags & (castTriggered | castInterruptPrevious)))
            return false;
        // `CAST_FORCE_TARGET_SELF`: the target casts it on itself; only it itself can be made to.
        if ((flags & castForceTargetSelf) && target != me.guid)
            return false;
        if (target == 0)
            target = victim ? victim : me.guid;
        if (target != me.guid)
        {
            if (auto other = world_.unit(target))
            {
                if (!other.fighter.alive || ((flags & castAuraNotPresent) && other.hasAuraOf(spell.id)))
                    return false;
            }
            else if (auto friend = world_.creatureAt(target))
            {
                // A friend (to heal, to buff).
                if (!friend.alive || ((flags & castAuraNotPresent) && friend.auras.find(spell.id) !is null))
                    return false;
            }
            else
                return false;
        }
        else if ((flags & castAuraNotPresent) && me.auras.find(spell.id) !is null)
            return false;
        if (!(flags & (castForceCast | castForceTargetSelf)) && !triggered)
        {
            if (!inRangeFor(spell, target))
                return false;
            if (spell.casting.powerType == 0 && manaCost(spell) > me.values.get!UNIT_FIELD_POWER1)
            {
                // Out of mana, it comes in to fight (unless told not to).
                if (rangedMode_ && !(flags & castNoMeleeIfOom))
                    rangedMode_ = false;
                return false;
            }
        }
        if (casting_ !is null)
            interruptCast();
        if (!triggered && isNextMeleeSwingSpell(*spell))
        {
            nextSwing = spell;
            return true;
        }
        const time = triggered ? 0 : castTime(*spell, lore.clientData, me.values.get!UNIT_FIELD_LEVEL);
        if (time <= 0)
        {
            go(spell, target, !triggered);
            return true;
        }
        casting_ = spell;
        castTarget = target;
        castTimer = time;
        if (!me.spline.finalized)
            stopMoving(me, world_);
        auto targets = targetsOf(target);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_START, spellStartPacket(me.guid, spell.id, time, targets));
        return true;
    }

    /// The cast under way: it goes off when its time is up, or fails if its target is gone.
    private void updateCasting(int diff)
    {
        if (casting_ is null)
            return;
        if (castTarget != me.guid)
        {
            auto other = world_.unit(castTarget);
            auto friend = !other ? world_.creatureAt(castTarget) : null;
            if ((!other || !other.fighter.alive) && (friend is null || !friend.alive))
                return interruptCast();
        }
        castTimer -= diff;
        if (castTimer > 0)
            return;
        auto spell = casting_;
        casting_ = null;
        go(spell, castTarget, true);
    }

    /// The cast stops (`SMSG_SPELL_FAILURE` around).
    void interruptCast()
    {
        import dmangos.world.spellcast : spellFailurePacket, SpellCastResult;

        if (casting_ is null)
            return;
        if (world_ !is null)
            world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(me.guid, casting_.id, SpellCastResult.interrupted));
        casting_ = null;
    }

    /// The spell's mana cost for it.
    private int manaCost(const(SpellInfo)* spell)
    {
        return powerCost(*spell, me.values.get!UNIT_FIELD_LEVEL, me.values.get!UNIT_FIELD_MAXPOWER1,
            me.values.get!UNIT_FIELD_MAXHEALTH, me.values.get!UNIT_FIELD_MAXPOWER1);
    }

    /// Within the spell's range of its target (and out of its minimum).
    private bool inRangeFor(const(SpellInfo)* spell, ulong target)
    {
        if (target == me.guid)
            return true;
        const r = range(*spell, lore.clientData);
        const d = distanceTo(target);
        // Its combat reach and the target's count towards the maximum.
        return d <= r[1] + me.fighter.combatReach + 1.5f && (r[0] == 0 || d >= r[0]);
    }

    /// Yards to a target; infinity if it is not here.
    private float distanceTo(ulong target)
    {
        if (target == me.guid)
            return 0;
        Position p;
        if (auto other = world_.unit(target))
            p = other.fighter.position;
        else if (auto friend = world_.creatureAt(target))
            p = friend.position;
        else
            return float.infinity;
        const dx = p.x - me.position.x, dy = p.y - me.position.y, dz = p.z - me.position.z;
        return sqrt(dx * dx + dy * dy + dz * dz);
    }

    private SpellTargets targetsOf(ulong target)
    {
        SpellTargets t;
        if (target != me.guid)
        {
            t.mask = TargetFlags.unit;
            t.unit = target;
        }
        return t;
    }

    /// The implicit targets the creature resolves: the caster, enemies in an area or cone, or the target.
    private ulong[] targetsFor(const(SpellInfo)* spell, size_t i, ulong target)
    {
        enum uint self = 1, enemyInArea = 15, enemyInAreaInstant = 16, casterCoordinates = 22, frontalCone = 24;
        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        const area = a == enemyInArea || a == enemyInAreaInstant || b == enemyInArea || b == enemyInAreaInstant;
        if (area || a == frontalCone)
        {
            auto center = me.position;
            if (area && a != casterCoordinates && a != self && target != me.guid)
                if (auto other = world_.unit(target))
                    center = other.fighter.position;
            const r = radius(*spell, i, lore.clientData);
            ulong[] found;
            foreach (other; world_.playersNear(center, r))
            {
                const f = other.fighter;
                if (!f.alive || !canAttack(relating, other.relating, me.client))
                    continue;
                if (a == frontalCone && !hasInArc(me.position, f.position, PI / 2))
                    continue;
                found ~= other.combatGuid;
            }
            return found;
        }
        if (a == self || target == 0)
            return [me.guid];
        return [target];
    }

    /**
     * The spell goes off (`SMSG_SPELL_GO` with who it hit and missed) and its effects
     * happen to each target; its mana is spent.
     */
    private void go(const(SpellInfo)* spell, ulong target, bool takeMana)
    {
        enum uint schoolDamage = 2, applyAura = 6, heal = 10, weaponDamageNoSchool = 17, weaponPercent = 31,
            weaponDamage = 58, triggerSpell = 64, normalizedWeapon = 121;
        if (takeMana && spell.casting.powerType == 0)
        {
            const cost = manaCost(spell), mana = me.values.get!UNIT_FIELD_POWER1;
            me.values.set!UNIT_FIELD_POWER1(cost >= mana ? 0 : mana - cost);
        }
        const level = me.values.get!UNIT_FIELD_LEVEL;
        // Who each effect reaches; a hostile target rolls once to be hit.
        ulong[][3] reached;
        bool[ulong] all;
        foreach (i; 0 .. 3)
            if (spell.effect[i])
            {
                reached[i] = targetsFor(spell, i, target);
                foreach (guid; reached[i])
                    all[guid] = true;
            }
        TargetResult[] results;
        MeleeDamage[ulong] weaponRolls;
        bool weapon;
        foreach (i; 0 .. 3)
            weapon |= spell.effect[i] == weaponDamageNoSchool || spell.effect[i] == weaponPercent
                || spell.effect[i] == weaponDamage || spell.effect[i] == normalizedWeapon;
        foreach (guid, _; all)
        {
            auto miss = SpellMissInfo.none;
            if (guid != me.guid)
                if (auto other = world_.unit(guid))
                {
                    // Only what it may attack rolls (a heal on a friend never misses).
                    if (!canAttack(relating, other.relating, me.client))
                    {
                        results ~= TargetResult(guid, miss);
                        continue;
                    }
                    const f = other.fighter;
                    if (weapon)
                    {
                        auto d = calculateMeleeDamage(me.fighter, f, AttackType.mainHand, world_.random);
                        weaponRolls[guid] = d;
                        switch (d.outcome)
                        {
                        case MeleeHitOutcome.miss: miss = SpellMissInfo.miss; break;
                        case MeleeHitOutcome.dodge: miss = SpellMissInfo.dodge; break;
                        case MeleeHitOutcome.parry: miss = SpellMissInfo.parry; break;
                        case MeleeHitOutcome.evade: miss = SpellMissInfo.evade; break;
                        default: break;
                        }
                    }
                    else if (spell.casting.dmgClass == 1)
                    {
                        // Missed, or resisted whole by the player's resistance to its school.
                        import dmangos.world.combat : fullResistChance;
                        import dmangos.world.spellcast : isBinarySpell;

                        float chance = spellMissChance(level, f.level, true);
                        if (spell.casting.school > 1)
                            chance += fullResistChance(world_.unit(guid).resistance(spell.casting.school), level, f.level,
                                isBinarySpell(*spell), false);
                        if (uniform01(world_.random) * 100 < chance)
                            miss = SpellMissInfo.resist;
                    }
                }
            results ~= TargetResult(guid, miss);
        }
        auto targets = targetsOf(target);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_GO, spellGoPacket(me.guid, spell.id, results, targets));
        bool[ulong] missed;
        foreach (r; results)
            if (r.miss != SpellMissInfo.none)
                missed[r.guid] = true;
        bool auraDone;
        foreach (i; 0 .. 3)
        {
            const effect = spell.effect[i];
            if (effect == 0)
                continue;
            const value = effectValue(*spell, i, level, uniform01(world_.random));
            foreach (guid; reached[i])
            {
                if (guid in missed)
                    continue;
                if (!me.alive)
                    return;
                switch (effect)
                {
                case schoolDamage:
                    if (guid != me.guid)
                        spellDamageTo(spell, guid, value > 0 ? value : 0, spell.casting.school);
                    break;
                case weaponDamageNoSchool, weaponPercent, weaponDamage, normalizedWeapon:
                    if (auto d = guid in weaponRolls)
                    {
                        uint damage = d.damage;
                        if (effect == weaponPercent)
                            damage = cast(uint)(damage * (value > 0 ? value : 0) / 100.0f);
                        else if (value > 0)
                            damage += cast(uint) armorReducedDamage(level,
                                world_.unit(guid) ? world_.unit(guid).fighter.armor : 0, value);
                        spellDamageTo(spell, guid, damage, -1);
                    }
                    break;
                case applyAura:
                    if (!auraDone)
                        auraOn(spell, guid);
                    break;
                case heal:
                    healCreature(spell, guid == me.guid ? me : world_.creatureAt(guid), value);
                    break;
                case triggerSpell:
                    if (const triggered = lore.spellInfo(spell.triggerSpell[i]))
                        castSpell(triggered, guid, castTriggered);
                    break;
                case 3, 77: // SPELL_EFFECT_DUMMY, SPELL_EFFECT_SCRIPT_EFFECT: the spell's script
                    spellEffectScript(spell, i, guid, value);
                    break;
                case 68: // SPELL_EFFECT_INTERRUPT_CAST
                    if (guid != me.guid)
                        if (auto other = world_.unit(guid))
                            other.castInterruptedBy(me.guid);
                    break;
                default:
                    break;
                }
            }
            if (effect == applyAura)
                auraDone = true;
        }
        world_.flushCreature(me);
    }

    /// A school's damage to a player, armor taking some of physical; -1: already through armor.
    private void spellDamageTo(const(SpellInfo)* spell, ulong guid, uint damage, int school)
    {
        auto other = world_.unit(guid);
        if (!other)
            return;
        uint resisted;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(me.values.get!UNIT_FIELD_LEVEL, other.fighter.armor, damage);
        else if (school > 1)
        {
            // Partly resisted by its resistance (a binary spell was resisted whole or not at all).
            import std.random : uniform;
            import dmangos.world.combat : effectiveResistPercent, rollPartialResist;
            import dmangos.world.spellcast : isBinarySpell;

            if (!isBinarySpell(*spell))
            {
                const percent = effectiveResistPercent(other.resistance(school), me.values.get!UNIT_FIELD_LEVEL,
                    other.fighter.level, false);
                const share = rollPartialResist(percent, uniform!"[]"(1u, 10000u, world_.random));
                if (share > 0)
                {
                    resisted = cast(uint)(damage * share);
                    damage -= resisted;
                }
                else if (share < 0)
                    damage += cast(uint)(damage * -share);
            }
        }
        const absorbed = other.absorb(school < 0 ? 0 : school, damage);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(guid, me.guid,
            spell.id, damage, school < 0 ? 0 : school, absorbed, resisted, false, 0, false));
        if (damage)
            triggerCombatTimer();
        other.spellHitBy(me.guid, damage);
        if (!other.fighter.alive && script !is null)
            script.killed(this, guid);
        if (!other.fighter.alive)
            raiseScript(KilledUnit(EntityRef(guid)));
    }

    /// `SPELL_EFFECT_APPLY_AURA`: a debuff on a player, or a buff on itself.
    private void auraOn(const(SpellInfo)* spell, ulong guid)
    {
        enum uint applyAura = 6;
        const level = me.values.get!UNIT_FIELD_LEVEL;
        int[3] values;
        foreach (j; 0 .. 3)
            if (spell.effect[j] == applyAura)
                values[j] = effectValue(*spell, j, level, uniform01(world_.random));
        const ms = duration(*spell, lore.clientData, level);
        if (auto creature = guid == me.guid ? me : world_.creatureAt(guid))
        {
            bool isNew;
            creature.auras.apply(makeAura(spell, me.guid, level, ms, true, values), creature.values, isNew);
            if (creature !is me)
                world_.flushCreature(creature);
            world_.wake(creature.guid);
            return;
        }
        if (auto other = world_.unit(guid))
            other.auraFrom(me.guid, spell, level, ms, values);
    }

    /// `SPELL_EFFECT_HEAL` on itself or a friend.
    private void healCreature(const(SpellInfo)* spell, Creature who, int value)
    {
        if (value <= 0 || who is null || !who.alive)
            return;
        const health = who.values.get!UNIT_FIELD_HEALTH, maximum = who.values.get!UNIT_FIELD_MAXHEALTH;
        const healed = health + value > maximum ? maximum - health : value;
        who.values.set!UNIT_FIELD_HEALTH(health + healed);
        world_.sendToObservers(who.guid, Opcode.SMSG_SPELLHEALLOG,
            healLog(who.guid, me.guid, spell.id, healed, false));
        if (who !is me)
            world_.flushCreature(who);
    }

    /// The spell on its next swing, instead of the swing (`true`): its weapon damage.
    private bool swingSpell(UnitRef target)
    {
        if (nextSwing is null)
            return false;
        auto spell = nextSwing;
        nextSwing = null;
        go(spell, target.combatGuid, true);
        return true;
    }

    // -----------------------------------------------------------------------
    // Fleeing
    // -----------------------------------------------------------------------

    /// Running in fear from its victim: away, and again when it gets there; it does not fight meanwhile.
    private void updateFleeing(int diff)
    {
        fleeTimer -= diff;
        if (fleeTimer <= 0)
        {
            fleeTimer = 0;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.fleeing);
            world_.flushCreature(me);
            if (!me.spline.finalized)
                stopMoving(me, world_);
            return;
        }
        if (!me.spline.finalized)
            return;
        auto from = me.position;
        if (auto enemy = world_.unit(victim))
            from = enemy.fighter.position;
        // Away from the enemy, a little to one side or the other.
        const angle = angleTo(from, me.position) + uniform(-0.6f, 0.6f, world_.random);
        import std.math : cos, sin;

        const x = me.position.x + 12 * cos(angle), y = me.position.y + 12 * sin(angle);
        auto z = world_.groundHeight(x, y, me.position.z + 2, false);
        if (!(z > -100_000))
            z = me.position.z;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world_, points, false, float.nan, true);
    }

    // -----------------------------------------------------------------------
    // `Scripted`: what the script's actions do
    // -----------------------------------------------------------------------

    /// See `Scripted`.
    uint healthPercent()
    {
        const maximum = me.values.get!UNIT_FIELD_MAXHEALTH;
        return maximum ? cast(uint)(ulong(me.values.get!UNIT_FIELD_HEALTH) * 100 / maximum) : 0;
    }

    /// ditto
    uint manaPercent()
    {
        const maximum = me.values.get!UNIT_FIELD_MAXPOWER1;
        return maximum ? cast(uint)(ulong(me.values.get!UNIT_FIELD_POWER1) * 100 / maximum) : 0;
    }

    /// ditto
    @property bool fighting()
    {
        return inCombat_;
    }

    /// ditto
    bool hasOwnAura(uint spell)
    {
        return me.auras.find(spell) !is null;
    }

    /// ditto
    bool victimCasting()
    {
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return other && other.castingSpell;
    }

    /// ditto: the one most hurt among itself and those near it in combat that are not its enemies.
    ulong lowestHpFriendly(float radius, uint deficit, bool percent)
    {
        ulong best;
        uint mostMissing;
        foreach (other; world_.creaturesNear(me.position, radius))
        {
            if (!other.alive || other.ai is null || !other.ai.inCombat)
                continue;
            if (other !is me && isEnemy(relating, other.ai.relating, me.client)) // not hostile to it
                continue;
            const maximum = other.values.get!UNIT_FIELD_MAXHEALTH, health = other.values.get!UNIT_FIELD_HEALTH;
            const missing = maximum - health;
            const measure = percent ? (maximum ? cast(uint)(ulong(missing) * 100 / maximum) : 0) : missing;
            if (measure > deficit && measure > mostMissing)
            {
                mostMissing = measure;
                best = other.guid;
            }
        }
        return best;
    }

    /// ditto
    void scriptSound(uint sound)
    {
        ByteWriter w;
        w.put(sound);
        world_.sendToObservers(me.guid, Opcode.SMSG_PLAY_SOUND, w.data);
    }

    /// ditto: on itself or another creature here.
    void scriptUnitFlags(ulong target, uint flags, bool set)
    {
        auto who = target == me.guid ? me : world_.creatureAt(target);
        if (who is null)
            return;
        const now = who.values.get!UNIT_FIELD_FLAGS;
        who.values.set!UNIT_FIELD_FLAGS(set ? now | flags : now & ~flags);
        world_.flushCreature(who);
    }

    /// ditto
    void scriptMelee(bool on)
    {
        meleeEnabled = on;
        if (!on)
            meleeStop(world_);
    }

    /// ditto
    void scriptRemoveAura(ulong target, uint spell)
    {
        if (auto creature = target == me.guid ? me : world_.creatureAt(target))
        {
            if (auto aura = creature.auras.find(spell))
            {
                creature.auras.remove(aura, creature.values);
                world_.flushCreature(creature);
            }
        }
        else if (auto other = world_.unit(target))
            other.auraRemovedBy(spell);
    }

    /// ditto
    void scriptDespawn(uint delay)
    {
        despawnTimer = delay ? delay : 1;
    }

    /// ditto
    void scriptDeathPrevention(bool on)
    {
        deathPrevention = on;
    }

    /// ditto
    void scriptRelay(int id, ulong target)
    {
        if (lore !is null && id != 0)
            lore.startRelay(id, world_, me.guid, target);
    }

    /// ditto: back to its template's faction with 0.
    void scriptFaction(uint faction)
    {
        const id = faction ? faction : me.template_.faction;
        me.factionTemplate = lore is null ? null : lore.clientData.factionTemplates.lookup(id);
        me.values.set!UNIT_FIELD_FACTIONTEMPLATE(id);
        world_.flushCreature(me);
    }

    /// ditto: for every player fighting it (`all`: those on its threat list), or one.
    void scriptQuestEvent(uint quest, ulong player, bool all)
    {
        if (!all)
        {
            if (auto other = world_.unit(player))
                other.questEventHappened(quest);
            return;
        }
        foreach (guid, _; threat)
            if (auto other = world_.unit(guid))
                if (other.fighter.alive)
                    other.questEventHappened(quest);
    }

    /// ditto
    void scriptKillCredit(uint entry, ulong player)
    {
        if (auto other = world_.unit(player))
            other.killCreditFrom(entry, me.guid);
    }

    /// ditto: summoned for a while out of combat, or until its corpse goes (`timedOutOfCombatOrDead`), or until
    /// out of combat at all (`timedOutOfCombat` with no time).
    bool scriptSummon(uint entry, ulong target, uint durationMs, uint spot)
    {
        import dmangos.world.creature : TempSpawnType;

        if (lore is null)
            return false;
        Position at;
        if (spot)
        {
            uint seconds;
            if (!lore.summonSpot(spot, at, seconds))
                return false;
            durationMs = seconds * 1000;
        }
        auto summoned = lore.summon(world_, entry, at,
            durationMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.timedOutOfCombat, durationMs, me.guid);
        if (summoned is null)
            return false;
        if (target)
            if (auto victim = world_.unit(target))
                summoned.ai.attackStart(victim, world_);
        return true;
    }

    /// ditto: to the creatures near that are not its enemies (itself left out).
    void scriptThrowAiEvent(uint type, float radius, ulong invoker)
    {
        foreach (other; world_.creaturesNear(me.position, radius))
            if (other !is me && other.alive && other.ai !is null && !isEnemy(relating, other.ai.relating, me.client))
                other.ai.aiEventFrom(type, me, invoker, world_);
    }

    /// Another creature's AI event, for its script.
    void aiEventFrom(uint type, Creature sender, ulong invoker, CombatWorld world)
    {
        if (script is null)
            return;
        world_ = world;
        script.aiEventReceived(this, type, sender.guid, sender.template_.entry, invoker);
    }

    /// ditto
    void scriptReactState(uint state)
    {
        if (state <= ReactState.max)
            react = cast(ReactState) state;
    }

    /// ditto
    uint victimHealthPercent()
    {
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return !other ? uint.max : other.healthPercent;
    }

    /// ditto
    float victimDistance()
    {
        return victim ? distanceTo(victim) : float.infinity;
    }

    /// ditto: by the target type, its threat list among the choices.
    ulong targetFor(int type, ulong invoker)
    {
        import std.algorithm.sorting : sort;

        switch (type)
        {
        case EventTarget.self:
            return me.guid;
        case EventTarget.hostile:
            return victim;
        case EventTarget.actionInvoker:
            return invoker;
        case EventTarget.hostileSecondAggro, EventTarget.hostileLastAggro, EventTarget.hostileRandom,
                EventTarget.hostileRandomNotTop, EventTarget.hostileRandomPlayer,
                EventTarget.hostileRandomNotTopPlayer:
        {
            ulong[] list = threat.keys;
            if (list.length == 0)
                return 0;
            list.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
            switch (type)
            {
            case EventTarget.hostileSecondAggro:
                return list.length > 1 ? list[1] : 0;
            case EventTarget.hostileLastAggro:
                return list[$ - 1];
            case EventTarget.hostileRandom, EventTarget.hostileRandomPlayer:
                return list[uniform(0, list.length, world_.random)];
            default:
                return list.length > 1 ? list[uniform(1, list.length, world_.random)] : 0;
            }
        }
        default:
            return 0;
        }
    }

    /// ditto
    bool scriptCast(uint spell, ulong target, uint flags)
    {
        return castSpell(lore is null ? null : lore.spellInfo(spell), target, flags);
    }

    /**
     * ditto: the text said, yelled or emoted around it (as far as each is heard),
     * or whispered to `target`; its emote with it.
     */
    void scriptText(uint id, ulong target)
    {
        const text = lore is null ? null : lore.broadcastText(id);
        if (text is null)
            return;
        speak(text, target);
    }

    /// `text` said, yelled or emoted as its type says (whispered to `target`).
    void speak(const(BroadcastText)* text, ulong target)
    {
        ChatType type;
        auto language = Language.LANG_UNIVERSAL;
        switch (text.chatType)
        {
        case 0:
            type = ChatType.CHAT_MSG_MONSTER_SAY;
            language = cast(Language) text.language;
            break;
        case 1, 6:
            type = ChatType.CHAT_MSG_MONSTER_YELL;
            break;
        case 2:
            type = ChatType.CHAT_MSG_MONSTER_EMOTE;
            break;
        case 3:
            type = ChatType.CHAT_MSG_RAID_BOSS_EMOTE;
            break;
        case 4, 5:
            type = text.chatType == 4 ? ChatType.CHAT_MSG_MONSTER_WHISPER : ChatType.CHAT_MSG_RAID_BOSS_WHISPER;
            break;
        default:
            return;
        }
        const body_ = monsterChatMessage(type, me.guid, me.template_.name, text.text(false), language, target);
        if (type == ChatType.CHAT_MSG_MONSTER_WHISPER || type == ChatType.CHAT_MSG_RAID_BOSS_WHISPER)
        {
            if (auto other = world_.unit(target))
                other.tell(Opcode.SMSG_MESSAGECHAT, body_);
        }
        else
            world_.sendInRange(me.position, lore.listenRange(type == ChatType.CHAT_MSG_RAID_BOSS_EMOTE
                ? ChatType.CHAT_MSG_MONSTER_YELL : type), Opcode.SMSG_MESSAGECHAT, body_);
        if (text.emotes[0].emote)
            scriptEmote(text.emotes[0].emote);
    }

    /// ditto
    void scriptEmote(uint emote)
    {
        ByteWriter w;
        w.put(emote);
        w.put(me.guid);
        world_.sendToObservers(me.guid, Opcode.SMSG_EMOTE, w.data);
    }

    /// ditto
    void scriptStandState(uint state)
    {
        me.values.setByte!UNIT_FIELD_BYTES_1(0, cast(ubyte) state);
        world_.flushCreature(me);
    }

    /// ditto: in fear for 7 seconds.
    bool scriptFlee()
    {
        if (!victim || fleeTimer > 0)
            return false;
        interruptCast();
        fleeTimer = 7000;
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.fleeing);
        world_.flushCreature(me);
        if (!me.spline.finalized)
            stopMoving(me, world_);
        return true;
    }

    /// ditto: the allies within `radius` yards that may help join in now.
    void scriptCallForHelp(float radius)
    {
        auto enemy = victim ? world_.unit(victim) : UnitRef.init;
        if (!enemy)
            return;
        foreach (other; world_.creaturesNear(me.position, radius))
            if (other !is me && other.ai !is null && other.ai.canAssistAgainst(me, enemy))
                other.ai.attackStart(enemy, world_);
    }

    /// ditto
    void scriptEvade()
    {
        if (inCombat_)
            enterEvadeMode(world_);
    }

    /// ditto
    void scriptAttack(ulong target)
    {
        if (auto other = world_.unit(target))
            attackStart(other, world_);
    }

    /// ditto: it stops where it is, or chases again.
    void scriptCombatMovement(bool on)
    {
        combatMovement_ = on;
        if (!on && !me.spline.finalized && !evadingHome)
            stopMoving(me, world_);
    }

    /// ditto: it keeps `distance` yards from its victim to cast.
    void scriptRangedMode(bool on, float distance)
    {
        rangedModeSet = rangedMode_ = on;
        chaseDistance_ = on ? distance : 0;
    }

    /// ditto
    @property bool rangedMode()
    {
        return rangedMode_;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A scripted creature (`creature_ai_scripts`): attacked, it yells and starts casting a bolt (1.5 s,
 * standing still), which hits the player; it puts damage over time on it that ticks; below half
 * health it heals itself once; out of mana it does not cast; evading, its script starts over.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind, count;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.eventai;
    import dmangos.world.movement : Position;
    import dmangos.world.npcdata : BroadcastText;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0], [2u, 1500, 0, 1500]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 6000, 0, 6000]]), "SpellDuration.dbc");
    enum uint bolt = 95001, mend = 95002, rot = 95003, yell = 95004;
    with (context.data.spells)
    {
        spells[bolt] = testSpell(bolt, 2, 6, 7, 2);         // 7 fire damage, 1.5 s
        spells.edit(bolt).casting.school = 2;
        spells.edit(bolt).casting.dmgClass = 0;                  // never resisted, for the test
        spells.edit(bolt).casting.manaCost = 50;
        spells[mend] = testSpell(mend, 10, 1, 200);         // heals itself 200
        spells[rot] = testSpell(rot, 6, 6, 3);              // 3 shadow damage every second for 6 s
        spells.edit(rot).casting.applyAuraName[0] = AuraType.periodicDamage;
        spells.edit(rot).casting.amplitude[0] = 1000;
        spells.edit(rot).casting.durationIndex = 1;
        spells.edit(rot).casting.school = 5;
        spells.edit(rot).casting.dmgClass = 0;
    }
    context.data.npcs.broadcastTexts[yell] = BroadcastText("You will die!", "", 0, 1);

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    keeper.values.set!UNIT_FIELD_MINDAMAGE(1.0f);
    keeper.values.set!UNIT_FIELD_MAXDAMAGE(1.0f);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    keeper.values.set!UNIT_FIELD_MAXPOWER1(120u);
    keeper.values.set!UNIT_FIELD_POWER1(120u);

    // On aggro: the yell and the bolt; every 5 s in combat the rot; below 50% the mend, once.
    EventAiEvent aggro = {id: 1, type: EventType.aggro, chance: 100};
    aggro.actions[0] = EventAiAction(ActionType.text, [yell, 0, 0]);
    aggro.actions[1] = EventAiAction(ActionType.castSpell, [bolt, EventTarget.hostile, 0]);
    EventAiEvent rotting = {id: 2, type: EventType.timerInCombat, chance: 100, flags: eventRepeatable,
        params: [2000, 2000, 5000, 5000, 0, 0]};
    rotting.actions[0] = EventAiAction(ActionType.castSpell, [rot, EventTarget.hostile, castAuraNotPresent]);
    EventAiEvent mending = {id: 3, type: EventType.hp, chance: 100, params: [50, 0, 0, 0, 0, 0]};
    mending.actions[0] = EventAiAction(ActionType.castSpell, [mend, EventTarget.self, 0]);
    auto events = [aggro, rotting, mending];
    keeper.ai.setScript(events, context.data.eventAi);

    const me = anduin.session.character;
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    auto got = anduin.read();
    tick(50);
    got ~= anduin.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_MESSAGECHAT), "the yell");
    assert(opcodesOf(got).canFind(Opcode.SMSG_SPELL_START) && keeper.ai.castingNow, "the bolt begins");
    const health = me.values.get!UNIT_FIELD_HEALTH;
    tick(1000);
    assert(keeper.ai.castingNow && me.values.get!UNIT_FIELD_HEALTH == health, "not yet");
    tick(600);
    got = anduin.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_SPELL_GO) && opcodesOf(got).canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG));
    assert(!keeper.ai.castingNow);
    assert(keeper.values.get!UNIT_FIELD_POWER1 == 70, "its mana spent");
    assert(me.values.get!UNIT_FIELD_HEALTH < health, "the bolt hurt");

    // The rot after two seconds, ticking on the player.
    foreach (_; 0 .. 4)
        tick(500);
    assert(anduin.session.inWorld.hasAuraOf(rot), "the rot on the player");
    anduin.read();
    foreach (_; 0 .. 6)
        tick(500);
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_PERIODICAURALOG) >= 2, "it ticks");

    // Below half: it heals itself, once.
    keeper.values.set!UNIT_FIELD_HEALTH(200u);
    tick(500);
    tick(500);
    assert(keeper.values.get!UNIT_FIELD_HEALTH >= 400 - 50, "the mend");
    keeper.values.set!UNIT_FIELD_HEALTH(200u);
    foreach (_; 0 .. 4)
        tick(500);
    assert(keeper.values.get!UNIT_FIELD_HEALTH < 300, "not again");

    // Out of mana, no bolt: 70 left, 50 a bolt.
    keeper.values.set!UNIT_FIELD_POWER1(10u);
    assert(!keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0), "out of mana");

    // A bolt begun, and the player's interrupt (Pummel's effect): it stops.
    import dmangos.bytes : ByteWriter;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    keeper.values.set!UNIT_FIELD_POWER1(120u);
    assert(keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0) && keeper.ai.castingNow);
    enum uint pummel = 95011;
    context.data.spells.spells[pummel] = testSpell(pummel, 68, 6, 0);
    context.data.spells.spells.edit(pummel).casting.dmgClass = 0;
    (cast(Player) me).spells ~= pummel;
    ByteWriter w;
    w.put(pummel);
    SpellTargets(TargetFlags.unit, keeper.guid).write(w);
    anduin.read();
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    assert(!keeper.ai.castingNow && opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_FAILURE), "interrupted");

    // A friend in the fight, badly hurt: healed (`EVENT_T_FRIENDLY_HP`, cast at the event's own target).
    auto trainer = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    trainer.factionTemplate = keeper.factionTemplate;
    trainer.values.set!UNIT_FIELD_MAXHEALTH(500u);
    trainer.values.set!UNIT_FIELD_HEALTH(100u);
    trainer.ai.attackedBy(anduin.session.inWorld.unit, map);
    enum uint mendOther = 95012;
    context.data.spells.spells[mendOther] = testSpell(mendOther, 10, 21, 200);
    EventAiEvent friendly = {id: 4, type: EventType.friendlyHp, chance: 100, flags: eventRepeatable,
        params: [100, 30, 3000, 3000, 0, 0]};
    friendly.actions[0] = EventAiAction(ActionType.castSpell, [mendOther, EventTarget.eventSpecific, 0]);
    auto healing = [friendly];
    keeper.ai.setScript(healing, context.data.eventAi);
    keeper.values.set!UNIT_FIELD_HEALTH(keeper.values.get!UNIT_FIELD_MAXHEALTH); // only the friend hurt
    assert(keeper.ai.inCombat && trainer.ai.inCombat);
    tick(600);
    assert(trainer.values.get!UNIT_FIELD_HEALTH == 300, "the friend healed");
}
