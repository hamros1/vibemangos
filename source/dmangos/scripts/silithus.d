/**
 * Silithus: Nelson the Nice, who shows a hunter on "Stave of the Ancients" (7636) his real face,
 * Solenor the Slayer, a demon to be fought alone: anyone else joining in, the demon leaves and The
 * Cleaner comes for them all. The opening of Ahn'Qiraj played again for "A Pawn on
 * the Eternal Board" (Anachronos the Ancient, called by the Crystalline Tear), and the Colossi waking
 * (and falling, which the war effort remembers).
 */
module dmangos.scripts.silithus;

import dmangos.script;

/// Nelson the Nice and, after the question, Solenor the Slayer.
@creature("npc_solenor")
struct Solenor
{
    enum uint questStaveOfTheAncients = 7636, nelson = 14536, solenor = 14530, theCleaner = 14503, showFace = 1,
        gossipFlag = 1, emoteLaugh = 11;
    enum : uint { spellSoulFlame = 23272, spellDreadfulFright = 23275, spellCreepingDoom = 23589,
        spellCripplingClip = 23279, spellWingClip3 = 14268, spellFrostTrap = 13810 }
    enum int emoteImmobilized = -1001252;

    enum Step : ubyte { laugh, transform, soulFlame, creepingDoom, dreadfulFright, leave }
    Schedule!Step steps;
    EntityRef hunter;
    bool demon;

    void on(ref CreatureContext me, const ref GossipHello e)
    {
        if (demon || me.questStatus(e.player, questStaveOfTheAncients) != QuestProgress.incomplete)
            return;
        GossipMenu menu;
        menu.add(GossipIcon.chat, "Show me your real face, demon.", showFace);
        me.sendGossip(e.player, 0, menu, false);
        me.consume();
    }

    void on(ref CreatureContext me, const ref GossipSelect e)
    {
        if (e.action != showFace || demon)
            return;
        me.closeGossip(e.player);
        hunter = e.player;
        me.npcFlags(0);
        me.follow(EntityRef.init); // he stops his walk
        steps.after(Step.laugh, 5.seconds);
        steps.after(Step.transform, 10.seconds);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.laugh:
            me.emote(emoteLaugh);
            break;
        case Step.transform:
            demon = true;
            me.changeEntry(solenor);
            me.castSelf(spellSoulFlame);
            steps.after(Step.soulFlame, 150.msecs); // again, so that the player sees it
            steps.after(Step.leave, 20 * 60.seconds);
            break;
        case Step.soulFlame:
            me.castSelf(spellSoulFlame);
            break;
        case Step.creepingDoom:
            if (!me.inCombat)
                return;
            me.castSelf(spellCreepingDoom);
            steps.after(Step.creepingDoom, 15.seconds);
            break;
        case Step.dreadfulFright:
            if (!me.inCombat)
                return;
            if (me.victim && me.distanceTo(me.victim) > 5 && me.castSpell(spellDreadfulFright) == ActionResult.ok)
                steps.after(Step.dreadfulFright, (15 + me.random(6)).seconds);
            else
                steps.after(Step.dreadfulFright, 1.seconds);
            break;
        case Step.leave:
            if (me.inCombat)
                return cast(void) steps.after(Step.leave, 10.seconds);
            me.despawn(1);
            break;
        }
    }

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        if (!demon)
            return;
        if (e.enemy.isPlayer && hunter && e.enemy != hunter)
            return leave(me, e.enemy);
        if (e.enemy.isPlayer)
            hunter = e.enemy;
        steps.after(Step.creepingDoom, (3 + me.random(4)).seconds);
        steps.after(Step.dreadfulFright, (10 + me.random(6)).seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        // Another player joining the fight (a pet is the hunter's own help).
        if (demon && e.attacker.isPlayer && hunter && e.attacker != hunter)
            leave(me, e.attacker);
        else if (demon && me.hasAura(me.self, spellSoulFlame) && me.hasAura(me.self, spellFrostTrap))
            me.removeAura(me.self, spellSoulFlame);
    }

    void on(ref CreatureContext me, const ref SpellHit e)
    {
        if (demon && e.spell == spellWingClip3 && me.castSelf(spellCripplingClip, true) == ActionResult.ok)
            me.say(emoteImmobilized);
    }

    /// Unfair: the demon goes, and The Cleaner comes for those who fought it.
    private void leave(ref CreatureContext me, EntityRef intruder)
    {
        const cleaner = me.summon(theCleaner, Location.init, 20 * 60_000);
        me.attack(cleaner, intruder);
        if (hunter)
            me.attack(cleaner, hunter);
        steps.clear();
        me.despawn(1);
    }
}


// ---------------------------------------------------------------------------
// The opening of Ahn'Qiraj
// ---------------------------------------------------------------------------

/// Who plays a part in "A Pawn on the Eternal Board".
enum Pawn : ubyte { anachronos, fandral, merithra, arygos, caelestrasz }

/**
 * Anachronos the Ancient, called by the Crystalline Tear for "A Pawn on the Eternal Board" (8519): the
 * War of the Shifting Sands played again. The bronze dragon calls Fandral Staghelm, Merithra, Arygos and
 * Caelestrasz and the armies; the three dragons fall on the Qiraji in turn, Anachronos stops time and
 * raises the barrier, Fandral calls the roots; then the scepter, Fandral's refusal, and its pieces picked
 * up. Those near on the quest have its event; Anachronos flies off.
 */
@creature("npc_anachronos_the_ancient")
struct AnachronosTheAncient
{
    enum : uint
    {
        npcMerithra = 15378, npcCaelestrasz = 15379, npcArygos = 15380, npcAnachronos = 15381, npcFandral = 15382,
        npcQuestTrigger = 15454, npcKaldoreiInfantry = 15423, npcQirajiWasp = 15414, npcQirajiDrone = 15421,
        npcQirajiTank = 15422, npcAnubisathConqueror = 15424,
        questPawnOnTheEternalBoard = 8519,
        spellGreenDragon = 25105, spellRedDragon = 25106, spellBlueDragon = 25107, spellBronzeDragon = 25108,
        spellMerithraWake = 25145, spellArygosVengeance = 25149, spellMoltenRain = 25150, spellTimeStop = 25158,
        spellPrismaticBarrier = 25159, spellGlyphOfWarding = 25166, spellCallAncients = 25167,
        spellShatterHammer = 25182,
        emoteShout = 5,
    }

    /// Movement points.
    enum Point : uint { dragonAttack = 1, exit, gate, scepter1, scepter2, epilogue }

    private enum Location flight = Location(-8159.951f, 1525.241f, 74.994f), anachronosGate = Location(-8106.238f, 1525.948f, 2.639f),
        fandralGate = Location(-8103.861f, 1525.923f, 2.677f), shatteredScepter = Location(-8107.387f, 1523.641f, 2.609f),
        fandralEpilogue = Location(-8100.921f, 1527.740f, 2.871f), pieces1 = Location(-8115.270f, 1515.926f, 3.305f),
        pieces2 = Location(-8116.879f, 1530.615f, 3.762f), fandralExit = Location(-7997.790f, 1548.664f, 3.738f),
        launch = Location(-8061.933f, 1496.196f, 2.556f), anachronosFlight = Location(-8008.705f, 1446.063f, 44.104f),
        armyAnchor = Location(-8085.748f, 1521.484f, 2.624f);

    private static immutable Location[4] pawnSpawns = [Location(-8029.301f, 1534.612f, 2.609f, 3.121f),
        Location(-8034.227f, 1536.580f, 2.609f, 6.161f), Location(-8031.935f, 1532.658f, 2.609f, 1.012f),
        Location(-8034.106f, 1534.224f, 2.609f, 0.290f)];
    private static immutable uint[4] pawnEntries = [npcFandral, npcArygos, npcCaelestrasz, npcMerithra];

    /// What a beat of the scene does besides its line.
    enum Act : ubyte
    {
        none, summonPawns, summonArmy, sendMerithra, merithraTransforms, merithraWakes, sendArygos, merithraLeaves,
        arygosTransforms, arygosVengeance, arygosLeaves, sendCaelestrasz, caelestraszTransforms, moltenRain,
        caelestraszLeaves, toTheGate, fandralToTheGate, prismaticBarrier, glyphOfWarding, callAncients, fandralKneels,
        handScepter, fandralStands, anachronosStands, shatter, fandralToScepter, fandralLeaves, gatherPieces,
    }

    /// A beat: its line (by whom), what is done, and the wait before the next (0: until a movement ends).
    static struct Beat
    {
        int text;
        Pawn speaker;
        Act act;
        uint ms;
    }

    private static immutable Beat[] scene = [
        Beat(0, Pawn.anachronos, Act.summonPawns, 2000),
        Beat(-1000740, Pawn.anachronos, Act.none, 3000),
        Beat(0, Pawn.anachronos, Act.summonArmy, 3000),
        Beat(-1000741, Pawn.fandral, Act.none, 6000),
        Beat(-1000745, Pawn.merithra, Act.none, 2000),
        Beat(-1000742, Pawn.merithra, Act.none, 3000),
        Beat(-1000743, Pawn.arygos, Act.none, 4000),
        Beat(-1000744, Pawn.caelestrasz, Act.none, 9000),
        Beat(-1000746, Pawn.merithra, Act.none, 5000),
        Beat(0, Pawn.anachronos, Act.sendMerithra, 0),         // on until she is there
        Beat(0, Pawn.anachronos, Act.none, 5000),
        Beat(-1000747, Pawn.merithra, Act.none, 1000),
        Beat(0, Pawn.anachronos, Act.merithraTransforms, 6000),
        Beat(-1000748, Pawn.arygos, Act.merithraWakes, 5000),
        Beat(0, Pawn.anachronos, Act.sendArygos, 1000),
        Beat(0, Pawn.anachronos, Act.merithraLeaves, 4000),
        Beat(-1000749, Pawn.arygos, Act.none, 4000),
        Beat(0, Pawn.anachronos, Act.arygosTransforms, 5000),
        Beat(0, Pawn.anachronos, Act.arygosVengeance, 7000),
        Beat(0, Pawn.anachronos, Act.arygosLeaves, 1000),
        Beat(-1000750, Pawn.caelestrasz, Act.none, 5000),
        Beat(0, Pawn.anachronos, Act.sendCaelestrasz, 0),      // on until he is there
        Beat(0, Pawn.anachronos, Act.none, 3000),
        Beat(-1000751, Pawn.caelestrasz, Act.none, 5000),
        Beat(0, Pawn.anachronos, Act.caelestraszTransforms, 4000),
        Beat(0, Pawn.anachronos, Act.moltenRain, 6000),
        Beat(-1000752, Pawn.anachronos, Act.caelestraszLeaves, 5000),
        Beat(-1000753, Pawn.fandral, Act.none, 3000),
        Beat(-1000754, Pawn.anachronos, Act.none, 1000),
        Beat(0, Pawn.anachronos, Act.toTheGate, 1000),
        Beat(0, Pawn.anachronos, Act.fandralToTheGate, 0),     // on when Anachronos is at the gate (Time Stop)
        Beat(0, Pawn.anachronos, Act.none, 7000),
        Beat(0, Pawn.anachronos, Act.prismaticBarrier, 15_000),
        Beat(0, Pawn.anachronos, Act.glyphOfWarding, 4000),
        Beat(-1000756, Pawn.anachronos, Act.none, 3000),
        Beat(-1000757, Pawn.fandral, Act.callAncients, 9000),
        Beat(-1000758, Pawn.fandral, Act.fandralKneels, 1000),
        Beat(-1000759, Pawn.anachronos, Act.none, 6000),
        Beat(-1000760, Pawn.anachronos, Act.none, 5000),
        Beat(-1000761, Pawn.anachronos, Act.none, 15_000),
        Beat(0, Pawn.anachronos, Act.handScepter, 3000),
        Beat(-1000763, Pawn.fandral, Act.fandralStands, 3000),
        Beat(0, Pawn.anachronos, Act.anachronosStands, 4000),
        Beat(-1000764, Pawn.fandral, Act.none, 12_000),
        Beat(-1000765, Pawn.fandral, Act.shatter, 3000),
        Beat(-1000766, Pawn.anachronos, Act.fandralToScepter, 0), // on when Fandral is back from the pieces
        Beat(-1000767, Pawn.fandral, Act.none, 8000),
        Beat(0, Pawn.anachronos, Act.fandralLeaves, 4000),
        Beat(-1000768, Pawn.anachronos, Act.none, 1000),
        Beat(0, Pawn.anachronos, Act.gatherPieces, 0),
    ];

    /// The beats a movement's end resumes the scene at.
    enum : ubyte { afterMerithraArrives = 10, afterCaelestraszArrives = 22, afterTimeStop = 31, afterFandralReturns = 46 }

    enum Step : ubyte { beat, pickUp, credit, toLaunch, takeOff }
    Schedule!Step steps;
    EntityRef[Pawn.max + 1] pawns;
    EntityRef[48] army;
    ubyte armyCount, beat;
    Location attackPoint;

    void on(ref CreatureContext me, const ref Spawned e)
    {
        pawns[Pawn.anachronos] = me.self;
        steps.after(Step.beat, 100.msecs);
    }

    void on(ref CreatureContext me, Step step)
    {
        final switch (step)
        {
        case Step.beat:
            if (beat >= scene.length)
                return;
            const b = scene[beat++];
            if (b.text)
                me.sayOther(pawns[b.speaker], b.text, b.act == Act.handScepter ? pawns[Pawn.fandral] : EntityRef.init);
            act(me, b.act);
            if (b.ms)
                steps.after(Step.beat, b.ms.msecs);
            break;
        case Step.pickUp:
            me.moveTo(pieces2, Point.scepter2);
            me.standState(StandState.stand);
            break;
        case Step.credit:
            // Those near on the quest (`GroupEventHappens`).
            EntityRef[40] players;
            foreach (p; players[0 .. me.playersNear(100, players[])])
                if (me.questStatus(p, questPawnOnTheEternalBoard) == QuestProgress.incomplete)
                    me.questEvent(p, questPawnOnTheEternalBoard);
            me.standState(StandState.stand);
            steps.after(Step.toLaunch, 4.seconds);
            break;
        case Step.toLaunch:
            me.moveTo(launch, Point.exit, true);
            break;
        case Step.takeOff:
            me.flying(true);
            me.moveNow(anachronosFlight, 0);
            me.despawn(10_000);
            break;
        }
    }

    private void act(ref CreatureContext me, Act what)
    {
        final switch (what)
        {
        case Act.none:
            break;
        case Act.summonPawns:
            foreach (i, entry; pawnEntries)
            {
                const pawn = me.summon(entry, pawnSpawns[i]);
                final switch (entry)
                {
                case npcFandral: pawns[Pawn.fandral] = pawn; break;
                case npcArygos: pawns[Pawn.arygos] = pawn; break;
                case npcCaelestrasz: pawns[Pawn.caelestrasz] = pawn; break;
                case npcMerithra: pawns[Pawn.merithra] = pawn; break;
                }
            }
            foreach (_; 0 .. 3)
                enlist(me, me.summon(npcAnubisathConqueror, around(me, 20)));
            break;
        case Act.summonArmy:
            me.emote(emoteShout);
            foreach (_; 0 .. 20)
                enlist(me, me.summon(npcKaldoreiInfantry, around(me, 10)));
            foreach (_; 0 .. 6)
                foreach (entry; [npcQirajiWasp, npcQirajiDrone, npcQirajiTank])
                    enlist(me, me.summon(entry, around(me, 15)));
            break;
        case Act.sendMerithra:
            sendToAttack(me, Pawn.merithra);
            break;
        case Act.merithraTransforms:
            me.castAs(pawns[Pawn.merithra], spellGreenDragon, pawns[Pawn.merithra]);
            break;
        case Act.merithraWakes:
            me.castAs(pawns[Pawn.merithra], spellMerithraWake, pawns[Pawn.merithra]);
            break;
        case Act.sendArygos:
            sendToAttack(me, Pawn.arygos);
            break;
        case Act.merithraLeaves:
            leave(me, Pawn.merithra);
            break;
        case Act.arygosTransforms:
            me.castAs(pawns[Pawn.arygos], spellBlueDragon, pawns[Pawn.arygos]);
            break;
        case Act.arygosVengeance:
            me.castAs(pawns[Pawn.arygos], spellArygosVengeance, pawns[Pawn.arygos]);
            break;
        case Act.arygosLeaves:
            leave(me, Pawn.arygos);
            break;
        case Act.sendCaelestrasz:
            sendToAttack(me, Pawn.caelestrasz);
            break;
        case Act.caelestraszTransforms:
            me.castAs(pawns[Pawn.caelestrasz], spellRedDragon, pawns[Pawn.caelestrasz]);
            break;
        case Act.moltenRain:
            me.castAs(pawns[Pawn.caelestrasz], spellMoltenRain, pawns[Pawn.caelestrasz]);
            break;
        case Act.caelestraszLeaves:
            leave(me, Pawn.caelestrasz);
            me.face(pawns[Pawn.fandral]);
            break;
        case Act.toTheGate:
            me.moveTo(anachronosGate, Point.gate, true);
            break;
        case Act.fandralToTheGate:
            me.moveCreature(pawns[Pawn.fandral], fandralGate, Point.gate, true);
            break;
        case Act.prismaticBarrier:
            me.castSelf(spellPrismaticBarrier);
            break;
        case Act.glyphOfWarding:
            me.castSelf(spellGlyphOfWarding);
            break;
        case Act.callAncients:
            me.castAs(pawns[Pawn.fandral], spellCallAncients, pawns[Pawn.fandral]);
            break;
        case Act.fandralKneels:
            me.face(pawns[Pawn.fandral]);
            break;
        case Act.handScepter:
            me.standState(StandState.kneel);
            break;
        case Act.fandralStands:
            break;
        case Act.anachronosStands:
            me.standState(StandState.stand);
            break;
        case Act.shatter:
            me.castAs(pawns[Pawn.fandral], spellShatterHammer, pawns[Pawn.fandral]);
            break;
        case Act.fandralToScepter:
            me.moveCreature(pawns[Pawn.fandral], shatteredScepter, Point.scepter1);
            break;
        case Act.fandralLeaves:
            me.moveCreature(pawns[Pawn.fandral], fandralExit, Point.exit);
            break;
        case Act.gatherPieces:
            me.moveTo(pieces1, Point.scepter1);
            break;
        }
    }

    void on(ref CreatureContext me, const ref MovementDone e)
    {
        switch (e.point)
        {
        case Point.gate:
            me.castSelf(spellTimeStop);
            resumeAt(afterTimeStop);
            break;
        case Point.scepter1:
            me.say(-1000769); // picks up the pieces
            me.standState(StandState.kneel);
            steps.after(Step.pickUp, 2.seconds);
            break;
        case Point.scepter2:
            me.say(-1000770);
            me.standState(StandState.kneel);
            steps.after(Step.credit, 4.seconds);
            break;
        case Point.exit:
            me.castSelf(spellBronzeDragon);
            steps.after(Step.takeOff, 4.seconds);
            break;
        default:
            break;
        }
    }

    void on(ref CreatureContext me, const ref SummonedArrived e)
    {
        if (e.summoned == pawns[Pawn.fandral])
        {
            switch (e.point)
            {
            case Point.scepter1:
                me.moveCreature(e.summoned, fandralEpilogue, Point.epilogue);
                break;
            case Point.epilogue:
                foreach (soldier; army[0 .. armyCount])
                    me.despawn(soldier);
                armyCount = 0;
                resumeAt(afterFandralReturns);
                break;
            case Point.exit:
                me.despawn(e.summoned);
                break;
            default:
                break;
            }
        }
        else if (e.point == Point.dragonAttack)
        {
            if (e.summoned == pawns[Pawn.merithra])
                resumeAt(afterMerithraArrives);
            else if (e.summoned == pawns[Pawn.caelestrasz])
                resumeAt(afterCaelestraszArrives);
        }
    }

    /// The scene goes on at beat `at` (a movement it waited for ended).
    private void resumeAt(ubyte at)
    {
        beat = at;
        steps.after(Step.beat, 0.msecs);
    }

    private void enlist(ref CreatureContext me, EntityRef soldier)
    {
        if (soldier && armyCount < army.length)
            army[armyCount++] = soldier;
    }

    /// A dragon runs at the Qiraji (where the quest trigger stands).
    private void sendToAttack(ref CreatureContext me, Pawn dragon)
    {
        if (attackPoint == Location.init)
        {
            const trigger = me.creatureNearby(npcQuestTrigger, 35);
            if (!trigger || !me.locationOf(trigger, attackPoint))
                attackPoint = armyAnchor;
        }
        me.moveCreature(pawns[dragon], attackPoint, Point.dragonAttack, true);
    }

    /// A dragon takes to the air and is gone.
    private void leave(ref CreatureContext me, Pawn dragon)
    {
        me.moveCreature(pawns[dragon], flight, Point.exit, true);
        me.despawn(pawns[dragon], 9000);
    }

    /// A random point within `range` yards of where the armies gather.
    private static Location around(ref CreatureContext me, uint range)
    {
        import std.math : cos, sin, PI;

        const angle = me.random(360) * PI / 180, distance = me.random(range + 1);
        return Location(armyAnchor.x + distance * cos(angle), armyAnchor.y + distance * sin(angle), armyAnchor.z);
    }
}

/// The Crystalline Tear: taking "A Pawn on the Eternal Board" calls Anachronos the Ancient, unless he is here.
@gameObject("go_crystalline_tear")
struct CrystallineTear
{
    void on(ref GameObjectContext it, const ref QuestAccepted e)
    {
        if (e.quest != AnachronosTheAncient.questPawnOnTheEternalBoard
                || it.creatureNearby(AnachronosTheAncient.npcAnachronos, 90))
            return;
        auto at = it.location;
        at.orientation = 3.75f;
        it.summon(AnachronosTheAncient.npcAnachronos, at);
    }
}

/// The Colossi of Silithus (Ashi, Regal, Zora): each tells the land it has woken; the war effort remembers
/// each that falls.
@creature("npc_silithus_boss")
struct SilithusColossus
{
    void on(ref CreatureContext me, const ref Died e)
    {
        switch (me.self.entry)
        {
        case 15742: me.warEffortColossusFell(0); break; // Ashi
        case 15741: me.warEffortColossusFell(1); break; // Regal
        case 15740: me.warEffortColossusFell(2); break; // Zora
        default: break;
        }
    }

    void on(ref CreatureContext me, const ref Spawned e)
    {
        switch (me.self.entry)
        {
        case 15740: me.sayText(11425); break; // Zora
        case 15741: me.sayText(11424); break; // Regal
        case 15742: me.sayText(11426); break; // Ashi
        default: break;
        }
    }
}

unittest
{
    import dmangos.scripts.kalimdortesting;
    alias self = dmangos.scripts.silithus;

    auto s = Driven!self("npc_solenor", 14_536);
    s.host.quests[Solenor.questStaveOfTheAncients] = QuestProgress.incomplete;
    assert(s.raise(GossipHello(hero)));
    s.raise(GossipSelect(hero, 0, 0, Solenor.showFace));
    s.run(10_000);
    assert(s.host.has("emote 11") && s.host.has("entry 14530") && s.host.has("cast 23272"));
    s.raise(EnteredCombat(hero));
    s.raise(Damaged(EntityRef(8), 100, 100, 95));
    assert(s.host.has("summon 14503") && s.host.has("despawn"), "another player: the Cleaner");

    // The Tear calls Anachronos; the scene runs to its end and its credit.
    // The war effort: a Colossus's fall.
    auto regal = Driven!self("npc_silithus_boss", 15_741);
    regal.raise(Died(hero));
    assert(regal.host.has("colossus 1"));

    auto tear = DrivenObject!self("go_crystalline_tear", 180_633);
    tear.raise(QuestAccepted(hero, AnachronosTheAncient.questPawnOnTheEternalBoard));
    assert(tear.host.has("summon 15381"));

    alias A = AnachronosTheAncient;
    auto a = Driven!self("npc_anachronos_the_ancient", A.npcAnachronos);
    a.raise(Spawned());
    a.run(2100);
    assert(a.host.summons == 4 + 3, "four in the scene, three conquerors");
    a.run(5000);
    assert(a.host.summons == 7 + 20 + 18 && a.host.has("emote 5"), "the armies");
    a.run(60_000);
    assert(a.host.has("move 15378 1"), "Merithra sent; the scene waits for her");
    const merithra = a.host.summoned[3];
    a.raise(SummonedArrived(merithra, A.Point.dragonAttack));
    a.run(45_000);
    assert(a.host.has("cast as 15378 25105") && a.host.has("cast as 15380 25149") && a.host.has("move 15379 1"));
    a.raise(SummonedArrived(a.host.summoned[2], A.Point.dragonAttack));
    a.run(30_000);
    assert(a.host.has("cast as 15379 25150") && a.host.has("move 3"), "to the gate");
    a.raise(MovementDone(A.Point.gate));
    a.run(100_000);
    assert(a.host.has("cast 25158") && a.host.has("cast as 15382 25182") && a.host.has("move 15382 4"));
    a.raise(SummonedArrived(a.host.summoned[0], A.Point.scepter1));
    a.raise(SummonedArrived(a.host.summoned[0], A.Point.epilogue));
    a.run(20_000);
    assert(a.host.has("despawn 15423") && a.host.has("move 4"), "the army gone; Anachronos gathers the pieces");
    a.raise(MovementDone(A.Point.scepter1));
    a.run(2000);
    a.raise(MovementDone(A.Point.scepter2));
    a.run(8000);
    assert(a.host.has("move 2"));
    a.raise(MovementDone(A.Point.exit));
    a.run(4000);
    assert(a.host.has("cast 25108") && a.host.has("despawn"));
}
