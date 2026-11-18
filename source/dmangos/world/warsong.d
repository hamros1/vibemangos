/**
 * Warsong Gulch's rules: two flags, three captures win.
 *
 * Each side's flag stands in its base. A player who takes the enemy's flag carries it (the flag's
 * aura: 23333 the Horde's, 23335 the Alliance's) and scores by bringing it into its own flag room
 * while its own flag is at home. A carrier who dies, leaves or logs out drops the flag where it is:
 * its own side may return it (to its base) by touching it, the other side take it up again, and left
 * alone for ten seconds it goes home by itself. After a capture both flags come back 23 seconds
 * later. A capture gives the side 35 reputation and the bonus honor of two kills; the winner gets the
 * bonus honor of one kill more.
 *
 * The flags, the spirit guides and the doors are the map's battleground events (0 the Alliance's
 * flag, 1 the Horde's, 2 the spirit guides). Until the start each side's graveyard is in its flag
 * room; then it is the main one.
 */
module dmangos.world.warsong;

import core.time : Duration, seconds;

import dmangos.bytes : ByteWriter;
import dmangos.world.battleground;
import dmangos.world.gameobject : GameObject;
import dmangos.world.opcodes : ChatType;

/// `BG_WS_MAX_TEAM_SCORE`, `BG_WS_FLAG_RESPAWN_TIME`, `BG_WS_FLAG_DROP_TIME`
enum uint maxCaptures = 3;
/// ditto
enum Duration flagRespawnTime = 23.seconds, flagDropTime = 10.seconds;

/// Reputation per capture and the bonus honor kills of a win (the normal, not a Call to Arms weekend).
enum int captureReputation = 35;
/// ditto
enum uint winKills = 1, captureKills = 2;
/// The same on a Call to Arms weekend.
enum int weekendCaptureReputation = 45;
/// ditto
enum uint weekendWinKills = 3;

/// The sides' reputation factions: Silverwing Sentinels, Warsong Outriders.
immutable uint[2] reputationFactions = [890, 889];

/// The flags at the bases, and dropped (`GO_WS_*`).
enum uint goSilverwingFlag = 179830, goWarsongFlag = 179831, goSilverwingFlagDrop = 179785,
    goWarsongFlagDrop = 179786;

/// Each side's flag at its base, and dropped.
immutable uint[2] baseFlags = [goSilverwingFlag, goWarsongFlag];
/// ditto
immutable uint[2] droppedFlags = [goSilverwingFlagDrop, goWarsongFlagDrop];

/// The flag carried: the Alliance's (Silverwing Flag, 23335) and the Horde's (Warsong Flag, 23333).
immutable uint[2] carriedFlagSpells = [23335, 23333];

/// The world states: each flag's state, the captures, their maximum, and the HUD's "holds the flag".
enum uint stateFlagAlliance = 1545, stateFlagHorde = 1546, stateCapturesAlliance = 1581, stateCapturesHorde = 1582,
    stateCapturesMax = 1601, stateHudHorde = 2338, stateHudAlliance = 2339;
/// ditto, by side
immutable uint[2] flagStates = [stateFlagAlliance, stateFlagHorde];
/// ditto: whether side i holds the other's flag
immutable uint[2] hudStates = [stateHudAlliance, stateHudHorde];
/// ditto: side i's captures
immutable uint[2] captureStates = [stateCapturesAlliance, stateCapturesHorde];

/// A flag's state (`WSPickedUpFlagStates`): at its base, carried, on the ground.
enum uint flagOnBase = 0, flagOnPlayer = 1, flagOnGround = uint.max; // -1
/// The HUD's icon (`WSFlagIconStates`)
enum uint iconInvisible = 1, iconVisible = 2;

/// The area triggers: the flag rooms (a capture), the exit portals.
enum uint triggerSilverwingRoom = 3646, triggerWarsongRoom = 3647, triggerHordePortal = 3669,
    triggerAlliancePortal = 3671;

/// The graveyards: in the flag rooms, and the main ones.
enum uint graveyardFlagRoomAlliance = 769, graveyardFlagRoomHorde = 770, graveyardMainAlliance = 771,
    graveyardMainHorde = 772;

/// The events: the flags and the spirit guides.
enum ubyte eventFlagAlliance = 0, eventFlagHorde = 1, eventSpiritGuides = 2;

/// The messages (`mangos_string`): side i's flag captured, dropped, returned, picked up, placed again.
immutable uint[2] stringCaptured = [606, 605], stringDropped = [608, 607], stringReturned = [609, 610],
    stringPickedUp = [612, 611], stringPlacedOne = [614, 615];
/// "The flags are now placed at their bases."
enum uint stringPlaced = 613;
/// "Only the Alliance (the Horde) can use that portal"
enum uint stringOnlyAlliancePortal = 752, stringOnlyHordePortal = 753;

/// The sounds: side i's flag picked up; side i captured; returned; the flags back.
immutable uint[2] soundPickedUp = [8174, 8212], soundCaptured = [8173, 8213];
/// ditto
enum uint soundReturned = 8192, soundFlagsBack = 8232;

/// The scoreboard's columns: flags captured, flags returned.
enum size_t scoreCaptures = 0, scoreReturns = 1;

/// The chat type a side's messages go out as.
ChatType sideChat(ubyte side) pure nothrow @nogc @safe
{
    return side == 0 ? ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE : ChatType.CHAT_MSG_BG_SYSTEM_HORDE;
}

/// See the module documentation. Index i of each array is side i's flag (0 the Alliance's).
final class WarsongRules : BattlegroundRules
{
    ulong[2] carrier;         /// who carries side i's flag
    ulong[2] dropped;         /// side i's flag on the ground (its object)
    Duration[2] dropLeft;     /// until side i's dropped flag goes home
    bool[2] respawning;       /// side i's flag is back after a capture ...
    Duration[2] respawnLeft;  /// ... in this long

    override void reset(Battleground copy)
    {
        foreach (side; 0 .. 2)
        {
            copy.setWorldState(captureStates[side], 0);
            copy.setWorldState(hudStates[side], iconInvisible);
            copy.setWorldState(flagStates[side], flagOnBase);
        }
        copy.setWorldState(stateCapturesMax, maxCaptures);
        copy.graveyardTeams[graveyardMainAlliance] = teamInvalidLink;
        copy.graveyardTeams[graveyardMainHorde] = teamInvalidLink;
        copy.graveyardTeams[graveyardFlagRoomAlliance] = teamAllianceLink;
        copy.graveyardTeams[graveyardFlagRoomHorde] = teamHordeLink;
    }

    override void started(Battleground copy)
    {
        copy.spawnEvent(eventSpiritGuides, 0, true);
        copy.spawnEvent(eventFlagAlliance, 0, true);
        copy.spawnEvent(eventFlagHorde, 0, true);
        copy.graveyardTeams[graveyardMainAlliance] = teamAllianceLink;
        copy.graveyardTeams[graveyardMainHorde] = teamHordeLink;
        copy.graveyardTeams[graveyardFlagRoomAlliance] = teamInvalidLink;
        copy.graveyardTeams[graveyardFlagRoomHorde] = teamInvalidLink;
    }

    override void tick(Battleground copy, Duration elapsed)
    {
        foreach (ubyte side; 0 .. 2)
        {
            if (respawning[side])
            {
                respawnLeft[side] -= elapsed;
                if (respawnLeft[side] <= Duration.zero)
                    respawnAtBase(copy, side, true);
            }
            else if (copy.worldStates.get(flagStates[side], 0) == flagOnGround && dropLeft[side] > Duration.zero)
            {
                dropLeft[side] -= elapsed;
                if (dropLeft[side] <= Duration.zero)
                    respawnDropped(copy, side);
            }
        }
    }

    override bool objectUsed(Battleground copy, ulong who, GameObject go)
    {
        const entry = go.spawn.entry;
        auto m = who in copy.members;
        if (m is null)
            return false;
        if (entry == goSilverwingFlag || entry == goWarsongFlag)
        {
            pickUpFromBase(copy, who, m.team);
            return true;
        }
        if (entry == goSilverwingFlagDrop || entry == goWarsongFlagDrop)
        {
            droppedFlagUsed(copy, who, m.team, go);
            return true;
        }
        return false;
    }

    override void playerKilled(Battleground copy, ulong victim, ulong killer)
    {
        dropFlagOf(copy, victim);
    }

    override void playerLeaving(Battleground copy, ulong guid)
    {
        dropFlagOf(copy, guid);
    }

    override bool areaTrigger(Battleground copy, ulong who, uint trigger)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (copy.status != BattlegroundStatus.inProgress)
            return false;
        auto m = who in copy.members;
        if (m is null)
            return false;
        switch (trigger)
        {
        case triggerSilverwingRoom: // the Alliance's flag room: a Horde flag carrier scores
            if (copy.worldStates.get(stateFlagHorde, 0) != flagOnBase && copy.worldStates.get(stateFlagAlliance, 0) == flagOnBase
                && carrier[1] == who)
                capture(copy, who, 0);
            return true;
        case triggerWarsongRoom:
            if (copy.worldStates.get(stateFlagAlliance, 0) != flagOnBase && copy.worldStates.get(stateFlagHorde, 0) == flagOnBase
                && carrier[0] == who)
                capture(copy, who, 1);
            return true;
        case triggerHordePortal:
            portal(copy, who, m.team, 1);
            return true;
        case triggerAlliancePortal:
            portal(copy, who, m.team, 0);
            return true;
        default:
            return false;
        }
    }

    override ubyte prematureWinner(Battleground copy)
    {
        const a = copy.worldStates.get(stateCapturesAlliance, 0), h = copy.worldStates.get(stateCapturesHorde, 0);
        return a > h ? winnerAlliance : h > a ? winnerHorde : winnerNone;
    }

    override void ending(Battleground copy, ubyte winner)
    {
        const kills = copy.weekend ? weekendWinKills : winKills;
        if (winner == winnerAlliance)
            copy.rewardHonorToTeam(kills, 0);
        else if (winner == winnerHorde)
            copy.rewardHonorToTeam(kills, 1);
    }

    /// The side's players, and the carrier of its own flag (the enemy who holds it).
    override const(ubyte)[] playerPositions(Battleground copy, ubyte team)
    {
        ByteWriter w;
        ByteWriter list;
        uint count;
        foreach (guid, ref m; copy.members)
            if (m.team == team)
                if (auto who = copy.onlinePlayerOf(guid))
                {
                    list.put(guid);
                    list.put(who.character.position.x);
                    list.put(who.character.position.y);
                    ++count;
                }
        w.put(count);
        w.putBytes(list.data);
        const holder = carrier[team];
        auto held = holder ? copy.onlinePlayerOf(holder) : null;
        w.put(ubyte(held !is null));
        if (held !is null)
        {
            w.put(holder);
            w.put(held.character.position.x);
            w.put(held.character.position.y);
        }
        return w.data.dup;
    }

private:
    /// `ProcessFlagPickUpFromBase`: the enemy's flag taken from its base.
    void pickUpFromBase(Battleground copy, ulong who, ubyte team)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        const other = cast(ubyte)(1 - team);
        if (copy.status != BattlegroundStatus.inProgress || copy.worldStates.get(flagStates[other], 0) != flagOnBase
            || respawning[other] || !copy.memberAlive(who))
            return;
        copy.spawnEvent(other, 0, false);
        carrier[other] = who;
        copy.setWorldState(flagStates[other], flagOnPlayer);
        copy.setWorldState(hudStates[team], iconVisible);
        copy.castOn(who, carriedFlagSpells[other]);
        copy.playSound(soundPickedUp[other]);
        copy.message(stringPickedUp[other], sideChat(team), who);
    }

    /// `ProcessDroppedFlagActions`: a dropped flag touched: one's own goes home, the enemy's is taken up.
    void droppedFlagUsed(Battleground copy, ulong who, ubyte team, GameObject go)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (copy.status != BattlegroundStatus.inProgress || !copy.memberAlive(who))
            return;
        const other = cast(ubyte)(1 - team);
        if (go.spawn.entry == droppedFlags[team])
        {
            if (copy.worldStates.get(flagStates[team], 0) != flagOnGround)
                return;
            removeDropped(copy, team);
            copy.setWorldState(hudStates[team], iconInvisible);
            respawnAtBase(copy, team, false);
            copy.addScore(who, scoreReturns);
            copy.message(stringReturned[team], sideChat(team), who);
            copy.playSound(soundReturned);
        }
        else if (go.spawn.entry == droppedFlags[other])
        {
            if (copy.worldStates.get(flagStates[other], 0) != flagOnGround)
                return;
            removeDropped(copy, other);
            copy.spawnEvent(other, 0, false);
            carrier[other] = who;
            copy.setWorldState(flagStates[other], flagOnPlayer);
            copy.setWorldState(hudStates[team], iconVisible);
            copy.castOn(who, carriedFlagSpells[other]);
            copy.message(stringPickedUp[other], sideChat(team), who);
            copy.playSound(soundPickedUp[other]);
        }
    }

    /// `HandlePlayerDroppedFlag`: the flag `who` carries falls where it is.
    void dropFlagOf(Battleground copy, ulong who)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        foreach (ubyte side; 0 .. 2)
        {
            if (carrier[side] != who || who == 0)
                continue;
            carrier[side] = 0;
            copy.removeAuraOf(who, carriedFlagSpells[side]);
            if (copy.status != BattlegroundStatus.inProgress)
                continue;
            const team = cast(ubyte)(1 - side);
            copy.setWorldState(flagStates[side], flagOnGround);
            copy.setWorldState(hudStates[team], iconInvisible);
            dropped[side] = copy.placeObjectAt(who, droppedFlags[side]);
            if (dropped[side] == 0) // nowhere to put it (its carrier is not here): it goes home
            {
                respawnAtBase(copy, side, false);
                continue;
            }
            copy.message(stringDropped[side], sideChat(side), who);
            dropLeft[side] = flagDropTime;
        }
    }

    /// `ProcessPlayerFlagScoreEvent`: `who` of `team` brought the enemy's flag home.
    void capture(Battleground copy, ulong who, ubyte team)
    {
        const other = cast(ubyte)(1 - team);
        carrier[other] = 0;
        copy.setWorldState(flagStates[other], flagOnBase);
        respawning[other] = true;
        copy.removeAuraOf(who, carriedFlagSpells[other]);
        copy.playSound(soundCaptured[team]);
        copy.rewardReputationToTeam(reputationFactions[team], copy.weekend ? weekendCaptureReputation : captureReputation,
            team);
        copy.rewardHonorToTeam(captureKills, team);
        const captures = copy.worldStates.get(captureStates[team], 0) + 1;
        copy.setWorldState(captureStates[team], captures);
        copy.setWorldState(flagStates[team], flagOnBase);
        copy.setWorldState(hudStates[team], iconInvisible);
        copy.spawnEvent(eventFlagAlliance, 0, false);
        copy.spawnEvent(eventFlagHorde, 0, false);
        copy.message(stringCaptured[other], sideChat(team), who);
        copy.addScore(who, scoreCaptures);
        if (captures >= maxCaptures)
        {
            foreach (side; 0 .. 2)
            {
                copy.setWorldState(flagStates[side], 0);
                copy.setWorldState(hudStates[side], iconInvisible);
            }
            respawning = [false, false];
            copy.end(Battleground.winnerOf(team));
        }
        else
            respawnLeft[other] = flagRespawnTime;
    }

    /// `RespawnFlagAtBase`: side `side`'s flag at its base again (after a capture: both flags, said aloud).
    void respawnAtBase(Battleground copy, ubyte side, bool afterCapture)
    {
        copy.setWorldState(flagStates[side], flagOnBase);
        copy.spawnEvent(side, 0, true);
        respawning[side] = false;
        if (afterCapture)
        {
            copy.spawnEvent(eventFlagAlliance, 0, true);
            copy.spawnEvent(eventFlagHorde, 0, true);
            copy.message(stringPlaced, ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
            copy.playSound(soundFlagsBack);
        }
    }

    /// `RespawnDroppedFlag`: left on the ground too long, it goes home.
    void respawnDropped(Battleground copy, ubyte side)
    {
        removeDropped(copy, side);
        respawnAtBase(copy, side, false);
        copy.message(stringPlacedOne[side], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        copy.playSound(soundFlagsBack);
    }

    void removeDropped(Battleground copy, ubyte side)
    {
        if (dropped[side])
            copy.removeObject(dropped[side]);
        dropped[side] = 0;
        dropLeft[side] = Duration.zero;
    }

    /// An exit portal: its own side leaves (a deserter while the battle is on); the other is told no.
    void portal(Battleground copy, ulong who, ubyte team, ubyte side)
    {
        if (team != side)
            return copy.notify(who, side == 0 ? stringOnlyAlliancePortal : stringOnlyHordePortal);
        copy.sendOut(who);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The flags: taken, dropped and returned, captured; three captures win, after the flags come back each time.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.bgqueue : BattlegroundStatus, BattlegroundType, battlegroundMaps;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.map : MapObject;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapWarsongGulch, raceOrc;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // The two flags at their bases (events 0 and 1, by each side's start), and the dropped flags' templates.
    foreach (i, entry; [goSilverwingFlag, goWarsongFlag, goSilverwingFlagDrop, goWarsongFlagDrop])
    {
        auto t = GameObjectTemplate.init;
        t.entry = entry;
        t.type = i < 2 ? 24 : 26;
        t.displayId = 5912;
        t.name = "flag";
        context.data.gameObjectTemplates[entry] = t;
    }
    const alliance = Position(1517, 1480, 352), horde = Position(935, 1433, 345);
    foreach (i, at; [alliance, horde])
    {
        context.data.gameObjectSpawns ~= GameObjectSpawn(90000 + cast(uint) i, baseFlags[i], mapWarsongGulch, at.x, at.y, at.z);
        context.data.gameObjectCells[mapWarsongGulch][cellKeyAt(at.x, at.y)] ~= context.data.gameObjectSpawns.length - 1;
        context.data.gameObjectBattleEvents[90000 + cast(uint) i] = [cast(ubyte) i, 0];
    }
    foreach (id, text; [605: "$n captured the Horde flag!", 606: "$n captured the Alliance flag!",
            609: "The Alliance Flag was returned to its base by $n!", 611: "The Horde flag was picked up by $n!",
            612: "The Alliance Flag was picked up by $n!", 613: "The flags are now placed at their bases.",
            608: "The Alliance Flag was dropped by $n!"])
        context.data.serverStrings[id] = text;

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto thrall = loggedIn(context, db, 8, "Thrall", Position(1629, -4373, 31), AccountLevel.player, raceOrc, 1);
    anduin.read();
    thrall.read();
    auto queue = context.battlegroundQueue;
    queue.testing = true;
    queue.join(7, context.nodeId, 0, 10, BattlegroundType.warsongGulch, 0);
    queue.join(8, context.nodeId, 1, 10, BattlegroundType.warsongGulch, 0);
    foreach (p; [&anduin, &thrall])
    {
        import dmangos.bytes : ByteWriter;

        ByteWriter port;
        port.put(battlegroundMaps[BattlegroundType.warsongGulch]);
        port.put(ubyte(1));
        p.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
        p.read();
        p.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        p.read();
    }
    auto copy = context.battlegrounds.all[0];
    auto rules = cast(WarsongRules) copy.rules;
    assert(rules !is null, "Warsong Gulch's rules");
    assert(copy.worldStates[stateCapturesMax] == 3 && copy.graveyardTeams[graveyardFlagRoomAlliance] == teamAllianceLink);
    auto map = context.existingMap(mapWarsongGulch, copy.instance);
    GameObject flag(uint entry)
    {
        GameObject found;
        map.forEachObject((MapObject o) {
            if (auto go = cast(GameObject) o)
                if (go.spawn.entry == entry)
                    found = go;
        });
        return found;
    }
    assert(flag(goSilverwingFlag) is null, "no flags before the start");
    copy.start();
    assert(flag(goSilverwingFlag) !is null && flag(goWarsongFlag) !is null, "the flags at the start");
    assert(copy.graveyardTeams[graveyardMainAlliance] == teamAllianceLink
        && copy.graveyardTeams[graveyardFlagRoomAlliance] == teamInvalidLink);

    // Thrall takes the Alliance's flag; Anduin cannot score his own flag room's trigger without the Horde's.
    assert(rules.objectUsed(copy, 8, flag(goSilverwingFlag)));
    assert(rules.carrier[0] == 8 && copy.worldStates[stateFlagAlliance] == flagOnPlayer);
    assert(flag(goSilverwingFlag) is null, "gone from its base");
    // Killed carrying it: it falls; Anduin returns it.
    copy.playerKilled(8, 7);
    assert(rules.carrier[0] == 0 && copy.worldStates[stateFlagAlliance] == flagOnGround);
    auto fallen = flag(goSilverwingFlagDrop);
    assert(fallen !is null, "the dropped flag on the ground");
    assert(rules.objectUsed(copy, 7, fallen));
    assert(copy.worldStates[stateFlagAlliance] == flagOnBase && flag(goSilverwingFlag) !is null
        && flag(goSilverwingFlagDrop) is null, "returned to its base");
    assert(copy.members[7].extra[scoreReturns] == 1);

    // Three captures by the Horde.
    foreach (n; 1 .. 4)
    {
        if (n > 1)
        {
            copy.tick(flagRespawnTime + 1.seconds);
            assert(flag(goSilverwingFlag) !is null && flag(goWarsongFlag) !is null, "both flags back after a capture");
        }
        thrall.read();
        rules.objectUsed(copy, 8, flag(goSilverwingFlag));
        assert(rules.areaTrigger(copy, 8, triggerWarsongRoom));
        assert(copy.worldStates[stateCapturesHorde] == n);
    }
    assert(copy.status == BattlegroundStatus.waitLeave && copy.winner == winnerHorde);
    assert(copy.members[8].extra[scoreCaptures] == 3);
    assert(copy.members[8].bonusHonor == 3 * bonusHonor(captureKills) + bonusHonor(winKills),
        "two kills' honor a capture, one more for the win");
}
