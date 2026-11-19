/**
 * Silithus: Nelson the Nice, who shows a hunter on "Stave of the Ancients" (7636) his real face,
 * Solenor the Slayer, a demon to be fought alone: anyone else joining in, the demon leaves and The
 * Cleaner comes for them all.
 */
module dmangos.scripts.silithus;

import dmangos.script;

/// Nelson the Nice and, after the question, Solenor the Slayer.
@creature("npc_solenor")
struct Solenor
{
    enum uint questStaveOfTheAncients = 7636, nelson = 14536, solenor = 14530, theCleaner = 14503, showFace = 1,
        gossipFlag = 1, emoteLaugh = 11;
    enum : uint { spellSoulFlame = 23272, spellDreadfulFright = 23275, spellCreepingDoom = 23589,
        spellCripplingClip = 23279, spellWingClip3 = 14268, spellFrostTrap = 13810 }
    enum int emoteImmobilized = -1001252;

    enum Step : ubyte { laugh, transform, soulFlame, creepingDoom, dreadfulFright, leave }
    Schedule!Step steps;
    EntityRef hunter;
    bool demon;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (demon || me.questStatus(e.player, questStaveOfTheAncients) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Show me your real face, demon.", showFace);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != showFace || demon)
            return;
        me.closeGossip(e.player);
        hunter = e.player;
        me.npcFlags(0);
        me.follow(EntityRef.init); // he stops his walk
        steps.after(Step.laugh, 5.seconds);
        steps.after(Step.transform, 10.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.laugh:
            me.emote(emoteLaugh);
            break;
        case Step.transform:
            demon = true;
            me.changeEntry(solenor);
            me.castSelf(spellSoulFlame);
            steps.after(Step.soulFlame, 150.msecs); // again, so that the player sees it
            steps.after(Step.leave, 20 * 60.seconds);
            break;
        case Step.soulFlame:
            me.castSelf(spellSoulFlame);
            break;
        case Step.creepingDoom:
            if (!me.inCombat)
                return;
            me.castSelf(spellCreepingDoom);
            steps.after(Step.creepingDoom, 15.seconds);
            break;
        case Step.dreadfulFright:
            if (!me.inCombat)
                return;
            if (me.victim && me.distanceTo(me.victim) > 5 && me.castSpell(spellDreadfulFright) == ActionResult.ok)
                steps.after(Step.dreadfulFright, (15 + me.random(6)).seconds);
            else
                steps.after(Step.dreadfulFright, 1.seconds);
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 10.seconds);
            me.despawn(1);
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!demon)
            return;
        if (e.enemy.isPlayer && hunter && e.enemy != hunter)
            return leave(me, e.enemy);
        if (e.enemy.isPlayer)
            hunter = e.enemy;
        steps.after(Step.creepingDoom, (3 + me.random(4)).seconds);
        steps.after(Step.dreadfulFright, (10 + me.random(6)).seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        // Another player joining the fight (a pet is the hunter's own help).
        if (demon && e.attacker.isPlayer && hunter && e.attacker != hunter)
            leave(me, e.attacker);
        else if (demon && me.hasAura(me.self, spellSoulFlame) && me.hasAura(me.self, spellFrostTrap))
            me.removeAura(me.self, spellSoulFlame);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (demon && e.spell == spellWingClip3 && me.castSelf(spellCripplingClip, true) == ActionResult.ok)
            me.say(emoteImmobilized);
    }

    /// Unfair: the demon goes, and The Cleaner comes for those who fought it.
    private void leave(ref CreatureContext me, EntityRef intruder)
    {
        const cleaner = me.summon(theCleaner, Location.init, 20 * 60_000);
        me.attack(cleaner, intruder);
        if (hunter)
            me.attack(cleaner, hunter);
        steps.clear();
        me.despawn(1);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.silithus;

    auto s = Driven!self("npc_solenor", 14_536);
    s.host.quests[Solenor.questStaveOfTheAncients] = QuestProgress.incomplete;
    assert(s.raise(GossipHello(hero)));
    s.raise(GossipSelect(hero, 0, 0, Solenor.showFace));
    s.run(10_000);
    assert(s.host.has("emote 11") && s.host.has("entry 14530") && s.host.has("cast 23272"));
    s.raise(EnteredCombat(hero));
    s.raise(Damaged(EntityRef(8), 100, 100, 95));
    assert(s.host.has("summon 14503") && s.host.has("despawn"), "another player: the Cleaner");
}
