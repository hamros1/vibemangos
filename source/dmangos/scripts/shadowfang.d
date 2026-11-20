/**
 * Shadowfang Keep (map 33): its doors, opened as their guardians fall (the cells with Rethilgore,
 * the Sorcerer's Gate with Fenrus, Arugal's Lair with Wolf Master Nandos) or by a freed prisoner
 * (the Courtyard Door); the two prisoners, who lead the way to the courtyard; Arugal's appearance
 * before Deathstalker Vincent as the keep is entered, and Vincent, left for dead; Wolf Master
 * Nandos, who comes when his pack is slain; Arugal's voidwalkers; and Archmage Arugal.
 */
module dmangos.scripts.shadowfang;

import dmangos.script;

/// Creatures and objects of the keep.
enum : uint
{
    rethilgore = 3914,
    fenrus = 4274,
    nandos = 3927,
    adamant = 3849,
    ashcrombe = 3850,
    arugal = 4275,
    arugalIntro = 10000, // "Arugal", who speaks to Vincent as the keep is entered
    vincent = 4444,
    lupineHorror = 3863,
    wolfguardWorg = 5058,
    bleakWorg = 3861,
    slaveringWorg = 3862,

    voidwalker = 4627,   // Arugal's Voidwalker, of the Fenrus event

    courtyardDoor = 18895,
    arugalFocus = 18973,  // its lightning, in the Fenrus event
    sorcerersGate = 18972,
    arugalsLair = 18971,
    cellDoor1 = 18934,
    cellDoor2 = 18935,
    cellDoor3 = 18936,
}

/// What the keep remembers (saved in `instance.data`).
@instance("instance_shadowfang_keep")
struct ShadowfangKeep
{
    enum Signals : uint { courtyardOpened = 1, prisonersFree = 2 }

    bool rethilgoreDead, fenrusDead, nandosDead, courtyardOpen;
    bool introDone, packCalled;
    ubyte introStep;
    ubyte fenrusStep;     /// the Fenrus event: Arugal's appearance, his voidwalkers
    ubyte voidwalkersDead;
    Pack!24 nandosPack;   /// the worgs of Nandos's hall
    @transient EntityRef courtyard, gate, lair;
    @transient EntityRef[3] cells;
    @transient EntityRef[2] prisoners;
    @transient EntityRef vincentRef, introArugal, nandosRef, fenrusRef, fenrusArugal, focus;

    enum : int
    {
        sayBossDieAdamant = -1033007, sayBossDieAshcrombe = -1033008, yellPackDead = -1033020,
        sayIntro1 = -1033009, sayIntro2 = -1033010, sayIntro3 = -1033011, sayIntro4 = -1033012,
        yellFenrus = -1033013,
    }
    enum uint spellSpawn = 7741, spellTeleport = 7136, spellFire = 6422;
    enum Location nandosComes = Location(-170.6f, 2182.45f, 151.91f);
    /// Where Arugal appears over Fenrus's body, and where his four voidwalkers come.
    enum Location fenrusArugalAt = Location(-136.89f, 2169.17f, 136.58f, 2.794f);
    static immutable Location[4] voidwalkersAt = [Location(-155.352f, 2172.780f, 128.448f, 4.679f),
        Location(-147.059f, 2163.193f, 128.696f, 0.128f), Location(-148.869f, 2180.859f, 128.448f, 1.814f),
        Location(-140.203f, 2175.263f, 128.448f, 0.373f)];

    enum Step : ubyte { intro, fenrus }
    Schedule!(Step, 2) steps;

    /// The Fenrus event (ScriptDev2's dialogue): Arugal yells, burns, calls the lightning, goes, and his voidwalkers
    /// come; the Sorcerer's Gate opens when the four are dead.
    private void fenrusEvent(ref InstanceContext keep)
    {
        static immutable uint[5] waits = [100, 2000, 5000, 5000, 500];
        const now = fenrusStep++;
        switch (now)
        {
        case 0:
            fenrusArugal = keep.summon(arugal, fenrusArugalAt, 30_000);
            break;
        case 1:
            if (fenrusArugal)
                keep.say(fenrusArugal, yellFenrus);
            break;
        case 2:
            if (fenrusArugal)
                keep.castSpell(fenrusArugal, spellFire);
            break;
        case 3:
            if (focus)
                keep.useObject(focus);
            break;
        case 4:
            if (fenrusArugal)
                keep.despawn(fenrusArugal, 0);
            break;
        case 5:
            // The first leads them round the room, the others follow it.
            EntityRef leader;
            foreach (i, at; voidwalkersAt)
            {
                const walker = keep.summon(voidwalker, at);
                if (!walker)
                    continue;
                if (!leader)
                {
                    leader = walker;
                    keep.signal(walker, ArugalVoidwalker.Signals.lead);
                }
                else
                    keep.signal(walker, ArugalVoidwalker.Signals.follow,
                        ArugalVoidwalker.followSignal(leader, cast(uint) i));
            }
            return;
        default:
            return;
        }
        steps.after(Step.fenrus, waits[now].msecs);
    }

    /// Arugal's appearance before Vincent: what happens at each step, and the wait after it.
    void on(ref InstanceContext keep, Step step)
    {
        if (step == Step.fenrus)
            return fenrusEvent(keep);
        static immutable uint[10] waits = [3000, 8000, 3300, 3600, 3500, 4500, 3000, 5500, 2500, 2000];
        const now = introStep++;
        switch (now)
        {
        case 1:
            if (vincentRef)
                keep.signal(vincentRef, DeathstalkerVincent.Signals.fall);
            break;
        case 2:
            if (introArugal)
                keep.castSpell(introArugal, spellSpawn);
            break;
        case 3: say(keep, sayIntro1); break;
        case 4: break;
        case 5: say(keep, sayIntro2); break;
        case 6: say(keep, sayIntro3); break;
        case 7: break;
        case 8: say(keep, sayIntro4); break;
        case 9:
            if (introArugal)
                keep.castSpell(introArugal, spellTeleport);
            break;
        case 10:
            introDone = true;
            if (introArugal)
                keep.despawn(introArugal, 1000);
            return;
        default:
            break;
        }
        if (now < waits.length)
            steps.after(Step.intro, waits[now].msecs);
    }

    private void say(ref InstanceContext keep, int text)
    {
        if (introArugal)
            keep.say(introArugal, text);
    }

    void on(ref InstanceContext keep, const ref ObjectLoaded e)
    {
        switch (e.object.entry)
        {
        case courtyardDoor:
            courtyard = e.object;
            if (courtyardOpen)
                keep.door(e.object, true);
            break;
        case sorcerersGate:
            gate = e.object;
            if (fenrusDead)
                keep.door(e.object, true);
            break;
        case arugalsLair:
            lair = e.object;
            if (nandosDead)
                keep.door(e.object, true);
            break;
        case arugalFocus:
            focus = e.object;
            break;
        case cellDoor1, cellDoor2, cellDoor3:
            cells[e.object.entry - cellDoor1] = e.object;
            if (rethilgoreDead)
                keep.door(e.object, true);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext keep, const ref CreatureLoaded e)
    {
        if (e.creature.entry == adamant || e.creature.entry == ashcrombe)
        {
            prisoners[e.creature.entry == adamant ? 0 : 1] = e.creature;
            if (rethilgoreDead)
                keep.signal(e.creature, Signals.prisonersFree);
        }
        switch (e.creature.entry)
        {
        case vincent:
            vincentRef = e.creature;
            if (introDone)
                keep.signal(e.creature, DeathstalkerVincent.Signals.fall);
            else if (!steps.pending(Step.intro))
            {
                introStep = 0;
                steps.after(Step.intro, 3.seconds);
            }
            break;
        case arugalIntro:
            introArugal = e.creature;
            if (introDone)
                keep.despawn(e.creature);
            break;
        case nandos:
            nandosRef = e.creature;
            break;
        case fenrus:
            fenrusRef = e.creature;
            break;
        case lupineHorror, wolfguardWorg, bleakWorg, slaveringWorg:
            Location at;
            if (keep.locationOf(e.creature, at) && at.z > nandosComes.z)
                nandosPack.add(e.creature);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext keep, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case lupineHorror, wolfguardWorg, bleakWorg, slaveringWorg:
            if (nandosPack.died(e.creature) && nandosPack.allDead && !packCalled && nandosRef
                && keep.alive(nandosRef) && !keep.victimOf(nandosRef))
            {
                packCalled = true;
                keep.say(nandosRef, yellPackDead);
                keep.moveTo(nandosRef, nandosComes, 0, true);
            }
            break;
        case rethilgore:
            if (prisoners[0] && prisoners[1] && keep.alive(prisoners[0]) && keep.alive(prisoners[1]))
            {
                keep.say(prisoners[0], sayBossDieAdamant);
                keep.say(prisoners[1], sayBossDieAshcrombe);
            }
            rethilgoreDead = true;
            foreach (cell; cells)
                if (cell)
                    keep.door(cell, true);
            foreach (prisoner; prisoners)
                if (prisoner)
                    keep.signal(prisoner, Signals.prisonersFree);
            break;
        case fenrus:
            // The gate opens when Arugal's voidwalkers are dead (after a restart, at once: they are gone).
            if (!fenrusDead)
            {
                fenrusDead = true;
                fenrusStep = 0;
                steps.after(Step.fenrus, 100.msecs);
            }
            break;
        case voidwalker:
            if (fenrusDead && ++voidwalkersDead == voidwalkersAt.length && gate)
                keep.door(gate, true);
            break;
        case nandos:
            nandosDead = true;
            if (lair)
                keep.door(lair, true);
            break;
        default:
            break;
        }
    }

    void on(ref InstanceContext keep, const ref Signal e)
    {
        if (e.id == Signals.courtyardOpened && !courtyardOpen)
        {
            courtyardOpen = true;
            if (courtyard)
                keep.door(courtyard, true);
        }
    }
}

/**
 * Deathstalker Adamant and Sorcerer Ashcrombe: freed when Rethilgore falls, either leads the player
 * who asks to the courtyard door (the twelfth point of its path), opens it there (Ashcrombe with his
 * spell, Adamant fumbling with the lock), and leaves: Ashcrombe vanishes in fire, Adamant runs on to
 * the end of her path.
 */
@creature("npc_shadowfang_prisoner")
struct ShadowfangPrisoner
{
    enum uint unlock = 1;
    enum : uint { textAdamant = 799, textAshcrombe = 798 } /// their `npc_text`s
    enum : uint { spellUnlock = 6421, spellFire = 6422 }
    enum : int
    {
        freeAshcrombe = -1033000, openAshcrombe = -1033001, afterAshcrombe = -1033002, vanishAshcrombe = -1033014,
        freeAdamant = -1033003, openAdamant = -1033004, afterAdamant = -1033005, leaveAdamant = -1033006,
        fumbleAdamant = -1033015,
    }
    /// Points of their paths (from 0: `script_waypoint`'s 11 and 12).
    enum : uint { pointNearDoor = 10, pointDoor = 11 }

    enum Step : ubyte { open, leave, vanish }
    Schedule!Step steps;
    Escort escort;
    bool free, opened;

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == ShadowfangKeep.Signals.prisonersFree)
            free = true;
    }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        GossipMenu menu;
        if (free && !escort.active && !opened)
            menu.add(GossipIcon.chat, "Please unlock the courtyard door.", unlock);
        me.sendGossip(e.player, me.self.entry == adamant ? textAdamant : textAshcrombe, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != unlock || escort.active || opened || !free)
            return;
        me.closeGossip(e.player);
        me.say(me.self.entry == adamant ? freeAdamant : freeAshcrombe, e.player);
        escort.start(me, e.player, 0);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point == pointNearDoor && me.self.entry == ashcrombe)
            me.say(openAshcrombe);
        else if (point != uint.max && (point == pointDoor || point + 1 == me.waypointCount) && !opened)
        {
            opened = true;
            escort.paused = true;
            if (me.self.entry == ashcrombe)
            {
                me.castSelf(spellUnlock);
                steps.after(Step.open, 5.seconds);
            }
            else
            {
                me.say(openAdamant, escort.player);
                me.say(fumbleAdamant);
                steps.after(Step.open, 6.seconds);
            }
        }
        else if (point != uint.max && point + 1 == me.waypointCount && me.self.entry == adamant)
            me.despawn(1000);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.open:
            me.say(me.self.entry == adamant ? afterAdamant : afterAshcrombe);
            me.signalDungeon(ShadowfangKeep.Signals.courtyardOpened);
            steps.after(Step.leave, 2.seconds);
            break;
        case Step.leave:
            if (me.self.entry == ashcrombe)
            {
                me.castSelf(spellFire);
                steps.after(Step.vanish, 2500.msecs);
            }
            else
            {
                me.say(leaveAdamant);
                escort.run = true;
                escort.paused = false;
                if (escort.point + 1 >= me.waypointCount)
                    me.despawn(1000); // the door at the end of her path: she goes from there
            }
            break;
        case Step.vanish:
            me.say(vanishAshcrombe);
            me.despawn(0);
            break;
        }
    }
}

/**

 * Archmage Arugal (ScriptDev2's, from sniffs): Void Bolt at his foe as he starts and every three to five seconds;
 * Thundershock when someone is in melee reach (then not for half a minute); his curse on someone other than his
 * foe, turning him into a worgen; and every fifty seconds or so a Shadow Port to another of his three places: the
 * ledge he stands on, the upper ledge (where he does not stay: two seconds on he goes again), the stairs. He yells as
 * he starts, and over each of his kills. The Arugal who appears in Fenrus's room (below it: the Fenrus event) only
 * watches.
 */
@creature("boss_arugal")
struct ArchmageArugal
{
    enum : int { yellAggro = -1033017, yellKill = -1033018, yellCurse = -1033019 }
    enum : uint { voidBolt = 7588, arugalsCurse = 7621, thundershock = 7803 }
    enum : uint { portSpawnLedge = 7586, portUpperLedge = 7587, portStairs = 7136 }
    enum float fenrusRoomHeight = 140;
    enum Place : ubyte { spawnLedge, upperLedge, stairs }

    enum Step : ubyte { bolt, curse, shock, port }
    Schedule!Step steps;
    Place place;
    bool watcher; /// the Arugal of the Fenrus event

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.location.z < fenrusRoomHeight)
        {
            watcher = true;
            me.unitFlags(UnitFlag.immuneToPlayer | UnitFlag.immuneToNpc);
            me.reactState(Reaction.passive);
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (watcher)
            return;
        me.say(yellAggro);
        me.castSpell(voidBolt, e.enemy);
        steps.after(Step.bolt, 1.seconds);
        steps.after(Step.shock, 1.seconds);
        steps.after(Step.curse, (20_000 + me.random(10_001)).msecs);
        steps.after(Step.port, (22_000 + me.random(4001)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.bolt:
            const bolted = me.castSpell(voidBolt) == ActionResult.ok;
            steps.after(Step.bolt, bolted ? (2900 + me.random(1901)).msecs : 1.seconds);
            break;
        case Step.shock:
            const near = me.selectTarget(Pick.topThreat, PickFilter.inMelee);
            if (near && me.castSelf(thundershock) == ActionResult.ok)
                steps.after(Step.shock, (30_000 + me.random(8001)).msecs);
            else
                steps.after(Step.shock, 1.seconds);
            break;
        case Step.curse:
            if (const target = me.selectTarget(Pick.random, 0, 1))
            {
                me.say(yellCurse);
                if (me.castSpell(arugalsCurse, target) == ActionResult.ok)
                {
                    steps.after(Step.curse, (20_000 + me.random(15_001)).msecs);
                    break;
                }
            }
            steps.after(Step.curse, 1.seconds);
            break;
        case Step.port:
            const next = cast(Place) me.random(3);
            if (next == place && place != Place.upperLedge)
            {
                steps.after(Step.port, (10_000 + me.random(5001)).msecs);
                break;
            }
            if (me.casting)
                me.interrupt();
            static immutable uint[3] ports = [portSpawnLedge, portUpperLedge, portStairs];
            auto result = me.castSelf(ports[next]);
            if (result != ActionResult.ok && place == Place.upperLedge)
                result = me.castSelf(ports[next], true); // out of mana up there: he must come down
            if (result != ActionResult.ok)
            {
                steps.after(Step.port, 1.seconds);
                break;
            }
            place = next;
            // On the upper ledge he does not melee, and leaves again soon.
            me.melee(next != Place.upperLedge);
            me.combatMovement(next != Place.upperLedge);
            steps.after(Step.port, next == Place.upperLedge ? (2000 + me.random(201)).msecs
                : (48_000 + me.random(7001)).msecs);
            break;
        }
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        if (e.victim.isPlayer)
            me.say(yellKill);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
        place = Place.spawnLedge;
        me.melee(true);
        me.combatMovement(true);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// Deathstalker Vincent: left for dead by Arugal; whoever attacks him finds him not quite dead.
@creature("npc_deathstalker_vincent")
struct DeathstalkerVincent
{
    enum Signals : uint { fall = 1 }
    enum int sayDie = -1033016;
    enum uint factionFriendly = 35;
    bool fallen;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.deathPrevention(true);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.fall)
        {
            fallen = true;
            me.standState(StandState.dead);
        }
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        me.standState(StandState.stand);
        if (e.after == 0)
        {
            me.setFaction(factionFriendly);
            me.say(sayDie);
        }
    }
}

/**
 * One of Arugal's voidwalkers (ScriptDev2's): the first of the four walks its path round Fenrus's room, the others
 * follow it, behind it and to its sides; in a fight its Dark Offering heals the most hurt of its kind near it.
 */
@creature("mob_arugal_voidwalker")
struct ArugalVoidwalker
{
    enum uint darkOffering = 7154;
    /// From the keep's script: lead (walk the path), or follow (the leader's guid counter, and the place behind it, by
    /// `followSignal`).
    enum Signals : uint { lead = 1, follow = 2 }
    enum Step : ubyte { offering }
    Schedule!Step steps;

    /// The `Signal` value that sends one to follow `leader` at `place` (1 behind-right, 2 behind, 3 behind-left).
    static int followSignal(EntityRef leader, uint place)
    {
        return cast(int)((leader.guid & 0xFF_FFFF) | place << 24);
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.lead)
            me.walkPath();
        else if (e.id == Signals.follow)
        {
            const leader = EntityRef(0xF130_0000_0000_0000UL | ulong(voidwalker) << 24 | (e.value & 0xFF_FFFF));
            me.follow(leader, 1, 1.5708f * (uint(e.value) >> 24));
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.after(Step.offering, (4400 + me.random(8101)).msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        // The most hurt of its kind within ten yards (itself too).
        EntityRef[8] near;
        const n = me.creaturesNearby(me.self.entry, 10, near[]);
        EntityRef worst = me.self;
        uint least = me.healthPercent;
        foreach (friend; near[0 .. n])
            if (me.alive(friend) && me.healthPercentOf(friend) < least)
            {
                worst = friend;
                least = me.healthPercentOf(friend);
            }
        if (least < 100 && me.castSpell(darkOffering, worst) == ActionResult.ok)
            steps.after(Step.offering, (4000 + me.random(8001)).msecs);
        else
            steps.after(Step.offering, 1.seconds);
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        steps.clear();
    }
}

unittest
{
    import dmangos.scripts.testing;

    alias self = dmangos.scripts.shadowfang;
    auto keep = runInstance!self("instance_shadowfang_keep");
    keep.raise(CreatureLoaded(creatureRef(arugalIntro)));
    keep.raise(CreatureLoaded(creatureRef(vincent)));
    keep.run(50_000);
    assert(keep.host.done("signal 4444 1 0") && keep.host.done("say 10000 -1033012") && keep.host.done("despawn 10000"));
    assert(keep.state!ShadowfangKeep.introDone);

    keep.host.places[creatureRef(bleakWorg, 1).guid] = Location(0, 0, 155);
    keep.raise(CreatureLoaded(creatureRef(nandos)));
    keep.raise(CreatureLoaded(creatureRef(bleakWorg, 1)));
    keep.host.fought = EntityRef.init;
    keep.raise(CreatureDied(creatureRef(bleakWorg, 1)));
    assert(keep.host.done("say 3927 -1033020") && keep.host.done("move 3927 0"));
}
