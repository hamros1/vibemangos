/**
 * The guards of the cities and the starting lands (ScriptDevAI's `guards` and `guard_ai`): killed by a
 * player, a guard has its zone told it is under attack; Orgrimmar's grunts answer the emotes of the Horde.
 * (Stormwind's guards are in `dmangos.scripts.npcs`; the contested towns' bruisers keep their EventAI.)
 */
module dmangos.scripts.guards;

import dmangos.script;

/// What every guard does (`guardAI`): its death at a player's hand puts its zone under attack.
@creature("guard_bluffwatcher", "guard_darnassus", "guard_dunmorogh", "guard_durotar", "guard_elwynnforest",
    "guard_ironforge", "guard_mulgore", "guard_teldrassil", "guard_tirisfal", "guard_undercity")
struct Guard
{
    void on(ref CreatureContext me, const ref Died e)
    {
        guardDied(me, e);
    }
}

/// An Orgrimmar grunt: a guard who answers a Horde player's emotes.
@creature("guard_orgrimmar")
struct GuardOrgrimmar
{
    enum uint factionOrgrimmar = 76;

    void on(ref CreatureContext me, const ref Died e)
    {
        guardDied(me, e);
    }

    void on(ref CreatureContext me, const ref EmoteReceived e)
    {
        if (me.standingOf(e.player, factionOrgrimmar) >= Standing.neutral) // one of the Horde
            replyToEmote(me, e.textEmote);
    }
}

/// A guard killed by a player (or a player's pet): its zone is under attack.
void guardDied(ref CreatureContext me, const ref Died e)
{
    if (e.killer)
        me.zoneUnderAttack(e.killer);
}

/// A guard's answer to a text emote (`DoReplyToTextEmote`): a bow for a kiss, a wave back, a salute
/// back, a flex for the shy, a point at the rude and the chicken.
void replyToEmote(ref CreatureContext me, uint textEmote)
{
    enum : uint { textChicken = 22, textKiss = 58, textRude = 77, textSalute = 78, textShy = 84, textWave = 101 }
    enum : uint { emoteBow = 2, emoteWave = 3, emoteFlex = 23, emotePoint = 25, emoteSalute = 66 }
    switch (textEmote)
    {
    case textKiss: me.emote(emoteBow); break;
    case textWave: me.emote(emoteWave); break;
    case textSalute: me.emote(emoteSalute); break;
    case textShy: me.emote(emoteFlex); break;
    case textRude, textChicken: me.emote(emotePoint); break;
    default: break;
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;

    alias self = dmangos.scripts.guards;

    auto grunt = Driven!self("guard_orgrimmar", 3296);
    grunt.raise(EmoteReceived(hero, 101));
    assert(grunt.host.has("emote 3"));
    grunt.host.standings[GuardOrgrimmar.factionOrgrimmar] = Standing.hated;
    grunt.raise(EmoteReceived(hero, 58));
    assert(!grunt.host.has("emote 2"), "not for the Alliance");
    grunt.raise(Died(hero));
    assert(grunt.host.has("zone under attack"));

    auto bluff = Driven!self("guard_bluffwatcher", 3084);
    bluff.raise(Died(EntityRef.init));
    assert(!bluff.host.has("zone under attack"), "nobody's kill");
}
