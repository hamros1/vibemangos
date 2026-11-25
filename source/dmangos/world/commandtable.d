/**
 * Registers staff commands and their usage. Table order is the fallback for existing
 * abbreviations. Exact names take precedence. The group key supplies a named capability
 * for database roles and a compatible permission letter for legacy accounts.
 */
module dmangos.world.commandtable;

/// One row of a `ChatCommand` table.
struct ChatCommand
{
    string name;
    char group;          /// the permission letter; '0' for everyone with permissions
    string handler;      /// the handler's name, or null
    string help;
    immutable(ChatCommand)[] children;
    string field;        /// the update field a `.modify` row sets, as a D expression
    string fieldMax;     /// the update field of its maximum, set too; or null
    ubyte valueType;     /// 1 integer, 2 float
}

/// The `.modify` commands.
immutable ChatCommand[] modifyCommandTable = [
    ChatCommand("hp", 'm', null, "Modifies health points (HP) of selected target", null, "UNIT_FIELD_HEALTH", "UNIT_FIELD_MAXHEALTH", 1),
    ChatCommand("gender", 'm', "HandleGenderChanger", "Changes gender of selected target. Usage: 0=male, 1=female.", null, null, null, 0),
    ChatCommand("mana", 'm', null, "Modifies mana points (MP) of selected target.", null, "UNIT_FIELD_POWER1", "UNIT_FIELD_MAXPOWER1", 1),
    ChatCommand("rage", 'm', null, "Modifies rage points of selected target.", null, "UNIT_FIELD_POWER2", "UNIT_FIELD_MAXPOWER2", 1),
    ChatCommand("energy", 'm', null, "Modifies energy points of selected target.", null, "UNIT_FIELD_POWER4", "UNIT_FIELD_MAXPOWER4", 1),
    ChatCommand("level", 'm', "HandleModifyLevelCommand", "Modifies the level of selected target.", null, null, null, 0),
    ChatCommand("strength", 'm', null, "Modifies the strength value of the selected target.", null, "UNIT_FIELD_STAT0", null, 1),
    ChatCommand("agility", 'm', null, "Modifies the agility value of the selected target.", null, "UNIT_FIELD_STAT1", null, 1),
    ChatCommand("intelligence", 'm', null, "Modifies the intelligence value of the selected target.", null, "UNIT_FIELD_STAT3", null, 1),
    ChatCommand("spirit", 'm', null, "Modifies the spirit value of the selected target.", null, "UNIT_FIELD_STAT4", null, 1),
    ChatCommand("armor", 'm', null, "Modifies the armor of selected target.", null, "UNIT_FIELD_RESISTANCES", null, 1),
    ChatCommand("holy", 'm', null, "Modifies the holy resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 1", null, 1),
    ChatCommand("fire", 'm', null, "Modifies the fire resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 2", null, 1),
    ChatCommand("nature", 'm', null, "Modifies the nature resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 3", null, 1),
    ChatCommand("frost", 'm', null, "Modifies the frost resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 4", null, 1),
    ChatCommand("shadow", 'm', null, "Modifies the shadow resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 5", null, 1),
    ChatCommand("arcane", 'm', null, "Modifies the arcane resistance of selected target.", null, "UNIT_FIELD_RESISTANCES + 6", null, 1),
    ChatCommand("damage", 'm', null, "Modifies the damage done by the selected target.", null, "UNIT_FIELD_MINDAMAGE", "UNIT_FIELD_MAXDAMAGE", 2),
    ChatCommand("ap", 'm', null, "Modifies the attack power of the selected target.", null, "UNIT_FIELD_ATTACK_POWER", null, 1),
    ChatCommand("rangeap", 'm', null, "Modifies the range attack power of the selected target.", null, "UNIT_FIELD_RANGED_ATTACK_POWER", null, 1),
    ChatCommand("scale", 'm', null, "Modifies the scale of the selected target.", null, "OBJECT_FIELD_SCALE_X", null, 2),
    ChatCommand("gold", 'm', "HandleModifyGoldCommand", "Modifies the gold amount of the selected target. Copper value.", null, null, null, 0),
    ChatCommand("speed", 'm', "HandleModifySpeedCommand", "Modifies the movement speed of the selected target.", null, null, null, 0),
    ChatCommand("nativedisplayid", 'm', null, "Modifies the native display identifier of the target.", null, "UNIT_FIELD_NATIVEDISPLAYID", null, 1),
    ChatCommand("displayid", 'm', null, "Modifies the display identifier (DisplayID) of the target.", null, "UNIT_FIELD_DISPLAYID", null, 1),
    ChatCommand("flags", 'm', null, "Modifies the flags of the selected target.", null, "UNIT_FIELD_FLAGS", null, 1),
    ChatCommand("faction", 'm', null, "Modifies the faction template of the selected target.", null, "UNIT_FIELD_FACTIONTEMPLATE", null, 1),
    ChatCommand("dynamicflags", 'm', null, "Modifies the dynamic flags of the selected target.", null, "UNIT_DYNAMIC_FLAGS", null, 1),
    ChatCommand("talentpoints", 'm', null, "Modifies the available talent points of the selected target.", null, "PLAYER_CHARACTER_POINTS1", null, 1),
    ChatCommand("happiness", 'm', null, "Modifies the happiness value of the selected target.", null, "UNIT_FIELD_POWER5", "UNIT_FIELD_MAXPOWER5", 1),
    ChatCommand("boundingraidius", 'm', null, "Modifies the bounding radius of the selected target.", null, "UNIT_FIELD_BOUNDINGRADIUS", null, 2),
    ChatCommand("combatreach", 'm', null, "Modifies the combat reach of the selected target.", null, "UNIT_FIELD_COMBATREACH", null, 2),
    ChatCommand("npcemotestate", 'm', null, "Modifies the NPC emote state of the selected target.", null, "UNIT_NPC_EMOTESTATE", null, 1),
    ChatCommand("bytes", 'm', null, "WARNING! Modifies the bytes entry of selected target.", null, "UNIT_FIELD_BYTES_0", null, 1),
];

/// The `.debug` commands.
immutable ChatCommand[] debugCommandTable = [
    ChatCommand("infront", 'd', "HandleDebugInFrontCommand", "", null, null, null, 0),
    ChatCommand("showreact", 'd', "HandleShowReactionCommand", "", null, null, null, 0),
    ChatCommand("aimove", 'd', "HandleAIMoveCommand", ".debug aimove <x> <y> <z>", null, null, null, 0),
    ChatCommand("dist", 'd', "HandleDistanceCommand", "", null, null, null, 0),
    ChatCommand("face", 'd', "HandleFaceCommand", "", null, null, null, 0),
    ChatCommand("moveinfo", 'd', "HandleMoveInfoCommand", "", null, null, null, 0),
    ChatCommand("setbytes", 'd', "HandleSetBytesCommand", "", null, null, null, 0),
    ChatCommand("getbytes", 'd', "HandleGetBytesCommand", "", null, null, null, 0),
    ChatCommand("unroot", 'd', "HandleDebugUnroot", "", null, null, null, 0),
    ChatCommand("root", 'd', "HandleDebugRoot", "", null, null, null, 0),
    ChatCommand("landwalk", 'd', "HandleDebugLandWalk", "", null, null, null, 0),
    ChatCommand("waterwalk", 'd', "HandleDebugWaterWalk", "", null, null, null, 0),
    ChatCommand("castspell", 'd', "HandleCastSpellCommand", ".castspell <spellid> - Casts spell on target.", null, null, null, 0),
    ChatCommand("castself", 'd', "HandleCastSelfCommand", ".castself <spellId> - Target casts spell <spellId>Â on itself.", null, null, null, 0),
    ChatCommand("castspellne", 'd', "HandleCastSpellNECommand", ".castspellne <spellid> - Casts spell on target (only plays animations, doesnt handle effects or range/facing/etc.", null, null, null, 0),
    ChatCommand("aggrorange", 'd', "HandleAggroRangeCommand", ".aggrorange - Shows aggro Range of the selected Creature.", null, null, null, 0),
    ChatCommand("knockback", 'd', "HandleKnockBackCommand", ".knockback <value> - Knocks you back.", null, null, null, 0),
    ChatCommand("fade", 'd', "HandleFadeCommand", ".debug fade <0-100> — Reduces your threat on the selected creature by a percentage.", null, null, null, 0),
    ChatCommand("threatMod", 'd', "HandleThreatModCommand", ".debug threatMod <-100–100> — Adjusts your threat on the selected creature by a percentage.", null, null, null, 0),
    ChatCommand("calcThreat", 'd', "HandleCalcThreatCommand", ".debug calcThreat <damage> <spell-id> — Estimates threat with your current modifiers.", null, null, null, 0),
    ChatCommand("threatList", 'd', "HandleThreatListCommand", ".threatList  - returns all AI_Targets of the selected Creature.", null, null, null, 0),
    ChatCommand("gettptime", 'd', "HandleGetTransporterTime", "Shows the current ship or zeppelin circuit time.", null, null, null, 0),
    ChatCommand("itempushresult", 'd', "HandleSendItemPushResult", "sends item push result", null, null, null, 0),
    ChatCommand("setbit", 'd', "HandleModifyBitCommand", "", null, null, null, 0),
    ChatCommand("setvalue", 'd', "HandleModifyValueCommand", "", null, null, null, 0),
    ChatCommand("aispelltestbegin", 'd', "HandleAIAgentDebugBegin", "", null, null, null, 0),
    ChatCommand("aispelltestcontinue", 'd', "HandleAIAgentDebugContinue", "", null, null, null, 0),
    ChatCommand("aispelltestskip", 'd', "HandleAIAgentDebugSkip", "", null, null, null, 0),
    ChatCommand("dumpcoords", 'd', "HandleDebugDumpCoordsCommmand", "", null, null, null, 0),
    ChatCommand("sendpacket", 'd', "HandleSendpacket", "<opcode ID>, <data>", null, null, null, 0),
    ChatCommand("sqlquery", 'd', "HandleSQLQueryCommand", "<sql query>", null, null, null, 0),
    ChatCommand("rangecheck", 'd', "HandleRangeCheckCommand", "Checks the 'yard' range and internal range between the player and the target.", null, null, null, 0),
    ChatCommand("setallratings", 'd', "HandleRatingsCommand", "Sets rating values to incremental numbers based on their index.", null, null, null, 0),
    ChatCommand("testlos", 'd', "HandleCollisionTestLOS", "tests los", null, null, null, 0),
    ChatCommand("testindoor", 'd', "HandleCollisionTestIndoor", "tests indoor", null, null, null, 0),
    ChatCommand("getheight", 'd', "HandleCollisionGetHeight", "Gets height", null, null, null, 0),
    ChatCommand("getpos", 'd', "HandleGetPosCommand", "", null, null, null, 0),
    ChatCommand("getUint32Value", 'd', "HandleGetUint32ValueCommand", "", null, null, null, 0),
];

/// The `.waypoint` commands.
immutable ChatCommand[] waypointCommandTable = [
    ChatCommand("add", 'w', "HandleWPAddCommand", ".waypoint add [wait-ms] — Adds your position to the draft", null, null, null, 0),
    ChatCommand("show", 'w', "HandleWPShowCommand", ".waypoint show — Lists the selected spawn’s draft", null, null, null, 0),
    ChatCommand("hide", 'w', "HandleWPHideCommand", ".waypoint hide — Closes the draft and discards unsaved edits", null, null, null, 0),
    ChatCommand("delete", 'w', "HandleWPDeleteCommand", ".waypoint delete <point>", null, null, null, 0),
    ChatCommand("movehere", 'w', "HandleWPMoveHereCommand", ".waypoint movehere <point>", null, null, null, 0),
    ChatCommand("flags", 'w', "HandleWPFlagsCommand", "Wp flags", null, null, null, 0),
    ChatCommand("waittime", 'w', "HandleWPWaitCommand", ".waypoint waittime <point> <milliseconds>", null, null, null, 0),
    ChatCommand("emote", 'w', "HandleWPEmoteCommand", "Emote at this wp", null, null, null, 0),
    ChatCommand("skin", 'w', "HandleWPSkinCommand", "Skin at this wp", null, null, null, 0),
    ChatCommand("change", 'w', "HandleWPChangeNoCommand", ".waypoint change <point> <new-point>", null, null, null, 0),
    ChatCommand("info", 'w', "HandleWPInfoCommand", ".waypoint info <point>", null, null, null, 0),
    ChatCommand("movetype", 'w', "HandleWPMoveTypeCommand", ".waypoint movetype <loop|linear>", null, null, null, 0),
    ChatCommand("generate", 'w', "HandleGenerateWaypoints", ".waypoint generate — Extends the draft to your position using the navigation mesh.", null, null, null, 0),
    ChatCommand("script", 'w', "HandleWPScriptCommand", ".waypoint script <point> <script-id|0> — Attaches or clears a movement script", null, null, null, 0),
    ChatCommand("save", 'w', "HandleSaveWaypoints", ".waypoint save — Persists the selected route", null, null, null, 0),
    ChatCommand("deleteall", 'w', "HandleDeleteWaypoints", ".waypoint deleteall — Clears the selected draft", null, null, null, 0),
    ChatCommand("addfly", 'w', "HandleWaypointAddFlyCommand", "Adds a flying waypoint", null, null, null, 0),
];

/// The `.gmTicket` commands.
immutable ChatCommand[] gMTicketCommandTable = [
    ChatCommand("list", 'c', "HandleGMTicketListCommand", "Lists all active GM Tickets.", null, null, null, 0),
    ChatCommand("get", 'c', "HandleGMTicketGetByIdCommand", "Gets GM Ticket with ID x.", null, null, null, 0),
    ChatCommand("remove", 'c', "HandleGMTicketRemoveByIdCommand", "Removes GM Ticket with ID x.", null, null, null, 0),
    ChatCommand("deletepermanent", 'z', "HandleGMTicketDeletePermanentCommand", "Deletes GM Ticket with ID x permanently.", null, null, null, 0),
    ChatCommand("assign", 'c', "HandleGMTicketAssignToCommand", "Assignes GM Ticket with id x to GM y (if empty to your self).", null, null, null, 0),
    ChatCommand("release", 'c', "HandleGMTicketReleaseCommand", "Releases assigned GM Ticket with ID x.", null, null, null, 0),
    ChatCommand("comment", 'c', "HandleGMTicketCommentCommand", "Sets comment x to GM Ticket with ID y.", null, null, null, 0),
    ChatCommand("toggle", 'z', "HandleGMTicketToggleTicketSystemStatusCommand", "Toggles the ticket system status.", null, null, null, 0),
];

/// The `.guild` commands.
immutable ChatCommand[] guildCommandTable = [
    ChatCommand("create", 'm', "CreateGuildCommand", "Creates a guild.", null, null, null, 0),
    ChatCommand("rename", 'm', "HandleRenameGuildCommand", "Renames a guild.", null, null, null, 0),
    ChatCommand("members", 'm', "HandleGuildMembersCommand", "Lists guildmembers and their ranks.", null, null, null, 0),
    ChatCommand("removeplayer", 'm', "HandleGuildRemovePlayerCommand", "Removes a player from a guild.", null, null, null, 0),
    ChatCommand("disband", 'm', "HandleGuildDisbandCommand", "Disbands the guild of your target.", null, null, null, 0),
];

/// The `.gobject` commands.
immutable ChatCommand[] gameObjectCommandTable = [
    ChatCommand("select", 'o', "HandleGOSelect", "Selects the nearest GameObject to you", null, null, null, 0),
    ChatCommand("delete", 'o', "HandleGODelete", "Deletes selected GameObject", null, null, null, 0),
    ChatCommand("spawn", 'o', "HandleGOSpawn", "Spawns a GameObject by ID", null, null, null, 0),
    ChatCommand("info", 'o', "HandleGOInfo", "Gives you informations about selected GO", null, null, null, 0),
    ChatCommand("activate", 'o', "HandleGOActivate", "Activates/Opens the selected GO.", null, null, null, 0),
    ChatCommand("enable", 'o', "HandleGOEnable", "Enables the selected GO for use.", null, null, null, 0),
    ChatCommand("scale", 'o', "HandleGOScale", "Sets scale of selected GO", null, null, null, 0),
    ChatCommand("animprogress", 'o', "HandleGOAnimProgress", "Sets anim progress", null, null, null, 0),
    ChatCommand("export", 'o', "HandleGOExport", "Prints coordinates and rotation of the selected game object.", null, null, null, 0),
    ChatCommand("move", 'g', "HandleGOMove", "Moves gameobject to player xyz", null, null, null, 0),
    ChatCommand("rotate", 'g', "HandleGORotate", "<Axis> <Value> - Rotates the object. <Axis> x,y, Default o.", null, null, null, 0),
];

/// The `.battleground` commands.
immutable ChatCommand[] battlegroundCommandTable = [
    ChatCommand("setbgscore", 'e', "HandleSetBGScoreCommand", ".battleground setbgscore <alliance|horde> <score> — Sets a below-win score in Warsong Gulch or Arathi Basin.", null, null, null, 0),
    ChatCommand("startbg", 'e', "HandleStartBGCommand", "Starts current battleground match.", null, null, null, 0),
    ChatCommand("pausebg", 'e', "HandlePauseBGCommand", "Pauses current battleground match.", null, null, null, 0),
    ChatCommand("bginfo", 'e', "HandleBGInfoCommnad", "Displays information about current battleground.", null, null, null, 0),
    ChatCommand("battleground", 'e', "HandleBattlegroundCommand", "Shows the current match and how to list match commands.", null, null, null, 0),
    ChatCommand("setworldstate", 'e', "HandleSetWorldStateCommand", "<var> <val> - Var can be in hex. WS Value.", null, null, null, 0),
    ChatCommand("setworldstates", 'e', "HandleSetWorldStatesCommand", "<var> <val> - Var can be in hex. WS Value.", null, null, null, 0),
    ChatCommand("playsound", 'e', "HandlePlaySoundCommand", "<val>. Val can be in hex.", null, null, null, 0),
    ChatCommand("setbfstatus", 'e', "HandleSetBattlefieldStatusCommand", ".battleground setbfstatus start — Starts the current match.", null, null, null, 0),
    ChatCommand("leave", 'e', "HandleBattlegroundExitCommand", "Leaves the current battleground.", null, null, null, 0),
    ChatCommand("getqueue", 'z', "HandleGetBattlegroundQueueCommand", "Shows queue and match counts from the battlegroup coordinator.", null, null, null, 0),
    ChatCommand("forcestart", 'z', "HandleInitializeAllQueuedBattlegroundsCommand", "Forces initialitation of all battlegrounds with active queue.", null, null, null, 0),
];

/// The `.npc` commands.
immutable ChatCommand[] nPCCommandTable = [
    ChatCommand("vendoradditem", 'n', "HandleItemCommand", "Adds to vendor", null, null, null, 0),
    ChatCommand("vendorremoveitem", 'n', "HandleItemRemoveCommand", "Removes from vendor.", null, null, null, 0),
    ChatCommand("flags", 'n', "HandleNPCFlagCommand", "Changes NPC flags", null, null, null, 0),
    ChatCommand("emote", 'n', "HandleEmoteCommand", ".emote - Sets emote state", null, null, null, 0),
    ChatCommand("delete", 'n', "HandleDeleteCommand", "Deletes mob from db and world.", null, null, null, 0),
    ChatCommand("info", 'n', "HandleNpcInfoCommand", "Displays NPC information", null, null, null, 0),
    ChatCommand("addAgent", 'n', "HandleAddAIAgentCommand", ".npc addAgent <agent> <procEvent> <procChance> <procCount> <spellId> <spellType> <spelltargetType> <spellCooldown> <floatMisc1> <Misc2>", null, null, null, 0),
    ChatCommand("traineradd", 'm', "HandleAddTrainerSpellCommand", ".npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]", null, null, null, 0),
    ChatCommand("listAgent", 'n', "HandleListAIAgentCommand", ".npc listAgent — Shows the selected creature’s scripts and combat spells", null, null, null, 0),
    ChatCommand("say", 'n', "HandleMonsterSayCommand", ".npc say <text> - Makes selected mob say text <text>.", null, null, null, 0),
    ChatCommand("yell", 'n', "HandleMonsterYellCommand", ".npc yell <Text> - Makes selected mob yell text <text>.", null, null, null, 0),
    ChatCommand("come", 'n', "HandleNpcComeCommand", ".npc come - Makes npc move to your position", null, null, null, 0),
    ChatCommand("return", 'n', "HandleNpcReturnCommand", ".npc return - Returns ncp to spawnpoint.", null, null, null, 0),
    ChatCommand("spawn", 'n', "HandleCreatureSpawnCommand", ".npc spawn - Spawns npc of entry <id>", null, null, null, 0),
    ChatCommand("respawn", 'n', "HandleCreatureRespawnCommand", ".respawn - Respawns a dead npc from it's corpse.", null, null, null, 0),
    ChatCommand("spawnlink", 'n', "HandleNpcSpawnLinkCommand", ".spawnlink sqlentry", null, null, null, 0),
    ChatCommand("possess", 'n', "HandleNpcPossessCommand", ".npc possess - Possess an npc (mind control)", null, null, null, 0),
    ChatCommand("unpossess", 'n', "HandleNpcUnPossessCommand", ".npc unpossess - Unposses any currently possessed npc.", null, null, null, 0),
    ChatCommand("select", 'n', "HandleNpcSelectCommand", ".npc select - selects npc closest", null, null, null, 0),
    ChatCommand("npcfollow", 'm', "HandleNpcFollowCommand", "Sets npc to follow you", null, null, null, 0),
    ChatCommand("nullfollow", 'm', "HandleNullFollowCommand", "Sets npc to not follow anything", null, null, null, 0),
    ChatCommand("formationlink1", 'm', "HandleFormationLink1Command", "Sets formation master.", null, null, null, 0),
    ChatCommand("formationlink2", 'm', "HandleFormationLink2Command", "Sets formation slave with distance and angle", null, null, null, 0),
    ChatCommand("formationclear", 'm', "HandleFormationClearCommand", "Removes formation from creature", null, null, null, 0),
];

/// The `.cheat` commands.
immutable ChatCommand[] cheatCommandTable = [
    ChatCommand("status", 'm', "HandleShowCheatsCommand", "Shows active cheats.", null, null, null, 0),
    ChatCommand("taxi", 'm', "HandleTaxiCheatCommand", "Enables all taxi nodes.", null, null, null, 0),
    ChatCommand("cooldown", 'm', "HandleCooldownCheatCommand", "Enables no cooldown cheat.", null, null, null, 0),
    ChatCommand("casttime", 'm', "HandleCastTimeCheatCommand", "Enables no cast time cheat.", null, null, null, 0),
    ChatCommand("power", 'm', "HandlePowerCheatCommand", "Disables mana consumption etc.", null, null, null, 0),
    ChatCommand("god", 'm', "HandleGodModeCommand", "Sets god mode, prevents you from taking damage.", null, null, null, 0),
    ChatCommand("fly", 'm', "HandleFlyCommand", "Sets fly mode", null, null, null, 0),
    ChatCommand("explore", 'm', "HandleExploreCheatCommand", "Reveals the unexplored parts of the map.", null, null, null, 0),
    ChatCommand("flyspeed", 'm', "HandleFlySpeedCheatCommand", "Modifies fly speed.", null, null, null, 0),
    ChatCommand("stack", 'm', "HandleAuraStackCheatCommand", "Enables aura stacking cheat.", null, null, null, 0),
    ChatCommand("triggerpass", 'm', "HandleTriggerpassCheatCommand", "Ignores area trigger prerequisites.", null, null, null, 0),
];

/// The `.account` commands.
immutable ChatCommand[] accountCommandTable = [
    ChatCommand("level", 'z', "HandleAccountLevelCommand", "Sets gm level on account. Pass it username and 0,1,2,3,az, etc.", null, null, null, 0),
    ChatCommand("mute", 'a', "HandleAccountMuteCommand", "Mutes account for <timeperiod>.", null, null, null, 0),
    ChatCommand("unmute", 'a', "HandleAccountUnmuteCommand", "Unmutes account <x>", null, null, null, 0),
];

/// The `.honor` commands.
immutable ChatCommand[] honorCommandTable = [
    ChatCommand("addpoints", 'm', "HandleAddHonorCommand", "Adds x amount of honor points/currency", null, null, null, 0),
    ChatCommand("addkills", 'm', "HandleAddKillCommand", "Adds x amount of honor kills", null, null, null, 0),
    ChatCommand("globaldailyupdate", 'm', "HandleGlobalHonorDailyMaintenanceCommand", "Daily honor field moves", null, null, null, 0),
    ChatCommand("singledailyupdate", 'm', "HandleNextDayCommand", "Daily honor field moves for selected player only", null, null, null, 0),
    ChatCommand("pvpcredit", 'm', "HandlePVPCreditCommand", "Sends PVP credit packet, with specified rank and points", null, null, null, 0),
];

/// The `.pet` commands.
immutable ChatCommand[] petCommandTable = [
    ChatCommand("createpet", 'm', "HandleCreatePetCommand", "Creates a pet with <entry>.", null, null, null, 0),
    ChatCommand("renamepet", 'm', "HandleRenamePetCommand", "Renames a pet to <name>.", null, null, null, 0),
    ChatCommand("addspell", 'm', "HandleAddPetSpellCommand", "Teaches pet <spell>.", null, null, null, 0),
    ChatCommand("removespell", 'm', "HandleRemovePetSpellCommand", "Removes pet spell <spell>.", null, null, null, 0),
    ChatCommand("spawnbot", 'a', "HandlePetSpawnAIBot", ".pet spawnbot <type> - spawn a helper bot for your aid", null, null, null, 0),
];

/// The `.recall` commands.
immutable ChatCommand[] recallCommandTable = [
    ChatCommand("list", 'q', "HandleRecallListCommand", "List recall locations", null, null, null, 0),
    ChatCommand("port", 'q', "HandleRecallGoCommand", "Port to recalled location", null, null, null, 0),
    ChatCommand("add", 'q', "HandleRecallAddCommand", "Add recall location", null, null, null, 0),
    ChatCommand("del", 'q', "HandleRecallDelCommand", "Remove a recall location", null, null, null, 0),
    ChatCommand("portplayer", 'm', "HandleRecallPortPlayerCommand", "recall ports player", null, null, null, 0),
];

/// The `.quest` commands.
immutable ChatCommand[] questCommandTable = [
    ChatCommand("addboth", '2', "HandleQuestAddBothCommand", "Add quest <id> to the targeted NPC as start & finish", null, null, null, 0),
    ChatCommand("addfinish", '2', "HandleQuestAddFinishCommand", "Add quest <id> to the targeted NPC as finisher", null, null, null, 0),
    ChatCommand("addstart", '2', "HandleQuestAddStartCommand", "Add quest <id> to the targeted NPC as starter", null, null, null, 0),
    ChatCommand("delboth", '2', "HandleQuestDelBothCommand", "Delete quest <id> from the targeted NPC as start & finish", null, null, null, 0),
    ChatCommand("delfinish", '2', "HandleQuestDelFinishCommand", "Delete quest <id> from the targeted NPC as finisher", null, null, null, 0),
    ChatCommand("delstart", '2', "HandleQuestDelStartCommand", "Delete quest <id> from the targeted NPC as starter", null, null, null, 0),
    ChatCommand("complete", '2', "HandleQuestFinishCommand", "Complete/Finish quest <id>", null, null, null, 0),
    ChatCommand("finisher", '2', "HandleQuestFinisherCommand", "Lookup quest finisher for quest <id>", null, null, null, 0),
    ChatCommand("item", '2', "HandleQuestItemCommand", "Lookup itemid necessary for quest <id>", null, null, null, 0),
    ChatCommand("list", '2', "HandleQuestListCommand", "Lists the quests for the npc <id>", null, null, null, 0),
    ChatCommand("load", '2', "HandleQuestLoadCommand", "Reloads quest definitions and giver relationships on all workers.", null, null, null, 0),
    ChatCommand("lookup", '2', "HandleQuestLookupCommand", "Looks up quest string x", null, null, null, 0),
    ChatCommand("giver", '2', "HandleQuestGiverCommand", "Lookup quest giver for quest <id>", null, null, null, 0),
    ChatCommand("remove", '2', "HandleQuestRemoveCommand", "Removes the quest <id> from the targeted player", null, null, null, 0),
    ChatCommand("reward", '2', "HandleQuestRewardCommand", "Shows reward for quest <id>", null, null, null, 0),
    ChatCommand("status", '2', "HandleQuestStatusCommand", "Lists the status of quest <id>", null, null, null, 0),
    ChatCommand("spawn", '2', "HandleQuestSpawnCommand", "Port to spawn location for quest <id>", null, null, null, 0),
    ChatCommand("start", '2', "HandleQuestStartCommand", "Starts quest <id>", null, null, null, 0),
];

/// The `.server` commands.
immutable ChatCommand[] serverCommandTable = [
    ChatCommand("setmotd", 'm', "HandleSetMotdCommand", "Sets MOTD", null, null, null, 0),
    ChatCommand("rehash", 'z', "HandleRehashCommand", "Reloads config file.", null, null, null, 0),
    ChatCommand("reloadtable", 'm', "HandleDBReloadCommand", "Reloads some of the database tables", null, null, null, 0),
    ChatCommand("shutdown", 'z', "HandleShutdownCommand", "Initiates server shutdown in <x> seconds (5 by default).", null, null, null, 0),
    ChatCommand("restart", 'z', "HandleShutdownRestartCommand", "Initiates server restart in <x> seconds (5 by default).", null, null, null, 0),
    ChatCommand("cancelshutdown", 'z', "HandleCancelShutdownCommand", "Cancels a Server Restart/Shutdown.", null, null, null, 0),
    ChatCommand("save", 's', "HandleSaveCommand", "Save's target character", null, null, null, 0),
    ChatCommand("saveall", 's', "HandleSaveAllCommand", "Save's all playing characters", null, null, null, 0),
    ChatCommand("info", '0', "HandleInfoCommand", "Server info", null, null, null, 0),
    ChatCommand("netstatus", '0', "HandleNetworkStatusCommand", "Shows network status.", null, null, null, 0),
];

/// The `.gm` commands.
immutable ChatCommand[] gmCommandTable = [
    ChatCommand("list", '0', "HandleGMListCommand", "Shows active GM's", null, null, null, 0),
    ChatCommand("off", 't', "HandleGMOffCommand", "Sets GM tag off", null, null, null, 0),
    ChatCommand("on", 't', "HandleGMOnCommand", "Sets GM tag on", null, null, null, 0),
    ChatCommand("whisperblock", 'g', "HandleWhisperBlockCommand", "Blocks like .gmon except without the <GM> tag", null, null, null, 0),
    ChatCommand("allowwhispers", 'c', "HandleAllowWhispersCommand", "Allows whispers from player <s> while in gmon mode.", null, null, null, 0),
    ChatCommand("blockwhispers", 'c', "HandleBlockWhispersCommand", "Blocks whispers from player <s> while in gmon mode.", null, null, null, 0),
];

/// The `.character` commands.
immutable ChatCommand[] characterCommandTable = [
    ChatCommand("learn", 'm', "HandleLearnCommand", "Learns spell", null, null, null, 0),
    ChatCommand("unlearn", 'm', "HandleUnlearnCommand", "Unlearns spell", null, null, null, 0),
    ChatCommand("getskillinfo", 'm', "HandleGetSkillsInfoCommand", "Gets all the skills from a player", null, null, null, 0),
    ChatCommand("learnskill", 'm', "HandleLearnSkillCommand", ".learnskill <skillid> (optional) <value> <maxvalue> - Learns skill id skillid.", null, null, null, 0),
    ChatCommand("advanceskill", 'm', "HandleModifySkillCommand", "advanceskill <skillid> <amount, optional, default = 1> - Advances skill line x times..", null, null, null, 0),
    ChatCommand("removeskill", 'm', "HandleRemoveSkillCommand", ".removeskill <skillid> - Removes skill", null, null, null, 0),
    ChatCommand("increaseweaponskill", 'm', "HandleIncreaseWeaponSkill", ".increaseweaponskill <count> - Increase eqipped weapon skill x times (defaults to 1).", null, null, null, 0),
    ChatCommand("resetreputation", 'n', "HandleResetReputationCommand", ".resetreputation - Resets reputation to start levels. (use on characters that were made before reputation fixes.)", null, null, null, 0),
    ChatCommand("resetspells", 'n', "HandleResetSpellsCommand", ".resetspells - Resets all spells to starting spells of targeted player. DANGEROUS.", null, null, null, 0),
    ChatCommand("resettalents", 'n', "HandleResetTalentsCommand", ".resettalents - Resets all talents of targeted player to that of their current level. DANGEROUS.", null, null, null, 0),
    ChatCommand("resetskills", 'n', "HandleResetSkillsCommand", ".resetskills - Resets all skills.", null, null, null, 0),
    ChatCommand("additem", 'm', "HandleAddInvItemCommand", "Adds item x count y", null, null, null, 0),
    ChatCommand("removeitem", 'm', "HandleRemoveItemCommand", "Removes item %u count %u.", null, null, null, 0),
    ChatCommand("additemset", 'm', "HandleAddItemSetCommand", "Adds item set to inv.", null, null, null, 0),
    ChatCommand("advanceallskills", 'm', "HandleAdvanceAllSkillsCommand", "Advances all skills <x> points.", null, null, null, 0),
    ChatCommand("getstanding", 'm', "HandleGetStandingCommand", "Gets standing of faction %u.", null, null, null, 0),
    ChatCommand("setstanding", 'm', "HandleSetStandingCommand", "Sets stanging of faction %u.", null, null, null, 0),
    ChatCommand("showitems", 'm', "HandleShowItems", "Shows items of selected Player", null, null, null, 0),
    ChatCommand("showskills", 'm', "HandleShowSkills", "Shows skills of selected Player", null, null, null, 0),
    ChatCommand("showinstances", 'z', "HandleShowInstancesCommand", "Shows persistent instances of selected Player", null, null, null, 0),
    ChatCommand("rename", 'm', "HandleRenameCommand", "Renames character x to y.", null, null, null, 0),
    ChatCommand("forcerename", 'm', "HandleForceRenameCommand", "Forces character x to rename his char next login", null, null, null, 0),
    ChatCommand("repairitems", 'n', "HandleRepairItemsCommand", ".repairitems - Repair all items from selected player", null, null, null, 0),
    ChatCommand("settitle", 'm', "HandleSetTitle", "Adds title to a player", null, null, null, 0),
];

/// The `.lookup` commands.
immutable ChatCommand[] lookupCommandTable = [
    ChatCommand("item", 'l', "HandleLookupItemCommand", "Looks up item string x.", null, null, null, 0),
    ChatCommand("quest", 'l', "HandleQuestLookupCommand", "Looks up quest string x.", null, null, null, 0),
    ChatCommand("creature", 'l', "HandleLookupCreatureCommand", "Looks up item string x.", null, null, null, 0),
    ChatCommand("object", 'l', "HandleLookupObjectCommand", "Looks up gameobject string x.", null, null, null, 0),
    ChatCommand("spell", '1', "HandleLookupSpellCommand", "Looks up spell string x.", null, null, null, 0),
    ChatCommand("skill", '1', "HandleLookupSkillCommand", "Looks up skill string x.", null, null, null, 0),
    ChatCommand("faction", '1', "HandleLookupFactionCommand", "Looks up faction string x.", null, null, null, 0),
];

/// The `.admin` commands.
immutable ChatCommand[] adminCommandTable = [
    ChatCommand("castall", 'z', "HandleCastAllCommand", "Makes all players online cast spell <x>.", null, null, null, 0),
    ChatCommand("dispelall", 'z', "HandleDispelAllCommand", "Dispels all negative (or positive w/ 1) auras on all players.", null, null, null, 0),
    ChatCommand("renameallinvalidchars", 'z', "HandleRenameAllCharacter", "Renames all invalid character names", null, null, null, 0),
    ChatCommand("masssummon", 'z', "HandleMassSummonCommand", ".masssummon - Summons all players.", null, null, null, 0),
    ChatCommand("playall", 'z', "HandleGlobalPlaySoundCommand", "Plays a sound to the entire server.", null, null, null, 0),
];

/// The `.kick` commands.
immutable ChatCommand[] kickCommandTable = [
    ChatCommand("byplayer", 'f', "HandleKillByPlayerCommand", "Disconnects the player with name <s>.", null, null, null, 0),
    ChatCommand("byaccount", 'f', "HandleKillBySessionCommand", "Disconnects the session with account name <s>.", null, null, null, 0),
    ChatCommand("byip", 'f', "HandleKillByIPCommand", "Disconnects the session with the ip <s>.", null, null, null, 0),
];

/// The `.ban` commands.
immutable ChatCommand[] banCommandTable = [
    ChatCommand("ip", 'm', "HandleIPBanCommand", "Adds an address to the IP ban table: <address> [duration]\nDuration must be a number optionally followed by a character representing the calendar subdivision to use (h>hours, d>days, w>weeks, m>months, y>years, default minutes)\nLack of duration results in a permanent ban.", null, null, null, 0),
    ChatCommand("character", 'b', "HandleBanCharacterCommand", "Bans character x with or without reason", null, null, null, 0),
    ChatCommand("account", 'a', "HandleAccountBannedCommand", "Ban account. .account ban name timeperiod", null, null, null, 0),
];

/// The `.unban` commands.
immutable ChatCommand[] unbanCommandTable = [
    ChatCommand("ip", 'm', "HandleIPUnBanCommand", "Deletes an address from the IP ban table: <address>", null, null, null, 0),
    ChatCommand("character", 'b', "HandleUnBanCharacterCommand", "Unbans character x", null, null, null, 0),
    ChatCommand("account", 'z', "HandleAccountUnbanCommand", "Unbans account x.", null, null, null, 0),
];

/// The `.instance` commands.
immutable ChatCommand[] instanceCommandTable = [
    ChatCommand("reset", 'z', "HandleResetInstanceCommand", "Removes instance ID x from target player.", null, null, null, 0),
    ChatCommand("resetall", 'm', "HandleResetAllInstancesCommand", "Removes all instance IDs from target player.", null, null, null, 0),
    ChatCommand("shutdown", 'z', "HandleShutdownInstanceCommand", "Shutdown instance with ID x (default is current instance).", null, null, null, 0),
    ChatCommand("info", 'm', "HandleGetInstanceInfoCommand", "Gets info about instance with ID x (default is current instance).", null, null, null, 0),
    ChatCommand("exit", 'm', "HandleExitInstanceCommand", "Exits current instance, return to entry point.", null, null, null, 0),
];

/// The `.arena` commands.
immutable ChatCommand[] arenaCommandTable = [
    ChatCommand("createteam", 'e', "HandleArenaCreateTeamCommand", "Creates arena team", null, null, null, 0),
    ChatCommand("setteamleader", 'e', "HandleArenaSetTeamLeaderCommand", "Sets the arena team leader", null, null, null, 0),
    ChatCommand("resetallratings", 'z', "HandleArenaResetAllRatingsCommand", "Resets all area teams to their default rating", null, null, null, 0),
];

immutable ChatCommand[] travelCommandTable = [
    ChatCommand("coords", 'v', "HandleWorldPortCommand", "Usage: .travel coords <map> <x> <y> <z>", null, null, null, 0),
    ChatCommand("player", 'v', "HandleAppearCommand", "Usage: .travel player <name>", null, null, null, 0),
    ChatCommand("summon", 'v', "HandleSummonCommand", "Usage: .travel summon <name>", null, null, null, 0),
];

immutable ChatCommand[] accessCommandTable = [
    ChatCommand("whoami", '0', "HandleGmAccessInfoCommand", "Shows your active staff roles and capabilities.", null, null, null, 0),
    ChatCommand("grant", 'z', "HandleGmAccessGrantCommand", "Usage: .access grant <account> <role>", null, null, null, 0),
    ChatCommand("revoke", 'z', "HandleGmAccessRevokeCommand", "Usage: .access revoke <account> <role>", null, null, null, 0),
];

/// The top-level commands, in lookup order; a group's row points to its sub-table.
immutable ChatCommand[] commandTable = [
    ChatCommand("commands", '0', "HandleCommandsCommand", "Shows Commands", null, null, null, 0),
    ChatCommand("help", '0', "HandleHelpCommand", "Shows help for command", null, null, null, 0),
    ChatCommand("announce", 'u', "HandleAnnounceCommand", "Sends Msg To All", null, null, null, 0),
    ChatCommand("wannounce", 'u', "HandleWAnnounceCommand", "Sends Widescreen Msg To All", null, null, null, 0),
    ChatCommand("appear", 'v', "HandleAppearCommand", "Teleports to x's position.", null, null, null, 0),
    ChatCommand("summon", 'v', "HandleSummonCommand", "Summons x to your position", null, null, null, 0),
    ChatCommand("kill", 'r', "HandleKillCommand", ".kill - Kills selected unit.", null, null, null, 0),
    ChatCommand("killplr", 'r', "HandleKillByPlrCommand", ".killplr <name> - Kills specified player", null, null, null, 0),
    ChatCommand("revive", 'r', "HandleReviveCommand", "Revives you.", null, null, null, 0),
    ChatCommand("reviveplr", 'r', "HandleReviveStringcommand", "Revives player specified.", null, null, null, 0),
    ChatCommand("demorph", 'm', "HandleDeMorphCommand", "Demorphs from morphed model.", null, null, null, 0),
    ChatCommand("mount", 'm', "HandleMountCommand", "Mounts into modelid x.", null, null, null, 0),
    ChatCommand("dismount", 'h', "HandleDismountCommand", "Dismounts.", null, null, null, 0),
    ChatCommand("gps", '0', "HandleGPSCommand", "Shows Position", null, null, null, 0),
    ChatCommand("scourge", 'z', "HandleScourgeCommand", ".scourge start|stop|status", null, null, null, 0),
    ChatCommand("worldport", 'v', "HandleWorldPortCommand", "", null, null, null, 0),
    ChatCommand("start", 'm', "HandleStartCommand", "Teleport's you to a starting location", null, null, null, 0),
    ChatCommand("invincible", 'j', "HandleInvincibleCommand", ".invincible - Toggles INVINCIBILITY (mobs won't attack you)", null, null, null, 0),
    ChatCommand("invisible", 'i', "HandleInvisibleCommand", ".invisible - Toggles INVINCIBILITY and INVISIBILITY (mobs won't attack you and nobody can see you, but they can see your chat messages)", null, null, null, 0),
    ChatCommand("playerinfo", 'm', "HandlePlayerInfo", ".playerinfo - Displays informations about the selected character (account...)", null, null, null, 0),
    ChatCommand("levelup", 'm', "HandleLevelUpCommand", "Levelup x lvls", null, null, null, 0),
    ChatCommand("modify", 'm', null, "", modifyCommandTable, null, null, 0),
    ChatCommand("waypoint", 'w', null, "", waypointCommandTable, null, null, 0),
    ChatCommand("debug", 'd', null, "", debugCommandTable, null, null, 0),
    ChatCommand("gm", '0', null, "", gmCommandTable, null, null, 0),
    ChatCommand("gmTicket", 'c', null, "", gMTicketCommandTable, null, null, 0),
    ChatCommand("gobject", 'o', null, "", gameObjectCommandTable, null, null, 0),
    ChatCommand("battleground", 'e', null, "", battlegroundCommandTable, null, null, 0),
    ChatCommand("npc", 'n', null, "", nPCCommandTable, null, null, 0),
    ChatCommand("cheat", 'm', null, "", cheatCommandTable, null, null, 0),
    ChatCommand("account", 'a', null, "", accountCommandTable, null, null, 0),
    ChatCommand("honor", 'm', null, "", honorCommandTable, null, null, 0),
    ChatCommand("quest", 'q', null, "", questCommandTable, null, null, 0),
    ChatCommand("pet", 'm', null, "", petCommandTable, null, null, 0),
    ChatCommand("recall", 'q', null, "", recallCommandTable, null, null, 0),
    ChatCommand("guild", 'm', null, "", guildCommandTable, null, null, 0),
    ChatCommand("server", '0', null, "", serverCommandTable, null, null, 0),
    ChatCommand("character", '0', null, "", characterCommandTable, null, null, 0),
    ChatCommand("lookup", 'l', null, "", lookupCommandTable, null, null, 0),
    ChatCommand("admin", 'z', null, "", adminCommandTable, null, null, 0),
    ChatCommand("kick", 'm', null, "", kickCommandTable, null, null, 0),
    ChatCommand("ban", 'm', null, "", banCommandTable, null, null, 0),
    ChatCommand("unban", 'm', null, "", unbanCommandTable, null, null, 0),
    ChatCommand("instance", 'm', null, "", instanceCommandTable, null, null, 0),
    ChatCommand("arena", 'e', null, "", arenaCommandTable, null, null, 0),
    ChatCommand("kickplayer", 'b', "HandleKickCommand", "Kicks player from server", null, null, null, 0),
    ChatCommand("gmannounce", 'u', "HandleGMAnnounceCommand", "Sends Msg to all online GMs", null, null, null, 0),
    ChatCommand("clearcooldowns", 'm', "HandleClearCooldownsCommand", "Clears all cooldowns for your class.", null, null, null, 0),
    ChatCommand("removeauras", 'm', "HandleRemoveAurasCommand", "Removes all auras from target", null, null, null, 0),
    ChatCommand("paralyze", 'b', "HandleParalyzeCommand", "Roots/Paralyzes the target.", null, null, null, 0),
    ChatCommand("unparalyze", 'b', "HandleUnParalyzeCommand", "Unroots/Unparalyzes the target.", null, null, null, 0),
    ChatCommand("gotrig", 'v', "HandleTriggerCommand", "Warps to areatrigger <id>", null, null, null, 0),
    ChatCommand("modperiod", 'm', "HandleModPeriodCommand", "Changes period of current transporter.", null, null, null, 0),
    ChatCommand("logcomment", '1', "HandleGmLogCommentCommand", "Adds a comment to the GM log for the admins to read.", null, null, null, 0),
    ChatCommand("removesickness", 'm', "HandleRemoveRessurectionSickessAuraCommand", "Removes ressurrection sickness from the target", null, null, null, 0),
    ChatCommand("fixscale", 'm', "HandleFixScaleCommand", "", null, null, null, 0),
    ChatCommand("addtrainerspell", 'm', "HandleAddTrainerSpellCommand", ".addtrainerspell <teaching-spell-id> [cost-in-copper] [required-level]", null, null, null, 0),
    ChatCommand("travel", 'v', null, "", travelCommandTable, null, null, 0),
    ChatCommand("access", '0', null, "", accessCommandTable, null, null, 0),
    ChatCommand("learn", 'm', "HandleLearnCommand", "Usage: .learn <spell-id|all>", null, null, null, 0),
];
