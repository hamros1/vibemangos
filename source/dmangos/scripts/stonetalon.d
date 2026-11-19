/**
 * Stonetalon Mountains: the escort of Kaya Flathoof to the Grimtotem's ambush and on to Camp
 * Aparaje ("Protect Kaya", 6523).
 */
module dmangos.scripts.stonetalon;

import dmangos.script;

/// Kaya Flathoof: Grimtotem lie in wait on her way; past them, she is safe.
@creature("npc_kaya")
struct Kaya
{
    enum uint questProtectKaya = 6523;
    enum : uint { grimtotemRuffian = 11910, grimtotemBrute = 11912, grimtotemSorcerer = 11913 }
    enum : int { sayStart = -1000357, sayAmbush = -1000358, sayEnd = -1000359 }

    Escort escort = { despawnAfterMs: 1000 };

    void on(ref CreatureContext me, const ref QuestAccepted e)
    {
        if (e.quest != questProtectKaya || escort.active)
            return;
        me.setFaction(EscortFaction.hordePassive);
        me.unitFlags(UnitFlag.immuneToNpc, false);
        me.say(sayStart);
        escort.start(me, e.player, e.quest);
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        const point = escort.reached(me, e);
        if (point + 1 == 17)
        {
            me.say(sayAmbush);
            me.attack(me.summon(grimtotemRuffian, Location(-50.75f, -500.77f, -46.13f, 0.4f), 30_000), me.self);
            me.attack(me.summon(grimtotemBrute, Location(-40.05f, -510.89f, -46.05f, 1.7f), 30_000), me.self);
            me.attack(me.summon(grimtotemSorcerer, Location(-32.21f, -499.20f, -45.35f, 2.8f), 30_000), me.self);
        }
        else if (point + 1 == 19)
        {
            me.say(sayEnd);
            me.groupQuestEvent(escort.player, questProtectKaya);
        }
    }

    void on(ref CreatureContext me, const ref Died e)
    {
        escort.fail(me);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.stonetalon;

    auto k = Driven!self("npc_kaya", 11_856, 19);
    k.raise(QuestAccepted(hero, Kaya.questProtectKaya));
    k.walkTo(18);
    assert(k.host.summons == 3 && k.host.has("say -1000359") && k.host.has("event 6523"));
}
