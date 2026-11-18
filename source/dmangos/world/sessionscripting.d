/**
 * The player's session as the host of spell and area trigger scripts (docs/SCRIPTING.md): a spell
 * script runs when a dummy or script effect of the player's spell hits (`EffectHit`), an area
 * trigger script when the player walks into its trigger (`TriggerEntered`); both act through the
 * session, by the rules its own actions follow. Mixed into `dmangos.world.session.Character`.
 */
module dmangos.world.sessionscripting;

/// See the module documentation.
mixin template SessionScripting()
{
    import dmangos.script.api : ActionResult, AreaTriggerContext, AreaTriggerHost, EffectHit, EntityRef, Location,
        QuestProgress, SpellContext, SpellHost, TriggerEntered;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    private const(SpellInfo)* scriptSpell; // the spell whose script is running

    /**
     * A dummy or script effect `i` of `spell` hit `target`: the spell's script hears of it; true if it
     * consumed the effect (its database script does not run).
     */
    package bool spellEffectScript(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        auto handle = context.spellScript(spell.id);
        if (!handle)
            return false;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = null;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, EffectHit(EntityRef(player.guid), EntityRef(target), cast(ubyte) i, value));
        return c.consumed;
    }

    /// An aura of this player's `spell` (its effect `i`, of `amount`) went onto `target`: the spell's script hears of it.
    package void auraAppliedScript(const(SpellInfo)* spell, size_t i, ulong target, int amount)
    {
        import dmangos.script.api : AuraApplied;

        auto handle = context.spellScript(spell.id);
        if (!handle)
            return;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = null;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, AuraApplied(EntityRef(player.guid), EntityRef(target), cast(ubyte) i, amount));
    }

    /// A periodic effect `i` of this player's aura ticks on `target`: what the tick does, as the
    /// spell's script has it (Curse of Agony's ramp).
    package int auraTickScript(const(SpellInfo)* spell, size_t i, ulong target, uint tick, uint ticks, int amount)
    {
        import dmangos.script.api : AuraTicked;

        auto handle = context.spellScript(spell.id);
        if (!handle)
            return amount;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = null;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, AuraTicked(EntityRef(player.guid), EntityRef(target), cast(ubyte) i, tick,
            ticks, amount));
        return c.amountChanged ? c.amount : amount;
    }

    /// The player walked into area trigger `id` (at `at`): its script hears of it; true if it consumed it.
    package bool areaTriggerScript(uint id, Location at)
    {
        auto handle = context.areaTriggerScript(id);
        if (!handle)
            return false;
        auto c = AreaTriggerContext(scriptHost);
        context.scripts.raise(handle, c, TriggerEntered(EntityRef(player.guid), id, at));
        return c.consumed;
    }

    /// Where this player stands with `quest` (`UnitRef.questStatusOf`).
    package QuestProgress questStatusFor(uint quest)
    {
        import dmangos.world.quests : QuestState;

        if (player is null)
            return QuestProgress.none;
        if (auto q = quest in player.questStatus)
        {
            if (q.rewarded)
                return QuestProgress.rewarded;
            switch (q.status)
            {
            case QuestState.incomplete:
                return QuestProgress.incomplete;
            case QuestState.complete:
                return QuestProgress.complete;
            case QuestState.failed:
                return QuestProgress.failed;
            default:
                return QuestProgress.none;
            }
        }
        return QuestProgress.none;
    }

    /// The script contexts' side of the session (the interfaces are implemented here, not by the
    /// session class: a mixin's methods come too late for that).
    private final class ScriptHost : SpellHost, AreaTriggerHost
    {
        uint hostSpellId() { return this.outer.hostSpellId(); }
        ActionResult hostCastFrom(EntityRef caster, uint spellId, EntityRef target, bool triggered) { return this.outer.hostCastFrom(caster, spellId, target, triggered); }
        ActionResult hostDamage(EntityRef target, uint amount) { return this.outer.hostDamage(target, amount); }
        ActionResult hostEnergize(EntityRef target, ubyte power, int amount) { return this.outer.hostEnergize(target, power, amount); }
        uint hostHealth(EntityRef who) { return this.outer.hostHealth(who); }
        void hostQuestEvent(EntityRef who, uint quest) { this.outer.hostQuestEvent(who, quest); }
        void hostKillCredit(EntityRef who, uint entry) { this.outer.hostKillCredit(who, entry); }
        EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack) { return this.outer.hostSummonAt(entry, at, despawnMs, attack); }
        ActionResult hostSignalCreature(EntityRef to, uint id, int value) { return this.outer.hostSignalCreature(to, id, value); }
        QuestProgress hostQuestStatusOf(EntityRef who, uint quest) { return this.outer.hostQuestStatusOf(who, quest); }
        EntityRef hostCreatureNear(uint entry, Location at, float range) { return this.outer.hostCreatureNear(entry, at, range); }
        void hostSignalDungeon(uint id, int value) { this.outer.hostSignalDungeon(id, value); }
        void hostLog(string text) { this.outer.hostLog(text); }
        ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent) { return this.outer.hostModifyThreat(creature, target, percent); }
    }

    private ScriptHost scriptHost_;

    private @property ScriptHost scriptHost()
    {
        if (scriptHost_ is null)
            scriptHost_ = new ScriptHost;
        return scriptHost_;
    }

    private Character sessionHere(EntityRef who)
    {
        import dmangos.world.character : Character;

        if (player !is null && who.guid == player.guid)
            return this;
        auto other = cast(Character) context.onlinePlayer(who.guid);
        return other !is null && other.player !is null && other.map is map ? other : null;
    }

    // -----------------------------------------------------------------------
    // `SpellHost` and `AreaTriggerHost`
    // -----------------------------------------------------------------------

    uint hostSpellId()
    {
        return scriptSpell is null ? 0 : scriptSpell.id;
    }

    ActionResult hostCastFrom(EntityRef caster, uint spellId, EntityRef target, bool triggered)
    {
        import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;

        const spell = context.data.spells.spell(spellId);
        if (spell is null)
            return ActionResult.failed;
        if (caster.guid == player.guid)
        {
            const self = !target || target.guid == player.guid;
            const result = castSpell(spell, SpellTargets(self ? TargetFlags.self : TargetFlags.unit,
                self ? player.guid : target.guid), triggered, 0);
            return result == SpellCastResult.ok ? ActionResult.ok : ActionResult.notAllowed;
        }
        if (auto creature = map.creatureAt(caster.guid))
            return creature.ai.castFor(map, spellId, target.guid, triggered);
        return ActionResult.notHere;
    }

    ActionResult hostDamage(EntityRef target, uint amount)
    {
        import dmangos.world.spellcast : nonMeleeDamageLog;

        if (amount == 0)
            return ActionResult.ok;
        const spellId = hostSpellId();
        if (target.guid == player.guid)
        {
            // Its own spell's cost in health (Life Tap): no fight comes of it.
            const health = player.values.get!UNIT_FIELD_HEALTH;
            if (health == 0)
                return ActionResult.notAllowed;
            player.values.set!UNIT_FIELD_HEALTH(amount >= health ? 0 : health - amount);
            map.sendToWatchers(this, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(target: player.guid, attacker: player.guid,
                spellId, amount, 0, 0, 0, false, 0, false), true);
            flushPlayerChanges();
            if (amount >= health)
                playerDied(false);
            return ActionResult.ok;
        }
        if (auto other = sessionHere(target))
        {
            {
                import dmangos.world.unit : Blow, dealDamage;

                dealDamage(unit, other.unit, amount, Blow.spell());
            }
            return ActionResult.ok;
        }
        if (auto creature = map.creatureAt(target.guid))
        {
            if (scriptSpell is null)
                return ActionResult.failed;
            spellDamage(scriptSpell, creature, amount, scriptSpell.casting.school);
            return ActionResult.ok;
        }
        return ActionResult.notHere;
    }

    ActionResult hostEnergize(EntityRef target, ubyte power, int amount)
    {
        import dmangos.world.spellcast : energizeLog;
        import dmangos.world.defines : Power;

        auto who = sessionHere(target);
        if (who is null)
            return ActionResult.notHere;
        if (power > Power.happiness)
            return ActionResult.failed;
        who.player.modifyPower(cast(Power) power, amount);
        if (amount > 0)
            map.sendToWatchers(this, Opcode.SMSG_SPELLENERGIZELOG, energizeLog(target.guid, player.guid, hostSpellId(),
                cast(Power) power, amount), true);
        who.flushPlayerChanges();
        return ActionResult.ok;
    }

    uint hostHealth(EntityRef who)
    {
        if (auto other = sessionHere(who))
            return other.player.values.get!UNIT_FIELD_HEALTH;
        if (auto creature = map.creatureAt(who.guid))
            return creature.values.get!UNIT_FIELD_HEALTH;
        return 0;
    }

    void hostQuestEvent(EntityRef who, uint quest)
    {
        if (auto other = sessionHere(who))
            other.areaExploredOrEventHappens(quest);
    }

    void hostKillCredit(EntityRef who, uint entry)
    {
        if (auto other = sessionHere(who))
            other.scriptKillCredit(entry, 0);
    }

    EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack)
    {
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.movement : Position;

        auto summoned = context.summonCreature(map, entry, Position(at.x, at.y, at.z, at.orientation),
            despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, player.guid);
        if (summoned is null)
            return EntityRef.init;
        if (attack)
            if (auto victim = sessionHere(attack))
                summoned.ai.attackedBy(victim.unit, map);
        return EntityRef(summoned.guid);
    }

    ActionResult hostSignalCreature(EntityRef to, uint id, int value)
    {
        return context.signalCreature(map, EntityRef(player.guid), to, id, value);
    }

    QuestProgress hostQuestStatusOf(EntityRef who, uint quest)
    {
        if (auto other = sessionHere(who))
            return other.questStatusFor(quest);
        return QuestProgress.none;
    }

    EntityRef hostCreatureNear(uint entry, Location at, float range)
    {
        import dmangos.world.movement : Position;

        foreach (creature; map.creaturesNear(Position(at.x, at.y, at.z), range))
            if (creature.spawn.entry == entry && creature.alive)
                return EntityRef(creature.guid);
        return EntityRef.init;
    }

    ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent)
    {
        if (auto c = map.creatureAt(creature.guid))
        {
            c.ai.modifyThreatPercent(target.guid, percent);
            return ActionResult.ok;
        }
        return ActionResult.notHere;
    }

    void hostSignalDungeon(uint id, int value)
    {
        if (instanceId_)
            context.signalDungeon(instanceId_, EntityRef(player.guid), id, value);
    }

    void hostLog(string text)
    {
        import dmangos.log : info;

        info!"script (%s, spell %s): %s"(player.data.name, hostSpellId(), text);
    }
}
