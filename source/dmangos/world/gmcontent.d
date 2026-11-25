/// Staff tools for creature content and transport schedules.
module dmangos.world.gmcontent;

/// See the module documentation.
mixin template ContentCommands()
{
    import std.format : format;
    import std.math : isFinite, PI;
    import dmangos.mysql : DatabaseException;
    import dmangos.world.creature : Creature;
    import dmangos.world.creaturelinking : CreatureLink, LinkFlag;
    import dmangos.world.objects : HighGuid, highGuidOf, counterOf, temporaryCounterStart;
    import dmangos.world.worlddata : SpellListEntry;

private:
    uint formationLeader;         // the spawn `.npc formation-add` links followers to
    ulong testingCreature;        // the creature under `.debug ai-test`
    SpellListEntry[] testSpells;  // its combat spells
    size_t nextTestSpell;         // the next of them to try

    /// The selected creature if it is a saved spawn; null after a message otherwise.
    Creature selectedSavedSpawn()
    {
        auto creature = selectedCreature(true);
        if (creature !is null && (!creature.spawnId || creature.spawnId >= temporaryCounterStart
            || creature.petOwner))
        {
            redSystemMessage("Select a saved creature spawn.");
            return null;
        }
        return creature;
    }

    /// `.npc link-info`: the selected spawn's formation, leader and followers.
    bool handleNpcLinkInfoCommand()
    {
        auto creature = selectedSavedSpawn();
        if (creature is null)
            return true;
        const guid = creature.spawnId;
        const link = context.data.creatureLinks.linkOf(guid, creature.template_.entry, map.id);
        greenSystemMessage(format!"Spawn %s · %s"(guid, creature.template_.name));
        if (const slot = guid in context.data.formationSlots)
            systemMessage(format!"Classic-DB formation %s, slot %s."((*slot)[0], (*slot)[1]));
        if (link !is null)
        {
            systemMessage(link.masterGuid ? format!"Leader spawn %s · Flags %#x"(link.masterGuid, link.flags)
                : format!"Leader entry %s · Flags %#x"(link.masterEntry, link.flags));
            if (link.hasOffset)
                systemMessage(format!"Formation offset %.1f yd at %.0f°."(link.distance, link.angle * 180 / PI));
        }
        if (auto followers = guid in context.data.creatureLinks.slavesOfGuid)
            systemMessage(format!"Linked followers: %s"(*followers));
        else if (link is null)
            systemMessage("This spawn has no active spawn links.");
        return true;
    }

    /// `.npc link`: the selected spawn linked to a leader spawn (0 clears the link).
    bool handleNpcSpawnLinkCommand(uint leader, uint flags = LinkFlag.aggroOnAggro)
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
        auto follower = selectedSavedSpawn();
        return follower is null || saveNpcLink(follower, CreatureLink(leader, 0, leader ? flags : 0));
    }

    /// `.npc formation-leader`: the selected spawn chosen as the leader for `.npc formation-add`.
    bool handleFormationLeaderCommand()
    {
        auto leader = selectedSavedSpawn();
        if (leader is null)
            return true;
        formationLeader = leader.spawnId;
        greenSystemMessage(format!"Leader set to spawn %s. Select a follower and use .npc formation-add."
            (formationLeader));
        return true;
    }

    /// `.npc formation-add`: the selected spawn follows the chosen leader at a distance and angle.
    bool handleFormationAddCommand(float distance = 3, float degrees = 180)
    {
        if (!distance.isFinite || distance < 0 || !degrees.isFinite)
            return false;
        if (!formationLeader)
        {
            redSystemMessage("Select the leader and run .npc formation-leader first.");
            return true;
        }
        auto follower = selectedSavedSpawn();
        return follower is null || saveNpcLink(follower, CreatureLink(formationLeader, 0, LinkFlag.follow, 0,
            true, distance, cast(float)(degrees % 360 * PI / 180)));
    }

    /// `.npc formation-remove`: the selected spawn's link cleared.
    bool handleFormationClearCommand()
    {
        auto follower = selectedSavedSpawn();
        return follower is null || saveNpcLink(follower, CreatureLink.init);
    }

    /// The follower's link saved to the world database, for the workers to load on restart.
    bool saveNpcLink(Creature follower, CreatureLink link)
    {
        if (follower.spawnId in context.data.formationSlots)
        {
            redSystemMessage(
                "This spawn belongs to a Classic-DB formation. Edit its spawn group in the world database.");
            return true;
        }
        try
        {
            if (!context.canWrite() || !context.database.saveGmSpawnLink(follower.spawnId, link))
            {
                redSystemMessage(
                    "The link could not be saved. Use different saved spawns on the same map and avoid loops.");
                return true;
            }
            gmLog(format!"set leader %s and link flags %#x for spawn %s"(link.masterGuid, link.flags,
                follower.spawnId));
            greenSystemMessage(link.masterGuid ? "Spawn link saved. World workers load it on restart."
                : "Spawn link cleared. World workers apply the change on restart.");
        }
        catch (DatabaseException)
            redSystemMessage("The world database could not save the link. Check the GM content migration.");
        return true;
    }

    /// `.npc ai-spell`: a spell added to the shared combat spell list of the selected creature's template.
    bool handleNpcAddAgentCommand(uint spell, string target, uint repeatMs)
    {
        const targetId = target == "self" ? 2 : target == "victim" ? 1 : 0;
        if (!targetId || !repeatMs || repeatMs >= int.max)
            return false;
        if (context.data.spells.spell(spell) is null)
        {
            redSystemMessage(format!"Unknown spell ID %s."(spell));
            return true;
        }
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        const list = creature.template_.spellList;
        if (!context.data.creatureSpellLists.get(list, null).length)
        {
            redSystemMessage("Select a creature with a combat spell list.");
            return true;
        }
        try
        {
            if (!context.canWrite() || !context.database.addGmNpcSpell(list, spell, targetId, repeatMs))
            {
                redSystemMessage("This spell could not be added. Check whether the list already contains it.");
                return true;
            }
            gmLog(format!"added spell %s to creature spell list %s"(spell, list));
            greenSystemMessage(format!"Spell %s added to shared list %s. World workers load it on restart."
                (spell, list));
        }
        catch (DatabaseException)
            redSystemMessage("The world database could not edit the spell list.");
        return true;
    }

    /// `.debug ai-test`: a test of the selected creature's combat spells, one at a time.
    bool handleAiTestBeginCommand()
    {
        testingCreature = 0;
        testSpells = null;
        nextTestSpell = 0;
        auto creature = selectedCreature(true);
        if (creature is null)
            return true;
        const list = creature.template_.spellList;
        testSpells = context.data.creatureSpellLists.get(list, null).dup;
        if (!testSpells.length)
        {
            redSystemMessage("This creature has no combat spell list.");
            return true;
        }
        testingCreature = creature.guid;
        greenSystemMessage(format!"%s · %s queued spells"(creature.template_.name, testSpells.length));
        showAiTestStep();
        return true;
    }

    /// `.debug ai-next`: the creature casts the next test spell, by its own targeting rule.
    bool handleAiTestNextCommand()
    {
        auto creature = cast(Creature) map.findObject(testingCreature);
        if (creature is null || !creature.alive || nextTestSpell >= testSpells.length)
        {
            redSystemMessage("Select a living creature and start a test with .debug ai-test.");
            return true;
        }
        const row = testSpells[nextTestSpell];
        if (!creature.ai.testCombatSpell(map, row))
        {
            redSystemMessage(format!"Spell %s did not start. Check its target, range, and casting state."(row.spell));
            return true;
        }
        greenSystemMessage(format!"%s started spell %s."(creature.template_.name, row.spell));
        ++nextTestSpell;
        showAiTestStep();
        return true;
    }

    /// `.debug ai-skip`: the next test spell passed over.
    bool handleAiTestSkipCommand()
    {
        if (nextTestSpell < testSpells.length)
            ++nextTestSpell;
        showAiTestStep();
        return true;
    }

    /// The spell the test tries next, or that none remain.
    void showAiTestStep()
    {
        if (nextTestSpell < testSpells.length)
            blueSystemMessage(format!"Next: spell %s. Use .debug ai-next or .debug ai-skip."
                (testSpells[nextTestSpell].spell));
        else
            systemMessage("No test spells remain.");
    }

    /// `.pet create`: a persistent pet of a creature entry for the selected hunter.
    bool handleCreatePetCommand(uint entry)
    {
        auto target = selectedCharacter(true);
        if (target is null)
            return true;
        if (!target.createStaffPet(entry))
        {
            redSystemMessage("Choose a tameable creature entry and a living hunter with no callable pet.");
            return true;
        }
        gmLog(format!"created hunter pet %s for %s"(entry, target.player.data.name));
        greenSystemMessage(format!"Pet %s created for %s."(entry, target.player.data.name));
        return true;
    }

    /// `.pet helper`: a temporary guardian that follows the GM.
    bool handleSummonHelperCommand(uint entry, uint seconds = 60)
    {
        if (entry !in context.data.creatureTemplates || !summonStaffHelper(entry, seconds))
        {
            redSystemMessage("Use a valid creature entry and a positive duration in seconds while alive.");
            return true;
        }
        gmLog(format!"summoned helper %s for %s seconds"(entry, seconds));
        greenSystemMessage(format!"Helper %s summoned for %s seconds."(entry, seconds));
        return true;
    }

    /// `.admin audit-names`: offline characters whose names the rules refuse, listed (the first ten) or marked
    /// for rename at their next login.
    bool handleAuditNamesCommand(string action = "preview")
    {
        import dmangos.world.names : checkPlayerName, CharNameResult;

        if (action != "preview" && action != "apply")
            return false;
        const config = context.config;
        uint candidates, marked;
        try
        {
            foreach (const ref record; context.database.gmNamesToReview())
            {
                if (checkPlayerName(record.name, config.minPlayerName, config.strictPlayerNames, config.realmZone)
                    == CharNameResult.CHAR_NAME_SUCCESS)
                    continue;
                ++candidates;
                if (action == "preview" && candidates <= 10)
                    blueSystemMessage(format!"%s · Character %s"(record.name, record.guid));
                if (action == "apply" && context.canWrite()
                    && context.database.gmMarkNameForChange(record.guid, record.name))
                    ++marked;
            }
            if (action == "apply")
            {
                gmLog(format!"marked %s invalid names for rename"(marked));
                greenSystemMessage(format!"Marked %s of %s invalid offline names for rename."(marked, candidates));
            }
            else
                systemMessage(format!"%s invalid offline names. Use .admin audit-names apply to mark them."
                    (candidates));
        }
        catch (DatabaseException)
            redSystemMessage(format!"Name review stopped after marking %s characters."(marked));
        return true;
    }

    /// `.debug database`: a saved creature or game object spawn's placement, read from the world database.
    bool handleDatabaseCheckCommand(string kind, uint id)
    {
        if (kind != "npc" && kind != "object")
            return false;
        try
        {
            if (kind == "npc")
                showSavedSpawn(context.database.savedCreatureSpawn(id), id, "creature", "Creature");
            else
                showSavedSpawn(context.database.savedGameObjectSpawn(id), id, "game object", "Object");
        }
        catch (DatabaseException)
            redSystemMessage("The world database could not read the placement.");
        return true;
    }

    /// `.debug database`'s line for one saved spawn, or that there is none.
    void showSavedSpawn(Record)(const Record record, uint id, string kind, string label)
    {
        if (record.isNull)
            return redSystemMessage(format!"No saved %s has that spawn ID."(kind));
        const spawn = record.get;
        blueSystemMessage(format!"Spawn %s · %s %s · Map %s · %.3f, %.3f, %.3f"
            (id, label, spawn.entry, spawn.map, spawn.x, spawn.y, spawn.z));
    }

    /// `.debug packet notification`: a test notification to the GM's own client.
    bool handlePacketCheckCommand(string kind)
    {
        import dmangos.world.packets : ServerNotification;

        if (kind != "notification")
            return false;
        send(ServerNotification("Client notification test."));
        return true;
    }

    /// `.transport-period`: the circuit time of the ship aboard saved, for the workers to load on restart.
    bool handleTransportPeriodCommand(uint milliseconds)
    {
        const guid = player.movement.transportGuid;
        if (highGuidOf(guid) == HighGuid.moTransport)
            foreach (const ref ship; context.data.ships)
                if (ship.entry == counterOf(guid))
                {
                    if (!milliseconds || milliseconds < ship.minimumPeriod)
                    {
                        redSystemMessage(format!"%s needs a circuit of at least %s ms."
                            (ship.name, ship.minimumPeriod));
                        return true;
                    }
                    try
                    {
                        if (!context.canWrite() || !context.database.setGmTransportPeriod(ship.entry, milliseconds))
                        {
                            redSystemMessage("The transport schedule could not be saved.");
                            return true;
                        }
                        gmLog(format!"set transport %s period to %s ms"(ship.entry, milliseconds));
                        greenSystemMessage(format!"%s: %s ms saved. World workers load it on restart."
                            (ship.name, milliseconds));
                    }
                    catch (DatabaseException)
                        redSystemMessage("The world database could not save the transport schedule.");
                    return true;
                }
        redSystemMessage("Board a scheduled ship or zeppelin first.");
        return true;
    }
}
