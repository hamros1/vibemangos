/**
 * Un'Goro Crater: the scent of Lar'korwi's mate, which the hunter on "The Scent of Lar'korwi"
 * (4291) follows from spot to spot until the mate comes out.
 */
module dmangos.scripts.ungoro;

import dmangos.script;

/// A scent spot: walked into on the quest, the mate comes out there, unless it is out already.
@areaTrigger("at_scent_larkorwi")
struct ScentOfLarkorwi
{
    enum uint questScent = 4291, larkorwiMate = 9683;

    void on(ref AreaTriggerContext spot, const ref TriggerEntered e)
    {
        if (spot.questStatus(e.player, questScent) != QuestProgress.incomplete)
            return;
        if (spot.creatureNear(larkorwiMate, e.at, 25))
            return;
        spot.summon(larkorwiMate, e.at, 2 * 60_000, e.player); // it goes two minutes after a fight
    }
}
