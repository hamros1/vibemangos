/**
 * What runs game objects' scripts (`WorldContext.objectScripts`): a use, a signal, or a quest taken or turned in at
 * one; its arrival in the world (`Spawned`); the scripts still busy, ticked each update; and `GoHost`, through which
 * a script acts on its object and the world.
 */
module dmangos.world.objectscripts;

import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.movement : Position;
import dmangos.world.wareffort : WarEffort, WarEffortHost;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.map : Map;
import dmangos.world.npcdata : BroadcastText;
import dmangos.script.api : ActionResult, EntityRef, GameObjectHost, Location, QuestProgress, Waypoint;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class ObjectScripts
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// A game object's use, for its script: the object's script hears of `player` using it; true if
    /// it handled the use (the usual use does not follow).
    bool gameObjectUsed(GameObject go, Map map, ulong player)
    {
        import dmangos.script.api : GameObjectContext, ObjectUsed;

        if (go.instanceId) // the copy's script hears of it first
            if (auto script = go.instanceId in world.instanceScripts)
            {
                import dmangos.script.api : ObjectUsedHere;

                if (script.raise(ObjectUsedHere(EntityRef(go.guid), EntityRef(player))))
                    return true;
            }
        if (!go.behaviour)
            return false;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        world.scripts.raise(go.behaviour, context, ObjectUsed(EntityRef(player)));
        goHost.go = null;
        goHost.map = null;
        noteTickingObject(go, map);
        return context.consumed;
    }

    /// A `Signal` for game object `go`'s script (from its dungeon's script); false if it has none.
    bool gameObjectSignalled(GameObject go, Map map, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : GameObjectContext, Signal;

        if (!go.behaviour)
            return false;
        // A signal may come while another object's script runs (it signalled its dungeon): theirs is kept.
        auto before = goHost.go, beforeMap = goHost.map;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        world.scripts.raise(go.behaviour, context, Signal(from, id, value));
        goHost.go = before;
        goHost.map = beforeMap;
        noteTickingObject(go, map);
        return true;
    }


    package bool[WorldContext.GameObjectOnMap] tickingObjects;
    package GameObjectArrival[] objectArrivals; // scripted game objects put in the world, for `Spawned`

    package static struct GameObjectArrival
    {
        GameObject go;
        Map map;
    }

    /// Raises `event` for game object `go`'s script on `map`; whether the script consumed it.
    package bool raiseObject(E)(GameObject go, Map map, const E event)
    {
        import dmangos.script.api : GameObjectContext;

        if (!go.behaviour || !world.scripts.handles!E(go.behaviour))
            return false;
        // Another object's script may be running (it signalled, it summoned): theirs is kept.
        auto before = goHost.go, beforeMap = goHost.map;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        world.scripts.raise(go.behaviour, context, event);
        goHost.go = before;
        goHost.map = beforeMap;
        noteTickingObject(go, map);
        return context.consumed;
    }

    /// A game object's script with steps pending ticks from now on.
    package void noteTickingObject(GameObject go, Map map)
    {
        if (go.behaviour && world.scripts.busy(go.behaviour))
            tickingObjects[WorldContext.GameObjectOnMap(map, go.guid)] = true;
    }

    /// A player accepted quest `quest` from game object `go`: its script hears of it.
    void gameObjectQuestAccepted(GameObject go, Map map, EntityRef player, uint quest)
    {
        import dmangos.script.api : QuestAccepted;

        raiseObject(go, map, QuestAccepted(player, quest));
    }

    /// A player was rewarded for quest `quest` by game object `go` (the Scarab Gong): its script hears of it.
    void gameObjectQuestRewarded(GameObject go, Map map, EntityRef player, uint quest)
    {
        import dmangos.script.api : QuestRewarded;

        raiseObject(go, map, QuestRewarded(player, quest));
    }

    /// The scripted game objects put in the world since the last tick hear `Spawned` (once their cell has
    /// loaded: what is near them is there), and those with steps pending tick `ms` on.
    package void gameObjectScriptsTick(int ms)
    {
        import dmangos.script.api : GameObjectContext, Spawned;

        if (objectArrivals.length)
        {
            auto arrived = objectArrivals;
            objectArrivals = null;
            foreach (a; arrived)
                if (a.map.findObject(a.go.guid) is a.go)
                    raiseObject(a.go, a.map, Spawned());
        }
        if (!tickingObjects.length)
            return;
        foreach (key, _; tickingObjects.dup)
        {
            auto map = key.map;
            auto go = cast(GameObject) map.findObject(key.guid);
            if (go is null || !go.behaviour || !world.scripts.busy(go.behaviour))
            {
                tickingObjects.remove(key);
                continue;
            }
            auto before = goHost.go, beforeMap = goHost.map;
            goHost.go = go;
            goHost.map = map;
            auto context = GameObjectContext(goHost);
            world.scripts.tick(go.behaviour, context, ms);
            goHost.go = before;
            goHost.map = beforeMap;
            if (!world.scripts.busy(go.behaviour))
                tickingObjects.remove(key);
        }
    }

    package final class GoHost : GameObjectHost
    {
        GameObject go;
        Map map;

        EntityRef hostSelf()
        {
            return EntityRef(go.guid);
        }

        void hostPulseTrap()
        {
            import dmangos.world.auras : makeAura;
            import dmangos.world.spellcast : duration, effectValue, radius;
            import dmangos.world.spellids : SpellEffect;

            const spell = world.data.spells.spell(cast(uint) go.template_.data[3]);
            if (spell is null)
                return;
            // Suppression Aura targets enemies around its caster's location. The device is the
            // source of the debuff, so players must not cast the area effect on one another.
            const level = spell.spellLevel;
            const lasts = duration(*spell, world.client, level);
            int[3] amounts;
            float range = 0;
            foreach (i; 0 .. spell.effect.length)
                if (spell.effect[i] == SpellEffect.applyAura)
                {
                    amounts[i] = effectValue(*spell, i, level, 0);
                    const effectRadius = radius(*spell, i, world.client);
                    if (range < effectRadius)
                        range = effectRadius;
                }
            if (range <= 0)
                return;
            foreach (who; map.near(go.position, range))
                if (auto session = world.trapTarget(go, who))
                    session.addAura(makeAura(spell, go.guid, level, lasts, false, amounts));
        }

        void hostDoor(bool open)
        {
            go.setDoorOpen(open);
            map.flushGameObject(go);
        }

        void hostSignalDungeon(uint id, int value)
        {
            if (go.instanceId)
                world.signalDungeon(go.instanceId, EntityRef(go.guid), id, value);
            else // its continent's script
                world.signalWorld(map.id, EntityRef(go.guid), id, value);
        }

        void hostLog(string text)
        {
            import dmangos.log : info;

            info!"script %s (%s %s): %s"(world.scripts.nameOf(go.behaviour), go.template_.name, go.spawn.guid, text);
        }


        int hostAskDungeon(uint id)
        {
            return go.instanceId ? world.askDungeon(go.instanceId, EntityRef(go.guid), id) : 0;
        }


        void hostCustomAnim()
        {
            import dmangos.world.gameobject : gameObjectAnimation;
            import dmangos.world.opcodes : Opcode;

            map.sendToObservers(go.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, gameObjectAnimation(go.guid, 0));
        }

        void hostPlaySound(uint sound, bool music)
        {
            import dmangos.bytes : ByteWriter;
            import dmangos.world.opcodes : Opcode;

            ByteWriter w;
            w.put(sound);
            map.sendToObservers(go.guid, music ? Opcode.SMSG_PLAY_MUSIC : Opcode.SMSG_PLAY_SOUND, w.data);
        }

        ActionResult hostMoveCreature(EntityRef creature, Location at, uint point, bool run)
        {
            auto c = map.creatureAt(creature.guid);
            if (c is null || c.ai is null || !c.alive)
                return ActionResult.notHere;
            if (c.ai.inCombat)
                return ActionResult.notAllowed;
            c.ai.bind(map);
            c.ai.hostMoveTo(at, point, run);
            map.wake(c.guid);
            return ActionResult.ok;
        }

        ActionResult hostSendHome(EntityRef creature)
        {
            auto c = map.creatureAt(creature.guid);
            if (c is null || c.ai is null || !c.alive)
                return ActionResult.notHere;
            if (c.ai.inCombat)
                return ActionResult.notAllowed;
            world.sendCreatureHome(map, c);
            return ActionResult.ok;
        }

        bool hostHasItem(EntityRef player, uint item)
        {
            auto session = world.onlinePlayer(player.guid);
            return session !is null && session.player !is null && session.player.inventory.count(item, false) > 0;
        }

        uint hostRandom(uint below)
        {
            import std.random : uniform;

            return below == 0 ? 0 : uniform(0, below);
        }

        uint hostMinuteOfDay()
        {
            import std.datetime.systime : Clock;

            const now = Clock.currTime();
            return now.hour * 60 + now.minute;
        }

        uint hostAreaId()
        {
            auto t = world.terrain(map.id);
            const p = go.position;
            return t is null || !t.knows(p.x, p.y) ? 0 : t.zoneAndArea(p.x, p.y, p.z)[1];
        }

        // The war effort:

        uint hostWarEffortPhase()
        {
            return world.warEffortHere.warEffort.phase;
        }

        void hostWarEffortGong(EntityRef player)
        {
            import dmangos.log : info;
            import dmangos.world.wareffort : WarEffortGong, WarEffortGongReply;

            const who = player.guid;
            world.services.call!(WarEffortHost.gong)(WarEffortGong(who), (WarEffortGongReply r) {
                if (r.warBegan)
                    info!"the war effort: player %s rang the Scarab Gong; the ten-hour war begins"(who & 0xFFFF_FFFF);
            });
        }

        ActionResult hostZoneNotice(uint text)
        {
            import dmangos.protocol.chat : chatPacket;

            const said = world.data.npcs.broadcastTexts.get(text, BroadcastText.init);
            auto t = world.terrain(map.id);
            const p = go.position;
            if (said.maleText.length == 0 && said.femaleText.length == 0)
                return ActionResult.failed;
            if (t is null || !t.knows(p.x, p.y))
                return ActionResult.notHere;
            const zone = t.zoneAndArea(p.x, p.y, p.z)[0];
            const message = chatPacket(ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL, Language.LANG_UNIVERSAL, 0, said.text(false));
            foreach (player; world.online.values) // those this node simulates (a zone across nodes: each node's own)
                if (player.character !is null && player.character.data.map == map.id
                        && player.character.data.zone == zone)
                    player.deliver(message);
            return ActionResult.ok;
        }


        QuestProgress hostQuestStatus(EntityRef player, uint quest)
        {
            if (auto who = map.unit(player.guid))
                return who.questStatusOf(quest);
            return QuestProgress.none;
        }

        void hostQuestEvent(EntityRef player, uint quest)
        {
            if (auto who = map.unit(player.guid))
                who.questEventHappened(quest);
        }

        EntityRef hostObjectNearby(uint entry, float range)
        {
            return EntityRef(nearestGameObject(map, go.position, entry, range, go.guid));
        }

        ActionResult hostObjectOpen(EntityRef object, bool open)
        {
            auto other = cast(GameObject) map.findObject(object.guid);
            if (other is null)
                return ActionResult.notHere;
            other.setDoorOpen(open);
            map.flushGameObject(other);
            return ActionResult.ok;
        }

        ActionResult hostObjectFlags(EntityRef object, uint flags, bool set)
        {
            import dmangos.world.updatefields : GAMEOBJECT_FLAGS;

            auto other = cast(GameObject) map.findObject(object.guid);
            if (other is null)
                return ActionResult.notHere;
            const now = other.values.get!GAMEOBJECT_FLAGS;
            other.values.set!GAMEOBJECT_FLAGS(set ? now | flags : now & ~flags);
            map.flushGameObject(other);
            return ActionResult.ok;
        }

        EntityRef hostCreatureNearby(uint entry, float range)
        {
            foreach (c; map.creaturesNear(go.position, range))
                if (c.spawn.entry == entry && c.alive)
                    return EntityRef(c.guid);
            return EntityRef.init;
        }

        EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack)
        {
            import dmangos.world.creature : TempSpawnType;

            auto summoned = world.summonCreature(map, entry, Position(at.x, at.y, at.z, at.orientation),
                despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, go.guid);
            if (summoned is null)
                return EntityRef.init;
            if (attack)
                if (auto victim = map.unit(attack.guid))
                    summoned.ai.attackedBy(victim, map);
            return EntityRef(summoned.guid);
        }

        ActionResult hostSayAs(EntityRef speaker, uint text, EntityRef target)
        {
            if (world.broadcastText(text) is null)
                return ActionResult.failed;
            auto c = map.creatureAt(speaker.guid);
            if (c is null || c.ai is null)
                return ActionResult.notHere;
            c.ai.sayFor(map, text, target.guid);
            return ActionResult.ok;
        }

        void hostKillCredit(EntityRef player, uint entry)
        {
            if (auto who = map.unit(player.guid))
                who.killCreditFrom(entry, go.guid);
        }


        Location hostObjectLocation()
        {
            const p = go.position;
            return Location(p.x, p.y, p.z, p.orientation);
        }

        ActionResult hostObjectSignal(EntityRef to, uint id, int value)
        {
            return world.signalCreature(map, EntityRef(go.guid), to, id, value);
        }

        size_t hostObjectCreaturesNear(uint entry, float range, EntityRef[] found)
        {
            size_t n;
            foreach (c; map.creaturesNear(go.position, range))
                if (n < found.length && c.spawn.entry == entry && c.alive)
                    found[n++] = EntityRef(c.guid);
            return n;
        }

        ActionResult hostObjectCast(EntityRef caster, uint spell, EntityRef target)
        {
            import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;

            if (auto creature = map.creatureAt(caster.guid))
                return creature.ai.castFor(map, spell, target.guid, true);
            auto session = world.onlinePlayer(caster.guid);
            if (session is null || session.player is null || session.currentMap !is map)
                return ActionResult.notHere;
            const info = world.data.spells.spell(spell);
            if (info is null)
                return ActionResult.failed;
            const self = !target || target.guid == caster.guid;
            const result = session.castSpell(info, SpellTargets(self ? TargetFlags.self : TargetFlags.unit,
                self ? caster.guid : target.guid), true, 0);
            return result == SpellCastResult.ok ? ActionResult.ok : ActionResult.notAllowed;
        }
    }

    /// The guid of the nearest game object of `entry` within `range` yards of `center` (not `except`); 0 if none.
    package static ulong nearestGameObject(Map map, Position center, uint entry, float range, ulong except = 0)
    {
        ulong best;
        float bestDistance = float.max;
        foreach (o; map.objectsNear(center, range))
            if (auto g = cast(GameObject) o)
                if (g.template_.entry == entry && g.guid != except)
                {
                    const p = g.position;
                    const d = (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2;
                    if (d <= range * range && d < bestDistance)
                    {
                        bestDistance = d;
                        best = g.guid;
                    }
                }
        return best;
    }

    /// The guid of the nearest game object of `entry` within `range` yards of `center` on `world`; 0 if none.
    ulong gameObjectNear(Map world, Position center, uint entry, float range)
    {
        auto map = world;
        return map is null ? 0 : nearestGameObject(map, center, entry, range);
    }

    /// Uses game object `guid` on `world` as a door or button is used: open for its time.
    ActionResult useGameObject(Map world, ulong guid)
    {
        auto map = world;
        auto g = map is null ? null : cast(GameObject) map.findObject(guid);
        if (g is null)
            return ActionResult.notHere;
        g.useDoorOrButton(map);
        return ActionResult.ok;
    }

    package GoHost goHost_;
    package @property GoHost goHost()
    {
        if (goHost_ is null)
            goHost_ = new GoHost;
        return goHost_;
    }
}
