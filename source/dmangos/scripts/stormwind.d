/**
 * Stormwind: Lady Katrana Prestor, whose advice the player on "The True Masters" (4185) seeks; the
 * conversation, three gossip steps, is the quest's event.
 */
module dmangos.scripts.stormwind;

import dmangos.script;

/// Lady Katrana Prestor: her conversation for "The True Masters", and her usual menu otherwise.
@creature("npc_lady_katrana_prestor")
struct LadyKatranaPrestor
{
    enum uint questTrueMasters = 4185;
    enum : uint { textGreeting = 2693, textAdvice = 2694, textWarning = 2695, textFarewell = 2696 }
    enum : uint { askAdvice = 1, apologize = 2, beg = 3 }

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (me.questStatus(e.player, questTrueMasters) != QuestProgress.incomplete)
            return; // her usual menu
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Pardon the intrusion, Lady Prestor, but Highlord Bolvar suggested that I seek your advice.",
            askAdvice);
        me.sendGossip(e.player, textGreeting, menu);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        GossipMenu menu;
        switch (e.action)
        {
        case askAdvice:
            menu.add(GossipIcon.chat, "My apologies, Lady Prestor.", apologize);
            me.sendGossip(e.player, textAdvice, menu, false);
            break;
        case apologize:
            menu.add(GossipIcon.chat, "Begging your pardon, Lady Prestor. That was not my intent.", beg);
            me.sendGossip(e.player, textWarning, menu, false);
            break;
        case beg:
            me.sendGossip(e.player, textFarewell, menu, false);
            me.questEvent(e.player, questTrueMasters);
            break;
        default:
            break;
        }
    }
}
