/**
 * World editing and live game administration.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmworld;

import dmangos.world.character : Character;
import dmangos.world.gameobject : GameObject;
import dmangos.world.movement : Position;

import core.time : MonoTime;
import std.format : format;
import std.math : sqrt;
import dmangos.world.commands : ChatColor, colored, Rest;
import dmangos.world.creature : Creature;
import dmangos.world.gmadmin : msecsSince, numberAtStart;
import dmangos.world.gmtargets : GmRemoteOp;
import dmangos.world.inventory : ItemState;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.player : DeathState;
import dmangos.world.queries : chatMessage, monsterChatMessage;
import dmangos.world.spellcast : SpellTargets, TargetFlags;
import dmangos.world.spells : SpellInfo;
import dmangos.world.updatefields;



/// `.server saveall`: every player saved, on every node, and the world told how long it took.
bool handleSaveAllCommand(Character gm)
{
    const started = MonoTime.currTime;
    uint count;
    foreach (other; gm.context.onlinePlayers)
    {
        gm.sessionOf(other).savePlayer();
        ++count;
    }
    // Every other node of a cluster saves its own (counted by presence).
    if (gm.gmEverywhere(GmRemoteOp.saveAll))
        count += cast(uint) gm.context.remotePlayers.length;
    const message = format!"Saved all %d online players in %d msec."(count, msecsSince(started));
    gm.sendWorldText(message);
    gm.sendWorldWideScreenText(message);
    gm.gmLog("saved all players");
    return true;
}

/// The game object selected, if it is still on the map; null (after a message if `showError`) if not.
GameObject selectedGameObject(Character gm, bool showError)
{
    auto go = gm.selectedGo ? cast(GameObject) gm.map.findObject(gm.selectedGo) : null;
    if (go is null && showError)
        gm.redSystemMessage("Select a game object first.");
    return go;
}

/// How far a game object is from the player, in yards.
float distanceToObject(Character gm, GameObject go)
{
    const at = go.position, here = gm.player.position;
    return sqrt((at.x - here.x) ^^ 2 + (at.y - here.y) ^^ 2 + (at.z - here.z) ^^ 2);
}

/// The selected creature, or null after "No selection." or "Select a creature first.".
Creature selectionAsCreature(Character gm)
{
    const guid = gm.player.values.get!UNIT_FIELD_TARGET;
    if (guid == 0)
    {
        gm.redSystemMessage("No selection.");
        return null;
    }
    auto creature = cast(Creature) gm.map.findObject(guid);
    if (creature is null)
        gm.redSystemMessage("Select a creature first.");
    return creature;
}

/// `.npc vendoradditem <item> <amount> [extended cost]`: a ware for the selected vendor.
bool handleItemCommand(Character gm, uint item, int amount = -1, uint costId = 0)
{
    import dmangos.world.npcdata : VendorItem;

    auto creature = gm.selectionAsCreature();
    if (creature is null)
        return true;
    if (amount == -1)
    {
        gm.redSystemMessage("You need to specify an amount.");
        return true;
    }
    if (costId > 0) // 1.12 has no ItemExtendedCost.dbc
    {
        gm.redSystemMessage("You've entered invalid extended cost id.");
        return true;
    }
    const entry = creature.spawn.entry;
    if (const proto = item in gm.context.data.items)
    {
        // The vendor sells the item by its own `BuyCount`; the amount is not kept.
        auto wares = &gm.context.data.npcs.vendors.require(entry, null);
        const slot = cast(uint) wares.length;
        *wares ~= VendorItem(item, 0, 0, slot, 0);
        gm.context.database.insertVendorItem(entry, item);
        gm.greenSystemMessage(format!"Item '%s' '%s' Added to list"(item, proto.details.name));
    }
    else
        gm.redSystemMessage(format!"Item '%s' Not Found in Database."(item));
    gm.gmLog(format!"added item %u to vendor %u"(item, entry));
    return true;
}

/// `.npc vendorremoveitem <item>`: a ware taken off the selected vendor.
bool handleItemRemoveCommand(Character gm, uint item)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    auto creature = gm.selectionAsCreature();
    if (creature is null)
        return true;
    const entry = creature.spawn.entry;
    auto wares = entry in gm.context.data.npcs.vendors;
    const index = wares is null ? -1 : (*wares).countUntil!(ware => ware.item == item);
    if (index < 0)
    {
        gm.redSystemMessage(format!"Item '%s' Not Found in List."(item));
        return true;
    }
    *wares = (*wares).remove(index);
    gm.context.database.deleteVendorItem(entry, item);
    if (const proto = item in gm.context.data.items)
        gm.greenSystemMessage(format!"Item '%s' '%s' Deleted from list"(item, proto.details.name));
    else
        gm.greenSystemMessage(format!"Item '%s' Deleted from list"(item));
    gm.gmLog(format!"removed item %u from vendor %u"(item, entry));
    return true;
}

/// `.npc select`: the creature nearest on the ground among those in sight becomes the selection.
bool handleNpcSelectCommand(Character gm)
{
    const here = gm.player.position;
    Creature nearest;
    float nearestSquared = 999_999.0f;
    foreach (object; gm.map.objectsNear(here, gm.context.config.visibilityDistance))
    {
        auto creature = cast(Creature) object;
        if (creature is null || !gm.map.seesObject(gm.player.guid, creature.guid))
            continue;
        const at = creature.position;
        const squared = (at.x - here.x) ^^ 2 + (at.y - here.y) ^^ 2;
        if (squared < nearestSquared)
        {
            nearest = creature;
            nearestSquared = squared;
        }
    }
    if (nearest is null)
    {
        gm.redSystemMessage("No inrange creatures found.");
        return true;
    }
    gm.player.values.set!UNIT_FIELD_TARGET(nearest.guid);
    gm.flushPlayerChanges();
    gm.greenSystemMessage(format!"Set selection to %s (%s)"(nearest.guid,
        nearest.template_ is null ? "Unknown" : nearest.template_.name));
    return true;
}

/// `.gobject select [1]`: the nearest game object in sight selected, or with 1 the one after the selection.
bool handleGameObjectSelectCommand(Character gm, string mode = null)
{
    import std.algorithm.searching : countUntil;

    GameObject[] seen;
    foreach (object; gm.map.objectsNear(gm.player.position, gm.context.config.visibilityDistance))
        if (auto go = cast(GameObject) object)
            if (gm.map.seesObject(gm.player.guid, go.guid))
                seen ~= go;
    GameObject chosen;
    if (mode.length && mode[0] == '1' && seen.length)
    {
        // The one after the selected (or the first): `.gobject select 1` steps through them.
        auto current = gm.selectedGameObject(false);
        const index = seen.countUntil!(go => go is current);
        if (current is null)
            chosen = seen[0];
        else if (index >= 0)
            chosen = seen[(index + 1) % seen.length];
    }
    if (chosen is null)
    {
        float closest = 9999.0f;
        foreach (go; seen)
        {
            const distance = gm.distanceToObject(go);
            if (distance < closest)
            {
                closest = distance;
                chosen = go;
            }
        }
    }
    if (chosen is null)
    {
        gm.redSystemMessage("No inrange GameObject found.");
        return true;
    }
    gm.selectedGo = chosen.guid;
    gm.greenSystemMessage(format!"Selected GameObject [ %s ] which is %.3f meters away from you."(
        chosen.template_.name, gm.distanceToObject(chosen)));
    return true;
}

/// `.addtrainerspell <teaching spell> [copper] [level]`: a lesson for the selected trainer, saved.
bool handleAddTrainerSpellCommand(Character gm, uint spell, uint cost = 0, ubyte requiredLevel = 0)
{
    import std.algorithm.searching : canFind;
    import dmangos.mysql : DatabaseException;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.npcdata : trainerLesson;

    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    if (!(creature.values.get!UNIT_NPC_FLAGS & NpcFlag.trainer))
    {
        gm.redSystemMessage("Select a trainer first.");
        return true;
    }
    const lesson = trainerLesson(gm.context.data.spells, spell, cost, requiredLevel);
    if (!lesson.learnedSpell)
    {
        gm.redSystemMessage("Use the ID of a supported trainer spell that teaches a lesson.");
        return true;
    }
    const entry = creature.template_.entry;
    if (gm.trainerSpells(creature).canFind!(existing => existing.learnedSpell == lesson.learnedSpell))
    {
        gm.redSystemMessage("The trainer already offers that lesson.");
        return true;
    }
    try
    {
        if (!gm.context.canWrite() || !gm.context.database.insertTrainerLesson(entry, spell, cost, requiredLevel))
        {
            gm.redSystemMessage("The lesson could not be added. It may already be saved.");
            return true;
        }
        gm.context.data.npcs.trainers[entry] ~= lesson;
        gm.gmLog(format!"added trainer spell %s at entry %s, cost %s, required level %s"(spell, entry, cost,
            requiredLevel));
        gm.greenSystemMessage(format!("Trainer %s will teach %s. Other workers will load the lesson on their next "
            ~ "catalog refresh.")(entry, lesson.learnedSpell));
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not save the lesson.");
    return true;
}

/// `.npc listAgent`: the selected creature's script, spell list and EventAI events.
bool handleListAiAgentCommand(Character gm)
{
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    const entry = creature.template_.entry, spawn = creature.spawn.guid;
    const spellList = creature.template_.spellList;
    const scriptName = gm.context.data.creatureScriptNames.get(entry, "");
    const events = gm.context.data.eventAi.byCreature.get(entry, null);
    const spawnEvents = gm.context.data.eventAi.bySpawn.get(spawn, null);
    gm.systemMessage(format!("Creature %s, spawn %s, script %s, spell list %s, EventAI events %s by entry and %s "
        ~ "by spawn.")(entry, spawn, scriptName.length ? scriptName : "none", spellList, events.length,
        spawnEvents.length));
    foreach (ref spell; gm.context.data.creatureSpellLists.get(spellList, null))
        gm.systemMessage(format!"Spell %s, target %s, availability %s%%, repeat %s–%s ms."(spell.spell,
            spell.targetId, spell.availability, spell.repeatMin, spell.repeatMax));
    return true;
}

/// `.gobject export`: the selected game object's spawn, as its row would hold it.
bool handleGameObjectExportCommand(Character gm)
{
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    const at = go.position;
    const rotation = go.spawn.rotation;
    gm.systemMessage(format!"Game object %s, spawn %s, map %s, position %.6f %.6f %.6f %.6f."(go.spawn.entry,
        go.spawn.guid, gm.map.id, at.x, at.y, at.z, at.orientation));
    gm.systemMessage(format!"Rotation %.6f %.6f %.6f %.6f, respawn %s seconds."(rotation[0], rotation[1],
        rotation[2], rotation[3], go.spawn.respawnSeconds));
    return true;
}

/// `.gobject info`: the selected game object's fields and distance.
bool handleGameObjectInfoCommand(Character gm)
{
    import dmangos.world.gameobject : GameObjectType;

    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    ref const values = go.values;
    gm.colorSystemMessage(ChatColor.silver, go.template_.name);
    void field(T)(string label, T value)
    {
        gm.systemMessage(colored(ChatColor.green, label) ~ "  " ~ colored(ChatColor.sky, format!"%s"(value)));
    }
    field("Entry", go.spawn.entry);
    field("Model", values.get!GAMEOBJECT_DISPLAYID);
    field("State", values.get!GAMEOBJECT_STATE);
    field("Flags", values.get!GAMEOBJECT_FLAGS);
    field("Dynamic flags", values.get!GAMEOBJECT_DYN_FLAGS);
    field("Faction", values.get!GAMEOBJECT_FACTION);
    field("Type", cast(GameObjectType) values.get!GAMEOBJECT_TYPE_ID);
    field("Distance", format!"%.2f"(gm.distanceToObject(go)));
    field("Scale", values.get!OBJECT_FIELD_SCALE_X);
    field("Rotation", format!"%.3f, %.3f, %.3f, %.3f"(values.get!GAMEOBJECT_ROTATION(0),
        values.get!GAMEOBJECT_ROTATION(1), values.get!GAMEOBJECT_ROTATION(2), values.get!GAMEOBJECT_ROTATION(3)));
    return true;
}

/// `.gobject activate`: the selected game object opened, or closed if it is open.
bool handleGameObjectActivateCommand(Character gm)
{
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    ref values = go.values;
    if (values.get!GAMEOBJECT_STATE == 1)
    {
        values.set!GAMEOBJECT_STATE(0u);
        values.set!GAMEOBJECT_FLAGS(values.get!GAMEOBJECT_FLAGS - 1);
        gm.blueSystemMessage("Gameobject closed.");
    }
    else
    {
        values.set!GAMEOBJECT_STATE(1u);
        values.set!GAMEOBJECT_FLAGS(values.get!GAMEOBJECT_FLAGS + 1);
        gm.blueSystemMessage("Gameobject opened.");
    }
    gm.map.flushGameObject(go);
    gm.gmLog(format!"opened/closed gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
    return true;
}

/// `.npc delete`: the selected creature's spawn deleted, from the world and the database.
bool handleDeleteCommand(Character gm)
{
    auto creature = gm.selectionAsCreature();
    if (creature is null)
        return true;
    const at = creature.position;
    if (!gm.context.spawnEditor.deleteCreatureSpawn(gm.map, creature))
    {
        gm.redSystemMessage("Could not delete the creature.");
        return true;
    }
    gm.gmLog(format!"used npc delete, sqlid %u, creature %s, pos %f %f %f"(creature.spawn.guid,
        creature.template_.name, at.x, at.y, at.z));
    gm.blueSystemMessage(format!"Deleted creature ID %u"(creature.spawn.guid));
    return true;
}

/// `.gobject spawn <entry> [save]`: a game object at the GM's position, saved if `save` is positive.
bool handleGameObjectSpawnCommand(Character gm, uint entry = 0, int save = 0)
{
    if (entry == 0)
        return false;
    if (entry !in gm.context.data.gameObjectTemplates)
    {
        gm.redSystemMessage(format!"GameObject Info '%s' Not Found"(entry));
        return true;
    }
    const at = gm.player.position;
    auto go = gm.context.spawnEditor.spawnGameObjectAt(gm.map, entry, at, save > 0);
    if (go is null)
    {
        gm.redSystemMessage("Could not spawn the game object.");
        return true;
    }
    gm.greenSystemMessage(format!"Spawning GameObject By Entry '%s'"(entry));
    gm.gmLog(format!"spawned gameobject %s, entry %u at %u %f %f %f%s"(go.template_.name, entry, gm.player.data.map,
        at.x, at.y, at.z, save > 0 ? ", saved in DB" : ""));
    return true;
}

/// `.gobject delete`: the selected game object's spawn deleted.
bool handleGameObjectDeleteCommand(Character gm)
{
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    if (!gm.context.spawnEditor.deleteGameObjectSpawn(gm.map, go))
    {
        gm.redSystemMessage("Could not delete the game object.");
        return true;
    }
    gm.gmLog(format!"deleted gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
    gm.selectedGo = 0;
    return true;
}

/// `.gobject enable`: the selected game object's dynamic flag toggled.
bool handleGameObjectEnableCommand(Character gm)
{
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    if (go.values.get!GAMEOBJECT_DYN_FLAGS == 1)
    {
        go.values.set!GAMEOBJECT_DYN_FLAGS(0u);
        gm.blueSystemMessage("Gameobject deactivated.");
    }
    else
    {
        go.values.set!GAMEOBJECT_DYN_FLAGS(1u);
        gm.blueSystemMessage("Gameobject activated.");
    }
    gm.map.flushGameObject(go);
    gm.gmLog(format!"activated/deactivated gameobject %s, entry %u"(go.template_.name, go.spawn.entry));
    return true;
}

/// `.gobject scale [scale]`: the selected game object's size (1 by default), not saved.
bool handleGameObjectScaleCommand(Character gm, float scale = 0)
{
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    if (!scale)
        scale = 1;
    go.values.set!OBJECT_FIELD_SCALE_X(scale);
    gm.blueSystemMessage(format!"Set scale to %.3f"(scale));
    gm.gmLog(format!"set scale on gameobject %s to %.3f, entry %u"(go.template_.name, scale, go.spawn.entry));
    // Made anew for the clients to see (the `gameobject` table has no size: it is not saved).
    gm.map.removeObject(go.guid);
    gm.map.addObject(go);
    return true;
}

/// `.gobject animprogress <progress>`.
bool handleGameObjectAnimProgressCommand(Character gm, uint progress = 0)
{
    auto go = gm.selectedGameObject(false);
    if (go is null)
        return false;
    go.values.set!GAMEOBJECT_ANIMPROGRESS(progress);
    gm.map.flushGameObject(go);
    gm.blueSystemMessage(format!"Set ANIMPROGRESS to %u"(progress));
    return true;
}

/// `.gobject move`: the selected game object's spawn moved to the GM's position.
bool handleGameObjectMoveCommand(Character gm)
{
    import dmangos.world.gameobject : GameObjectSpawn;

    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    GameObjectSpawn changed = go.spawn;
    const at = gm.player.position;
    changed.x = at.x;
    changed.y = at.y;
    changed.z = at.z;
    changed.orientation = at.orientation;
    if (auto moved = gm.context.spawnEditor.respawnGameObjectAs(gm.map, go, changed))
        gm.selectedGo = moved.guid;
    else
        gm.redSystemMessage("Could not move the game object.");
    return true;
}

/// `.gobject rotate <x|y|o> [degrees]`: the selected game object turned about an axis, or to the GM's facing.
bool handleGameObjectRotateCommand(Character gm, string axis = null, float degrees = 0)
{
    import std.ascii : toLower;
    import std.math : cos, sin, PI;
    import dmangos.world.gameobject : GameObjectSpawn;

    if (axis.length == 0)
        return false;
    auto go = gm.selectedGameObject(true);
    if (go is null)
        return true;
    const radians = degrees * (cast(float) PI / 180.0f);
    GameObjectSpawn changed = go.spawn;
    switch (axis[0].toLower)
    {
    case 'x':
        changed.rotation[0] += radians;
        break;
    case 'y':
        changed.rotation[1] += radians;
        break;
    case 'o':
        const facing = gm.player.position.orientation;
        changed.rotation[2] = sin(facing / 2);
        changed.rotation[3] = cos(facing / 2);
        break;
    default:
        gm.redSystemMessage("Choose an axis: x, y, or o.");
        return true;
    }
    if (auto rotated = gm.context.spawnEditor.respawnGameObjectAs(gm.map, go, changed))
        gm.selectedGo = rotated.guid;
    else
        gm.redSystemMessage("Could not rotate the game object.");
    return true;
}

/// `.npc come`: the selected creature walks to the GM.
bool handleNpcComeCommand(Character gm)
{
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    gm.npcWalkTo(creature, gm.player.position);
    gm.gmLog(format!"used npc come command on %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
    return true;
}

/// `.npc possess`: the GM controls the selected creature, as the client controls a charmed one.
bool handleNpcPossessCommand(Character gm)
{
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    if (!gm.player.alive || !creature.alive || creature.ai is null || (creature.petOwner && creature !is gm.ownPet)
        || creature.values.get!UNIT_FIELD_CHARMEDBY)
    {
        gm.redSystemMessage("This creature cannot be possessed.");
        return true;
    }
    gm.takeCharm(creature, null, true);
    return true;
}

/// `.npc unpossess`: the possessed creature let go.
bool handleNpcUnPossessCommand(Character gm)
{
    gm.releaseCharmForHandoff();
    return true;
}

/// `.npc return`: the selected creature's fight forgotten, or a walk back to its spawn point.
bool handleNpcReturnCommand(Character gm)
{
    auto creature = gm.selectedCreature(false);
    if (creature is null)
        return true;
    if (creature.ai !is null && creature.ai.inCombat)
    {
        creature.ai.bind(gm.map);
        creature.ai.scriptEvade();
    }
    else
    {
        const spawn = creature.spawn;
        gm.npcWalkTo(creature, Position(spawn.x, spawn.y, spawn.z, spawn.orientation));
    }
    gm.gmLog(format!"returned NPC %s, sqlid %u"(creature.template_.name, creature.spawn.guid));
    return true;
}

/// A walk to `at`, then what it did before.
void npcWalkTo(Character gm, Creature creature, Position at)
{
    import dmangos.vmap.math : Vector3;
    import dmangos.world.motion : PointMovement;

    auto previous = creature.generator;
    if (auto point = cast(PointMovement) previous)
        previous = point.after;
    auto move = new PointMovement(Vector3(at.x, at.y, at.z), at.orientation, true, previous);
    creature.generator = move;
    move.initialize(creature, gm.map);
    gm.map.wake(creature.guid);
}

/// `.character resetreputation`: every standing of the selected player back to its start.
bool handleResetReputationCommand(Character gm)
{
    auto target = gm.selectedCharacter(false);
    if (target is null)
    {
        gm.redSystemMessage("Select a player or yourself first.");
        return true;
    }
    if (target.player.reputation !is null)
    {
        target.player.reputation.initialize();
        target.saveReputation();
    }
    gm.greenSystemMessage("Done. Relog for changes to take effect.");
    gm.gmLog(format!"used reset reputation for %s"(target.player.data.name));
    return true;
}

/// `.character repairitems`: the selected player's items back to full durability.
bool handleRepairItemsCommand(Character gm)
{
    auto target = gm.selectedCharacter(false);
    if (target is null)
        return false;
    foreach (item; target.player.inventory.all())
    {
        if (item.durability == item.maxDurability)
            continue;
        if (item.durability == 0 && item.isEquipped)
            target.player.inventory.equipmentChanged = true; // a broken worn item gives its stats again
        item.values.set!ITEM_FIELD_DURABILITY(item.maxDurability);
        target.player.inventory.setState(item, ItemState.changed);
    }
    target.flushInventory();
    gm.greenSystemMessage("Items Repaired");
    return true;
}

/// `.demorph`: the selected player (or the GM) back to its own model.
bool handleDeMorphCommand(Character gm)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
        target = gm;
    ref values = target.player.values;
    values.set!UNIT_FIELD_DISPLAYID(values.get!UNIT_FIELD_NATIVEDISPLAYID);
    target.flushPlayerChanges();
    return true;
}

/// `.mount <model>`: the selected player or creature mounted on a model.
bool handleMountCommand(Character gm, uint modelId = 0)
{
    if (modelId == 0)
    {
        gm.redSystemMessage("No model specified");
        return true;
    }
    auto target = gm.selectedCharacter(false);
    auto creature = target is null ? gm.selectedCreature(false) : null;
    if (target is null && creature is null)
    {
        gm.redSystemMessage("No target found.");
        return true;
    }
    ref values = target !is null ? target.player.values : creature.values;
    if (values.get!UNIT_FIELD_MOUNTDISPLAYID != 0)
    {
        gm.redSystemMessage("Target is already mounted.");
        return true;
    }
    values.set!UNIT_FIELD_MOUNTDISPLAYID(modelId);
    if (target !is null)
        target.flushPlayerChanges();
    else
        gm.map.flushObjectChanges(creature);
    gm.blueSystemMessage(format!"Now mounted with model %d."(modelId));
    gm.gmLog(format!"used mount command to model %u"(modelId));
    return true;
}

// -----------------------------------------------------------------------
// Killing, reviving and casting
// -----------------------------------------------------------------------

/// `.kill`: the selected player killed outright, or the selected creature by Death Touch.
bool handleKillCommand(Character gm)
{
    enum uint deathTouch = 5;
    const guid = gm.player.values.get!UNIT_FIELD_TARGET;
    if (auto target = cast(Character) gm.map.find(guid))
    {
        gm.gmLog("used kill command on PLAYER " ~ target.player.data.name);
        // Killed outright, not by damage: god mode does not stop it.
        target.killedByGm(gm.player.data.name);
        return true;
    }
    auto creature = cast(Creature) gm.map.findObject(guid);
    if (creature is null)
    {
        gm.redSystemMessage("Select a unit first.");
        return true;
    }
    gm.gmLog(format!"used kill command on CREATURE %u [%s], sqlid %u%s"(creature.spawn.entry, creature.template_.name,
        creature.spawn.guid, gm.context.groups.of(gm.player.guid) !is null ? ", in group" : ""));
    const spell = gm.context.data.spells.spell(deathTouch);
    if (spell is null)
        return false;
    gm.castSpell(spell, SpellTargets(TargetFlags.unit, creature.guid), true, 0);
    return true;
}

/// `.killplr <name>`: the named player killed, on any node.
bool handleKillByPlrCommand(Character gm, Rest name = Rest.init)
{
    auto found = gm.context.onlinePlayer(name);
    if (found is null)
    {
        if (const remote = gm.context.remotePlayer(name))
            if (gm.gmElsewhere(name, GmRemoteOp.kill, name))
            {
                gm.gmLog(format!"remote killed %s (Name: %s)"(remote.entry.guid, remote.entry.name));
                return true;
            }
        gm.redSystemMessage(format!"Player %s is not online or does not exist."(name));
        return true;
    }
    auto target = gm.sessionOf(found);
    const wasAlive = target.player.deathState == DeathState.alive;
    target.killedByName(gm.gmSink, gm.player.data.name, name);
    if (wasAlive)
        gm.gmLog(format!"remote killed %s (Name: %s)"(target.player.guid, target.player.data.name));
    return true;
}

/// `.reviveplr <name>`: the named player alive again, on any node.
bool handleReviveByNameCommand(Character gm, Rest name = Rest.init)
{
    auto found = gm.context.onlinePlayer(name);
    if (found is null)
    {
        if (gm.context.remotePlayer(name) !is null && gm.gmElsewhere(name, GmRemoteOp.revive, name))
        {
            gm.gmLog("revived player " ~ name);
            return true;
        }
        gm.redSystemMessage(format!"Could not find player %s."(name));
        return true;
    }
    auto target = gm.sessionOf(found);
    const wasDead = target.player.deathState != DeathState.alive;
    target.revivedByName(gm.gmSink, name);
    if (wasDead)
        gm.gmLog("revived player " ~ name);
    return true;
}

/// The cast commands' target: the selected player, else the selected creature; null after a message.
Object castTarget(Character gm)
{
    if (auto character = gm.selectedCharacter(false))
        return character;
    if (auto creature = gm.selectedCreature(false))
        return creature;
    gm.redSystemMessage("Must select a char or creature.");
    return null;
}

/// The spell whose id `text` starts with (`numberAtStart`), and the id; null after "Invalid spell id!".
const(SpellInfo)* spellNamed(Character gm, string text, out uint id)
{
    id = numberAtStart(text);
    const spell = gm.context.data.spells.spell(id);
    if (spell is null)
        gm.redSystemMessage("Invalid spell id!");
    return spell;
}

/// The guid of a cast command's target.
ulong guidOf(Character gm, Object target)
{
    if (auto character = cast(Character) target)
        return character.player.guid;
    return (cast(Creature) target).guid;
}

/// The GM log line for a cast command at `target` (none for the GM's own casts at itself).
void logCast(Character gm, string action, uint spellId, Object target, bool self)
{
    if (auto character = cast(Character) target)
    {
        if (!self)
            gm.gmLog(format!"%s %d on PLAYER %s"(action, spellId, character.player.data.name));
    }
    else if (auto creature = cast(Creature) target)
        gm.gmLog(format!"%s %d on CREATURE %u [%s], sqlid %u"(action, spellId, creature.spawn.entry,
            creature.template_.name, creature.spawn.guid));
}

/// `.debug castspell <spell>`: the GM casts a spell at the selected player or creature.
bool handleCastSpellCommand(Character gm, Rest args = Rest.init)
{
    auto target = gm.castTarget();
    if (target is null)
        return true;
    uint id;
    const spell = gm.spellNamed(args, id);
    if (spell is null)
        return id != 0; // no number at all: the usage too
    gm.blueSystemMessage(format!"Casting spell %d on target."(id));
    gm.castSpell(spell, SpellTargets(TargetFlags.unit, gm.guidOf(target)), false, 0);
    gm.logCast("casted spell", id, target, target is gm);
    return true;
}

/// `.debug castspellne <spell>`: the look of a cast and nothing else, for this GM only (in the 1.12 client's
/// layout).
bool handleCastSpellPreviewCommand(Character gm, Rest args = Rest.init)
{
    import dmangos.world.spellcast : spellGoPacket, spellStartPacket, SpellMissInfo, TargetResult;

    auto target = gm.castTarget();
    if (target is null)
        return true;
    uint id;
    const spell = gm.spellNamed(args, id);
    if (spell is null)
        return id != 0; // no number at all: the usage too
    gm.blueSystemMessage(format!"Casting spell %d on target."(id));
    const guid = gm.guidOf(target);
    const targets = SpellTargets(TargetFlags.unit, guid);
    gm.deliver(Opcode.SMSG_SPELL_START, spellStartPacket(gm.player.guid, id, 0, targets));
    gm.deliver(Opcode.SMSG_SPELL_GO, spellGoPacket(gm.player.guid, id, [TargetResult(guid, SpellMissInfo.none)],
        targets));
    gm.logCast("casted spell", id, target, target is gm);
    return true;
}

/// `.debug castself <spell>`: the selected player or creature casts a spell at itself.
bool handleCastSelfCommand(Character gm, Rest args = Rest.init)
{
    auto target = gm.castTarget();
    if (target is null)
        return true;
    uint id;
    const spell = gm.spellNamed(args, id);
    if (spell is null)
        return id != 0; // no number at all: the usage too
    gm.blueSystemMessage(format!"Target is casting spell %d on himself."(id));
    if (auto character = cast(Character) target)
        character.castSpell(spell, SpellTargets(TargetFlags.unit, character.player.guid), false, 0);
    else if (auto creature = cast(Creature) target)
        creature.ai.castFromCommand(spell, gm.map);
    gm.logCast("used castself with spell", id, target, target is gm);
    return true;
}

/**
 * `.invisible`: invisible and invincible, or neither again: only game masters with their tag on and the
 * player's group see it, creatures leave it alone, its friends are told it went offline.
 */
bool handleInvisibleCommand(Character gm)
{
    const on = !gm.player.gmInvisible;
    gm.player.gmInvisible = on;
    gm.invincible = on;
    gm.announceToFriends(!on);
    gm.map.refreshVisibility(gm);
    // Two spaces before ON or OFF, as players have always seen it.
    gm.greenSystemMessage(format!("Invisibility and Invincibility are now  %s. You may have to leave and re-enter "
        ~ "this zone for changes to take effect.")(on ? "ON" : "OFF"));
    return true;
}

/// `.guild create <name>`: a guild of the selected player, who leads it alone.
bool handleGuildCreateCommand(Character gm, Rest name = Rest.init)
{
    import std.ascii : isAlpha;

    if (name.length == 0)
        return false;
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return false;
    if (target.ownGuild() !is null)
    {
        gm.redSystemMessage(format!"%s is already in a guild."(target.player.data.name));
        return true;
    }
    if (name.length > 75)
    {
        gm.redSystemMessage(format!"The name is %s characters too long."(name.length - 75));
        return true;
    }
    foreach (c; name)
        if (!isAlpha(c) && c != ' ')
        {
            gm.redSystemMessage("Error, name can only contain chars A-Z and a-z.");
            return true;
        }
    if (gm.context.guilds.named(name) !is null)
    {
        gm.redSystemMessage("Guild name is already taken.");
        return true;
    }
    target.gmFoundGuild(name);
    gm.context.guildFieldsHere();
    gm.greenSystemMessage("Guild created");
    return true;
}

/// `.invincible`: creatures leave the selected player (or the GM) alone, or no longer.
bool handleInvincibleCommand(Character gm)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
    {
        gm.redSystemMessage("Select a player or yourself first.");
        return true;
    }
    target.invincible = !target.invincible;
    if (target !is gm)
        gm.gmLog("toggled invincibility on " ~ target.player.data.name);
    gm.greenSystemMessage("Invincibility is now " ~ (target.invincible
        ? "ON. You may have to leave and re-enter this zone for changes to take effect."
        : "OFF. Exit and re-enter this zone for this change to take effect."));
    return true;
}

/// `.npc flags <flags>`: the selected creature's NPC flags until it respawns (the template is not changed).
bool handleNpcFlagCommand(Character gm, uint flags)
{
    if (gm.player.values.get!UNIT_FIELD_TARGET == 0)
    {
        gm.redSystemMessage("No selection.");
        return true;
    }
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    creature.values.set!UNIT_NPC_FLAGS(flags);
    gm.map.flushObjectChanges(creature);
    gm.greenSystemMessage("Value saved, you may need to rejoin or clean your client cache.");
    gm.gmLog(format!"changed npc flags of creature %u [%s] to %u"(creature.template_.entry, creature.template_.name,
        flags));
    return true;
}

/// `.npc say` and `.npc yell`: the selected creature (or player) says it.
bool monsterChat(Character gm, string text, bool yell)
{
    if (auto creature = gm.selectedCreature(false))
    {
        const range = yell ? gm.context.config.listenRangeYell : gm.context.config.listenRangeSay;
        const type = yell ? ChatType.CHAT_MSG_MONSTER_YELL : ChatType.CHAT_MSG_MONSTER_SAY;
        gm.map.sendInRange(creature.position, range, Opcode.SMSG_MESSAGECHAT,
            monsterChatMessage(type, creature.guid, creature.template_.name, text));
        return true;
    }
    if (auto speaker = gm.selectedCharacter(false))
    {
        const message = chatMessage(yell ? ChatType.CHAT_MSG_YELL : ChatType.CHAT_MSG_SAY,
            Language.LANG_UNIVERSAL, speaker.player.guid, text);
        speaker.map.sendToWatchers(speaker, Opcode.SMSG_MESSAGECHAT, message, true);
        return true;
    }
    gm.redSystemMessage("Please select a creature or player before using this command.");
    return true;
}

/// `.npc say <text>`.
bool handleMonsterSayCommand(Character gm, Rest text = Rest.init)
{
    return gm.monsterChat(text, false);
}

/// `.npc yell <text>`.
bool handleMonsterYellCommand(Character gm, Rest text = Rest.init)
{
    return gm.monsterChat(text, true);
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
    import dmangos.world.commands : ChatColor, colored;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : DamageClass;
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
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Select a unit first.|r"]);

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
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "You need to specify an amount.|r"]);
    gm.say(format!".npc vendoradditem %s 1 5"(itemShirt));
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "You've entered invalid extended cost id.|r"]);
    gm.say(format!".npc vendoradditem %s 1"(itemShirt));
    assert(systemMessages(gm.read()).length == 1 && db.vendorRows.canFind([creatureInnkeeper, itemShirt]));
    assert(context.data.npcs.vendors[creatureInnkeeper].canFind!(v => v.item == itemShirt));
    gm.say(format!".npc vendorremoveitem %s"(itemShirt));
    assert(systemMessages(gm.read())[0].canFind("Deleted from list") && !db.vendorRows.canFind([creatureInnkeeper, itemShirt]));
    gm.say(format!".npc vendorremoveitem %s"(itemShirt));
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ format!"Item '%s' Not Found in List.|r"(itemShirt)]);

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
    // Valid input that cannot be carried out gets its own message, not the usage too.
    gm.say(".npc respawn");
    assert(systemMessages(gm.read())
        == [ChatColor.softRed ~ "You must select a creature's corpse with a valid CreatureSpawn point.|r"]);
    gm.say(".debug castspell 999999");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Invalid spell id!|r"]);

    // A player, by selection and by name; and back to life by name.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".kill");
    gm.read();
    assert(victim.deathState == DeathState.corpse);
    assert(systemMessages(anduin.read()) == [ChatColor.sky ~ "Varian killed you with a GM command.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Player anduin is already dead.|r"]);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Revived player anduin.|r"]);
    assert(victim.deathState == DeathState.alive
        && victim.values.get!UNIT_FIELD_HEALTH == victim.values.get!UNIT_FIELD_MAXHEALTH);
    gm.say(".reviveplr anduin");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Player anduin is not dead.|r"]);
    gm.say(".killplr anduin");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Killed player anduin.|r"]);
    assert(systemMessages(anduin.read()) == [ChatColor.sky ~ "You were killed by Varian with a GM command.|r"]);
    gm.say(".killplr nobody");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Player nobody is not online or does not exist.|r"]);
    gm.say(".reviveplr anduin");
    gm.read();

    // God mode: no damage taken.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".cheat god");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Damage immunity: on for Anduin.|r"]);
    assert(systemMessages(anduin.read()) == [ChatColor.green ~ "Varian turned on Damage immunity.|r"]);
    const health = victim.values.get!UNIT_FIELD_HEALTH;
    anduin.session.inWorld.unit.spellHitBy(keeper.guid, 50);
    assert(victim.values.get!UNIT_FIELD_HEALTH == health);
    gm.say(".cheat casttime on");
    gm.say(".cheat status");
    const status = systemMessages(gm.read());
    assert(status.canFind("Damage immunity  " ~ ChatColor.green ~ "On|r"));
    assert(status.canFind("Instant casts  " ~ ChatColor.green ~ "On|r"));
    assert(status.canFind("Skip area requirements  " ~ ChatColor.grey ~ "Off|r"));
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
    import dmangos.world.commands : ChatColor, colored;
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
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Select a game object first.|r"]);

    GameObjectTemplate door = {entry: 9001, type: GameObjectType.door, displayId: 1, name: "Door"};
    context.data.gameObjectTemplates[9001] = door;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90001, 9001, 0, -8949, -131, 83.53f);
    auto go = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
    context.map(0).addObject(go);
    gm.read();

    gm.say(".gobject select");
    assert(systemMessages(gm.read())[0].startsWith(ChatColor.green ~ "Selected GameObject [ Door ] which is 1."));
    gm.say(".gobject info");
    const info = systemMessages(gm.read());
    assert(info.canFind(colored(ChatColor.green, "Entry") ~ "  " ~ colored(ChatColor.sky, "9001")));
    assert(info.canFind(colored(ChatColor.green, "Type") ~ "  " ~ colored(ChatColor.sky, "door")));
    gm.say(".gobject activate");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Gameobject closed.|r"] && go.values.get!GAMEOBJECT_STATE == 0);
    gm.say(".gobject activate");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Gameobject opened.|r"] && go.values.get!GAMEOBJECT_STATE == 1);
}

/// `.npc spawn` and `.npc delete`, `.gobject spawn` (saved) and `.gobject delete`: in the world and the database.
unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : ChatColor, colored;
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
    assert(systemMessages(gm.read())[0].startsWith(ChatColor.sky ~ "Spawned a creature `"));
    assert(db.creatureSpawnRows.length == 1);
    const row = db.creatureSpawnRows.values[0];
    auto spawned = cast(Creature) map.findObject(makeGuidFor(row.entry, row.guid));
    assert(spawned !is null && spawned.template_.entry == 6774);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(spawned.guid));
    import dmangos.world.fencing : FencedDatabase;

    context.database = new FencedDatabase(db, () => false);
    gm.say(".npc delete");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Could not delete the creature.|r"]);
    assert(map.findObject(spawned.guid) is spawned && db.creatureSpawnRows.length == 1);
    context.database = db;
    gm.say(".npc delete");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Deleted creature ID " ~ format!"%s"(row.guid) ~ "|r"]);
    assert(map.findObject(spawned.guid) is null && db.creatureSpawnRows.length == 0);

    GameObjectTemplate chair = {entry: 9010, type: GameObjectType.chair, displayId: 1, name: "Chair"};
    context.data.gameObjectTemplates[9010] = chair;
    gm.say(".gobject spawn 9010 1");
    assert(systemMessages(gm.read()) == [ChatColor.green ~ "Spawning GameObject By Entry '9010'|r"]);
    assert(db.gameObjectSpawnRows.length == 1);
    gm.say(".gobject select");
    assert(systemMessages(gm.read())[0].canFind("[ Chair ]"));
    gm.say(".gobject scale 2");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Set scale to 2.000|r"]);
    gm.say(".gobject enable");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Gameobject activated.|r"]);
    gm.say(".gobject animprogress 5");
    assert(systemMessages(gm.read()) == [ChatColor.sky ~ "Set ANIMPROGRESS to 5|r"]);
    const chairRow = db.gameObjectSpawnRows.keys[0];
    db.gameObjectSpawnRows[chairRow].respawnSeconds = 100; // a column that a placement edit must leave intact
    gm.say(".gobject rotate x 90");
    assert(db.gameObjectSpawnRows.values[0].rotation[0] > 1.5f, "turned and saved");
    assert(db.gameObjectSpawnRows[chairRow].respawnSeconds == 100);
    gm.say(".gobject rotate q 90");
    assert(systemMessages(gm.read()).canFind(ChatColor.softRed ~ "Choose an axis: x, y, or o.|r"));
    gm.say(".gobject move");
    assert(db.gameObjectSpawnRows.length == 1);
    gm.read();
    context.database = new FencedDatabase(db, () => false);
    gm.say(".gobject delete");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Could not delete the game object.|r"]);
    assert(db.gameObjectSpawnRows.length == 1);
    context.database = db;
    db.deleteGameObjectSpawn(chairRow);
    gm.say(".gobject move");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Could not move the game object.|r"]);
    assert(db.gameObjectSpawnRows.length == 0, "a failed placement edit cannot recreate a deleted spawn");
    gm.say(".gobject delete");
    assert(db.gameObjectSpawnRows.length == 0);

    context.database = new FencedDatabase(db, () => false);
    gm.say(".gobject spawn 9010 1");
    assert(systemMessages(gm.read()) == [ChatColor.softRed ~ "Could not spawn the game object.|r"]);
    assert(db.gameObjectSpawnRows.length == 0);
    context.database = db;

    // Two worlds with the same initial spawn data use one database allocator.
    auto left = newCreationContext(db), right = newCreationContext(db);
    const at = Position(-8930, -120, 83.53f);
    foreach (node; [left, right])
    {
        node.data.gameObjectTemplates[chair.entry] = chair;
        assert(node.spawnEditor.spawnCreatureAt(node.map(0), 6774, at) !is null);
        assert(node.spawnEditor.spawnGameObjectAt(node.map(0), chair.entry, at, true) !is null);
    }
    assert(db.creatureSpawnRows.length == 2 && db.gameObjectSpawnRows.length == 2);
    auto transient = right.spawnEditor.spawnGameObjectAt(right.map(0), chair.entry, at, false);
    auto changed = cast(imported!"dmangos.world.gameobject".GameObjectSpawn) transient.spawn;
    changed.y += 1;
    transient = right.spawnEditor.respawnGameObjectAs(right.map(0), transient, changed);
    assert(transient.position.y == changed.y && db.gameObjectSpawnRows.length == 2);
    right.spawnEditor.deleteGameObjectSpawn(right.map(0), transient);
    assert(db.gameObjectSpawnRows.length == 2);
}

version (unittest) private ulong makeGuidFor(uint entry, uint spawn)
{
    import dmangos.world.objects : HighGuid, makeGuid;

    return makeGuid(HighGuid.unit, entry, spawn);
}

/// GM possession uses normal client control and releases the native creature without a spell aura.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.creatureai : ReactState;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata : creatureInnkeeper, innkeeperSpawn;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    auto session = gm.session.inWorld;
    const guid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto npc = context.map(0).creatureAt(guid);
    const faction = npc.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    npc.ai.react = ReactState.passive;
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(guid));
    gm.say(".npc possess");
    assert(session.activeMover == guid && npc.values.get!UNIT_FIELD_CHARMEDBY == session.player.guid);
    assert(gm.read().opcodesOf.canFind(Opcode.SMSG_CLIENT_CONTROL_UPDATE));
    gm.say(".npc unpossess");
    assert(session.activeMover == 0 && npc.values.get!UNIT_FIELD_CHARMEDBY == 0);
    assert(npc.values.get!UNIT_FIELD_FACTIONTEMPLATE == faction && !npc.ai.inCombat);
    assert(npc.ai.react == ReactState.passive);
}
