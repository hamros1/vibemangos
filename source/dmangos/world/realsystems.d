/**
 * The smaller systems tested on the real data (the client's DBC files and the world database): the auction houses'
 * rates, battleground scoreboards, Alterac Valley's turn-ins, forced reactions and Silithus' texts. Run only where
 * `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realsystems;

version (unittest):

import dmangos.world.realspelltests : haveRealData, RealWorld;

/// The scoreboard columns `WorldStateUI.dbc` gives map `map` (rows whose type, field 24, is 2), in the file's order:
/// their names (field 4).
private string[] scoreColumns(uint map)
{
    import std.array : split;
    import std.file : read;
    import std.bitmanip : littleEndianToNative;
    import std.process : environment;
    import std.string : indexOf;

    const bytes = cast(const(ubyte)[]) read(environment["DMANGOS_REAL_DATA"].split("|")[0] ~ "/dbc/WorldStateUI.dbc");
    uint at(size_t offset) { return littleEndianToNative!uint(bytes[offset .. offset + 4][0 .. 4]); }
    string text(size_t offset)
    {
        const tail = cast(const(char)[]) bytes[offset .. $];
        const end = tail.indexOf('\0');
        assert(end >= 0, "a string runs past the end of WorldStateUI.dbc");
        return tail[0 .. end].idup;
    }
    const rows = at(4), fields = at(8), size = at(12);
    const strings = 20 + rows * size;
    string[] names;
    foreach (i; 0 .. rows)
    {
        const row = 20 + i * size;
        if (at(row + 4) == map && at(row + 24 * 4) == 2)
            names ~= text(strings + at(row + 4 * 4));
    }
    assert(fields == 39);
    return names;
}

/// The scoreboard's own columns of each battleground are the client's (`WorldStateUI.dbc`): as many as
/// `MSG_PVP_LOG_DATA` sends (`extraScores`), in the order the rules count them.
unittest
{
    import dmangos.world.alterac : scoreGravesAssaulted, scoreGravesDefended, scoreLeaders, scoreMines, scoreSecondary,
        scoreTowersAssaulted, scoreTowersDefended;
    import dmangos.world.arathi : scoreAssaulted, scoreDefended;
    import dmangos.world.battleground : extraScores;
    import dmangos.world.bgqueue : BattlegroundType;
    import dmangos.world.warsong : scoreCaptures, scoreReturns;

    if (!haveRealData())
        return;
    const av = scoreColumns(30);
    assert(av.length == extraScores[BattlegroundType.alteracValley]);
    assert(av[scoreGravesAssaulted] == "Graveyards Assaulted" && av[scoreGravesDefended] == "Graveyards Defended");
    assert(av[scoreTowersAssaulted] == "Towers Assaulted" && av[scoreTowersDefended] == "Towers Defended");
    assert(av[scoreMines] == "Mines Captured" && av[scoreLeaders] == "Leaders Killed"
        && av[scoreSecondary] == "Secondary Objectives");
    const wsg = scoreColumns(489);
    assert(wsg.length == extraScores[BattlegroundType.warsongGulch]);
    assert(wsg[scoreCaptures] == "Flag Captures" && wsg[scoreReturns] == "Flag Returns");
    const ab = scoreColumns(529);
    assert(ab.length == extraScores[BattlegroundType.arathiBasin]);
    assert(ab[scoreAssaulted] == "Bases Assaulted" && ab[scoreDefended] == "Bases Defended");
}

/// Alterac Valley's officers ("Leaders Killed") are the database's lieutenants, commanders, marshals, warmasters,
/// captains and generals, each of its side's faction (1216, 1534 the Stormpike's; 1214 the Frostwolf's).
unittest
{
    import dmangos.world.alterac : officers;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    static immutable uint[][2] factionsOf = [[1216, 1534, 1597, 1334], [1214, 1335]];
    foreach (side; 0 .. 2)
        foreach (entry; officers[side])
        {
            const t = entry in w.context.data.creatureTemplates;
            assert(t !is null, "an officer the database has");
            bool ofSide;
            foreach (f; factionsOf[side])
                ofSide = ofSide || t.faction == f;
            import std.conv : to;

            assert(ofSide, "of its side: " ~ entry.to!string ~ " faction " ~ t.faction.to!string);
        }
}

/// The auction houses' rates are AuctionHouse.dbc's: the factions' houses 5% deposit (for each 2 hours) and 5% cut,
/// the goblins' (Blackwater, 7) 25% and 15%; so 2, 8 and 24 hours cost 5%, 20% and 60% of the sell price at a
/// faction's house, five times that at the goblins'. docs/FORMULAS.md, "Auction houses".
unittest
{
    import dmangos.world.auctionhouse : AuctionRecord, auctionDeposit, minAuctionTime;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (id; [1u, 2, 3, 4, 5, 6])
    {
        const house = w.context.client.auctionHouses.lookup(id);
        assert(house !is null && house.depositPercent == 5 && house.cutPercent == 5, "a faction's house: 5% and 5%");
    }
    const goblins = w.context.client.auctionHouses.lookup(7);
    assert(goblins !is null && goblins.depositPercent == 25 && goblins.cutPercent == 15, "the goblins': 25% and 15%");
    const stormwind = w.context.client.auctionHouses.lookup(1);
    // An item sold to a vendor for 1 gold (10000 copper), for 2, 8 and 24 hours.
    assert(auctionDeposit(*stormwind, minAuctionTime, 10_000, 1) == 500);
    assert(auctionDeposit(*stormwind, 4 * minAuctionTime, 10_000, 1) == 2000);
    assert(auctionDeposit(*stormwind, 12 * minAuctionTime, 10_000, 1) == 6000);
    assert(auctionDeposit(*goblins, minAuctionTime, 10_000, 1) == 2500);
    assert(auctionDeposit(*goblins, 12 * minAuctionTime, 10_000, 1) == 30_000);
    AuctionRecord a = {bid: 10_000};
    assert(a.cut(*stormwind) == 500 && a.cut(*goblins) == 1500);
}

/**
 * The Corrupted Ashbringer (22691), wielded: its equip aura (28282, `spell_ashbringer_item`) casts AB Effect 001
 * (28442: `SPELL_AURA_FORCE_REACTION`, faction 56) as friendly; the Scarlet Crusade's reaction is forced and the
 * client told (`SMSG_SET_FORCED_REACTIONS`). Put away, it is not.
 */
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientItemPos;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.testclient : bodyOf;

    if (!haveRealData())
        return;
    enum uint ashbringer = 22691, itemAura = 28282, effect001 = 28442, scarletCrusade = 56;
    enum ubyte classPaladin = 2;
    auto w = RealWorld.make();
    auto c = w.character(30, "Mograine", classPaladin, 60, [202]); // Two-Handed Swords
    auto me = c.session.inWorld;
    me.player.setSkill(55, 300, 300); // ditto, the skill
    me.storeLoot(ashbringer, 1, 0, false);
    c.read();
    ubyte slot;
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == ashbringer)
                slot = s;
    assert(slot, "the Ashbringer carried");
    c.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    const packets = c.read();
    assert(me.player.inventory.equipped(15) !is null, "wielded");
    assert(me.player.auras.find(itemAura) !is null, "its equip aura");
    assert(me.player.auras.find(effect001) !is null, "AB Effect 001, cast by the aura's script");
    assert(me.reputations.forcedReactions.get(scarletCrusade, ReputationRank.hated) == ReputationRank.friendly);
    // The client told, last of all both forced: the Argent Dawn's (529) by the item's own aura, then the Crusade's.
    const(ubyte)[] told;
    foreach (p; packets)
        if (p.opcode == Opcode.SMSG_SET_FORCED_REACTIONS)
            told = p.body_;
    assert(told !is null, "the client told");
    auto r = ByteReader(told);
    uint[uint] listed;
    foreach (i; 0 .. r.read!uint)
    {
        const faction = r.read!uint;
        listed[faction] = r.read!uint;
    }
    assert(listed.get(scarletCrusade, 99) == ReputationRank.friendly && 529 in listed);

    // Into the backpack again: the reaction is the Crusade's own.
    c.write(Opcode.CMSG_AUTOSTORE_BAG_ITEM, cast(const(ubyte)[]) [inventorySlotBag0, ubyte(15), inventorySlotBag0]);
    c.read();
    assert(me.player.inventory.equipped(15) is null, "put away");
    assert(me.player.auras.find(effect001) is null && scarletCrusade !in me.reputations.forcedReactions);
}

/**
 * Alterac Valley's turn-ins on the real data: the quests take what the rules count (20 Armor Scraps; one or five
 * Storm Crystals or Stormpike Soldier's Blood); every graveyard has four kinds of defenders a side (Stormpike
 * Defender, Seasoned, Veteran, Champion; the Frostwolf Guardians alike) for the upgrades to spawn; General's Warcry is
 * 10%, 20%, 30% more damage; a general cries it, and a lord comes onto the Field of Strife.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.alterac;
    import dmangos.world.bgqueue : BattlegroundType;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.spellids : AuraType;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint armorScraps = 17_422, stormCrystal = 17_423, soldiersBlood = 17_306;
    foreach (side; 0 .. 2)
    {
        foreach (q; questsScraps[side])
        {
            const quest = w.context.data.quests.quest(q);
            assert(quest.reqItemId[0] == armorScraps && quest.reqItemCount[0] == scrapsPerTurnIn);
        }
        const offering = side == ownerAlliance ? stormCrystal : soldiersBlood;
        assert(w.context.data.quests.quest(questsOfferOne[side]).reqItemId[0] == offering
            && w.context.data.quests.quest(questsOfferOne[side]).reqItemCount[0] == 1);
        assert(w.context.data.quests.quest(questsOfferFive[side]).reqItemId[0] == offering
            && w.context.data.quests.quest(questsOfferFive[side]).reqItemCount[0] == 5);
        assert(lords[side] in w.context.data.creatureTemplates);
    }

    // The defenders of each kind, by the spawns' battleground events.
    uint[ubyte][ubyte] spawned; // event1 -> event2 -> spawns
    string[ubyte] kind;         // event2 -> a name
    uint[uint] entryOf;
    foreach (ref s; w.context.data.creatureSpawns)
        entryOf[s.guid] = s.entry;
    foreach (guid, e; w.context.data.creatureBattleEvents)
        if (e[0] >= eventGraveDefenders && e[0] < eventGraveDefenders + 7)
        {
            ++spawned.require(e[0], null).require(e[1], 0);
            if (const entry = guid in entryOf)
                kind[e[1]] = w.context.data.creatureTemplates[*entry].name;
        }
    foreach (ubyte n; 0 .. nodeCount)
        if (!isTower(n))
            foreach (ubyte e2; 0 .. 8)
                assert(spawned[cast(ubyte)(eventGraveDefenders + n)].get(e2, 0) > 0, "defenders of every kind");
    assert(kind[1] == "Seasoned Defender" && kind[2] == "Veteran Defender" && kind[3] == "Champion Defender");
    assert(kind[5] == "Seasoned Guardian" && kind[6] == "Veteran Guardian" && kind[7] == "Champion Guardian");

    foreach (i, spell; spellsGeneralsWarcry)
    {
        const s = w.context.data.spells.spell(spell);
        assert(s !is null && s.casting.applyAuraName[0] == AuraType.modDamagePercentDone);
        assert(s.basePoints[0] + 1 == 10 * (i + 1), "10%, 20%, 30%");
    }

    // On the valley's map: Vanndar cries the first rank once the Alliance has upgraded; Ivus comes onto the field.
    auto copy = w.context.battlegrounds.open(901, BattlegroundType.alteracValley);
    auto rules = cast(AlteracRules) copy.rules;
    auto map = w.context.map(30, 901);
    const vanndar = copy.summonAt(npcVanndar, 722.43f, -10.998f, 50.70f, 0);
    assert(vanndar);
    copy.testing = true;
    copy.members[7] = imported!"dmangos.world.battleground".Battleground.Member(0);
    copy.start();
    foreach (_; 0 .. 25)
        rules.questRewarded(copy, 7, questsScraps[ownerAlliance][0]);
    assert(rules.upgrades[ownerAlliance] == 1);
    auto general = cast(Creature) map.findObject(vanndar);
    assert(general.auras.find(spellsGeneralsWarcry[0]) !is null, "Vanndar cries General's Warcry");

}

/// Both field rituals use the original summoners and ten distinct active participants inside the same match.
unittest
{
    if (!haveRealData())
        return;
    import core.time : msecs;
    import std.format : format;
    import dmangos.world.alterac;
    import dmangos.world.bgqueue : BattlegroundEntry, BattlegroundType;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.map : MapObject;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGuid, ClientTeleportAck;
    import dmangos.world.testclient : TestClient;

    foreach (ubyte side; 0 .. 2)
    {
        auto w = RealWorld.make(20261122, true);
        const instance = 950u + side;
        auto copy = w.context.battlegrounds.open(instance, BattlegroundType.alteracValley);
        auto rules = cast(AlteracRules) copy.rules;
        auto map = w.context.map(30, instance);
        copy.testing = true;
        copy.start();
        TestClient[] raiders;
        void arrive(size_t i, ubyte team)
        {
            auto client = w.character(cast(uint)(700 + i), format!"Raid%s"(cast(char)('a' + i)), 1, 60, [], team == 0 ? 1 : 2);
            client.session.inWorld.enterBattleground(BattlegroundEntry(true, instance, team, BattlegroundType.alteracValley));
            client.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
            client.session.inWorld.godModeCheat = true;
            assert(client.session.inWorld.currentMap is map && (client.session.inWorld.player.guid in copy.members));
            raiders ~= client;
        }
        void move(size_t i, Position p)
        {
            auto c = raiders[i].session.inWorld;
            c.teleportTo(30, p, null, instance, true);
            raiders[i].write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(c.player.guid, 0, 0));
        }
        arrive(0, side);
        Position camp;
        foreach (ref row; w.context.data.creatureSpawns)
            if (row.map == 30 && row.entry == summoners[side])
            {
                camp = Position(row.x, row.y, row.z);
                break;
            }
        assert(camp.x != 0);
        move(0, camp);
        const contributor = raiders[0].session.inWorld.player.guid;
        foreach (_; 0 .. 40)
            rules.questRewarded(copy, contributor, questsOfferFive[side]);
        assert(!rules.lordCalled[side]);
        const dest = lordsAt[side];
        Position field = Position(dest[0], dest[1], dest[2], dest[3]);
        GameObject altar;
        auto findAltar = () {
            map.forEachObject((MapObject o) {
                auto g = cast(GameObject) o;
                if (g !is null && g.template_.entry == altars[side])
                    altar = g;
            });
        };
        findAltar();
        assert(altar is null && rules.processions[side].leader != 0);
        auto leader = map.creatureAt(rules.processions[side].leader);
        foreach (i; 0 .. 2400)
        {
            w.now += 500.msecs;
            w.context.update(w.now);
            if (i % 10 == 0)
            {
                raiders[0].read();
                findAltar();
                if (altar !is null)
                    break;
                // The raid accompanies the summoners through the valley.
                move(0, leader.position);
            }
        }
        assert(altar !is null, format!"side %s escort stopped at %s, target %s, alive %s"(side, leader.position, field, leader.alive));
        foreach (i; 1 .. 11)
            arrive(i, i == 10 ? cast(ubyte)(1 - side) : side);
        foreach (i; 0 .. raiders.length)
            move(i, field);
        void use(size_t i) { raiders[i].write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(altar.guid)); }
        foreach (i; 0 .. 9)
            use(i);
        use(0);
        use(10);
        assert(altar.ritualUsers.length == 9 && !rules.lordCalled[side], "repeated click or opposing faction counted");
        raiders[0].session.inWorld.endChannel(true);
        use(9);
        assert(altar.ritualUsers.length == 9 && !rules.lordCalled[side], "cancelled participant counted");
        use(0);
        assert(rules.lordCalled[side] && map.findObject(altar.guid) is null && copy.members[contributor].extra[scoreSecondary] == 1);
        use(9);
        uint count;
        foreach (c; map.creaturesNear(field, 20))
            if (c.template_.entry == lords[side])
                ++count;
        assert(count == 1, "ten raiders call one faction lord");
        import core.time : minutes;
        import dmangos.world.motion : MotionType;
        auto lord = map.creatureAt(rules.processions[side].lord);
        rules.tick(copy, 10.minutes);
        assert(lord.generator.type == MotionType.point, "the faction lord did not begin its march");
    }
}
