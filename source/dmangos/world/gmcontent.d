/**
 * Staff tools for creature content and transport schedules.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmcontent;

import dmangos.world.character : Character;

import std.format : format;
import std.math : isFinite, PI;
import dmangos.mysql : DatabaseException;
import dmangos.world.creature : Creature;
import dmangos.world.creaturelinking : CreatureLink, LinkFlag;
import dmangos.world.objects : HighGuid, highGuidOf, counterOf, temporaryCounterStart;
import dmangos.world.worlddata : SpellListEntry;


/// The selected creature if it is a saved spawn; null after a message otherwise.
Creature selectedSavedSpawn(Character gm)
{
    auto creature = gm.selectedCreature(true);
    if (creature !is null && (!creature.spawnId || creature.spawnId >= temporaryCounterStart
        || creature.petOwner))
    {
        gm.redSystemMessage("Select a saved creature spawn.");
        return null;
    }
    return creature;
}

/// `.npc link-info`: the selected spawn's formation, leader and followers.
bool handleNpcLinkInfoCommand(Character gm)
{
    auto creature = gm.selectedSavedSpawn();
    if (creature is null)
        return true;
    const guid = creature.spawnId;
    const link = gm.context.data.creatureLinks.linkOf(guid, creature.template_.entry, gm.map.id);
    gm.greenSystemMessage(format!"Spawn %s · %s"(guid, creature.template_.name));
    if (const slot = guid in gm.context.data.formationSlots)
        gm.systemMessage(format!"Classic-DB formation %s, slot %s."((*slot)[0], (*slot)[1]));
    if (link !is null)
    {
        gm.systemMessage(link.masterGuid ? format!"Leader spawn %s · Flags %#x"(link.masterGuid, link.flags)
            : format!"Leader entry %s · Flags %#x"(link.masterEntry, link.flags));
        if (link.hasOffset)
            gm.systemMessage(format!"Formation offset %.1f yd at %.0f°."(link.distance, link.angle * 180 / PI));
    }
    if (auto followers = guid in gm.context.data.creatureLinks.slavesOfGuid)
        gm.systemMessage(format!"Linked followers: %s"(*followers));
    else if (link is null)
        gm.systemMessage("This spawn has no active spawn links.");
    return true;
}

/// `.npc link`: the selected spawn linked to a leader spawn (0 clears the link).
bool handleNpcSpawnLinkCommand(Character gm, uint leader, uint flags = LinkFlag.aggroOnAggro)
{
    import std.traits : EnumMembers;

    enum supported = () {
        uint mask;
        static foreach (flag; EnumMembers!LinkFlag)
            mask |= flag;
        return mask;
    }();
    if (flags & ~supported)
        return false;
    auto follower = gm.selectedSavedSpawn();
    return follower is null || gm.saveNpcLink(follower, CreatureLink(leader, 0, leader ? flags : 0));
}

/// `.npc formation-leader`: the selected spawn chosen as the leader for `.npc formation-add`.
bool handleFormationLeaderCommand(Character gm)
{
    auto leader = gm.selectedSavedSpawn();
    if (leader is null)
        return true;
    gm.gmState.formationLeader = leader.spawnId;
    gm.greenSystemMessage(format!"Leader set to spawn %s. Select a follower and use .npc formation-add."
        (gm.gmState.formationLeader));
    return true;
}

/// `.npc formation-add`: the selected spawn follows the chosen leader at a distance and angle.
bool handleFormationAddCommand(Character gm, float distance = 3, float degrees = 180)
{
    if (!distance.isFinite || distance < 0 || !degrees.isFinite)
        return false;
    if (!gm.gmState.formationLeader)
    {
        gm.redSystemMessage("Select the leader and run .npc formation-leader first.");
        return true;
    }
    auto follower = gm.selectedSavedSpawn();
    return follower is null || gm.saveNpcLink(follower, CreatureLink(gm.gmState.formationLeader, 0, LinkFlag.follow, 0,
        true, distance, cast(float)(degrees % 360 * PI / 180)));
}

/// `.npc formation-remove`: the selected spawn's link cleared.
bool handleFormationClearCommand(Character gm)
{
    auto follower = gm.selectedSavedSpawn();
    return follower is null || gm.saveNpcLink(follower, CreatureLink.init);
}

/// The follower's link saved to the world database, for the workers to load on restart.
bool saveNpcLink(Character gm, Creature follower, CreatureLink link)
{
    if (follower.spawnId in gm.context.data.formationSlots)
    {
        gm.redSystemMessage(
            "This spawn belongs to a Classic-DB formation. Edit its spawn group in the world database.");
        return true;
    }
    try
    {
        if (!gm.context.canWrite() || !gm.context.database.saveGmSpawnLink(follower.spawnId, link))
        {
            gm.redSystemMessage(
                "The link could not be saved. Use different saved spawns on the same map and avoid loops.");
            return true;
        }
        gm.gmLog(format!"set leader %s and link flags %#x for spawn %s"(link.masterGuid, link.flags,
            follower.spawnId));
        gm.greenSystemMessage(link.masterGuid ? "Spawn link saved. World workers load it on restart."
            : "Spawn link cleared. World workers apply the change on restart.");
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not save the link. Check the GM content migration.");
    return true;
}

/// `.npc ai-spell`: a spell added to the shared combat spell list of the selected creature's template.
bool handleNpcAddAgentCommand(Character gm, uint spell, string target, uint repeatMs)
{
    const targetId = target == "self" ? 2 : target == "victim" ? 1 : 0;
    if (!targetId || !repeatMs || repeatMs >= int.max)
        return false;
    if (gm.context.data.spells.spell(spell) is null)
    {
        gm.redSystemMessage(format!"Unknown spell ID %s."(spell));
        return true;
    }
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    const list = creature.template_.spellList;
    if (!gm.context.data.creatureSpellLists.get(list, null).length)
    {
        gm.redSystemMessage("Select a creature with a combat spell list.");
        return true;
    }
    try
    {
        if (!gm.context.canWrite() || !gm.context.database.addGmNpcSpell(list, spell, targetId, repeatMs))
        {
            gm.redSystemMessage("This spell could not be added. Check whether the list already contains it.");
            return true;
        }
        gm.gmLog(format!"added spell %s to creature spell list %s"(spell, list));
        gm.greenSystemMessage(format!"Spell %s added to shared list %s. World workers load it on restart."
            (spell, list));
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not edit the spell list.");
    return true;
}

/// `.debug ai-test`: a test of the selected creature's combat spells, one at a time.
bool handleAiTestBeginCommand(Character gm)
{
    gm.gmState.testingCreature = 0;
    gm.gmState.testSpells = null;
    gm.gmState.nextTestSpell = 0;
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return true;
    const list = creature.template_.spellList;
    gm.gmState.testSpells = gm.context.data.creatureSpellLists.get(list, null).dup;
    if (!gm.gmState.testSpells.length)
    {
        gm.redSystemMessage("This creature has no combat spell list.");
        return true;
    }
    gm.gmState.testingCreature = creature.guid;
    gm.greenSystemMessage(format!"%s · %s queued spells"(creature.template_.name, gm.gmState.testSpells.length));
    gm.showAiTestStep();
    return true;
}

/// `.debug ai-next`: the creature casts the next test spell, by its own targeting rule.
bool handleAiTestNextCommand(Character gm)
{
    auto creature = cast(Creature) gm.map.findObject(gm.gmState.testingCreature);
    if (creature is null || !creature.alive || gm.gmState.nextTestSpell >= gm.gmState.testSpells.length)
    {
        gm.redSystemMessage("Select a living creature and start a test with .debug ai-test.");
        return true;
    }
    const row = gm.gmState.testSpells[gm.gmState.nextTestSpell];
    if (!creature.ai.testCombatSpell(gm.map, row))
    {
        gm.redSystemMessage(format!"Spell %s did not start. Check its target, range, and casting state."(row.spell));
        return true;
    }
    gm.greenSystemMessage(format!"%s started spell %s."(creature.template_.name, row.spell));
    ++gm.gmState.nextTestSpell;
    gm.showAiTestStep();
    return true;
}

/// `.debug ai-skip`: the next test spell passed over.
bool handleAiTestSkipCommand(Character gm)
{
    if (gm.gmState.nextTestSpell < gm.gmState.testSpells.length)
        ++gm.gmState.nextTestSpell;
    gm.showAiTestStep();
    return true;
}

/// The spell the test tries next, or that none remain.
void showAiTestStep(Character gm)
{
    if (gm.gmState.nextTestSpell < gm.gmState.testSpells.length)
        gm.blueSystemMessage(format!"Next: spell %s. Use .debug ai-next or .debug ai-skip."
            (gm.gmState.testSpells[gm.gmState.nextTestSpell].spell));
    else
        gm.systemMessage("No test spells remain.");
}

/// `.pet create`: a persistent pet of a creature entry for the selected hunter.
bool handleCreatePetCommand(Character gm, uint entry)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
        return true;
    if (!target.createStaffPet(entry))
    {
        gm.redSystemMessage("Choose a tameable creature entry and a living hunter with no callable pet.");
        return true;
    }
    gm.gmLog(format!"created hunter pet %s for %s"(entry, target.player.data.name));
    gm.greenSystemMessage(format!"Pet %s created for %s."(entry, target.player.data.name));
    return true;
}

/// `.pet helper`: a temporary guardian that follows the GM.
bool handleSummonHelperCommand(Character gm, uint entry, uint seconds = 60)
{
    if (entry !in gm.context.data.creatureTemplates || !gm.guardians.summonStaffHelper(entry, seconds))
    {
        gm.redSystemMessage("Use a valid creature entry and a positive duration in seconds while alive.");
        return true;
    }
    gm.gmLog(format!"summoned helper %s for %s seconds"(entry, seconds));
    gm.greenSystemMessage(format!"Helper %s summoned for %s seconds."(entry, seconds));
    return true;
}

/// `.admin audit-names`: offline characters whose names the rules refuse, listed (the first ten) or marked
/// for rename at their next login.
bool handleAuditNamesCommand(Character gm, string action = "preview")
{
    import dmangos.world.names : checkPlayerName, CharNameResult;

    if (action != "preview" && action != "apply")
        return false;
    const config = gm.context.config;
    uint candidates, marked;
    try
    {
        foreach (const ref record; gm.context.database.gmNamesToReview())
        {
            if (checkPlayerName(record.name, config.minPlayerName, config.strictPlayerNames, config.realmZone)
                == CharNameResult.CHAR_NAME_SUCCESS)
                continue;
            ++candidates;
            if (action == "preview" && candidates <= 10)
                gm.blueSystemMessage(format!"%s · Character %s"(record.name, record.guid));
            if (action == "apply" && gm.context.canWrite()
                && gm.context.database.gmMarkNameForChange(record.guid, record.name))
                ++marked;
        }
        if (action == "apply")
        {
            gm.gmLog(format!"marked %s invalid names for rename"(marked));
            gm.greenSystemMessage(format!"Marked %s of %s invalid offline names for rename."(marked, candidates));
        }
        else
            gm.systemMessage(format!"%s invalid offline names. Use .admin audit-names apply to mark them."
                (candidates));
    }
    catch (DatabaseException)
        gm.redSystemMessage(format!"Name review stopped after marking %s characters."(marked));
    return true;
}

/// `.debug database`: a saved creature or game object spawn's placement, read from the world database.
bool handleDatabaseCheckCommand(Character gm, string kind, uint id)
{
    if (kind != "npc" && kind != "object")
        return false;
    try
    {
        if (kind == "npc")
            gm.showSavedSpawn(gm.context.database.savedCreatureSpawn(id), id, "creature", "Creature");
        else
            gm.showSavedSpawn(gm.context.database.savedGameObjectSpawn(id), id, "game object", "Object");
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not read the placement.");
    return true;
}

/// `.debug database`'s line for one saved spawn, or that there is none.
void showSavedSpawn(Record)(Character gm, const Record record, uint id, string kind, string label)
{
    if (record.isNull)
        return gm.redSystemMessage(format!"No saved %s has that spawn ID."(kind));
    const spawn = record.get;
    gm.blueSystemMessage(format!"Spawn %s · %s %s · Map %s · %.3f, %.3f, %.3f"
        (id, label, spawn.entry, spawn.map, spawn.x, spawn.y, spawn.z));
}

/// `.debug packet notification`: a test notification to the GM's own client.
bool handlePacketCheckCommand(Character gm, string kind)
{
    import dmangos.world.packets : ServerNotification;

    if (kind != "notification")
        return false;
    gm.send(ServerNotification("Client notification test."));
    return true;
}

/// `.transport-period`: the circuit time of the ship aboard saved, for the workers to load on restart.
bool handleTransportPeriodCommand(Character gm, uint milliseconds)
{
    const guid = gm.player.movement.transportGuid;
    if (highGuidOf(guid) == HighGuid.moTransport)
        foreach (const ref ship; gm.context.data.ships)
            if (ship.entry == counterOf(guid))
            {
                if (!milliseconds || milliseconds < ship.minimumPeriod)
                {
                    gm.redSystemMessage(format!"%s needs a circuit of at least %s ms."
                        (ship.name, ship.minimumPeriod));
                    return true;
                }
                try
                {
                    if (!gm.context.canWrite() || !gm.context.database.setGmTransportPeriod(ship.entry, milliseconds))
                    {
                        gm.redSystemMessage("The transport schedule could not be saved.");
                        return true;
                    }
                    gm.gmLog(format!"set transport %s period to %s ms"(ship.entry, milliseconds));
                    gm.greenSystemMessage(format!"%s: %s ms saved. World workers load it on restart."
                        (ship.name, milliseconds));
                }
                catch (DatabaseException)
                    gm.redSystemMessage("The world database could not save the transport schedule.");
                return true;
            }
    gm.redSystemMessage("Board a scheduled ship or zeppelin first.");
    return true;
}

