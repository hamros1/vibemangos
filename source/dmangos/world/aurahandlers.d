/**
 * Auras on players and the creatures they cast at (CMaNGOS `Spell::EffectApplyAura`, `SpellAuras.cpp`'s
 * handlers and periodic ticks, `HandleCancelAuraOpcode`), mixed into `dmangos.world.character.Character`.
 *
 * What an aura does while it lasts: stats, resistances, armor and attack power (the stats are worked
 * out again), speeds (and mounts), a stance or form, being rooted or stunned, and periodic effects:
 * damage and heals over time, food's health and drink's mana, energize, triggered spells. Auras end
 * when their time is up, when cancelled (positive ones), at death, and by what their
 * `AuraInterruptFlags` say: standing up (food and drink), moving, taking damage, casting, attacking.
 * Not yet: saving auras (they end at logout), dispels, procs, absorbs, area auras on others.
 */
module dmangos.world.aurahandlers;

/// See the module documentation.
mixin template AuraHandlers()
{
    import core.time : Duration;
    import std.random : uniform01;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.auras;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.movement : baseMoveSpeed, MoveType;
    import dmangos.world.opcodes;
    import dmangos.world.player : DeathState;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellcast : duration, effectValue, SpellTargets, TargetFlags;
    import dmangos.world.combat : armorReducedDamage;
    import dmangos.world.packets : ServerStandStateUpdate;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

private:
    float manaFromDrink = 0; // drink's mana not yet whole

    /**
     * `SPELL_EFFECT_APPLY_AURA` (at the spell's first aura effect, for all of them): the aura on its
     * target, this player or another, or a creature.
     */
    void applyAuraEffect(const(SpellInfo)* spell, size_t i, ulong target)
    {
        enum uint applyAura = 6;
        foreach (j; 0 .. i)
            if (spell.effect[j] == applyAura)
                return;
        int[3] values;
        foreach (j; 0 .. 3)
            if (spell.effect[j] == applyAura)
                values[j] = effectMod(spell, j, effectValue(*spell, j, player.data.level, uniform01(map.random)));
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        // Damage over time (`SPELLMOD_DOT`): what each tick deals.
        foreach (j; 0 .. 3)
            if (spell.effect[j] == applyAura && spell.casting.applyAuraName[j] == AuraType.periodicDamage)
                values[j] = spellMod(SpellModOp.dot, spell, values[j]);
        // `SpellDamageBonusDone` / `SpellHealingBonusDone` over time: the bonus times the duration over
        // 15 seconds (at most whole), shared out among the ticks.
        foreach (j; 0 .. 3)
            if (spell.effect[j] == applyAura && spell.casting.amplitude[j] > 0 && ms > 0)
            {
                const type = cast(AuraType) spell.casting.applyAuraName[j];
                int done;
                if (type == AuraType.periodicDamage)
                    done = auraBonus(AuraType.modDamageDone, spell.casting.school);
                else if (type == AuraType.periodicHeal)
                    done = auraBonus(AuraType.modHealingDone, uint.max);
                if (done > 0)
                {
                    const ticks = ms / spell.casting.amplitude[j];
                    const coefficient = ms >= 15_000 ? 1.0f : ms / 15_000.0f;
                    if (ticks > 0)
                        values[j] += cast(int)(done * coefficient / ticks);
                }
            }
        if (auto creature = cast(Creature) map.findObject(target))
        {
            if (!creature.alive)
                return;
            auto aura = makeAura(spell, player.guid, player.data.level, ms, false, values);
            bool isNew;
            creature.auras.apply(aura, creature.values, isNew);
            map.flushObjectChanges(creature);
            foreach (j; 0 .. 3)
                if (spell.effect[j] == applyAura)
                    auraAppliedScript(spell, j, target, values[j]);
            spellAttacked(creature, 0);
            return;
        }
        auto who = target == player.guid ? this : cast(typeof(this)) context.onlinePlayer(target);
        if (who is null || who.player is null || who.map !is map)
            return;
        // On an enemy (a duel's opponent) it is a debuff.
        const hostile = who !is this && canAttack(relatingNow(), who.relatingNow(), context.client);
        who.addAura(makeAura(spell, player.guid, player.data.level, ms, !hostile, values));
    }

    /// The caster's auras of `type` (for spells of `school`; `uint.max`: any): their amounts summed.
    int auraBonus(AuraType type, uint school)
    {
        if (school == 0)
            return 0; // physical: none
        int done;
        foreach (aura; player.auras.list)
            foreach (k; 0 .. 3)
                if ((aura.effects & (1 << k)) && aura.type(k) == type
                    && (school == uint.max || (aura.misc(k) & (1 << school))))
                    done += aura.amount[k];
        return done;
    }

    /// The aura on this player: its effects begin (if new), its duration shown.
    package void addAura(Aura aura)
    {
        bool isNew;
        auto applied = player.auras.apply(aura, player.values, isNew);
        if (isNew)
            auraEffects(applied, true);
        sendAuraDuration(applied);
        flushPlayerChanges();
    }

    /// The aura ends: its slot empties, its effects end.
    package void removeAura(Aura aura)
    {
        player.auras.remove(aura, player.values);
        auraEffects(aura, false);
        flushPlayerChanges();
    }

    /// `Unit::DispelAll`: the negative auras go, and with `positive` the positive ones too (not the passive).
    package void dispelAll(bool positive)
    {
        if (player is null)
            return;
        foreach (aura; player.auras.list.dup)
            if (!aura.passive && (positive || !aura.positive))
                removeAura(aura);
    }

    /// `SMSG_UPDATE_AURA_DURATION`: how long the aura in its slot lasts, for the client's buff bar.
    void sendAuraDuration(const Aura aura)
    {
        if (aura.slot == noSlot || aura.passive)
            return;
        ByteWriter w;
        w.put(aura.slot);
        w.put(cast(uint) aura.duration);
        deliver(Opcode.SMSG_UPDATE_AURA_DURATION, w.data);
    }

    /**
     * What an aura's effects do as it begins (`apply`) and ends: the `HandleAura*` functions this
     * server has.
     */
    void auraEffects(Aura aura, bool apply)
    {
        bool stats, speeds, movement;
        foreach (i; 0 .. 3)
        {
            if (!(aura.effects & (1 << i)))
                continue;
            switch (aura.type(i))
            {
            case AuraType.modStat, AuraType.modPercentStat, AuraType.modResistance, AuraType.modAttackPower,
                    AuraType.modRangedAttackPower, AuraType.modIncreaseHealth, AuraType.modIncreaseEnergy:
                stats = true;
                break;
            case AuraType.modIncreaseSpeed, AuraType.modDecreaseSpeed, AuraType.modIncreaseSwimSpeed:
                speeds = true;
                break;
            case AuraType.modIncreaseMountedSpeed:
                speeds = true;
                break;
            case AuraType.mounted:
                uint display;
                if (apply)
                    if (const t = cast(uint) aura.misc(i) in context.data.creatureTemplates)
                        display = t.modelId1;
                player.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
                break;
            case AuraType.modShapeshift:
                player.values.setByte!UNIT_FIELD_BYTES_1(2, apply ? cast(ubyte) aura.misc(i) : 0);
                break;
            case AuraType.modRoot, AuraType.modStun:
                movement = true;
                break;
            default:
                break;
            }
        }
        // Food and drink sit down (`_AddSpellAuraHolder`).
        if (apply && (aura.spell.casting.auraInterruptFlags & AuraInterrupt.standingCancels)
            && player.values.getByte!UNIT_FIELD_BYTES_1(0) == 0)
        {
            player.setStandState(1);
            send(ServerStandStateUpdate(1));
        }
        if (stats)
            player.refreshEquipmentStats(context.data);
        if (speeds)
            refreshSpeeds();
        if (movement)
            refreshRooted();
    }

    /// `UpdateSpeed`: run and swim speeds by the strongest speed-up (or mount) and slow.
    void refreshSpeeds()
    {
        const auras = &player.auras;
        int up = auras.strongest(AuraType.modIncreaseSpeed, true);
        const mounted = auras.strongest(AuraType.modIncreaseMountedSpeed, true);
        if (mounted > up)
            up = mounted;
        const down = auras.strongest(AuraType.modDecreaseSpeed, false);
        float factor = (1 + up / 100.0f) * (1 + down / 100.0f);
        if (player.deathState == DeathState.ghost)
            factor *= player.data.race == 4 ? 1.5f : 1.25f;
        const run = baseMoveSpeed[MoveType.run] * factor;
        if (run != player.speeds[MoveType.run])
            forceSpeed!(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)(MoveType.run, run);
        const swimFactor = factor * (1 + auras.strongest(AuraType.modIncreaseSwimSpeed, true) / 100.0f);
        const swim = baseMoveSpeed[MoveType.swim] * swimFactor;
        if (swim != player.speeds[MoveType.swim])
            forceSpeed!(Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE)(MoveType.swim, swim);
    }

    /// `SetRooted`, `SetStunned`: rooted while any root or stun lasts (and stunned while a stun does).
    void refreshRooted()
    {
        const stunned = player.auras.has(AuraType.modStun);
        const rooted = stunned || player.auras.has(AuraType.modRoot);
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        player.values.set!UNIT_FIELD_FLAGS(stunned ? flags | UnitFlags.stunned : flags & ~UnitFlags.stunned);
        if (rooted)
            sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        else if (player.deathState != DeathState.corpse)
            sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
    }

    /// `RemoveAurasWithInterruptFlags`: what standing up, moving, damage, casting or attacking ends.
    package void interruptAuras(uint flags)
    {
        if (player is null)
            return;
        foreach (aura; player.auras.interruptedBy(flags))
            removeAura(aura);
    }

    /// `RemoveAllAurasOnDeath`: all but the passive ones.
    package void removeAurasOnDeath()
    {
        foreach (aura; player.auras.list.dup)
            if (!aura.passive)
                removeAura(aura);
    }

    /// `Player::_SaveAuras`: the auras that last (not passive ones), as they are now.
    package void saveAuras()
    {
        import dmangos.world.database : AuraRecord;

        AuraRecord[] rows;
        foreach (aura; player.auras.list)
            if (!aura.passive && aura.duration != 0)
                rows ~= AuraRecord(aura.caster, aura.spell.id, aura.stacks, aura.amount, aura.periodTimer,
                    aura.maxDuration, aura.duration, aura.effects);
        context.database.saveAuras(player.data.guid, rows);
    }

    /// `Player::_LoadAuras`: the auras saved at the last logout, with the time they had left.
    package void loadAuras()
    {
        foreach (ref row; context.database.loadAuras(player.data.guid))
        {
            const spell = context.data.spells.spell(row.spell);
            if (spell is null || row.remaining == 0)
                continue;
            auto aura = makeAura(spell, row.caster, player.data.level, row.maxDuration, true, row.amount);
            aura.duration = row.remaining;
            aura.stacks = row.stacks ? row.stacks : 1;
            foreach (i; 0 .. 3)
                if (aura.period[i] > 0 && row.periodTimer[i] > 0)
                    aura.periodTimer[i] = row.periodTimer[i];
            addAura(aura);
        }
    }

    /// `HandleCancelAuraOpcode`: a positive aura the player clicks off.
    @Handles(Opcode.CMSG_CANCEL_AURA, WorldState.inWorld)
    void handleCancelAura(ref ByteReader reader)
    {
        const spell = reader.read!uint;
        if (auto aura = player.auras.find(spell))
            if (aura.positive && !(aura.spell.attributes & spellAttrNoAuraCancel))
                removeAura(aura);
    }

    /// The auras' time passes (`SpellAuraHolder::Update`): their ticks, then those that ended; drink's mana.
    void updateAuras(Duration elapsed)
    {
        const ms = cast(int) elapsed.total!"msecs";
        if (player.auras.list.length == 0 || ms <= 0)
            return;
        AuraTick[] ticks;
        Aura[] expired;
        player.auras.update(ms, ticks, expired);
        foreach (tick; ticks)
            selfTick(tick.aura, tick.effect);
        // `UpdateManaRegen`: drink (`MOD_POWER_REGEN` of mana) adds its mana every 5 seconds' worth.
        const drink = player.auras.totalByMisc(AuraType.modPowerRegen, Power.mana);
        if (drink > 0 && player.deathState == DeathState.alive)
        {
            manaFromDrink += drink * ms / 5000.0f;
            if (manaFromDrink >= 1)
            {
                player.modifyPower(Power.mana, cast(int) manaFromDrink);
                manaFromDrink -= cast(int) manaFromDrink;
            }
        }
        foreach (aura; expired)
            removeAura(aura);
        if (ticks.length || drink > 0)
            flushPlayerChanges();
    }

    /// `Aura::PeriodicTick` on this player.
    void selfTick(Aura aura, size_t i)
    {
        if (player.deathState != DeathState.alive)
            return;
        auto v = &player.values;
        const amount = aura.amount[i] > 0 ? aura.amount[i] : 0;
        uint healed;
        switch (aura.type(i))
        {
        case AuraType.periodicHeal, AuraType.modRegen:
            healed = amount;
            break;
        case AuraType.obsModHealth:
            healed = v.get!UNIT_FIELD_MAXHEALTH * amount / 100;
            break;
        case AuraType.obsModMana:
            player.modifyPower(Power.mana, cast(int)(v.get!UNIT_FIELD_MAXPOWER1(Power.mana) * amount / 100));
            return periodicLog(player.guid, aura, i, amount, Power.mana);
        case AuraType.periodicEnergize:
            if (aura.misc(i) >= 0 && aura.misc(i) <= Power.happiness)
                player.modifyPower(cast(Power) aura.misc(i), amount);
            return periodicLog(player.guid, aura, i, amount, cast(uint) aura.misc(i));
        case AuraType.periodicTriggerSpell:
            if (const spell = context.data.spells.spell(aura.spell.triggerSpell[i]))
                castSpell(spell, SpellTargets(TargetFlags.self, player.guid), true, 0);
            return;
        case AuraType.periodicDamage:
        {
            // A creature's damage over time (armor takes off physical).
            if (aura.caster == player.guid || amount == 0)
                return;
            uint damage = amount;
            if (aura.spell.casting.school == 0)
                damage = cast(uint) armorReducedDamage(aura.casterLevel, player.fighter.armor, damage);
            periodicLog(player.guid, aura, i, damage, 0);
            import dmangos.world.unit : Blow, dealDamage;

            return dealDamage(map.unit(aura.caster), unit, damage, Blow.periodic());
        }
        default:
            return;
        }
        const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
        if (health >= maxHealth)
            return;
        v.set!UNIT_FIELD_HEALTH(health + healed > maxHealth ? maxHealth : health + healed);
        if (aura.type(i) != AuraType.modRegen) // food shows no log
            periodicLog(player.guid, aura, i, healed, 0);
    }

    /// `SMSG_PERIODICAURALOG`
    void periodicLog(ulong target, const Aura aura, size_t i, uint amount, uint powerOrSchool)
    {
        ByteWriter w;
        w.putPackedGuid(target);
        w.putPackedGuid(aura.caster);
        w.put(aura.spell.id);
        w.put(1u);
        w.put(cast(uint) aura.type(i));
        switch (aura.type(i))
        {
        case AuraType.periodicDamage:
            w.put(amount);
            w.put(aura.spell.casting.school);
            w.put(0u);
            w.put(0);
            break;
        case AuraType.periodicHeal, AuraType.obsModHealth:
            w.put(amount);
            break;
        default:
            w.put(powerOrSchool);
            w.put(amount);
            break;
        }
        if (target == player.guid)
            return map.sendToWatchers(this, Opcode.SMSG_PERIODICAURALOG, w.data, true);
        map.sendToObservers(target, Opcode.SMSG_PERIODICAURALOG, w.data);
        if (!map.seesObject(player.guid, target))
            deliver(Opcode.SMSG_PERIODICAURALOG, w.data);
    }

    /**
     * See `UnitRef.auraTick`: a periodic effect of this player's aura on a creature ticked: damage
     * over time hurts it as a spell would (tapping, threat, the kill); a leech heals this player.
     */
    package void creatureAuraTick(Creature target, Aura aura, size_t i)
    {
        if (!target.alive || player is null)
            return;
        // Its spell's script may make this tick another (`OnPeriodicCalculateAmount`).
        int scripted = aura.amount[i];
        if (aura.period[i] > 0 && aura.maxDuration > 0)
            scripted = auraTickScript(aura.spell, i, target.guid, (aura.maxDuration - aura.duration) / aura.period[i],
                aura.maxDuration / aura.period[i], aura.amount[i]);
        const amount = scripted > 0 ? cast(uint) scripted : 0;
        switch (aura.type(i))
        {
        case AuraType.periodicDamage, AuraType.periodicLeech:
            uint damage = amount;
            const school = aura.spell.casting.school;
            if (school == 0)
                damage = cast(uint) armorReducedDamage(player.data.level, target.fighter.armor, damage);
            else if (school != 1)
            {
                // A tick partly resisted; a binary spell's at a tenth of the resistance.
                import dmangos.world.combat : effectiveResistPercent, rollPartialResist;
                import dmangos.world.spellcast : isBinarySpell;
                import std.random : uniform;

                const binary = isBinarySpell(*aura.spell);
                float percent = effectiveResistPercent(cast(int) target.values.get!UNIT_FIELD_RESISTANCES(school),
                    player.data.level, target.values.get!UNIT_FIELD_LEVEL, !binary);
                if (percent > 0 && binary)
                    percent *= 0.1f;
                const share = rollPartialResist(percent, uniform!"[]"(1u, 10000u, map.random), false);
                damage = share >= 0 ? damage - cast(uint)(damage * share) : damage + cast(uint)(damage * -share);
            }
            periodicLog(target.guid, aura, i, damage, aura.spell.casting.school);
            spellAttacked(target, damage, true);
            break;
        default:
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A buff raises a stat while it lasts and shows on the buff bar; food sits the player down and heals
 * every 5 seconds until it stands; damage over time ticks on a creature; a speed buff speeds up;
 * a buff can be cancelled.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind, count;
    import dmangos.dbc : buildDbc;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Stat;
    import dmangos.world.movement : MoveType, Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientStandStateChange;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
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
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 10_000, 0, 10_000], [2u, 9000, 0, 9000], [3u, -1, 0, -1]]), "SpellDuration.dbc");
    enum uint wits = 91001, meal = 91002, gash = 91003, haste = 91004;
    with (context.data.spells)
    {
        spells[wits] = testSpell(wits, 6, 1, 2);                    // +2 intellect, 10 s
        spells[wits].casting.applyAuraName[0] = AuraType.modStat;
        spells[wits].miscValue[0] = Stat.intellect;
        spells[wits].casting.durationIndex = 1;
        spells[meal] = testSpell(meal, 6, 1, 16);                   // 16 health every 5 s, sitting
        spells[meal].casting.applyAuraName[0] = AuraType.modRegen;
        spells[meal].casting.durationIndex = 3;
        spells[meal].casting.auraInterruptFlags = 0x00040000;
        spells[meal].attributes = 0x08000000;                       // castable while sitting
        spells[gash] = testSpell(gash, 6, 6, 5);                    // 5 damage every 3 s for 9 s
        spells[gash].casting.applyAuraName[0] = AuraType.periodicDamage;
        spells[gash].casting.amplitude[0] = 3000;
        spells[gash].casting.durationIndex = 2;
        spells[gash].casting.school = 1;
        spells[gash].casting.dmgClass = 0; // no hit roll: the test must not depend on a 1% miss
        spells[haste] = testSpell(haste, 6, 1, 50);                 // 50% faster
        spells[haste].casting.applyAuraName[0] = AuraType.modIncreaseSpeed;
        spells[haste].casting.durationIndex = 1;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= [wits, meal, gash, haste];

    ubyte[] castAt(uint spell, ulong target)
    {
        ByteWriter w;
        w.put(spell);
        SpellTargets(target ? TargetFlags.unit : TargetFlags.self, target).write(w);
        return w.data.dup;
    }

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        context.map(0).update(ms.msecs);
    }

    // The buff: two more intellect, in the first positive slot, for ten seconds.
    const intellect = me.values.get!UNIT_FIELD_STAT0(Stat.intellect);
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(wits, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_UPDATE_AURA_DURATION));
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.intellect) == intellect + 2 && me.values.get!UNIT_FIELD_AURA(0) == wits);
    tick(10_100);
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.intellect) == intellect && me.values.get!UNIT_FIELD_AURA(0) == 0,
        "it ended");
    anduin.read();

    // Food: sitting, 16 health every 5 seconds; standing up ends it.
    me.values.set!UNIT_FIELD_HEALTH(10u);
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(meal, 0));
    assert(me.values.getByte!UNIT_FIELD_BYTES_1(0) == 1, "sat down");
    tick(5000);
    assert(me.values.get!UNIT_FIELD_HEALTH >= 26, "16 from the food (and the regeneration of sitting)");
    anduin.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(0));
    assert(me.auras.list.length == 0);
    anduin.read();

    // Damage over time on the innkeeper (an enemy): three ticks of 5.
    enum uint players = 1, monsters = 8;
    const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, players, 0,
        0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    (cast(Player) me).values.set!UNIT_FIELD_LEVEL(60u); // so that the spell is not resisted
    (cast(Player) me).data.level = 60;
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(gash, keeper.guid));
    assert(keeper.auras.list.length == 1 && keeper.values.get!UNIT_FIELD_AURA(32) == gash);
    foreach (_; 0 .. 10)
        tick(1000);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 485, "three ticks");
    assert(keeper.auras.list.length == 0 && keeper.values.get!UNIT_FIELD_AURA(32) == 0, "and it ended");
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_PERIODICAURALOG) == 3);

    // With +30 holy damage done: 30 times 9 s over 15 s, over 3 ticks: 6 more a tick.
    {
        enum uint devotion = 91005;
        context.data.spells.spells[devotion] = testSpell(devotion, 6, 1, 30);
        context.data.spells.spells[devotion].casting.applyAuraName[0] = AuraType.modDamageDone;
        context.data.spells.spells[devotion].miscValue[0] = 1 << 1; // holy
        import dmangos.world.auras : makeAura;

        auto bonus = makeAura(&context.data.spells.spells[devotion], me.guid, 60, -1, true, [30, 0, 0]);
        bonus.passive = true;
        anduin.session.inWorld.addAura(bonus);
        now += 2.seconds;
        anduin.write(Opcode.CMSG_CAST_SPELL, castAt(gash, keeper.guid));
        foreach (_; 0 .. 10)
            tick(1000);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == 485 - 3 * 11, "three ticks of 5 and 6");
        anduin.session.inWorld.removeAura((cast(Player) me).auras.find(devotion));
        anduin.read();
    }

    // Faster; then the buff is clicked off.
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(haste, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE));
    assert(me.speeds[MoveType.run] == 7.0f * 1.5f);
    ByteWriter cancel;
    cancel.put(haste);
    anduin.write(Opcode.CMSG_CANCEL_AURA, cancel.data);
    assert(me.speeds[MoveType.run] == 7.0f && me.auras.list.length == 0);
}

/// Auras last across a logout: saved with the time they had left, and back at the next login.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.database : AuraRecord;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint wits = 91001;
    context.data.spells.spells[wits] = testSpell(wits, 6, 1, 2);
    context.data.spells.spells[wits].casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells[wits].miscValue[0] = 3;
    db.auraRows[7] = [AuraRecord(7, wits, 1, [2, 0, 0], [0, 0, 0], 60_000, 42_000, 1)];
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    assert(me.auras.list.length == 1 && me.auras.list[0].duration == 42_000 && me.values.get!UNIT_FIELD_AURA(0) == wits);
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    import core.time : seconds;

    anduin.session.update(25.seconds);
    assert(db.auraRows[7].length == 1 && db.auraRows[7][0].remaining > 0, "saved again at logout");
}
