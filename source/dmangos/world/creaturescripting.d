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
    import dmangos.script.api : MenuOption, MovementDone, QuestProgress, SpellHost, Waypoint;
    import dmangos.world.spells : SpellInfo;

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

    /// Raises `event` from outside its own moments (a player's gossip, a quest): its world as given.
    /// Whether the script consumed it (`CreatureContext.consume`).
    bool raiseFrom(E)(CombatWorld world, const E event)
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
        if (world_ !is null)
            world_.wake(me.guid);
        return context.consumed;
    }

    /// Its `moveTo` arrived.
    private void movementArrived(uint point)
    {
        raiseScript(MovementDone(point));
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
        if (auto player = world_.unit(who.guid))
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
            if (who.guid == me.guid)
                return me.values.get!UNIT_FIELD_HEALTH;
            if (world_ !is null)
                if (auto other = world_.creatureAt(who.guid))
                    return other.values.get!UNIT_FIELD_HEALTH;
            return 0;
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
    }

    private CastHost castHost_;

    private @property CastHost castHost()
    {
        if (castHost_ is null)
            castHost_ = new CastHost;
        return castHost_;
    }

    /// A spell script has it cast `spellId` at `target`.
    ActionResult castFor(CombatWorld world, uint spellId, ulong target, bool triggered)
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
    void sayFor(CombatWorld world, uint text, ulong target)
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
    void despawnFor(CombatWorld world, uint delayMs)
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
        move.onArrived = (Creature c) {
            c.ai.movementArrived(point);
            if (orderedBy)
                c.ai.tellArrival(orderedBy, point);
        };
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
            return player.fighter.alive;
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
    package void summonedDied(CombatWorld world, EntityRef summoned, EntityRef killer)
    {
        if (world !is null)
            world_ = world;
        raiseScript(SummonedDied(summoned, killer));
        if (world_ !is null)
            world_.wake(me.guid);
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
        if (!victim_ || !victim_.fighter.alive)
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
            if (auto other = world_.creatureAt(who.guid))
                return other.auras.find(spell) !is null;
        return false;
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
}
