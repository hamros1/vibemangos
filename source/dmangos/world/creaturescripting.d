/**
 * A creature's script (docs/SCRIPTING.md): `CreatureAI` is its host (`CreatureHost`), raises its
 * events at the moments of the fight, ticks its schedules, and carries its state when the creature
 * moves to another node. Every action a script asks for goes through what the AI and its spells
 * already do, with their rules. Mixed into `dmangos.world.creatureai.CreatureAI`.
 */
module dmangos.world.creaturescripting;

/// See the module documentation.
mixin template CreatureScripting()
{
    import dmangos.world.map : Map;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.script.api;
    import dmangos.script.registry : ScriptHandle, ScriptRuntime;
    import dmangos.world.eventai : castTriggered;
    import dmangos.script.api : MenuOption, MovementDone, QuestProgress, SpellHost, Waypoint;
    import dmangos.world.spells : SpellInfo;

    private
    {
        ScriptRuntime scripts_;   // the server's scripts; null if this creature has none
        ScriptHandle behaviour;   // its script's state
        bool spawnRaised;         // `Spawned` was raised
    }

    private enum BehaviourFlags : ubyte
    {
        spawned = 1,
        noChase = 2,
        noMelee = 4,
        forceMelee = 8,
        reactionOverride = 16,
        held = 128, /// a second byte follows: `HeldFlags`
    }
    private enum uint reactionShift = 5, reactionMask = 3;

    /// What its script holds it to (`scriptImmobilized`, `scriptDeathPrevention`), in the byte after the flags.
    private enum HeldFlags : ubyte
    {
        rooted = 1,
        rootedForFight = 2,
        deathPrevention = 4,
    }

    /// Its script: `name` of `runtime` (no script if none serves it).
    void setBehaviour(ScriptRuntime runtime, string name)
    {
        import dmangos.script.registry : ScriptKind;

        if (runtime is null || !runtime.serves(ScriptKind.creature, name))
            return;
        scripts_ = runtime;
        behaviour = runtime.create(ScriptKind.creature, name);
    }

    /// Whether it has a script.
    @property bool scripted() const
    {
        return cast(bool) behaviour;
    }

    /// The `ScriptName` of its script; null if it has none.
    @property string behaviourName() const
    {
        return scripts_ is null ? null : scripts_.nameOf(behaviour);
    }

    /// It has left the world for good (gone, or moved to another node): its script's state goes.
    void releaseBehaviour()
    {
        if (persistentAreas_.length)
        {
            import dmangos.world.spellareas : endPersistentAreas;

            auto caster = spellCaster();
            endPersistentAreas(caster, persistentAreas_);
        }
        if (scripts_ !is null)
            scripts_.destroy(behaviour);
    }

    /// Its script's state, for the node it moves to (`Creature.saveState`).
    void saveBehaviour(ref ByteWriter w)
    {
        ByteWriter state;
        if (scripts_ !is null)
            scripts_.save(behaviour, state);
        // The existing spawn byte was 0 or 1 on older checkpoints.
        ubyte flags = spawnRaised ? BehaviourFlags.spawned : 0;
        if (spawnRaised || !behaviour)
        {
            if (!combatMovement_)
                flags |= BehaviourFlags.noChase;
            const defaultMelee = !(me.template_.staticFlags1 & staticFlagNoMeleeFlee);
            if (meleeEnabled != defaultMelee)
                flags |= meleeEnabled ? BehaviourFlags.forceMelee : BehaviourFlags.noMelee;
            if (react != defaultReaction)
                flags |= cast(ubyte)(BehaviourFlags.reactionOverride | (cast(uint) react << reactionShift));
        }
        // Older checkpoints have no second byte (the flags' top bit clear): nothing held.
        ubyte held;
        if (me.scriptRooted)
            held |= HeldFlags.rooted;
        if (rootedForFight)
            held |= HeldFlags.rootedForFight;
        if (deathPrevention)
            held |= HeldFlags.deathPrevention;
        if (held)
            flags |= BehaviourFlags.held;
        w.put(flags);
        if (held)
            w.put(held);
        w.put(cast(uint) state.length);
        w.putBytes(state.data);
    }

    /// Reads what `saveBehaviour` wrote; a state of another layout leaves the script fresh.
    void loadBehaviour(ref ByteReader r)
    {
        const flags = r.read!ubyte;
        spawnRaised = (flags & BehaviourFlags.spawned) != 0;
        combatMovement_ = !(flags & BehaviourFlags.noChase);
        if (flags & (BehaviourFlags.noMelee | BehaviourFlags.forceMelee))
            meleeEnabled = (flags & BehaviourFlags.forceMelee) != 0;
        if (flags & BehaviourFlags.reactionOverride)
        {
            const savedReaction = (flags >> reactionShift) & reactionMask;
            if (savedReaction <= typeof(react).max)
                react = cast(typeof(react)) savedReaction;
        }
        if (flags & BehaviourFlags.held)
        {
            const held = r.read!ubyte;
            me.scriptRooted = (held & HeldFlags.rooted) != 0;
            rootedForFight = (held & HeldFlags.rootedForFight) != 0;
            deathPrevention = (held & HeldFlags.deathPrevention) != 0;
        }
        auto state = ByteReader(r.readBytes(r.read!uint));
        if (scripts_ !is null && state.remaining && !scripts_.load(behaviour, state))
        {
            import dmangos.log : warning;

            warning!"script %s of creature %s: its state from the last node has another layout; it starts afresh"(
                behaviourName, me.spawn.guid);
        }
    }

    /// Raises `event` for its script (after `Spawned`, the first time).
    package void raiseScript(E)(const E event)
    {
        if (!behaviour)
            return;
        auto context = CreatureContext(this);
        if (!spawnRaised)
        {
            spawnRaised = true;
            scripts_.raise(behaviour, context, Spawned());
        }
        static if (!is(E == Spawned))
            scripts_.raise(behaviour, context, event);
        checkpointQuestActor(is(E == MovementDone) || is(E == Died) || is(E == SummonedDied));
    }

    /// Its script's schedules, `diff` milliseconds on.
    private void tickBehaviour(int diff)
    {
        if (!behaviour)
            return;
        auto context = CreatureContext(this);
        if (!spawnRaised)
        {
            spawnRaised = true;
            scripts_.raise(behaviour, context, Spawned());
        }
        scripts_.tick(behaviour, context, diff);
        checkpointQuestActor(false);
    }

    /// Whether its script has steps pending: it must tick even out of combat.
    private @property bool behaviourBusy() const
    {
        return behaviour && (cast() scripts_).busy(behaviour); // reads only
    }

    package ulong questActorPlayer() const
    {
        return behaviour ? (cast() scripts_).questActorPlayer(behaviour) : 0;
    }

    private void checkpointQuestActor(bool immediate)
    {

        if (auto map = world_)
            if (map.world !is null)
                map.world.questActorChanged(map, me, questActorPlayer(), immediate);
    }

    /// Raises `event` from outside its own moments (a player's gossip, a quest): its world as given.
    /// Whether the script consumed it (`CreatureContext.consume`).
    bool raiseFrom(E)(Map world, const E event)
    {
        if (!behaviour)
            return false;
        if (world !is null)
            world_ = world;
        auto context = CreatureContext(this);
        if (!spawnRaised)
        {
            spawnRaised = true;
            scripts_.raise(behaviour, context, Spawned());
        }
        scripts_.raise(behaviour, context, event);
        checkpointQuestActor(true);
        if (world_ !is null)
            world_.wake(me.guid);
        return context.consumed;
    }

    /// Its `moveTo` arrived.
    private void movementArrived(uint point)
    {
        raiseScript(MovementDone(point));
    }

    package void scriptPointArrived(uint point, ulong orderedBy)
    {
        movementArrived(point);
        if (orderedBy)
            tellArrival(orderedBy, point);
    }

    /// A `Signal` from another script.
    void signalled(EntityRef from, uint id, int value, Map world)
    {
        if (world !is null)
            world_ = world;
        raiseScript(Signal(from, id, value));
        if (world_ !is null)
            world_.wake(me.guid);
    }

    // -----------------------------------------------------------------------
    // `CreatureHost`
    // -----------------------------------------------------------------------

    EntityRef hostSelf()
    {
        return EntityRef(me.guid);
    }

    EntityRef hostVictim()
    {
        return EntityRef(victim);
    }

    uint hostHealthPercent()
    {
        return healthPercent();
    }

    bool hostInCombat()
    {
        return inCombat_;
    }

    Location hostLocation()
    {
        const p = me.position;
        return Location(p.x, p.y, p.z, p.orientation);
    }

    uint hostHealthPercentOf(EntityRef who)
    {
        if (world_ is null)
            return uint.max;
        if (who.guid == me.guid)
            return healthPercent();
        if (auto other = world_.creatureAt(who.guid))
            return other.ai.healthPercent();
        if (auto player = world_.unit(who.guid))
            return player.healthPercent();
        return uint.max;
    }

    uint hostHealthOf(EntityRef who)
    {
        return world_ is null ? 0 : world_.unit(who.guid).health;
    }

    bool hostInMeleeReach(EntityRef who)
    {
        if (world_ is null)
            return false;
        auto target = world_.unit(who.guid);
        return target && target.alive && !target.untouchable && canReachWithMelee(me.fighter, target.fighter);
    }

    ActionResult hostCast(uint spellId, EntityRef target, bool triggered)
    {
        if (lore is null || world_ is null)
            return ActionResult.notHere;
        const spell = lore.spellInfo(spellId);
        if (spell is null)
            return ActionResult.failed;
        if (target.guid != me.guid && world_.creatureAt(target.guid) is null && !world_.unit(target.guid))
            return ActionResult.notHere;
        return castSpell(spell, target.guid, triggered ? castTriggered : 0) ? ActionResult.ok : ActionResult.notAllowed;
    }

    ActionResult hostSay(int entry, EntityRef target)
    {
        if (lore is null || world_ is null)
            return ActionResult.notHere;
        const text = lore.scriptText(entry);
        if (text is null)
            return ActionResult.failed;
        speak(text, target.guid);
        if (const sound = lore.scriptTextSound(entry))
            scriptSound(sound);
        return ActionResult.ok;
    }

    void hostEquip(uint mainHand, uint offHand, uint ranged)
    {
        if (lore is null)
            return;
        foreach (slot, entry; [mainHand, offHand, ranged])
            me.setVirtualItem(slot, lore.virtualItem(entry));
        if (world_ !is null)
            world_.flushCreature(me);
    }

    void hostRestoreEquipment()
    {
        foreach (slot; 0 .. 3)
            me.setVirtualItem(slot, me.templateEquipment[slot]);
        if (world_ !is null)
            world_.flushCreature(me);
    }

    void hostStandState(StandState state)
    {
        me.values.setByte!UNIT_FIELD_BYTES_1(0, cast(ubyte) state);
        if (world_ !is null)
            world_.flushCreature(me);
    }

    void hostCombatMovement(bool on)
    {
        if (world_ !is null)
            scriptCombatMovement(on);
        else
            combatMovement_ = on;
    }

    void hostMelee(bool on)
    {
        if (world_ !is null)
            scriptMelee(on);
        else
            meleeEnabled = on;
    }

    EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack)
    {
        import dmangos.world.creature : TempSpawnType;

        if (lore is null || world_ is null)
            return EntityRef.init;
        auto summoned = lore.summon(world_, entry, Position(at.x, at.y, at.z, at.orientation),
            despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, me.guid);
        if (summoned is null)
            return EntityRef.init;
        if (attack)
            if (auto victim = world_.unit(attack.guid))
                summoned.ai.attackStart(victim, world_);
        return EntityRef(summoned.guid);
    }

    void hostDespawn(uint delayMs)
    {
        scriptDespawn(delayMs);
    }

    ActionResult hostSignal(EntityRef to, uint id, int value)
    {
        if (world_ is null || lore is null)
            return ActionResult.notHere;
        return lore.signalCreature(world_, EntityRef(me.guid), to, id, value);
    }

    // -----------------------------------------------------------------------
    // Its own spells' scripts (`SpellHost`, through `castHost`)
    // -----------------------------------------------------------------------

    private const(SpellInfo)* scriptSpell; // its spell whose script is running

    /// A dummy or script effect `i` of its spell hit `target`: the spell's script hears of it.
    package void spellEffectScript(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        import dmangos.script.api : EffectHit, SpellContext;

        if (lore is null)
            return;
        auto handle = lore.spellScript(spell.id);
        if (!handle)
            return;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = null;
        auto c = SpellContext(castHost);
        lore.scriptRuntime.raise(handle, c, EffectHit(EntityRef(me.guid), EntityRef(target), cast(ubyte) i, value));
    }

    /// A direct damage effect `i` of its `spell` is about to strike `target` for `value`: what its script makes of
    /// the amount (`EffectDamage`), or `value` as it is.
    package int effectDamageScript(const(SpellInfo)* spell, size_t i, ulong target, int value)
    {
        import dmangos.script.api : EffectDamage, SpellContext;

        auto handle = lore is null ? ScriptHandle.init : lore.spellScript(spell.id);
        if (!handle)
            return value;
        auto outer = scriptSpell;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        auto c = SpellContext(castHost);
        lore.scriptRuntime.raise(handle, c, EffectDamage(EntityRef(me.guid), EntityRef(target), cast(ubyte) i, value));
        return c.amountChanged ? c.amount : value;
    }

    /// Spell scripts of items, quests and the world: `event` (an aura's) reaches `spell`'s script, if it has one,
    /// with this creature its host, acting on `world`.
    package void spellScriptEvent(E)(const(SpellInfo)* spell, const auto ref E event, Map world)
    {
        import dmangos.script.api : SpellContext;

        if (lore is null || world is null)
            return;
        auto handle = lore.spellScript(spell.id);
        if (!handle)
            return;
        world_ = world;
        auto outer = scriptSpell;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        auto c = SpellContext(castHost);
        lore.scriptRuntime.raise(handle, c, event);
    }

    /// The targets of effect `i` of its spell its script keeps (`TargetChecked`): all if the spell has none.
    package ulong[] scriptPicked(const(SpellInfo)* spell, size_t i, ulong[] targets)
    {
        import dmangos.script.api : SpellContext, TargetChecked;

        auto handle = lore is null ? ScriptHandle.init : lore.spellScript(spell.id);
        if (!handle || targets.length == 0)
            return targets;
        auto outer = scriptSpell;
        scriptSpell = spell;
        scope (exit)
            scriptSpell = outer;
        ulong[] kept;
        foreach (guid; targets)
        {
            auto c = SpellContext(castHost);
            lore.scriptRuntime.raise(handle, c, TargetChecked(EntityRef(me.guid), EntityRef(guid), cast(ubyte) i));
            if (!c.excluded)
                kept ~= guid;
        }
        return kept;
    }

    private final class CastHost : SpellHost
    {
        uint hostSpellId() { return scriptSpell is null ? 0 : scriptSpell.id; }
        ActionResult hostCastFrom(EntityRef caster, uint spellId, EntityRef target, bool triggered)
        {
            if (caster.guid == me.guid)
                return hostCast(spellId, target, triggered);
            if (world_ !is null)
                if (auto other = world_.creatureAt(caster.guid))
                    return other.ai.castFor(world_, spellId, target.guid, triggered);
            return ActionResult.notHere;
        }
        ActionResult hostDamage(EntityRef target, uint amount)
        {
            if (world_ is null || scriptSpell is null || !world_.unit(target.guid))
                return ActionResult.notHere;
            spellDamageTo(scriptSpell, target.guid, amount, scriptSpell.casting.school);
            return ActionResult.ok;
        }
        ActionResult hostEnergize(EntityRef, ubyte, int) { return ActionResult.failed; }
        uint hostHealth(EntityRef who)
        {
            return world_ is null ? 0 : world_.unit(who.guid).health;
        }
        void hostQuestEvent(EntityRef player, uint quest) { this.outer.hostQuestEvent(player, quest); }
        void hostKillCredit(EntityRef player, uint entry)
        {
            if (world_ !is null)
                if (auto other = world_.unit(player.guid))
                    other.killCreditFrom(entry, me.guid);
        }
        EntityRef hostSummonAt(uint entry, Location at, uint despawnMs, EntityRef attack)
        {
            return hostSummon(entry, at, despawnMs, attack);
        }
        Location hostLocationOf(EntityRef who)
        {
            Position at;
            if (world_ is null || !world_.positionOf(who.guid, at))
                return Location.init;
            return Location(at.x, at.y, at.z, at.orientation);
        }
        ActionResult hostPlaceTrap(uint entry, Location at, uint seconds, uint fuseMs)
        {
            if (lore is null || world_ is null)
                return ActionResult.notHere;
            return lore.remoteSpells.placeFusedTrap(world_, entry, Position(at.x, at.y, at.z, at.orientation), seconds, fuseMs)
                ? ActionResult.ok : ActionResult.failed;
        }
        ActionResult hostSignalCreature(EntityRef to, uint id, int value) { return hostSignal(to, id, value); }
        void hostLog(string text) { this.outer.hostLog(text); }
        ActionResult hostModifyThreat(EntityRef creature, EntityRef target, int percent)
        {
            if (creature.guid == me.guid)
            {
                modifyThreatPercent(target.guid, percent);
                return ActionResult.ok;
            }
            if (world_ !is null)
                if (auto other = world_.creatureAt(creature.guid))
                {
                    other.ai.modifyThreatPercent(target.guid, percent);
                    return ActionResult.ok;
                }
            return ActionResult.notHere;
        }
        ActionResult hostCastCustom(EntityRef caster, uint spellId, EntityRef target, int[3] values, ubyte which)
        {
            import dmangos.world.classspells : CustomValues;

            if (world_ is null || lore is null || caster.guid != me.guid || !world_.unit(target.guid))
                return ActionResult.notHere;
            return castSpell(lore.spellInfo(spellId), target.guid, castTriggered, CustomValues(values, which))
                ? ActionResult.ok : ActionResult.notAllowed;
        }
        ActionResult hostSetPower(EntityRef, ubyte, int) { return ActionResult.failed; }
        float hostDamageMultiplier(ubyte effect) { return scriptSpell is null || effect > 2 ? 1 : scriptSpell.casting.dmgMultiplier[effect]; }
        uint hostResetCooldowns(EntityRef, uint, uint, uint) { return 0; }
        int hostEffectValue(ubyte effect)
        {
            import dmangos.world.spellcast : effectValue;

            return scriptSpell is null || effect > 2 ? 0
                : effectValue(*scriptSpell, effect, me.values.get!UNIT_FIELD_LEVEL, 0.5f);
        }
        int hostAffectingAuraTotal(EntityRef, ubyte) { return 0; }
        int hostSpellPower(EntityRef) { return 0; }
        ActionResult hostCastHighestRank(EntityRef, uint, bool) { return ActionResult.failed; }

        // Spell scripts of items, quests and the world (`dmangos.world.spellscripting`):
        private Map scriptWorld() { return world_; }
        import dmangos.world.spellscripting : SpellScriptActions;
        mixin SpellScriptActions;
    }

    private CastHost castHost_;

    private @property CastHost castHost()
    {
        if (castHost_ is null)
            castHost_ = new CastHost;
        return castHost_;
    }

    /// A spell script acts on it (`dmangos.world.spellscripting`): through its own script's host, on `world`.
    CreatureHost hostIn(Map world)
    {
        world_ = world;
        return this;
    }

    /// A spell script has it cast `spellId` at `target`.
    ActionResult castFor(Map world, uint spellId, ulong target, bool triggered)
    {
        world_ = world;
        return hostCast(spellId, EntityRef(target), triggered);
    }

    QuestProgress hostQuestStatus(EntityRef player, uint quest)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                return other.questStatusOf(quest);
        return QuestProgress.none;
    }

    ActionResult hostSayBroadcast(EntityRef speaker, uint text, EntityRef target)
    {
        if (lore is null || world_ is null || lore.broadcastText(text) is null)
            return ActionResult.failed;
        if (speaker.guid == me.guid)
        {
            scriptText(text, target.guid);
            return ActionResult.ok;
        }
        auto other = world_.creatureAt(speaker.guid);
        if (other is null)
            return ActionResult.notHere;
        other.ai.sayFor(world_, text, target.guid);
        return ActionResult.ok;
    }

    /// Another creature's script has it say `broadcast_text` `text`.
    void sayFor(Map world, uint text, ulong target)
    {
        world_ = world;
        scriptText(text, target);
    }

    void hostEmote(uint emote)
    {
        if (world_ !is null)
            scriptEmote(emote);
    }

    EntityRef hostCreatureNearby(uint entry, float range)
    {
        if (world_ is null)
            return EntityRef.init;
        foreach (other; world_.creaturesNear(me.position, range))
            if (other !is me && other.spawn.entry == entry && other.alive)
                return EntityRef(other.guid);
        return EntityRef.init;
    }

    ActionResult hostDespawnOther(EntityRef creature, uint delayMs)
    {
        if (creature.guid == me.guid)
        {
            scriptDespawn(delayMs);
            return ActionResult.ok;
        }
        auto other = world_ is null ? null : world_.creatureAt(creature.guid);
        if (other is null)
            return ActionResult.notHere;
        other.ai.despawnFor(world_, delayMs);
        return ActionResult.ok;
    }

    /// Another creature's script has it go in `delayMs`.
    void despawnFor(Map world, uint delayMs)
    {
        world_ = world;
        scriptDespawn(delayMs);
        world.wake(me.guid);
    }

    EntityRef hostRandomTarget()
    {
        import std.random : uniform;

        if (threat.length == 0 || world_ is null)
            return EntityRef.init;
        const who = threat.keys;
        return EntityRef(who[uniform(0, who.length, world_.random)]);
    }

    void hostSendGossip(EntityRef player, uint textId, const(MenuOption)[] options, bool withQuests)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.showScriptGossip(me.guid, textId, options, withQuests);
    }

    void hostSignalDungeon(uint id, int value)
    {
        if (lore !is null && me.instanceId)
            lore.signalDungeon(me.instanceId, EntityRef(me.guid), id, value);
        else if (lore !is null && world_ !is null) // its continent's script
            lore.signalWorldMap(world_, EntityRef(me.guid), id, value);
    }

    void hostLog(string text)
    {
        import dmangos.log : info;

        info!"script %s (%s %s): %s"(behaviourName, me.template_.name, me.spawn.guid, text);
    }

    void hostMoveTo(Location at, uint point, bool run)
    {
        moveOrdered(at, point, run, 0);
    }

    /// `hostMoveTo`, for itself or for creature `orderedBy`'s script, which hears of the arrival.
    private void moveOrdered(Location at, uint point, bool run, ulong orderedBy)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : PointMovement;

        auto move = new PointMovement(Vector3(at.x, at.y, at.z), at.orientation, !run, null);
        move.notifyScript = true;
        move.arrivalPoint = point;
        move.orderedBy = orderedBy;
        if (inCombat_ || evadingHome)
        {
            outOfCombat = move; // where it goes once home from the fight
            return;
        }
        me.generator = move;
        if (world_ !is null)
        {
            move.initialize(me, world_);
            world_.wake(me.guid);
        }
    }

    bool hostMoving()
    {
        import dmangos.world.motion : PointMovement;

        return !me.spline.finalized || cast(PointMovement) me.generator !is null
            || cast(PointMovement) outOfCombat !is null;
    }

    bool hostWaypoint(size_t index, out Waypoint point)
    {
        const path = lore is null ? null : lore.escortPath(me.spawn.entry);
        if (index >= path.length)
            return false;
        point = path[index];
        return true;
    }

    size_t hostWaypointCount()
    {
        return lore is null ? 0 : lore.escortPath(me.spawn.entry).length;
    }

    float hostDistanceTo(EntityRef who)
    {
        Position there;
        if (world_ is null || !world_.positionOf(who.guid, there))
            return float.infinity;
        const here = me.position;
        return sqrt((here.x - there.x) ^^ 2 + (here.y - there.y) ^^ 2 + (here.z - there.z) ^^ 2);
    }

    bool hostAlive(EntityRef who)
    {
        if (world_ is null)
            return true;
        if (auto creature = world_.creatureAt(who.guid))
            return creature.alive;
        if (auto player = world_.unit(who.guid))
            return player.alive;
        return true;
    }

    void hostQuestEvent(EntityRef player, uint quest)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.questEventHappened(quest);
    }

    void hostFailQuest(EntityRef player, uint quest)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.questFailedBy(quest);
    }

    void hostNpcFlags(uint flags)
    {
        me.values.set!UNIT_NPC_FLAGS(flags);
        if (world_ !is null)
            world_.flushCreature(me);
    }

    void hostRestoreNpcFlags()
    {
        hostNpcFlags(me.template_.npcFlags);
    }

    void hostGossipMenu(EntityRef player, uint menu)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.showGossip(me.guid, menu);
    }

    void hostCloseGossip(EntityRef player)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.closeGossip();
    }

    uint hostRandom(uint below)
    {
        import std.random : uniform;

        if (below == 0)
            return 0;
        return world_ is null ? 0 : uniform(0, below, world_.random);
    }

    // -----------------------------------------------------------------------
    // Eastern Kingdoms scripts: `CreatureHost`
    // -----------------------------------------------------------------------

    /// A creature it summoned died: its script hears of it.
    package void summonedDied(Map world, EntityRef summoned, EntityRef killer)
    {
        if (world !is null)
            world_ = world;
        raiseScript(SummonedDied(summoned, killer));
        if (script !is null && world_ !is null) // `EVENT_T_SUMMONED_JUST_DIED`
            if (auto c = world_.creatureAt(summoned.guid))
                script.summonedDied(this, summoned.guid, c.template_.entry);
        if (world_ !is null)
            world_.wake(me.guid);
    }

    /// A creature it summoned went away alive, its time up: its script hears of it.
    package void summonedGone(Map world, ulong summoned)
    {
        if (world !is null)
            world_ = world;
        raiseScript(SummonedDied(EntityRef(summoned), EntityRef.init, true));
    }

    /// It arrived where creature `orderedBy`'s script sent it: that script hears of it.
    private void tellArrival(ulong orderedBy, uint point)
    {
        if (world_ is null)
            return;
        auto orderer = world_.creatureAt(orderedBy);
        if (orderer is null || orderer.ai is null)
            return;
        orderer.ai.world_ = world_;
        orderer.ai.raiseScript(SummonedArrived(EntityRef(me.guid), point));
        world_.wake(orderedBy);
    }

    /// A stealthed unit is near enough to alert it, not to be seen: its script hears of it.
    package void stealthAlert(UnitRef who)
    {
        if (behaviour && scripts_.handles!StealthAlert(behaviour))
            raiseScript(StealthAlert(EntityRef(who.combatGuid)));
    }

    /// A player (or pet) came into its sight: its script hears of it.
    package void unitInSight(UnitRef who)
    {
        import dmangos.script.registry : ScriptKind;

        if (behaviour && scripts_.handles!UnitInSight(behaviour))
            raiseScript(UnitInSight(EntityRef(who.combatGuid)));
    }

    void hostSetFaction(uint faction)
    {
        if (world_ !is null)
            scriptFaction(faction);
    }

    void hostUnitFlags(uint flags, bool set)
    {
        if (world_ !is null)
            scriptUnitFlags(me.guid, flags, set);
    }

    void hostReactState(Reaction state)
    {
        scriptReactState(cast(uint) state);
    }

    void hostDeathPrevention(bool on)
    {
        scriptDeathPrevention(on);
    }

    void hostEvade()
    {
        if (world_ !is null)
            scriptEvade();
    }

    ActionResult hostAttackBy(EntityRef attacker, EntityRef target)
    {
        if (world_ is null)
            return ActionResult.notHere;
        auto victim_ = world_.unit(target.guid);
        if (!victim_ || !victim_.alive)
            return ActionResult.notHere;
        if (attacker.guid == me.guid)
        {
            if (!me.alive)
                return ActionResult.notAllowed;
            attackStart(victim_, world_);
            return ActionResult.ok;
        }
        auto other = world_.creatureAt(attacker.guid);
        if (other is null || other.ai is null)
            return ActionResult.notHere;
        if (!other.alive)
            return ActionResult.notAllowed;
        other.ai.attackStart(victim_, world_);
        return ActionResult.ok;
    }

    ActionResult hostMoveOther(EntityRef creature, Location at, uint point, bool run)
    {
        if (world_ is null)
            return ActionResult.notHere;
        if (creature.guid == me.guid)
        {
            hostMoveTo(at, point, run);
            return ActionResult.ok;
        }
        auto other = world_.creatureAt(creature.guid);
        if (other is null || other.ai is null)
            return ActionResult.notHere;
        if (!other.alive)
            return ActionResult.notAllowed;
        other.ai.world_ = world_;
        other.ai.moveOrdered(at, point, run, other.summon.summoner == me.guid ? me.guid : 0);
        return ActionResult.ok;
    }

    void hostFace(EntityRef target)
    {
        if (world_ !is null)
            scriptFace(target.guid, false);
    }

    void hostSheath(Sheath state)
    {
        if (world_ !is null)
            scriptSheath(cast(uint) state);
    }

    void hostMount(uint display)
    {
        if (world_ !is null)
            scriptMount(0, display);
    }

    void hostDie()
    {
        if (world_ !is null)
            scriptDie();
    }

    bool hostChangeEntry(uint entry)
    {
        return world_ !is null && scriptUpdateTemplate(entry);
    }

    EntityRef hostObjectNearby(uint entry, float range)
    {
        if (world_ is null || lore is null)
            return EntityRef.init;
        return EntityRef(lore.gameObjectNear(world_, me.position, entry, range));
    }

    ActionResult hostUseObject(EntityRef object)
    {
        if (world_ is null || lore is null)
            return ActionResult.notHere;
        return lore.useGameObject(world_, object.guid);
    }

    ActionResult hostRemoveAura(EntityRef who, uint spell)
    {
        if (world_ is null)
            return ActionResult.notHere;
        if (who.guid != me.guid && !world_.unit(who.guid))
            return ActionResult.notHere;
        scriptRemoveAura(who.guid, spell);
        return ActionResult.ok;
    }

    bool hostHasAura(EntityRef who, uint spell)
    {
        if (who.guid == me.guid)
            return me.auras.find(spell) !is null;
        if (world_ !is null)
        {
            if (auto other = world_.creatureAt(who.guid))
                return other.auras.find(spell) !is null;
            if (auto unit = world_.unit(who.guid)) // a player
                return unit.hasAuraOf(spell);
        }
        return false;
    }


    float hostThreatOf(EntityRef who)
    {
        return threatOf(who.guid);
    }

    ActionResult hostMovementScriptOf(EntityRef who, uint id)
    {
        if (world_ is null || id == 0)
            return ActionResult.notHere;
        auto creature = who.guid == me.guid ? me : world_.creatureAt(who.guid);
        if (creature is null)
            return ActionResult.notHere;
        world_.waypointScript(creature, id);
        return ActionResult.ok;
    }

    ActionResult hostTeleportPlayer(EntityRef who, Location at)
    {
        import dmangos.world.unit : UnitKind;

        auto map = world_;
        if (map is null)
            return ActionResult.notHere;
        auto unit = world_.unit(who.guid);
        if (unit.kind != UnitKind.player)
            return ActionResult.notHere;
        unit.session.spellTeleport(map.id, Position(at.x, at.y, at.z, at.orientation));
        return ActionResult.ok;
    }

    ActionResult hostSayOther(EntityRef speaker, int entry, EntityRef target)
    {
        if (speaker.guid == me.guid)
            return hostSay(entry, target);
        auto other = world_ is null ? null : world_.creatureAt(speaker.guid);
        if (other is null || other.ai is null)
            return ActionResult.notHere;
        other.ai.world_ = world_;
        return other.ai.hostSay(entry, target);
    }

    void hostMovementScript(uint id)
    {
        if (world_ !is null && id)
            world_.waypointScript(me, id);
    }

    void hostRelay(int id, EntityRef target)
    {
        if (world_ !is null)
            scriptRelay(id, target.guid);
    }

    void hostKillCredit(EntityRef player, uint entry)
    {
        if (world_ !is null)
            if (auto other = world_.unit(player.guid))
                other.killCreditFrom(entry, me.guid);
    }

    /// Something else's script (an area trigger's) has it say `script_texts` row `entry`.
    ActionResult sayScriptFor(Map world, int entry, EntityRef target)
    {
        world_ = world;
        return hostSay(entry, target);
    }

    // -----------------------------------------------------------------------
    // Kalimdor scripts: `CreatureHost`
    // -----------------------------------------------------------------------

    /// Itself or another creature here, bound to its world; null if not here.
    private Creature scriptCreature(EntityRef who)
    {
        if (who.guid == me.guid)
            return me;
        if (world_ is null)
            return null;
        auto other = world_.creatureAt(who.guid);
        if (other !is null && other.ai !is null)
            other.ai.bind(world_);
        return other;
    }

    ActionResult hostFactionOf(EntityRef creature, uint faction)
    {
        auto who = scriptCreature(creature);
        if (who is null || world_ is null)
            return ActionResult.notHere;
        who.ai.scriptFaction(faction);
        return ActionResult.ok;
    }

    ActionResult hostUnitFlagsOf(EntityRef creature, uint flags, bool set)
    {
        auto who = scriptCreature(creature);
        if (who is null || world_ is null)
            return ActionResult.notHere;
        scriptUnitFlags(who.guid, flags, set);
        return ActionResult.ok;
    }

    void hostFollow(EntityRef leader, float distance, float angle)
    {
        import dmangos.world.motion : FollowMovement, IdleMovement;

        MovementGenerator next = leader ? new FollowMovement(leader.guid, distance, angle) : new IdleMovement;
        if (inCombat_ || evadingHome)
        {
            outOfCombat = next; // how it moves once home from the fight
            return;
        }
        me.generator = next;
        if (world_ !is null)
        {
            if (!leader)
                stopMoving(me, world_);
            next.initialize(me, world_);
            world_.wake(me.guid);
        }
    }

    ActionResult hostCastAs(EntityRef caster, uint spell, EntityRef target, bool triggered)
    {
        if (caster.guid == me.guid)
            return hostCast(spell, target, triggered);
        // A player here casts it (a mark on the one it killed, a lesson it learns).
        if (caster.isPlayer)
        {
            auto session = playerSession(caster);
            return session is null ? ActionResult.notHere : session.scriptCast(spell, target.guid, triggered);
        }
        auto who = scriptCreature(caster);
        if (who is null)
            return ActionResult.notHere;
        return who.ai.castFor(world_, spell, target.guid, triggered);
    }

    ActionResult hostObjectUsable(EntityRef object, bool usable)
    {
        import dmangos.world.updatefields : GAMEOBJECT_FLAGS;

        enum uint goFlagNoInteract = 0x10;
        auto go = world_ is null ? null : world_.gameObjectAt(object.guid);
        if (go is null)
            return ActionResult.notHere;
        const flags = go.values.get!GAMEOBJECT_FLAGS;
        go.values.set!GAMEOBJECT_FLAGS(usable ? flags & ~goFlagNoInteract : flags | goFlagNoInteract);
        world_.flushGameObject(go);
        return ActionResult.ok;
    }

    uint hostEntryOf(EntityRef who)
    {
        if (who.guid == me.guid)
            return me.template_.entry;
        if (world_ is null)
            return 0;
        if (auto c = world_.creatureAt(who.guid))
            return c.template_.entry;
        if (auto go = world_.gameObjectAt(who.guid))
            return go.template_.entry;
        return 0;
    }

    void hostGroupQuestEvent(EntityRef player, uint quest)
    {
        if (world_ is null || lore is null)
            return;
        if (auto leader = world_.unit(player.guid))
            leader.questEventHappened(quest);
        foreach (other; world_.playersNear(me.position, 100))
            if (other.combatGuid != player.guid && other.alive && lore.sameGroup(player.guid, other.combatGuid))
                other.questEventHappened(quest);
    }

    bool hostLocationOf(EntityRef who, out Location at)
    {
        Position p;
        if (world_ is null || !world_.positionOf(who.guid, p))
            return false;
        at = Location(p.x, p.y, p.z, p.orientation);
        return true;
    }

    void hostEmoteState(uint emote)
    {
        import dmangos.world.updatefields : UNIT_NPC_EMOTESTATE;

        me.values.set!UNIT_NPC_EMOTESTATE(emote);
        if (world_ !is null)
            world_.flushCreature(me);
    }

    size_t hostCreaturesNearby(uint entry, float range, EntityRef[] found)
    {
        if (world_ is null)
            return 0;
        size_t n;
        foreach (other; world_.creaturesNear(me.position, range))
            if (n < found.length && other !is me && other.spawn.entry == entry && other.alive)
                found[n++] = EntityRef(other.guid);
        return n;
    }

    EntityRef hostOwner()
    {
        return EntityRef(me.petOwner ? me.petOwner : me.summon.summoner);
    }

    uint hostItemCount(EntityRef player, uint item)
    {
        import dmangos.world.unit : UnitKind;

        auto unit = world_ is null ? UnitRef.init : world_.unit(player.guid);
        if (!unit || unit.kind != UnitKind.player || unit.session.player is null)
            return 0;
        return unit.session.player.inventory.count(item);
    }

    uint hostGiveItem(EntityRef player, uint item, uint count)
    {
        import dmangos.world.unit : UnitKind;

        auto unit = world_ is null ? UnitRef.init : world_.unit(player.guid);
        if (!unit || unit.kind != UnitKind.player || unit.session.player is null || count == 0)
            return 0;
        return unit.session.scriptGiveItem(item, count);
    }

    // Dungeon scripts:

    EntityRef hostPlayerNearby(float range)
    {
        if (world_ is null)
            return EntityRef.init;
        const here = me.position;
        UnitRef best;
        float bestDistance = float.infinity;
        foreach (player; world_.playersNear(here, range))
        {
            if (!player.alive || player.untouchable)
                continue;
            Position at;
            if (!world_.positionOf(player.combatGuid, at))
                continue;
            const d = (at.x - here.x) ^^ 2 + (at.y - here.y) ^^ 2 + (at.z - here.z) ^^ 2;
            if (d < bestDistance)
            {
                bestDistance = d;
                best = player;
            }
        }
        return best ? EntityRef(best.combatGuid) : EntityRef.init;
    }

    // -----------------------------------------------------------------------
    // -----------------------------------------------------------------------

    int hostAskDungeon(uint id)
    {
        return lore is null || !me.instanceId ? 0 : lore.askDungeon(me.instanceId, EntityRef(me.guid), id);
    }

    EntityRef hostSelectTarget(Pick pick, uint filter, uint skip)
    {
        import std.algorithm.sorting : sort;
        import std.random : uniform;
        import dmangos.world.defines : Power;
        import dmangos.world.unit : UnitKind;

        if (world_ is null || threat.length == 0)
            return EntityRef.init;
        const self = me.fighter;
        ulong[] list;
        foreach (guid, _; threat)
        {
            auto who = world_.unit(guid);
            if (!who || !who.alive || who.untouchable)
                continue;
            const isPlayer = who.kind == UnitKind.player;
            if ((filter & PickFilter.player) && !isPlayer)
                continue;
            if ((filter & PickFilter.notVictim) && guid == victim)
                continue;
            if (filter & (PickFilter.manaUser | PickFilter.notManaUser))
            {
                const mana = isPlayer ? who.session.player.powerType == Power.mana
                    : who.creature.values.get!UNIT_FIELD_MAXPOWER1 > 0;
                if (((filter & PickFilter.manaUser) && !mana) || ((filter & PickFilter.notManaUser) && mana))
                    continue;
            }
            if (filter & (PickFilter.inMelee | PickFilter.notInMelee))
            {
                const near = canReachWithMelee(self, who.fighter);
                if (((filter & PickFilter.inMelee) && !near) || ((filter & PickFilter.notInMelee) && near))
                    continue;
            }
            list ~= guid;
        }
        float distance(ulong guid)
        {
            Position at;
            if (!world_.positionOf(guid, at))
                return float.infinity;
            return (at.x - me.position.x) ^^ 2 + (at.y - me.position.y) ^^ 2 + (at.z - me.position.z) ^^ 2;
        }
        final switch (pick)
        {
        case Pick.random, Pick.topThreat, Pick.bottomThreat:
            list.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
            break;
        case Pick.nearest:
            list.sort!((a, b) => distance(a) < distance(b));
            break;
        case Pick.farthest:
            list.sort!((a, b) => distance(a) > distance(b));
            break;
        }
        if (skip >= list.length)
            return EntityRef.init;
        final switch (pick)
        {
        case Pick.random:
            return EntityRef(list[uniform(skip, list.length, world_.random)]);
        case Pick.topThreat, Pick.nearest, Pick.farthest:
            return EntityRef(list[skip]);
        case Pick.bottomThreat:
            return EntityRef(list[$ - 1 - skip]);
        }
    }

    size_t hostThreatList(EntityRef[] into)
    {
        import std.algorithm.sorting : sort;

        auto list = threat.keys;
        list.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
        size_t n;
        foreach (guid; list)
            if (n < into.length)
                into[n++] = EntityRef(guid);
        return n;
    }

    ActionResult hostModifyThreat(EntityRef target, int percent)
    {
        if (!target)
        {
            foreach (guid, ref amount; threat)
                amount = percent <= -100 ? 0 : amount * (100 + percent) / 100.0f;
            return ActionResult.ok;
        }
        if (target.guid !in threat)
            return ActionResult.notHere;
        modifyThreatPercent(target.guid, percent);
        return ActionResult.ok;
    }







    size_t hostPlayersNear(float range, EntityRef[] into)
    {
        if (world_ is null)
            return 0;
        size_t n;
        foreach (p; world_.playersNear(me.position, range))
            if (p.alive && n < into.length)
                into[n++] = EntityRef(p.combatGuid);
        return n;
    }

    void hostTeleport(Location at)
    {
        import dmangos.world.motion : stopMoving;
        import dmangos.world.spline : monsterStop;

        if (world_ is null)
            return;
        stopMoving(me, world_);
        me.movement.position = Position(at.x, at.y, at.z, at.orientation);
        world_.sendToObservers(me.guid, Opcode.SMSG_MONSTER_MOVE, monsterStop(me.guid, me.position, me.spline.id));
        if (auto map = world_)
            map.objectRelocated(me);
    }




    void hostZoneCombat()
    {
        if (world_ !is null)
            scriptZoneCombatPulse();
    }


    bool hostCasting()
    {
        return castingNow;
    }

    void hostInterrupt()
    {
        if (world_ !is null)
            interruptCast();
    }


    void hostFlying(bool on)
    {
        import dmangos.world.motion : fallToGround;
        import dmangos.world.movement : MovementFlags;

        const wasFlying = me.flyingMovement;
        me.scriptFlying = on;
        if (on)
            me.movement.flags |= MovementFlags.levitating;
        else
        {
            me.movement.flags &= ~MovementFlags.levitating;
            if (wasFlying && world_ !is null)
                fallToGround(me, world_);
        }
    }

    void hostDisplay(uint model)
    {
        if (world_ !is null)
            scriptMorph(0, model);
    }

    void hostSetHealthPercent(EntityRef who, uint percent)
    {
        auto c = who.guid == me.guid ? me : world_ is null ? null : world_.creatureAt(who.guid);
        if (c is null || !c.alive)
            return;
        const most = c.values.get!UNIT_FIELD_MAXHEALTH;
        auto health = cast(uint)(ulong(most) * (percent > 100 ? 100 : percent) / 100);
        c.values.set!UNIT_FIELD_HEALTH(health ? health : 1);
        if (world_ !is null)
            world_.flushCreature(c);
    }


    void hostRooted(bool on)
    {
        if (world_ !is null)
            scriptImmobilized(on, true);
        else
            me.scriptRooted = on;
    }


    void hostMoveNow(Location at, uint point, bool run)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : PointMovement;

        if (evadingHome || !me.alive)
            return;
        if (!inCombat_)
            return hostMoveTo(at, point, run);
        auto move = new PointMovement(Vector3(at.x, at.y, at.z), at.orientation, !run, null);
        move.notifyScript = true;
        move.arrivalPoint = point;
        me.generator = move;
        if (world_ !is null)
        {
            move.initialize(me, world_);
            world_.wake(me.guid);
        }
    }

    void hostSpellList(uint id)
    {
        chooseSpellList(id);
    }

    ubyte hostClassOf(EntityRef who)
    {
        import dmangos.world.unit : UnitKind;

        if (world_ is null || !who.isPlayer)
            return 0;
        auto unit = world_.unit(who.guid);
        return unit && unit.kind == UnitKind.player ? unit.session.player.values.getByte!UNIT_FIELD_BYTES_0(1) : 0;
    }

    void hostAddThreat(EntityRef who, float amount)
    {
        if (world_ is null || !me.alive)
            return;
        if (auto other = world_.unit(who.guid))
            addThreat(other, amount);
    }

    // -----------------------------------------------------------------------
    // `CreatureHost`
    // -----------------------------------------------------------------------

    /// The session of a player on its map; null if `who` is no player here.
    private auto playerSession(EntityRef who)
    {
        import dmangos.world.unit : UnitKind;

        if (world_ is null || !who.isPlayer)
            return null;
        auto unit = world_.unit(who.guid);
        return unit && unit.kind == UnitKind.player && unit.session.player !is null ? unit.session : null;
    }

    uint hostLevelOf(EntityRef who)
    {
        import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

        if (who.guid == me.guid)
            return me.values.get!UNIT_FIELD_LEVEL;
        if (auto session = playerSession(who))
            return session.player.values.get!UNIT_FIELD_LEVEL;
        if (auto c = world_ is null ? null : world_.creatureAt(who.guid))
            return c.values.get!UNIT_FIELD_LEVEL;
        return 0;
    }

    uint hostSkillOf(EntityRef player, uint skill)
    {
        auto session = playerSession(player);
        return session is null ? 0 : session.player.skillValue(skill)[0];
    }

    bool hostKnowsSpell(EntityRef player, uint spell)
    {
        auto session = playerSession(player);
        return session !is null && session.player.knowsSpell(spell);
    }

    Standing hostStandingOf(EntityRef player, uint faction)
    {
        auto session = playerSession(player);
        return session is null || session.player.reputation is null ? Standing.hated
            : cast(Standing) session.player.reputation.rankWith(faction);
    }

    bool hostWearsItemNeeding(EntityRef player, uint spell)
    {
        auto session = playerSession(player);
        return session !is null && session.scriptWearsItemNeeding(spell);
    }

    bool hostTakeMoney(EntityRef player, uint copper)
    {
        auto session = playerSession(player);
        return session !is null && session.scriptTakeMoney(copper);
    }

    void hostUnlearnSpell(EntityRef player, uint spell)
    {
        if (auto session = playerSession(player))
            session.scriptUnlearnSpecialization(spell);
    }

    void hostOpenWindow(EntityRef player, NpcWindow window)
    {
        auto session = playerSession(player);
        if (session is null)
            return;
        final switch (window)
        {
        case NpcWindow.vendor:
            session.scriptOpenWindow(me.guid, false);
            break;
        case NpcWindow.trainer:
            session.scriptOpenWindow(me.guid, true);
            break;
        }
    }

    void hostWalkPath(uint pathId)
    {
        import dmangos.world.motion : WaypointMovement;

        const path = lore is null ? null : lore.creaturePath(me.spawn.entry, me.spawn.guid, pathId);
        if (path.length == 0)
            return;
        auto next = new WaypointMovement(path, false, pathId);
        if (inCombat_ || evadingHome)
        {
            outOfCombat = next; // once home from the fight
            return;
        }
        me.generator = next;
        if (world_ !is null)
        {
            next.initialize(me, world_);
            world_.wake(me.guid);
        }
    }

    ActionResult hostSendHome(EntityRef creature)
    {
        auto c = creature.guid == me.guid ? me : scriptCreature(creature);
        if (c is null || !c.alive || lore is null || world_ is null)
            return ActionResult.notHere;
        if (c.ai.inCombat)
            return ActionResult.notAllowed;
        lore.sendCreatureHome(world_, c);
        return ActionResult.ok;
    }

    void hostZoneUnderAttack(EntityRef attacker)
    {
        if (lore !is null && world_ !is null)
            lore.zoneUnderAttack(world_, me, attacker.guid);
    }

    bool hostDisruptEngineer(EntityRef who)
    {
        auto session = playerSession(who);
        if (me.template_.entry != 16230 || !me.alive || session is null) return false;
        const spell = lore.spellInfo(31315);
        if (spell is null) return false;
        const rune = spell.reagents[0], count = spell.casting.reagentCount[0];
        if (rune <= 0 || !count || session.player.inventory.count(rune) < count) return false;
        if (session.scriptCast(spell.id, me.guid, true) != ActionResult.ok) return false;
        session.takeItem(rune, count);
        if (auto map = world_)
            if (const shield = hostObjectNearby(181142, 3))
                map.removeObject(shield.guid);
        return true;
    }

    long hostInvasionCampaign(out uint generation)
    {
        import dmangos.world.context : WorldContext;
        auto context = lore;
        if (context is null || context.invasionHere.invasionLayout is null || world_ is null) return 0;
        const site = context.invasionHere.invasionLayout.nearest(context.invasionHere.invasionLayout.camps, me.spawn.map, me.position);
        if (site is null || !site.present(context.invasionHere.invasion)) return 0;
        generation = context.invasionHere.invasion.zones[site.zone].generation;
        return context.invasionHere.invasion.campaign;
    }

    void hostCampDefeated(long campaign, uint generation)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.scourge : InvasionHost;
        auto context = lore;
        if (!campaign || context is null || context.invasionHere.invasionLayout is null) return;
        const site = context.invasionHere.invasionLayout.nearest(context.invasionHere.invasionLayout.camps, me.spawn.map, me.position);
        if (site is null) return;
        auto event = site.stamp(context.invasionHere.invasion);
        event.campaign = campaign;
        event.generation = generation;
        context.services.call!(InvasionHost.defeated)(event);
    }

    // The war effort:

    void hostWarEffortHandIn(uint quest, uint resource)
    {
        if (lore !is null)
            lore.warEffortHere.warEffortHandIn(quest, resource);
    }

    void hostWarEffortColossus(uint colossus)
    {
        if (lore !is null)
            lore.warEffortHere.warEffortColossusFell(colossus);
    }
}
