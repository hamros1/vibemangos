# Provenance

Where the behaviour of each module was taken from. The modules describe what they do; this index
records, per module, the external projects and the functions, files and constants of theirs that
its implementation reproduces, as its comments named them before they were rewritten (2026-11-18).
Use it to check behaviour against the reference implementations. Licences: NOTICE.md.

Functions and files are CMaNGOS-classic's (`src/game`) unless the module is one of the GM command
modules, whose names are ArcEmu 2.4.3's (`arcemu-world`).

## auth/accounts.d

* Projects: CMaNGOS
* Constants: `MAX_ACCOUNT_STR`

## auth/config.d

* Projects: CMaNGOS

## auth/database.d

* Projects: CMaNGOS

## auth/main.d

* Projects: CMaNGOS

## auth/mysqldb.d

* Projects: CMaNGOS
* Files: `AccountMgr.cpp`, `AuthSocket.cpp`, `RealmList.cpp`
* Functions: `AccountMgr::CreateAccount`
* Constants: `LOGIN_TYPE_REALMD`

## auth/protocol.d

* Projects: CMaNGOS, Ember
* Files: `AuthSocket.cpp`

## auth/realms.d

* Projects: CMaNGOS
* Files: `RealmList.cpp`
* Functions: `AuthSocket::LoadRealmlist`

## auth/session.d

* Projects: CMaNGOS
* Files: `AuthSocket.cpp`

## cluster/protocol.d

* Projects: ArcEmu
* Functions: `Group::RewardGroupAtKill`
* Constants: `CMSG_REQUEST_PARTY_MEMBER_STATS`, `SMSG_TRANSFER_ABORTED`

## crypto/srp6.d

* Projects: CMaNGOS, Ember
* Files: `SRP6.cpp`
* Functions: `AccountMgr::normalizeString`

## dbc.d

* Projects: CMaNGOS, mangosd
* Files: `DBCfmt.h`
* Constants: `WDBC`

## extractor/assembler.d

* Projects: CMaNGOS
* Files: `TileAssembler.cpp`
* Functions: `TileAssembler::convertWorld2`, `TileAssembler::exportGameobjectModels`, `TileAssembler::readMapSpawns`

## extractor/dbc.d

* Projects: CMaNGOS, mangosd
* Files: `System.cpp`

## extractor/main.d

* Projects: CMaNGOS, mangosd
* Constants: `OUTPUT`

## extractor/maps.d

* Projects: CMaNGOS
* Files: `System.cpp`
* Functions: `FileLoader::prepareLoadedData`, `MAIN::adt_list`, `MCIN::getMCNK`, `WDT_file::prepareLoadedData`
* Constants: `ADT_CELLS_PER_GRID`, `ADT_CELL_SIZE`, `FILE_FORMAT_VERSION`, `MCLQ`, `MCNK`, `WDT_MAP_SIZE`

## extractor/mmaps.d

* Projects: CMaNGOS, Detour, Recast
* Functions: `MapBuilder::buildMoveMapTile`, `MapBuilder::getGridBounds`, `TerrainBuilder::getHeightTriangle`, `TerrainBuilder::loadMap`
* Constants: `MMAP_MAGIC`

## extractor/vmaps.d

* Projects: CMaNGOS
* Functions: `ADT::MODF`, `ADTFile::init`, `Doodad::ExtractSet`, `Model::ConvertToVMAPModel`, `ModelInstance::ModelInstance`, `WDTFile::init`, `WMO::MODD`, `WMO::MODS`, `WMOGroup::ConvertToVMAPGroupWmo`, `WMOGroup::ShouldSkip`, `WMOGroup::open`, `WMOInstance::WMOInstance`

## mapfile.d

* Projects: CMaNGOS
* Files: `GridMapDefines.h`
* Constants: `MAP_AREA_NO_AREA`, `MAP_HEIGHT_AS_INT16`, `MAP_HEIGHT_AS_INT8`, `MAP_HEIGHT_NO_HEIGHT`, `MAP_LIQUID_NO_HEIGHT`, `MAP_LIQUID_NO_TYPE`

## mpq/archive.d

* Projects: Blizzard

## mpq/crypt.d

* Projects: Blizzard

## mpq/explode.d

* Projects: blast.c

## mysql/connection.d

* Projects: CMaNGOS

## navigation.d

* Projects: CMaNGOS, Detour, Recast
* Functions: `MapBuilder::buildMoveMapTile`
* Constants: `BASE_UNIT_DIM`, `SIZE_OF_GRIDS`

## net/server.d

* Projects: Ember

## script/escort.d

* Projects: CMaNGOS
* Constants: `DEFAULT_MAX_PLAYER_DISTANCE`

## scripts/gnomeregan.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/gnomeregan/instance_gnomeregan.cpp`, `gnomeregan.cpp`, `boss_thermaplugg.cpp`, `gnomeregan.h`
* Functions/ScriptNames: `instance_gnomeregan` (`DoActivateBombFace`, `DoDeactivateBombFace`), `npc_blastmaster_emi_shortfuse`, `npc_kernobee`, `boss_thermaplugg`, `go_gnomeface_button`

## scripts/razorfendowns.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/razorfen_downs/instance_razorfen_downs.cpp`, `razorfen_downs.cpp`, `razorfen_downs.h`
* Functions/ScriptNames: `instance_razorfen_downs` (`DoSpawnWaveIfCan`, `OnCreatureDeath`), `event_go_tutenkash_gong`, `npc_belnistrasz`

## scripts/razorfenkraul.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/razorfen_kraul/instance_razorfen_kraul.cpp`, `razorfen_kraul.cpp`, `razorfen_kraul.h`
* Functions/ScriptNames: `instance_razorfen_kraul`, `npc_willix_the_importer`

## scripts/scarletmonastery.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/scarlet_monastery/instance_scarlet_monastery.cpp`, `boss_mograine_and_whitemane.cpp`, `boss_herod.cpp`, `boss_arcanist_doan.cpp`, `scarlet_monastery.h`
* Functions/ScriptNames: `instance_scarlet_monastery`, `boss_scarlet_commander_mograine`, `boss_high_inquisitor_whitemane`, `boss_herod`, `mob_scarlet_trainee`, `boss_arcanist_doan`

## scripts/uldaman.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/uldaman/instance_uldaman.cpp`, `boss_archaedas.cpp`, `uldaman.h`
* Functions/ScriptNames: `instance_uldaman` (`StartEvent`, `Update`, `GetClosestDwarfNotInCombat`), `event_spell_altar_boss_aggro`, `boss_archaedas`, `spell_awaken_vault_warder`, `spell_awaken_earthen_archaedas`

## scripts/zulfarrak.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/zulfarrak/instance_zulfarrak.cpp`, `zulfarrak.cpp`, `boss_zumrah.cpp`, `zulfarrak.h`
* Functions/ScriptNames: `instance_zulfarrak` (`Update`, `OnCreatureEnterCombat`, `OnCreatureEvade`), `event_go_zulfarrak_gong`, `event_spell_unlocking`, `at_zulfarrak`, `boss_zumrah`

## timer.d

* Projects: CMaNGOS, Ember

## vmap/bih.d

* Projects: CMaNGOS
* Files: `BIH.cpp`, `BIH.h`
* Functions: `BIH::build`, `BIH::intersectPoint`, `BIH::intersectRay`, `BIH::readFromFile`, `BIH::subdivide`, `BIH::writeToFile`
* Constants: `MAX_STACK_SIZE`

## vmap/maptree.d

* Projects: CMaNGOS
* Files: `MapTree.cpp`, `ModelInstance.cpp`, `VMapManager2.cpp`
* Functions: `ModelInstance::GetLiquidLevel`, `ModelInstance::intersectPoint`, `ModelInstance::intersectRay`, `StaticMapTree::CanLoadMap`, `StaticMapTree::InitMap`, `StaticMapTree::IsTileLoaded`, `StaticMapTree::LoadMapTile`, `StaticMapTree::getAreaInfo`, `StaticMapTree::getHeight`, `StaticMapTree::getIntersectionTime`, `StaticMapTree::getTileFileName`, `StaticMapTree::isInLineOfSight`, `StaticMapTree::packTileID`, `VMapManager2::GetLiquidLevel`, `VMapManager2::acquireModelInstance`, `VMapManager2::convertPositionToInternalRep`, `VMapManager2::existsMap`
* Constants: `VMAP_INVALID_HEIGHT_VALUE`

## vmap/math.d

* Projects: CMaNGOS, G3D
* Functions: `AABox::contains`, `AABox::merge`, `CollisionDetection::collisionLocationForMovingPointFixedAABox`, `G3D::AABox`, `G3D::Matrix3`, `G3D::Ray`, `G3D::Vector3`, `G3D::aSin`, `G3D::eps`, `G3D::fuzzyEpsilon`, `G3D::fuzzyEq`, `G3D::fuzzyNe`, `Matrix3::fromEulerAnglesZYX`, `Matrix3::inverse`, `Matrix3::toEulerAnglesXYZ`, `Quat::unitize`, `Ray::intersectionTime`, `Vector3::magnitude`, `Vector3::primaryAxis`

## vmap/model.d

* Projects: CMaNGOS
* Files: `ModelInstance.cpp`, `ModelInstance.h`, `VMapDefinitions.h`, `WorldModel.cpp`, `WorldModel.h`
* Functions: `GroupModel::GetLiquidLevel`, `GroupModel::GetLiquidType`, `GroupModel::IntersectRay`, `GroupModel::IsInsideObject`, `GroupModel::readFromFile`, `GroupModel::setMeshData`, `GroupModel::writeToFile`, `ModelSpawn::readFromFile`, `ModelSpawn::writeToFile`, `WmoLiquid::GetFileSize`, `WmoLiquid::GetLiquidHeight`, `WmoLiquid::readFromFile`, `WmoLiquid::writeToFile`, `WorldModel::IntersectPoint`, `WorldModel::IntersectRay`, `WorldModel::readFile`, `WorldModel::setGroupModels`, `WorldModel::writeFile`
* Constants: `GAMEOBJECT_MODELS`, `LIQUID_TILE_SIZE`, `MOD_M2`, `RAW_VMAP_MAGIC`, `VMAP_MAGIC`

## world/addons.d

* Projects: Blizzard, CMaNGOS
* Constants: `CMSG_AUTH_SESSION`, `SMSG_ADDON_INFO`

## world/auctionhandlers.d

* Projects: CMaNGOS
* Files: `AuctionHouseHandler.cpp`

## world/auctionhouse.d

* Projects: CMaNGOS
* Files: `AuctionHouseMgr.cpp`
* Functions: `AuctionHouseMgr::GetAuctionHouseEntry`
* Constants: `MAX_AUCTION_ITEMS_CLIENT_UI_PAGE`, `MIN_AUCTION_TIME`, `SMSG_AUCTION_BIDDER_NOTIFICATION`, `SMSG_AUCTION_OWNER_NOTIFICATION`, `SMSG_AUCTION_REMOVED_NOTIFICATION`

## world/aurahandlers.d

* Projects: CMaNGOS
* Files: `SpellAuras.cpp`
* Functions: `Aura::PeriodicTick`, `Player::_LoadAuras`, `Player::_SaveAuras`, `Spell::EffectApplyAura`, `SpellAuraHolder::Update`, `Unit::DispelAll`
* Constants: `MOD_POWER_REGEN`, `SMSG_PERIODICAURALOG`, `SMSG_UPDATE_AURA_DURATION`, `SPELLMOD_DOT`, `SPELL_EFFECT_APPLY_AURA`

## world/auras.d

* Projects: CMaNGOS
* Files: `SpellAuras.cpp`
* Functions: `SpellAuraHolder::Update`, `Unit::AddSpellAuraHolder`
* Constants: `MAX_AURAS`, `MAX_POSITIVE_AURAS`, `SPELL_ATTR_NO_AURA_CANCEL`, `UNIT_FIELD_AURA`

## world/battleground.d

* Projects: ArcEmu, CMaNGOS, MaNGOS
* Files: `BattleGroundHandler.cpp`
* Functions: `BattleGround::AddPlayer`, `BattleGround::EndBattleGround`, `BattleGround::EventPlayerLoggedOut`, `BattleGround::HandleKillPlayer`, `BattleGround::RemovePlayerAtLeave`, `BattleGround::SendMessageToAll`, `BattleGround::Update`, `BattleGroundMap::Update`, `BattleGroundMgr::BuildPvpLogDataPacket`, `BattleGroundMgr::SendBattleGroundList`, `BattleGroundMgr::SendToBattleGround`, `BattleGroundMgr::ToggleTesting`, `CBattleground::Close`, `Creature::CanInteractWithBattleMaster`, `Group::CanJoinBattleGroundQueue`, `MaNGOS::Honor`, `Player::CanJoinToBattleground`, `Player::LeaveBattleground`, `Player::LoadFromDB`, `Player::TeleportToBGEntryPoint`, `Player::_LoadBGData`, `Player::_SaveBGData`, `WorldSession::LogoutPlayer`
* Constants: `BG_EVENT_DOOR`, `BG_EVENT_NONE`, `CHAT_MSG_BATTLEGROUND`, `CMSG_AREA_SPIRIT_HEALER_QUEUE`, `CMSG_BATTLEFIELD_PORT`, `MAX_OFFLINE_TIME`, `MSG_BATTLEGROUND_PLAYER_POSITIONS`, `MSG_PVP_LOG_DATA`, `SMSG_AREA_SPIRIT_HEALER_TIME`, `SMSG_GROUP_JOINED_BATTLEGROUND`, `SMSG_INIT_WORLD_STATES`, `SMSG_MESSAGECHAT`, `SOUND_BG_START`, `SPELL_ID_BATTLEGROUND_DESERTER`, `TEAM_INVALID`, `TIME_TO_AUTOREMOVE`

## world/bgqueue.d

* Projects: ArcEmu, CMaNGOS
* Files: `BattleGroundHandler.cpp`
* Functions: `BattleGround::RemovePlayerAtLeave`, `BattleGroundMgr::BuildBattleGroundStatusPacket`, `BattleGroundMgr::GetBattleGroundBracketIdFromLevel`, `BattleGroundMgr::ToggleTesting`, `BattleGroundQueue::BuildBattleGroundListPacket`, `BattleGroundQueue::GetAverageQueueWaitTime`, `BattleGroundQueueItem::Update`, `WorldSession::LogoutPlayer`
* Constants: `CMSG_BATTLEFIELD_PORT`, `CMSG_LEAVE_BATTLEFIELD`, `COUNT_OF_PLAYERS_TO_AVERAGE_WAIT_TIME`, `INVITATION_REMIND_TIME`, `INVITE_ACCEPT_WAIT_TIME`, `MAX_BATTLEGROUND_BRACKETS`, `PLAYER_MAX_BATTLEGROUND_QUEUES`, `SMSG_BATTLEFIELD_LIST`, `SMSG_BATTLEFIELD_STATUS`, `SMSG_GROUP_JOINED_BATTLEGROUND`

## world/channel.d

* Projects: ArcEmu, CMaNGOS, mangosd
* Files: `Channel.cpp`, `ChannelMgr.cpp`
* Functions: `Channel::AttemptJoin`, `Channel::ChannelDBCFlags`, `Channel::ChannelFlags`, `Channel::ChannelMemberFlags`, `Channel::Invite`, `Channel::Join`, `Channel::KickOrBan`, `Channel::Leave`, `Channel::Moderate`, `Channel::Say`, `Channel::SendChannelListResponse`, `Channel::SendChannelOwnerResponse`, `Channel::SetModeFlags`, `Channel::SetOwner`, `Channel::SetPassword`, `Channel::ToggleAnnouncements`, `Channel::ToggleModeration`, `Channel::UnBan`, `ChannelMgr::GetChannel`, `ChannelMgr::GetJoinChannel`, `ChannelMgr::LeftChannel`, `Player::CleanupChannels`, `Player::GetTeam`, `Player::UpdateLocalChannels`
* Constants: `SMSG_CHANNEL_NOTIFY`, `SPEAK_IN_LOCALDEFENSE_RANK`, `SPEAK_IN_WORLDDEFENSE_RANK`

## world/channelhandlers.d

* Projects: ArcEmu, CMaNGOS
* Files: `ChannelHandler.cpp`
* Functions: `WorldSession::CheckChatChannelNameAndPassword`

## world/character.d

* Projects: ArcEmu
* Functions: `Player::CooldownCheat`, `Player::LeaveBattleground`, `Player::TriggerpassCheat`, `Player::UpdateGroupLeaderFlag`, `Player::m_teleport_dest`, `Player::m_zoneUpdateTimer`, `WorldSession::CanUseCommand`, `WorldSession::GetPermissionCount`, `WorldSession::HasGMPermissions`, `WorldSession::LogoutPlayer`, `WorldSession::SendNotification`, `WorldSession::floodLines`, `WorldSession::permissions`
* Constants: `MSG_MOVE_WORLDPORT_ACK`, `PLAYER_GUILDID`, `SMSG_NEW_WORLD`

## world/characterdb.d

* Projects: CMaNGOS
* Functions: `AuctionHouseMgr::RemovePlayerAuctions`, `Group::Create`, `Group::Disband`, `Group::LoadGroupFromDB`, `Group::RemoveMember`, `Group::_addMember`, `Group::_removeMember`, `Group::_setAssistantFlag`, `Guild::DelMember`, `GuildMgr::GetGuildByLeader`, `MailDraft::SendMailTo`, `MailDraft::SendReturnToSender`, `ObjectMgr::GetPlayerGuidByName`, `ObjectMgr::LoadGroups`, `ObjectMgr::SetHighestGuids`, `Pet::DeleteFromDB`, `Player::DeleteFromDB`, `Player::LoadFromDB`, `Player::RemovePetitionsAndSigns`, `Player::SaveToDB`, `Player::SetHomebindToLocation`, `Player::_SaveActions`, `Player::_SaveSkills`, `Player::_SaveSpells`, `World::UpdateRealmCharCount`, `WorldSession::SaveTutorialsData`
* Constants: `SMSG_NAME_QUERY_RESPONSE`

## world/characters.d

* Projects: CMaNGOS
* Functions: `Player::BuildEnumData`
* Constants: `HIGHGUID_PLAYER`

## world/charscreen.d

* Projects: ArcEmu, CMaNGOS
* Files: `CharacterHandler.cpp`
* Functions: `Map::Add`, `Player::Create`, `Player::DeleteFromDB`, `Player::LoadFromDB`, `Player::LoadPet`, `Player::SendInitialPacketsAfterAddToMap`, `Player::SendInitialPacketsBeforeAddToMap`, `Player::_LoadHomeBind`, `WorldSession::HandleCharCreateOpcode`, `WorldSession::HandlePlayerLogin`, `WorldSession::SendMotd`
* Constants: `SMSG_CHAR_CREATE`, `SMSG_LOGIN_SETTIMESPEED`, `SMSG_LOGIN_VERIFY_WORLD`

## world/clientdata.d

* Projects: CMaNGOS, mangosd
* Files: `DBCStores.cpp`, `DBCStructure.h`, `DBCfmt.h`, `SpellMgr.cpp`
* Functions: `MapEntry::IsBattleGround`, `MapEntry::IsContinent`, `MapEntry::IsDungeon`, `MapEntry::IsRaid`, `MapManager::IsValidMapCoord`, `Player::InitDisplayIds`, `Player::TeamForRace`
* Constants: `CLASSMASK_ALL_PLAYABLE`, `MAX_OUTFIT_ITEMS`, `MAX_SKILL_STEP`, `MAX_TALENT_RANK`, `RACEMASK_ALL_PLAYABLE`, `SECTION_FLAG_UNAVAILABLE`, `SKILL_FLAG_MAXIMIZED`

## world/combat.d

* Projects: CMaNGOS
* Files: `Unit.cpp`
* Functions: `Player::RewardRage`, `Unit::CalculateEffectiveMagicResistancePercent`, `Unit::RollMagicResistanceMultiplierOutcomeAgainst`, `WorldObject::HasInArc`
* Constants: `ATTACK_DISPLAY_DELAY`, `ATTACK_DISTANCE`, `BASE_MELEERANGE_OFFSET`, `CLASSMASK_WAND_USERS`, `CONFIG_UINT32_WORLD_BOSS_LEVEL_DIFF`, `MELEE_LEEWAY`, `SMSG_ATTACKERSTATEUPDATE`, `SMSG_ATTACKSTART`, `SMSG_ATTACKSTOP`, `SPELL_PARTIAL_RESIST_DISTRIBUTION`, `TYPEID_PLAYER`, `UNIT_FIELD_COMBATREACH`, `UNIT_FIELD_MINDAMAGE`, `UNIT_FLAG_PLAYER_CONTROLLED`

## world/combathandlers.d

* Projects: CMaNGOS
* Files: `CombatHandler.cpp`
* Functions: `BattleGround::HandleKillPlayer`, `Player::CastItemCombatSpell`, `Player::Update`, `Player::UpdateCombatSkills`, `Unit::Attack`, `Unit::AttackStop`, `Unit::DealDamage`, `Unit::Kill`, `Unit::Update`
* Constants: `CMSG_ATTACKSTOP`, `CMSG_ATTACKSWING`, `CMSG_SETSHEATHED`, `SMSG_ATTACKSTOP`, `SMSG_CANCEL_COMBAT`, `UNIT_FLAG_IN_COMBAT`, `UNIT_STAT_MELEE_ATTACKING`

## world/commands.d

* Projects: ArcEmu, CMaNGOS
* Files: `BattlegroundCommands.cpp`, `Chat.cpp`, `Chat.h`, `Common.h`, `Level0.cpp`, `Level3.cpp`, `RecallCommands.cpp`, `Util.cpp`
* Functions: `ChatHandler::BlueSystemMessage`, `ChatHandler::CmdSetValueField`, `ChatHandler::ColorSystemMessage`, `ChatHandler::ExecuteCommandInTable`, `ChatHandler::GreenSystemMessage`, `ChatHandler::HandleNYICommand`, `ChatHandler::ParseCommands`, `ChatHandler::RedSystemMessage`, `ChatHandler::SendMultilineMessage`, `ChatHandler::SystemMessage`, `ChatHandler::getSelectedChar`, `ChatHandler::getSelectedCreature`, `ChatHandler::hasStringAbbr`, `CommandTableStorage::Override`, `WorldSession::CanUseCommand`, `WorldSession::HasGMPermissions`, `WorldSession::LoadSecurity`

## world/commandtable.d

* Projects: ArcEmu
* Files: `Chat.cpp`
* Functions: `CommandTableStorage::Init`

## world/conditions.d

* Projects: CMaNGOS
* Files: `Conditions.cpp`
* Functions: `ConditionEntry::Meets`, `ObjectMgr::IsConditionSatisfied`
* Constants: `CONDITION_LEARNABLE_ABILITY`, `CONDITION_PVP_RANK`

## world/config.d

* Projects: ArcEmu, CMaNGOS, mangosd
* Functions: `WorldSession::LoadSecurity`
* Constants: `WORLD_SLEEP_CONST`

## world/context.d

* Projects: ArcEmu, EventAI
* Functions: `AuctionHouseObject::Update`, `BattleGroundMap::CanEnter`, `CommandTableStorage::Load`, `Creature::Create`, `Creature::Despawn`, `Creature::SaveRespawnTime`, `Creature::Update`, `DungeonMap::Add`, `GameObject::SaveRespawnTime`, `GameObject::Update`, `GameObject::Use`, `InstanceMap::UnloadAll`, `InstanceSaveManager::LoadFromDB`, `MailDraft::SendMailTo`, `Map::Instanceable`, `Map::Update`, `MapManager::CanPlayerEnter`, `MapManager::CreateInstance`, `MapMgr::InstanceShutdown`, `ObjectMgr::ReturnOrDeleteOldMails`, `Pet::Create`, `Player::GetBoundInstance`, `Player::Update`, `TerrainManager::LoadTerrain`, `WeatherSystem::FindOrCreateWeather`, `WeatherSystem::UpdateWeathers`, `World::SendGlobalMessage`, `World::ShutdownMsg`, `World::ShutdownServ`, `World::Update`, `World::m_StartTime`, `WorldObject::SummonCreature`
* Constants: `DEAD`, `GAMEOBJECT_TYPE_TRAP`, `SMSG_TRANSFER_ABORTED`, `SMSG_WEATHER`, `WUPDATE_AUCTIONS`

## world/corpse.d

* Projects: CMaNGOS
* Files: `Corpse.cpp`
* Functions: `Corpse::Create`, `Player::CreateCorpse`
* Constants: `CORPSE_RECLAIM_RADIUS`, `HIGHGUID_CORPSE`

## world/creature.d

* Projects: CMaNGOS, mangosd
* Files: `Creature.cpp`
* Functions: `Creature::ChooseDisplayId`, `Creature::Create`, `Creature::GetVendorItemCurrentCount`, `Creature::InspectingLoot`, `Creature::IsTappedBy`, `Creature::SelectLevel`, `Creature::SetDeathState`, `Creature::SetLootRecipient`, `Creature::Update`, `Creature::UpdateDamagePhysical`, `Creature::UpdateVendorItemCurrentCount`, `Creature::m_vendorItemCounts`, `Object::BuildCreateUpdateBlockForPlayer`, `Object::BuildValuesUpdate`, `Pet::Create`, `TemporarySpawn::Update`, `Unit::DealDamage`, `Unit::GetCollisionHeight`, `Unit::Kill`, `Unit::SetPowerType`, `Unit::m_attackers`
* Constants: `DEFAULT_COLLISION_HEIGHT`, `FACTION_TEMPLATE_FLAG_ASSIST_PLAYERS`, `HIGHGUID_PET`, `NO_LOOT`, `NO_XP`, `PLAYER_FLAGS`, `UNIT_DYNFLAG_LOOTABLE`, `UNIT_DYNFLAG_TAPPED`, `UNIT_MOD_DAMAGE_OFFHAND`

## world/creatureai.d

* Projects: CMaNGOS, mangosd
* Files: `CombatManager.cpp`, `CreatureAI.cpp`, `ThreatManager.cpp`, `UnitAI.cpp`
* Functions: `CombatManager::IsEvadingHome`, `CombatManager::IsInEvadeMode`, `CombatManager::StartEvadeTimer`, `CombatManager::TriggerCombatTimer`, `CombatManager::Update`, `CombatManager::m_combatTimer`, `CombatManager::m_evadeTimer`, `Creature::CallAssistance`, `Creature::RegenerateAll`, `Creature::Update`, `FactionTemplateEntry::IsNeutralToAll`, `HomeMovementGenerator::Finalize`, `ThreatContainer::selectNextVictim`, `ThreatManager::addThreat`, `Unit::Attack`, `Unit::EvadeTimerExpired`, `Unit::GetAttackDistance`, `Unit::SelectHostileTarget`, `UnitAI::AttackStart`, `UnitAI::AttackedBy`, `UnitAI::CheckForHelp`, `UnitAI::EnterEvadeMode`, `UnitAI::MoveInLineOfSight`, `UnitAI::UpdateAI`
* Constants: `AI_REACTION_HOSTILE`, `COMBAT_MANAGER_TICK`, `CONFIG_FLOAT_LEASH_RADIUS`, `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT`, `CREATURE_EXTRA_FLAG_NO_CALL_ASSIST`, `EVADE_HOME`, `REGEN_TIME_FULL_UNIT`, `STATE_SUPPRESSED`, `UNIT_STAT_MELEE_ATTACKING`, `UNIT_STAT_STUNNED`

## world/creaturecasting.d

* Projects: CMaNGOS, EventAI
* Functions: `Spell::CheckRange`, `Spell::cast`, `Spell::prepare`, `UnitAI::DoCastSpellIfCan`
* Constants: `CAST_FORCE_TARGET_SELF`, `EVENT_T_FRIENDLY_HP`, `SMSG_SPELL_FAILURE`, `SMSG_SPELL_GO`, `SPELL_EFFECT_APPLY_AURA`, `SPELL_EFFECT_HEAL`, `TEMPSPAWN_TIMED_OOC_DESPAWN`, `TEMPSPAWN_TIMED_OOC_OR_DEAD_DESPAWN`, `UNIT_STAT_NO_COMBAT_MOVEMENT`

## world/crypt.d

* Projects: CMaNGOS

## world/database.d

* Projects: ArcEmu, CMaNGOS
* Files: `CharacterHandler.cpp`, `WorldSocket.cpp`
* Functions: `AuctionEntry::SaveToDB`, `Corpse::DeleteFromDB`, `Corpse::SaveToDB`, `GameObject::SaveRespawnTime`, `Group::Create`, `Group::Disband`, `Group::_addMember`, `Group::_removeMember`, `GuildMgr::LoadGuilds`, `Item::SaveToDB`, `MailDraft::SendMailTo`, `MapPersistentState::SaveCreatureRespawnTime`, `ObjectMgr::AddGameTele`, `ObjectMgr::DeleteGameTele`, `ObjectMgr::LoadGroups`, `Pet::LoadPetFromDB`, `Player::LoadFromDB`, `Player::SaveItemToInventory`, `Player::SaveToDB`, `Player::SetHomebindToLocation`, `Player::_LoadAuras`, `Player::_LoadBGData`, `Player::_SaveAuras`, `Player::_SaveBGData`, `Player::_SaveInventory`, `Player::_SaveQuestStatus`, `Player::_SaveSkills`, `Player::_SaveSpells`, `ReputationMgr::SaveToDB`
* Constants: `LOGIN_TYPE_MANGOSD`, `PET_SAVE_AS_CURRENT`

## world/dbscripts.d

* Projects: CMaNGOS, EventAI
* Files: `ScriptMgr.cpp`
* Functions: `Map::ScriptsProcess`, `Map::ScriptsStart`
* Constants: `FORCED_MOVEMENT_RUN`, `SCRIPT_COMMAND_MOVE_TO`, `SCRIPT_COMMAND_RESPAWN_GAMEOBJECT`, `SCRIPT_COMMAND_TERMINATE_SCRIPT`, `SCRIPT_FLAG_BUDDY_AS_TARGET`, `SCRIPT_FLAG_BUDDY_BY_GUID`, `SPELL_EFFECT_SEND_EVENT`, `TYPEMASK_CREATURE_OR_GAMEOBJECT`

## world/death.d

* Projects: CMaNGOS
* Files: `MiscHandler.cpp`, `NPCHandler.cpp`, `QueryHandler.cpp`
* Functions: `GraveyardManager::GetClosestGraveYard`, `Player::KillPlayer`, `Player::Update`, `Player::UpdateCorpseReclaimDelay`, `Player::getCorpseReclaimDelayHelper`, `Unit::Kill`, `WorldSession::LogoutPlayer`
* Constants: `CORPSE_RECLAIM_DELAY`, `DEATH_EXPIRE_STEP`, `PLAYER_FLAGS_GHOST`, `TEAM_INVALID`

## world/defines.d

* Projects: CMaNGOS
* Files: `ItemPrototype.h`, `Player.h`, `SharedDefines.h`
* Constants: `INVENTORY_SLOT_BAG_0`, `MAX_ACTION_BUTTONS`, `MAX_POWERS`, `NULL_BAG`, `NULL_SLOT`, `PLAYER_EXPLORED_ZONES_SIZE`, `UNIT_FIELD_FLAGS`, `UNIT_FLAG_FLEEING`, `UNIT_FLAG_LOOTING`

## world/duelhandlers.d

* Projects: CMaNGOS
* Files: `DuelHandler.cpp`
* Functions: `Player::DuelComplete`, `Player::Update`, `Player::UpdateDuelFlag`, `Player::duel`, `Spell::EffectDuel`, `Unit::DealDamage`
* Constants: `EMOTE_ONESHOT_BEG`, `PLAYER_DUEL_ARBITER`, `PLAYER_DUEL_TEAM`

## world/dynobject.d

* Projects: Blizzard, CMaNGOS
* Files: `DynamicObject.cpp`
* Functions: `DynamicObject::Create`
* Constants: `HIGHGUID_DYNAMICOBJECT`

## world/eventai.d

* Projects: CMaNGOS, EventAI
* Files: `CreatureEventAI.cpp`
* Constants: `EFLAG_RANDOM_ACTION`, `EVENT_UPDATE_TIME`, `TARGET_T_EVENT_SENDER`, `TARGET_T_EVENT_SPECIFIC`

## world/experience.d

* Projects: CMaNGOS, MaNGOS
* Files: `Formulas.h`
* Functions: `MaNGOS::XP`, `XP::BaseGain`, `XP::Gain`, `XP::GetGrayLevel`, `XP::GetQuestGreenRange`, `XP::GetZeroDifference`, `XP::IsTrivialLevelDifference`, `XP::xp_in_group_rate`
* Constants: `CONFIG_FLOAT_GROUP_XP_DISTANCE`, `NO_XP`

## world/exploration.d

* Projects: CMaNGOS
* Functions: `ObjectMgr::GetBaseXP`, `Player::CheckAreaExploreAndOutdoor`, `Player::GetZoneAndAreaId`, `Player::GiveLevel`, `Player::GiveXP`, `Player::SetPosition`, `Player::Update`, `Player::UpdateArea`, `Player::UpdateZone`, `WorldSession::HandleZoneUpdateOpcode`
* Constants: `AREA_FLAG_CAPITAL`, `CMSG_ZONEUPDATE`, `SMSG_INIT_WORLD_STATES`

## world/gameobject.d

* Projects: CMaNGOS
* Files: `GameObject.cpp`
* Functions: `GameObject::Create`, `GameObject::Update`, `GameObjectInfo::GetLockId`, `Object::BuildCreateUpdateBlockForPlayer`
* Constants: `GAMEOBJECT_DYN_FLAGS`, `GAMEOBJECT_TYPE_GOOBER`, `GAMEOBJECT_TYPE_MO_TRANSPORT`, `GO_DYNFLAG_LO_ACTIVATE`, `GO_JUST_DEACTIVATED`

## world/gameobjecthandlers.d

* Projects: CMaNGOS
* Functions: `GameObject::ActivateToQuest`, `GameObject::Use`, `Loot::Loot`, `Loot::Release`, `Player::UpdateGatherSkill`, `Player::UpdateSkillPro`, `Spell::CanOpenLock`, `Spell::EffectOpenLock`, `Spell::SendLoot`
* Constants: `GAMEOBJECT_TYPE_CHAIR`, `INTERACTION_DISTANCE`, `SCRIPT_COMMAND_OPEN_DOOR`

## world/gmactions.d

* Projects: ArcEmu, CMaNGOS
* Functions: `Player::DestroyItemCount`, `Player::GiveLevel`, `Player::SaveToDB`, `Player::SetPlayerSpeed`, `Player::SetSkill`, `Player::learnSpell`, `Player::removeSpell`, `World::SendGMWorldText`, `World::SendWorldText`, `World::SendWorldWideScreenText`
* Constants: `SMSG_AREA_TRIGGER_MESSAGE`, `SMSG_LEARNED_SPELL`, `SMSG_LEVELUP_INFO`

## world/gmdebug.d

* Projects: ArcEmu, CMaNGOS
* Files: `BattlegroundCommands.cpp`, `RecallCommands.cpp`
* Functions: `CBattleground::Close`, `Object::isInFront`
* Constants: `SMSG_ITEM_PUSH_RESULT`

## world/gminstance.d

* Projects: ArcEmu
* Files: `InstanceCommands.cpp`
* Functions: `InstanceMgr::ResetSavedInstances`, `MapMgr::InstanceShutdown`, `Player::ExitInstance`

## world/gmlevel0.d

* Projects: ArcEmu
* Files: `Level0.cpp`
* Functions: `ChatHandler::ShowHelpForCommand`, `SocketMgr::ShowStatus`, `World::GetUptimeString`

## world/gmlevel1.d

* Projects: ArcEmu
* Files: `Level1.cpp`
* Functions: `World::AnnounceColorChooser`

## world/gmlevel2.d

* Projects: ArcEmu, CMaNGOS
* Files: `Level2.cpp`
* Functions: `AIInterface::MoveTo`, `Player::bInvincible`, `Unit::DeMorph`

## world/gmlevel3.d

* Projects: ArcEmu, CMaNGOS
* Files: `CharacterHandler.cpp`, `Level3.cpp`, `QuestCommands.cpp`
* Functions: `MapMgr::GetUnit`, `Player::Reset_Spells`, `Player::SetStanding`, `Player::SummonRequest`, `World::DisconnectUsersWith`, `World::DisconnectUsersWithAccount`, `World::DisconnectUsersWithIP`, `World::DisconnectUsersWithPlayerName`, `World::FindSessionByName`, `WorldSession::HandleSummonResponseOpcode`
* Constants: `SMSG_SUMMON_REQUEST`

## world/gmquest.d

* Projects: ArcEmu, CMaNGOS
* Files: `QuestCommands.cpp`
* Functions: `Player::AddToFinishedQuests`, `Player::GetQuestLogForEntry`, `Player::HasFinishedQuest`
* Constants: `SMSG_QUESTGIVER_QUEST_COMPLETE`

## world/gmtargets.d

* Projects: ArcEmu
* Functions: `Player::RemoteRevive`, `World::DisconnectUsersWithPlayerName`

## world/grid.d

* Projects: CMaNGOS
* Files: `GridDefines.h`
* Constants: `SIZE_OF_GRID_CELL`

## world/group.d

* Projects: CMaNGOS
* Files: `Group.cpp`
* Functions: `Group::AddMember`, `Group::BroadcastPacket`, `Group::ChangeLeader`, `Group::ConvertToRaid`, `Group::Create`, `Group::Disband`, `Group::MemberSlot`, `Group::RemoveMember`, `Group::SendTargetIconList`, `Group::SendUpdate`, `Group::SendUpdateTo`, `Group::SetTargetIcon`, `Group::UpdatePlayerOnlineStatus`, `Group::UpdatePlayerOutOfRange`, `ObjectMgr::LoadGroups`, `Player::GetGroup`, `Player::GetGroupInvite`, `Player::IsInSameGroupWith`, `Player::UninviteFromGroup`, `WorldSession::BuildPartyMemberStatsChangedPacket`, `WorldSession::HandleRequestPartyMemberStatsOpcode`
* Constants: `ITEM_QUALITY_UNCOMMON`, `MAX_GROUP_SIZE`, `MAX_RAID_SIZE`, `MAX_RAID_SUBGROUPS`, `SMSG_GROUP_LIST`, `SMSG_PARTY_MEMBER_STATS`, `SMSG_PARTY_MEMBER_STATS_FULL`, `TARGET_ICON_COUNT`

## world/grouphandlers.d

* Projects: CMaNGOS
* Files: `GroupHandler.cpp`, `LootHandler.cpp`
* Functions: `WorldSession::LogoutPlayer`, `WorldSession::SendPartyResult`
* Constants: `SMSG_COMPRESSED_UPDATE_OBJECT`

## world/groupservice.d

* Projects: CMaNGOS, vmangos
* Files: `GroupHandler.cpp`; vmangos `LFGHandler.cpp`, `LFGQueue.cpp`, `Group.cpp`
* Functions: `Player::CanUninviteFromGroup`, `WorldSession::HandleGroupInviteOpcode`, `WorldSession::LogoutPlayer`, `WorldSession::SendPartyResult`

## world/meetingstone.d

* Projects: vmangos
* Files: `LFG/LFGDefines.h`, `LFG/LFGMgr.cpp`, `LFG/LFGQueue.cpp`, `Group/Group.cpp`, `Server/Packets/Misc.cpp`
* Functions: `LFGMgr::CalculateRoles`, `LFGMgr::GetPriority`, `LFGQueue::Update`, `LFGQueue::FindRoleToGroup`, `Group::CalculateLFGRoles`, `Group::FillPremadeLFG`

## world/guild.d

* Projects: CMaNGOS
* Functions: `Guild::HasRankRight`, `Guild::Query`
* Constants: `GUILD_RANKS_MAX_COUNT`, `GUILD_RANKS_MIN_COUNT`, `SMSG_GUILD_COMMAND_RESULT`, `SMSG_GUILD_EVENT`, `SMSG_GUILD_QUERY_RESPONSE`

## world/guildhandlers.d

* Projects: CMaNGOS
* Files: `GuildHandler.cpp`, `PetitionsHandler.cpp`
* Functions: `Guild::AddMember`, `Guild::BroadcastPacket`, `Guild::Create`, `Guild::DelMember`, `Guild::Disband`, `Guild::Roster`
* Constants: `CHARTER_DISPLAY_ID`, `CHAT_MSG_GUILD`, `CHAT_MSG_OFFICER`, `CMSG_GUILD_CREATE`, `CONFIG_UINT32_MIN_PETITION_SIGNS`, `ERR_GUILD_RANK_IN_USE`, `ERR_PLAYER_NO_MORE_IN_GUILD`, `GUILD_CHARTER`, `GUILD_CHARTER_COST`, `MSG_TABARDVENDOR_ACTIVATE`

## world/honor.d

* Projects: ArcEmu, CMaNGOS, MaNGOS
* Files: `HonorHandler.cpp`
* Functions: `HonorCP::isKill`, `MaNGOS::Honor`, `Player::AddHonorCP`, `Player::CalculateTotalKills`, `Player::GetRankPoints`, `Player::RewardHonor`, `Player::UpdateHonor`, `Unit::Kill`, `World::GetDateLastMaintenanceDay`, `WorldSession::HandleInspectHonorStatsOpcode`
* Constants: `SMSG_PVP_CREDIT`, `TYPE_OF_HONOR`

## world/honorweek.d

* Projects: CMaNGOS, MaNGOS
* Functions: `MaNGOS::Honor`, `ObjectMgr::CalculateRpDecay`, `ObjectMgr::CalculateRpEarning`, `ObjectMgr::FlushRankPoints`, `ObjectMgr::GenerateScores`, `World::ServerMaintenanceStart`

## world/inventory.d

* Projects: CMaNGOS
* Files: `Bag.cpp`, `Item.cpp`, `Item.h`, `ItemPrototype.h`, `Player.cpp`, `SharedDefines.h`
* Functions: `Bag::Create`, `Bag::IsEmpty`, `Bag::RemoveItem`, `Bag::StoreItem`, `Item::CalculateDurabilityRepairCost`, `Item::CanBeMergedPartlyWith`, `Item::CloneItem`, `Item::Create`, `Item::CreateItem`, `Item::GetBagSlot`, `Item::GetBaseRepairCost`, `Item::GetPos`, `Item::GetSellPrice`, `Item::GetSkill`, `Item::IsBag`, `Item::IsBindedNotWith`, `Item::IsEquipped`, `Item::IsSoulBound`, `Item::LoadFromDB`, `Item::SaveToDB`, `Item::SetBinding`, `Item::SetState`, `ItemPosCount::isContainedIn`, `ItemPrototype::CanChangeEquipStateInCombat`, `Player::AddItemToBuyBackSlot`, `Player::AutoUnequipOffhandIfNeed`, `Player::CanBankItem`, `Player::CanDualWield`, `Player::CanEquipItem`, `Player::CanEquipNewItem`, `Player::CanStoreItem`, `Player::CanStoreNewItem`, `Player::CanUnequipItem`, `Player::CanUseAmmo`, `Player::CanUseItem`, `Player::DestroyItem`, `Player::DestroyItemCount`, `Player::EquipItem`, `Player::EquipNewItem`, `Player::FindEquipSlot`, `Player::GetBankBagSlotCount`, `Player::GetItemByGuid`, `Player::GetItemByPos`, `Player::GetItemCount`, `Player::GetItemFromBuyBackSlot`, `Player::GetMaxKeyringClientSize`, `Player::HasItemWithIdEquipped`, `Player::HasSpell`, `Player::IsBagPos`, `Player::IsBankPos`, `Player::IsEquipmentPos`, `Player::IsInventoryPos`, `Player::IsTwoHandUsed`, `Player::IsValidPos`, `Player::RemoveItem`, `Player::RemoveItemFromBuyBackSlot`, `Player::SaveItemToInventory`, `Player::SendEquipError`, `Player::SetBankBagSlotCount`, `Player::SetVisibleItemSlot`, `Player::SplitItem`, `Player::StoreItem`, `Player::StoreNewItem`, `Player::SwapItem`, `Player::ViableEquipSlots`, `Player::VisualizeItem`, `Player::_CanStoreItem`, `Player::_CanStoreItem_InBag`, `Player::_CanStoreItem_InInventorySlots`, `Player::_CanStoreItem_InSpecificSlot`, `Player::_CanTakeMoreSimilarItems`, `Player::_LoadInventory`, `Player::_SaveInventory`, `Player::_StoreItem`, `Player::m_items`
* Constants: `EQUIP_ERR_NONE`, `ITEM_DYNFLAG_BINDED`, `ITEM_DYNFLAG_UNLOCKED`, `ITEM_DYNFLAG_WRAPPED`, `SMSG_BUY_FAILED`, `SMSG_INVENTORY_CHANGE_FAILURE`, `SMSG_SELL_ITEM`

## world/inworld.d

* Projects: ArcEmu, CMaNGOS
* Files: `ChatHandler.cpp`, `ItemHandler.cpp`, `MiscHandler.cpp`, `MovementHandler.cpp`, `QueryHandler.cpp`
* Functions: `Player::RegenerateAll`, `Player::Say`, `Player::Update`, `Player::Whisper`, `Unit::HandleEmote`, `WorldSession::HandleLogoutRequestOpcode`, `WorldSession::LogoutPlayer`, `WorldSession::Update`, `WorldSession::VerifyMovementInfo`, `WorldSession::m_muted`

## world/itemhandlers.d

* Projects: ArcEmu, CMaNGOS
* Files: `ItemHandler.cpp`, `NPCHandler.cpp`
* Functions: `Player::BuyItemFromVendor`, `Player::DurabilityRepair`, `Player::DurabilityRepairAll`, `Player::SendBuyError`, `Player::SendEquipError`, `Player::SendNewItem`, `Player::SendSellError`, `Player::SetAmmo`, `WorldSession::HandleAutoBankItemOpcode`, `WorldSession::HandleAutoEquipItemOpcode`, `WorldSession::HandleAutoEquipItemSlotOpcode`, `WorldSession::HandleAutoStoreBagItemOpcode`, `WorldSession::HandleAutoStoreBankItemOpcode`, `WorldSession::HandleBuyBankSlotOpcode`, `WorldSession::HandleBuyItemInSlotOpcode`, `WorldSession::HandleBuyItemOpcode`, `WorldSession::HandleBuybackItem`, `WorldSession::HandleDestroyItemOpcode`, `WorldSession::HandleRepairItemOpcode`, `WorldSession::HandleSellItemOpcode`, `WorldSession::HandleSetAmmoOpcode`, `WorldSession::HandleSplitItemOpcode`, `WorldSession::HandleSwapInvItemOpcode`, `WorldSession::HandleSwapItem`
* Constants: `RANK_REQUIRE`

## world/loot.d

* Projects: CMaNGOS
* Files: `LootMgr.cpp`
* Functions: `GroupLootRoll::AllPlayerVoted`, `GroupLootRoll::Finish`, `GroupLootRoll::PlayerVote`, `GroupLootRoll::TryToStart`, `GroupLootRoll::UpdateRoll`, `Loot::AddItem`, `Loot::CanLoot`, `Loot::FillLoot`, `Loot::GenerateMoneyLoot`, `Loot::GetLootContentFor`, `Loot::GetLootStatusFor`, `Loot::GroupCheck`, `Loot::IsItemAlreadyIn`, `Loot::IsLootedFor`, `Loot::IsLootedForAll`, `Loot::NotifyItemRemoved`, `Loot::Release`, `Loot::SendGold`, `Loot::SendItem`, `Loot::SendReleaseFor`, `Loot::SendReleaseForAll`, `Loot::ShowContentTo`, `Loot::Update`, `LootGroup::Roll`, `LootItem::GetSlotTypeForSharedLoot`, `LootMgr::PlayerVote`, `LootStoreItem::Roll`, `LootTemplate::AddEntry`, `LootTemplate::HasQuestDrop`, `LootTemplate::LootGroup`, `LootTemplate::Process`
* Constants: `ITEM_FLAG_MULTI_DROP`, `ITEM_QUALITY_UNCOMMON`, `LOOTITEM_TYPE_QUEST`, `LOOT_ROLL_TIMEOUT`, `LOOT_STATUS_FAKE_LOOT`, `MAX_NR_LOOT_ITEMS`, `SMSG_LOOT_RESPONSE`, `SMSG_LOOT_ROLL`, `SMSG_LOOT_START_ROLL`, `UNIT_FLAG_LOOTING`

## world/loothandlers.d

* Projects: CMaNGOS
* Files: `LootHandler.cpp`
* Functions: `Creature::PrepareBodyLootState`, `CreatureStaticFlags::NO_LOOT`, `CreatureStaticFlags::NO_XP`, `Group::RewardGroupAtKill`, `Item::m_loot`, `LockEntry::Skill`, `Loot::Loot`, `Loot::Release`, `Loot::SetGroupLootRight`, `Loot::SetPlayerIsLooting`, `ObjectMgr::IsConditionSatisfied`, `Player::IsAtGroupRewardDistance`, `Player::RemoveFromWorld`, `Player::RewardSinglePlayerAtKill`, `Player::SendLootError`, `Unit::DealDamage`, `Unit::Kill`, `XP::Gain`
* Constants: `CMSG_AUTOSTORE_LOOT_ITEM`, `CMSG_LOOT_MASTER_GIVE`, `CMSG_LOOT_ROLL`, `SMSG_PARTYKILLLOG`, `UNIT_FLAG_LOOTING`

## world/mailhandlers.d

* Projects: CMaNGOS
* Files: `MailHandler.cpp`
* Functions: `MailDraft::SendMailTo`, `Player::SendMailResult`
* Constants: `MAIL_BODY_ITEM_TEMPLATE`

## world/main.d

* Projects: CMaNGOS, mangosd
* Constants: `RESTART_EXIT_CODE`

## world/map.d

* Projects: CMaNGOS, mangosd
* Files: `Map.cpp`
* Functions: `Cell::SetNoCreate`, `Map::Add`, `Map::CreatureRelocation`, `Map::PlayerRelocation`, `Map::Remove`, `Map::SendObjectUpdates`, `Map::Update`, `Object::BuildValuesUpdate`, `Object::UpdateVisibilityOf`, `ObjectGridLoader::Load`, `Player::UpdateVisibilityOf`, `TerrainInfo::IsInWater`, `Unit::OnRelocated`
* Constants: `SMSG_DESTROY_OBJECT`

## world/motion.d

* Projects: CMaNGOS
* Functions: `FactorySelector::selectMovementGenerator`, `Map::GetHeight`, `MotionMaster::Initialize`, `MotionMaster::MovePoint`, `MoveSplineInit::Launch`, `MoveSplineInit::MoveTo`, `MoveSplineInit::Stop`, `TerrainInfo::GetWaterOrGroundLevel`, `Unit::InterruptMoving`, `Unit::StopMoving`, `Unit::UpdateAllowedPositionZ`, `Unit::UpdateSplineMovement`, `WaypointManager::Load`
* Constants: `SCRIPT_COMMAND_PAUSE_WAYPOINTS`

## world/movement.d

* Projects: CMaNGOS, MaNGOS
* Files: `Unit.cpp`
* Functions: `MaNGOS::IsValidMapCoord`, `MovementInfo::Read`, `MovementInfo::Write`
* Constants: `MOVEFLAG_MASK_MOVING`

## world/names.d

* Projects: CMaNGOS
* Functions: `ObjectMgr::CheckPlayerName`
* Constants: `MAX_INTERNAL_PLAYER_NAME`, `MAX_PLAYER_NAME`

## world/npcdata.d

* Projects: CMaNGOS
* Functions: `BroadcastText::GetText`, `ObjectMgr::LoadGossipMenus`, `ObjectMgr::LoadGossipText`, `ObjectMgr::LoadTrainers`

## world/npchandlers.d

* Projects: CMaNGOS
* Files: `GossipDef.cpp`, `ItemHandler.cpp`, `NPCHandler.cpp`, `Player.cpp`, `QueryHandler.cpp`
* Functions: `Creature::CanInteractWithBattleMaster`, `Creature::IsTrainerOf`, `ObjectMgr::LoadTrainers`, `Player::CanSeeVendorItem`, `Player::GetGossipTextId`, `Player::GetNPCIfCanInteractWith`, `Player::GetTrainerSpellState`, `Player::IsSpellFitByClassAndRace`, `Player::OnGossipSelect`, `Player::PrepareGossipMenu`, `Player::SendPreparedGossip`, `Player::SetBindPoint`, `Player::learnSpell`, `PlayerMenu::CloseGossip`, `PlayerMenu::SendPointOfInterest`, `Spell::EffectBind`, `Spell::EffectLearnSpell`, `SpellMgr::IsPrimaryProfessionFirstRankSpell`, `SpellMgr::IsProfessionSpell`, `WorldObject::IsWithinDistInMap`, `WorldSession::HandleBinderActivateOpcode`, `WorldSession::HandleNpcTextQueryOpcode`, `WorldSession::HandleTrainerBuySpellOpcode`, `WorldSession::SendListInventory`, `WorldSession::SendTrainerList`
* Constants: `ADD_GOSSIP_ITEM`, `DEFAULT_GOSSIP_MESSAGE`, `GOSSIP_OPTION_STABLEPET`, `INTERACTION_DISTANCE`, `SEND_GOSSIP_MENU`, `UNIT_NPC_FLAGS`

## world/objects.d

* Projects: CMaNGOS, mangosd
* Files: `Object.cpp`, `UpdateData.cpp`, `UpdateMask.h`
* Functions: `Object::BuildCreateUpdateBlockForPlayer`, `Object::BuildMovementUpdate`, `Object::BuildValuesUpdate`, `Object::BuildValuesUpdateBlockForPlayer`, `Object::GetUpdateFieldFlagsForTarget`, `UpdateData::AddOutOfRangeGUID`, `UpdateData::BuildPacketOfBlocks`, `UpdateData::GetPacketEnd`
* Constants: `HIGHGUID_PET`, `MAX_NETCLIENT_PACKET_SIZE`, `OBJECT_UPDATE_FLAGS`, `OBJECT_UPDATE_TYPE`, `SMSG_COMPRESSED_UPDATE_OBJECT`, `SMSG_UPDATE_OBJECT`, `STAT4`, `UNIT_FIELD_STAT0`

## world/online.d

* Projects: ArcEmu
* Functions: `Player::IsBeingTeleportedFar`, `Player::Update`, `WorldSession::CanUseCommand`, `WorldSession::GetPermissionCount`, `WorldSession::GetSecurity`, `WorldSession::Update`

## world/opcodes.d

* Projects: CMaNGOS
* Files: `Opcodes.h`, `SharedDefines.h`
* Constants: `MSG_MOVE_TIME_SKIPPED`, `NUM_MSG_TYPES`, `SMSG_AUTH_RESPONSE`, `SMSG_CHARACTER_LOGIN_FAILED`, `SMSG_CHAR_CREATE`, `SMSG_CHAR_DELETE`

## world/packets.d

* Projects: CMaNGOS
* Files: `ChannelHandler.cpp`, `GossipDef.cpp`, `GroupHandler.cpp`, `ItemHandler.cpp`, `MiscHandler.cpp`, `MovementHandler.cpp`, `NPCHandler.cpp`, `QueryHandler.cpp`, `WorldSocket.cpp`
* Functions: `Player::SendBuyError`, `Player::SendEquipError`, `Player::SendInitialPacketsBeforeAddToMap`, `Player::SendInitialSpells`, `Player::SendLogXPGain`, `Player::SendNewItem`, `Player::SendOpenContainer`, `Player::SendSellError`, `Player::SendSummonRequest`, `Player::SetBindPoint`, `Player::SetSpeedRate`, `Player::TeleportTo`, `PlayerMenu::SendGossipMenu`, `PlayerMenu::SendPointOfInterest`, `Spell::EffectBind`, `WorldSession::HandleNpcTextQueryOpcode`, `WorldSession::SendListInventory`, `WorldSession::SendTrainerList`
* Constants: `BUYBACK_SLOT_START`, `CMSG_AREATRIGGER`, `CMSG_AUTH_SESSION`, `CMSG_AUTOBANK_ITEM`, `CMSG_AUTOEQUIP_ITEM`, `CMSG_AUTOEQUIP_ITEM_SLOT`, `CMSG_AUTOSTORE_BAG_ITEM`, `CMSG_AUTOSTORE_BANK_ITEM`, `CMSG_BANKER_ACTIVATE`, `CMSG_BINDER_ACTIVATE`, `CMSG_BUYBACK_ITEM`, `CMSG_BUY_ITEM`, `CMSG_BUY_ITEM_IN_SLOT`, `CMSG_CHANNEL_ANNOUNCEMENTS`, `CMSG_CHANNEL_LIST`, `CMSG_CHANNEL_MODERATE`, `CMSG_CHANNEL_OWNER`, `CMSG_CHANNEL_PASSWORD`, `CMSG_CHAR_CREATE`, `CMSG_CHAR_DELETE`, `CMSG_CREATURE_QUERY`, `CMSG_DESTROYITEM`, `CMSG_GAMEOBJECT_QUERY`, `CMSG_GOSSIP_HELLO`, `CMSG_GOSSIP_SELECT_OPTION`, `CMSG_GROUP_ASSISTANT_LEADER`, `CMSG_GROUP_CHANGE_SUB_GROUP`, `CMSG_GROUP_INVITE`, `CMSG_GROUP_SET_LEADER`, `CMSG_GROUP_SWAP_SUB_GROUP`, `CMSG_GROUP_UNINVITE`, `CMSG_GROUP_UNINVITE_GUID`, `CMSG_ITEM_QUERY_SINGLE`, `CMSG_JOIN_CHANNEL`, `CMSG_LEAVE_CHANNEL`, `CMSG_LIST_INVENTORY`, `CMSG_LOOT_METHOD`, `CMSG_NAME_QUERY`, `CMSG_NPC_TEXT_QUERY`, `CMSG_PING`, `CMSG_PLAYER_LOGIN`, `CMSG_REPAIR_ITEM`, `CMSG_REQUEST_PARTY_MEMBER_STATS`, `CMSG_SELL_ITEM`, `CMSG_SET_ACTIONBAR_TOGGLES`, `CMSG_SET_ACTION_BUTTON`, `CMSG_SET_AMMO`, `CMSG_SET_SELECTION`, `CMSG_SPLIT_ITEM`, `CMSG_STANDSTATECHANGE`, `CMSG_SUMMON_RESPONSE`, `CMSG_SWAP_INV_ITEM`, `CMSG_SWAP_ITEM`, `CMSG_TEXT_EMOTE`, `CMSG_TRAINER_BUY_SPELL`, `CMSG_TRAINER_LIST`, `CMSG_TUTORIAL_FLAG`, `CMSG_WORLD_TELEPORT`, `CMSG_ZONEUPDATE`, `MAX_REPUTATION_LIST`, `MSG_MINIMAP_PING`, `MSG_MOVE_TELEPORT_ACK`, `MSG_MOVE_WORLDPORT_ACK`, `MSG_RANDOM_ROLL`, `NUM_ACCOUNT_DATA_TYPES`, `SMSG_ACCOUNT_DATA_TIMES`, `SMSG_ACTION_BUTTONS`, `SMSG_ADDON_INFO`, `SMSG_AREA_TRIGGER_MESSAGE`, `SMSG_AUTH_RESPONSE`, `SMSG_BINDER_CONFIRM`, `SMSG_BINDPOINTUPDATE`, `SMSG_BUY_BANK_SLOT_RESULT`, `SMSG_BUY_FAILED`, `SMSG_BUY_ITEM`, `SMSG_CHARACTER_LOGIN_FAILED`, `SMSG_CHAR_CREATE`, `SMSG_CHAR_DELETE`, `SMSG_CHAR_ENUM`, `SMSG_CHAT_PLAYER_NOT_FOUND`

## world/pet.d

* Projects: CMaNGOS
* Functions: `CharmInfo::PetActionBar`, `ObjectMgr::GeneratePetName`, `Pet::InitStatsForLevel`, `Pet::addSpell`, `Player::PetSpellInitialize`
* Constants: `ACTION_BAR_INDEX_START`, `MAKE_UNIT_ACTION_BUTTON`, `MAX_PET_STABLES`, `MSG_LIST_STABLED_PETS`, `SMSG_PET_NAME_QUERY_RESPONSE`, `SMSG_PET_SPELLS`, `UNIT_ACTION_BUTTON_ACTION`, `UNIT_FIELD_PETNUMBER`

## world/petai.d

* Projects: CMaNGOS
* Functions: `CharmInfo::GetCommandState`, `PetAI::AttackStart`, `PetAI::MoveInLineOfSight`, `PetAI::UpdateAI`, `PetAI::m_followDist`
* Constants: `ACT_ENABLED`, `CMSG_PET_ACTION`, `CMSG_PET_CAST_SPELL`, `SPELL_ATTR_EX_NO_AUTOCAST_AI`

## world/pethandlers.d

* Projects: CMaNGOS
* Files: `NPCHandler.cpp`, `PetHandler.cpp`, `SpellEffects.cpp`
* Functions: `CreatureInfo::isTameable`, `ObjectMgr::CheckPetName`, `ObjectMgr::GetXPForPetLevel`, `Pet::GivePetXP`, `Pet::InitPetCreateSpells`, `Pet::LoadPetFromDB`, `Pet::SavePetToDB`, `Pet::ToggleAutocast`, `Pet::TryLoadFromDB`, `Pet::Unsummon`, `Pet::Update`, `PetAI::PetAI`, `Player::LoadPet`, `Player::PetSpellInitialize`, `Player::SynchronizeLevelWithOwner`, `Spell::CheckCast`, `TameBeastChannel::OnCheckCast`, `WorldSession::HandlePetAction`
* Constants: `CLASS_HUNTER`, `CLASS_WARLOCK`, `CMSG_PET_CANCEL_AURA`, `CMSG_REQUEST_PET_INFO`, `CONFIG_UINT32_MIN_PET_NAME`, `CORPSE_DECAY_NORMAL`, `CREATURE_TYPEFLAGS_TAMEABLE`, `CREATURE_TYPE_BEAST`, `MAX_PET_NAME`, `PETTAME_DEAD`, `SMSG_PET_ACTION_FEEDBACK`, `SMSG_PET_TAME_FAILURE`, `SMSG_STABLE_RESULT`, `SPELL_ATTR_EX_DISMISS_PET_FIRST`, `SPELL_EFFECT_DISMISS_PET`, `SPELL_EFFECT_SUMMON_DEAD_PET`, `SPELL_EFFECT_SUMMON_PET`, `SPELL_EFFECT_TAMECREATURE`, `UNIT_FLAG_PET_ABANDON`, `UNIT_FLAG_PET_RENAME`

## world/player.d

* Projects: ArcEmu, CMaNGOS
* Functions: `Aura::HandleAuraModStat`, `Group::_updateMembersOnRosterChanged`, `Object::BuildValuesUpdate`, `Player::BuildCreateUpdateBlockForPlayer`, `Player::CanDualWield`, `Player::ComputeRest`, `Player::ExploreArea`, `Player::GetChatTag`, `Player::GiveLevel`, `Player::HasItemCount`, `Player::HasSpell`, `Player::LoadFromDB`, `Player::ModifyMoney`, `Player::RegenerateAll`, `Player::SaveToDB`, `Player::SendInitialPacketsBeforeAddToMap`, `Player::SetRestBonus`, `Player::SetRestType`, `Player::SetSkill`, `Player::UpdateFreeTalentPoints`, `Player::UpdateSkillsForLevel`, `Player::_ApplyItemMods`, `Player::_LoadInventory`, `Player::autoReplyMsg`, `Player::bGMTagOn`, `Player::m_areaUpdateId`, `Spell::EffectDualWield`, `Spell::EffectProficiency`, `Unit::GetPowerType`, `Unit::HandleEmoteState`, `Unit::OCTRegenHPPerSpirit`, `Unit::OCTRegenMPPerSpirit`, `Unit::SetStandState`, `Unit::SetStunned`, `Unit::SetTargetGuid`, `Unit::m_speed_rate`
* Constants: `CORPSE`, `DEAD`, `MAX_MONEY_AMOUNT`, `PLAYER_EXPLORED_ZONES_1`, `PLAYER_FIELD_COINAGE`, `SKILL_FLAG_MAXIMIZED`, `SMSG_ACTION_BUTTONS`, `SMSG_LEVELUP_INFO`, `SMSG_SET_PROFICIENCY`, `SPELL_EFFECT_DUAL_WIELD`

## world/playercreate.d

* Projects: CMaNGOS, mangosd
* Files: `ItemPrototype.h`, `Player.h`, `SharedDefines.h`, `StatSystem.cpp`
* Functions: `Player::Create`, `Player::GetSkillInfo`, `Player::HasSpell`, `Player::InitPrimaryProfessions`, `Player::IsNeedCastPassiveLikeSpellAtLearn`, `Player::LoadFromDB`, `Player::SetAmmo`, `Player::SetSkill`, `Player::StoreNewItemInBestSlots`, `Player::ValidateAppearance`, `Player::addSpell`, `Player::learnSpell`, `Spell::EffectLearnSpell`, `SpellMgr::GetSpellBookSuccessorSpellId`, `SpellMgr::IsPrimaryProfessionFirstRankSpell`, `SpellMgr::IsSpellValid`
* Constants: `AT_LOGIN_FIRST`, `CMSG_CHAR_CREATE`, `ITEM_DYNFLAG_BINDED`, `MAX_ENCHANTMENT_SLOT`, `SMSG_LEARNED_SPELL`, `SMSG_SUPERCEDED_SPELL`

## world/pvp.d

* Projects: CMaNGOS
* Functions: `Player::UpdateArea`, `Player::UpdatePvP`, `Player::UpdatePvPContested`, `Player::UpdatePvPFlagTimer`, `Player::UpdateZone`, `Unit::ClearInCombat`, `Unit::SetInCombatWith`, `Unit::SetInCombatWithAggressor`, `Unit::SetInCombatWithAssisted`, `Unit::SetPvP`, `WorldSession::HandleTogglePvP`
* Constants: `AREA_FLAG_ARENA`, `AREA_FLAG_CAPITAL`, `FACTION_TEMPLATE_FLAG_ATTACK_PVP_ACTIVE_PLAYERS`, `PLAYER_FLAGS_CONTESTED_PVP`, `PLAYER_FLAGS_FFA_PVP`, `PLAYER_FLAGS_PVP_DESIRED`, `UNIT_FLAG_PVP`

## world/queries.d

* Functions: `ChatHandler::BuildChatPacket`, `WorldSession::HandleCreatureQueryOpcode`, `WorldSession::HandleGameObjectQueryOpcode`, `WorldSession::HandleItemQuerySingleOpcode`, `WorldSession::HandleWhoOpcode`
* Constants: `CHAT_MSG_CHANNEL`, `CMSG_MESSAGECHAT`, `CMSG_WHO`, `SMSG_ITEM_QUERY_SINGLE_RESPONSE`, `SMSG_MESSAGECHAT`, `SMSG_WHO`

## world/questhandlers.d

* Projects: CMaNGOS
* Files: `GossipDef.cpp`, `QuestHandler.cpp`
* Functions: `Player::AddQuest`, `Player::AreaExploredOrEventHappens`, `Player::CanShareQuest`, `Player::CompleteQuest`, `Player::FailQuest`, `Player::HasQuestForItem`, `Player::IncompleteQuest`, `Player::KilledMonsterCredit`, `Player::PrepareQuestMenu`, `Player::RewardQuest`, `Player::SatisfyQuest`, `Player::SendPreparedQuest`, `Player::Update`, `WorldSession::getDialogStatus`
* Constants: `SMSG_QUESTGIVER_STATUS`

## world/quests.d

* Projects: CMaNGOS
* Files: `QuestDef.cpp`
* Functions: `ObjectMgr::LoadQuests`, `Player::GetQuestLevelForPlayer`, `Quest::XPValue`
* Constants: `MAX_QUEST_LOG_SIZE`, `QUEST_OBJECTIVES_COUNT`, `QUEST_REWARDS_COUNT`, `QUEST_REWARD_CHOICES_COUNT`, `SMSG_QUESTGIVER_QUEST_INVALID`

## world/realm.d

* Projects: CMaNGOS, mangosd
* Files: `Master.cpp`, `World.cpp`
* Constants: `REALM_FLAG_OFFLINE`

## world/relations.d

* Projects: CMaNGOS
* Files: `Relations.cpp`
* Functions: `CGUnit_C::UnitReaction`, `Player::IsPvP`, `ReputationMgr::GetBaseReputation`, `ReputationMgr::ReputationToRank`, `Unit::CanAttack`, `Unit::CanAttackNow`, `Unit::GetReactionTo`, `Unit::IsEnemy`, `Unit::IsFriend`
* Constants: `FACTION_FLAG_AT_WAR`, `FACTION_TEMPLATE_FLAG_ASSIST_PLAYERS`, `FACTION_TEMPLATE_FLAG_ATTACK_PVP_ACTIVE_PLAYERS`, `PLAYER_DUEL_ARBITER`, `PLAYER_DUEL_TEAM`, `PLAYER_FLAGS`, `PLAYER_FLAGS_CONTESTED_PVP`, `PLAYER_FLAGS_FFA_PVP`, `PLAYER_FLAGS_PVP_DESIRED`, `UNIT_FIELD_FLAGS`

## world/reputation.d

* Projects: CMaNGOS
* Files: `ReputationMgr.cpp`
* Functions: `ReputationMgr::Initialize`
* Constants: `MAX_REPUTATION_LIST`, `SMSG_INITIALIZE_FACTIONS`, `SMSG_SET_FACTION_VISIBLE`

## world/reputationhandlers.d

* Projects: CMaNGOS
* Files: `MiscHandler.cpp`
* Functions: `Player::CalculateReputationGain`, `Player::GetReputationPriceDiscount`, `Player::ReputationChanged`, `Player::RewardReputation`, `ReputationMgr::LoadFromDB`, `ReputationMgr::ModifyReputation`, `ReputationMgr::SaveToDB`
* Constants: `SMSG_INITIALIZE_FACTIONS`, `SMSG_SET_FACTION_STANDING`

## world/session.d

* Projects: CMaNGOS
* Files: `CharacterHandler.cpp`, `Handler.cpp`, `WorldSocket.cpp`
* Functions: `WorldSession::HandlePlayerLogin`
* Constants: `CMSG_AUTH_SESSION`, `CMSG_PLAYER_LOGIN`, `SMSG_ADDON_INFO`, `SMSG_AUTH_CHALLENGE`, `SMSG_AUTH_RESPONSE`

## world/social.d

* Projects: CMaNGOS
* Files: `MiscHandler.cpp`
* Functions: `PlayerSocial::HasIgnore`, `PlayerSocial::LoadFromDB`, `PlayerSocial::SendFriendList`
* Constants: `CHAT_MSG_IGNORED`, `SMSG_FRIEND_STATUS`, `SOCIALMGR_FRIEND_LIMIT`, `SOCIALMGR_IGNORE_LIMIT`

## world/spellcast.d

* Projects: CMaNGOS
* Files: `Spell.cpp`
* Functions: `Spell::CalculatePowerCost`, `SpellCastTargets::read`, `SpellCastTargets::write`
* Constants: `SMSG_CAST_RESULT`, `SMSG_SPELLENERGIZELOG`, `SMSG_SPELLHEALLOG`, `SMSG_SPELLLOGMISS`, `SMSG_SPELLNONMELEEDAMAGELOG`, `SMSG_SPELL_FAILURE`, `SMSG_SPELL_GO`, `SMSG_SPELL_START`, `SPELL_ATTR_CANT_USED_IN_COMBAT`, `SPELL_ATTR_CASTABLE_WHILE_DEAD`, `SPELL_ATTR_EX2_CANT_CRIT`, `SPELL_ATTR_EX3_ALWAYS_HIT`, `SPELL_ATTR_ON_NEXT_SWING`, `SPELL_ATTR_ON_NEXT_SWING_NO_DAMAGE`

## world/spellhandlers.d

* Projects: CMaNGOS
* Files: `Spell.cpp`, `SpellEffects.cpp`, `SpellHandler.cpp`
* Functions: `GameObject::Use`, `Player::ClearCooldownForSpell`, `Player::ClearCooldownsOnLine`, `Player::HasItemFitToSpellReqirements`, `Player::UpdateFishingSkill`, `Player::_LoadSpellCooldowns`, `Player::_SaveSpellCooldowns`, `Spell::CheckCast`, `Spell::CheckItems`, `Spell::EffectEnergize`, `Spell::EffectHeal`, `Spell::EffectInstaKill`, `Spell::EffectPersistentAA`, `Spell::EffectTeleportUnits`, `Spell::EffectTransmitted`, `Spell::EffectWeaponDmg`, `Spell::SendChannelStart`, `Spell::SendChannelUpdate`, `Spell::SetTargetMap`, `Spell::SpellStart`, `Spell::cancel`, `Spell::cast`, `Spell::m_delayMoment`, `Spell::update`, `Unit::AttackerStateUpdate`, `Unit::CalculateSpellDamage`, `Unit::SpellDamageBonusDone`, `Unit::SpellHealingBonusDone`, `Unit::SpellHitResult`
* Constants: `CMSG_CANCEL_CHANNELLING`, `CURRENT_CHANNELED_SPELL`, `CURRENT_GENERIC_SPELL`, `CURRENT_MELEE_SPELL`, `FISHING_BOBBER_READY_TIME`, `MSG_CHANNEL_START`, `MSG_CHANNEL_UPDATE`, `SMSG_CLEAR_COOLDOWN`, `SMSG_FISH_NOT_HOOKED`, `SMSG_INITIAL_SPELLS`, `SMSG_SPELLINSTAKILLLOG`, `SMSG_SPELL_GO`, `SMSG_SPELL_START`, `SPELL_ATTR_EX_IS_CHANNELED`, `SPELL_AURA_MOD_DAMAGE_DONE`, `SPELL_AURA_MOD_HEALING_DONE`, `SPELL_AURA_PERIODIC_DAMAGE`, `SPELL_EFFECT_APPLY_AURA`, `SPELL_FAILED_EQUIPPED_ITEM_CLASS`, `SPELL_INTERRUPT_FLAG_MOVEMENT`, `TARGET_ALL_ENEMY_IN_AREA`, `TARGET_CASTER_COORDINATES`, `TRIGGERED_OLD_TRIGGERED`

## world/spellmods.d

* Functions: `Player::ApplySpellMod`, `SpellModifier::isAffectedOnSpell`
* Constants: `SPELL_AURA_ADD_FLAT_MODIFIER`, `SPELL_AURA_ADD_PCT_MODIFIER`

## world/spells.d

* Projects: CMaNGOS
* Constants: `SPELL_ATTR_DO_NOT_DISPLAY`, `SPELL_ATTR_EX2_ALLOW_WHILE_NOT_SHAPESHIFTED`, `SPELL_ATTR_EX_CAST_WHEN_LEARNED`, `SPELL_ATTR_PASSIVE`, `TARGET_UNIT_CASTER_PET`

## world/spline.d

* Projects: CMaNGOS, G3D
* Files: `MoveSpline.cpp`, `MoveSplineInit.cpp`
* Functions: `ByteBuffer::appendPackXYZ`, `G3D::wrap`, `MoveSpline::ComputePosition`, `MoveSpline::Initialize`, `MoveSpline::init_spline`, `MoveSpline::updateState`, `MoveSplineInit::SetFacing`, `MoveSplineInit::Stop`, `MoveSplineInitArgs::Validate`, `PacketBuilder::WriteCreate`, `PacketBuilder::WriteMonsterMove`, `SplineBase::InitLinear`
* Constants: `SMSG_MONSTER_MOVE`

## world/stats.d

* Projects: CMaNGOS
* Files: `StatSystem.cpp`
* Functions: `Player::GetHealthBonusFromStamina`, `Player::GetManaBonusFromIntellect`, `Player::GetMeleeCritFromAgility`, `Player::InitStatsForLevel`, `Player::UpdateCritPercentage`, `Player::_ApplyItemBonuses`, `Unit::m_modCritChance`
* Constants: `MOD_ATTACK_POWER`, `MOD_INCREASE_ENERGY`, `MOD_INCREASE_HEALTH`, `MOD_PERCENT_STAT`, `MOD_RANGED_ATTACK_POWER`, `MOD_RESISTANCE`, `MOD_STAT`, `SPELL_AURA_MOD_STAT`

## world/talenthandlers.d

* Projects: CMaNGOS
* Functions: `Player::AddItemsSetItem`, `Player::ApplyItemEquipSpell`, `Player::LearnTalent`, `Player::Reset_Talents`, `Player::resetTalents`, `Player::resetTalentsCost`
* Constants: `ITEM_SPELLTRIGGER_ON_EQUIP`, `PLAYER_CHARACTER_POINTS1`

## world/taxi.d

* Projects: CMaNGOS
* Files: `Taxi.cpp`
* Functions: `ObjectMgr::GetNearestTaxiNode`, `Tracker::AddRoutes`, `Tracker::Save`, `Tracker::Load`, `Tracker::Prepare`
* Constants: `PLAYER_FLIGHT_SPEED`

## world/taxihandlers.d

* Projects: CMaNGOS
* Files: `TaxiHandler.cpp`, `Player.cpp`
* Functions: `Player::ActivateTaxiPathTo`, `Player::LoadFromDB` (the saved flight), `Player::TaxiFlightResume`
* Constants: `SMSG_MONSTER_MOVE`

## world/teleport.d

* Projects: ArcEmu, CMaNGOS
* Files: `MiscHandler.cpp`, `MovementHandler.cpp`
* Functions: `BattleGround::HandleAreaTrigger`, `InstanceMap::CanEnter`, `Player::GetAreaTriggerLockStatus`, `Player::IsBeingTeleported`, `Player::SafeTeleport`, `Player::SendTransferAbortedByLockStatus`, `Player::TeleportTo`, `Unit::SendTeleportPacket`, `WorldSession::HandleAreaTriggerOpcode`, `WorldSession::HandleMoveTeleportAckOpcode`, `WorldSession::HandleMoveWorldportAckOpcode`, `WorldSession::HandleWorldTeleportOpcode`
* Constants: `ENTER_HALL_RANK`, `MSG_MOVE_TELEPORT_ACK`, `MSG_MOVE_WORLDPORT_ACK`, `SMSG_NEW_WORLD`, `SMSG_TRANSFER_PENDING`

## world/terrain.d

* Projects: CMaNGOS, Detour
* Files: `GridMap.cpp`
* Functions: `GridMap::getArea`, `GridMap::getHeight`, `GridMap::getHeightFromFloat`, `GridMap::getHeightFromUint8`, `GridMap::getLiquidLevel`, `GridMap::getLiquidStatus`, `GridMap::getTerrainType`, `GridMap::isHole`, `GridMap::loadData`, `MMapManager::loadMap`, `MMapManager::loadMapData`, `PathFinder::calculate`, `TerrainInfo::GetAreaFlag`, `TerrainInfo::GetAreaInfo`, `TerrainInfo::GetGrid`, `TerrainInfo::GetHeightStatic`, `TerrainInfo::GetZoneAndAreaId`, `TerrainInfo::IsOutdoors`, `TerrainInfo::getLiquidStatus`, `VMapManager2::getHeight`, `VMapManager2::isInLineOfSight`, `VMapManager::getHeight`
* Constants: `DEFAULT_HEIGHT_SEARCH`, `DEFAULT_WATER_SEARCH`, `INVALID_HEIGHT`, `INVALID_HEIGHT_VALUE`, `MAP_RESOLUTION`, `MAX_NUMBER_OF_GRIDS`, `SIZE_OF_GRIDS`

## world/tradehandlers.d

* Projects: CMaNGOS
* Files: `TradeHandler.cpp`
* Functions: `Item::CanBeTraded`, `Player::TradeCancel`, `TradeData::SetAccepted`
* Constants: `ITEM_FIELD_GIFTCREATOR`, `TRADE_DISTANCE`, `TRADE_SLOT_COUNT`, `TRADE_SLOT_TRADED_COUNT`

## world/unit.d

* Projects: CMaNGOS
* Functions: `Unit::DealDamage`
* Constants: `DIRECT_DAMAGE`, `SPELL_DIRECT_DAMAGE`

## world/updatefields.d

* Projects: CMaNGOS
* Files: `UpdateFields.cpp`
* Constants: `ITEM_FIELD_SPELL_CHARGES`, `MAX_BAG_SIZE`, `MAX_INSPECTED_ENCHANTMENT_SLOT`, `OBJECT_FIELD_TYPE`, `PLAYER_FIELD_MOD_DAMAGE_DONE_PCT`, `PLAYER_MAX_SKILLS`, `UNIT_FIELD_HEALTH`, `UNIT_FIELD_TARGET`

## world/weather.d

* Projects: CMaNGOS
* Files: `Weather.cpp`
* Functions: `Player::SendFineWeather`, `Weather::GetSound`, `Weather::NormalizeGrade`, `Weather::ReGenerate`
* Constants: `SMSG_WEATHER`

## world/whisper.d

* Functions: `WorldSession::HandleMessagechatOpcode`

## world/worlddata.d

* Projects: CMaNGOS, mangosd
* Functions: `GraveyardManager::GraveyardLinkKey`, `ObjectMgr::GetBaseXP`, `ObjectMgr::GetGameTele`, `ObjectMgr::GetMapEntranceTrigger`, `ObjectMgr::GetXPForLevel`, `ObjectMgr::LoadAreaTriggerTeleports`, `ObjectMgr::LoadCreatureTemplates`, `ObjectMgr::LoadCreatures`, `ObjectMgr::LoadGameTele`, `ObjectMgr::LoadItemPrototypes`, `ObjectMgr::LoadPlayerInfo`, `Player::IsActionButtonDataValid`, `WaypointManager::Load`
* Constants: `GRAVEYARD_AREALINK`, `GRAVEYARD_MAPLINK`, `MAX_LEVEL`, `SMSG_ITEM_QUERY_SINGLE_RESPONSE`
