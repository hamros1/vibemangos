/**
 * Stranglethorn Vale: Yenniku, the Darkspear prisoner whom the player on "Saving Yenniku" (592)
 * entrances with the Soul Gem.
 */
module dmangos.scripts.stranglethorn;

import dmangos.script;

/**
 * Yenniku: hit by Yenniku's Release from a player on the quest, he stops fighting and, entranced,
 * follows the Horde for a minute (his faction), then is himself again.
 */
@creature("mob_yenniku")
struct Yenniku
{
    enum uint spellYennikusRelease = 3607, questSavingYenniku = 592, factionHordeGeneric = 83;
    enum uint emoteStun = 64;

    enum Step : ubyte { awaken }
    Schedule!Step steps;

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (e.spell != spellYennikusRelease || !e.caster.isPlayer || steps.pending(Step.awaken))
            return;
        if (me.questStatus(e.caster, questSavingYenniku) != QuestProgress.incomplete)
            return;
        me.evade();
        me.setFaction(factionHordeGeneric);
        me.emote(emoteStun);
        steps.after(Step.awaken, 60.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        me.setFaction(0);
        me.evade();
    }
}

unittest
{
    import dmangos.scripts.testhost : Driven;

    auto y = Driven!(dmangos.scripts.stranglethorn).make("mob_yenniku");
    y.host.fighting = true;
    y.raise(SpellHit(y.host.player, 3607));
    assert(y.host.did("evade") && y.host.faction == 83);
    y.tick(60_000);
    assert(y.host.faction == 0);
}
