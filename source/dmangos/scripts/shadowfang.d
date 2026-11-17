/**
 * Shadowfang Keep (map 33): its doors, opened as their guardians fall (the cells with Rethilgore,
 * the Sorcerer's Gate with Fenrus, Arugal's Lair with Wolf Master Nandos) or by a freed prisoner
 * (the Courtyard Door); the two prisoners, who lead the way to the courtyard; and Archmage Arugal.
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

    courtyardDoor = 18895,
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
    @transient EntityRef courtyard, gate, lair;
    @transient EntityRef[3] cells;
    @transient EntityRef[2] prisoners;

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
    }

    void on(ref InstanceContext keep, const ref CreatureDied e)
    {
        switch (e.creature.entry)
        {
        case rethilgore:
            rethilgoreDead = true;
            foreach (cell; cells)
                if (cell)
                    keep.door(cell, true);
            foreach (prisoner; prisoners)
                if (prisoner)
                    keep.signal(prisoner, Signals.prisonersFree);
            break;
        case fenrus:
            fenrusDead = true;
            if (gate)
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
 * who asks to the courtyard, opens its door there, and leaves.
 */
@creature("npc_shadowfang_prisoner")
struct ShadowfangPrisoner
{
    enum uint unlock = 1;
    enum : int
    {
        freeAshcrombe = -1033000, openAshcrombe = -1033001, afterAshcrombe = -1033002, vanishAshcrombe = -1033014,
        freeAdamant = -1033003, openAdamant = -1033004, afterAdamant = -1033005, leaveAdamant = -1033006,
        fumbleAdamant = -1033015,
    }

    enum Step : ubyte { open, thanks, leave }
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
        if (!free || escort.active || opened)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Please unlock the courtyard door.", unlock);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != unlock || escort.active || opened)
            return;
        me.closeGossip(e.player);
        me.say(adamant == me.self.entry ? freeAdamant : freeAshcrombe, e.player);
        escort.start(me, e.player, 0);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point != uint.max && point + 1 == me.waypointCount && !opened)
        {
            opened = true;
            if (me.self.entry == adamant)
                me.say(fumbleAdamant);
            me.say(me.self.entry == adamant ? openAdamant : openAshcrombe, escort.player);
            steps.after(Step.open, 2.seconds);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.open:
            me.signalDungeon(ShadowfangKeep.Signals.courtyardOpened);
            me.say(me.self.entry == adamant ? afterAdamant : afterAshcrombe);
            steps.after(me.self.entry == adamant ? Step.thanks : Step.leave, 3.seconds);
            break;
        case Step.thanks:
            me.say(leaveAdamant);
            steps.after(Step.leave, 3.seconds);
            break;
        case Step.leave:
            if (me.self.entry == ashcrombe)
                me.say(vanishAshcrombe);
            me.despawn(1000);
            break;
        }
    }
}

/**
 * Archmage Arugal: Void Bolt at his foe; his curse on someone he fights, turning him into a worgen;
 * Thundershock when he is crowded. He yells as he starts, and over each of his kills.
 */
@creature("boss_arugal")
struct ArchmageArugal
{
    enum : int { yellAggro = -1033017, yellKill = -1033018, yellCurse = -1033019 }
    enum : uint { voidBolt = 7588, arugalsCurse = 7621, thundershock = 7803 }

    enum Step : ubyte { bolt, curse, shock }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(yellAggro);
        steps.every(Step.bolt, 1.seconds, 5.seconds);
        steps.every(Step.curse, 7.seconds, 20.seconds);
        steps.every(Step.shock, 2.seconds, 2.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.bolt:
            me.castSpell(voidBolt);
            break;
        case Step.curse:
            if (const target = me.randomTarget())
                if (me.castSpell(arugalsCurse, target) == ActionResult.ok)
                    me.say(yellCurse);
            break;
        case Step.shock:
            if (me.victim && me.distanceTo(me.victim) < 5)
                if (me.castSpell(thundershock, me.self) == ActionResult.ok)
                    steps.every(Step.shock, 30.seconds); // not again soon
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
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}
