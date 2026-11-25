/// The in-game command catalog. Each action declares its syntax, description and access policy.
module dmangos.world.commandtable;

import dmangos.world.gmaccess : gmCapability;
import dmangos.world.updatefields;

struct CommandPermission
{
    char legacy;
    string capability;
    string alsoRequires;
    bool delegable = true;
}

private CommandPermission permit(char legacy) pure @safe
{
    return CommandPermission(legacy, gmCapability(legacy));
}

private CommandPermission permit(string capability, char legacy) pure @safe
{
    return CommandPermission(legacy, capability);
}

private enum roleAdministration = CommandPermission('z', "roles.manage", "staff.admin", false);
private enum legacyAdministration = CommandPermission('z', "staff.admin", null, false);

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

private ChatCommand section(string name, char legacy, immutable(ChatCommand)[] children,
    string alternate = null) pure @safe
{
    return ChatCommand(name, alternate, permit(legacy), null, null, null, children);
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
    ChatCommand row = action(name, permit('m'), null, arguments, description, alternate);
    row.field = field;
    row.maximum = maximum;
    row.decimal = decimal;
    return row;
}

immutable ChatCommand[] modifyCommandTable = [
    stat("hp", UNIT_FIELD_HEALTH, "Set health and maximum health.", UNIT_FIELD_MAXHEALTH),
    action("gender", permit('m'), "handleGenderChanger", "[0|1]", "Set the selected player's gender."),
    stat("mana", UNIT_FIELD_POWER1, "Set mana and maximum mana.", UNIT_FIELD_MAXPOWER1),
    stat("rage", UNIT_FIELD_POWER2, "Set rage and maximum rage.", UNIT_FIELD_MAXPOWER2),
    stat("energy", UNIT_FIELD_POWER4, "Set energy and maximum energy.", UNIT_FIELD_MAXPOWER4),
    action("level", permit('m'), "handleModifyLevelCommand", "<level>", "Set the selected unit's level."),
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
    action("gold", permit('m'), "handleModifyGoldCommand", "<copper>", "Adjust money by an amount in copper."),
    action("speed", permit('m'), "handleModifySpeedCommand", "<speed>", "Set movement speed."),
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
    action("infront", permit('d'), "handleDebugInFrontCommand", "", "Check whether the target is in front of you."),
    action("showreact", permit('d'), "handleShowReactionCommand", "<reaction-id>", "Preview a reaction on the selected unit."),
    action("aimove", permit('d'), "handleAIMoveCommand", "<x> <y> <z>", "Move the selected creature to coordinates on this map."),
    action("dist", permit('d'), "handleDistanceCommand", "", "Show the distance to the selected unit.", "distance"),
    action("face", permit('d'), "handleFaceCommand", "<degrees>", "Turn the selected creature to an angle in degrees."),
    action("moveinfo", permit('d'), "handleMoveInfoCommand", "", "Inspect the selected creature's movement."),
    action("setbytes", permit('d'), "handleSetBytesCommand", "<index> <b0> <b1> <b2> <b3>", "Set four bytes in a unit field."),
    action("getbytes", permit('d'), "handleGetBytesCommand", "<field>", "Read the four bytes of a unit field."),
    action("unroot", permit('d'), "handleDebugUnroot", "", "Send an unroot movement order."),
    action("root", permit('d'), "handleDebugRoot", "", "Send a root movement order."),
    action("landwalk", permit('d'), "handleDebugLandWalk", "", "Send a land-walking movement order."),
    action("waterwalk", permit('d'), "handleDebugWaterWalk", "", "Send a water-walking movement order."),
    action("castspell", permit('d'), "handleCastSpellCommand", "<spell-id>", "Cast a spell on the selected unit.", "cast"),
    action("castself", permit('d'), "handleCastSelfCommand", "<spell-id>", "Make the selected unit cast a spell on itself."),
    action("castspellne", permit('d'), "handleCastSpellNECommand", "<spell-id>", "Preview a spell's animation."),
    action("aggrorange", permit('d'), "handleAggroRangeCommand", "", "Show the selected creature's aggro range.", "aggro"),
    action("knockback", permit('d'), "handleKnockBackCommand", "[speed]", "Apply a knockback for testing."),
    action("fade", permit('d'), "handleFadeCommand", "<percent>", "Reduce your threat by a percentage."),
    action("threatMod", permit('d'), "handleThreatModCommand", "<percent>", "Change your threat by a signed percentage."),
    action("calcThreat", permit('d'), "handleCalcThreatCommand", "<damage> <spell-id>", "Estimate spell threat from damage and your modifiers."),
    action("threatList", permit('d'), "handleThreatListCommand", "", "List the selected creature's threat entries."),
    action("gettptime", permit('d'), "handleGetTransporterTime", "", "Show the circuit time of the ship or zeppelin aboard."),
    action("itempushresult", permit('d'), "handleSendItemPushResult", "<item-id> [count] [type] [flag-1] [flag-2] [flag-3]", "Send a test item acquisition notification."),
    action("setbit", permit('d'), "handleModifyBitCommand", "<field> <bit>", "Toggle a bit in an update field."),
    action("setvalue", permit('d'), "handleModifyValueCommand", "<field> <value>", "Set a unit update field."),
    unavailable("aispelltestbegin", permit('d'), "The automated creature spell tester is unavailable."),
    unavailable("aispelltestcontinue", permit('d'), "The automated creature spell tester is unavailable."),
    unavailable("aispelltestskip", permit('d'), "The automated creature spell tester is unavailable."),
    action("dumpcoords", permit('d'), "handleDebugDumpCoordsCommmand", "", "Show map, instance, coordinates and facing.", "position"),
    unavailable("sendpacket", permit('d'), "Sending raw packets from chat is disabled."),
    unavailable("sqlquery", permit('d'), "Use the MariaDB client for SQL."),
    action("rangecheck", permit('d'), "handleRangeCheckCommand", "", "Show distance and combat reach against the selected unit."),
    unavailable("setallratings", permit('d'), "Combat ratings are unavailable in this client."),
    action("testlos", permit('d'), "handleCollisionTestLOS", "", "Check line of sight to the selected unit.", "los"),
    action("testindoor", permit('d'), "handleCollisionTestIndoor", "", "Check whether your position is indoors."),
    action("getheight", permit('d'), "handleCollisionGetHeight", "", "Show terrain and collision heights at your position."),
    action("getpos", permit('d'), "handleGetPosCommand", "<area-id>", "Show coordinates for a world area."),
    action("getUint32Value", permit('d'), "handleGetUint32ValueCommand", "<field>", "Read a unit update field as an unsigned integer."),
];

immutable ChatCommand[] waypointCommandTable = [
    action("add", permit('w'), "handleWPAddCommand", "[wait-ms]", "Add your position to the route draft."),
    action("show", permit('w'), "handleWPShowCommand", "", "List points in the route draft.", "list"),
    action("hide", permit('w'), "handleWPHideCommand", "", "Discard unsaved route edits.", "discard"),
    action("delete", permit('w'), "handleWPDeleteCommand", "<point>", "Remove a point from the draft."),
    action("movehere", permit('w'), "handleWPMoveHereCommand", "<point>", "Move a draft point to your position.", "move"),
    unavailable("flags", permit('w'), "This route format has no per-point flags."),
    action("waittime", permit('w'), "handleWPWaitCommand", "<point> <wait-ms>", "Set a point's wait time in milliseconds.", "wait"),
    unavailable("emote", permit('w'), "Use a movement script with .wp script to play an emote."),
    unavailable("skin", permit('w'), "Use a movement script with .wp script to change the model."),
    action("change", permit('w'), "handleWPChangeNoCommand", "<point> <replacement>", "Renumber a draft point.", "renumber"),
    action("info", permit('w'), "handleWPInfoCommand", "<point>", "Show one draft point."),
    action("movetype", permit('w'), "handleWPMoveTypeCommand", "<loop|linear>", "Set the route to loop or run in a line.", "mode"),
    action("generate", permit('w'), "handleGenerateWaypoints", "", "Extend the draft to your position using the navigation mesh."),
    action("script", permit('w'), "handleWPScriptCommand", "<point> <script-id|0>", "Attach a movement script to a point or clear it with 0."),
    action("save", permit('w'), "handleSaveWaypoints", "", "Save the route for the selected spawn."),
    action("deleteall", permit('w'), "handleDeleteWaypoints", "", "Remove all points from the draft.", "clear"),
    unavailable("addfly", permit('w'), "This route editor saves ground waypoints."),
];

immutable ChatCommand[] gMTicketCommandTable = [
    action("list", permit("support.tickets", 'c'), "handleGMTicketListCommand", "[all]", "List open player tickets."),
    action("get", permit("support.tickets", 'c'), "handleGMTicketGetByIdCommand", "<id>", "Read a ticket by ID.", "show"),
    action("remove", permit("support.tickets", 'c'), "handleGMTicketRemoveByIdCommand", "<id>", "Close a ticket.", "close"),
    action("deletepermanent", permit('z'), "handleGMTicketDeletePermanentCommand", "<id>", "Permanently delete a ticket.", "delete"),
    action("assign", permit("support.tickets", 'c'), "handleGMTicketAssignToCommand", "<id> [character]", "Assign a ticket to a staff member or yourself."),
    action("release", permit("support.tickets", 'c'), "handleGMTicketReleaseCommand", "<id>", "Clear a ticket's assignment."),
    action("comment", permit("support.tickets", 'c'), "handleGMTicketCommentCommand", "<id> <note>", "Add a note to a ticket."),
    action("toggle", permit('z'), "handleGMTicketToggleTicketSystemStatusCommand", "", "Enable or disable player tickets."),
];

immutable ChatCommand[] guildCommandTable = [
    action("create", permit("guild.manage", 'm'), "createGuildCommand", "<name>", "Create a guild for the selected player."),
    action("rename", permit("guild.manage", 'm'), "handleRenameGuildCommand", "<name>", "Rename the selected player's guild."),
    action("members", permit("guild.manage", 'm'), "handleGuildMembersCommand", "", "List members and ranks in the selected player's guild."),
    action("removeplayer", permit("guild.manage", 'm'), "handleGuildRemovePlayerCommand", "", "Remove the selected player from their guild."),
    action("disband", permit("guild.manage", 'm'), "handleGuildDisbandCommand", "", "Disband the selected player's guild."),
];

immutable ChatCommand[] gameObjectCommandTable = [
    action("select", permit('o'), "handleGOSelect", "[name]", "Select the nearest game object."),
    action("delete", permit('o'), "handleGODelete", "", "Delete the selected game object."),
    action("spawn", permit('o'), "handleGOSpawn", "<entry-id> [save: 0|1]", "Spawn a game object by entry ID."),
    action("info", permit('o'), "handleGOInfo", "", "Inspect the selected game object."),
    action("activate", permit('o'), "handleGOActivate", "", "Activate the selected game object."),
    action("enable", permit('o'), "handleGOEnable", "", "Toggle whether the selected game object is usable."),
    action("scale", permit('o'), "handleGOScale", "<scale>", "Set the selected game object's scale."),
    action("animprogress", permit('o'), "handleGOAnimProgress", "[progress]", "Set the selected game object's animation progress.", "animation"),
    action("export", permit('o'), "handleGOExport", "", "Show the selected game object's placement and rotation."),
    action("move", permit('g'), "handleGOMove", "", "Move the selected game object to your position."),
    action("rotate", permit('g'), "handleGORotate", "<x|y|o> <degrees>", "Set rotation around an axis in degrees."),
];

immutable ChatCommand[] battlegroundCommandTable = [
    action("setbgscore", permit('e'), "handleSetBGScoreCommand", "<alliance|horde> <score>", "Set a below-win score in Warsong Gulch or Arathi Basin.", "score"),
    action("startbg", permit('e'), "handleStartBGCommand", "", "Start the current battleground.", "start"),
    unavailable("pausebg", permit('e'), "Battleground pause is unavailable."),
    action("bginfo", permit('e'), "handleBGInfoCommnad", "", "Show the current match and its status.", "status"),
    action("battleground", permit('e'), "handleBattlegroundCommand", "", "Show the current match and available tools."),
    action("setworldstate", permit('e'), "handleSetWorldStateCommand", "<id> <value>", "Set a world state in the current battleground.", "worldstate"),
    action("setworldstates", permit('e'), "handleSetWorldStatesCommand", "<id> <value>", "Set a world state in the current battleground."),
    action("playsound", permit('e'), "handlePlaySoundCommand", "<sound-id>", "Play a sound in the current battleground.", "sound"),
    action("setbfstatus", permit('e'), "handleSetBattlefieldStatusCommand", "start", "Start the current battleground with the start action."),
    action("leave", permit('e'), "handleBattlegroundExitCommand", "", "Leave the current battleground."),
    action("getqueue", permit('z'), "handleGetBattlegroundQueueCommand", "", "Show battlegroup queue and match counts.", "queue"),
    action("forcestart", permit('z'), "handleInitializeAllQueuedBattlegroundsCommand", "", "Start all queued battlegrounds."),
];

immutable ChatCommand[] nPCCommandTable = [
    action("vendoradditem", permit('n'), "handleItemCommand", "<item-id> [quantity] [extended-cost-id]", "Add an item to the selected vendor.", "sell"),
    action("vendorremoveitem", permit('n'), "handleItemRemoveCommand", "<item-id>", "Remove an item from the selected vendor.", "unsell"),
    action("flags", permit('n'), "handleNPCFlagCommand", "<flags>", "Set the selected NPC's flags."),
    action("emote", permit('n'), "handleEmoteCommand", "[emote]", "Set the selected NPC's emote state."),
    action("delete", permit('n'), "handleDeleteCommand", "", "Delete the selected creature and its saved spawn."),
    action("info", permit('n'), "handleNpcInfoCommand", "", "Inspect the selected NPC."),
    unavailable("addAgent", permit('n'), "Editing creature AI spells in chat is unavailable."),
    shortcut("traineradd", "addtrainerspell"),
    action("listAgent", permit('n'), "handleListAIAgentCommand", "", "Show the selected creature's scripts and combat spells.", "ai"),
    action("say", permit('n'), "handleMonsterSayCommand", "<message>", "Make the selected NPC say a message."),
    action("yell", permit('n'), "handleMonsterYellCommand", "<message>", "Make the selected NPC yell a message."),
    action("come", permit('n'), "handleNpcComeCommand", "", "Move the selected NPC to your position."),
    action("return", permit('n'), "handleNpcReturnCommand", "", "Send the selected NPC back to its spawn point."),
    action("spawn", permit('n'), "handleCreatureSpawnCommand", "<entry-id>", "Create a saved creature spawn."),
    action("respawn", permit('n'), "handleCreatureRespawnCommand", "", "Respawn the selected creature."),
    unavailable("spawnlink", permit('n'), "Editing spawn links in chat is unavailable."),
    action("possess", permit('n'), "handleNpcPossessCommand", "", "Take control of the selected NPC."),
    action("unpossess", permit('n'), "handleNpcUnPossessCommand", "", "Release control of a possessed NPC."),
    action("select", permit('n'), "handleNpcSelectCommand", "", "Select the closest NPC."),
    action("npcfollow", permit('m'), "handleNpcFollowCommand", "", "Make the selected NPC follow you.", "follow"),
    action("nullfollow", permit('m'), "handleNullFollowCommand", "", "Stop the selected NPC from following.", "unfollow"),
    unavailable("formationlink1", permit('m'), "Editing NPC formations in chat is unavailable."),
    unavailable("formationlink2", permit('m'), "Editing NPC formations in chat is unavailable."),
    unavailable("formationclear", permit('m'), "Editing NPC formations in chat is unavailable."),
];

immutable ChatCommand[] cheatCommandTable = [
    action("status", permit("testing.cheats", 'm'), "handleShowCheatsCommand", "", "Show active testing toggles."),
    action("taxi", permit("testing.cheats", 'm'), "handleTaxiCheatCommand", "<on|off>", "Toggle access to all flight paths."),
    action("cooldown", permit("testing.cheats", 'm'), "handleCooldownCheatCommand", "[on|off]", "Toggle spell cooldowns."),
    action("casttime", permit("testing.cheats", 'm'), "handleCastTimeCheatCommand", "[on|off]", "Toggle instant casts."),
    action("power", permit("testing.cheats", 'm'), "handlePowerCheatCommand", "[on|off]", "Toggle free spell casts."),
    action("god", permit("testing.cheats", 'm'), "handleGodModeCommand", "[on|off]", "Toggle damage immunity."),
    unavailable("fly", permit("testing.cheats", 'm'), "Player flight is unavailable in this client."),
    action("explore", permit("testing.cheats", 'm'), "handleExploreCheatCommand", "<on|off>", "Reveal or clear map exploration."),
    unavailable("flyspeed", permit("testing.cheats", 'm'), "Player flight is unavailable in this client."),
    unavailable("stack", permit("testing.cheats", 'm'), "The aura stacking override is unavailable."),
    action("triggerpass", permit("testing.cheats", 'm'), "handleTriggerpassCheatCommand", "[on|off]", "Toggle bypass of area trigger requirements.", "skip-requirements"),
];

immutable ChatCommand[] accountCommandTable = [
    action("level", legacyAdministration, "handleAccountLevelCommand", "<account> <0|1|2|3>", "Set an account's legacy staff level."),
    action("mute", permit('a'), "handleAccountMuteCommand", "<account> <duration>", "Mute an account for a duration."),
    action("unmute", permit('a'), "handleAccountUnmuteCommand", "<account>", "Remove an account mute."),
];

immutable ChatCommand[] honorCommandTable = [
    action("addpoints", permit('m'), "handleAddHonorCommand", "<points>", "Add honor to the selected player."),
    action("addkills", permit('m'), "handleAddKillCommand", "<kills>", "Add honorable kills to the selected player."),
    action("globaldailyupdate", permit('m'), "handleGlobalHonorDailyMaintenanceCommand", "", "Run the daily honor update for the realm."),
    action("singledailyupdate", permit('m'), "handleNextDayCommand", "", "Run the daily honor update for the selected player."),
    action("pvpcredit", permit('m'), "handlePVPCreditCommand", "<points> [rank]", "Send a test PvP credit notification."),
];

immutable ChatCommand[] petCommandTable = [
    unavailable("createpet", permit('m'), "Creating pets from chat is unavailable."),
    action("renamepet", permit('m'), "handleRenamePetCommand", "<name>", "Rename your pet.", "rename"),
    action("addspell", permit('m'), "handleAddPetSpellCommand", "<spell-id>", "Teach a spell to the selected player's pet.", "teach"),
    action("removespell", permit('m'), "handleRemovePetSpellCommand", "<spell-id>", "Remove a spell from the selected player's pet.", "forget"),
    unavailable("spawnbot", permit('a'), "Helper bots are unavailable."),
];

immutable ChatCommand[] recallCommandTable = [
    action("list", permit('q'), "handleRecallListCommand", "", "List saved locations."),
    action("port", permit('q'), "handleRecallGoCommand", "<name>", "Teleport to a saved location.", "go"),
    action("add", permit('q'), "handleRecallAddCommand", "<name>", "Save your current location."),
    action("del", permit('q'), "handleRecallDelCommand", "<name>", "Delete a saved location.", "delete"),
    action("portplayer", permit('m'), "handleRecallPortPlayerCommand", "<name> <location>", "Send a player to a saved location."),
];

immutable ChatCommand[] questCommandTable = [
    action("addboth", permit('2'), "handleQuestAddBothCommand", "<quest-id>", "Make the selected NPC start and finish a quest.", "add-both"),
    action("addfinish", permit('2'), "handleQuestAddFinishCommand", "<quest-id>", "Make the selected NPC finish a quest.", "add-finish"),
    action("addstart", permit('2'), "handleQuestAddStartCommand", "<quest-id>", "Make the selected NPC start a quest.", "add-start"),
    action("delboth", permit('2'), "handleQuestDelBothCommand", "<quest-id>", "Remove both quest relationships from the selected NPC.", "remove-both"),
    action("delfinish", permit('2'), "handleQuestDelFinishCommand", "<quest-id>", "Remove a quest's finish relationship from the selected NPC.", "remove-finish"),
    action("delstart", permit('2'), "handleQuestDelStartCommand", "<quest-id>", "Remove a quest's start relationship from the selected NPC.", "remove-start"),
    action("complete", permit('2'), "handleQuestFinishCommand", "<quest-id>", "Complete a quest for the selected player."),
    action("finisher", permit('2'), "handleQuestFinisherCommand", "<quest-id>", "Find NPCs or objects that finish a quest."),
    action("item", permit('2'), "handleQuestItemCommand", "<quest-id>", "List the items a quest requires."),
    action("list", permit('2'), "handleQuestListCommand", "[entry-id]", "List quests for a player or quest giver."),
    action("load", permit('2'), "handleQuestLoadCommand", "", "Reload quest definitions and giver relationships.", "reload"),
    action("lookup", permit('2'), "handleQuestLookupCommand", "<search>", "Search quests by title."),
    action("giver", permit('2'), "handleQuestGiverCommand", "<quest-id>", "Find NPCs or objects that start a quest."),
    action("remove", permit('2'), "handleQuestRemoveCommand", "<quest-id>", "Remove a quest from the selected player's log."),
    action("reward", permit('2'), "handleQuestRewardCommand", "<quest-id>", "Show a quest's rewards."),
    action("status", permit('2'), "handleQuestStatusCommand", "<quest-id>", "Show the selected player's status for a quest."),
    action("spawn", permit('2'), "handleQuestSpawnCommand", "<quest-id>", "Teleport to a spawn associated with a quest."),
    action("start", permit('2'), "handleQuestStartCommand", "<quest-id>", "Start a quest for the selected player."),
];

immutable ChatCommand[] serverCommandTable = [
    action("setmotd", permit('m'), "handleSetMotdCommand", "[message]", "Set the message of the day.", "motd"),
    action("rehash", permit('z'), "handleRehashCommand", "", "Reload server configuration.", "reload-config"),
    action("reloadtable", permit('m'), "handleDBReloadCommand", "<table>", "Reload supported world data.", "reload-data"),
    action("shutdown", permit('z'), "handleShutdownCommand", "[seconds]", "Schedule a server shutdown in seconds."),
    action("restart", permit('z'), "handleShutdownRestartCommand", "[seconds]", "Schedule a server restart in seconds."),
    action("cancelshutdown", permit('z'), "handleCancelShutdownCommand", "", "Cancel a scheduled shutdown or restart.", "cancel"),
    action("save", permit('s'), "handleSaveCommand", "", "Save the selected player."),
    action("saveall", permit('s'), "handleSaveAllCommand", "", "Save online characters.", "save-all"),
    action("info", permit('0'), "handleInfoCommand", "", "Show uptime and player counts.", "status"),
    action("netstatus", permit('0'), "handleNetworkStatusCommand", "", "Show connection counts.", "network"),
];

immutable ChatCommand[] gmCommandTable = [
    action("list", permit('0'), "handleGMListCommand", "", "List online staff."),
    action("off", permit('t'), "handleGMOffCommand", "", "Turn off the GM tag and whisper blocking."),
    action("on", permit('t'), "handleGMOnCommand", "", "Turn on the GM tag and whisper blocking."),
    action("whisperblock", permit('g'), "handleWhisperBlockCommand", "", "Block whispers while keeping the visible GM tag off.", "quiet"),
    action("allowwhispers", permit('c'), "handleAllowWhispersCommand", "<name>", "Allow whispers from a player while in GM mode.", "allow"),
    action("blockwhispers", permit('c'), "handleBlockWhispersCommand", "<name>", "Remove a player's whisper exception.", "block"),
];

immutable ChatCommand[] characterCommandTable = [
    action("learn", permit("character.learn", 'm'), "handleLearnCommand", "<spell-id|all>", "Teach a spell or the character's class spells."),
    action("unlearn", permit("character.learn", 'm'), "handleUnlearnCommand", "<spell-id>", "Remove a spell from the selected player."),
    action("getskillinfo", permit('m'), "handleGetSkillsInfoCommand", "", "Show the selected player's skills."),
    action("learnskill", permit("character.learn", 'm'), "handleLearnSkillCommand", "<skill-id> <value> [max]", "Teach a skill and set its value and cap."),
    action("advanceskill", permit("character.learn", 'm'), "handleModifySkillCommand", "<skill-id> [points]", "Raise a skill by the given number of points."),
    action("removeskill", permit("character.learn", 'm'), "handleRemoveSkillCommand", "<skill>", "Remove a skill."),
    action("increaseweaponskill", permit("character.learn", 'm'), "handleIncreaseWeaponSkill", "[points]", "Raise the equipped weapon skill."),
    action("resetreputation", permit('n'), "handleResetReputationCommand", "", "Reset reputation to starting values."),
    action("resetspells", permit("character.learn", 'n'), "handleResetSpellsCommand", "", "Restore the character's starting spells."),
    action("resettalents", permit("character.learn", 'n'), "handleResetTalentsCommand", "", "Reset the character's talents."),
    action("resetskills", permit("character.learn", 'n'), "handleResetSkillsCommand", "", "Restore the character's starting skills."),
    action("additem", permit('m'), "handleAddInvItemCommand", "<item-id> [count] [random-property]", "Give items to the selected player.", "give"),
    action("removeitem", permit('m'), "handleRemoveItemCommand", "<item-id> [count]", "Remove items from the selected player.", "take"),
    action("additemset", permit('m'), "handleAddItemSetCommand", "<set-id>", "Give an item set to the selected player."),
    action("advanceallskills", permit("character.learn", 'm'), "handleAdvanceAllSkillsCommand", "<points>", "Raise all skills by the given number of points."),
    action("getstanding", permit('m'), "handleGetStandingCommand", "<faction-id>", "Show standing with a faction."),
    action("setstanding", permit('m'), "handleSetStandingCommand", "<faction-id> <standing>", "Set standing with a faction."),
    action("showitems", permit('m'), "handleShowItems", "", "List the selected player's items.", "items"),
    action("showskills", permit('m'), "handleShowSkills", "", "List the selected player's skills.", "skills"),
    action("showinstances", permit('z'), "handleShowInstancesCommand", "", "List the selected player's saved instances."),
    action("rename", permit('m'), "handleRenameCommand", "<old-name> <new-name>", "Rename a character."),
    action("forcerename", permit('m'), "handleForceRenameCommand", "<name>", "Require a character to take a new name at login."),
    action("repairitems", permit('n'), "handleRepairItemsCommand", "", "Repair the selected player's equipment.", "repair"),
    unavailable("settitle", permit('m'), "Custom character titles are unavailable in this client."),
];

immutable ChatCommand[] lookupCommandTable = [
    action("item", permit('l'), "handleLookupItemCommand", "<search>", "Search items by name."),
    action("quest", permit('l'), "handleQuestLookupCommand", "<search>", "Search quests by title."),
    action("creature", permit('l'), "handleLookupCreatureCommand", "<search>", "Search creature templates by name."),
    action("object", permit('l'), "handleLookupObjectCommand", "<search>", "Search game object templates by name."),
    action("spell", permit('1'), "handleLookupSpellCommand", "<search>", "Search spells by name."),
    action("skill", permit('1'), "handleLookupSkillCommand", "<search>", "Search skills by name."),
    action("faction", permit('1'), "handleLookupFactionCommand", "<search>", "Search factions by name."),
];

immutable ChatCommand[] adminCommandTable = [
    action("castall", permit('z'), "handleCastAllCommand", "<spell-id>", "Make online players on this worker cast a spell."),
    action("dispelall", permit('z'), "handleDispelAllCommand", "[all: 0|1]", "Remove harmful or helpful auras from players on this worker."),
    unavailable("renameallinvalidchars", permit('z'), "Use .character forcerename for individual characters."),
    action("masssummon", permit('z'), "handleMassSummonCommand", "", "Summon online players to your position."),
    action("playall", permit('z'), "handleGlobalPlaySoundCommand", "<sound-id>", "Play a sound for all players."),
];

immutable ChatCommand[] kickCommandTable = [
    action("byplayer", permit('f'), "handleKillByPlayerCommand", "<character>", "Disconnect a player by character name.", "player"),
    action("byaccount", permit('f'), "handleKillBySessionCommand", "<account>", "Disconnect a session by account name.", "account"),
    action("byip", permit('f'), "handleKillByIPCommand", "<ip-address>", "Disconnect sessions from an IP address.", "ip"),
];

immutable ChatCommand[] banCommandTable = [
    action("ip", permit('m'), "handleIPBanCommand", "<ip-address> <duration> [reason]", "Ban an IP address."),
    action("character", permit('b'), "handleBanCharacterCommand", "<character> <duration> <reason>", "Ban a character's account."),
    action("account", permit('a'), "handleAccountBannedCommand", "<account> <duration> [reason]", "Ban an account."),
];

immutable ChatCommand[] unbanCommandTable = [
    action("ip", permit('m'), "handleIPUnBanCommand", "<ip-address>", "Remove a ban from an IP address."),
    action("character", permit('b'), "handleUnBanCharacterCommand", "<character>", "Remove a ban from a character's account."),
    action("account", permit('z'), "handleAccountUnbanCommand", "<account>", "Remove a ban from an account."),
];

immutable ChatCommand[] instanceCommandTable = [
    action("reset", permit('z'), "handleResetInstanceCommand", "[instance-id]", "Remove one saved instance from the selected player."),
    action("resetall", permit('m'), "handleResetAllInstancesCommand", "", "Remove all saved instances from the selected player."),
    action("shutdown", permit('z'), "handleShutdownInstanceCommand", "[instance-id]", "Close an instance by ID, or the current instance."),
    action("info", permit('m'), "handleGetInstanceInfoCommand", "[instance-id]", "Inspect an instance by ID, or the current instance."),
    action("exit", permit('m'), "handleExitInstanceCommand", "", "Return to the instance entrance."),
];

immutable ChatCommand[] arenaCommandTable = [
    unavailable("createteam", permit('e'), "Rated arena teams are unavailable in this client."),
    unavailable("setteamleader", permit('e'), "Rated arena teams are unavailable in this client."),
    unavailable("resetallratings", permit('z'), "Rated arena teams are unavailable in this client."),
];

immutable ChatCommand[] travelCommandTable = [
    shortcut("coords", "worldport"),
    shortcut("player", "appear"),
    shortcut("summon", "summon"),
];

immutable ChatCommand[] accessCommandTable = [
    action("whoami", permit('0'), "handleGmAccessInfoCommand", "", "Show your roles and capabilities.", "status"),
    action("grant", roleAdministration, "handleGmAccessGrantCommand", "<account> <role>", "Assign a role to an account."),
    action("revoke", roleAdministration, "handleGmAccessRevokeCommand", "<account> <role>", "Remove a role from an account."),
];

immutable ChatCommand[] commandTable = [
    action("commands", permit('0'), "handleCommandsCommand", "[command or prefix]", "Find commands you can use."),
    action("help", permit('0'), "handleHelpCommand", "[command]", "Show syntax and details for a command."),
    action("announce", permit('u'), "handleAnnounceCommand", "[message]", "Send a realm-wide chat announcement."),
    action("wannounce", permit('u'), "handleWAnnounceCommand", "<message>", "Send a realm-wide on-screen announcement."),
    action("appear", permit('v'), "handleAppearCommand", "<name>", "Teleport to a player."),
    action("summon", permit('v'), "handleSummonCommand", "<name>", "Bring a player to your location."),
    action("kill", permit('r'), "handleKillCommand", "", "Kill the selected unit."),
    action("killplr", permit('r'), "handleKillByPlrCommand", "<character>", "Kill a player by name."),
    action("revive", permit('r'), "handleReviveCommand", "", "Resurrect the selected player or yourself."),
    action("reviveplr", permit('r'), "handleReviveStringcommand", "<character>", "Resurrect a player by name."),
    action("demorph", permit('m'), "handleDeMorphCommand", "", "Restore your normal appearance."),
    action("mount", permit('m'), "handleMountCommand", "<display-id>", "Mount the selected player with a display ID."),
    action("dismount", permit('h'), "handleDismountCommand", "", "Dismount the selected unit or yourself."),
    action("gps", permit('0'), "handleGPSCommand", "", "Show your position or the selected unit’s position.", "where"),
    action("scourge", permit('z'), "handleScourgeCommand", "[status|start|stop]", "Check or control the Scourge Invasion."),
    action("worldport", permit('v'), "handleWorldPortCommand", "<map> <x> <y> <z>", "Teleport to map coordinates."),
    action("start", permit('m'), "handleStartCommand", "[race]", "Teleport to a racial starting area."),
    action("invincible", permit('j'), "handleInvincibleCommand", "", "Toggle invincibility."),
    action("invisible", permit('i'), "handleInvisibleCommand", "", "Toggle invisibility and invincibility."),
    action("playerinfo", permit('m'), "handlePlayerInfo", "[name]", "Inspect a character and their account."),
    action("levelup", permit('m'), "handleLevelUpCommand", "[levels]", "Raise the selected player's level."),
    section("modify", 'm', modifyCommandTable),
    section("waypoint", 'w', waypointCommandTable, "wp"),
    section("debug", 'd', debugCommandTable),
    section("gm", '0', gmCommandTable),
    section("gmTicket", 'c', gMTicketCommandTable, "ticket"),
    section("gobject", 'o', gameObjectCommandTable, "object"),
    section("battleground", 'e', battlegroundCommandTable, "bg"),
    section("npc", 'n', nPCCommandTable),
    section("cheat", 'm', cheatCommandTable),
    section("account", 'a', accountCommandTable),
    section("honor", 'm', honorCommandTable),
    section("quest", 'q', questCommandTable),
    section("pet", 'm', petCommandTable),
    section("recall", 'q', recallCommandTable),
    section("guild", 'm', guildCommandTable),
    section("server", '0', serverCommandTable),
    section("character", '0', characterCommandTable),
    section("lookup", 'l', lookupCommandTable),
    section("admin", 'z', adminCommandTable),
    section("kick", 'm', kickCommandTable),
    section("ban", 'm', banCommandTable),
    section("unban", 'm', unbanCommandTable),
    section("instance", 'm', instanceCommandTable),
    section("arena", 'e', arenaCommandTable),
    action("kickplayer", permit('b'), "handleKickCommand", "<name> [kick-reason]", "Disconnect a player with an optional reason."),
    action("gmannounce", permit('u'), "handleGMAnnounceCommand", "<message>", "Send a message to online staff."),
    action("clearcooldowns", permit('m'), "handleClearCooldownsCommand", "", "Clear the selected player's spell cooldowns."),
    action("removeauras", permit('m'), "handleRemoveAurasCommand", "", "Remove auras from the selected unit."),
    action("paralyze", permit('b'), "handleParalyzeCommand", "", "Root the selected player."),
    action("unparalyze", permit('b'), "handleUnParalyzeCommand", "", "Release the selected player's root."),
    action("gotrig", permit('v'), "handleTriggerCommand", "<trigger-id> [instance-id]", "Teleport to an area trigger."),
    unavailable("modperiod", permit('m'), "Changing a transport schedule in chat is unavailable."),
    action("logcomment", permit('1'), "handleGmLogCommentCommand", "<comment>", "Write a note to the GM log."),
    action("removesickness", permit('m'), "handleRemoveRessurectionSickessAuraCommand", "", "Remove resurrection sickness."),
    action("fixscale", permit('m'), "handleFixScaleCommand", "[scale]", "Set the selected unit's scale."),
    action("addtrainerspell", permit("world.trainers", 'm'), "handleAddTrainerSpellCommand", "<teaching-spell-id> [copper] [level]", "Add a lesson to the selected trainer."),
    section("travel", 'v', travelCommandTable, "go"),
    section("access", '0', accessCommandTable),
    shortcut("learn", "character learn"),
];
