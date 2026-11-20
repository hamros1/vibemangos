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

    bool[3] guardianDead;              /// Rhahk'Zor, Sneed, Gilnid
    bool ironCladOpen;
    @transient EntityRef[4] doors;     /// as they load (their guids are their spawns')
    @transient EntityRef smite;        /// Mr. Smite, once loaded

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
            copy.log("the cannon blew the Iron Clad Door open");
            if (doors[3])
                copy.door(doors[3], true);
            if (smite)
                copy.signal(smite, MrSmite.Signals.alarm);
        }
    }

    private bool open(size_t door) const
    {
        return door < 3 ? guardianDead[door] : ironCladOpen;
    }
}

/**
 * Mr. Smite: slams his foe; at two thirds and one third of his health he stuns everyone near with a
 * stomp, kneels to take up new weapons (two axes, then a great hammer), and fights on.
 */
@creature("boss_mr_smite")
struct MrSmite
{
    enum Signals : uint { alarm = 1 }
    enum : int { sayAlarm = -1036001, sayPhaseTwo = -1036002, sayPhaseThree = -1036003 }
    enum : uint { smiteStomp = 6432, smiteSlam = 6435 }
    enum : uint { reaver = 5196, mightyHammer = 7230 }

    enum Step : ubyte { slam, rearm }
    Schedule!Step steps;
    ubyte phase; /// 0, then 1 (axes), then 2 (hammer)

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.slam, 6.seconds, 9.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if ((phase == 0 && e.crossed(66)) || (phase == 1 && e.crossed(33)))
        {
            ++phase;
            steps.clear();
            me.castSelf(smiteStomp, true);
            me.say(phase == 1 ? sayPhaseTwo : sayPhaseThree);
            me.combatMovement(false);
            me.melee(false);
            me.standState(StandState.kneel);
            steps.after(Step.rearm, 2500.msecs);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.slam:
            me.castSpell(smiteSlam);
            break;
        case Step.rearm:
            if (phase == 1)
                me.equip(reaver, reaver);
            else
                me.equip(mightyHammer);
            me.standState(StandState.stand);
            me.combatMovement(true);
            me.melee(true);
            steps.every(Step.slam, 6.seconds, 9.seconds);
            break;
        }
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        phase = 0;
        steps.clear();
        me.restoreEquipment();
        me.standState(StandState.stand);
        me.combatMovement(true);
        me.melee(true);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.id == Signals.alarm)
            me.say(sayAlarm); // the whole ship hears it
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
