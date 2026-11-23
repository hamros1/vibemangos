/// The outdoor camps and their necropolises during the original Scourge Invasion.
module dmangos.scripts.scourgeinvasion;

import dmangos.script;

private enum uint intact = 16136, damaged = 16172, engineer = 16230, shadow = 16143, finder = 16356;
private immutable uint[3] spawners = [16306,16336,16338], themes = [28198,28197,28199];

@gameObject("scourge_invasion_go_circle")
struct GroundCircle
{
    void on(ref GameObjectContext it, const ref Spawned e)
    {
        if (!it.creatureNearby(intact, 3) && !it.creatureNearby(damaged, 3))
            it.summon(intact, it.location);
    }
}

@gameObject("scourge_invasion_go_necropolis")
struct FloatingNecropolis
{
    void on(ref GameObjectContext it, const ref Spawned e)
    {
        // The world data places both controllers alongside the model.
        if (const anchor = it.creatureNearby(16401, 40))
            it.castSpell(anchor, 28373, anchor);
    }
}

@creature("scourge_invasion_necrotic_shard")
struct Shard
{
    enum Step { wave, repair }
    Schedule!Step steps;
    long campaign;
    uint generation, theme, shadows;
    EntityRef[4] engineers;
    struct UsedFinder { ulong guid; uint nextWave; }
    UsedFinder[] usedFinders;
    uint wave;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        campaign = me.invasionCampaign(generation);
        me.reactState(Reaction.passive);
        me.combatMovement(false);
        me.melee(false);
        theme = me.random(3);
        me.castSelf(themes[theme], true);
        me.castSelf(28346, true);
        steps.every(Step.wave, 2.seconds, 5.seconds);
        if (me.self.entry == damaged)
        {
            summonEngineers(me);
            steps.every(Step.repair, 3600.seconds);
        }
    }

    private void summonEngineers(ref CreatureContext me)
    {
        static immutable float[2][4] offsets = [[4,0], [0,4], [-4,0], [0,-4]];
        foreach (i, offset; offsets)
        {
            if (engineers[i]) me.despawn(engineers[i]);
            auto pos = me.location;
            pos.x += offset[0];
            pos.y += offset[1];
            engineers[i] = me.summon(engineer, pos);
        }
    }

    void on(ref CreatureContext me, Step step)
    {
        uint current;
        if (!campaign || me.invasionCampaign(current) != campaign || generation != current)
        {
            foreach (npc; engineers) if (npc) me.despawn(npc);
            me.despawn(1);
            return;
        }
        if (step == Step.repair)
        {
            shadows = 0;
            me.setHealthPercent(100);
            summonEngineers(me);
            return;
        }
        ++wave;
        import std.algorithm.mutation : remove;
        usedFinders = usedFinders.remove!(f => f.nextWave <= wave);
        EntityRef[64] anchors;
        const count = me.creaturesNearby(finder, 60, anchors[]);
        if (!count) return;
        const attempts = 1 + me.random(3);
        foreach (_; 0 .. attempts)
        {
            const anchor = anchors[me.random(cast(uint) count)];
            import std.algorithm.searching : canFind;
            if (usedFinders.canFind!(f => f.guid == anchor.guid)) continue;
            Location pos;
            if (me.locationOf(anchor, pos))
            {
                me.summon(spawners[theme], pos, 10000);
                usedFinders ~= UsedFinder(anchor.guid, wave + 30 + me.random(11));
            }
        }

    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == 28326)
            me.castSelf(28449, true);
        if (e.spell == 28056 && me.self.entry == damaged && e.caster.entry == shadow)
        {
            if (++shadows >= 4) me.die();
            else me.setHealthPercent(100 - 25 * shadows);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        if (me.self.entry == intact)
        {
            if (const next = me.summon(damaged, me.location))
                me.signal(next, 1, theme);
        }
        else
        {
            foreach (npc; engineers) if (npc) me.despawn(npc);
            me.castSelf(28681, true);
            if (const relay = me.creatureNearby(16386, 200))
                me.castSpell(28351, relay, true);
            me.campDefeated(campaign, generation);
        }
    }

    void on(ref CreatureContext me, const ref Signal e)
    {
        if (e.from.entry == intact && e.id == 1 && e.value >= 0 && e.value < 3)
        {
            me.removeAura(me.self, themes[theme]);
            theme = e.value;
            me.castSelf(themes[theme], true);
        }
    }
}

@creature("scourge_invasion_minion_spawner")
struct MinionSpawner
{
    enum Step { emerge }
    Schedule!Step steps;
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        steps.after(Step.emerge, (2 + me.random(4)).seconds);
    }
    void on(ref CreatureContext me, Step step)
    {
        static immutable uint[2][3] ordinary = [[16298,16141],[16298,16299],[16141,16299]];
        static immutable uint[2][3] rare = [[16379,14697],[16379,16380],[14697,16380]];
        foreach (i, entry; spawners)
            if (entry == me.self.entry)
            {
                const pool = me.random(100) == 0 ? rare[i] : ordinary[i];
                me.summon(pool[me.random(2)], me.location, 3600000);
                me.castSelf(28234, true);
                me.despawn(500);
            }
    }
}

@creature("scourge_invasion_cultist_engineer")
struct Cultist
{
    bool used;
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.reactState(Reaction.passive);
        me.castSelf(28132, true);
        me.castSelf(28078, true); // Buttress Channel selects the nearby damaged shard by entry.
    }
    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.menu != 7166 || e.option != 0) return;
        me.consume();
        me.closeGossip(e.player);
        if (used || me.itemCount(e.player, 22484) < 8 || !me.creatureNearby(damaged, 12)) return;
        used = true;
        if (!me.disruptEngineer(e.player))
        {
            used = false;
            return;
        }
        me.die();
    }
}

@spell("spell_summon_boss")
struct SummonBoss
{
    void on(ref SpellContext it, const ref CastChecked e)
    {
        if (!e.caster.isPlayer || e.target.entry != engineer) it.refuse();
    }
}

@creature("scourge_invasion_minion")
struct InvasionMinion
{
    enum Step { attack, fear }
    Schedule!Step steps;
    void on(ref CreatureContext me, const ref Spawned e)
    {
        if (me.self.entry == shadow)
        {
            static immutable uint[] taunts = [12420,12421,12422,12243];
            me.castSelf(10389, true);
            me.sayText(taunts[me.random(4)]);
            if (me.owner.isPlayer) me.attack(me.owner);
            else if (const enemy = me.playerNearby(15)) me.attack(enemy);
        }
        else me.castSelf(28330, true);
    }
    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.attack, 4.seconds, me.self.entry == shadow ? 10.seconds : 30.seconds);
        if (me.self.entry == shadow) steps.every(Step.fear, 13.seconds, 22.seconds);
    }
    void on(ref CreatureContext me, Step step)
    {
        if (me.victim)
            me.castSpell(step == Step.fear ? 12542 : me.self.entry == shadow ? 16568 : 28314, me.victim);
    }
    void on(ref CreatureContext me, const ref Died e)
    {
        if (me.self.entry == shadow)
        {
            if (const shard = me.creatureNearby(damaged, 120)) me.castSpell(28056, shard, true);
        }
        else me.castSpell(28323, e.killer, true);
    }
}

@creature("scourge_invasion_necropolis")
struct Necropolis
{
    enum Step { pulse }
    Schedule!Step steps;
    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.flying(true);
        steps.every(Step.pulse, 5.seconds, 35.seconds);
    }
    void on(ref CreatureContext me, Step step) { me.castSelf(28373, true); }
    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == 28367) me.castSelf(28395, true);
    }
}

@creature("scourge_invasion_necropolis_relay")
struct Relay
{
    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == 28366) me.castSelf(28326, true);
        else if (e.spell == 28281) me.castSelf(28365, true);
        else if (e.spell == 28351 && e.caster.entry == damaged)
            if (const proxy = me.creatureNearby(16398, 200)) me.castSpell(28351, proxy, true);
    }
}

@creature("scourge_invasion_necropolis_proxy")
struct Proxy
{
    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == 28373) me.castSelf(28366, true);
        else if (e.spell == 28365) me.castSelf(28367, true);
        else if (e.spell == 28351 && e.caster.entry == 16386)
            if (const health = me.creatureNearby(16421, 250)) me.castSpell(28351, health, true);
    }
}

@creature("scourge_invasion_necropolis_health")
struct NecropolisHealth
{
    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell == 28351 && e.caster.entry == 16398)
            me.castSelf(28386, true);
    }
}

@creature("scourge_invasion_mouth")
struct Mouth
{
    enum Step { yell }
    Schedule!Step steps;
    void on(ref CreatureContext me, const ref Spawned e)
    {
        steps.after(Step.yell, (150 + me.random(3451)).seconds);
    }
    void on(ref CreatureContext me, Step step)
    {
        static immutable uint[] cries = [13126,13124,13122,13123];
        me.sayText(cries[me.random(4)]);
        steps.after(Step.yell, (150 + me.random(3451)).seconds);
    }
}
