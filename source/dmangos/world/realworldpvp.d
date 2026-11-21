/**
 * World PvP (`dmangos.world.worldpvp`) on the real data: the towers of the Eastern Plaguelands and Silithus's Silithyst,
 * with the client's DBC files and the world database's capture points, spells, game objects, scripts and quests. Run
 * only where `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realworldpvp;

version (unittest):

import core.time : seconds;
import dmangos.auth.accounts : AccountLevel;
import dmangos.world.character : Character;
import dmangos.world.gameobject : GameObject;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : CharacterData, Player;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.testclient;
import dmangos.world.testdata : raceHuman, raceOrc;
import dmangos.world.worldpvp;

private:

/// A level 60 character of `race` at `at` on `map` in `zone`, logged in, the world's clock the test's.
TestClient player(ref RealWorld w, uint guid, string name, ubyte race, uint map, uint zone, Position at)
{
    auto clock = &w.now;
    w.context.clock = () => *clock;
    auto c = loggedIn(w.context, w.db, guid, name, at, AccountLevel.player, race, map, 60,
        (ref CharacterData d) { d.zone = zone; });
    c.read();
    return c;
}

/// `n` seconds of the world, a tick each.
void pass(ref RealWorld w, int n)
{
    foreach (_; 0 .. n)
    {
        w.now += 1.seconds;
        w.context.update(w.now);
    }
}

/// The world states the client was told of since it last read (`SMSG_UPDATE_WORLD_STATE`), the last value of each; and
/// the bonus honor it was told of (`SMSG_PVP_CREDIT`).
struct Told
{
    uint[uint] states;
    uint honor;
    string[] notices;
    string[] said; /// what creatures said or yelled
}

/// ditto
Told told(ref TestClient c)
{
    import dmangos.bytes : ByteReader;

    Told t;
    foreach (p; c.read())
    {
        auto r = ByteReader(p.body_);
        if (p.opcode == Opcode.SMSG_UPDATE_WORLD_STATE)
        {
            const id = r.read!uint;
            t.states[id] = r.read!uint;
        }
        else if (p.opcode == Opcode.SMSG_PVP_CREDIT)
            t.honor += r.read!uint;
        else if (p.opcode == Opcode.SMSG_DEFENSE_MESSAGE)
        {
            const zone = r.read!uint, length = r.read!uint;
            assert((zone == zoneEasternPlaguelands || zone == zoneSilithus) && length == p.body_.length - 8
                && p.body_[$ - 1] == 0);
            t.notices ~= cast(string) p.body_[8 .. $ - 1].idup;
        }
        else if (p.opcode == Opcode.SMSG_MESSAGECHAT)
        {
            import dmangos.world.opcodes : ChatType;

            const type = cast(ChatType) r.read!ubyte;
            if (type != ChatType.CHAT_MSG_MONSTER_SAY && type != ChatType.CHAT_MSG_MONSTER_YELL)
                continue;
            r.read!uint; // language
            r.read!ulong; // the speaker
            r.readBytes(r.read!uint); // its name
            r.read!ulong; // the target
            const text = r.readBytes(r.read!uint);
            t.said ~= cast(string) text[0 .. $ - 1].idup;
        }
    }
    return t;
}

Character me(ref TestClient c)
{
    return cast(Character) c.session.inWorld;
}

bool has(ref TestClient c, uint spell)
{
    return (cast(Player) c.session.character).auras.find(spell) !is null;
}

/// The game objects of `entry` within `range` of `at` on `map`.
GameObject[] objects(ref RealWorld w, uint map, Position at, float range, uint entry)
{
    GameObject[] found;
    foreach (o; w.context.map(map).objectsNear(at, range))
        if (auto go = cast(GameObject) o)
            if (go.spawn.entry == entry)
                found ~= go;
    return found;
}

/// The service's state, to set a slider or a count where a test begins.
ref WorldPvp served(ref RealWorld w)
{
    return w.context.services.local!WorldPvpHost().state;
}

/// What the data says the code has: the capture points' rules (their templates' data), the shrines' spawns, the spells.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    with (w.context.data)
    {
        foreach (ref t; towers)
        {
            const p = t.capturePoint in gameObjectTemplates;
            assert(p !is null && p.type == 29, t.name);
            assert(p.data[0] == captureRadius && p.data[2] == stateBarShown && p.data[3] == stateBarSlider);
            assert(p.data[8] == t.capturedEvent[0] && p.data[9] == t.capturedEvent[1], t.name);
            assert(p.data[12] == neutralPercent && p.data[13] == stateBarNeutral);
            assert(p.data[14] == minSuperiority && p.data[15] == maxSuperiority);
            assert(p.data[16] == minCaptureSeconds && p.data[17] == maxCaptureSeconds && p.data[20] == sliderStart);
            bool spawned;
            foreach (ref s; gameObjectSpawns)
                spawned = spawned || (s.entry == t.capturePoint && s.x == t.x && s.y == t.y && s.map == towersMap);
            assert(spawned, t.name);
        }
        // The captures' scripts: Eastwall's squads (a leader and four), Plaguewood's flight master.
        alias Event = imported!"dmangos.world.dbscripts".DbScriptType;
        foreach (team; 0 .. 2)
        {
            assert(dbScripts.steps(Event.event, towers[Tower.eastwall].capturedEvent[team]).length == 5);
            assert(dbScripts.steps(Event.event, towers[Tower.plaguewood].capturedEvent[team]).length == 1);
        }
        foreach (team; 0 .. 2)
        {
            bool found;
            foreach (ref s; gameObjectSpawns)
                found = found || (s.guid == shrineSpawns[team] && s.entry == shrineEntries[team] && s.respawnSeconds < 0);
            assert(found, "the shrine's spawn, not in the world by default");
            foreach (spell; echoesOfLordaeron[team])
                assert(spells.spell(spell) !is null);
        }
        foreach (spell; [spellSilithyst, spellTracesOfSilithyst, spellCenarionFavor])
            assert(spells.spell(spell) !is null);
        // Dropping it makes a mound (`SUMMON_OBJECT_WILD`).
        const drop = spells.spell(spellSilithystDrop);
        assert(drop !is null && drop.miscValue[0] == silithystMound);
    }
    foreach (id; turnInTriggers)
        assert(w.context.client.areaTriggers.lookup(id) !is null);
    assert(w.context.client.worldSafeLocs.lookup(crownGuardGraveyard) !is null);
}

/// Taking Plaguewood Tower: an Alliance player in range sees the capture bar, pushes the slider over time and takes it;
/// the map, the banners, Echoes of Lordaeron, the honor, the quest credit, the zone's notice and the flight master
/// follow. Pushed back by the Horde into the neutral band, it is nobody's again, and what it brought goes.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const tower = towers[Tower.plaguewood];
    const top = Position(tower.x, tower.y, tower.z, 0);
    auto a = player(w, 1, "Arnaud", raceHuman, towersMap, zoneEasternPlaguelands, top);
    me(a).addQuest(w.context.data.quests.quests[9664]); // Establishing New Outposts
    auto bystander = player(w, 2, "Bystander", raceHuman, towersMap, zoneEasternPlaguelands,
        Position(tower.x + 200, tower.y, tower.z, 0));
    told(a);
    told(bystander);

    // Not flagged for PvP: in range (the bar), but not counted.
    w.pass(2);
    assert(me(a).worldPvpTower == Tower.plaguewood && !me(a).worldPvpCounted);
    assert(told(a).states.get(stateBarShown, 0) == 1, "the capture bar shown");
    w.pass(20);
    assert(w.served.towers[Tower.plaguewood].slider == sliderStart);

    // Flagged: the slider moves, a percent each 12 seconds, and the bar follows.
    a.write(Opcode.CMSG_TOGGLE_PVP, null);
    w.pass(14);
    const moved = w.served.towers[Tower.plaguewood].slider;
    assert(moved > 50.9f && moved < 51.2f);
    assert(told(a).states.get(stateBarSlider, 0) == 51);
    assert(told(bystander).states.get(stateBarSlider, 0) == 0, "out of range: no bar");

    // At the neutral band's edge: it is taken.
    w.served.towers[Tower.plaguewood].slider = 59.95f;
    w.pass(3);
    assert(w.context.worldPvp.state.towers[Tower.plaguewood].holder == Holder.alliance);
    auto seen = told(a);
    assert(seen.states.get(tower.lookStates[TowerLook.allianceProgressing], 0) == 1
        && seen.states[tower.lookStates[TowerLook.neutral]] == 0, "the map: the Alliance's, progressing");
    assert(seen.states.get(stateTowersAlliance, 0) == 1);
    assert(seen.honor == captureHonor, "189 bonus honor");
    assert(seen.notices == ["|cffffff00The Plaguewood Tower has been taken by the Alliance!|r"], "the zone told");
    assert((cast(Player) a.session.character).questStatus[9664].mobCount[3] == 1, "Capture Plaguewood Tower");
    assert(told(bystander).honor == 0, "not counted there: no honor");
    w.pass(2);
    assert(a.has(echoesOfLordaeron[PvpTeam.alliance][0]), "Echoes of Lordaeron, a tower's rank");
    assert(bystander.has(echoesOfLordaeron[PvpTeam.alliance][0]), "everyone of the side in the zone");
    import dmangos.world.updatefields : GAMEOBJECT_ARTKIT;

    auto banners = w.objects(towersMap, top, bannerRange, towerBanner) ~ w.objects(towersMap, top, 5, tower.capturePoint);
    assert(banners.length == 3);
    foreach (go; banners)
        assert(go.values.get!GAMEOBJECT_ARTKIT == bannerArtKits[Holder.alliance], "the Alliance's banners");
    size_t kielars()
    {
        size_t n;
        foreach (c; w.context.map(towersMap).creaturesNear(top, 60))
            n += c.template_.entry == williamKielar;
        return n;
    }
    assert(kielars == 1, "the flight master comes (event 10701)");

    // The Horde, two to one, pushes it back into the neutral band: nobody's.
    foreach (uint guid; 3 .. 5)
    {
        auto h = player(w, guid, guid == 3 ? "Hrok" : "Grukk", raceOrc, towersMap, zoneEasternPlaguelands, top);
        h.write(Opcode.CMSG_TOGGLE_PVP, null);
    }
    w.served.towers[Tower.plaguewood].slider = 60.05f;
    w.pass(4);
    assert(w.context.worldPvp.state.towers[Tower.plaguewood].holder == Holder.none);
    assert(w.context.worldPvp.state.towers[Tower.plaguewood].look == TowerLook.neutral);
    w.pass(2);
    assert(!a.has(echoesOfLordaeron[PvpTeam.alliance][0]), "no tower, no Echoes");
    assert(kielars == 0, "the flight master goes");
    foreach (go; w.objects(towersMap, top, bannerRange, towerBanner))
        assert(go.values.get!GAMEOBJECT_ARTKIT == bannerArtKits[Holder.none]);
}

/// Northpass's shrine is its holder's; Crown Guard's graveyard its holder's (closed when nobody holds it); in the
/// Fungal Vale its holder's dead go there.
unittest
{
    import dmangos.world.death : closestGraveyard;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const np = towers[Tower.northpass];
    auto h = player(w, 1, "Hrok", raceOrc, towersMap, zoneEasternPlaguelands, Position(np.x, np.y, np.z, 0));
    w.pass(1);
    assert(w.objects(towersMap, Position(np.x, np.y, np.z, 0), 60, shrineEntries[1]).length == 0);
    w.served.towers[Tower.northpass].holder = Holder.horde;
    w.served.towers[Tower.northpass].slider = 0;
    w.served.towers[Tower.crownGuard].holder = Holder.horde;
    w.context.services.local!WorldPvpHost().start(); // told
    assert(w.objects(towersMap, Position(np.x, np.y, np.z, 0), 60, shrineEntries[1]).length == 1, "the Horde's shrine");
    assert(w.objects(towersMap, Position(np.x, np.y, np.z, 0), 60, shrineEntries[0]).length == 0);
    w.pass(2);
    assert(h.has(echoesOfLordaeron[PvpTeam.horde][1]), "two towers: the second rank");

    // Near Crown Guard's graveyard: the Horde's while it holds the tower, nobody's otherwise.
    const near = Position(1990, -3660, 120, 0);
    const teams = w.context.worldPvp.graveyardTeams;
    auto horde = closestGraveyard(w.context.data, w.context.client, towersMap, near, 67, zoneEasternPlaguelands, 0, teams);
    auto alliance = closestGraveyard(w.context.data, w.context.client, towersMap, near, 469, zoneEasternPlaguelands, 0,
        teams);
    assert(horde !is null && horde.id == crownGuardGraveyard && alliance !is null && alliance.id != crownGuardGraveyard);
    assert(me(h).worldPvpGraveyard(areaFungalVale).id == crownGuardGraveyard);
    w.served.towers[Tower.crownGuard].holder = Holder.none;
    w.context.services.local!WorldPvpHost().start();
    const closed = w.context.worldPvp.graveyardTeams;
    horde = closestGraveyard(w.context.data, w.context.client, towersMap, near, 67, zoneEasternPlaguelands, 0, closed);
    assert(horde.id != crownGuardGraveyard, "nobody's: closed");
    assert(me(h).worldPvpGraveyard(areaFungalVale) is null);
}

/// Silithyst: a geyser gives it (and the PvP flag); the Horde's camp takes it from a Horde player (Traces of Silithyst,
/// the Cenarion Circle, honor, the count everyone in Silithus sees), the Alliance's does not; a carrier who dies drops a
/// mound another player picks up.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const geyserAt = Position(-6999.92f, 823.196f, 13.1457f, 0);
    auto h = player(w, 1, "Dusty", raceOrc, silithusMap, zoneSilithus, geyserAt);
    auto a = player(w, 2, "Thief", raceHuman, silithusMap, zoneSilithus, Position(-7000, 826, 13, 0));
    w.pass(1);
    auto geysers = w.objects(silithusMap, geyserAt, 5, silithystGeyser);
    assert(geysers.length == 1);
    me(h).useGameObject(geysers[0]);
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

        const flags = (cast(Player) h.session.character).values.get!UNIT_FIELD_FLAGS;
        assert(h.has(spellSilithyst), "carrying it (its own immunity, 0x200000 on itself, does not purge it)");
        assert(flags & UnitFlags.pvp, "flagged");
    }

    // The wrong camp: nothing.
    auto dusty = cast(Player) h.session.character;
    const allianceCamp = w.context.client.areaTriggers.lookup(turnInTriggers[PvpTeam.alliance]);
    dusty.movement.position = Position(allianceCamp.x, allianceCamp.y, allianceCamp.z, 0);
    h.write(Opcode.CMSG_AREATRIGGER, imported!"dmangos.world.packets".ClientAreaTrigger(turnInTriggers[PvpTeam.alliance]));
    assert(h.has(spellSilithyst));

    // Its own: turned in.
    const reputation = dusty.reputation.standingWith(factionCenarionCircle);
    const camp = w.context.client.areaTriggers.lookup(turnInTriggers[PvpTeam.horde]);
    dusty.movement.position = Position(camp.x, camp.y, camp.z, 0);
    told(a);
    h.read();
    h.write(Opcode.CMSG_AREATRIGGER, imported!"dmangos.world.packets".ClientAreaTrigger(turnInTriggers[PvpTeam.horde]));
    assert(!h.has(spellSilithyst) && h.has(spellTracesOfSilithyst));
    assert(dusty.reputation.standingWith(factionCenarionCircle) == reputation + silithystReputation);
    assert(told(h).honor == 198, "a bonus honor unit at 60");
    assert(w.context.worldPvp.state.silithus.collected == [0, 1]);
    assert(told(a).states.get(stateSilithystCollected[PvpTeam.horde], 0) == 1, "Silithus sees the count");

    // Picked up at another geyser; the carrier dies: a mound where it fell, which the Alliance player picks up.
    auto other = w.objects(silithusMap, Position(-7135.93f, 780.037f, 7.27633f, 0), 5, silithystGeyser);
    assert(other.length == 1);
    dusty.movement.position = Position(-7135, 780, 7.3f, 0);
    me(h).useGameObject(other[0]);
    assert(h.has(spellSilithyst));
    me(h).playerDied(false);
    assert(!h.has(spellSilithyst));
    auto mounds = w.objects(silithusMap, dusty.position, 6, silithystMound);
    assert(mounds.length == 1, "a mound where it fell");
    (cast(Player) a.session.character).movement.position = dusty.position;
    me(a).useGameObject(mounds[0]);
    assert(a.has(spellSilithyst), "anyone may pick it up");
}

/// The goal: the 200th turn-in favors its side, Cenarion Favor on its players in Silithus (not the other side's), and
/// the counts start again.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const camp = w.context.client.areaTriggers.lookup(turnInTriggers[PvpTeam.alliance]);
    const at = Position(camp.x, camp.y, camp.z, 0);
    auto a = player(w, 1, "Anduin", raceHuman, silithusMap, zoneSilithus, at);
    auto h = player(w, 2, "Garrosh", raceOrc, silithusMap, zoneSilithus, at);
    w.pass(1);
    w.served.silithus.collected = [199, 150];
    w.context.services.local!WorldPvpHost().start(); // told
    me(a).battlegroundCastHere(spellSilithyst);
    assert(a.has(spellSilithyst));
    a.write(Opcode.CMSG_AREATRIGGER, imported!"dmangos.world.packets".ClientAreaTrigger(turnInTriggers[PvpTeam.alliance]));
    assert(w.context.worldPvp.state.silithus.favored == Holder.alliance);
    assert(w.context.worldPvp.state.silithus.collected == [0, 0], "a new race");
    assert(told(h).states.get(stateSilithystCollected[PvpTeam.horde], 99) == 0);
    w.pass(2);
    assert(a.has(spellCenarionFavor) && !h.has(spellCenarionFavor));
    assert(!a.has(spellSilithyst));
}

/**
 * The camps' announcers: Marshal Bluewall says the Alliance has a quarter, half, three quarters of the 200
 * (`broadcast_text` 13479 .. 13481) as its count reaches 50, 100 and 150, and cheers the win (13470), the zone told
 * "The Alliance has collected 200 silithyst!" (`mangos_string` 1636). A carrier who logs out drops a mound.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    const camp = w.context.client.areaTriggers.lookup(turnInTriggers[PvpTeam.alliance]);
    auto a = player(w, 1, "Anduin", raceHuman, silithusMap, zoneSilithus, Position(camp.x, camp.y, camp.z, 0));
    w.pass(1);
    bool bluewallHere;
    foreach (c; w.context.map(silithusMap).creaturesNear(Position(camp.x, camp.y, camp.z, 0), 60))
        bluewallHere = bluewallHere || c.template_.entry == silithusAnnouncers[PvpTeam.alliance];
    assert(bluewallHere, "Marshal Bluewall at the Alliance's camp");
    told(a);

    void turnIn()
    {
        me(a).battlegroundCastHere(spellSilithyst);
        a.write(Opcode.CMSG_AREATRIGGER, imported!"dmangos.world.packets".ClientAreaTrigger(turnInTriggers[PvpTeam.alliance]));
    }

    w.served.silithus.collected = [48, 0];
    w.context.services.local!WorldPvpHost().start();
    told(a);
    turnIn();
    assert(told(a).said.length == 0, "49: nothing to say");
    turnIn();
    auto t = told(a);
    assert(t.said == ["We haveone quarter of the needed silithyst! Keep it up!"], "50 of 200 (13479, as the data has it)");
    w.served.silithus.collected = [99, 0];
    turnIn();
    assert(told(a).said == ["We have half of our needed silithyst.  We can do it!"]);
    w.served.silithus.collected = [149, 0];
    turnIn();
    assert(told(a).said == ["We have almost all the silithyst we need!  Don't stop now!"]);
    w.served.silithus.collected = [199, 0];
    turnIn();
    t = told(a);
    assert(t.said == ["We've done it!  Victory to the Alliance!"]);
    assert(t.notices == ["|cffffff00The Alliance has collected 200 silithyst!|r"]);

    // A carrier logging out: the Silithyst falls where it stood, and does not go with it.
    auto anduin = cast(Player) a.session.character;
    anduin.movement.position = Position(-7135, 780, 7.3f, 0);
    me(a).battlegroundCastHere(spellSilithyst);
    assert(a.has(spellSilithyst));
    a.write(Opcode.CMSG_LOGOUT_REQUEST, null); // at once: the test world's logout delay is 0
    assert(w.objects(silithusMap, Position(-7135, 780, 7.3f, 0), 6, silithystMound).length == 1, "a mound");
    assert(!w.db.auraRows.get(1, null).length || {
        foreach (r; w.db.auraRows[1])
            if (r.spell == spellSilithyst)
                return false;
        return true;
    }(), "not saved with the character");
}
