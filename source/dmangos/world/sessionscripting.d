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
    import dmangos.script.api : ActionResult, AreaTriggerContext, AreaTriggerHost, EventContext, EventStarted, EffectHit, EntityRef, Location,
        QuestProgress, SpellContext, SpellHost, TriggerEntered;
    import dmangos.script.registry : ScriptHandle;
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
        const outer = scriptSpell; // (a script's cast runs scripts of its own)
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
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
        const outer = scriptSpell; // (a script's cast runs scripts of its own)
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
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
        const outer = scriptSpell; // (a script's cast runs scripts of its own)
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, AuraTicked(EntityRef(player.guid), EntityRef(target), cast(ubyte) i, tick,
            ticks, amount));
        return c.amountChanged ? c.amount : amount;
    }

    /// This player cast `spell` at `target` (before its hits are rolled): the spell's script hears of it (`OnCast`).
    package void spellCastScript(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.script.api : SpellCast;

        auto handle = context.spellScript(spell.id);
        if (!handle)
            return;
        const outer = scriptSpell; // (a script's cast runs scripts of its own)
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, SpellCast(EntityRef(player.guid), EntityRef(target)));
    }

    /// This player's `spell` reached `target`, or `missed` it: the spell's script hears of it (`OnHit`).
    package void spellLandedScript(const(SpellInfo)* spell, ulong target, bool missed)
    {
        import dmangos.script.api : SpellLanded;

        auto handle = context.spellScript(spell.id);
        if (!handle)
            return;
        const outer = scriptSpell; // (a script's cast runs scripts of its own)
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        auto c = SpellContext(scriptHost);
        context.scripts.raise(handle, c, SpellLanded(EntityRef(player.guid), EntityRef(target), missed));
    }

    /// Scripted event `event` (started by `source`, at `target`) reached its script, around this player: true if the
    /// script consumed it.
    package bool eventScript(ScriptHandle handle, uint event, ulong source, ulong target)
    {
        auto c = EventContext(scriptHost);
        context.scripts.raise(handle, c, EventStarted(event, EntityRef(source), EntityRef(target)));
        return c.consumed;
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

    // Kalimdor scripts:

    /// A script gives this player `count` of `entry`: onto stacks first, then free slots, as many as
    /// fit (as a quest's reward is given). How many it got.
    public uint scriptGiveItem(uint entry, uint count)
    {
        import dmangos.world.inventory : InventoryResult, ItemPosCount;
        import dmangos.world.defines : nullBag, nullSlot;

        if (player is null || count == 0)
            return 0;
        ItemPosCount[] dest;
        uint noSpace;
        if (player.inventory.canStoreNew(nullBag, nullSlot, dest, entry, count, &noSpace) != InventoryResult.ok)
            count -= noSpace;
        if (count == 0 || dest.length == 0)
            return 0;
        auto made = player.inventory.storeNew(dest, entry);
        if (made is null)
            return 0;
        sendNewItem(made, count, true, false);
        flushInventory();
        return count;
    }

    /// Where this player stands with `quest` (`UnitRef.questStatusOf`).
    public QuestProgress questStatusOf(uint quest)
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
        bool hostHasItem(EntityRef who, uint item) { return this.outer.hostHasItem(who, item); }
        int hostAskDungeon(uint id) { return this.outer.hostAskDungeon(id); }
        void hostLog(string text) { this.outer.hostLog(text); }
        // Instance round 2:
        ActionResult hostTeleportPlayer(EntityRef who, Location at) { return this.outer.hostTeleportPlayer(who, at); }
        bool hostHasAura(EntityRef who, uint spell) { return this.outer.hostHasAura(who, spell); }
        ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent) { return this.outer.hostModifyThreat(creature, target, percent); }
        // Class spells (`dmangos.world.classspells`):
        ActionResult hostCastCustom(EntityRef caster, uint spellId, EntityRef target, int[3] values, ubyte which) { return this.outer.hostCastCustom(caster, spellId, target, values, which); }
        int hostPower(EntityRef who, ubyte power) { return this.outer.hostPower(who, power); }
        ActionResult hostSetPower(EntityRef who, ubyte power, int value) { return this.outer.hostSetPower(who, power, value); }
        float hostDamageMultiplier(ubyte effect) { return scriptSpell is null || effect > 2 ? 1 : scriptSpell.casting.dmgMultiplier[effect]; }
        uint hostResetCooldowns(EntityRef who, uint family, uint schoolMask, uint except) { return this.outer.hostResetCooldowns(who, family, schoolMask, except); }
        int hostEffectValue(ubyte effect)
        {
            import dmangos.world.spellcast : effectValue;
            import std.random : uniform01;

            return scriptSpell is null || effect > 2 ? 0
                : effectValue(*scriptSpell, effect, player.data.level, uniform01(map.random));
        }
        ActionResult hostCastHighestRank(EntityRef who, uint firstRank, bool resetCooldown) { return this.outer.hostCastHighestRank(who, firstRank, resetCooldown); }
        int hostAffectingAuraTotal(EntityRef who, ubyte auraType) { return scriptSpell is null ? 0 : this.outer.affectingAuraTotal(who, scriptSpell, auraType); }
        int hostSpellPower(EntityRef who) { return scriptSpell is null || who.guid != player.guid ? 0 : cast(int) spellDamageBonus(scriptSpell, scriptSpell.casting.school); }
        // Eastern Kingdoms scripts:
        void hostKillCreditAt(EntityRef who, uint entry) { this.outer.hostKillCredit(who, entry); }
        ActionResult hostSayAt(EntityRef speaker, int entry, EntityRef target)
        {
            auto c = map is null ? null : map.creatureAt(speaker.guid);
            if (c is null || c.ai is null)
                return ActionResult.notHere;
            return c.ai.sayScriptFor(map, entry, target);
        }

        // Open-world round 2:

        bool hostLocationOf(EntityRef who, out Location at)
        {
            import dmangos.world.movement : Position;

            Position p;
            if (map is null || !map.positionOf(who.guid, p))
                return false;
            at = Location(p.x, p.y, p.z, p.orientation);
            return true;
        }

        uint hostHealthPercentOf(EntityRef who)
        {
            if (map is null)
                return uint.max;
            auto unit = map.unit(who.guid);
            return unit ? unit.healthPercent : uint.max;
        }

        uint hostRespawnObjectsNear(uint entry, Location at, float range, uint seconds)
        {
            return map is null ? 0 : context.respawnObjectsNear(map, entry, at, range, seconds);
        }

        ActionResult hostAiEvent(EntityRef creature, uint type, EntityRef invoker)
        {
            auto c = map is null ? null : map.creatureAt(creature.guid);
            if (c is null || c.ai is null || !c.alive)
                return ActionResult.notHere;
            if (c.ai.inCombat)
                return ActionResult.notAllowed;
            c.ai.aiEventFrom(type, c, invoker.guid, map);
            return ActionResult.ok;
        }

        uint hostCompanionEntry(EntityRef who)
        {
            import dmangos.world.creature : Creature;

            auto c = sessionHere(who);
            if (c is null || !c.companion || map is null)
                return 0;
            auto pet = cast(Creature) map.findObject(c.companion);
            return pet is null ? 0 : pet.spawn.entry;
        }

        size_t hostCreaturesNear(Location at, uint entry, float range, EntityRef[] into)
        {
            import dmangos.world.movement : Position;

            size_t n;
            if (map !is null)
                foreach (c; map.creaturesNear(Position(at.x, at.y, at.z), range))
                    if (c.alive && (entry == 0 || c.spawn.entry == entry) && n < into.length)
                        into[n++] = EntityRef(c.guid);
            return n;
        }

        void hostFlagForPvP(EntityRef who)
        {
            if (auto other = sessionHere(who))
            {
                other.updatePvP(true);
                other.flushPlayerChanges();
            }
        }
    }

    /// Open-world round 2: a creature's script opens its goods (or its training) for this player.
    public void scriptOpenWindow(ulong npc, bool training)
    {
        if (training)
            sendTrainerList(npc);
        else
            sendListInventory(npc);
    }

    /// Open-world round 2: this player casts `spell` at `target` (itself if nothing) for a creature's script.
    public ActionResult scriptCast(uint spell, ulong target, bool triggered)
    {
        if (player is null)
            return ActionResult.notHere;
        return hostCastFrom(EntityRef(player.guid), spell, EntityRef(target), triggered);
    }

    /// Open-world round 2: a script takes `copper` of this player's money; false (nothing taken) if it has less.
    public bool scriptTakeMoney(uint copper)
    {
        import dmangos.world.updatefields : PLAYER_FIELD_COINAGE;

        if (player is null)
            return false;
        const money = player.values.get!PLAYER_FIELD_COINAGE;
        if (money < copper)
            return false;
        player.values.set!PLAYER_FIELD_COINAGE(money - copper);
        flushPlayerChanges();
        return true;
    }

    /// Open-world round 2: whether this player wears an item that needs `spell` (`item_template.requiredspell`).
    public bool scriptWearsItemNeeding(uint spell)
    {
        import dmangos.world.defines : equipmentSlotEnd;

        if (player is null || spell == 0)
            return false;
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            if (const item = player.inventory.equipped(slot))
                if (item.proto.requiredSpell == spell)
                    return true;
        return false;
    }

    /**
     * Open-world round 2: this player forgets `spell` (a specialization) and the recipes it learned from
     * the items that need it (a plan's or a pattern's learning spell teaches the recipe).
     */
    public void scriptUnlearnSpecialization(uint spell)
    {
        import dmangos.world.spellids : SpellEffect;

        if (player is null)
            return;
        unlearn(spell);
        foreach (ref item; context.data.items)
        {
            if (item.requiredSpell != spell)
                continue;
            foreach (ref use; item.details.spells)
                if (const teaching = use.id ? context.data.spells.spell(use.id) : null)
                    foreach (i; 0 .. 3)
                        if (teaching.effect[i] == SpellEffect.learnSpell && teaching.triggerSpell[i])
                            unlearn(teaching.triggerSpell[i]);
        }
    }

    /**
     * Open-world round 2: this player uses item `entry` (at `target`): the item's script hears of it; true
     * if it refused the use (the item's spell is not cast).
     */
    package bool itemScript(uint entry, ulong target)
    {
        import dmangos.script.api : ItemContext, ItemUsed;

        auto handle = context.itemScript(entry);
        if (!handle)
            return false;
        auto c = ItemContext(scriptHost);
        context.scripts.raise(handle, c, ItemUsed(EntityRef(player.guid), entry, EntityRef(target)));
        return c.consumed;
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
            // Its own spell's cost in health (Life Tap's: a power cost of health, as CMaNGOS has it, so no damage log
            // and no fight comes of it).
            const health = player.values.get!UNIT_FIELD_HEALTH;
            if (health == 0)
                return ActionResult.notAllowed;
            player.values.set!UNIT_FIELD_HEALTH(amount >= health ? 0 : health - amount);
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

    /// See `AreaTriggerContext.hasItem`.
    bool hostHasItem(EntityRef who, uint item)
    {
        if (auto other = sessionHere(who))
            return other.player.inventory.count(item, false) > 0;
        return false;
    }

    QuestProgress hostQuestStatusOf(EntityRef who, uint quest)
    {
        if (auto other = sessionHere(who))
            return other.questStatusOf(quest);
        return QuestProgress.none;
    }

    // Instance round 2:

    /// See `AreaTriggerContext.teleport`.
    ActionResult hostTeleportPlayer(EntityRef who, Location at)
    {
        import dmangos.world.movement : Position;
        import dmangos.world.unit : UnitKind;

        if (map is null)
            return ActionResult.notHere;
        auto unit = map.unit(who.guid);
        if (unit.kind != UnitKind.player)
            return ActionResult.notHere;
        unit.session.spellTeleport(map.id, Position(at.x, at.y, at.z, at.orientation));
        return ActionResult.ok;
    }

    /// See `AreaTriggerContext.hasAura`.
    bool hostHasAura(EntityRef who, uint spell)
    {
        if (map is null)
            return false;
        auto unit = map.unit(who.guid);
        return unit && unit.hasAuraOf(spell);
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
        else if (map !is null) // open-world round 2: the continent's script
            context.signalWorld(map.id, EntityRef(player.guid), id, value);
    }

    /// Raid scripts: see `AreaTriggerHost.hostAskDungeon`.
    int hostAskDungeon(uint id)
    {
        return instanceId_ ? context.askDungeon(instanceId_, EntityRef(player.guid), id) : 0;
    }

    void hostLog(string text)
    {
        import dmangos.log : info;

        info!"script (%s, spell %s): %s"(player.data.name, hostSpellId(), text);
    }
}
