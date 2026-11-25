/// The in-game command catalog. Each action declares its syntax, description and access policy.
module dmangos.world.commandtable;

import dmangos.world.updatefields;

struct CommandPermission
{
    string capability;
    string alsoRequires;
    bool delegable = true;
}

private CommandPermission permit(string capability) pure @safe
{
    return CommandPermission(capability);
}

private enum roleAdministration = CommandPermission("roles.manage", "staff.admin", false);

struct ChatCommand
{
    string name;
    string alternate;
    CommandPermission permission;
    string handler;
    string arguments;
    string description;
    immutable(ChatCommand)[] children;
    string target;
    string unavailableReason;
    int field = -1;
    int maximum = -1;
    bool decimal;

    string label() const pure @safe
    {
        return alternate.length ? alternate : name;
    }
}

private ChatCommand action(string name, CommandPermission permission, string handler,
    string arguments, string description, string alternate = null) pure @safe
{
    return ChatCommand(name, alternate, permission, handler, arguments, description);
}

private ChatCommand section(string name, immutable(ChatCommand)[] children,
    string alternate = null) pure @safe
{
    return ChatCommand(name, alternate, CommandPermission.init, null, null, null, children);
}

private ChatCommand shortcut(string name, string target) pure @safe
{
    ChatCommand row;
    row.name = name;
    row.target = target;
    return row;
}

private ChatCommand unavailable(string name, CommandPermission permission, string reason) pure @safe
{
    ChatCommand row = action(name, permission, null, null, null);
    row.unavailableReason = reason;
    return row;
}

private ChatCommand stat(string name, int field, string description, int maximum = -1,
    bool decimal = false, string alternate = null) pure @safe
{
    const arguments = maximum < 0 ? "<value>" : name == "damage" ? "<min> <max>" : "<value> [max]";
    ChatCommand row = action(name, permit("character.modify"), null, arguments, description, alternate);
    row.field = field;
    row.maximum = maximum;
    row.decimal = decimal;
    return row;
}

immutable ChatCommand[] modifyCommandTable = [
    stat("hp", UNIT_FIELD_HEALTH, "Set health and maximum health.", UNIT_FIELD_MAXHEALTH),
    action("gender", permit("character.modify"), "handleGenderChanger", "[0|1]", "Set the selected player's gender."),
    stat("mana", UNIT_FIELD_POWER1, "Set mana and maximum mana.", UNIT_FIELD_MAXPOWER1),
    stat("rage", UNIT_FIELD_POWER2, "Set rage and maximum rage.", UNIT_FIELD_MAXPOWER2),
    stat("energy", UNIT_FIELD_POWER4, "Set energy and maximum energy.", UNIT_FIELD_MAXPOWER4),
    action("level", permit("character.modify"), "handleModifyLevelCommand", "<level>", "Set the selected unit's level."),
    stat("strength", UNIT_FIELD_STAT0, "Set strength."),
    stat("agility", UNIT_FIELD_STAT1, "Set agility."),
    stat("intelligence", UNIT_FIELD_STAT3, "Set intellect."),
    stat("spirit", UNIT_FIELD_STAT4, "Set spirit."),
    stat("armor", UNIT_FIELD_RESISTANCES, "Set armor."),
    stat("holy", UNIT_FIELD_RESISTANCES + 1, "Set Holy resistance."),
    stat("fire", UNIT_FIELD_RESISTANCES + 2, "Set Fire resistance."),
    stat("nature", UNIT_FIELD_RESISTANCES + 3, "Set Nature resistance."),
    stat("frost", UNIT_FIELD_RESISTANCES + 4, "Set Frost resistance."),
    stat("shadow", UNIT_FIELD_RESISTANCES + 5, "Set Shadow resistance."),
    stat("arcane", UNIT_FIELD_RESISTANCES + 6, "Set Arcane resistance."),
    stat("damage", UNIT_FIELD_MINDAMAGE, "Set minimum and maximum melee damage.", UNIT_FIELD_MAXDAMAGE, true),
    stat("ap", UNIT_FIELD_ATTACK_POWER, "Set melee attack power."),
    stat("rangeap", UNIT_FIELD_RANGED_ATTACK_POWER, "Set ranged attack power."),
    stat("scale", OBJECT_FIELD_SCALE_X, "Set object scale.", -1, true),
    action("gold", permit("character.modify"), "handleModifyGoldCommand", "<copper>", "Adjust money by an amount in copper."),
    action("speed", permit("character.modify"), "handleModifySpeedCommand", "<speed>", "Set movement speed."),
    stat("nativedisplayid", UNIT_FIELD_NATIVEDISPLAYID, "Set the native display ID."),
    stat("displayid", UNIT_FIELD_DISPLAYID, "Set the current display ID."),
    stat("flags", UNIT_FIELD_FLAGS, "Set unit flags."),
    stat("faction", UNIT_FIELD_FACTIONTEMPLATE, "Set the faction template ID."),
    stat("dynamicflags", UNIT_DYNAMIC_FLAGS, "Set dynamic flags."),
    stat("talentpoints", PLAYER_CHARACTER_POINTS1, "Set unspent talent points."),
    stat("happiness", UNIT_FIELD_POWER5, "Set pet happiness and its maximum.", UNIT_FIELD_MAXPOWER5),
    stat("boundingraidius", UNIT_FIELD_BOUNDINGRADIUS, "Set the unit's bounding radius.", -1, true, "radius"),
    stat("combatreach", UNIT_FIELD_COMBATREACH, "Set the unit's combat reach.", -1, true, "reach"),
    stat("npcemotestate", UNIT_NPC_EMOTESTATE, "Set the NPC's emote state."),
    stat("bytes", UNIT_FIELD_BYTES_0, "Set the first packed unit field."),
];

immutable ChatCommand[] debugCommandTable = [
    action("infront", permit("debug.use"), "handleDebugInFrontCommand", "", "Check whether the target is in front of you."),
    action("showreact", permit("debug.use"), "handleShowReactionCommand", "<reaction-id>", "Preview a reaction on the selected unit."),
    action("aimove", permit("debug.use"), "handleAIMoveCommand", "<x> <y> <z>", "Move the selected creature to coordinates on this map."),
    action("dist", permit("debug.use"), "handleDistanceCommand", "", "Show the distance to the selected unit.", "distance"),
    action("face", permit("debug.use"), "handleFaceCommand", "<degrees>", "Turn the selected creature to an angle in degrees."),
    action("moveinfo", permit("debug.use"), "handleMoveInfoCommand", "", "Inspect the selected creature's movement."),
    action("setbytes", permit("debug.use"), "handleSetBytesCommand", "<index> <b0> <b1> <b2> <b3>", "Set four bytes in a unit field."),
    action("getbytes", permit("debug.use"), "handleGetBytesCommand", "<field>", "Read the four bytes of a unit field."),
    action("unroot", permit("debug.use"), "handleDebugUnroot", "", "Send an unroot movement order."),
    action("root", permit("debug.use"), "handleDebugRoot", "", "Send a root movement order."),
    action("landwalk", permit("debug.use"), "handleDebugLandWalk", "", "Send a land-walking movement order."),
    action("waterwalk", permit("debug.use"), "handleDebugWaterWalk", "", "Send a water-walking movement order."),
    action("castspell", permit("debug.use"), "handleCastSpellCommand", "<spell-id>", "Cast a spell on the selected unit.", "cast"),
    action("castself", permit("debug.use"), "handleCastSelfCommand", "<spell-id>", "Make the selected unit cast a spell on itself."),
    action("castspellne", permit("debug.use"), "handleCastSpellNECommand", "<spell-id>", "Preview a spell's animation."),
    action("aggrorange", permit("debug.use"), "handleAggroRangeCommand", "", "Show the selected creature's aggro range.", "aggro"),
    action("knockback", permit("debug.use"), "handleKnockBackCommand", "[speed]", "Apply a knockback for testing."),
    action("fade", permit("debug.use"), "handleFadeCommand", "<percent>", "Reduce your threat by a percentage."),
    action("threatMod", permit("debug.use"), "handleThreatModCommand", "<percent>", "Change your threat by a signed percentage."),
    action("calcThreat", permit("debug.use"), "handleCalcThreatCommand", "<damage> <spell-id>", "Estimate spell threat from damage and your modifiers."),
    action("threatList", permit("debug.use"), "handleThreatListCommand", "", "List the selected creature's threat entries."),
    action("gettptime", permit("debug.use"), "handleGetTransporterTime", "", "Show the circuit time of the ship or zeppelin aboard."),
    action("itempushresult", permit("debug.use"), "handleSendItemPushResult", "<item-id> [count] [type] [flag-1] [flag-2] [flag-3]", "Send a test item acquisition notification."),
    action("setbit", permit("debug.use"), "handleModifyBitCommand", "<field> <bit>", "Toggle a bit in an update field."),
    action("setvalue", permit("debug.use"), "handleModifyValueCommand", "<field> <value>", "Set a unit update field."),
    action("aispelltestbegin", permit("debug.use"), "handleAiTestBeginCommand", "", "Start a test of the selected creature’s combat spells.", "ai-test"),
    action("aispelltestcontinue", permit("debug.use"), "handleAiTestNextCommand", "", "Attempt the next test spell using the creature’s targeting rule.", "ai-next"),
    action("aispelltestskip", permit("debug.use"), "handleAiTestSkipCommand", "", "Skip the current test spell.", "ai-skip"),
    action("dumpcoords", permit("debug.use"), "handleDebugDumpCoordsCommmand", "", "Show map, instance, coordinates and facing.", "position"),
    action("sendpacket", permit("debug.use"), "handlePacketCheckCommand", "notification", "Send a test notification to your own client.", "packet"),
    action("sqlquery", permit("debug.use"), "handleDatabaseCheckCommand", "<npc|object> <spawn-id>", "Read a saved spawn’s placement from the world database.", "database"),
    action("rangecheck", permit("debug.use"), "handleRangeCheckCommand", "", "Show distance and combat reach against the selected unit."),
    unavailable("setallratings", permit("debug.use"), "Combat ratings are unavailable in this client."),
    action("testlos", permit("debug.use"), "handleCollisionTestLOS", "", "Check line of sight to the selected unit.", "los"),
    action("testindoor", permit("debug.use"), "handleCollisionTestIndoor", "", "Check whether your position is indoors."),
    action("getheight", permit("debug.use"), "handleCollisionGetHeight", "", "Show terrain and collision heights at your position."),
    action("getpos", permit("debug.use"), "handleGetPosCommand", "<area-id>", "Show coordinates for a world area."),
    action("getUint32Value", permit("debug.use"), "handleGetUint32ValueCommand", "<field>", "Read a unit update field as an unsigned integer."),
];

immutable ChatCommand[] waypointCommandTable = [
    action("add", permit("world.waypoints"), "handleWPAddCommand", "[wait-ms]", "Add your position to the route draft."),
    action("show", permit("world.waypoints"), "handleWPShowCommand", "", "List points in the route draft.", "list"),
    action("hide", permit("world.waypoints"), "handleWPHideCommand", "", "Discard unsaved route edits.", "discard"),
    action("delete", permit("world.waypoints"), "handleWPDeleteCommand", "<point>", "Remove a point from the draft."),
    action("movehere", permit("world.waypoints"), "handleWPMoveHereCommand", "<point>", "Move a draft point to your position.", "move"),
    action("flags", permit("world.waypoints"), "handleWPGaitCommand", "<point> <default|walk|run>", "Set the movement into a draft point.", "gait"),
    action("waittime", permit("world.waypoints"), "handleWPWaitCommand", "<point> <wait-ms>", "Set a point's wait time in milliseconds.", "wait"),
    action("emote", permit("world.waypoints"), "handleWPEmoteCommand", "<point> <emote-id|0>", "Set or clear an emote played at a draft point."),
    action("skin", permit("world.waypoints"), "handleWPModelCommand", "<point> <display-id|0>", "Set or clear a model applied at a draft point.", "model"),
    action("change", permit("world.waypoints"), "handleWPChangeNoCommand", "<point> <replacement>", "Renumber a draft point.", "renumber"),
    action("info", permit("world.waypoints"), "handleWPInfoCommand", "<point>", "Show one draft point."),
    action("movetype", permit("world.waypoints"), "handleWPMoveTypeCommand", "<loop|linear>", "Set the route to loop or run in a line.", "mode"),
    action("generate", permit("world.waypoints"), "handleGenerateWaypoints", "", "Extend the draft to your position using the navigation mesh."),
    action("script", permit("world.waypoints"), "handleWPScriptCommand", "<point> <script-id|0>", "Attach a movement script to a point or clear it with 0."),
    action("save", permit("world.waypoints"), "handleSaveWaypoints", "", "Save the route for the selected spawn."),
    action("deleteall", permit("world.waypoints"), "handleDeleteWaypoints", "", "Remove all points from the draft.", "clear"),
    action("addfly", permit("world.waypoints"), "handleWPAddFlyCommand", "[wait-ms]", "Add an airborne point for a creature that can fly.", "add-air"),
];

immutable ChatCommand[] gMTicketCommandTable = [
    action("list", permit("support.tickets"), "handleGMTicketListCommand", "[all]", "List open player tickets."),
    action("get", permit("support.tickets"), "handleGMTicketGetByIdCommand", "<id>", "Read a ticket by ID.", "show"),
    action("remove", permit("support.tickets"), "handleGMTicketRemoveByIdCommand", "<id>", "Close a ticket.", "close"),
    action("deletepermanent", permit("staff.admin"), "handleGMTicketDeletePermanentCommand", "<id>", "Permanently delete a ticket.", "delete"),
    action("assign", permit("support.tickets"), "handleGMTicketAssignToCommand", "<id> [character]", "Assign a ticket to a staff member or yourself."),
    action("release", permit("support.tickets"), "handleGMTicketReleaseCommand", "<id>", "Clear a ticket's assignment."),
    action("comment", permit("support.tickets"), "handleGMTicketCommentCommand", "<id> <note>", "Add a note to a ticket."),
    action("toggle", permit("staff.admin"), "handleGMTicketToggleTicketSystemStatusCommand", "", "Enable or disable player tickets."),
];

immutable ChatCommand[] guildCommandTable = [
    action("create", permit("guild.manage"), "createGuildCommand", "<name>", "Create a guild for the selected player."),
    action("rename", permit("guild.manage"), "handleRenameGuildCommand", "<name>", "Rename the selected player's guild."),
    action("members", permit("guild.manage"), "handleGuildMembersCommand", "", "List members and ranks in the selected player's guild."),
    action("removeplayer", permit("guild.manage"), "handleGuildRemovePlayerCommand", "", "Remove the selected player from their guild."),
    action("disband", permit("guild.manage"), "handleGuildDisbandCommand", "", "Disband the selected player's guild."),
];

immutable ChatCommand[] gameObjectCommandTable = [
    action("select", permit("world.objects"), "handleGOSelect", "[name]", "Select the nearest game object."),
    action("delete", permit("world.objects"), "handleGODelete", "", "Delete the selected game object."),
    action("spawn", permit("world.objects"), "handleGOSpawn", "<entry-id> [save: 0|1]", "Spawn a game object by entry ID."),
    action("info", permit("world.objects"), "handleGOInfo", "", "Inspect the selected game object."),
    action("activate", permit("world.objects"), "handleGOActivate", "", "Activate the selected game object."),
    action("enable", permit("world.objects"), "handleGOEnable", "", "Toggle whether the selected game object is usable."),
    action("scale", permit("world.objects"), "handleGOScale", "<scale>", "Set the selected game object's scale."),
    action("animprogress", permit("world.objects"), "handleGOAnimProgress", "[progress]", "Set the selected game object's animation progress.", "animation"),
    action("export", permit("world.objects"), "handleGOExport", "", "Show the selected game object's placement and rotation."),
    action("move", permit("world.objects.move"), "handleGOMove", "", "Move the selected game object to your position."),
    action("rotate", permit("world.objects.move"), "handleGORotate", "<x|y|o> <degrees>", "Set rotation around an axis in degrees."),
];

immutable ChatCommand[] battlegroundCommandTable = [
    action("setbgscore", permit("battleground.manage"), "handleSetBGScoreCommand", "<alliance|horde> <score>", "Set a below-win score in Warsong Gulch or Arathi Basin.", "score"),
    action("startbg", permit("battleground.manage"), "handleStartBGCommand", "", "Start the current battleground.", "start"),
    action("pausebg", permit("battleground.manage"), "handlePauseBGCommand", "[on|off]", "Pause or resume the countdown, combat, and objectives.", "pause"),
    action("bginfo", permit("battleground.manage"), "handleBGInfoCommnad", "", "Show the current match and its status.", "status"),
    action("battleground", permit("battleground.manage"), "handleBattlegroundCommand", "", "Show the current match and available tools."),
    action("setworldstate", permit("battleground.manage"), "handleSetWorldStateCommand", "<id> <value>", "Set a world state in the current battleground.", "worldstate"),
    action("setworldstates", permit("battleground.manage"), "handleSetWorldStatesCommand", "<id> <value>", "Set a world state in the current battleground."),
    action("playsound", permit("battleground.manage"), "handlePlaySoundCommand", "<sound-id>", "Play a sound in the current battleground.", "sound"),
    action("setbfstatus", permit("battleground.manage"), "handleSetBattlefieldStatusCommand", "start", "Start the current battleground with the start action."),
    action("leave", permit("battleground.manage"), "handleBattlegroundExitCommand", "", "Leave the current battleground."),
    action("getqueue", permit("staff.admin"), "handleGetBattlegroundQueueCommand", "", "Show battlegroup queue and match counts.", "queue"),
    action("forcestart", permit("staff.admin"), "handleInitializeAllQueuedBattlegroundsCommand", "", "Start all queued battlegrounds."),
];

immutable ChatCommand[] nPCCommandTable = [
    action("vendoradditem", permit("world.creatures"), "handleItemCommand", "<item-id> [quantity] [extended-cost-id]", "Add an item to the selected vendor.", "sell"),
    action("vendorremoveitem", permit("world.creatures"), "handleItemRemoveCommand", "<item-id>", "Remove an item from the selected vendor.", "unsell"),
    action("flags", permit("world.creatures"), "handleNPCFlagCommand", "<flags>", "Set the selected NPC's flags."),
    action("emote", permit("world.creatures"), "handleEmoteCommand", "[emote]", "Set the selected NPC's emote state."),
    action("delete", permit("world.creatures"), "handleDeleteCommand", "", "Delete the selected creature and its saved spawn."),
    action("info", permit("world.creatures"), "handleNpcInfoCommand", "", "Inspect the selected NPC."),
    action("addAgent", permit("world.creatures"), "handleNpcAddAgentCommand", "<spell-id> <self|victim> <repeat-ms>", "Add a spell to the selected NPC’s shared combat list.", "ai-add"),
    shortcut("traineradd", "addtrainerspell"),
    action("listAgent", permit("world.creatures"), "handleListAIAgentCommand", "", "Show the selected creature's scripts and combat spells.", "ai"),
    action("say", permit("world.creatures"), "handleMonsterSayCommand", "<message>", "Make the selected NPC say a message."),
    action("yell", permit("world.creatures"), "handleMonsterYellCommand", "<message>", "Make the selected NPC yell a message."),
    action("come", permit("world.creatures"), "handleNpcComeCommand", "", "Move the selected NPC to your position."),
    action("return", permit("world.creatures"), "handleNpcReturnCommand", "", "Send the selected NPC back to its spawn point."),
    action("spawn", permit("world.creatures"), "handleCreatureSpawnCommand", "<entry-id>", "Create a saved creature spawn."),
    action("respawn", permit("world.creatures"), "handleCreatureRespawnCommand", "", "Respawn the selected creature."),
    action("link-info", permit("world.creatures"), "handleNpcLinkInfoCommand", "", "Inspect the selected creature’s active spawn links."),
    action("spawnlink", permit("world.creatures"), "handleNpcSpawnLinkCommand", "<leader-spawn|0> [flags]", "Save a link to a leader spawn, or clear it with 0.", "link"),
    action("possess", permit("world.creatures"), "handleNpcPossessCommand", "", "Take control of the selected NPC."),
    action("unpossess", permit("world.creatures"), "handleNpcUnPossessCommand", "", "Release control of a possessed NPC."),
    action("select", permit("world.creatures"), "handleNpcSelectCommand", "", "Select the closest NPC."),
    action("npcfollow", permit("character.modify"), "handleNpcFollowCommand", "", "Make the selected NPC follow you.", "follow"),
    action("nullfollow", permit("character.modify"), "handleNullFollowCommand", "", "Stop the selected NPC from following.", "unfollow"),
    action("formationlink1", permit("world.creatures"), "handleFormationLeaderCommand", "", "Select the leader for a formation edit.", "formation-leader"),
    action("formationlink2", permit("world.creatures"), "handleFormationAddCommand", "[yards] [degrees]", "Save the selected creature as a follower of the chosen leader.", "formation-add"),
    action("formationclear", permit("world.creatures"), "handleFormationClearCommand", "", "Clear the selected spawn’s saved formation link.", "formation-remove"),
];

immutable ChatCommand[] cheatCommandTable = [
    action("status", permit("testing.cheats"), "handleShowCheatsCommand", "", "Show active testing toggles."),
    action("taxi", permit("testing.cheats"), "handleTaxiCheatCommand", "<on|off>", "Toggle access to all flight paths."),
    action("cooldown", permit("testing.cheats"), "handleCooldownCheatCommand", "[on|off]", "Toggle spell cooldowns."),
    action("casttime", permit("testing.cheats"), "handleCastTimeCheatCommand", "[on|off]", "Toggle instant casts."),
    action("power", permit("testing.cheats"), "handlePowerCheatCommand", "[on|off]", "Toggle free spell casts."),
    action("god", permit("testing.cheats"), "handleGodModeCommand", "[on|off]", "Toggle damage immunity."),
    unavailable("fly", permit("testing.cheats"), "Player flight is unavailable in this client."),
    action("explore", permit("testing.cheats"), "handleExploreCheatCommand", "<on|off>", "Reveal or clear map exploration."),
    unavailable("flyspeed", permit("testing.cheats"), "Player flight is unavailable in this client."),
    action("stack", permit("testing.cheats"), "handleAuraStackCommand", "<spell-id> <stacks>", "Set the stack count of an active aura on a player."),
    action("triggerpass", permit("testing.cheats"), "handleTriggerpassCheatCommand", "[on|off]", "Toggle bypass of area trigger requirements.", "skip-requirements"),
];

immutable ChatCommand[] accountCommandTable = [
    action("mute", permit("account.moderate"), "handleAccountMuteCommand", "<account> <duration>", "Mute an account for a duration."),
    action("unmute", permit("account.moderate"), "handleAccountUnmuteCommand", "<account>", "Remove an account mute."),
];

immutable ChatCommand[] honorCommandTable = [
    action("addpoints", permit("character.modify"), "handleAddHonorCommand", "<points>", "Add honor to the selected player."),
    action("addkills", permit("character.modify"), "handleAddKillCommand", "<kills>", "Add honorable kills to the selected player."),
    action("globaldailyupdate", permit("character.modify"), "handleGlobalHonorDailyMaintenanceCommand", "", "Run the daily honor update for the realm."),
    action("singledailyupdate", permit("character.modify"), "handleNextDayCommand", "", "Run the daily honor update for the selected player."),
    action("pvpcredit", permit("character.modify"), "handlePVPCreditCommand", "<points> [rank]", "Send a test PvP credit notification."),
];

immutable ChatCommand[] petCommandTable = [
    action("createpet", permit("character.modify"), "handleCreatePetCommand", "<creature-entry>", "Create a persistent pet for the selected hunter.", "create"),
    action("renamepet", permit("character.modify"), "handleRenamePetCommand", "<name>", "Rename your pet.", "rename"),
    action("addspell", permit("character.modify"), "handleAddPetSpellCommand", "<spell-id>", "Teach a spell to the selected player's pet.", "teach"),
    action("removespell", permit("character.modify"), "handleRemovePetSpellCommand", "<spell-id>", "Remove a spell from the selected player's pet.", "forget"),
    action("spawnbot", permit("account.moderate"), "handleSummonHelperCommand", "<creature-entry> [seconds]", "Summon a temporary guardian that follows you.", "helper"),
];

immutable ChatCommand[] recallCommandTable = [
    action("list", permit("world.quests"), "handleRecallListCommand", "", "List saved locations."),
    action("port", permit("world.quests"), "handleRecallGoCommand", "<name>", "Teleport to a saved location.", "go"),
    action("add", permit("world.quests"), "handleRecallAddCommand", "<name>", "Save your current location."),
    action("del", permit("world.quests"), "handleRecallDelCommand", "<name>", "Delete a saved location.", "delete"),
    action("portplayer", permit("character.modify"), "handleRecallPortPlayerCommand", "<name> <location>", "Send a player to a saved location."),
];

immutable ChatCommand[] questCommandTable = [
    action("addboth", permit("world.quests"), "handleQuestAddBothCommand", "<quest-id>", "Make the selected NPC start and finish a quest.", "add-both"),
    action("addfinish", permit("world.quests"), "handleQuestAddFinishCommand", "<quest-id>", "Make the selected NPC finish a quest.", "add-finish"),
    action("addstart", permit("world.quests"), "handleQuestAddStartCommand", "<quest-id>", "Make the selected NPC start a quest.", "add-start"),
    action("delboth", permit("world.quests"), "handleQuestDelBothCommand", "<quest-id>", "Remove both quest relationships from the selected NPC.", "remove-both"),
    action("delfinish", permit("world.quests"), "handleQuestDelFinishCommand", "<quest-id>", "Remove a quest's finish relationship from the selected NPC.", "remove-finish"),
    action("delstart", permit("world.quests"), "handleQuestDelStartCommand", "<quest-id>", "Remove a quest's start relationship from the selected NPC.", "remove-start"),
    action("complete", permit("world.quests"), "handleQuestFinishCommand", "<quest-id>", "Complete a quest for the selected player."),
    action("finisher", permit("world.quests"), "handleQuestFinisherCommand", "<quest-id>", "Find NPCs or objects that finish a quest."),
    action("item", permit("world.quests"), "handleQuestItemCommand", "<quest-id>", "List the items a quest requires."),
    action("list", permit("world.quests"), "handleQuestListCommand", "[entry-id]", "List quests for a player or quest giver."),
    action("load", permit("world.quests"), "handleQuestLoadCommand", "", "Reload quest definitions and giver relationships.", "reload"),
    action("lookup", permit("world.quests"), "handleQuestLookupCommand", "<search>", "Search quests by title."),
    action("giver", permit("world.quests"), "handleQuestGiverCommand", "<quest-id>", "Find NPCs or objects that start a quest."),
    action("remove", permit("world.quests"), "handleQuestRemoveCommand", "<quest-id>", "Remove a quest from the selected player's log."),
    action("reward", permit("world.quests"), "handleQuestRewardCommand", "<quest-id>", "Show a quest's rewards."),
    action("status", permit("world.quests"), "handleQuestStatusCommand", "<quest-id>", "Show the selected player's status for a quest."),
    action("spawn", permit("world.quests"), "handleQuestSpawnCommand", "<quest-id>", "Teleport to a spawn associated with a quest."),
    action("start", permit("world.quests"), "handleQuestStartCommand", "<quest-id>", "Start a quest for the selected player."),
];

immutable ChatCommand[] serverCommandTable = [
    action("setmotd", permit("character.modify"), "handleSetMotdCommand", "[message]", "Set the message of the day.", "motd"),
    action("rehash", permit("staff.admin"), "handleRehashCommand", "", "Reload server configuration.", "reload-config"),
    action("reloadtable", permit("character.modify"), "handleDBReloadCommand", "<table>", "Reload supported world data.", "reload-data"),
    action("shutdown", permit("staff.admin"), "handleShutdownCommand", "[seconds]", "Schedule a server shutdown in seconds."),
    action("restart", permit("staff.admin"), "handleShutdownRestartCommand", "[seconds]", "Schedule a server restart in seconds."),
    action("cancelshutdown", permit("staff.admin"), "handleCancelShutdownCommand", "", "Cancel a scheduled shutdown or restart.", "cancel"),
    action("save", permit("server.save"), "handleSaveCommand", "", "Save the selected player."),
    action("saveall", permit("server.save"), "handleSaveAllCommand", "", "Save online characters.", "save-all"),
    action("info", permit(""), "handleInfoCommand", "", "Show uptime and player counts.", "status"),
    action("netstatus", permit(""), "handleNetworkStatusCommand", "", "Show connection counts.", "network"),
];

immutable ChatCommand[] gmCommandTable = [
    action("list", permit(""), "handleGMListCommand", "", "List online staff."),
    action("off", permit("staff.tag"), "handleGMOffCommand", "", "Turn off the GM tag and whisper blocking."),
    action("on", permit("staff.tag"), "handleGMOnCommand", "", "Turn on the GM tag and whisper blocking."),
    action("whisperblock", permit("world.objects.move"), "handleWhisperBlockCommand", "", "Block whispers while keeping the visible GM tag off.", "quiet"),
    action("allowwhispers", permit("staff.support"), "handleAllowWhispersCommand", "<name>", "Allow whispers from a player while in GM mode.", "allow"),
    action("blockwhispers", permit("staff.support"), "handleBlockWhispersCommand", "<name>", "Remove a player's whisper exception.", "block"),
];

immutable ChatCommand[] characterCommandTable = [
    action("learn", permit("character.learn"), "handleLearnCommand", "<spell-id|all>", "Teach a spell or the character's class spells."),
    action("unlearn", permit("character.learn"), "handleUnlearnCommand", "<spell-id>", "Remove a spell from the selected player."),
    action("getskillinfo", permit("character.modify"), "handleGetSkillsInfoCommand", "", "Show the selected player's skills."),
    action("learnskill", permit("character.learn"), "handleLearnSkillCommand", "<skill-id> <value> [max]", "Teach a skill and set its value and cap."),
    action("advanceskill", permit("character.learn"), "handleModifySkillCommand", "<skill-id> [points]", "Raise a skill by the given number of points."),
    action("removeskill", permit("character.learn"), "handleRemoveSkillCommand", "<skill>", "Remove a skill."),
    action("increaseweaponskill", permit("character.learn"), "handleIncreaseWeaponSkill", "[points]", "Raise the equipped weapon skill."),
    action("resetreputation", permit("world.creatures"), "handleResetReputationCommand", "", "Reset reputation to starting values."),
    action("resetspells", permit("character.learn"), "handleResetSpellsCommand", "", "Restore the character's starting spells."),
    action("resettalents", permit("character.learn"), "handleResetTalentsCommand", "", "Reset the character's talents."),
    action("resetskills", permit("character.learn"), "handleResetSkillsCommand", "", "Restore the character's starting skills."),
    action("additem", permit("character.modify"), "handleAddInvItemCommand", "<item-id> [count] [random-property]", "Give items to the selected player.", "give"),
    action("removeitem", permit("character.modify"), "handleRemoveItemCommand", "<item-id> [count]", "Remove items from the selected player.", "take"),
    action("additemset", permit("character.modify"), "handleAddItemSetCommand", "<set-id>", "Give an item set to the selected player."),
    action("advanceallskills", permit("character.learn"), "handleAdvanceAllSkillsCommand", "<points>", "Raise all skills by the given number of points."),
    action("getstanding", permit("character.modify"), "handleGetStandingCommand", "<faction-id>", "Show standing with a faction."),
    action("setstanding", permit("character.modify"), "handleSetStandingCommand", "<faction-id> <standing>", "Set standing with a faction."),
    action("showitems", permit("character.modify"), "handleShowItems", "", "List the selected player's items.", "items"),
    action("showskills", permit("character.modify"), "handleShowSkills", "", "List the selected player's skills.", "skills"),
    action("showinstances", permit("staff.admin"), "handleShowInstancesCommand", "", "List the selected player's saved instances."),
    action("rename", permit("character.modify"), "handleRenameCommand", "<old-name> <new-name>", "Rename a character."),
    action("forcerename", permit("character.modify"), "handleForceRenameCommand", "<name>", "Require a character to take a new name at login."),
    action("repairitems", permit("world.creatures"), "handleRepairItemsCommand", "", "Repair the selected player's equipment.", "repair"),
    unavailable("settitle", permit("character.modify"), "Custom character titles are unavailable in this client."),
];

immutable ChatCommand[] lookupCommandTable = [
    action("item", permit("support.lookup"), "handleLookupItemCommand", "<search>", "Search items by name."),
    action("quest", permit("support.lookup"), "handleQuestLookupCommand", "<search>", "Search quests by title."),
    action("creature", permit("support.lookup"), "handleLookupCreatureCommand", "<search>", "Search creature templates by name."),
    action("object", permit("support.lookup"), "handleLookupObjectCommand", "<search>", "Search game object templates by name."),
    action("spell", permit("support.lookup"), "handleLookupSpellCommand", "<search>", "Search spells by name."),
    action("skill", permit("support.lookup"), "handleLookupSkillCommand", "<search>", "Search skills by name."),
    action("faction", permit("support.lookup"), "handleLookupFactionCommand", "<search>", "Search factions by name."),
];

immutable ChatCommand[] adminCommandTable = [
    action("castall", permit("staff.admin"), "handleCastAllCommand", "<spell-id>", "Make online players on this worker cast a spell."),
    action("dispelall", permit("staff.admin"), "handleDispelAllCommand", "[all: 0|1]", "Remove harmful or helpful auras from players on this worker."),
    action("renameallinvalidchars", permit("staff.admin"), "handleAuditNamesCommand", "[preview|apply]", "Review invalid offline names and mark them for rename.", "audit-names"),
    action("masssummon", permit("staff.admin"), "handleMassSummonCommand", "", "Summon online players to your position."),
    action("playall", permit("staff.admin"), "handleGlobalPlaySoundCommand", "<sound-id>", "Play a sound for all players."),
];

immutable ChatCommand[] kickCommandTable = [
    action("byplayer", permit("staff.disconnect"), "handleKillByPlayerCommand", "<character>", "Disconnect a player by character name.", "player"),
    action("byaccount", permit("staff.disconnect"), "handleKillBySessionCommand", "<account>", "Disconnect a session by account name.", "account"),
    action("byip", permit("staff.disconnect"), "handleKillByIPCommand", "<ip-address>", "Disconnect sessions from an IP address.", "ip"),
];

immutable ChatCommand[] banCommandTable = [
    action("ip", permit("character.modify"), "handleIPBanCommand", "<ip-address> <duration> [reason]", "Ban an IP address."),
    action("character", permit("staff.discipline"), "handleBanCharacterCommand", "<character> <duration> <reason>", "Ban a character's account."),
    action("account", permit("account.moderate"), "handleAccountBannedCommand", "<account> <duration> [reason]", "Ban an account."),
];

immutable ChatCommand[] unbanCommandTable = [
    action("ip", permit("character.modify"), "handleIPUnBanCommand", "<ip-address>", "Remove a ban from an IP address."),
    action("character", permit("staff.discipline"), "handleUnBanCharacterCommand", "<character>", "Remove a ban from a character's account."),
    action("account", permit("staff.admin"), "handleAccountUnbanCommand", "<account>", "Remove a ban from an account."),
];

immutable ChatCommand[] instanceCommandTable = [
    action("reset", permit("staff.admin"), "handleResetInstanceCommand", "[instance-id]", "Remove one saved instance from the selected player."),
    action("resetall", permit("character.modify"), "handleResetAllInstancesCommand", "", "Remove all saved instances from the selected player."),
    action("shutdown", permit("staff.admin"), "handleShutdownInstanceCommand", "[instance-id]", "Close an instance by ID, or the current instance."),
    action("info", permit("character.modify"), "handleGetInstanceInfoCommand", "[instance-id]", "Inspect an instance by ID, or the current instance."),
    action("exit", permit("character.modify"), "handleExitInstanceCommand", "", "Return to the instance entrance."),
];

immutable ChatCommand[] arenaCommandTable = [
    unavailable("createteam", permit("battleground.manage"), "Rated arena teams are unavailable in this client."),
    unavailable("setteamleader", permit("battleground.manage"), "Rated arena teams are unavailable in this client."),
    unavailable("resetallratings", permit("staff.admin"), "Rated arena teams are unavailable in this client."),
];

immutable ChatCommand[] travelCommandTable = [
    shortcut("coords", "worldport"),
    shortcut("player", "appear"),
    shortcut("summon", "summon"),
];

immutable ChatCommand[] accessCommandTable = [
    action("whoami", permit(""), "handleGmAccessInfoCommand", "", "Show your roles and capabilities.", "status"),
    action("grant", roleAdministration, "handleGmAccessGrantCommand", "<account> <role>", "Assign a role to an account."),
    action("revoke", roleAdministration, "handleGmAccessRevokeCommand", "<account> <role>", "Remove a role from an account."),
];

immutable ChatCommand[] commandTable = [
    action("commands", permit(""), "handleCommandsCommand", "[command or prefix]", "Find commands you can use."),
    action("help", permit(""), "handleHelpCommand", "[command]", "Show syntax and details for a command."),
    action("announce", permit("staff.announce"), "handleAnnounceCommand", "[message]", "Send a realm-wide chat announcement."),
    action("wannounce", permit("staff.announce"), "handleWAnnounceCommand", "<message>", "Send a realm-wide on-screen announcement."),
    action("appear", permit("world.teleport"), "handleAppearCommand", "<name>", "Teleport to a player."),
    action("summon", permit("world.teleport"), "handleSummonCommand", "<name>", "Bring a player to your location."),
    action("kill", permit("character.combat"), "handleKillCommand", "", "Kill the selected unit."),
    action("killplr", permit("character.combat"), "handleKillByPlrCommand", "<character>", "Kill a player by name."),
    action("revive", permit("character.combat"), "handleReviveCommand", "", "Resurrect the selected player or yourself."),
    action("reviveplr", permit("character.combat"), "handleReviveStringcommand", "<character>", "Resurrect a player by name."),
    action("demorph", permit("character.modify"), "handleDeMorphCommand", "", "Restore your normal appearance."),
    action("mount", permit("character.modify"), "handleMountCommand", "<display-id>", "Mount the selected player with a display ID."),
    action("dismount", permit("character.mount"), "handleDismountCommand", "", "Dismount the selected unit or yourself."),
    action("gps", permit(""), "handleGPSCommand", "", "Show your position or the selected unit’s position.", "where"),
    action("scourge", permit("staff.admin"), "handleScourgeCommand", "[status|start|stop]", "Check or control the Scourge Invasion."),
    action("worldport", permit("world.teleport"), "handleWorldPortCommand", "<map> <x> <y> <z>", "Teleport to map coordinates."),
    action("start", permit("character.modify"), "handleStartCommand", "[race]", "Teleport to a racial starting area."),
    action("invincible", permit("staff.presence"), "handleInvincibleCommand", "", "Toggle invincibility."),
    action("invisible", permit("staff.presence"), "handleInvisibleCommand", "", "Toggle invisibility and invincibility."),
    action("playerinfo", permit("character.modify"), "handlePlayerInfo", "[name]", "Inspect a character and their account."),
    action("levelup", permit("character.modify"), "handleLevelUpCommand", "[levels]", "Raise the selected player's level."),
    section("modify", modifyCommandTable),
    section("waypoint", waypointCommandTable, "wp"),
    section("debug", debugCommandTable),
    section("gm", gmCommandTable),
    section("gmTicket", gMTicketCommandTable, "ticket"),
    section("gobject", gameObjectCommandTable, "object"),
    section("battleground", battlegroundCommandTable, "bg"),
    section("npc", nPCCommandTable),
    section("cheat", cheatCommandTable),
    section("account", accountCommandTable),
    section("honor", honorCommandTable),
    section("quest", questCommandTable),
    section("pet", petCommandTable),
    section("recall", recallCommandTable),
    section("guild", guildCommandTable),
    section("server", serverCommandTable),
    section("character", characterCommandTable),
    section("lookup", lookupCommandTable),
    section("admin", adminCommandTable),
    section("kick", kickCommandTable),
    section("ban", banCommandTable),
    section("unban", unbanCommandTable),
    section("instance", instanceCommandTable),
    section("arena", arenaCommandTable),
    action("kickplayer", permit("staff.discipline"), "handleKickCommand", "<name> [kick-reason]", "Disconnect a player with an optional reason."),
    action("gmannounce", permit("staff.announce"), "handleGMAnnounceCommand", "<message>", "Send a message to online staff."),
    action("clearcooldowns", permit("character.modify"), "handleClearCooldownsCommand", "", "Clear the selected player's spell cooldowns."),
    action("removeauras", permit("character.modify"), "handleRemoveAurasCommand", "", "Remove auras from the selected unit."),
    action("paralyze", permit("staff.discipline"), "handleParalyzeCommand", "", "Root the selected player."),
    action("unparalyze", permit("staff.discipline"), "handleUnParalyzeCommand", "", "Release the selected player's root."),
    action("gotrig", permit("world.teleport"), "handleTriggerCommand", "<trigger-id> [instance-id]", "Teleport to an area trigger."),
    action("modperiod", permit("character.modify"), "handleTransportPeriodCommand", "<period-ms>", "Save the current ship or zeppelin’s circuit time.", "transport-period"),
    action("logcomment", permit("support.lookup"), "handleGmLogCommentCommand", "<comment>", "Write a note to the GM log."),
    action("removesickness", permit("character.modify"), "handleRemoveRessurectionSickessAuraCommand", "", "Remove resurrection sickness."),
    action("fixscale", permit("character.modify"), "handleFixScaleCommand", "[scale]", "Set the selected unit's scale."),
    action("addtrainerspell", permit("world.trainers"), "handleAddTrainerSpellCommand", "<teaching-spell-id> [copper] [level]", "Add a lesson to the selected trainer."),
    section("travel", travelCommandTable, "go"),
    section("access", accessCommandTable),
    shortcut("learn", "character learn"),
];
