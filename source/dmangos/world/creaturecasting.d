/**
 * A creature's spells and script (CMaNGOS `UnitAI::DoCastSpellIfCan`, `Spell::prepare`/`cast` for a
 * creature caster, `CreatureEventAI`'s side of the AI), mixed into `dmangos.world.creatureai.CreatureAI`.
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

    private
    {
        CombatWorld world_;            // the map, while the AI acts
        EventAI script;                // its `creature_ai_scripts`; null if it has none
        CreatureLore lore;
        const(SpellInfo)* casting_;    // the spell being cast
        ulong castTarget;
        int castTimer;                 // until it goes off
        const(SpellInfo)* nextSwing;   // a spell on its next swing
        bool combatMovement_ = true;   // `UNIT_STAT_NO_COMBAT_MOVEMENT` off
        bool rangedModeSet;            // `m_rangedMode`: its script keeps it at a distance to cast
        bool rangedMode_;              // `m_currentRangedMode`: and it does now (not out of mana)
        float chaseDistance_ = 0;      // `m_chaseDistance`
        int fleeTimer;                 // running in fear, for so long yet
    }

    /// What its casts and texts need of the world's data (every creature made in the world has it).
    void setLore(CreatureLore lore)
    {
        this.lore = lore;
    }

    /// `CreatureEventAI`: the creature runs `events` (from `data`).
    void setScript(const(EventAiEvent)[] events, const EventAiData data)
    {
        this.script = new EventAI(events, data);
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
     * `DoCastSpellIfCan`: casts `spell` at `target` (itself, or a player) as `flags`
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
            auto other = world_.combatant(target);
            if (other is null || !other.fighter.alive)
                return false;
            if ((flags & castAuraNotPresent) && other.hasAuraOf(spell.id))
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
                // `HandleSpellCastResult`: out of mana, it comes in to fight (unless told not to).
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
            auto other = world_.combatant(castTarget);
            if (other is null || !other.fighter.alive)
                return interruptCast();
        }
        castTimer -= diff;
        if (castTimer > 0)
            return;
        auto spell = casting_;
        casting_ = null;
        go(spell, castTarget, true);
    }

    /// `InterruptNonMeleeSpells`: the cast stops (`SMSG_SPELL_FAILURE` around).
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

    /// The spell's mana cost for it (`CalculatePowerCost`).
    private int manaCost(const(SpellInfo)* spell)
    {
        return powerCost(*spell, me.values.get!UNIT_FIELD_LEVEL, me.values.get!UNIT_FIELD_MAXPOWER1,
            me.values.get!UNIT_FIELD_MAXHEALTH, me.values.get!UNIT_FIELD_MAXPOWER1);
    }

    /// `Spell::CheckRange`: within the spell's range of its target (and out of its minimum).
    private bool inRangeFor(const(SpellInfo)* spell, ulong target)
    {
        if (target == me.guid)
            return true;
        const r = range(*spell, lore.clientData);
        const d = distanceTo(target);
        // Its combat reach and the target's count towards the maximum (`GetCombatDistance`).
        return d <= r[1] + me.fighter.combatReach + 1.5f && (r[0] == 0 || d >= r[0]);
    }

    /// Yards to a target; infinity if it is not here.
    private float distanceTo(ulong target)
    {
        if (target == me.guid)
            return 0;
        auto other = world_.combatant(target);
        if (other is null)
            return float.infinity;
        const p = other.fighter.position;
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

    /// `ImplicitTarget`s the creature resolves: the caster, enemies in an area or cone, or the target.
    private ulong[] targetsFor(const(SpellInfo)* spell, size_t i, ulong target)
    {
        enum uint self = 1, enemyInArea = 15, enemyInAreaInstant = 16, casterCoordinates = 22, frontalCone = 24;
        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        const area = a == enemyInArea || a == enemyInAreaInstant || b == enemyInArea || b == enemyInAreaInstant;
        if (area || a == frontalCone)
        {
            auto center = me.position;
            if (area && a != casterCoordinates && a != self && target != me.guid)
                if (auto other = world_.combatant(target))
                    center = other.fighter.position;
            const r = radius(*spell, i, lore.clientData);
            ulong[] found;
            foreach (other; world_.combatantsNear(center, r))
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
     * `Spell::cast`: the spell goes off (`SMSG_SPELL_GO` with who it hit and missed) and its effects
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
                if (auto other = world_.combatant(guid))
                {
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
                    else if (spell.casting.dmgClass == 1 && uniform01(world_.random) * 100 < spellMissChance(level,
                            f.level, true))
                        miss = SpellMissInfo.resist;
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
                                world_.combatant(guid) ? world_.combatant(guid).fighter.armor : 0, value);
                        spellDamageTo(spell, guid, damage, -1);
                    }
                    break;
                case applyAura:
                    if (!auraDone)
                        auraOn(spell, guid);
                    break;
                case heal:
                    if (guid == me.guid)
                        healSelf(spell, value);
                    break;
                case triggerSpell:
                    if (const triggered = lore.spellInfo(spell.triggerSpell[i]))
                        castSpell(triggered, guid, castTriggered);
                    break;
                case 68: // SPELL_EFFECT_INTERRUPT_CAST
                    if (guid != me.guid)
                        if (auto other = world_.combatant(guid))
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

    /// A school's damage to a player (`DealSpellDamage`), armor taking some of physical; -1: already through armor.
    private void spellDamageTo(const(SpellInfo)* spell, ulong guid, uint damage, int school)
    {
        auto other = world_.combatant(guid);
        if (other is null)
            return;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(me.values.get!UNIT_FIELD_LEVEL, other.fighter.armor, damage);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(guid, me.guid,
            spell.id, damage, school < 0 ? 0 : school, 0, 0, false, 0, false));
        if (damage)
            triggerCombatTimer();
        other.spellHitBy(me.guid, damage);
        if (!other.fighter.alive && script !is null)
            script.killed(this, guid);
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
        if (guid == me.guid)
        {
            bool isNew;
            me.auras.apply(makeAura(spell, me.guid, level, ms, true, values), me.values, isNew);
            return;
        }
        if (auto other = world_.combatant(guid))
            other.auraFrom(me.guid, spell, level, ms, values);
    }

    /// `SPELL_EFFECT_HEAL` on itself.
    private void healSelf(const(SpellInfo)* spell, int value)
    {
        if (value <= 0)
            return;
        const health = me.values.get!UNIT_FIELD_HEALTH, maximum = me.values.get!UNIT_FIELD_MAXHEALTH;
        const healed = health + value > maximum ? maximum - health : value;
        me.values.set!UNIT_FIELD_HEALTH(health + healed);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELLHEALLOG,
            healLog(me.guid, me.guid, spell.id, healed, false));
    }

    /// The spell on its next swing, instead of the swing (`true`): its weapon damage.
    private bool swingSpell(Combatant target)
    {
        if (nextSwing is null)
            return false;
        auto spell = nextSwing;
        nextSwing = null;
        go(spell, target.combatGuid, true);
        return true;
    }

    // -----------------------------------------------------------------------
    // Fleeing (`DoFlee`, `TimedFleeingMovementGenerator`)
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
        if (auto enemy = world_.combatant(victim))
            from = enemy.fighter.position;
        // Away from the enemy, a little to one side or the other.
        const angle = angleTo(from, me.position) + uniform(-0.6f, 0.6f, world_.random);
        import std.math : cos, sin;

        const x = me.position.x + 12 * cos(angle), y = me.position.y + 12 * sin(angle);
        auto z = world_.groundHeight(x, y, me.position.z + 2, false);
        if (!(z > -100_000))
            z = me.position.z;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world_, points, false);
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
    uint victimHealthPercent()
    {
        auto other = victim ? world_.combatant(victim) : null;
        return other is null ? uint.max : other.healthPercent;
    }

    /// ditto
    float victimDistance()
    {
        return victim ? distanceTo(victim) : float.infinity;
    }

    /// ditto: `GetTargetByType` over its threat list.
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
     * ditto: `DoDisplayText` — the text said, yelled or emoted around it (as far as each is heard),
     * or whispered to `target`; its emote with it.
     */
    void scriptText(uint id, ulong target)
    {
        const text = lore is null ? null : lore.broadcastText(id);
        if (text is null)
            return;
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
            if (auto other = world_.combatant(target))
                other.tell(Opcode.SMSG_MESSAGECHAT, body_);
        }
        else
            world_.sendInRange(me.position, lore.listenRange(type == ChatType.CHAT_MSG_RAID_BOSS_EMOTE
                ? ChatType.CHAT_MSG_MONSTER_YELL : type), Opcode.SMSG_MESSAGECHAT, body_);
        if (text.emotes[0].emote)
            scriptEmote(text.emotes[0].emote);
    }

    /// ditto: `HandleEmote`
    void scriptEmote(uint emote)
    {
        ByteWriter w;
        w.put(emote);
        w.put(me.guid);
        world_.sendToObservers(me.guid, Opcode.SMSG_EMOTE, w.data);
    }

    /// ditto: `SetStandState`
    void scriptStandState(uint state)
    {
        me.values.setByte!UNIT_FIELD_BYTES_1(0, cast(ubyte) state);
        world_.flushCreature(me);
    }

    /// ditto: `DoFlee` — in fear for `CreatureFamilyFleeDelay` (7 seconds).
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

    /// ditto: `CallForHelp` — the allies within `radius` yards that may help join in now.
    void scriptCallForHelp(float radius)
    {
        auto enemy = victim ? world_.combatant(victim) : null;
        if (enemy is null)
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
        if (auto other = world_.combatant(target))
            attackStart(other, world_);
    }

    /// ditto: `SetCombatMovement` — it stops where it is, or chases again.
    void scriptCombatMovement(bool on)
    {
        combatMovement_ = on;
        if (!on && !me.spline.finalized && !evadingHome)
            stopMoving(me, world_);
    }

    /// ditto: `SetRangedMode` — it keeps `distance` yards from its victim to cast.
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
        spells[bolt].casting.school = 2;
        spells[bolt].casting.dmgClass = 0;                  // never resisted, for the test
        spells[bolt].casting.manaCost = 50;
        spells[mend] = testSpell(mend, 10, 1, 200);         // heals itself 200
        spells[rot] = testSpell(rot, 6, 6, 3);              // 3 shadow damage every second for 6 s
        spells[rot].casting.applyAuraName[0] = AuraType.periodicDamage;
        spells[rot].casting.amplitude[0] = 1000;
        spells[rot].casting.durationIndex = 1;
        spells[rot].casting.school = 5;
        spells[rot].casting.dmgClass = 0;
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
    assert(anduin.session.hasAuraOf(rot), "the rot on the player");
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
    context.data.spells.spells[pummel].casting.dmgClass = 0;
    (cast(Player) me).spells ~= pummel;
    ByteWriter w;
    w.put(pummel);
    SpellTargets(TargetFlags.unit, keeper.guid).write(w);
    anduin.read();
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    assert(!keeper.ai.castingNow && opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_FAILURE), "interrupted");
}
