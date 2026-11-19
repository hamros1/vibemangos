/**
 * The level 2 GM commands this server's systems support (their permissions and messages match
 * ArcEmu 2.4.3's exactly): `.server saveall`, `.character repairitems`, `.demorph`, `.mount`,
 * `.invincible`, `.npc flags`, `.npc say` and `.npc yell`, `.kill`, `.killplr`, `.reviveplr`,
 * `.castspell`, `.castspellne` and `.castself`, and more. Mixed into
 * `dmangos.world.character.Character`.
 */
module dmangos.world.gmlevel2;

import dmangos.world.spellids;

/// See the module documentation.
mixin template Level2Commands()
{
    import dmangos.world.spellids;
    import core.time : MonoTime;
    import std.format : format;
    import dmangos.world.commands;
    import dmangos.world.inventory : ItemState;
    import dmangos.world.opcodes;
    import dmangos.world.queries : chatMessage, monsterChatMessage;
    import dmangos.world.updatefields;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.player : DeathState;
    import dmangos.world.spells : SpellInfo;

    package bool invincible; // `.invincible`: creatures do not attack it

private:

    bool handleSaveAllCommand()
    {
        const started = MonoTime.currTime;
        uint count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).savePlayer();
            ++count;
        }
        // Every other node of a cluster saves its own (counted by presence).
        if (gmEverywhere(GmRemoteOp.saveAll))
            count += cast(uint) context.remotePlayers.length;
        const message = format!"Saved all %d online players in %d msec."(count,
            (MonoTime.currTime - started).total!"msecs");
        sendWorldText(message);
        sendWorldWideScreenText(message);
        gmLog("saved all players");
        return true;
    }

    /// The game object selected, if it is still on the map.
    GameObject selectedGameObject()
    {
        return selectedGo ? cast(GameObject) map.findObject(selectedGo) : null;
    }

    /// `.npc vendoradditem <item> <amount> [extended cost]`: a ware for the selected vendor.
    bool handleItemCommand(uint item, int amount = -1, uint costId = 0)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.npcdata : VendorItem;
        import dmangos.world.updatefields : UNIT_FIELD_TARGET;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        auto creature = cast(Creature) map.findObject(guid);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        if (amount == -1)
        {
            systemMessage("You need to specify an amount.");
            return true;
        }
        if (costId > 0) // 1.12 has no ItemExtendedCost.dbc
        {
            systemMessage("You've entered invalid extended cost id.");
            return true;
        }
        const entry = creature.spawn.entry;
        string text;
        if (const proto = item in context.data.items)
        {
            // The vendor sells the item by its own `BuyCount`; the amount is not kept.
            auto list = &context.data.npcs.vendors.require(entry, null);
            const slot = cast(uint) list.length;
            *list ~= VendorItem(item, 0, 0, slot, 0);
            context.database.insertVendorItem(entry, item, slot);
            text = format!"Item '%s' '%s' Added to list"(item, proto.details.name);
        }
        else
            text = format!"Item '%s' Not Found in Database."(item);
        gmLog(format!"added item %u to vendor %u"(item, entry));
        systemMessage(text);
        return true;
    }

    /// `.npc vendorremoveitem <item>`.
    bool handleItemRemoveCommand(uint item)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;
        import dmangos.world.creature : Creature;
        import dmangos.world.updatefields : UNIT_FIELD_TARGET;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        auto creature = cast(Creature) map.findObject(guid);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        const entry = creature.spawn.entry;
        auto list = entry in context.data.npcs.vendors;
        const at = list is null ? -1 : (*list).countUntil!(v => v.item == item);
        string text;
        if (at >= 0)
        {
            *list = (*list).remove(at);
            context.database.deleteVendorItem(entry, item);
            if (const proto = item in context.data.items)
                text = format!"Item '%s' '%s' Deleted from list"(item, proto.details.name);
            else
                text = format!"Item '%s' Deleted from list"(item);
            gmLog(format!"removed item %u from vendor %u"(item, entry));
        }
        else
            text = format!"Item '%s' Not Found in List."(item);
        systemMessage(text);
        return true;
    }

    /// `.npc select`: the creature nearest on the ground among those in sight becomes the selection.
    bool handleNpcSelectCommand()
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.updatefields : UNIT_FIELD_TARGET;

        const me = player.position;
        Creature un;
        float dist = 999999.0f;
        foreach (o; map.objectsNear(me, context.config.visibilityDistance))
            if (auto c = cast(Creature) o)
                if (map.seesObject(player.guid, c.guid))
                {
                    const p = c.position;
                    const dist2 = (p.x - me.x) ^^ 2 + (p.y - me.y) ^^ 2;
                    if (dist2 < dist)
                    {
                        un = c;
                        dist = dist2;
                    }
                }
        if (un is null)
        {
            systemMessage("No inrange creatures found.");
            return true;
        }
        player.values.set!UNIT_FIELD_TARGET(un.guid);
        flushPlayerChanges();
        systemMessage(format!"Set selection to %s (%s)"(un.guid, un.template_ is null ? "Unknown" : un.template_.name));
        return true;
    }

    bool handleGOSelect(string arg = null)
    {
        import std.math : sqrt;

        const me = player.position;
        float distanceTo(GameObject go)
        {
            const p = go.position;
            return sqrt((p.x - me.x) ^^ 2 + (p.y - me.y) ^^ 2 + (p.z - me.z) ^^ 2);
        }

        GameObject[] seen; // the objects this player sees
        foreach (o; map.objectsNear(me, context.config.visibilityDistance))
            if (auto go = cast(GameObject) o)
                if (map.seesObject(player.guid, go.guid))
                    seen ~= go;
        GameObject chosen;
        if (arg.length && arg[0] == '1')
        {
            // The one after the selected (or the first): `.gobject select 1` steps through them.
            auto current = selectedGameObject();
            bool next = current is null;
            foreach (go; seen ~ seen)
            {
                if (next)
                {
                    chosen = go;
                    break;
                }
                if (go is current)
                    next = true;
            }
        }
        if (chosen is null)
        {
            float closest = 9999.0f;
            foreach (go; seen)
                if (distanceTo(go) < closest)
                {
                    closest = distanceTo(go);
                    chosen = go;
                }
        }
        if (chosen is null)
        {
            redSystemMessage("No inrange GameObject found.");
            return true;
        }
        selectedGo = chosen.guid;
        greenSystemMessage(format!"Selected GameObject [ %s ] which is %.3f meters away from you."(chosen.template_.name,
            distanceTo(chosen)));
        return true;
    }

    bool handleGOInfo()
    {
        import std.math : sqrt;
        import dmangos.world.gameobject : GameObjectType;

        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        const v = &go.values;
        systemMessage(format!"%s Informations:"(MSG_COLOR_SUBWHITE));
        systemMessage(format!"%s Entry:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, go.spawn.entry));
        systemMessage(format!"%s Model:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_DISPLAYID));
        systemMessage(format!"%s State:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_STATE));
        systemMessage(format!"%s flags:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_FLAGS));
        systemMessage(format!"%s dynflags:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_DYN_FLAGS));
        systemMessage(format!"%s faction:%s%u"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_FACTION));
        static immutable string[] typeNames = ["Door", "Button", "Quest Giver", "Chest", "Binder", "Generic", "Trap",
            "Chair", "Spell Focus", "Text", "Goober", "Transport", "Area Damage", "Camera", "Map Object",
            "Mo Transport", "Duel Arbiter", "Fishing Node", "Ritual", "Mailbox", "Auction House", "Guard Post",
            "Spell Caster", "Meeting Stone", "Flag Stand", "Fishing Hole", "Flag Drop"];
        const type = v.get!GAMEOBJECT_TYPE_ID;
        systemMessage(format!"%s Type:%s%u -- %s"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, type,
            type < typeNames.length ? typeNames[type] : "Unknown."));
        const p = go.position, me = player.position;
        systemMessage(format!"%s Distance:%s%f"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE,
            sqrt((p.x - me.x) ^^ 2 + (p.y - me.y) ^^ 2 + (p.z - me.z) ^^ 2)));
        systemMessage(format!"%s Name:%s%s"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, go.template_.name));
        systemMessage(format!"%s Size:%s%s"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!OBJECT_FIELD_SCALE_X));
        systemMessage(format!"%s Rotation X:%s%f"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_ROTATION(0)));
        systemMessage(format!"%s Rotation Y:%s%f"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_ROTATION(1)));
        systemMessage(format!"%s Rotation O1:%s%f"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_ROTATION(2)));
        systemMessage(format!"%s Rotation O2:%s%f"(MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, v.get!GAMEOBJECT_ROTATION(3)));
        return true;
    }

    bool handleGOActivate()
    {
        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        auto v = &go.values;
        if (v.get!GAMEOBJECT_STATE == 1)
        {
            v.set!GAMEOBJECT_STATE(0u);
            v.set!GAMEOBJECT_FLAGS(v.get!GAMEOBJECT_FLAGS - 1);
            blueSystemMessage("Gameobject closed.");
        }
        else
        {
            v.set!GAMEOBJECT_STATE(1u);
            v.set!GAMEOBJECT_FLAGS(v.get!GAMEOBJECT_FLAGS + 1);
            blueSystemMessage("Gameobject opened.");
        }
        map.flushGameObject(go);
        gmLog(format!"opened/closed gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
        return true;
    }

    bool handleDeleteCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        auto unit = cast(Creature) map.findObject(guid);
        if (unit is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        const at = unit.position;
        gmLog(format!"used npc delete, sqlid %u, creature %s, pos %f %f %f"(unit.spawn.guid, unit.template_.name, at.x, at.y,
            at.z));
        blueSystemMessage(format!"Deleted creature ID %u"(unit.spawn.guid));
        context.deleteCreatureSpawn(map, unit);
        return true;
    }

    bool handleGOSpawn(uint entryId = 0, int save = 0)
    {
        if (entryId == 0)
            return false;
        if (entryId !in context.data.gameObjectTemplates)
        {
            systemMessage(format!"GameObject Info '%s' Not Found"(entryId));
            return true;
        }
        systemMessage(format!"Spawning GameObject By Entry '%s'"(entryId));
        const at = player.position;
        auto go = context.spawnGameObjectAt(map, entryId, at, save > 0);
        gmLog(format!"spawned gameobject %s, entry %u at %u %f %f %f%s"(go.template_.name, entryId, player.data.map, at.x,
            at.y, at.z, save > 0 ? ", saved in DB" : ""));
        return true;
    }

    bool handleGODelete()
    {
        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        context.deleteGameObjectSpawn(map, go);
        gmLog(format!"deleted gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
        selectedGo = 0;
        return true;
    }

    bool handleGOEnable()
    {
        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        if (go.values.get!GAMEOBJECT_DYN_FLAGS == 1)
        {
            go.values.set!GAMEOBJECT_DYN_FLAGS(0u);
            blueSystemMessage("Gameobject deactivated.");
        }
        else
        {
            go.values.set!GAMEOBJECT_DYN_FLAGS(1u);
            blueSystemMessage("Gameobject activated.");
        }
        map.flushGameObject(go);
        gmLog(format!"activated/deactivated gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
        return true;
    }

    bool handleGOScale(float scale = 0)
    {
        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        if (!scale)
            scale = 1;
        go.values.set!OBJECT_FIELD_SCALE_X(scale);
        blueSystemMessage(format!"Set scale to %.3f"(scale));
        gmLog(format!"set scale on gameobject %s to %.3f, entry %u"(go.template_.name, scale, go.spawn.entry));
        // Made anew for the clients to see (the `gameobject` table has no size: it is not saved).
        map.removeObject(go.guid);
        map.addObject(go);
        return true;
    }

    bool handleGOAnimProgress(uint progress = 0)
    {
        auto go = selectedGameObject();
        if (go is null)
            return false;
        go.values.set!GAMEOBJECT_ANIMPROGRESS(progress);
        map.flushGameObject(go);
        blueSystemMessage(format!"Set ANIMPROGRESS to %u"(progress));
        return true;
    }

    bool handleGOMove()
    {
        import dmangos.world.gameobject : GameObjectSpawn;

        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        GameObjectSpawn changed = go.spawn;
        const at = player.position;
        changed.x = at.x;
        changed.y = at.y;
        changed.z = at.z;
        changed.orientation = at.orientation;
        selectedGo = context.respawnGameObjectAs(map, go, changed).guid;
        return true;
    }

    bool handleGORotate(string axis = null, float degrees = 0)
    {
        import std.math : cos, sin, PI;
        import dmangos.world.gameobject : GameObjectSpawn;

        if (axis.length == 0)
            return false;
        auto go = selectedGameObject();
        if (go is null)
        {
            redSystemMessage("No selected GameObject...");
            return true;
        }
        const rad = degrees * (cast(float) PI / 180.0f);
        GameObjectSpawn changed = go.spawn;
        switch (axis[0] | 0x20) // tolower
        {
        case 'x':
            changed.rotation[0] += rad;
            break;
        case 'y':
            changed.rotation[1] += rad;
            break;
        case 'o':
            const o = player.position.orientation;
            changed.rotation[2] = sin(o / 2);
            changed.rotation[3] = cos(o / 2);
            break;
        default:
            redSystemMessage("Invalid Axis, Please use x, y, or o.");
            return true;
        }
        selectedGo = context.respawnGameObjectAs(map, go, changed).guid;
        return true;
    }

    bool handleNpcComeCommand()
    {
        auto creature = getSelectedCreature(true);
        if (creature is null)
            return true;
        npcWalkTo(creature, player.position);
        gmLog(format!"used npc come command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    bool handleNpcReturnCommand()
    {
        auto creature = getSelectedCreature(false);
        if (creature is null)
            return true;
        // Its fight forgotten, back to its spawn point.
        if (creature.ai !is null && creature.ai.inCombat)
        {
            creature.ai.bind(map);
            creature.ai.scriptEvade();
        }
        else
        {
            const s = creature.spawn;
            npcWalkTo(creature, Position(s.x, s.y, s.z, s.orientation));
        }
        gmLog(format!"returned NPC %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
        return true;
    }

    /// A walk to `at`, then what it did before.
    void npcWalkTo(Creature creature, Position at)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : PointMovement;

        auto previous = creature.generator;
        if (auto point = cast(PointMovement) previous)
            previous = point.after;
        auto move = new PointMovement(Vector3(at.x, at.y, at.z), at.orientation, true, previous);
        creature.generator = move;
        move.initialize(creature, map);
        map.wake(creature.guid);
    }

    bool handleResetReputationCommand()
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
        {
            systemMessage("Select a player or yourself first.");
            return true;
        }
        if (plr.player.reputation !is null) // every standing back to its start
        {
            plr.player.reputation.initialize();
            plr.saveReputation();
        }
        systemMessage("Done. Relog for changes to take effect.");
        gmLog(format!"used reset reputation for %s"(plr.player.data.name));
        return true;
    }

    bool handleRepairItemsCommand()
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
            return false;
        foreach (item; plr.player.inventory.all()) // back to full durability
        {
            if (item.durability == item.maxDurability)
                continue;
            if (item.durability == 0 && item.isEquipped)
                plr.player.inventory.equipmentChanged = true; // a broken worn item gives its stats again
            item.values.set!ITEM_FIELD_DURABILITY(item.maxDurability);
            plr.player.inventory.setState(item, ItemState.changed);
        }
        plr.flushInventory();
        systemMessage("Items Repaired");
        return true;
    }

    bool handleDeMorphCommand()
    {
        auto target = getSelectedChar(true);
        if (target is null)
            target = this;
        auto values = &target.player.values; // back to its own model
        values.set!UNIT_FIELD_DISPLAYID(values.get!UNIT_FIELD_NATIVEDISPLAYID);
        target.flushPlayerChanges();
        return true;
    }

    bool handleMountCommand(uint modelId = 0)
    {
        if (modelId == 0)
        {
            redSystemMessage("No model specified");
            return true;
        }
        auto plr = getSelectedChar(false);
        auto creature = plr is null ? getSelectedCreature(false) : null;
        if (plr is null && creature is null)
        {
            redSystemMessage("No target found.");
            return true;
        }
        auto values = plr !is null ? &plr.player.values : &creature.values;
        if (values.get!UNIT_FIELD_MOUNTDISPLAYID != 0)
        {
            redSystemMessage("Target is already mounted.");
            return true;
        }
        values.set!UNIT_FIELD_MOUNTDISPLAYID(modelId);
        if (plr !is null)
            plr.flushPlayerChanges();
        else
            map.flushObjectChanges(creature);
        blueSystemMessage(format!"Now mounted with model %d."(modelId));
        gmLog(format!"used mount command to model %u"(modelId));
        return true;
    }

    // -----------------------------------------------------------------------
    // Killing, reviving and casting
    // -----------------------------------------------------------------------

    bool handleKillCommand()
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto plr = cast(Character) map.find(guid);
        auto creature = plr is null ? cast(Creature) map.findObject(guid) : null;
        if (plr is null && creature is null)
        {
            redSystemMessage("A valid selection is required.");
            return true;
        }
        if (plr !is null)
        {
            gmLog("used kill command on PLAYER " ~ plr.player.data.name);
            // Killed outright, not by damage: god mode does not stop it.
            plr.killedByGm(player.data.name);
            return true;
        }
        gmLog(format!"used kill command on CREATURE %u [%s], sqlid %u%s"(creature.spawn.entry, creature.template_.name,
            creature.spawn.guid, context.groups.of(player.guid) !is null ? ", in group" : ""));
        // Cast insta-kill (Death Touch).
        const deathTouch = context.data.spells.spell(5);
        if (deathTouch is null)
            return false;
        castSpell(deathTouch, SpellTargets(TargetFlags.unit, creature.guid), true, 0);
        return true;
    }

    bool handleKillByPlrCommand(Rest args = Rest.init)
    {
        auto found = context.onlinePlayer(args);
        if (found is null)
        {
            if (const remote = context.remotePlayer(args))
                if (gmElsewhere(args, GmRemoteOp.kill, args))
                {
                    gmLog(format!"remote killed %s (Name: %s)"(remote.entry.guid, remote.entry.name));
                    return true;
                }
            redSystemMessage(format!"Player %s is not online or does not exist."(args));
            return true;
        }
        auto plr = sessionOf(found);
        const wasAlive = plr.player.deathState == DeathState.alive;
        plr.killedByName(gmSink, player.data.name, args);
        if (wasAlive)
            gmLog(format!"remote killed %s (Name: %s)"(plr.player.guid, plr.player.data.name));
        return true;
    }

    bool handleReviveStringcommand(Rest args = Rest.init)
    {
        auto found = context.onlinePlayer(args);
        if (found is null)
        {
            if (context.remotePlayer(args) !is null && gmElsewhere(args, GmRemoteOp.revive, args))
            {
                gmLog("revived player " ~ args);
                return true;
            }
            redSystemMessage(format!"Could not find player %s."(args));
            return true;
        }
        auto plr = sessionOf(found);
        const wasDead = plr.player.deathState != DeathState.alive;
        plr.revivedByName(gmSink, args);
        if (wasDead)
            gmLog("revived player " ~ args);
        return true;
    }

    /// `getSelectedChar(false)`, else `getSelectedCreature(false)`: the cast commands' target, or null after the message.
    Object castTarget()
    {
        if (auto plr = getSelectedChar(false))
            return plr;
        if (auto creature = getSelectedCreature(false))
            return creature;
        redSystemMessage("Must select a char or creature.");
        return null;
    }

    /// `atol`: the number its text starts with (0 if none), and its spell; null after "Invalid spell id!".
    const(SpellInfo)* spellNamed(string args, out uint id)
    {
        import std.ascii : isDigit;
        import std.conv : to;

        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        id = n ? args[0 .. n].to!uint : 0;
        const spell = context.data.spells.spell(id);
        if (spell is null)
            redSystemMessage("Invalid spell id!");
        return spell;
    }

    /// The GM log line for a cast command at `target`.
    void logCast(string what, uint spellId, Object target, bool self)
    {
        import dmangos.world.creature : Creature;

        if (auto plr = cast(Character) target)
        {
            if (!self)
                gmLog(format!"%s %d on PLAYER %s"(what, spellId, plr.player.data.name));
        }
        else if (auto creature = cast(Creature) target)
            gmLog(format!"%s %d on CREATURE %u [%s], sqlid %u"(what, spellId, creature.spawn.entry,
                creature.template_.name, creature.spawn.guid));
    }

    bool handleCastSpellCommand(Rest args = Rest.init)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Casting spell %d on target."(id));
        const guid = guidOf(target);
        castSpell(spell, SpellTargets(TargetFlags.unit, guid), false, 0);
        logCast("casted spell", id, target, target is this);
        return true;
    }

    bool handleCastSpellNECommand(Rest args = Rest.init)
    {
        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Casting spell %d on target."(id));
        // The look of a cast and nothing else, for this GM only (in the 1.12 client's layout).
        import dmangos.world.spellcast : spellGoPacket, spellStartPacket, SpellMissInfo, SpellTargets, TargetFlags,
            TargetResult;

        const targets = SpellTargets(TargetFlags.unit, guidOf(target));
        deliver(Opcode.SMSG_SPELL_START, spellStartPacket(player.guid, id, 0, targets));
        deliver(Opcode.SMSG_SPELL_GO, spellGoPacket(player.guid, id, [TargetResult(guidOf(target), SpellMissInfo.none)],
            targets));
        logCast("casted spell", id, target, target is this);
        return true;
    }

    bool handleCastSelfCommand(Rest args = Rest.init)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto target = castTarget();
        if (target is null)
            return false;
        uint id;
        const spell = spellNamed(args, id);
        if (spell is null)
            return false;
        blueSystemMessage(format!"Target is casting spell %d on himself."(id));
        if (auto plr = cast(Character) target)
            plr.castSpell(spell, SpellTargets(TargetFlags.unit, plr.player.guid), false, 0);
        else if (auto creature = cast(Creature) target)
            creature.ai.castFromCommand(spell, map);
        logCast("used castself with spell", id, target, target is this);
        return true;
    }

    /// The guid of a cast command's target.
    ulong guidOf(Object target)
    {
        import dmangos.world.creature : Creature;

        if (auto plr = cast(Character) target)
            return plr.player.guid;
        return (cast(Creature) target).guid;
    }

    /**
     * `.invisible`: invisible and invincible, or neither again (ArcEmu's `m_isGmInvisible`, `m_invisible`,
     * `bInvincible`): only game masters with their tag on and the player's group see it, creatures leave it
     * alone, its friends are told it went offline.
     */
    bool handleInvisibleCommand()
    {
        string message = "Invisibility and Invincibility are now ";
        const on = !player.gmInvisible;
        player.gmInvisible = on;
        invincible = on;
        announceToFriends(!on);
        message ~= on ? " ON." : " OFF."; // ArcEmu's `"%s ON."` after the space already there
        message ~= " You may have to leave and re-enter this zone for changes to take effect.";
        map.refreshVisibility(this);
        greenSystemMessage(message);
        return true;
    }

    bool handleInvincibleCommand()
    {
        auto chr = getSelectedChar(true);
        string message;
        if (chr !is null)
        {
            chr.invincible = !chr.invincible;
            message = "Invincibility is now " ~ (chr.invincible
                ? "ON. You may have to leave and re-enter this zone for changes to take effect."
                : "OFF. Exit and re-enter this zone for this change to take effect.");
        }
        else
            message = "Select a player or yourself first.";
        if (chr !is null && chr !is this)
            gmLog("toggled invincibility on " ~ chr.player.data.name);
        systemMessage(message.length > 99 ? message[0 .. 99] : message); // at most 99 bytes
        return true;
    }

    bool handleNPCFlagCommand(uint flags)
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        auto creature = getSelectedCreature(false);
        if (creature is null)
        {
            systemMessage("You should select a creature.");
            return true;
        }
        creature.values.set!UNIT_NPC_FLAGS(flags);
        map.flushObjectChanges(creature);
        // Not saved: npc flags are kept in creature_template, which stays as it is.
        systemMessage("Value saved, you may need to rejoin or clean your client cache.");
        gmLog(format!"changed npc flags of creature %u [%s] to %u"(creature.template_.entry, creature.template_.name,
            flags));
        return true;
    }

    /// `.npc say` and `.npc yell`: the selected creature (or player) says it.
    bool monsterChat(string text, bool yell)
    {
        if (auto creature = getSelectedCreature(false))
        {
            const range = yell ? context.config.listenRangeYell : context.config.listenRangeSay;
            const type = yell ? ChatType.CHAT_MSG_MONSTER_YELL : ChatType.CHAT_MSG_MONSTER_SAY;
            map.sendInRange(creature.position, range, Opcode.SMSG_MESSAGECHAT,
                monsterChatMessage(type, creature.guid, creature.template_.name, text));
            return true;
        }
        if (auto plr = getSelectedChar(false))
        {
            const body_ = chatMessage(yell ? ChatType.CHAT_MSG_YELL : ChatType.CHAT_MSG_SAY, Language.LANG_UNIVERSAL,
                plr.player.guid, text);
            plr.map.sendToWatchers(plr, Opcode.SMSG_MESSAGECHAT, body_, true);
            return true;
        }
        redSystemMessage("Please select a creature or player before using this command.");
        return true;
    }

    bool handleMonsterSayCommand(Rest text = Rest.init)
    {
        return monsterChat(text, false);
    }

    bool handleMonsterYellCommand(Rest text = Rest.init)
    {
        return monsterChat(text, true);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * `.kill` on a creature (Death Touch) and on a player, `.killplr`, `.reviveplr`, `.npc respawn`, and the
 * cheats that change casting and damage (`.cheat god`, `.cheat casttime`, `.cheat status`).
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.spells.spells[5] = testSpell(5, 1, 25, 0); // Death Touch
    context.data.spells.spells.edit(5).casting.dmgClass = DamageClass.none;
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto victim = cast(Player) anduin.session.character;

    // Nothing selected.
    gm.say(".kill");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "A valid selection is required.|r"]);

    // `.npc select`: the nearest creature.
    gm.say(".npc select");
    {
        const said = systemMessages(gm.read());
        const chosen = (cast(Player) gm.session.character).values.get!UNIT_FIELD_TARGET;
        assert(chosen != 0 && cast(Creature) map.findObject(chosen) !is null);
        assert(said.length == 1 && said[0].canFind("Set selection to "));
    }

    // `.npc vendoradditem` and `.npc vendorremoveitem` on the innkeeper.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
    gm.say(format!".npc vendoradditem %s"(itemShirt));
    assert(systemMessages(gm.read()) == ["You need to specify an amount."]);
    gm.say(format!".npc vendoradditem %s 1 5"(itemShirt));
    assert(systemMessages(gm.read()) == ["You've entered invalid extended cost id."]);
    gm.say(format!".npc vendoradditem %s 1"(itemShirt));
    assert(systemMessages(gm.read()).length == 1 && db.vendorRows.canFind([creatureInnkeeper, itemShirt]));
    assert(context.data.npcs.vendors[creatureInnkeeper].canFind!(v => v.item == itemShirt));
    gm.say(format!".npc vendorremoveitem %s"(itemShirt));
    assert(systemMessages(gm.read())[0].canFind("Deleted from list") && !db.vendorRows.canFind([creatureInnkeeper, itemShirt]));
    gm.say(format!".npc vendorremoveitem %s"(itemShirt));
    assert(systemMessages(gm.read()) == [format!"Item '%s' Not Found in List."(itemShirt)]);

    // A creature: Death Touch.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
    gm.say(".kill");
    assert(opcodesOf(gm.read()).canFind(Opcode.SMSG_SPELLINSTAKILLLOG) && !keeper.alive, "dead");

    // `.npc respawn` on its corpse: gone now, back a second later.
    gm.say(".npc respawn");
    assert(systemMessages(gm.read())[0].canFind("Respawning a Creature: `"));
    assert(map.findObject(keeper.guid) is null);
    now += 2.seconds;
    context.update(now);
    auto again = cast(Creature) map.findObject(keeper.guid);
    assert(again !is null && again.alive, "back");

    // A player, by selection and by name; and back to life by name.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".kill");
    gm.read();
    assert(victim.deathState == DeathState.corpse);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_LIGHTBLUE ~ "Varian killed you with a GM command.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Player anduin is already dead.|r"]);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Revived player anduin.|r"]);
    assert(victim.deathState == DeathState.alive
        && victim.values.get!UNIT_FIELD_HEALTH == victim.values.get!UNIT_FIELD_MAXHEALTH);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Player anduin is not dead.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Killed player anduin.|r"]);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_LIGHTBLUE ~ "You were killed by Varian with a GM command.|r"]);
    gm.say(".killplr nobody");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Player nobody is not online or does not exist.|r"]);
    gm.say(".reviveplr anduin");
    gm.read();

    // God mode: no damage taken.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".cheat god");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "activated the god mode cheat on Anduin.|r"]);
    assert(systemMessages(anduin.read()) == [MSG_COLOR_GREEN ~ "activated the god mode cheat on you.|r"]);
    const health = victim.values.get!UNIT_FIELD_HEALTH;
    anduin.session.inWorld.unit.spellHitBy(keeper.guid, 50);
    assert(victim.values.get!UNIT_FIELD_HEALTH == health);
    gm.say(".cheat casttime on");
    gm.say(".cheat status");
    const status = systemMessages(gm.read());
    assert(status.canFind(MSG_COLOR_LIGHTBLUE ~ "GodMode: " ~ MSG_COLOR_LIGHTRED ~ "Active"));
    assert(status.canFind(MSG_COLOR_LIGHTBLUE ~ "CastTime: " ~ MSG_COLOR_LIGHTRED ~ "Active"));
    assert(status[$ - 1] == "2 cheats active, 5 inactive.");
}

/// `.npc come` walks the selected creature to the GM; `.npc return` walks it back to its spawn point.
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.creature : Creature;
    import dmangos.world.motion : PointMovement;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8940, -132, 83.53f), AccountLevel.administrator);
    gm.read();
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
    gm.say(".npc come");
    auto walk = cast(PointMovement) keeper.generator;
    assert(walk !is null && !keeper.spline.finalized, "walking to the GM");
    gm.say(".npc return");
    assert(cast(PointMovement) keeper.generator !is null, "and back");
}

/// `.gobject select` the nearest game object, `.gobject info` on it, `.gobject activate` it.
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    gm.read();
    gm.say(".gobject info");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "No selected GameObject...|r"]);

    GameObjectTemplate door = {entry: 9001, type: GameObjectType.door, displayId: 1, name: "Door"};
    context.data.gameObjectTemplates[9001] = door;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90001, 9001, 0, -8949, -131, 83.53f);
    auto go = context.makeGameObject(&context.data.gameObjectSpawns[$ - 1]);
    context.map(0).addObject(go);
    gm.read();

    gm.say(".gobject select");
    assert(systemMessages(gm.read())[0].startsWith(MSG_COLOR_GREEN ~ "Selected GameObject [ Door ] which is 1."));
    gm.say(".gobject info");
    const info = systemMessages(gm.read());
    assert(info.canFind(MSG_COLOR_GREEN ~ " Entry:" ~ MSG_COLOR_LIGHTBLUE ~ "9001"));
    assert(info.canFind(MSG_COLOR_GREEN ~ " Type:" ~ MSG_COLOR_LIGHTBLUE ~ "0 -- Door"));
    gm.say(".gobject activate");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Gameobject closed.|r"] && go.values.get!GAMEOBJECT_STATE == 0);
    gm.say(".gobject activate");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Gameobject opened.|r"] && go.values.get!GAMEOBJECT_STATE == 1);
}

/// `.npc spawn` and `.npc delete`, `.gobject spawn` (saved) and `.gobject delete`: in the world and the database.
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
    import dmangos.world.creature : Creature;
    import dmangos.world.gameobject : GameObjectTemplate, GameObjectType;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8930, -120, 83.53f), AccountLevel.administrator);
    gm.read();
    auto map = context.map(0);

    gm.say(".npc spawn 6774");
    assert(systemMessages(gm.read())[0].startsWith(MSG_COLOR_LIGHTBLUE ~ "Spawned a creature `"));
    assert(db.creatureSpawnRows.length == 1);
    const row = db.creatureSpawnRows.values[0];
    auto spawned = cast(Creature) map.findObject(makeGuidFor(row.entry, row.guid));
    assert(spawned !is null && spawned.template_.entry == 6774);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(spawned.guid));
    gm.say(".npc delete");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Deleted creature ID " ~ format!"%s"(row.guid) ~ "|r"]);
    assert(map.findObject(spawned.guid) is null && db.creatureSpawnRows.length == 0);

    GameObjectTemplate chair = {entry: 9010, type: GameObjectType.chair, displayId: 1, name: "Chair"};
    context.data.gameObjectTemplates[9010] = chair;
    gm.say(".gobject spawn 9010 1");
    assert(systemMessages(gm.read()) == ["Spawning GameObject By Entry '9010'"]);
    assert(db.gameObjectSpawnRows.length == 1);
    gm.say(".gobject select");
    assert(systemMessages(gm.read())[0].canFind("[ Chair ]"));
    gm.say(".gobject scale 2");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Set scale to 2.000|r"]);
    gm.say(".gobject enable");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Gameobject activated.|r"]);
    gm.say(".gobject animprogress 5");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Set ANIMPROGRESS to 5|r"]);
    gm.say(".gobject rotate x 90");
    assert(db.gameObjectSpawnRows.values[0].rotation[0] > 1.5f, "turned and saved");
    gm.say(".gobject rotate q 90");
    assert(systemMessages(gm.read()).canFind(MSG_COLOR_LIGHTRED ~ "Invalid Axis, Please use x, y, or o.|r"));
    gm.say(".gobject move");
    assert(db.gameObjectSpawnRows.length == 1);
    gm.say(".gobject delete");
    assert(db.gameObjectSpawnRows.length == 0);
}

version (unittest) private ulong makeGuidFor(uint entry, uint spawn)
{
    import dmangos.world.objects : HighGuid, makeGuid;

    return makeGuid(HighGuid.unit, entry, spawn);
}
