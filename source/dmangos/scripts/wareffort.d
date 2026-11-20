/**
 * The Ahn'Qiraj war effort's scripts: the capitals' officers who take the resources in, and the Scarab
 * Gong. What they hand on is counted, server-wide, by the war effort itself (`dmangos.world.wareffort`);
 * the Colossi of Silithus, whose fall it remembers, are in `dmangos.scripts.silithus`.
 */
module dmangos.scripts.wareffort;

import dmangos.script;

/// The officers (`npc_war_effort`): each of their quests hands in one resource, its first required items'
/// count of it.
@creature("npc_war_effort")
struct WarEffortOfficer
{
    /// The quests (two for each resource: the first time, and again) and the resource each counts as, in
    /// `AQResources`' order.
    enum uint[3][] handIns = [
        // Horde
        [8549, 8550, 0],   // Peacebloom
        [8611, 8612, 1],   // Lean Wolf Steaks
        [8542, 8543, 2],   // Tin Bars
        [8604, 8605, 3],   // Wool Bandages
        [8580, 8581, 4],   // Firebloom
        [8588, 8589, 5],   // Heavy Leather
        [8545, 8546, 6],   // Mithril Bars
        [8607, 8608, 7],   // Mageweave Bandages
        [8600, 8601, 8],   // Rugged Leather
        [8615, 8616, 9],   // Baked Salmon
        // Alliance
        [8511, 8512, 10],  // Light Leather
        [8517, 8518, 11],  // Linen Bandages
        [8513, 8514, 12],  // Medium Leather
        [8503, 8504, 13],  // Stranglekelp
        [8524, 8525, 14],  // Rainbow Fin Albacore
        [8494, 8495, 15],  // Iron Bars
        [8526, 8527, 16],  // Roast Raptor
        [8520, 8521, 17],  // Silk Bandages
        [8499, 8500, 18],  // Thorium Bars
        [8509, 8510, 19],  // Arthas' Tears
        // Both, each side its own
        [8492, 8493, 20],  // Copper Bars (Alliance)
        [8505, 8506, 21],  // Purple Lotus (Alliance)
        [8515, 8516, 22],  // Thick Leather (Alliance)
        [8528, 8529, 23],  // Spotted Yellowtail (Alliance)
        [8522, 8523, 24],  // Runecloth Bandages (Alliance)
        [8532, 8533, 25],  // Copper Bars (Horde)
        [8582, 8583, 26],  // Purple Lotus (Horde)
        [8590, 8591, 27],  // Thick Leather (Horde)
        [8613, 8614, 28],  // Spotted Yellowtail (Horde)
        [8609, 8610, 29],  // Runecloth Bandages (Horde)
    ];

    /// The resource quest `quest` hands in; -1 for another quest.
    static int resourceOf(uint quest) pure nothrow @nogc @safe
    {
        foreach (h; handIns)
            if (h[0] == quest || h[1] == quest)
                return h[2];
        return -1;
    }

    void on(ref CreatureContext me, const ref QuestRewarded e)
    {
        const resource = resourceOf(e.quest);
        if (resource >= 0)
            me.warEffortHandIn(e.quest, resource);
    }
}

/// The Scarab Gong: "Bang a Gong!" rung in its time begins the ten-hour war, Silithus hearing of it.
@gameObject("go_scarab_gong")
struct ScarabGong
{
    enum uint questBangAGong = 8743, sayBangGong = 11427, sayQirajiBreak = 11432, phaseGongTime = 3;

    void on(ref GameObjectContext it, const ref QuestRewarded e)
    {
        if (e.quest != questBangAGong || it.warEffortPhase != phaseGongTime)
            return;
        it.zoneNotice(sayBangGong);
        it.zoneNotice(sayQirajiBreak);
        it.warEffortGong(e.player);
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.wareffort;

    // Every resource has its two quests, and no quest is counted twice.
    bool[uint] seen;
    foreach (i, h; WarEffortOfficer.handIns)
    {
        assert(h[2] == i && h[0] !in seen && h[1] !in seen);
        seen[h[0]] = seen[h[1]] = true;
    }
    assert(WarEffortOfficer.handIns.length == 30);

    auto officer = Driven!self("npc_war_effort", 15_383);
    officer.raise(QuestRewarded(hero, 8533));
    assert(officer.host.has("war effort 8533 25"), "Copper Bars, the Horde's count");
    officer.raise(QuestRewarded(hero, 1));
    assert(officer.host.did.length == 1, "another quest: nothing");

    auto gong = DrivenObject!self("go_scarab_gong", 180_717);
    gong.raise(QuestRewarded(hero, ScarabGong.questBangAGong));
    assert(gong.host.did.length == 0, "not the gong's time");
    gong.host.warEffortPhase = ScarabGong.phaseGongTime;
    gong.raise(QuestRewarded(hero, ScarabGong.questBangAGong));
    assert(gong.host.did == ["notice 11427", "notice 11432", "gong"]);
}
