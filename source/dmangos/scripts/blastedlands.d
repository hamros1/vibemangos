/**
 * Blasted Lands: Lord Kazzak, the world boss of the Tainted Scar.
 */
module dmangos.scripts.blastedlands;

import dmangos.script;

/**
 * Lord Kazzak: he announces himself when he comes; in a fight he binds the souls of those who die
 * near him, casts shadow volleys, cleaves, thunderclaps, void bolts, marks and twists his enemies;
 * after three minutes he goes berserk and his volleys come every second or two.
 */
@creature("boss_kazzak")
struct LordKazzak
{
    /// `script_texts` rows.
    enum : int
    {
        sayIntro = -1000147, sayAggro1 = -1000148, sayAggro2 = -1000149, saySupreme1 = -1000150,
        saySupreme2 = -1000151, sayKill1 = -1000152, sayDeath = -1000155,
    }
    enum : uint
    {
        spellShadowVolley = 21341, spellBerserk = 21340, spellCleave = 20691, spellThunderclap = 26554,
        spellVoidBolt = 21066, spellMarkOfKazzak = 21056, spellCaptureSoul = 21053,
        spellTwistedReflection = 21063,
    }

    enum Step : ubyte { supreme, shadowVolley, cleave, thunderclap, voidBolt, mark, reflection }
    Schedule!Step steps;
    bool berserk;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        me.say(sayIntro);
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.castSelf(spellCaptureSoul, true);
        me.say(me.random(2) ? sayAggro1 : sayAggro2);
        berserk = false;
        steps.clear();
        steps.after(Step.supreme, (3 * 60).seconds);
        steps.after(Step.shadowVolley, (3000 + me.random(9001)).msecs);
        steps.after(Step.cleave, 7.seconds);
        steps.after(Step.thunderclap, (16_000 + me.random(4001)).msecs);
        steps.after(Step.voidBolt, 30.seconds);
        steps.after(Step.mark, 25.seconds);
        steps.after(Step.reflection, 33.seconds);
    }

    void on(ref CreatureContext me, const ref KilledUnit e)
    {
        const line = me.random(4); // one time in four he says nothing
        if (e.victim.isPlayer && line < 3)
            me.say(sayKill1 - cast(int) line);
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        steps.clear();
        me.say(sayDeath);
    }

    void on(ref CreatureContext me, const ref Evaded e)
    {
        steps.clear();
    }

    void on(ref CreatureContext me, Step step)
    {
        if (!me.inCombat)
            return steps.clear();
        final switch (step)
        {
        case Step.supreme:
            if (me.castSelf(spellBerserk) == ActionResult.ok)
            {
                me.say(me.random(2) ? saySupreme1 : saySupreme2);
                berserk = true;
                steps.after(Step.shadowVolley, 1.seconds);
            }
            break;
        case Step.shadowVolley:
            again(me, step, me.castSelf(spellShadowVolley), berserk ? 1000 : 5000, berserk ? 3000 : 30_000);
            break;
        case Step.cleave:
            again(me, step, me.castSpell(spellCleave), 8000, 12_000);
            break;
        case Step.thunderclap:
            again(me, step, me.castSelf(spellThunderclap), 10_000, 14_000);
            break;
        case Step.voidBolt:
            again(me, step, me.castSpell(spellVoidBolt), 15_000, 28_000);
            break;
        case Step.mark:
            again(me, step, me.castSpell(spellMarkOfKazzak, me.randomTarget), 20_000, 20_000);
            break;
        case Step.reflection:
            const target = me.randomTarget;
            again(me, step, target.isPlayer ? me.castSpell(spellTwistedReflection, target) : ActionResult.notAllowed,
                15_000, 15_000);
            break;
        }
    }

    /// `step` again after `low` to `high` ms if it was cast; soon if not.
    private void again(ref CreatureContext me, Step step, ActionResult result, uint low, uint high)
    {
        steps.after(step, result == ActionResult.ok ? (low + me.random(high - low + 1)).msecs : 1.seconds);
    }
}

/// Mark of Kazzak: it drains its target's mana; one drained dry bursts (hurting those around it), and the mark goes.
@spell("spell_mark_of_lord_kazzak")
struct MarkOfKazzak
{
    enum uint markExplosion = 21058;

    void on(ref SpellContext it, const ref AuraTickEnded e)
    {
        if (it.power(e.target, Power.mana) != 0) // mana left, or none to have (-1)
            return;
        it.castSpell(e.target, markExplosion, EntityRef.init);
        it.removeAura(e.target, it.spellId);
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto k = Driven!(dmangos.scripts.blastedlands).make("boss_kazzak");
    k.raise(Spawned());
    assert(k.host.did("say -1000147"));
    k.host.fighting = true;
    k.raise(EnteredCombat(k.host.player));
    assert(k.host.did("cast 21053"));
    k.tick(40_000);
    import std.conv : to;

    foreach (spell; [21341, 20691, 26554, 21066, 21056, 21063])
        assert(k.host.did("cast " ~ spell.to!string), spell.to!string);
    assert(!k.host.did("cast 21340"), "not berserk yet");
    k.tick(150_000);
    assert(k.host.did("cast 21340"));
    k.raise(Died());
    assert(k.host.did("say -1000155"));
}
