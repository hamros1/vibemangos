/**
 * Durotar and Orgrimmar: the lazy peons of the Valley of Trials, woken with the Foreman's Blackjack
 * ("Lazy Peons", 5441); and Overlord Runthalak and High Overlord Saurfang, who speak of the dragon's
 * head on the gate while it hangs there.
 */
module dmangos.scripts.durotar;

import dmangos.script;

/**
 * A lazy peon: sleeps by his tree; woken (by the blackjack, the quest's credit, or by himself after
 * a while) he goes to the lumber pile, kneels there, and chops wood until he is tired again (eighty
 * seconds), then walks back and sleeps.
 */
@creature("npc_lazy_peon")
struct LazyPeon
{
    enum uint sleepingPeon = 10556, lumberpile = 175784, spellPeonSleep = 17743, spellAwakenPeon = 19938;
    enum int sayAwoken = -1000795;
    enum : uint { emoteKneel = 16, emoteStateNone = 0, emoteStateChopwood = 234 }
    enum : uint { pointPile = 1, pointHome = 2 }

    enum Step : ubyte { wake, sleep, kneel, chop }
    Schedule!Step steps;
    Location home;
    bool asleep, homeKnown;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        home = me.location;
        homeKnown = true;
        fallAsleep(me);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == spellAwakenPeon && e.caster.isPlayer && asleep)
            awaken(me, e.caster);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        if (e.point == pointPile)
            steps.after(Step.kneel, 2500.msecs);
        else if (e.point == pointHome)
            fallAsleep(me);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.wake:
            awaken(me, EntityRef.init);
            break;
        case Step.kneel:
            me.emote(emoteKneel);
            steps.after(Step.chop, 3.seconds);
            break;
        case Step.chop:
            me.emoteState(emoteStateChopwood);
            break;
        case Step.sleep:
            steps.cancel(Step.kneel);
            steps.cancel(Step.chop);
            me.emoteState(emoteStateNone);
            if (homeKnown)
                me.moveTo(home, pointHome);
            else
                fallAsleep(me);
            break;
        }
    }

    private void fallAsleep(ref CreatureContext me)
    {
        asleep = true;
        me.emoteState(emoteStateNone);
        me.castSelf(spellPeonSleep);
        steps.after(Step.wake, (100 + me.random(21)).seconds);
    }

    private void awaken(ref CreatureContext me, EntityRef player)
    {
        asleep = false;
        steps.cancel(Step.wake);
        if (player)
        {
            me.say(sayAwoken, player);
            me.killCredit(player, sleepingPeon);
        }
        me.removeAura(me.self, spellPeonSleep);
        steps.after(Step.sleep, 80.seconds);
        Location pile;
        const pileRef = me.objectNearby(lumberpile, 15);
        if (pileRef && me.locationOf(pileRef, pile))
            me.moveTo(Location(pile.x + 1, pile.y, pile.z), pointPile, cast(bool) player); // runs when woken
        else
            steps.after(Step.chop, 1.seconds);
    }
}

/// Overlord Runthalak and High Overlord Saurfang: while a dragon's head hangs on Orgrimmar's gate, they speak of it.
@creature("npc_overlord_runthalak", "npc_high_overlord_saurfang")
struct OrgrimmarHeadGossip
{
    enum uint runthalak = 14392, headOfNefarian = 179881, headOfOnyxia = 179556, menuHead = 6024;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        const head = me.self.entry == runthalak ? headOfNefarian : headOfOnyxia;
        if (!me.objectNearby(head, 100))
            return; // the usual menu
        me.gossipMenu(e.player, menuHead);
        me.consume();
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.durotar;

    auto p = Driven!self("npc_lazy_peon", 10_556);
    p.host.objects[LazyPeon.lumberpile] = EntityRef(0xF110_0000_0000_0003);
    p.raise(Spawned());
    assert(p.host.has("cast 17743"));
    p.raise(SpellHit(hero, LazyPeon.spellAwakenPeon));
    assert(p.host.has("credit 10556") && p.host.has("say -1000795") && p.host.has("move 1"));
    const before = p.host.did.length;
    p.raise(SpellHit(hero, LazyPeon.spellAwakenPeon));
    assert(p.host.did.length == before, "awake already: once");
    p.raise(MovementDone(LazyPeon.pointPile));
    p.run(6000);
    assert(p.host.has("emote 16") && p.host.has("emote state 234"));
    p.run(80_000);
    assert(p.host.has("move 2"));
    p.raise(MovementDone(LazyPeon.pointHome));
    assert(p.host.has("emote state 0"));
    p.run(121_000);
    assert(p.host.did[$ - 1] == "move 1", "up by himself");

    auto saurfang = Driven!self("npc_high_overlord_saurfang", 14_720);
    assert(!saurfang.raise(GossipHello(hero)));
    saurfang.host.objects[OrgrimmarHeadGossip.headOfOnyxia] = EntityRef(0xF110_0000_0000_0004);
    assert(saurfang.raise(GossipHello(hero)) && saurfang.host.has("menu 6024"));
}
