/**
 * The Deadmines (map 36): its doors, opened as the bosses guarding them fall and kept open for the
 * copy's life; the Defias Cannon, which blows the Iron Clad Door open and raises the alarm; and
 * Mr. Smite, who sounds that alarm and changes weapons twice as his fight goes on.
 */
module dmangos.scripts.deadmines;

import dmangos.script;

/// Creatures and objects of the dungeon.
enum : uint
{
    rhahkZor = 644,
    sneed = 643,
    gilnid = 1763,
    mrSmite = 646,

    factoryDoor = 13965,  /// behind Rhahk'Zor
    mastRoomDoor = 16400, /// behind Sneed
    foundryDoor = 16399,  /// behind Gilnid
    ironCladDoor = 16397, /// the cannon blows it open
}

/// What the copy remembers: which guardians have fallen (saved in `instance.data`).
@instance("instance_deadmines")
struct Deadmines
{
    enum Signals : uint { cannonFired = 1 }
    enum : int { sayAlarm1 = -1036000, sayAlarm2 = -1036001 }
    /// The guards of the Iron Clad Door (the world database's spawns): two run to it when it is blown, one walks.
    enum : uint { guardFast1 = 3600148, guardFast2 = 3600149, guardSlow = 3600150 }

    bool[3] guardianDead;              /// Rhahk'Zor, Sneed, Gilnid
    bool ironCladOpen;
    @transient EntityRef[4] doors;     /// as they load (their guids are their spawns')
    @transient EntityRef smite;        /// Mr. Smite, once loaded
    @transient EntityRef[3] guards;    /// the door's guards, once loaded

    enum Step : ubyte { blowDoor, secondAlarm }
    Schedule!Step steps;

    private static immutable uint[3] guardians = [rhahkZor, sneed, gilnid];
    private static immutable uint[4] doorEntries = [factoryDoor, mastRoomDoor, foundryDoor, ironCladDoor];

    void on(ref InstanceContext copy, const ref ObjectLoaded e)
    {
        foreach (i, entry; doorEntries)
            if (e.object.entry == entry)
            {
                doors[i] = e.object;
                if (open(i))
                    copy.door(e.object, true);
            }
    }

    void on(ref InstanceContext copy, const ref CreatureLoaded e)
    {
        if (e.creature.entry == mrSmite)
            smite = e.creature;
        foreach (i, spawn; [guardFast1, guardFast2, guardSlow])
            if ((e.creature.guid & 0xFF_FFFF) == spawn)
                guards[i] = e.creature;
    }

    void on(ref InstanceContext copy, const ref CreatureDied e)
    {
        foreach (i, entry; guardians)
            if (e.creature.entry == entry && !guardianDead[i])
            {
                guardianDead[i] = true;
                copy.log("guardian " ~ (i == 0 ? "Rhahk'Zor" : i == 1 ? "Sneed" : "Gilnid") ~ " fell: its door opens");
                if (doors[i])
                    copy.door(doors[i], true);
            }
    }

    void on(ref InstanceContext copy, const ref Signal e)
    {
        if (e.id == Signals.cannonFired && !ironCladOpen)
        {
            ironCladOpen = true;
            // The door goes half a second on, with the cannon's shot.
            steps.after(Step.blowDoor, 500.msecs);
        }
    }

    void on(ref InstanceContext copy, Step step)
    {
        final switch (step)
        {
        case Step.blowDoor:
            copy.log("the cannon blew the Iron Clad Door open");
            if (doors[3])
                copy.door(doors[3], true);
            if (smite)
                copy.say(smite, sayAlarm1); // "You there! Check out that noise."
            // Its guards come to see: two at a run, one walking.
            Location at;
            if (doors[3] && copy.locationOf(doors[3], at))
                foreach (i, guard; guards)
                    if (guard && copy.alive(guard))
                        copy.moveTo(guard, at, 0, i < 2);
            steps.after(Step.secondAlarm, 15.seconds);
            break;
        case Step.secondAlarm:
            if (smite)
                copy.say(smite, sayAlarm2); // "We're under attack! A vast, ye swabs! Repel the invaders!"
            break;
        }
    }

    private bool open(size_t door) const
    {
        return door < 3 ? guardianDead[door] : ironCladOpen;
    }
}

/**
 * Mr. Smite (as ScriptDev2 has him, from sniffs): Nimble Reflexes on him until his first stomp. Below two thirds of his
 * health he stomps (Smite Stomp: everyone near stunned), runs to his chest, kneels, and takes up two axes (Thrash on
 * him while he wields them); below one third he stomps again and takes up his great hammer (Smite's Hammer), and
 * slams his foe (Smite Slam) every eleven seconds.
 */
@creature("boss_mr_smite")
struct MrSmite
{
    enum : int { sayPhaseTwo = -1036002, sayPhaseThree = -1036003 }
    enum : uint { smiteStomp = 6432, nimbleReflexes = 6433, smiteSlam = 6435, smitesHammer = 6436, thrash = 12787 }
    enum : uint { axe = 2183, hammer = 10756 } /// "Monster - Axe, Metal Badass", "Monster - Mace2H, Smite's Mighty Hammer"
    enum uint smiteChest = 144111;
    enum uint pointChest = 1;

    enum Phase : ubyte { one, two, three, toChest, atChest, rearmed }
    enum Step : ubyte { slam, toChest, rearm, fight }
    Schedule!Step steps;
    Phase phase;

    void on(ref CreatureContext me, const ref Reset e)
    {
        phase = Phase.one;
        steps.clear();
        me.restoreEquipment();
        me.standState(StandState.stand);
        me.sheath(Sheath.melee);
        me.combatMovement(true);
        me.melee(true);
        if (!me.hasAura(me.self, nimbleReflexes))
            me.castSelf(nimbleReflexes, true);
    }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (!me.hasAura(me.self, nimbleReflexes))
            me.castSelf(nimbleReflexes, true);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if ((phase == Phase.one && e.after < 66) || (phase == Phase.two && e.after < 33))
        {
            me.castSelf(smiteStomp);
            me.say(e.after < 33 ? sayPhaseThree : sayPhaseTwo);
            me.removeAura(me.self, phase == Phase.one ? nimbleReflexes : thrash);
            phase = Phase.toChest;
            steps.clear();
            me.melee(false);
            me.combatMovement(false);
            steps.after(Step.toChest, 2500.msecs);
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point != pointChest || phase != Phase.toChest)
            return;
        me.sheath(Sheath.unarmed);
        me.standState(StandState.kneel);
        me.equip(0, 0, 0);
        phase = Phase.atChest;
        steps.after(Step.rearm, 3.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.slam:
            me.castSpell(smiteSlam);
            break;
        case Step.toChest:
            Location chest;
            const found = me.objectNearby(smiteChest, 100);
            if (found && me.locationOf(found, chest))
            {
                // Beside it, on his side.
                const here = me.location;
                const dx = here.x - chest.x, dy = here.y - chest.y;
                const length = (dx * dx + dy * dy) ^^ 0.5f;
                if (length > 1.5f)
                {
                    chest.x += dx / length * 1.5f;
                    chest.y += dy / length * 1.5f;
                }
                me.moveNow(chest, pointChest, true);
            }
            else
            {
                MovementDone there;
                there.point = pointChest;
                on(me, there); // no chest: he rearms where he stands
            }
            break;
        case Step.rearm:
            if (me.healthPercent < 33)
            {
                me.equip(hammer);
                me.castSelf(smitesHammer);
            }
            else
                me.equip(axe, axe);
            me.standState(StandState.stand);
            phase = Phase.rearmed;
            steps.after(Step.fight, 1.seconds);
            break;
        case Step.fight:
            me.sheath(Sheath.melee);
            phase = me.healthPercent < 33 ? Phase.three : Phase.two;
            if (phase == Phase.two)
                me.castSelf(thrash, true);
            else
                steps.every(Step.slam, 9.seconds, 11.seconds);
            me.combatMovement(true);
            me.melee(true);
            const foe = me.selectTarget(Pick.topThreat);
            if (foe)
                me.attack(foe);
            else
                me.evade();
            break;
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }
}

/// The Defias Cannon: fired, it blows the Iron Clad Door open (its dungeon script opens it).
@gameObject("go_defias_cannon")
struct DefiasCannon
{
    bool fired;

    void on(ref GameObjectContext cannon, const ref ObjectUsed e)
    {
        if (fired)
            return;
        fired = true;
        cannon.signalDungeon(Deadmines.Signals.cannonFired);
    }
}

/// Unarmed Woodcutter (a Goblin Woodcarver's): while it lasts the woodcarver's hands are empty.
@spell("spell_unarmed_woodcutter")
struct UnarmedWoodcutter
{
    void on(ref SpellContext it, const ref AuraApplied e)
    {
        if (e.effect == 0 && e.target.isCreature)
            it.armed(e.target, false);
    }

    void on(ref SpellContext it, const ref AuraEnded e)
    {
        if (e.effect == 0 && e.target.isCreature)
            it.armed(e.target, true);
    }
}
