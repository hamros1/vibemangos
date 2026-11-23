/** Alterac Valley's stables, quartermasters and assault orders. Each copy owns its supplies and troops. */
module dmangos.world.alteracassaults;

import dmangos.world.alterac;
import dmangos.world.battleground : Battleground;
import dmangos.world.character : Character;
import dmangos.world.creature : Creature;
import dmangos.world.movement : Position;
import dmangos.script.api : EntityRef, Location, QuestProgress;
import core.time : Duration, minutes;

enum ValleyOrder : uint { none, deliverMount, collectOrders, cavalry, advance, rescue, beacon, sortie }
struct ValleyChoice { ValleyOrder order; string text; }

immutable uint[2] stableQuest = [7027, 7001], hideQuest = [7026, 7002], stableMasters = [13617, 13616],
    wildMounts = [10990, 10981], collarSpells = [21866, 21794], cavalryChiefs = [13577, 13441],
    riders = [13576, 13440], quartermasters = [12096, 12097], orderItems = [17353, 17442],
    groundQuest = [6846, 6901], groundChiefs = [13446, 13449];
immutable uint[2][2] mineQuest = [[5892, 6982], [6985, 5893]];
immutable Position[2] muster = [Position(-243.75f, -431.32f, 20, 2.59f), Position(-470.38f, -51.84f, 41, 5.93f)];

mixin template ValleyAssaults()
{
    import dmangos.world.alteracassaults;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.bgqueue : BattlegroundStatus;
    import dmangos.script.api : EntityRef, Location, QuestProgress;
    import std.algorithm.searching : canFind;
    import std.math : PI;

    uint[2][2] mineSupplies;
    uint[2] mounts, hides;
    private ulong[ulong] capturedMount;
    private enum Column : ubyte { infantry, cavalry }
    private struct Assault
    {
        ulong[] troops;
        bool marching;
        Duration cooldown;
    }
    private Assault[2][2] assaults;
    private ulong[2] fieldCommander;

    private void transferAssaultState(ref imported!"dmangos.world.battlegroundstate".BattlegroundState state)
    {
        state.transfer(mineSupplies, mounts, hides, capturedMount, assaults, fieldCommander);
    }

    private bool supplied(ubyte side)
    {
        return mineSupplies[side][side] >= 280 || mineSupplies[side][1 - side] >= 70;
    }

    bool groundReady(ubyte side)
    {
        const column = &assaults[side][Column.infantry];
        return supplied(side) && !column.troops.length && column.cooldown <= Duration.zero;
    }

    private void provision(Battleground copy, ubyte side, uint quest, ulong who)
    {
        airTurnIn(quest, side);
        if (quest == stableQuest[side])
            ++mounts[side];
        if (quest == hideQuest[side])
            ++hides[side];
        foreach (mine; 0 .. 2)
            if (quest == mineQuest[side][mine])
                mineSupplies[side][mine] += 10;
        if (quest == groundQuest[side] && groundReady(side))
        {
            auto member = cast(Character) copy.onlinePlayerOf(who);
            if (member is null)
                return;
            if (deploy(copy, side, Column.infantry, member.character.position))
            {
                const mine = mineSupplies[side][side] >= 280 ? side : 1 - side;
                mineSupplies[side][mine] -= mine == side ? 280 : 70;
                copy.addScore(who, scoreSecondary);
            }
        }
    }

    void collar(Battleground copy, Character handler, Creature beast, uint spell)
    {
        auto m = handler.player.guid in copy.members;
        if (m is null || copy.status != BattlegroundStatus.inProgress || !beast.alive)
            return;
        const side = m.team;
        if (beast.template_.entry != wildMounts[side] || spell != collarSpells[side]
            || handler.questStatusOf(stableQuest[side]) != QuestProgress.incomplete)
            return;
        if (handler.player.guid in capturedMount || capturedMount.values.canFind(beast.guid))
            return;
        import dmangos.script.api : Reaction;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;
        auto map = handler.currentMap;
        beast.ai.petStopAttack(map);
        beast.ai.dropThreat(map);
        beast.ai.hostSetFaction(handler.player.values.get!UNIT_FIELD_FACTIONTEMPLATE);
        beast.ai.hostReactState(Reaction.passive);
        capturedMount[handler.player.guid] = beast.guid;
        beast.ai.hostFollow(EntityRef(handler.player.guid), 3, PI);
        copy.context.map(copy.mapId, copy.instance).wake(beast.guid);
    }

    private void clearCaptured(Battleground copy, ulong who)
    {
        if (auto id = who in capturedMount)
        {
            if (auto map = copy.context.existingMap(copy.mapId, copy.instance))
                if (auto beast = map.creatureAt(*id))
                    beast.ai.despawnFor(map, 0);
            capturedMount.remove(who);
        }
    }

    ValleyChoice[] orderChoices(Battleground copy, Character who, Creature npc)
    {
        auto member = who.player.guid in copy.members;
        if (member is null || copy.status != BattlegroundStatus.inProgress || !who.player.alive || !npc.alive)
            return null;
        const side = member.team, entry = npc.template_.entry;
        if (auto choices = airChoices(who, npc, side))
            return choices;
        if (entry == stableMasters[side] && who.questStatusOf(stableQuest[side]) == QuestProgress.incomplete)
            if (auto id = who.player.guid in capturedMount)
                if (auto beast = who.currentMap.creatureAt(*id))
                {
                    const p = beast.position, q = npc.position;
                    if (beast.alive && (p.x - q.x) ^^ 2 + (p.y - q.y) ^^ 2 + (p.z - q.z) ^^ 2 <= 100)
                        return [ValleyChoice(ValleyOrder.deliverMount, "I have brought a mount for the stables.")];
                }
        if (who.player.reputationRank(factions[side]) < ReputationRank.honored)
            return null;
        if (entry == quartermasters[side] && groundReady(side) && !who.player.inventory.count(orderItems[side]))
            return [ValleyChoice(ValleyOrder.collectOrders, "Give me the ground assault orders.")];
        if (entry == cavalryChiefs[side] && mounts[side] >= 25 && hides[side] >= 25
            && !assaults[side][Column.cavalry].troops.length && assaults[side][Column.cavalry].cooldown <= Duration.zero)
            return [ValleyChoice(ValleyOrder.cavalry, "Riders, assemble for the assault!")];
        foreach (ref assault; assaults[side])
            if (!assault.marching && assault.troops.canFind(npc.guid))
                return [ValleyChoice(ValleyOrder.advance, "Advance on the enemy base!")];
        return null;
    }

    void order(Battleground copy, Character who, Creature npc, ValleyOrder order)
    {
        if (!orderChoices(copy, who, npc).canFind!(choice => choice.order == order))
            return;
        const side = copy.members[who.player.guid].team;
        final switch (order)
        {
        case ValleyOrder.none: break;
        case ValleyOrder.rescue, ValleyOrder.beacon, ValleyOrder.sortie:
            wingOrder(copy, who, npc, order);
            break;
        case ValleyOrder.deliverMount:
            who.questEventHappened(stableQuest[side]);
            clearCaptured(copy, who.player.guid);
            break;
        case ValleyOrder.collectOrders:
            if (ensureGroundCommander(copy, side))
                who.giveItem(orderItems[side], 1, true, false);
            break;
        case ValleyOrder.cavalry:
            if (deploy(copy, side, Column.cavalry, npc.position))
            {
                mounts[side] -= 25;
                hides[side] -= 25;
                copy.addScore(who.player.guid, scoreSecondary);
            }
            break;
        case ValleyOrder.advance:
            foreach (ref assault; assaults[side])
                if (assault.troops.canFind(npc.guid))
                {
                    assault.marching = true;
                    foreach (guid; assault.troops)
                        if (auto soldier = who.currentMap.creatureAt(guid))
                            if (soldier.alive)
                                sendToEnemyBase(copy, soldier, side);
                }
            break;
        }
    }

    private bool ensureGroundCommander(Battleground copy, ubyte side)
    {
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.map : MapObject;
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return false;
        if (auto chief = map.creatureAt(fieldCommander[side]))
            if (chief.alive)
                return true;
        foreach (ref spawn; copy.context.data.creatureSpawns)
            if (spawn.map == copy.mapId && spawn.entry == groundChiefs[side])
            {
                map.loadCell(cellKeyAt(spawn.x, spawn.y));
                foreach (c; map.creaturesNear(Position(spawn.x, spawn.y, spawn.z), 40))
                    if (c.template_.entry == groundChiefs[side] && c.alive)
                    {
                        fieldCommander[side] = c.guid;
                        return true;
                    }
                return false;
            }
        const p = muster[side];
        fieldCommander[side] = copy.summonAt(groundChiefs[side], p.x, p.y, p.z, p.orientation);
        return fieldCommander[side] != 0;
    }

    private bool deploy(Battleground copy, ubyte side, Column column, Position p)
    {
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return false;
        auto squad = &assaults[side][column];
        const entry = column == Column.cavalry ? riders[side] : (side == 0 ? 13524u : 13528u) + upgrades[side];
        const count = column == Column.cavalry ? 5 : 10;
        const field = muster[side];
        foreach (i; 0 .. count)
        {
            const dx = (i % 3 - 1) * 3, dy = (i / 3) * 3;
            const guid = copy.summonAt(entry, p.x + dx, p.y + dy, p.z, p.orientation);
            if (!guid)
                continue;
            squad.troops ~= guid;
            auto c = map.creatureAt(guid);
            import dmangos.world.npchandlers : NpcFlag;
            c.ai.hostNpcFlags(c.template_.npcFlags | NpcFlag.gossip);
            c.ai.hostMoveTo(Location(field.x + dx, field.y + dy, field.z, field.orientation), 0, true);
            map.wake(guid);
        }
        squad.marching = false;
        return squad.troops.length > 0;
    }

    private void updateAssaults(Battleground copy, Duration elapsed)
    {
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return;
        foreach (ref forces; assaults)
            foreach (ref squad; forces)
            {
                if (squad.cooldown > Duration.zero)
                    squad.cooldown -= elapsed;
                if (!squad.troops.length)
                    continue;
                size_t alive;
                foreach (guid; squad.troops)
                    if (auto c = map.creatureAt(guid))
                        if (c.alive)
                            squad.troops[alive++] = guid;
                squad.troops.length = alive;
                if (!alive)
                    squad.cooldown = 30.minutes;
            }
        foreach (who; capturedMount.keys)
        {
            auto beast = map.creatureAt(capturedMount[who]);
            auto handler = cast(Character) copy.onlinePlayerOf(who);
            if (who !in copy.members || handler is null || !handler.character.alive || beast is null || !beast.alive
                || handler.questStatusOf(stableQuest[copy.members[who].team]) != QuestProgress.incomplete)
                clearCaptured(copy, who);
        }
    }
}
