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
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.script.api;
    import dmangos.script.registry : ScriptHandle, ScriptRuntime;
    import dmangos.world.eventai : castTriggered;

    private
    {
        ScriptRuntime scripts_;   // the server's scripts; null if this creature has none
        ScriptHandle behaviour;   // its script's state
        bool spawnRaised;         // `Spawned` was raised
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
        if (scripts_ !is null)
            scripts_.destroy(behaviour);
    }

    /// Its script's state, for the node it moves to (`Creature.saveState`).
    void saveBehaviour(ref ByteWriter w)
    {
        ByteWriter state;
        if (scripts_ !is null)
            scripts_.save(behaviour, state);
        w.put(spawnRaised);
        w.put(cast(uint) state.length);
        w.putBytes(state.data);
    }

    /// Reads what `saveBehaviour` wrote; a state of another layout leaves the script fresh.
    void loadBehaviour(ref ByteReader r)
    {
        spawnRaised = r.read!bool;
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
    }

    /// Whether its script has steps pending: it must tick even out of combat.
    private @property bool behaviourBusy() const
    {
        return behaviour && (cast() scripts_).busy(behaviour); // reads only
    }

    /// A `Signal` from another script.
    void signalled(EntityRef from, uint id, int value, CombatWorld world)
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
        if (auto player = world_.combatant(who.guid))
            return player.healthPercent();
        return uint.max;
    }

    ActionResult hostCast(uint spellId, EntityRef target, bool triggered)
    {
        if (lore is null || world_ is null)
            return ActionResult.notHere;
        const spell = lore.spellInfo(spellId);
        if (spell is null)
            return ActionResult.failed;
        if (target.guid != me.guid && world_.creatureAt(target.guid) is null && world_.combatant(target.guid) is null)
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
            if (auto victim = world_.combatant(attack.guid))
                summoned.ai.attackStart(victim, world_);
        return EntityRef(summoned.guid);
    }

    void hostDespawn(uint delayMs)
    {
        scriptDespawn(delayMs);
    }

    ActionResult hostSignal(EntityRef to, uint id, int value)
    {
        if (world_ is null)
            return ActionResult.notHere;
        auto other = world_.creatureAt(to.guid); // this node's own only: a replica is not a creature here
        if (other is null)
            return ActionResult.notHere;
        other.ai.signalled(EntityRef(me.guid), id, value, world_);
        return ActionResult.ok;
    }

    void hostSignalDungeon(uint id, int value)
    {
        if (lore !is null && me.instanceId)
            lore.signalDungeon(me.instanceId, EntityRef(me.guid), id, value);
    }

    void hostLog(string text)
    {
        import dmangos.log : info;

        info!"script %s (%s %s): %s"(behaviourName, me.template_.name, me.spawn.guid, text);
    }
}
