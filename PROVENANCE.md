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

## script/follower.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/base/follower_ai.cpp`
* Functions: `FollowerAI::StartFollow`, `FollowerAI::SetFollowComplete`, `FollowerAI::SetFollowPaused`
* Constants: `MAX_PLAYER_DISTANCE`

## scripts/arathi.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/arathi_highlands.cpp`
* Functions/ScriptNames: `npc_professor_phizzlethorpe`, `npc_kinelory`

## scripts/areatriggers.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/areatrigger_scripts.cpp`
* Functions/ScriptNames: `at_huldar_miran`, `at_ravenholdt`, `at_twilight_grove`, `at_ancient_leaf`, `at_childrens_week_spot`

## scripts/ashenvale.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/ashenvale.cpp`
* Functions/ScriptNames: `npc_muglash`, `go_naga_brazier`, `npc_ruul_snowhoof`, `npc_torek`, `npc_feero_ironhand`

## scripts/azshara.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/azshara.cpp`, `AI/ScriptDevAI/scripts/kalimdor/boss_azuregos.cpp`
* Open-world round 2: ScriptDev2-classic `scripts/kalimdor/azshara.cpp`, `npc_loramus_thalipedes`; `boss_maws` walking its path as `event_arcanite_buoy` starts it
* Functions/ScriptNames: `mobs_spitelashes`, `npc_felhound_tracker`, `boss_maws`, `boss_azuregos`

## scripts/barrens.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/the_barrens.cpp`
* Functions/ScriptNames: `npc_gilthares`, `npc_taskmaster_fizzule`, `npc_twiggy_flathead`, `at_twiggy_flathead`,
  `npc_wizzlecranks_shredder`, `npc_regthar_deathgate`, `npc_gallywix`, `npc_venture_co_lookout`, `npc_foreman_silixiz`

## scripts/blackfathomdeeps.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/blackfathom_deeps/instance_blackfathom_deeps.cpp`, `blackfathom_deeps.h`
* Functions/ScriptNames: `instance_blackfathom_deeps` (`DoSpawnMobs`, `IsWaveEventFinished`), `go_fire_of_akumai`, `go_fathom_stone`

## scripts/blackrockdepths.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/blackrock_depths/instance_blackrock_depths.cpp`, `blackrock_depths.cpp`, `boss_ambassador_flamelash.cpp`, `boss_emperor_dagran_thaurissan.cpp`, `boss_general_angerforge.cpp`, `boss_high_interrogator_gerstahn.cpp`, `blackrock_depths.h`
* Functions/ScriptNames: `instance_blackrock_depths` (`DoCallNextDwarf`, `HandleBarPatrons`, `Update`), `at_ring_of_law`, `npc_grimstone`, `at_shadowforge_bridge`, `go_shadowforge_brazier`, `go_relic_coffer_door`, `go_bar_beer_keg`, `go_bar_ale_mug`, `boss_doomrel`, `npc_rocknot`, `npc_phalanx`, `boss_plugger_spazzring`, `npc_hurley_blackbreath`, `npc_ironhand_guardian`, `boss_emperor_dagran_thaurissan`, `boss_moira_bronzebeard`, `boss_ambassador_flamelash`, `boss_general_angerforge`, `boss_high_interrogator_gerstahn`, `npc_marshal_windsor`, `npc_dughal_stormwing`, `npc_tobias_seecher`, `npc_mistress_nagmara`, `SummonThelrinDnd` (27517, `npc_theldren_trigger`), `npc_grimstone` (Theldren's gladiators, `DoChallengeQuestCredit`)

## scripts/blackrockspire.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/blackrock_spire/instance_blackrock_spire.cpp`, `boss_pyroguard_emberseer.cpp`, `boss_gyth.cpp`, `boss_overlord_wyrmthalak.cpp`, `blackrock_spire.h`
* Functions/ScriptNames: `instance_blackrock_spire` (`DoSortRoomEventMobs`, `DoProcessEmberseerEvent`, `DoUseEmberseerRunes`, `DoSendNextStadiumWave`, `DoSendNextFlamewreathWave`, `Update`), `at_blackrock_spire`, `event_spell_altar_emberseer`, `go_father_flame`, `npc_rookery_hatcher`, `boss_pyroguard_emberseer`, `boss_gyth`, `boss_overlord_wyrmthalak`

## scripts/blastedlands.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/boss_kazzak.cpp`
* Functions/ScriptNames: `boss_kazzak`, `spell_mark_of_lord_kazzak` (`MarkOfLordKazzak::OnPeriodicTickEnd`)

## scripts/burningsteppes.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/burning_steppes.cpp`
* Functions/ScriptNames: `npc_grark_lorkrub`, `npc_klinfran`

## scripts/deadmines.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/deadmines/deadmines.cpp`, `instance_deadmines.cpp`, `boss_mr_smite.cpp`,
  `deadmines.h`
* Functions/ScriptNames: `spell_unarmed_woodcutter` (`UnarmedWoodcutter::OnApply`), `instance_deadmines`
  (`SetData(TYPE_IRON_CLAD_DOOR)`, `Update`: the two alarms, the guards run to the door), `boss_mr_smite`
  (`PhaseEquipStart`, `PhaseEquipProcess`, `PhaseEquipEnd`, `UpdateAI`: Nimble Reflexes, Thrash, the chest)

## scripts/darkshore.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/darkshore.cpp`
* Functions/ScriptNames: `npc_kerlonian` (with `AwakenKerlonian`), `npc_prospector_remtravel`, `npc_threshwackonator`,
  `npc_volcor`, `npc_therylune`, `npc_rabid_bear`, `npc_blackwood_warrior`, `npc_blackwood_totemic`, `go_furbolg_food`
* Open-world round 2: `npc_corrupted_furbolgAI::SeekPurification`, `event_purify_food` (`ProcessEventId_event_purify_food`)

## scripts/desolace.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/desolace.cpp`
* Functions/ScriptNames: `npc_aged_dying_ancient_kodo` (with `KodoKombobulator`), `npc_dalinda_malem`,
  `npc_melizza_brimbuzzle`, `npc_magrami_spectre`

## scripts/diremaul.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/dire_maul/instance_dire_maul.cpp`, `dire_maul.h`, `dire_maul.cpp`
* Functions/ScriptNames: `instance_dire_maul` (`SortPylonGuards`, `PylonGuardJustDied`, `ProcessForceFieldOpening`), `Update` (the ritual's failure), `ProcessDreadsteedRitualStart`, `GetRitualSymbolGuids`; `event_spells_warlock_dreadsteed`, `npc_warlock_mount_ritual`, `go_dreadsteed_quest_objects` (`DreadsteedQuestObjects`), `go_fixed_trap`, `spell_ritual_candle_aura` (`RitualCandleAura::OnCheckTarget`)

## scripts/durotar.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/durotar.cpp`, `AI/ScriptDevAI/scripts/kalimdor/orgrimmar.cpp`
* Functions/ScriptNames: `npc_lazy_peon` (with `AwakenPeon`), `npc_overlord_runthalak`, `npc_high_overlord_saurfang`

## scripts/dustwallow.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/dustwallow_marsh.cpp`
* Functions/ScriptNames: `npc_morokk`, `npc_ogron`, `npc_private_hendel`, `npc_stinky_ignatz`, `at_sentry_point`

## scripts/easternplaguelands.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/eastern_plaguelands.cpp`
* Functions/ScriptNames: `npc_eris_havenfire`

## scripts/felwood.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/felwood.cpp`
* Functions/ScriptNames: `npc_kitten` (with `CorruptedSaberVisual`), `npc_corrupt_saber`, `npc_captured_arkonarin`, `npc_arei`

## scripts/feralas.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/feralas.cpp`, `AI/ScriptDevAI/scripts/kalimdor/world_kalimdor.cpp`
  (`TYPE_FREEDOM_CREATURES`)
* Functions/ScriptNames: `npc_oox22fe`, `npc_shay_leafrunner` (with `ShaysBell`), `npc_captured_sprite_darter`,
  `go_cage_door`, `npc_kindal_moonweaver`, `spell_capture_wildkin`, `spell_capture_hippogryph`,
  `spell_capture_faerie_dragon`, `spell_capture_treant`, `spell_capture_mountain_giant` (`SpecificTargetScript::OnCheckCast`)

## scripts/gnomeregan.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/gnomeregan/instance_gnomeregan.cpp`, `gnomeregan.cpp`, `boss_thermaplugg.cpp`, `gnomeregan.h`
* Functions/ScriptNames: `instance_gnomeregan` (`DoActivateBombFace`, `DoDeactivateBombFace`), `npc_blastmaster_emi_shortfuse`, `npc_kernobee`, `boss_thermaplugg`, `go_gnomeface_button`

## scripts/hinterlands.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/hinterlands.cpp`
* Functions/ScriptNames: `npc_00x09hl`, `npc_rinji`, `spell_gammerita_turtle_camera` (`GammeritaTurtleCamera::OnCheckCast`)

## scripts/lochmodan.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/loch_modan.cpp`
* Functions/ScriptNames: `npc_miran`

## scripts/maraudon.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/maraudon/instance_maraudon.cpp`, `boss_noxxion.cpp`, `maraudon.h`
* Functions/ScriptNames: `instance_maraudon` (`Update`), `go_larva_spewer`, `boss_noxxion`

## scripts/moonglade.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/moonglade.cpp`
* Functions/ScriptNames: `npc_keeper_remulos`, `boss_eranikus` (with `ConjureDreamRift`)

## scripts/npcs.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/npcs_special.cpp`, `ScriptDevAI/scripts/world/guards.cpp`, `ScriptDevAI/scripts/world/spell_scripts.cpp`, `ScriptDevAI/base/guard_ai.cpp`
* Functions/ScriptNames: `npc_doctor`, `npc_injured_patient`, `npc_garments_of_quests`, `npc_redemption_target`, `npc_chicken_cluck`, `npc_the_cleaner`, `guard_stormwind` (open-world round 2: `guardAI::JustDied`, `guardAI_stormwind::ReceiveEmote`), `spell_dummy_npc`; open-world round 2: `npc_guardian`, `npc_advanced_target_dummy`, `npc_aoe_damage_trigger`

## scripts/razorfendowns.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/razorfen_downs/instance_razorfen_downs.cpp`, `razorfen_downs.cpp`, `razorfen_downs.h`
* Functions/ScriptNames: `instance_razorfen_downs` (`DoSpawnWaveIfCan`, `OnCreatureDeath`), `event_go_tutenkash_gong`, `npc_belnistrasz`

## scripts/razorfenkraul.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/razorfen_kraul/instance_razorfen_kraul.cpp`, `razorfen_kraul.cpp`, `razorfen_kraul.h`
* Functions/ScriptNames: `instance_razorfen_kraul`, `npc_willix_the_importer`, `npc_snufflenose_gopher`, `spell_snufflenose_command`, `spell_left_for_dead`

## scripts/redridge.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/redridge_mountains.cpp`
* Functions/ScriptNames: `npc_corporal_keeshan`

## scripts/scarletmonastery.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/scarlet_monastery/instance_scarlet_monastery.cpp`, `boss_mograine_and_whitemane.cpp`, `boss_herod.cpp`, `boss_arcanist_doan.cpp`, `scarlet_monastery.h`
* Functions/ScriptNames: `instance_scarlet_monastery`, `boss_scarlet_commander_mograine`, `boss_high_inquisitor_whitemane`, `boss_herod`, `mob_scarlet_trainee`, `boss_arcanist_doan`, `at_cathedral_entrance`

## scripts/scholomance.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/scholomance/instance_scholomance.cpp`, `boss_darkmaster_gandling.cpp`, `boss_jandice_barov.cpp`, `scholomance.cpp`, `scholomance.h`
* Functions/ScriptNames: `instance_scholomance` (`DoSpawnGandlingIfCan`, `DoRespawnEntranceRoom`, `HandleDawnGambitEvent`), `event_dawn_gambit`, `boss_darkmaster_gandling`, `boss_jandice_barov`, `npc_spectral_tutor`, `event_spell_gandling_shadow_portal` (`HandlePortalEvent`; Shadow Portal 17950's dummy: one of 17863, 17939, 17943, 17944, 17946, 17948)

## scripts/searinggorge.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/searing_gorge.cpp`
* Functions/ScriptNames: `npc_dorius_stonetender`

## scripts/shadowfang.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/shadowfang_keep/instance_shadowfang_keep.cpp`, `shadowfang_keep.cpp`, `shadowfang_keep.h`
* Functions/ScriptNames: `instance_shadowfang_keep` (`DoSpeech`, `JustDidDialogueStep`, `OnCreatureDeath`,
  `SetData(TYPE_FENRUS)`, `SetData(TYPE_VOIDWALKER)`: the Fenrus event), `npc_shadowfang_prisoner` (`WaypointReached`,
  `HandleSpeech`), `npc_deathstalker_vincent`, `mob_arugal_voidwalker` (`InitVoidWalkersGroup`, `ExecuteAction`),
  `boss_arugal` (`ExecuteAction`: the Shadow Ports, `ReceiveAIEvent`)

## scripts/silithus.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/silithus.cpp`; open-world round 2: ScriptDev2-classic `scripts/kalimdor/silithus.cpp` (`npc_anachronos_the_ancient`, `go_crystalline_tear`), CMaNGOS `ScriptDevAI/scripts/world/war_effort.cpp` (`npc_silithus_boss`)
* Functions/ScriptNames: `npc_solenor`, `npc_anachronos_the_ancient` (`aEventDialogue`, `JustDidDialogueStep`), `go_crystalline_tear`, `npc_silithus_boss` (`JustRespawned`, `JustDied`)

## scripts/silverpine.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/silverpine_forest.cpp`
* Functions/ScriptNames: `npc_deathstalker_erland`, `npc_deathstalker_faerleia`

## scripts/spells.d

* Projects: CMaNGOS
* Files: `Spells/Scripts/Scripting/ClassScripts/Warlock.cpp`, `Warrior.cpp`, `Rogue.cpp`
* Functions/ScriptNames: `spell_life_tap`, `spell_warrior_execute`, `spell_warrior_execute_damage`, `spell_preparation`,
  `spell_vanish`, `spell_improved_sap`, `CastHighestStealthRank`, `spell_curse_of_agony`, `spell_hate_to_zero`

## scripts/stonetalon.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/stonetalon_mountains.cpp`
* Functions/ScriptNames: `npc_kaya`

## scripts/stormwind.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/stormwind_city.cpp`
* Functions/ScriptNames: `npc_lady_katrana_prestor`, `npc_bartleby`, `npc_dashel_stonefist`, `npc_major_mattingly`, `npc_field_marshal_afrasiabi`, `npc_squire_rowe`, `npc_reginald_windsor`

## scripts/stranglethorn.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/stranglethorn_vale.cpp`
* Functions/ScriptNames: `mob_yenniku`

## scripts/stratholme.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/stratholme/stratholme.cpp`, `stratholmeScripts.cpp`, `boss_baroness_anastari.cpp`, `boss_cannon_master_willey.cpp`, `boss_maleki_the_pallid.cpp`, `boss_dathrohan_balnazzar.cpp`, `stratholme.h`
* Functions/ScriptNames: `instance_stratholme` (`DoSortZiggurats`, `ThazudinAcolyteJustDied`, `StartSlaughterSquare`, `DoScarletBastionDefense`, `Update`), `go_gauntlet_gate`, `go_service_gate`, `go_stratholme_postbox`, `npc_aurius`, `boss_baroness_anastari`, `boss_cannon_master_willey`, `boss_maleki_the_pallid`, `boss_dathrohan_balnazzar`, `mob_restless_soul`, `mobs_spectral_ghostly_citizen`; the gate traps (`DoGateTrap`, `DoSpawnPlaguedCritters`, `Update`)

## scripts/sunkentemple.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/sunken_temple/sunken_temple.cpp`, `sunken_templeScripts.cpp`, `sunken_temple.h`
* Functions/ScriptNames: `instance_sunken_temple` (`ProcessStatueEvent`, `DoSpawnAtalarionIfCan`, `Update`), `event_antalarion_statue_activation`, `event_avatar_of_hakkar`, `go_eternal_flame`, `at_shade_of_eranikus`, `npc_malfurion_stormrage`, `spell_summon_hakkar`,
  `spell_hex_of_jammalan` (`HexOfJammalanAura::OnApply`)

## scripts/swamp.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/swamp_of_sorrows.cpp`
* Functions/ScriptNames: `npc_galen_goodward`

## scripts/tanaris.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/tanaris.cpp`
* Open-world round 2: ScriptDev2-classic `scripts/kalimdor/tanaris.cpp`, `npc_stone_watcher_of_norgannon`
* Functions/ScriptNames: `mob_aquementas`, `npc_oox17tn`, `npc_tooga`

## scripts/teldrassil.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/teldrassil.cpp`
* Functions/ScriptNames: `npc_mist`

## scripts/thousandneedles.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/thousand_needles.cpp`
* Functions/ScriptNames: `npc_kanati`, `npc_lakota_windsong`, `npc_paoka_swiftmountain`, `npc_plucky_johnson`

## scripts/tirisfal.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/tirisfal_glades.cpp`
* Functions/ScriptNames: `go_mausoleum_door`, `go_mausoleum_trigger`, `npc_calvin_montague`

## scripts/uldaman.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/uldaman/instance_uldaman.cpp`, `boss_archaedas.cpp`, `uldaman.h`
* Functions/ScriptNames: `instance_uldaman` (`StartEvent`, `Update`, `GetClosestDwarfNotInCombat`), `event_spell_altar_boss_aggro`, `boss_archaedas`, `spell_awaken_vault_warder`, `spell_awaken_earthen_archaedas`

## scripts/ungoro.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/ungoro_crater.cpp`
* Functions/ScriptNames: `at_scent_larkorwi`, `npc_ame01`, `npc_ringo`, `npc_simone_the_inconspicuous`,
  `npc_simone_seductress`, `npc_precious_the_devourer`

## scripts/wailingcaverns.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/wailing_caverns/wailing_caverns.cpp`, `wailing_cavernsScripts.cpp`,
  `wailing_caverns.h`
* Functions/ScriptNames: `instance_wailing_caverns` (`SetData`), `npc_disciple_of_naralex` (`WaypointReached`,
  `UpdateEscortAI`: the three stops and the ritual, `AttackedBy`, `GossipHello`, `GossipSelect`)

## scripts/wareffort.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/war_effort.cpp`
* Functions/ScriptNames: `npc_war_effort` (`QuestRewarded_war_effort`, the quest ids), `go_scarab_gong` (`QuestRewarded_war_effort`, `SendBgNeutralToPlayer`)

## scripts/westernplaguelands.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/western_plaguelands.cpp`, `ScriptDevAI/scripts/world/go_scripts.cpp`
* Functions/ScriptNames: `npc_the_scourge_cauldron`, `npc_taelan_fordring`, `npc_isillien`, `npc_tirion_fordring`, `go_andorhal_tower`

## scripts/westfall.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/westfall.cpp`
* Functions/ScriptNames: `npc_defias_traitor`, `npc_daphne_stilwell`, `npc_foreman_klaven_mortwake`

## scripts/wetlands.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/eastern_kingdoms/wetlands.cpp`
* Functions/ScriptNames: `npc_mikhail`, `npc_tapoke_slim_jahn`

## scripts/winterspring.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/winterspring.cpp`
* Functions/ScriptNames: `npc_ranshalla`, `go_elune_fire`, `npc_artorius`

## scripts/zulfarrak.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/zulfarrak/instance_zulfarrak.cpp`, `zulfarrak.cpp`, `boss_zumrah.cpp`, `zulfarrak.h`
* Functions/ScriptNames: `instance_zulfarrak` (`Update`, `OnCreatureEnterCombat`, `OnCreatureEvade`), `event_go_zulfarrak_gong`, `event_spell_unlocking`, `at_zulfarrak`, `boss_zumrah` (`SetFactionTemporary`, `TEMPFACTION_TOGGLE_IMMUNE_TO_PLAYER`)

## scripts/professions.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/npc_professions.cpp`
* Functions/ScriptNames: `npc_prof_blacksmith`, `npc_prof_leather` (`GetUnlearnCostMedium`, `GetUnlearnCostLow`, `EquippedOk`, `IsEligibleSpecializeLW`); forgetting a specialization is done directly, Classic having no unlearn spells

## scripts/emeralddragons.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/bosses_emerald_dragons.cpp`
* Functions/ScriptNames: `boss_emerald_dragonAI` (as the `DreamDragon` component), `boss_emeriss`, `boss_lethon`, `npc_spirit_shade`, `boss_taerar`, `boss_ysondre`

## scripts/worldobjects.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/go_scripts.cpp`, `item_scripts.cpp`, `areatrigger_scripts.cpp`, `ScriptDevAI/scripts/kalimdor/azshara.cpp`, `stonetalon_mountains.cpp`, `ScriptDevAI/scripts/eastern_kingdoms/blasted_lands.cpp`, `hinterlands.cpp`
* Functions/ScriptNames: `go_bells`, `go_darkmoon_faire_music`, `go_elemental_rift`, `go_dragon_head`, `go_unadorned_spike`, `go_lightning`, `go_covert_ops`, `go_transpolyporter_bb` (`TrapTargetSearch`), `go_rune_of_the_defiler`, `event_arcanite_buoy`, `event_wildhammer_message`, `item_orb_of_draconic_energy`, `at_wondervolt`, `at_hive_tower`, `at_stormwind_recruiter`, `spell_wondervolt_trap`
  (`ScriptDevAI/scripts/world/spell_scripts.cpp`: `WondervoltTrap`)

## scripts/worldspells.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/spell_scripts.cpp`, `item_scripts.cpp`, `scourge_invasion.cpp`, `scourge_invasion.h`
* Functions/ScriptNames: `spell_food_animation`, `spell_drink_animation` (`FoodAnimation`, `DrinkAnimation::OnHeartbeat`),
  `spell_gameobject_call_for_help_on_usage` (`OnSuccessfulStart`), `spell_hate_to_half`, `spell_random_aggro`,
  `spell_arcane_cloaking`, `spell_stoned` (with `Spell::EffectDummy`'s 10254, Stone Dwarf Awaken Visual),
  `spell_banish_exile`, `spell_orb_of_deception` (`GetAuraScriptCustomizationValue`), `spell_scourge_strike`,
  `spell_communique_trigger`, `spell_despawner_self`
* Constants: `SPELL_VISUAL_KIT_FOOD`, `SPELL_VISUAL_KIT_DRINK`, `SPELL_COMMUNIQUE_CAMP_TO_RELAY`, `SPELL_SPIRIT_SPAWN_OUT`

## scripts/itemeffects.d

* Projects: CMaNGOS
* Files: `Spells/SpellEffects.cpp`
* Functions: the generic cases of `Spell::EffectDummy` (8063 Deviate Fish, 8213 Savory Deviate Delight, 8344
  Gnomish Universal Remote, 9976 Polly Eats the E.C.A.C., 13006 Gnomish Shrink Ray, 13120 Net-O-Matic, 13180
  Gnomish Mind Control Cap, 14537 Six Demon Bag, 15998 Capture Worg Pup, 16589 Noggenfogger Elixir, 17271 Test
  Fetid Skull, 23074, 23075, 23076 the dragonlings, 23133 Gnomish Battle Chicken, 23453 Gnomish Transporter, 23645
  Hourglass Sand, 24930 Hallow's End Treat, 26374 Elune's Candle, 26899 Give Friendship Bracers, 28414 Call of the
  Ashbringer) and of `Spell::EffectScriptEffect` (8856 Bending Shinbone, 23853 Jubling Cooldown, 24194 Uther's
  Tribute, 24195 Grom's Tribute, 24717, 24718, 24719, 24720, 24737 the costumes, 24935 Summon RC Tank, 26678 Create
  Heart Candy)

## scripts/worldmaps.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/kalimdor/world_kalimdor.cpp`, `world_kalimdor.h`, `ScriptDevAI/scripts/world/areatrigger_scripts.cpp`, `ScriptDevAI/scripts/kalimdor/moonglade.cpp`
* Functions/ScriptNames: `world_map_kalimdor` (`OnCreatureDeath`, `SetData` of `TYPE_OMEN`, `Update`), `at_murkdeep`, `go_omen_cluster`

## scripts/guards.d

* Projects: CMaNGOS
* Files: `ScriptDevAI/scripts/world/guards.cpp`, `ScriptDevAI/base/guard_ai.cpp`
* Functions/ScriptNames: `guard_bluffwatcher`, `guard_darnassus`, `guard_dunmorogh`, `guard_durotar`, `guard_elwynnforest`, `guard_ironforge`, `guard_mulgore`, `guard_orgrimmar`, `guard_teldrassil`, `guard_tirisfal`, `guard_undercity` (`guardAI::JustDied`, `DoReplyToTextEmote`)

## scripts/moltencore.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/molten_core/` (`molten_core.cpp`, `molten_core.h`,
  `molten_coreScripts.cpp`, `boss_lucifron.cpp`, `boss_magmadar.cpp`, `boss_gehennas.cpp`, `boss_garr.cpp`,
  `boss_shazzrah.cpp`, `boss_baron_geddon.cpp`, `boss_golemagg.cpp`, `boss_sulfuron_harbinger.cpp`,
  `boss_majordomo_executus.cpp`, `boss_ragnaros.cpp`)
* Functions/ScriptNames: `instance_molten_core`, `go_molten_core_rune`, `boss_lucifron`, `boss_magmadar`,
  `boss_gehennas`, `boss_garr`, `mob_firesworn`, `boss_shazzrah`, `boss_baron_geddon`, `boss_golemagg`,
  `mob_core_rager`, `boss_sulfuron`, `mob_flamewaker_priest`, `boss_majordomo`, `boss_ragnaros`

## scripts/onyxia.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/onyxias_lair/` (`instance_onyxias_lair.cpp`, `onyxias_lair.h`,
  `boss_onyxia.cpp`)
* Functions/ScriptNames: `instance_onyxias_lair`, `boss_onyxia`

## scripts/zulgurub.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/zulgurub/` (`zulgurub.cpp`, `zulgurub.h`, `zulgurubScripts.cpp`,
  `boss_venoxis.cpp`, `boss_jeklik.cpp`, `boss_marli.cpp`, `boss_thekal.cpp`, `boss_arlokk.cpp`,
  `boss_mandokir.cpp`, `boss_renataki.cpp`, `boss_hakkar.cpp`)
* Functions/ScriptNames: `instance_zulgurub`, `at_zulgurub`, `boss_venoxis`, `boss_jeklik`,
  `npc_gurubashi_bat_rider`, `boss_marli`, `boss_thekal`, `mob_zealot_lorkhan`, `mob_zealot_zath`,
  `boss_arlokk`, `npc_zulian_prowler`, `go_gong_of_bethekk`, `boss_mandokir`, `mob_ohgan`, `boss_renataki`,
  `boss_hakkar`, `npc_soulflayer`, `spell_arlokk_vanish`, `spell_renataki_vanish`, `spell_thekal_resurrect`, `spell_threatening_gaze` (`ThreateningGaze`, Mandokir's `ReceiveAIEvent`)

## scripts/blackwinglair.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/blackwing_lair/` (`blackwing_lair.cpp`, `blackwing_lair.h`,
  `boss_razorgore.cpp`, `boss_vaelastrasz.cpp`, `boss_broodlord_lashlayer.cpp`, `boss_firemaw.cpp`,
  `boss_ebonroc.cpp`, `boss_flamegor.cpp`, `boss_chromaggus.cpp`, `boss_victor_nefarius.cpp`, `boss_nefarian.cpp`)
* Functions/ScriptNames: `instance_blackwing_lair`, `at_vaelastrasz`, `boss_razorgore`, `npc_blackwing_orb`,
  `boss_vaelastrasz`, `boss_broodlord`, `boss_firemaw`, `boss_ebonroc`, `boss_flamegor`, `boss_chromaggus`,
  `boss_victor_nefarius`, `boss_nefarian`, `event_weekly_chromatic_selection` (`InitiateBreath`, `InitiateDrakonid`), `event_razorgore_possess`

## scripts/ruinsofahnqiraj.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/ruins_of_ahnqiraj/` (`ruins_of_ahnqiraj.cpp`, `ruins_of_ahnqiraj.h`,
  `ruins_of_ahnqirajScripts.cpp`, `boss_kurinnaxx.cpp`, `boss_rajaxx.cpp`, `boss_moam.cpp`, `boss_buru.cpp`,
  `boss_ayamiss.cpp`, `boss_ossirian.cpp`)
* Functions/ScriptNames: `instance_ruins_of_ahnqiraj`, `boss_kurinnaxx`, `npc_general_andorov`,
  `npc_kaldorei_elite`, `boss_moam`, `boss_buru`, `npc_buru_egg`, `boss_ayamiss`, `npc_hive_zara_larva`,
  `boss_ossirian`, `go_ossirian_crystal`, `mob_anubisath_guardian`

## scripts/templeofahnqiraj.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/kalimdor/temple_of_ahnqiraj/` (`temple_of_ahnqiraj.cpp`, `temple_of_ahnqiraj.h`,
  `boss_skeram.cpp`, `boss_bug_trio.cpp`, `boss_sartura.cpp`, `boss_fankriss.cpp`, `boss_viscidus.cpp`,
  `boss_huhuran.cpp`, `boss_twinemperors.cpp`, `boss_ouro.cpp`, `boss_cthun.cpp`, `mob_anubisath_sentinel.cpp`)
* Functions/ScriptNames: `instance_temple_of_ahnqiraj`, `at_temple_ahnqiraj`, `boss_skeram`, `boss_kri`,
  `boss_vem`, `boss_yauj`, `boss_sartura`, `boss_fankriss`, `boss_viscidus`, `boss_huhuran`, `boss_veknilash`,
  `boss_veklor`, `boss_ouro`, `npc_ouro_spawner`, `npc_ouro_mound`, `npc_ouro_scarab`, `npc_ouro_trigger`,
  `boss_eye_of_cthun`, `boss_cthun`, `mob_giant_claw_tentacle`, `mob_anubisath_sentinel`, `mob_anubisath_defender`, `event_cthun_reset`, `at_stomach_cthun`; C'Thun's stomach (`DoSpawnTentacles`, `HandleWeaken`, `EnterEvadeMode`, `ExitStomach`, `CThunMouthTentacle`, `DigestiveAcidPeriodic`)

## scripts/naxxramas.d

* Projects: CMaNGOS
* Files: `AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/` (`naxxramas.cpp`, `naxxramas.h`, `boss_anubrekhan.cpp`,
  `boss_faerlina.cpp`, `boss_maexxna.cpp`, `boss_noth.cpp`, `boss_heigan.cpp`, `boss_loatheb.cpp`,
  `boss_razuvious.cpp`, `boss_gothik.cpp`, `boss_four_horsemen.cpp`, `boss_patchwerk.cpp`, `boss_grobbulus.cpp`,
  `boss_gluth.cpp`, `boss_thaddius.cpp`, `boss_sapphiron.cpp`, `boss_kelthuzad.cpp`)
* Functions/ScriptNames: `instance_naxxramas`, `at_naxxramas`, `go_anub_door`, `go_sapphiron_birth`,
  `boss_anubrekhan`, `boss_faerlina`, `boss_maexxna`, `npc_web_wrap`, `boss_noth`, `boss_heigan`,
  `npc_diseased_maggot`, `boss_loatheb`, `boss_razuvious`, `boss_gothik`, `boss_lady_blaumeux`,
  `boss_alexandros_mograine`, `boss_thane_korthazz`, `boss_sir_zeliek`, `boss_patchwerk`, `boss_grobbulus`,
  `boss_gluth`, `boss_stalagg`, `boss_feugen`, `boss_thaddius`, `boss_sapphiron`, `boss_kelthuzad`,
  `npc_icecrown_guardian`, `npc_stoneskin_gargoyle`, `npc_living_poison`, `event_naxxramas` (`DoHandleEvent`, the shackles check of `Update`), `npc_invible_man` (`npc_invisible_manAI`, `WebWrapMaexxna`), `spell_anchor`

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

## world/alterac.d

* Projects: CMaNGOS
* Files: `BattleGroundAV.cpp`, `BattleGroundAV.h`
* Functions: `BattleGroundAV::Reset`, `Update`, `HandleKillPlayer`, `HandleKillUnit`, `HandlePlayerClickedOnFlag`, `ProcessPlayerAssaultsPoint`, `ProcessPlayerDefendsPoint`, `ProcessPlayerDestroyedPoint`, `ChangeMineOwner`, `UpdateScore`, `EndBattleGround`, `GetPrematureWinner`, `HandleAreaTrigger`
* Not from an emulator: the bonus honor units of the general, captain and towers (Wowpedia "Honor system (pre-2.0 formulas)")

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
* Also: `Aura::PeriodicTick`'s `SPELL_AURA_PERIODIC_LEECH` (`SendSpellNonMeleeDamageLog`, periodic) and `SPELL_AURA_PERIODIC_MANA_LEECH`, `Unit::SendPeriodicAuraLog`'s mana leech format, `Aura::HandleFeignDeath`, `Aura::HandleAuraModTotalThreat`, `Aura::HandleAuraTrackCreatures`, `Aura::HandleAuraTrackResources`, `Unit::CalculateDamageAbsorbAndResist`'s `SPELL_AURA_SPLIT_DAMAGE_FLAT`
* Also: `Aura::HandleAuraTransform` and `Unit::RestoreDisplayId` (a player's), `Unit::Heartbeat` and
  `WorldObject::GetHeartbeatDuration` (`Aura::OnHeartbeat`), `Aura::OnPeriodicTickEnd`, `SpellAuraHolder` removal
  (`AURA_REMOVE_BY_EXPIRE`), `Aura::PeriodicTick`'s `SPELL_AURA_PERIODIC_MANA_LEECH` from a creature
* Not from an emulator: `SPELLMOD_CHARGES` on a cast's aura (Improved Shield Block's tooltip), the health Last
  Stand's `MOD_INCREASE_HEALTH` aura grants and takes back (its tooltip), one shapeshift aura at a time (a stance
  ends the one before), a finisher's aura amounts by its combo points, Improved Sprint's purge
* Also: a `SpellAuraHolder` per target with only the effects at it (`Spell::DoSpellHitOnUnit`)

## world/aurastate.d

* Projects: CMaNGOS
* Files: `SpellAuraDefines.h`, `Unit.cpp`
* Functions: `Unit::ModifyAuraState`, `Unit::Update` (the health state)
* Constants: `AURA_STATE_DEFENSE`, `AURA_STATE_HEALTHLESS_20_PERCENT`, `AURA_STATE_FROZEN`, `AURA_STATE_JUDGEMENT`,
  `AURA_STATE_HUNTER_PARRY`, `UNIT_FIELD_AURASTATE`

## world/auras.d

* Projects: CMaNGOS
* Files: `SpellAuras.cpp`
* Functions: `SpellAuraHolder::Update`, `Unit::AddSpellAuraHolder`, `SpellAuraHolder::SetHeartbeatResist`, `SpellAuraHolder::UpdateHeartbeatResist`
* Constants: `MAX_AURAS`, `MAX_POSITIVE_AURAS`, `SPELL_ATTR_NO_AURA_CANCEL`, `UNIT_FIELD_AURA`
* Also: `Aura::HandleAuraModStalked` (`UNIT_DYNFLAG_TRACK_UNIT`), `Unit::SetFeignDeath` (`UNIT_DYNFLAG_DEAD`), `Aura::HandleAuraUntrackable` (`UNIT_VIS_FLAG_UNTRACKABLE`), `Aura::HandleAuraModScale` (`ApplyPercentModFloatValue`), `Aura::HandleInvisibilityDetect` (the strongest detection of a type)
* Also: `SpellStacker::IsSpellStackableWithSpellForDifferentCasters`, `SpellStacker::IsStackableAuraEffect`, `SpellAuraHolder::ModStackAmount`, `SpellAuraHolder::SetStackAmount` (the same spell from two casters)

## world/battleground.d

* Projects: ArcEmu, CMaNGOS, MaNGOS
* Files: `BattleGroundHandler.cpp`
* Functions: `BattleGround::AddPlayer`, `BattleGround::EndBattleGround`, `BattleGround::EventPlayerLoggedOut`, `BattleGround::HandleKillPlayer`, `BattleGround::RemovePlayerAtLeave`, `BattleGround::SendMessageToAll`, `BattleGround::Update`, `BattleGroundMap::Update`, `BattleGroundMgr::BuildPvpLogDataPacket`, `BattleGroundMgr::SendBattleGroundList`, `BattleGroundMgr::SendToBattleGround`, `BattleGroundMgr::ToggleTesting`, `CBattleground::Close`, `Creature::CanInteractWithBattleMaster`, `Group::CanJoinBattleGroundQueue`, `Player::CanJoinToBattleground`, `Player::LeaveBattleground`, `Player::LoadFromDB`, `Player::TeleportToBGEntryPoint`, `Player::_LoadBGData`, `Player::_SaveBGData`, `WorldSession::LogoutPlayer`
* Constants: `BG_EVENT_DOOR`, `BG_EVENT_NONE`, `CHAT_MSG_BATTLEGROUND`, `CMSG_AREA_SPIRIT_HEALER_QUEUE`, `CMSG_BATTLEFIELD_PORT`, `MAX_OFFLINE_TIME`, `MSG_BATTLEGROUND_PLAYER_POSITIONS`, `MSG_PVP_LOG_DATA`, `SMSG_AREA_SPIRIT_HEALER_TIME`, `SMSG_GROUP_JOINED_BATTLEGROUND`, `SMSG_INIT_WORLD_STATES`, `SMSG_MESSAGECHAT`, `SOUND_BG_START`, `SPELL_ID_BATTLEGROUND_DESERTER`, `TEAM_INVALID`, `TIME_TO_AUTOREMOVE`
* Not from an emulator: `bonusHonor`, a bonus honor unit by the player's bracket (Wowpedia "Honor system (pre-2.0 formulas)"; docs/FORMULAS.md, "Honor"); the units of Warsong Gulch (warsong.d) and Arathi Basin (arathi.d) from the same page

## world/bgqueue.d

* Projects: ArcEmu, CMaNGOS
* Files: `BattleGroundHandler.cpp`
* Functions: `BattleGround::RemovePlayerAtLeave`, `BattleGroundMgr::BuildBattleGroundStatusPacket`, `BattleGroundMgr::GetBattleGroundBracketIdFromLevel`, `BattleGroundMgr::ToggleTesting`, `BattleGroundQueue::BuildBattleGroundListPacket`, `BattleGroundQueue::GetAverageQueueWaitTime`, `BattleGroundQueueItem::Update`, `WorldSession::LogoutPlayer`
* Constants: `CMSG_BATTLEFIELD_PORT`, `CMSG_LEAVE_BATTLEFIELD`, `COUNT_OF_PLAYERS_TO_AVERAGE_WAIT_TIME`, `INVITATION_REMIND_TIME`, `INVITE_ACCEPT_WAIT_TIME`, `MAX_BATTLEGROUND_BRACKETS`, `PLAYER_MAX_BATTLEGROUND_QUEUES`, `SMSG_BATTLEFIELD_LIST`, `SMSG_BATTLEFIELD_STATUS`, `SMSG_GROUP_JOINED_BATTLEGROUND`

## world/caster.d

* Projects: CMaNGOS, vmangos
* Functions: `Unit::GetSpellModOwner`, `Unit::GetCritChance` (a creature's 5% base), `Unit::SpellCriticalDamageBonus`, `Unit::SpellBaseDamageBonusDone`, `Unit::SpellBaseHealingBonusDone`
* Moved here (2026-11-20): a player's damage factors, crit chance and damage, target resistance and hit bonus hooks from `spellhandlers.d`; a pet's and a totem's owner's modifiers from `creaturecasting.d` (`petModOwner`, the totem's `effectMod`)

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

## world/classspells.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`, `SpellAuras.cpp`, `Spell.cpp`, `UnitAuraProcHandler.cpp`, `Unit.cpp`,
  `Spells/Scripts/Scripting/ClassScripts/*.cpp`
* Functions: `Spell::EffectSchoolDMG` (Bloodthirst, Shield Slam, Conflagrate, Ferocious Bite), `Spell::EffectDummy` (Cold Snap,
  Enrage, Holy Shock, Judgement of Command, Flametongue Weapon and Totem procs, Touch of Weakness),
  `Spell::EffectScriptEffect` (Holy Light, Flash of Light), `Spell::EffectHeal` (Swiftmend),
  `Spell::EffectWeaponDmg` (Ambush), `Spell::CheckCast` (Conflagrate, Hammer of Wrath),
  `Spell::Prepare` (`AddPrecastSpell`: Weakened Soul, Forbearance, Recently Bandaged; Holy Nova's heal),
  `Spell::ProcSpellAuraTriggers`, `Spell::DoSpellHitOnUnit` (Bloodthirst's aura), `Aura::HandlePeriodicDamage` (Rip,
  Rupture), `Aura::HandleManaShield`, `Aura::HandleAuraModStun` (Wyvern Sting), `Aura::TriggerSpell` (Frenzied
  Regeneration), `SpellAuraHolder::_AddSpellAuraHolder`, `_RemoveSpellAuraHolder` (seals' aura state),
  `Unit::HandleDummyAuraProc` (Seal of Righteousness, Ignite, Combustion, Master of Elements, Vampiric Embrace),
  `Unit::HandleProcTriggerSpellAuraProc` (Deep Wounds, Lightning Shield, Illumination, Blessed Recovery, Ruthlessness,
  Seal Fate), `Unit::HandleOverrideClassScriptAuraProc` (Nightfall), `Unit::ProcDamageAndSpell` (the reactive states),
  `Unit::UpdateReactives`, `Unit::ClearAllReactives`, `Player::RemoveSomeCooldown`, `SpellMgr::GetSpellSpecific`,
  `SpellStacker::IsStackableAuraEffect` (a helpful spell's ranks), `Unit::CalculateLevelPenalty`,
  `Unit::SpellBaseDamageBonusDone`
* Functions/ScriptNames: `spell_judgement`, `spell_judgement_of_command`, `spell_judgement_of_light_intermediate`,
  `spell_judgement_of_wisdom_intermediate`, `spell_swiftmend`, `spell_curse_of_doom`, `spell_power_infusion`,
  `spell_shatter_mage`, `spell_retaliation_warrior`, `spell_blessing_of_light`, `spell_healing_way`, `spell_seal_of_the_crusader`, `spell_shadowguard`, `spell_blizzard`
* Constants: `IsSealSpell`, `REACTIVE_TIMER_START`, `SPELL_ATTR_EX_DRAIN_ALL_POWER`, `TRIGGERED_IGNORE_HIT_CALCULATION`
* Not from an emulator (2026-11-20, from the 1.12 tooltips and data; tested in world/realclass_paladin_shaman_druid.d):
  Seal of Righteousness' swing damage (the tooltip's expression: its amount by the weapon's speed in hundredths) and
  Improved Seal of Righteousness on it; Blessing of Light by the heal spell's own coefficient; Eye for an Eye (its
  share of a spell's crit, at most half the paladin's health); a spell's `TargetCreatureType` at its target; a dummy
  effect's spell spending its caster's charged modifiers (Divine Favor by Holy Light's heal); Holy Shield's 20% more
  threat; Stormstrike's charges (17364, of no family); a spell's crit damage bonus by its modifiers (Elemental Fury,
  Vengeance); heals' threat by their modifiers (Healing Grace, Subtlety, Improved Tranquility); a cast's end as a proc
  (Elemental Focus); a missile's charged modifiers spent as it lands (Elemental Mastery's crit); a totem's spells and
  auras by its owner's talents (Enhancing, Guardian, Restorative Totems, Totemic Mastery, Call of Flame, Improved Fire
  Totems), its periodic spells cast (Fire Nova, Magma, Earthbind) and its weapon enchantments given to the party;
  Improved Weapon Totems' masks (its tooltip, not `spell_affect`); the passives bound to a weapon, a shield or a
  shapeshift form on while those are; a druid's forms (their passives, Moonkin Aura, Bear Form's threat), Predatory
  Strikes, Leader of the Pack, Furor, Heart of the Wild's forms, Enrage's combat state; a spell that neither hurts nor
  heals procs as it lands (Improved Enrage)
* Not from an emulator (the 1.12.1 tooltips and data, docs/FORMULAS.md "Class rules from the tooltips"): Arcane
  Concentration's Blizzard ticks, the Wards' reflection by Improved Fire Ward and Frost Warding, Magic Absorption,
  Permafrost's and the curses' slow (`classEffectMod`), Pyroclasm, Improved Drain Mana, Drain Soul's Soul Siphon,
  Shadow Trance's charge, Create Healthstone and Improved Healthstone, Spirit of Redemption, Eye of Kilrogg
  (`summonPossessedEffect`)
* Not from an emulator: Add Target Trigger talents roll once a target, the caster only alone (Relentless Strikes' tooltip); Ruthlessness and Seal Fate cast once, after the finishing move

## world/classspelltests.d

* Projects: CMaNGOS (the spells' fields as the world database has them)

## world/clientdata.d

* Projects: CMaNGOS, mangosd
* Files: `DBCStores.cpp`, `DBCStructure.h`, `DBCfmt.h`, `SpellMgr.cpp`
* Functions: `MapEntry::IsBattleGround`, `MapEntry::IsContinent`, `MapEntry::IsDungeon`, `MapEntry::IsRaid`, `MapManager::IsValidMapCoord`, `Player::InitDisplayIds`, `Player::TeamForRace`
* Constants: `CLASSMASK_ALL_PLAYABLE`, `MAX_OUTFIT_ITEMS`, `MAX_SKILL_STEP`, `MAX_TALENT_RANK`, `RACEMASK_ALL_PLAYABLE`, `SECTION_FLAG_UNAVAILABLE`, `SKILL_FLAG_MAXIMIZED`
* Not from an emulator: `instanceResets`, `resetIntervalDays` (Classic Era's MapDifficulty.db2, `tools/fetch-instance-resets.py`; docs/FORMULAS.md)
* Not from an emulator: `procOptions`, `ProcOptions` (Classic Era's SpellAuraOptions.db2, `tools/fetch-procs.py`; docs/FORMULAS.md, "Procs")

## world/combat.d

* Projects: CMaNGOS
* Files: `Unit.cpp`
* Functions: `Player::RewardRage`, `Unit::CalculateEffectiveMagicResistancePercent`, `Unit::RollMagicResistanceMultiplierOutcomeAgainst`, `WorldObject::HasInArc`
* Constants: `ATTACK_DISPLAY_DELAY`, `ATTACK_DISTANCE`, `BASE_MELEERANGE_OFFSET`, `CLASSMASK_WAND_USERS`, `CONFIG_UINT32_WORLD_BOSS_LEVEL_DIFF`, `MELEE_LEEWAY`, `SMSG_ATTACKERSTATEUPDATE`, `SMSG_ATTACKSTART`, `SMSG_ATTACKSTOP`, `SPELL_PARTIAL_RESIST_DISTRIBUTION`, `TYPEID_PLAYER`, `UNIT_FIELD_COMBATREACH`, `UNIT_FIELD_MINDAMAGE`, `UNIT_FLAG_PLAYER_CONTROLLED`
* Not from an emulator: `armorAgainst`, the armor a blow ignores (Serrated Blades' tooltip and data)
* Not from an emulator: the attack table's chances (`missChance`, `dodgeChance`, `parryChance`, `blockChance`,
  `critChance` with `auraCritSuppression`, `glanceChance`), from Blizzard's statements and Classic Era's
  measurements (Magey's "Attack-table"); no dodge of ranged attacks (the 1.12 tooltips of Dodge, Parry and Block);
  `rollPartialResist`, `fullResistChance` and `partiallyResisted` by Blizzard's resistance page (its five published
  rows of `partialResistRows` checked; the rows between still CMaNGOS's fit). docs/FORMULAS.md, "The melee attack
  table", "Ranged attacks: no dodge", "Spell resistance". Still CMaNGOS's: `crushChance`, casters' glancing,
  `effectiveResistPercent`'s level bonus.

## world/crowdcontrol.d

* Projects: CMaNGOS
* Files: `Unit.cpp`, `Player.cpp`, `Spell.cpp`, `SpellAuras.cpp`, `FleeingMovementGenerator.cpp`, `ConfusedMovementGenerator.cpp`
* Functions: `Unit::SetFleeing`, `Unit::SetConfused`, `Unit::SetStunned`, `Player::UpdateClientControl`, `Spell::CheckCasterAuras`, `Aura::HandleModFear`, `Aura::HandleModConfuse`
* Constants: `SMSG_CLIENT_CONTROL_UPDATE`, `UNIT_FLAG_FLEEING`, `UNIT_FLAG_CONFUSED`, `UNIT_FLAG_SILENCED`, `UNIT_FLAG_PACIFIED`, `UNIT_FLAG_DISARMED`, `SPELL_FAILED_STUNNED`, `SPELL_FAILED_SILENCED`, `SPELL_FAILED_PACIFIED`, `SPELL_FAILED_FLEEING`, `SPELL_FAILED_CONFUSED`, `SPELL_PREVENTION_TYPE_SILENCE`, `SPELL_PREVENTION_TYPE_PACIFY`

## world/combathandlers.d

* Projects: CMaNGOS
* Files: `CombatHandler.cpp`
* Functions: `BattleGround::HandleKillPlayer`, `Player::CastItemCombatSpell`, `Player::Update`, `Player::UpdateCombatSkills`, `Unit::Attack`, `Unit::AttackStop`, `Unit::DealDamage`, `Unit::Kill`, `Unit::Update`
* Constants: `CMSG_ATTACKSTOP`, `CMSG_ATTACKSWING`, `CMSG_SETSHEATHED`, `SMSG_ATTACKSTOP`, `SMSG_CANCEL_COMBAT`, `UNIT_FLAG_IN_COMBAT`, `UNIT_STAT_MELEE_ATTACKING`
* Not from an emulator: a weapon enchantment's proc chance with its spell's `SPELLMOD_CHANCE_OF_SUCCESS` (Improved Poisons' tooltip)

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
* Also: `CreatureLinkingHolder::DoCreatureLinkingEvent` (the respawn flags in dungeon copies), `Creature::Respawn`, `PoolManager::UpdatePool` (a pooled spawn's respawn rolls its pool again)
* Not from an emulator: `raidResetDays` (MapDifficulty.db2's `ResetInterval`, patch 1.9.0's days), `instanceLimitReached` and `tooManyInstances` (five copies an hour, Blizzard's statement) (docs/FORMULAS.md)

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
* Not from an emulator: crit, dodge, parry and block chances from its auras; a pet's stats from its auras (`showPetStats`); the ticks that heal it or give it power, whoever cast them (`selfTick`: Mend Pet, Spirit Bond, Consume Shadows)

## world/creatureprocs.d

* Projects: CMaNGOS (the proc checks it shares with world/procs.d: `SpellMgr::IsSpellProcEventCanTriggeredBy`,
  `Aura::CanProcFrom`; `spell_proc_event`)
* Not from an emulator: a pet's Proc Trigger Spell auras on its swings and spell hits, their chance by its owner's
  `SPELLMOD_CHANCE_OF_SUCCESS` (Frenzy's tooltip and data)

## world/creatureai.d

* Projects: CMaNGOS, mangosd
* Files: `CombatManager.cpp`, `CreatureAI.cpp`, `ThreatManager.cpp`, `UnitAI.cpp`
* Functions: `CombatManager::IsEvadingHome`, `CombatManager::IsInEvadeMode`, `CreatureAI::HandleAssistanceCall`, `CreatureAI::OnCallForHelp`, `HostileRefManager::threatAssist`, `Unit::CanAssistInCombatAgainst`, `Unit::CanJoinInAttacking`, `Unit::RemoveAllAurasOnEvade`, `UnitAI::DetectOrAttack`, `CombatManager::StartEvadeTimer`, `CombatManager::TriggerCombatTimer`, `CombatManager::Update`, `CombatManager::m_combatTimer`, `CombatManager::m_evadeTimer`, `Creature::CallAssistance`, `Creature::RegenerateAll`, `Creature::Update`, `FactionTemplateEntry::IsNeutralToAll`, `HomeMovementGenerator::Finalize`, `ThreatContainer::selectNextVictim`, `ThreatManager::addThreat`, `Unit::Attack`, `Unit::EvadeTimerExpired`, `Unit::SelectHostileTarget`, `UnitAI::AttackStart`, `UnitAI::AttackedBy`, `UnitAI::CheckForHelp`, `UnitAI::EnterEvadeMode`, `UnitAI::MoveInLineOfSight`, `UnitAI::UpdateAI`
* Constants: `AI_REACTION_HOSTILE`, `COMBAT_MANAGER_TICK`, `CONFIG_FLOAT_LEASH_RADIUS`, `CREATURE_EXTRA_FLAG_AGGRO_ZONE`, `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT`, `CREATURE_EXTRA_FLAG_NO_CALL_ASSIST`, `FACTION_TEMPLATE_RESPOND_TO_CALL_FOR_HELP`, `SPELL_ATTR_EX_NO_THREAT`, `SPELL_ATTR_EX2_NO_INITIAL_THREAT`, `EVADE_HOME`, `REGEN_TIME_FULL_UNIT`, `STATE_SUPPRESSED`, `UNIT_STAT_MELEE_ATTACKING`, `UNIT_STAT_STUNNED`
* Also: `Spell::EffectTaunt`, `ThreatManager::TauntUpdate` and the taunt states (`taunt`, `tauntedBy`), `Unit::CombatStop`'s deleted hostile references (`forget`), `MotionMaster::MoveDistract` (`distract`)
* Not from an emulator: `aggroRadius` (Warcraft Wiki "Aggro radius": 5 to 45 yards, a yard a level), `pursuitTime` (the leash time by level, measured on Classic Era) (docs/FORMULAS.md)

## world/creatureevents.d

* Projects: CMaNGOS, EventAI
* Files: `CreatureEventAI.cpp`, `GridNotifiers.h`, `Object.cpp`, `SpellMgr.h`, `UnitAI.cpp`
* Functions: `CreatureEventAI::GetTargetByType`, `FriendlyEligibleDispelInRangeCheck`, `FriendlyMissingBuffInRangeInCombatCheck`, `FriendlyMissingBuffInRangeNotInCombatCheck`, `IsSpellRemovedOnEvade`, `Spell::CalculatePowerCost`, `Unit::SelectAttackingTarget`, `UnitAI::DoFindFriendlyEligibleDispel`, `UnitAI::DoFindFriendlyMissingBuff`, `Unit::isInBackInMap`, `Unit::isInFrontInMap`, `WorldObject::CalculateSpellEffectValue`
* Constants: `SELECT_FLAG_NOT_IN_MELEE_RANGE`, `SELECT_FLAG_POWER_MANA`, `SELECT_FLAG_RANGE_RANGE`, `SELECT_FLAG_USE_EFFECT_RADIUS`, `SPELL_ATTR_EX_AURA_STAYS_AFTER_COMBAT`, `SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL`, `SPELL_ATTR_SS_IGNORE_EVADE`

## world/creaturecasting.d

* Projects: CMaNGOS, EventAI
* Functions: `Spell::CheckRange`, `Spell::cast`, `Spell::prepare`, `UnitAI::DoCastSpellIfCan`, `UnitAI::DoFlee`, `Unit::SetFleeing`, `Unit::SetInCombatWith` (the critter flee), `CreatureAI::CreatureAI`, `CreatureAI::TimedFleeingEnded`, `PanicMovementGenerator::Update`
* Constants: `CreatureStaticFlags::NO_MELEE_FLEE`, `CONFIG_UINT32_CREATURE_FAMILY_FLEE_DELAY`, `ORDER_CRITTER_FLEE`, `ACTION_T_FLEE_FOR_ASSIST`, `CAST_FORCE_TARGET_SELF`, `EVENT_T_FRIENDLY_HP`, `SMSG_SPELL_FAILURE`, `SMSG_SPELL_GO`, `SPELL_EFFECT_APPLY_AURA`, `SPELL_EFFECT_HEAL`, `TEMPSPAWN_TIMED_OOC_DESPAWN`, `TEMPSPAWN_TIMED_OOC_OR_DEAD_DESPAWN`, `UNIT_STAT_NO_COMBAT_MOVEMENT`
* Also: `Spell::EffectSendEvent` (a creature's `SPELL_EFFECT_SEND_EVENT`), `Unit::RemoveAura` (its script told, `AuraRemoved`)
* Also: `TARGET_ENUM_UNITS_SCRIPT_AOE_AT_SRC_LOC` (`Spell::SetTargetMap`, `SPELL_TARGETS_ALL`), `Spell::OnCheckTarget`
* Also: `Creature::DoFleeToGetAssistance` (`SPELL_AURA_PREVENTS_FLEEING`)
* Not from an emulator: a pet's spells by its owner's spell modifiers (`petModOwner`: effects, damage, cast time, duration), its own damage done on its spells, its area auras on itself, the threat effect on a creature, `TARGET_UNIT_CASTER_MASTER`
* Also: vmangos's `Spell::CheckPower` (a creature without a mana pool casts its mana spells; no creature pays another power)
* Also: `Spell::DoSpellHitOnUnit` (a creature hit by a creature's spell: its AI's `SpellHit`), `CHAT_TYPE_ZONE_YELL`
  (`DoScriptText`: heard in the whole zone; a dungeon's copy)
* Moved out (2026-11-20): its effect switch to `spelleffects.d`, its damage, heals and drains to `spelldamage.d`, its auras to `spellauras.d`

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
* Constants: `SCRIPT_EXEC_PARAM_UNIQUE_BY_SOURCE`, `SCRIPT_EXEC_PARAM_UNIQUE_BY_TARGET`, `FORCED_MOVEMENT_RUN`, `SCRIPT_COMMAND_MOVE_TO`, `SCRIPT_COMMAND_RESPAWN_GAMEOBJECT`, `SCRIPT_COMMAND_TERMINATE_SCRIPT`, `SCRIPT_FLAG_BUDDY_AS_TARGET`, `SCRIPT_FLAG_BUDDY_BY_GUID`, `SPELL_EFFECT_SEND_EVENT`, `TYPEMASK_CREATURE_OR_GAMEOBJECT`
* Also: `InstanceData::OnObjectCreate` (an object the script spawns, told to the dungeon's script)

## world/death.d

* Projects: CMaNGOS
* Files: `MiscHandler.cpp`, `NPCHandler.cpp`, `QueryHandler.cpp`
* Functions: `GraveyardManager::GetClosestGraveYard`, `Player::KillPlayer`, `Player::Update`, `Player::UpdateCorpseReclaimDelay`, `Player::getCorpseReclaimDelayHelper`, `Unit::Kill`, `WorldSession::LogoutPlayer`
* Constants: `CORPSE_RECLAIM_DELAY`, `DEATH_EXPIRE_STEP`, `PLAYER_FLAGS_GHOST`, `TEAM_INVALID`

## world/defines.d

* Projects: CMaNGOS
* Files: `ItemPrototype.h`, `Player.h`, `SharedDefines.h`
* Constants: `INVENTORY_SLOT_BAG_0`, `MAX_ACTION_BUTTONS`, `MAX_POWERS`, `NULL_BAG`, `NULL_SLOT`, `PLAYER_EXPLORED_ZONES_SIZE`, `UNIT_FIELD_FLAGS`, `UNIT_FLAG_FLEEING`, `UNIT_FLAG_LOOTING`

## world/diminishing.d

* Not from an emulator: diminishing returns in PvP from Blizzard's patch notes 1.4.0 to 1.11.0 (docs/FORMULAS.md,
  "Diminishing returns").

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

## world/effecthandlers.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`, `SpellAuras.cpp`, `Spell.cpp`, `Unit.cpp`, `GameObject.cpp`, `MotionMaster.cpp`
* Functions: `Spell::EffectThreat`, `Spell::EffectTaunt`, `Spell::EffectSanctuary`, `Spell::EffectCharge`, `MotionMaster::MoveCharge`, `Spell::EffectLeapForward` (and `TARGET_LOCATION_CASTER_FRONT_LEAP`'s steps in `Spell::SetTargetMap`), `Spell::EffectStuck`, `Spell::EffectPowerBurn`, `Spell::EffectPowerDrain`, `Spell::EffectHealthLeech`, `Spell::EffectHealMaxHealth`, `Spell::EffectAddExtraAttacks`, `Unit::DoExtraAttacks`, `Spell::EffectDispelMechanic`, `Spell::EffectDistract`, `Spell::EffectSummonObject`, `GameObject::Update` (traps), `GameObject::Use` (traps), `Unit::CombatStop`, `Aura::HandleFeignDeath`, `Unit::SetFeignDeath`, `HostileRefManager::threatTemporaryFade`, `Aura::HandleAuraTrackCreatures`, `Aura::HandleAuraTrackResources`, `Aura::PeriodicTick` (`SPELL_AURA_PERIODIC_LEECH`, `SPELL_AURA_PERIODIC_MANA_LEECH`), `Unit::HandleProcTriggerDamageAuraProc`, `Unit::CalculateDamageAbsorbAndResist` (`SPELL_AURA_SPLIT_DAMAGE_FLAT`)
* Constants: `BASE_CHARGE_SPEED`, `SMSG_SPELLLOGEXECUTE`, `SMSG_FEIGN_DEATH_RESISTED`, `SMSG_GAMEOBJECT_SPAWN_ANIM_OBSOLETE`, `SMSG_MONSTER_MOVE`, `SPELL_EFFECT_ATTACK_ME`, `SPELL_EFFECT_SUMMON_OBJECT_SLOT1`, `SPELLMOD_MULTIPLE_VALUE`, `PLAYER_TRACK_CREATURES`, `PLAYER_TRACK_RESOURCES`, `PROC_EX_BLOCK` (`spell_proc_event` of Holy Shield and Blessing of Sanctuary)

## world/environment.d

* Projects: CMaNGOS
* Files: `MovementHandler.cpp`, `World.cpp` (`MirrorTimer.*.Max`, `EnvironmentalDamage.Min/Max`, `Rate.Damage.Fall`)
* Functions: `MirrorTimer` (`Start`, `Stop`, `SetScale`, `SetDuration`, `SetFrozen`, `Update`, `FetchStatus`), `Player::UpdateMirrorTimers`, `Player::CheckMirrorTimerActivation`, `Player::CheckMirrorTimerDeactivation`, `Player::OnMirrorTimerExpirationPulse`, `Player::GetMirrorTimerMaxDuration`, `Player::SendMirrorTimers`, `Player::SendMirrorTimerStart`, `Player::SendMirrorTimerStop`, `Player::SetEnvironmentFlags`, `Player::UpdateTerainEnvironmentFlags`, `Player::SetWaterBreathingIntervalMultiplier`, `Player::GetWaterBreathingInterval`, `Player::EnvironmentalDamage`, `Player::HandleFall`, `Player::UpdateFallInformationIfNeed`, `Player::SetFallInformation`, `Unit::SendEnvironmentalDamageLog`, `Unit::GetCollisionHeight`, `Aura::HandleWaterBreathing`, `Aura::HandleModWaterBreathing`, `WorldSession::HandleMoverRelocation` (below -500), `WorldSession::ProcessMovementInfo`
* Constants: `EnvironmentFlags`, `EnvironmentalDamageType`, `MAP_ALL_LIQUIDS`, `SMSG_START_MIRROR_TIMER`, `SMSG_STOP_MIRROR_TIMER`, `SMSG_ENVIRONMENTALDAMAGELOG`, `AURA_INTERRUPT_FLAG_UNDERWATER_CANCELS`, `AURA_INTERRUPT_FLAG_ABOVEWATER_CANCELS`

## world/eventai.d

* Projects: CMaNGOS, EventAI
* Files: `CreatureEventAI.cpp`
* Functions: `CreatureEventAI::CheckEvent`, `CreatureEventAI::EnterCombat`, `CreatureEventAI::IsTimerBasedEvent`, `CreatureEventAI::IsTimerExecutedEvent`, `CreatureEventAI::JustRespawned`, `CreatureEventAI::JustSummoned`, `CreatureEventAI::MoveInLineOfSight`, `CreatureEventAI::ProcessAction`, `CreatureEventAI::Reset`, `CreatureEventAI::SpellHitTarget`, `CreatureEventAI::SummonedCreatureJustDied`, `CreatureEventAI::UpdateEventTimers`, `GetRepeatTimers`
* Constants: `EFLAG_RANDOM_ACTION`, `EVENT_UPDATE_TIME`, `TARGET_T_EVENT_SENDER`, `TARGET_T_EVENT_SPECIFIC`, `EVENT_T_OOC_LOS`, `EVENT_T_FRIENDLY_IS_CC`, `EVENT_T_FRIENDLY_MISSING_BUFF`, `EVENT_T_SUMMONED_UNIT`, `EVENT_T_TARGET_MANA`, `EVENT_T_TARGET_AURA`, `EVENT_T_SUMMONED_JUST_DIED`, `EVENT_T_TARGET_MISSING_AURA`, `EVENT_T_TIMER_GENERIC`, `EVENT_T_SELECT_ATTACKING_TARGET`, `EVENT_T_FACING_TARGET`, `EVENT_T_SPELLHIT_TARGET`, `EVENT_T_TARGET_NOT_REACHABLE`, `ACTION_T_RANGED_MOVEMENT`, `ACTION_T_CHANGE_MOVEMENT`, `ACTION_T_PAUSE_WAYPOINTS`, `TARGET_T_ACTION_INVOKER_OWNER`, `TARGET_T_SPAWNER`, `TARGET_T_PLAYER_INVOKER`, `TARGET_T_PLAYER_TAPPED`, `TARGET_T_HOSTILE_RANDOM_MANA`, `TARGET_T_NEAREST_AOE_TARGET`, `TARGET_T_HOSTILE_FARTHEST_AWAY`

## world/experience.d

* Projects: CMaNGOS, MaNGOS
* Functions: `XP::xp_in_group_rate` (a raid's rate), `Player::ComputeRest` (the client doubling the rest field)
* Constants: `CONFIG_FLOAT_GROUP_XP_DISTANCE`, `NO_XP`
* Not from an emulator: `baseGain`, `zeroDifference`, `grayLevel`/`isGray` (47 at 60), `eliteFactor`, the party rates, `restEarned`, `restCap`, `restedBonus`, `restAfterKill`: Wowpedia's 1.x research and Exhaustion.dbc (docs/FORMULAS.md, "Experience")

## world/exploration.d

* Projects: CMaNGOS
* Functions: `ObjectMgr::GetBaseXP`, `Player::CheckAreaExploreAndOutdoor`, `Player::GetZoneAndAreaId`, `Player::GiveLevel`, `Player::GiveXP`, `Player::SetPosition`, `Player::Update`, `Player::UpdateArea`, `Player::UpdateZone`, `WorldSession::HandleZoneUpdateOpcode`
* Constants: `AREA_FLAG_CAPITAL`, `CMSG_ZONEUPDATE`, `SMSG_INIT_WORLD_STATES`

## world/gameobject.d

* Projects: CMaNGOS
* Files: `GameObject.cpp`
* Functions: `GameObject::Create`, `GameObject::Update`, `GameObjectInfo::GetLockId`, `Object::BuildCreateUpdateBlockForPlayer`
* Constants: `GAMEOBJECT_DYN_FLAGS`, `GAMEOBJECT_TYPE_GOOBER`, `GAMEOBJECT_TYPE_MO_TRANSPORT`, `GO_DYNFLAG_LO_ACTIVATE`, `GO_JUST_DEACTIVATED`
* Also: `GAMEOBJECT_TYPE_SPELLCASTER`

## world/gameobjecthandlers.d

* Projects: CMaNGOS
* Functions: `GameObject::ActivateToQuest`, `GameObject::Use`, `Loot::Loot`, `Loot::Release`, `Player::GetSpellRank`, `Player::UpdateGatherSkill`, `Player::UpdateSkillPro`, `Spell::CanOpenLock`, `Spell::EffectOpenLock`, `Spell::SendLoot`
* Constants: `GAMEOBJECT_TYPE_CHAIR`, `INTERACTION_DISTANCE`, `SCRIPT_COMMAND_OPEN_DOOR`
* Also: `GameObject::Use`'s `GAMEOBJECT_TYPE_SPELLCASTER` (`spellcaster.partyOnly`, `charges`, `GO_FLAG_LOCKED`)

## world/gmactions.d

* Projects: ArcEmu, CMaNGOS
* Functions: `Player::DestroyItemCount`, `Player::learnSpell`, `Player::removeSpell` (the free primary professions), `Player::GiveLevel` (TBC's mail at level-up), `ObjectMgr::LoadMailLevelRewards` (TBC), `Player::SaveToDB`, `Player::SetPlayerSpeed`, `Player::SetSkill`, `Player::learnSpell`, `Player::removeSpell`, `World::SendGMWorldText`, `World::SendWorldText`, `World::SendWorldWideScreenText`
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

## world/itemuse.d

* Projects: CMaNGOS
* Files: `SpellHandler.cpp`, `Spell.cpp`, `Item.cpp`, `Player.cpp`, `Unit.cpp`
* Functions: `Item::SendTimeUpdate`, `Item::UpdateDuration`, `Player::AddCooldown`, `Player::AddItemDurations`, `Player::ApplyEquipCooldown`, `Player::DurabilityPointLossForEquipSlot`, `Player::DurabilityPointsLoss`, `Player::IsSpellReady`, `Player::UpdateItemDuration`, `Spell::CheckItems`, `Spell::TakeAmmo`, `Spell::TakeCastItem`, `Unit::DealDamage`, `WorldSession::HandleUseItemOpcode`
* Constants: `BIND_WHEN_USE`, `CONFIG_FLOAT_RATE_DURABILITY_LOSS_DAMAGE`, `ITEM_EXTRA_REAL_TIME_DURATION`, `ITEM_FLAG_NO_EQUIPCOOLDOWN`, `SMSG_ITEM_COOLDOWN`, `SMSG_ITEM_TIME_UPDATE`, `SPELL_FAILED_NO_CHARGES_REMAIN`

## world/meetingstone.d

* Projects: vmangos
* Files: `LFG/LFGDefines.h`, `LFG/LFGMgr.cpp`, `LFG/LFGQueue.cpp`, `Group/Group.cpp`, `Server/Packets/Misc.cpp`
* Functions: `LFGMgr::CalculateRoles`, `LFGMgr::GetPriority`, `LFGQueue::Update`, `LFGQueue::FindRoleToGroup`, `Group::CalculateLFGRoles`, `Group::FillPremadeLFG`

## world/guardians.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`, `GuardianAI.cpp`, `CreatureAISelector.cpp`, `Unit.cpp`, `Player.cpp`
* Functions: `Spell::EffectSummon`, `Spell::EffectSummonGuardian`, `Spell::EffectSummonObjectWild`, `GuardianAI::GuardianAI`, `GuardianAI::UpdateAI`, `FactorySelector::selectAI`, `Unit::FindGuardianWithEntry`, `Unit::RemoveGuardians`, `Player::SetDeathState`
* Constants: `SPELL_EFFECT_SUMMON`, `SPELL_EFFECT_SUMMON_GUARDIAN`, `SPELL_EFFECT_SUMMON_OBJECT_WILD`, `GUARDIAN_PET`, `UNIT_BYTE2_FLAG_SUPPORTABLE`, `UNIT_BYTE2_FLAG_UNK5`, `UNIT_FIELD_SUMMONEDBY`, `UNIT_FIELD_CREATEDBY`, `UNIT_CREATED_BY_SPELL`, `SKILL_ENGINEERING`, `INVTYPE_TRINKET`

## world/durability.d

* Projects: CMaNGOS
* Files: `Player.cpp`, `SpellEffects.cpp`, `Spell.h`
* Functions: `Player::DurabilityLossAll`, `Player::DurabilityLoss`, `Player::DurabilityPointsLossAll`, `Player::DurabilityPointsLoss`, `Spell::EffectDurabilityDamage`, `Spell::EffectDurabilityDamagePCT`, `SpellLog::AddLog`
* Constants: `SPELL_EFFECT_DURABILITY_DAMAGE`, `SPELL_EFFECT_DURABILITY_DAMAGE_PCT`, `SMSG_SPELLLOGEXECUTE`, `INVENTORY_SLOT_BAG_START`, `INVENTORY_SLOT_ITEM_START`

## world/rituals.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`, `GameObject.cpp`, `GameObject.h`, `MovementHandler.cpp`, `Player.cpp`, `Player.h`
* Functions: `Spell::EffectTransmitted`, `Spell::EffectSummonPlayer`, `GameObject::Use`, `GameObject::IsUseRequirementMet`, `GameObject::TriggerSummoningRitual`, `GameObject::AddUniqueUse`, `WorldSession::HandleSummonResponseOpcode`, `Player::SetSummonPoint`, `Player::SummonIfPossible`
* Constants: `GAMEOBJECT_TYPE_SUMMONING_RITUAL`, `GAMEOBJECT_TYPE_MEETINGSTONE`, `SPELL_EFFECT_TRANS_DOOR`, `SPELL_EFFECT_SUMMON_PLAYER`, `SMSG_SUMMON_REQUEST`, `CMSG_SUMMON_RESPONSE`, `MAX_PLAYER_SUMMON_DELAY`, `SPELL_ATTR_NOT_IN_COMBAT_ONLY_PEACEFUL`, `TRIGGERED_CHANNEL_ONLY`

## world/homebind.d

* Projects: CMaNGOS
* Files: `Player.cpp`, `Group.cpp`, `MovementHandler.cpp`
* Functions: `Player::UpdateHomebindTime`, `Group::_homebindIfInstance`, `Group::AddMember`, `WorldSession::HandleMoveWorldportAckOpcode`
* Constants: `SMSG_RAID_GROUP_ONLY`, `ERR_RAID_GROUP_NONE`

## world/mounting.d

* Projects: CMaNGOS
* Files: `Spell.cpp`, `Relations.cpp`, `Unit.cpp`, `GameObject.cpp`, `GameObject.h`, `MovementHandler.cpp`, `Player.cpp`, `Pet.cpp`
* Functions: `Spell::CheckCast`, `Unit::CanAttackNow`, `Unit::Attack`, `GameObject::Use`, `GameObjectInfo::IsUsableMounted`, `WorldSession::HandleMoveWorldportAckOpcode`, `Map::IsMountAllowed`, `Player::Mount`, `Player::Unmount`, `Pet::SetModeFlags`
* Constants: `SPELL_ATTR_ALLOW_WHILE_MOUNTED`, `SPELL_FAILED_NOT_MOUNTED`, `SPELL_FAILED_NOT_ON_TAXI`, `SPELL_AURA_MOUNTED`, `PET_MODE_DISABLE_ACTIONS`, `SMSG_PET_MODE`, `SMSG_ATTACKSTOP`

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
* Not from an emulator: `honorableKillPoints`, `rankOneHonorAt`, `dishonorableKillPoints`, the grey (`isGray`) and the civilian rule: Wowpedia "Honor system (pre-2.0 formulas)", "Civilian" (docs/FORMULAS.md, "Honor"); from CMaNGOS still: the victim's level over the killer's, equal shares within 74 yards, a racial leader's 398
* Functions: `HonorCP::isKill`, `Player::AddHonorCP`, `Player::CalculateTotalKills`, `Player::GetRankPoints`, `Player::RewardHonor`, `Player::UpdateHonor`, `Unit::Kill`, `World::GetDateLastMaintenanceDay`, `WorldSession::HandleInspectHonorStatsOpcode`
* Constants: `SMSG_PVP_CREDIT`, `TYPE_OF_HONOR`

## world/honorweek.d

* Projects: CMaNGOS, MaNGOS
* Functions: `ObjectMgr::CalculateRpDecay`, `ObjectMgr::CalculateRpEarning`, `ObjectMgr::FlushRankPoints`, `ObjectMgr::GenerateScores`, `World::ServerMaintenanceStart`
* Not from an emulator: the standing's 1.12 breakpoints; the decay, the 15 kills and the rank points agree with Wowpedia "Honor system (pre-2.0 formulas)" (docs/FORMULAS.md, "Honor")

## world/inventory.d

* Projects: CMaNGOS
* Files: `Bag.cpp`, `Item.cpp`, `Item.h`, `ItemPrototype.h`, `Player.cpp`, `SharedDefines.h`
* Functions: `Bag::Create`, `Bag::IsEmpty`, `Bag::RemoveItem`, `Bag::StoreItem`, `Item::CalculateDurabilityRepairCost`, `Item::CanBeMergedPartlyWith`, `Item::CloneItem`, `Item::CreateItem`, `Item::Create`, `Item::GetBagSlot`, `Item::GetBaseRepairCost`, `Item::GetPos`, `Item::GetSellPrice`, `Item::GetSkill`, `Item::IsBag`, `Item::IsBindedNotWith`, `Item::IsEquipped`, `Item::IsSoulBound`, `Item::LoadFromDB`, `Item::SaveToDB`, `Item::SetBinding`, `Item::SetState`, `ItemPosCount::isContainedIn`, `ItemPrototype::CanChangeEquipStateInCombat`, `Player::AddItemToBuyBackSlot`, `Player::AutoUnequipOffhandIfNeed`, `Player::CanBankItem`, `Player::CanDualWield`, `Player::CanEquipItem`, `Player::CanEquipNewItem`, `Player::CanStoreItem`, `Player::CanStoreNewItem`, `Player::CanUnequipItem`, `Player::CanUseAmmo`, `Player::CanUseItem`, `Player::DestroyItemCount`, `Player::DestroyItem`, `Player::EquipItem`, `Player::EquipNewItem`, `Player::FindEquipSlot`, `Player::GetBankBagSlotCount`, `Player::GetItemByGuid`, `Player::GetItemByPos`, `Player::GetItemCount`, `Player::GetItemFromBuyBackSlot`, `Player::GetMaxKeyringClientSize`, `Player::HasItemWithIdEquipped`, `Player::HasSpell`, `Player::IsBagPos`, `Player::IsBankPos`, `Player::IsEquipmentPos`, `Player::IsInventoryPos`, `Player::IsTwoHandUsed`, `Player::IsValidPos`, `Player::RemoveItemFromBuyBackSlot`, `Player::RemoveItem`, `Player::SaveItemToInventory`, `Player::SendEquipError`, `Player::SetBankBagSlotCount`, `Player::SetVisibleItemSlot`, `Player::SplitItem`, `Player::StoreItem`, `Player::StoreNewItem`, `Player::SwapItem`, `Player::ViableEquipSlots`, `Player::VisualizeItem`, `Player::_CanStoreItem_InBag`, `Player::_CanStoreItem_InInventorySlots`, `Player::_CanStoreItem_InSpecificSlot`, `Player::_CanStoreItem`, `Player::_CanTakeMoreSimilarItems`, `Player::_LoadInventory`, `Player::_SaveInventory`, `Player::_StoreItem`, `Player::m_items`
* Constants: `EQUIP_ERR_NONE`, `ITEM_DYNFLAG_BINDED`, `ITEM_DYNFLAG_UNLOCKED`, `ITEM_DYNFLAG_WRAPPED`, `SMSG_BUY_FAILED`, `SMSG_INVENTORY_CHANGE_FAILURE`, `SMSG_SELL_ITEM`

## world/inworld.d

* Projects: ArcEmu, CMaNGOS
* Files: `ChatHandler.cpp`, `ItemHandler.cpp`, `MiscHandler.cpp`, `MovementHandler.cpp`, `QueryHandler.cpp`
* Functions: `WorldSession::HandleUnlearnSkillOpcode`, `Player::UpdateSkillTrainedSpells`, `Player::RegenerateAll`, `Player::Say`, `Player::Update`, `Player::Whisper`, `Unit::HandleEmote`, `WorldSession::HandleLogoutRequestOpcode`, `WorldSession::LogoutPlayer`, `WorldSession::Update`, `WorldSession::VerifyMovementInfo`, `WorldSession::m_muted`

## world/itemhandlers.d

* Projects: ArcEmu, CMaNGOS
* Files: `ItemHandler.cpp`, `NPCHandler.cpp`
* Functions: `Player::BuyItemFromVendor`, `Player::DurabilityRepairAll`, `Player::DurabilityRepair`, `Player::SendBuyError`, `Player::SendEquipError`, `Player::SendNewItem`, `Player::SendSellError`, `Player::SetAmmo`, `Player::_ApplyAmmoBonuses`, `WorldSession::HandleAutoBankItemOpcode`, `WorldSession::HandleAutoEquipItemOpcode`, `WorldSession::HandleAutoEquipItemSlotOpcode`, `WorldSession::HandleAutoStoreBagItemOpcode`, `WorldSession::HandleAutoStoreBankItemOpcode`, `WorldSession::HandleBuyBankSlotOpcode`, `WorldSession::HandleBuyItemInSlotOpcode`, `WorldSession::HandleBuyItemOpcode`, `WorldSession::HandleBuybackItem`, `WorldSession::HandleDestroyItemOpcode`, `WorldSession::HandleRepairItemOpcode`, `WorldSession::HandleSellItemOpcode`, `WorldSession::HandleSetAmmoOpcode`, `WorldSession::HandleSplitItemOpcode`, `WorldSession::HandleSwapInvItemOpcode`, `WorldSession::HandleSwapItem`
* Constants: `RANK_REQUIRE`

## world/loot.d

* Projects: CMaNGOS
* Files: `LootMgr.cpp`
* Functions: `GroupLootRoll::AllPlayerVoted`, `GroupLootRoll::Finish`, `GroupLootRoll::PlayerVote`, `GroupLootRoll::TryToStart`, `GroupLootRoll::UpdateRoll`, `Loot::AddItem`, `Loot::CanLoot`, `Loot::FillLoot`, `Loot::GenerateMoneyLoot`, `Loot::GetLootContentFor`, `Loot::GetLootStatusFor`, `Loot::GroupCheck`, `Loot::IsItemAlreadyIn`, `Loot::IsLootedFor`, `Loot::IsLootedForAll`, `Loot::NotifyItemRemoved`, `Loot::Release`, `Loot::SendGold`, `Loot::SendItem`, `Loot::SendReleaseFor`, `Loot::SendReleaseForAll`, `Loot::ShowContentTo`, `Loot::Update`, `LootGroup::Roll`, `LootItem::GetSlotTypeForSharedLoot`, `LootMgr::PlayerVote`, `LootStoreItem::Roll`, `LootTemplate::AddEntry`, `LootTemplate::HasQuestDrop`, `LootTemplate::LootGroup`, `LootTemplate::Process`
* Constants: `ITEM_FLAG_MULTI_DROP`, `ITEM_QUALITY_UNCOMMON`, `LOOTITEM_TYPE_QUEST`, `LOOT_ROLL_TIMEOUT`, `LOOT_STATUS_FAKE_LOOT`, `MAX_NR_LOOT_ITEMS`, `SMSG_LOOT_RESPONSE`, `SMSG_LOOT_ROLL`, `SMSG_LOOT_START_ROLL`, `UNIT_FLAG_LOOTING`

## world/loothandlers.d

* Projects: CMaNGOS
* Files: `LootHandler.cpp`
* Not from an emulator: a group kill's reputation, all of it to each member near it (docs/FORMULAS.md, "Reputation"); the shares of experience agree with Wowpedia "Mob experience" (CMaNGOS's half-plus-one when the highest member finds the kill grey has no source)
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

* Projects: CMaNGOS, mangosd, ArcEmu
* Files: `Map.cpp`, `Player.cpp`; ArcEmu `Player.cpp`
* Functions: `Player::IsVisibleInGridForPlayer` (ghosts), ArcEmu `Player::CanSee` (the GM tag sees ghosts), `Cell::SetNoCreate`, `Map::Add`, `Map::CreatureRelocation`, `Map::PlayerRelocation`, `Map::Remove`, `Map::SendObjectUpdates`, `Map::Update`, `Object::BuildValuesUpdate`, `Object::UpdateVisibilityOf`, `ObjectGridLoader::Load`, `Player::UpdateVisibilityOf`, `TerrainInfo::IsInWater`, `Unit::OnRelocated`
* Constants: `SMSG_DESTROY_OBJECT`

## world/motion.d

* Projects: CMaNGOS
* Functions: `FactorySelector::selectMovementGenerator`, `Map::GetHeight`, `MotionMaster::Initialize`, `MotionMaster::MovePoint`, `MoveSplineInit::Launch`, `MoveSplineInit::MoveTo`, `MoveSplineInit::Stop`, `TerrainInfo::GetWaterOrGroundLevel`, `Unit::InterruptMoving`, `Unit::StopMoving`, `Unit::UpdateAllowedPositionZ`, `Unit::UpdateSplineMovement`, `WaypointManager::Load`
* Constants: `SCRIPT_COMMAND_PAUSE_WAYPOINTS`
* Also: `DistractMovementGenerator`, `DISTRACT_MOTION_TYPE`

## world/moveorders.d

* Projects: CMaNGOS
* Files: `MovementHandler.cpp`, `SpellAuras.cpp`, `Unit.h` (`SetSpeed2Opc_table`)
* Functions: `Unit::UpdateSpeed`, `Unit::SetSpeedRate`, `Unit::SetWaterWalk`, `Unit::SetFeatherFall`, `Unit::SetHover`, `Unit::Mount`, `Unit::Unmount`, `Aura::HandleAuraModIncreaseSpeed`, `Aura::HandleAuraModDecreaseSpeed`, `Aura::HandleAuraModUseNormalSpeed`, `Aura::HandleAuraGhost`, `WorldSession::HandleForceSpeedChangeAckOpcodes`, `WorldSession::HandleMoveRootAck`, `WorldSession::HandleMoveKnockBackAck`, `WorldSession::HandleMoveFlagChangeOpcode`, `WorldSession::SendKnockBack`
* Constants: `MOVEFLAG_WATERWALKING`, `SPELL_AURA_MOD_SPEED_ALWAYS`, `SPELL_AURA_MOD_MOUNTED_SPEED_ALWAYS`, `SPELL_AURA_MOD_SPEED_NOT_STACK`, `SPELL_AURA_MOD_MOUNTED_SPEED_NOT_STACK`, `SPELL_AURA_USE_NORMAL_MOVEMENT_SPEED`

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
* Not from an emulator: `withAuras`, `showPetStats` (a pet's stats from its auras as a player's, docs/FORMULAS.md "Pets"); `spell_pet_auras` is CMaNGOS's table, read only where the data links no aura (docs/FORMULAS.md "Pets")

## world/petauras.d

* Projects: CMaNGOS (`spell_pet_auras`, its table; `Unit::GetSpellModOwner` as the idea of an owner's modifiers on
  its pet's spells)
* Not from an emulator: the passives from `CreatureFamily.dbc` and `SkillLineAbility.dbc`, the owner's modifiers on
  them (outdoors-only ones outdoors), `SPELL_EFFECT_APPLY_AREA_AURA_PET` (a pet's to its owner, an owner's to its pet),
  `SPELL_AURA_SPLIT_DAMAGE_PCT` to the aura's caster, Soul Link's dummy, Demonic Sacrifice by its tooltip
  (docs/FORMULAS.md "Pets")

## world/petai.d

* Projects: CMaNGOS
* Functions: `CharmInfo::GetCommandState`, `PetAI::AttackStart`, `PetAI::MoveInLineOfSight`, `PetAI::UpdateAI`, `PetAI::m_followDist`, `Creature::AddCooldown` (`SMSG_SPELL_COOLDOWN` to the owner, the category's cooldown), `WorldObject::IsSpellReady`
* Constants: `ACT_ENABLED`, `CMSG_PET_ACTION`, `CMSG_PET_CAST_SPELL`, `SPELL_ATTR_EX_NO_AUTOCAST_AI`
* Not from an emulator: a pet's cooldowns by its owner's `SPELLMOD_COOLDOWN` (Improved Lash of Pain's tooltip)

## world/pethandlers.d

* Projects: CMaNGOS
* Files: `NPCHandler.cpp`, `PetHandler.cpp`, `SpellEffects.cpp`
* Functions: `CreatureInfo::isTameable`, `ObjectMgr::CheckPetName`, `ObjectMgr::GetXPForPetLevel`, `Pet::GivePetXP`, `Pet::InitPetCreateSpells`, `Pet::LoadPetFromDB`, `Pet::SavePetToDB`, `Pet::ToggleAutocast`, `Pet::TryLoadFromDB`, `Pet::Unsummon`, `Pet::Update`, `PetAI::PetAI`, `Player::LoadPet`, `Player::PetSpellInitialize`, `Player::SynchronizeLevelWithOwner`, `Spell::CheckCast`, `TameBeastChannel::OnCheckCast`, `WorldSession::HandlePetAction`, `WorldSession::HandlePetCastSpellOpcode`, `Spell::SendCastResult` (a pet's cast), `Player::IsPetNeedBeTemporaryUnsummoned`
* Constants: `CLASS_HUNTER`, `CLASS_WARLOCK`, `CMSG_PET_CANCEL_AURA`, `CMSG_REQUEST_PET_INFO`, `CONFIG_UINT32_MIN_PET_NAME`, `CORPSE_DECAY_NORMAL`, `CREATURE_TYPEFLAGS_TAMEABLE`, `CREATURE_TYPE_BEAST`, `MAX_PET_NAME`, `PETTAME_DEAD`, `SMSG_PET_ACTION_FEEDBACK`, `SMSG_PET_TAME_FAILURE`, `SMSG_STABLE_RESULT`, `SPELL_ATTR_EX_DISMISS_PET_FIRST`, `SPELL_EFFECT_DISMISS_PET`, `SPELL_EFFECT_SUMMON_DEAD_PET`, `SPELL_EFFECT_SUMMON_PET`, `SPELL_EFFECT_TAMECREATURE`, `UNIT_FLAG_PET_ABANDON`, `UNIT_FLAG_PET_RENAME`
* Also: `Unit::TakeCharmOf`, `Unit::TakePossessOf`, `Unit::Uncharm`, `CharmInfo::InitCharmCreateSpells`, `UNIT_FIELD_CHARM`, `UNIT_FIELD_CHARMEDBY`, `SMSG_CLIENT_CONTROL_UPDATE`, `CMSG_SET_ACTIVE_MOVER`

## world/player.d

* Projects: ArcEmu, CMaNGOS
* Functions: `Aura::HandleAuraModStat`, `Group::_updateMembersOnRosterChanged`, `Object::BuildValuesUpdate`, `Player::BuildCreateUpdateBlockForPlayer`, `Player::CanDualWield`, `Player::ComputeRest`, `Player::ExploreArea`, `Player::GetChatTag`, `Player::GiveLevel`, `Player::HasItemCount`, `Player::HasSpell`, `Player::LoadFromDB`, `Player::ModifyMoney`, `Player::RegenerateAll`, `Player::SaveToDB`, `Player::SendInitialPacketsBeforeAddToMap`, `Player::SetRestBonus`, `Player::SetRestType`, `Player::SetSkill`, `Player::UpdateFreeTalentPoints`, `Player::UpdateSkillsForLevel`, `Player::_ApplyItemMods`, `Player::_LoadInventory`, `Player::autoReplyMsg`, `Player::bGMTagOn`, `Player::m_areaUpdateId`, `Spell::EffectDualWield`, `Spell::EffectProficiency`, `Unit::GetPowerType`, `Unit::HandleEmoteState`, `Unit::OCTRegenHPPerSpirit`, `Unit::OCTRegenMPPerSpirit`, `Unit::SetStandState`, `Unit::SetStunned`, `Unit::SetTargetGuid`, `Unit::m_speed_rate`
* Constants: `CORPSE`, `DEAD`, `MAX_MONEY_AMOUNT`, `PLAYER_EXPLORED_ZONES_1`, `PLAYER_FIELD_COINAGE`, `SKILL_FLAG_MAXIMIZED`, `SMSG_ACTION_BUTTONS`, `SMSG_LEVELUP_INFO`, `SMSG_SET_PROFICIENCY`, `SPELL_EFFECT_DUAL_WIELD`
* Also: `Player::RegenerateHealth` (`SPELL_AURA_MOD_REGEN_DURING_COMBAT`, `SPELL_AURA_MOD_HEALTH_REGEN_PERCENT`, `SPELL_AURA_MOD_HEALTH_REGEN_IN_COMBAT`), `Player::Regenerate` and `Player::UpdateManaRegen` (`SPELL_AURA_MOD_POWER_REGEN_PERCENT`), `Aura::HandleInterruptRegen` (`SetInDummyCombatState`, spells 5229 and 29131)
* Not from an emulator: health from spirit a two-second tick (the 1.x research table; a mage's, paladin's and priest's lines stay `OCTRegenHPPerSpirit`'s), a third more sitting, the five-second rule as long as a channel (docs/FORMULAS.md "Health and mana from spirit")

## world/playercreate.d

* Projects: CMaNGOS, mangosd
* Files: `ItemPrototype.h`, `Player.h`, `SharedDefines.h`, `StatSystem.cpp`
* Functions: `Player::Create`, `Player::GetSkillInfo`, `Player::HasSpell`, `Player::InitPrimaryProfessions`, `Player::IsNeedCastPassiveLikeSpellAtLearn`, `Player::LoadFromDB`, `Player::SetAmmo`, `Player::SetSkill`, `Player::StoreNewItemInBestSlots`, `Player::ValidateAppearance`, `Player::addSpell`, `Player::learnSpell`, `Spell::EffectLearnSpell`, `SpellMgr::GetSpellBookSuccessorSpellId`, `SpellMgr::IsPrimaryProfessionFirstRankSpell`, `SpellMgr::IsSpellValid`
* Constants: `AT_LOGIN_FIRST`, `CMSG_CHAR_CREATE`, `ITEM_DYNFLAG_BINDED`, `MAX_ENCHANTMENT_SLOT`, `SMSG_LEARNED_SPELL`, `SMSG_SUPERCEDED_SPELL`

## world/procs.d

* Projects: CMaNGOS
* Files: `UnitAuraProcHandler.cpp`, `SpellMgr.cpp`, `Spell.cpp`
* Functions: `Unit::ProcDamageAndSpell`, `Unit::IsTriggeredAtSpellProcEvent`, `SpellMgr::IsSpellProcEventCanTriggeredBy`,
  `Aura::CanProcFrom`, `Unit::GetPPMProcChance`, `Unit::TriggerProccedSpell`, `Unit::HandleProcTriggerDamageAuraProc`,
  `Spell::PrepareMasksForProcSystem`, `SpellMgr::LoadSpellProcEvents`
* Constants: `PROC_FLAG_*`, `PROC_EX_*`, `spell_proc_event`
* Not from an emulator: `SPELL_ATTR_EX3` 0x80000 read as "either hand's weapon" (only Sword Specialization has it;
  its tooltip asks for a sword, which CMaNGOS's "no equip requirement" did not); Unbridled Wrath's and Mace
  Specialization's chance the tooltip's flat one, not spell_proc_event's rate a minute (`flatChanceProcs`).
* Not from an emulator: `procRule`, `procFlagsOf`: the proc cooldowns Blizzard's (Classic Era's SpellAuraOptions
  `ProcCategoryRecovery`, its `ProcTypeMask` mapped to 1.12's flags), `spell_proc_event` the fallback
  (docs/FORMULAS.md, "Procs").

## world/physicalclasses.d

* Not from an emulator: the warrior's, rogue's and hunter's rules from their 1.12.1 tooltips and data
  (docs/spells/warrior.md, rogue.md, hunter.md; docs/FORMULAS.md): Last Stand's 30% of the maximum health, Tactical
  Mastery's rage kept by its script number's rank, Improved Sap's stealth, Pathfinding on the aspects' speed, Entrapment on a trap's effect only.
* Not from an emulator: Improved Mend Pet (24406, its tooltip's, at its amount's chance a tick) and Improved Scorpid Sting (its tooltip's 10% a rank of the strength reduced, as 19486)

## world/realclass_pets.d

* Not from an emulator: tests of the 1.12.1 tooltips' claims of the warlock's and the hunter's pet talents on the
  client's DBC files and the classic world database.

## world/realclass_warrior_rogue_hunter.d

* Not from an emulator: tests of the 1.12.1 tooltips' claims on the client's DBC files and the classic world database.

## world/professions.d

* Projects: CMaNGOS
* Files: `GridNotifiers.h`, `LootMgr.cpp`, `Spell.cpp`, `SpellEffects.cpp`
* Functions: `GameObjectFocusCheck`, `Loot::Release`, `ObjectMgr::LoadItemPrototypes`, `Spell::CanOpenLock`, `Spell::CheckCast`, `Spell::CheckItems`, `Spell::EffectDisEnchant`, `Spell::EffectOpenLock`, `Spell::SendCastResult`, `WorldObject::IsWithinDistInMap`
* Not from an emulator: `skinningSkillFor`, `fishingSkillUpChance` (docs/FORMULAS.md)
* Constants: `ITEM_DYNFLAG_UNLOCKED`, `LOOT_DISENCHANTING`, `SPELL_FAILED_ALREADY_OPEN`, `SPELL_FAILED_CANT_BE_DISENCHANTED`, `SPELL_FAILED_ITEM_GONE`, `SPELL_FAILED_REQUIRES_SPELL_FOCUS`, `SPELL_FAILED_TOTEMS`, `SPELL_FAILED_TRY_AGAIN`

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
* Functions: `Player::AddQuest`, `Player::AreaExploredOrEventHappens`, `Player::CanShareQuest`, `Player::CastedCreatureOrGO`, `Player::CompleteQuest`, `Player::FailQuest`, `Player::FailQuestsOnDeath`, `Player::HasQuestForItem`, `Player::IncompleteQuest`, `Player::IsCurrentQuest`, `Player::KilledMonsterCredit`, `Player::PrepareQuestMenu`, `Player::RewardPlayerAndGroupAtCast`, `Player::RewardQuest`, `Player::SatisfyQuestPreviousQuest`, `Player::SatisfyQuest`, `Player::SendNewItem`, `Player::SendPreparedQuest`, `Player::TakeQuestSourceItem`, `Player::TalkedToCreature`, `Player::UpdateForQuestWorldObjects`, `Player::Update`, `Quest::IsAllowedInRaid`, `WorldSession::HandleQuestLogRemoveQuest`, `WorldSession::getDialogStatus`
* Constants: `QUEST_FLAGS_AUTO_REWARDED`, `QUEST_FLAGS_STAY_ALIVE`, `QUEST_TYPE_RAID`, `SMSG_QUESTGIVER_STATUS`

## world/quests.d

* Projects: CMaNGOS
* Files: `QuestDef.cpp`
* Functions: `ObjectMgr::LoadQuests`, `Player::GetQuestLevelForPlayer`
* Not from an emulator: `questXp`, from 1.12's quest money and Wowpedia's falloff (docs/FORMULAS.md, "Quest experience")
* Constants: `MAX_QUEST_LOG_SIZE`, `QUEST_OBJECTIVES_COUNT`, `QUEST_REWARDS_COUNT`, `QUEST_REWARD_CHOICES_COUNT`, `SMSG_QUESTGIVER_QUEST_INVALID`

## world/realscriptkit.d

* Not from an emulator: a harness for tests of the scripts on the client's DBC files and the classic world database.

## world/realscripts_dungeons.d

* Not from an emulator: tests of the five-player dungeons' scripts on the client's DBC files and the classic world
  database; the expectations from the data, then Wowpedia's and warcraft.wiki.gg's pages of the encounters, with
  ScriptDev2's scripts (`AI/ScriptDevAI/scripts`) as a second opinion.

## world/realclassspelltests.d

* Projects: CMaNGOS (the client's DBC files and its classic world database, as the server runs on them)

## world/realrules_world2.d

* Not from an emulator: tests of the stats and regeneration rules, loot, the economy and the timers of docs/FORMULAS.md
  on the client's DBC files and the classic world database.

## world/realrules_combat.d

* Not from an emulator: tests of the attack table, spell resistance, Blizzard's proc data and diminishing returns
  on the client's DBC files, the classic world database and data/procs.csv.

## world/realm.d

* Projects: CMaNGOS, mangosd
* Files: `Master.cpp`, `World.cpp`
* Constants: `REALM_FLAG_OFFLINE`

## world/realscriptkit_raids.d

* Not from an emulator: a test harness (a raid's copy or a place on a continent, god-like characters, what their
  client was sent) on the client's DBC files and the classic world database.

## world/realscripts_raids.d

* Not from an emulator: tests of the raids' scripts on the client's DBC files and the classic world database; what
  each encounter must do from its data (`creature_template`, `script_texts`, the spells' rows), the encounters as
  Wowpedia and warcraft.wiki.gg describe them, and the scripts' own documentation (CMaNGOS ScriptDev only as a
  second opinion).

## world/realscripts_world.d

* Not from an emulator: tests of the world's scripts (the escort quests the scripts start, found in their sources)
  on the client's DBC files and the classic world database: `quest_template`, `script_waypoint` and
  `waypoint_path`, `script_texts`; CMaNGOS ScriptDev's escort AI (`MAX_PLAYER_DISTANCE`) as a second opinion.

## world/realspellsweep.d

* Projects: CMaNGOS (cross-checked against)
* Functions: `CalculateSpellDuration` (the oracle's durations), `Player::AddCooldown` (no `SMSG_SPELL_COOLDOWN` for a
  cast: the client starts its own; `SMSG_COOLDOWN_EVENT` for `SPELL_ATTR_COOLDOWN_ON_EVENT`), `Spell::FillTargetMap`
  (which unit each implicit target names)

## world/relations.d

* Projects: CMaNGOS
* Files: `Relations.cpp`
* Functions: `CGUnit_C::UnitReaction`, `Player::IsPvP`, `ReputationMgr::GetBaseReputation`, `ReputationMgr::ReputationToRank`, `Unit::CanAttack`, `Unit::CanAttackNow`, `Unit::GetReactionTo`, `Unit::IsEnemy`, `Unit::IsFriend`, `ReputationMgr::GetForcedRankIfAny` (in `Unit::GetReactionTo` and `GetFactionReaction`)
* Constants: `FACTION_FLAG_AT_WAR`, `FACTION_TEMPLATE_FLAG_ASSIST_PLAYERS`, `FACTION_TEMPLATE_FLAG_ATTACK_PVP_ACTIVE_PLAYERS`, `PLAYER_DUEL_ARBITER`, `PLAYER_DUEL_TEAM`, `PLAYER_FLAGS`, `PLAYER_FLAGS_CONTESTED_PVP`, `PLAYER_FLAGS_FFA_PVP`, `PLAYER_FLAGS_PVP_DESIRED`, `UNIT_FIELD_FLAGS`

## world/reputation.d

* Projects: CMaNGOS
* Files: `ReputationMgr.cpp`
* Functions: `ReputationMgr::Initialize`
* Constants: `MAX_REPUTATION_LIST`, `SMSG_INITIALIZE_FACTIONS`, `SMSG_SET_FACTION_VISIBLE`

## world/reputationhandlers.d

* Projects: CMaNGOS
* Files: `MiscHandler.cpp`
* Not from an emulator: a grey kill's fifth of the reputation (Wowpedia "Reputation"; docs/FORMULAS.md, "Reputation")
* Functions: `Player::CalculateReputationGain`, `Player::GetReputationPriceDiscount`, `Player::ReputationChanged`, `Player::RewardReputation`, `ReputationMgr::LoadFromDB`, `ReputationMgr::ModifyReputation`, `ReputationMgr::SaveToDB`, `Aura::HandleForceReaction`, `ReputationMgr::ApplyForceReaction`, `ReputationMgr::SendForceReactions`, `Player::StopAttackFaction`
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

## world/spellareas.d

* Projects: CMaNGOS
* Functions: `Spell::EffectPersistentAA`, `PersistentAreaAura`, `DynamicObject::Update`
* Moved here (2026-11-20): the persistent areas of `spellhandlers.d` (`makePersistentArea`, `areaTick`, `updatePersistentAreas`, `loseAreaAura`), now for a creature's casts too

## world/spellauras.d

* Projects: CMaNGOS
* Files: `SpellAuras.cpp`, `SpellEffects.cpp`
* Functions: `Spell::EffectApplyAura`, `Aura::PeriodicTick` (`SPELL_AURA_PERIODIC_DAMAGE`, `_LEECH`, `_MANA_LEECH`), `Unit::SendPeriodicAuraLog`, `Aura::HandleAuraTransform`, `Spell::EffectDispel`, `Spell::EffectDispelMechanic`
* Constants: `SMSG_PERIODICAURALOG`, `SMSG_SPELLDISPELLOG`, `SPELLMOD_DOT`, `SPELLMOD_CHARGES`, `SPELL_ATTR_HEARTBEAT_RESIST`
* Moved here (2026-11-20): `applyAuraEffect`, `auraTick` and `periodicLog` of `aurahandlers.d`, `leechTick` and `manaLeechTick` and `dispelMechanicEffect` of `effecthandlers.d`, `dispelEffect` of `spellhandlers.d`, `auraOn` of `creaturecasting.d`, `auraFrom` of `character.d` and `unit.d`

## world/spellcast.d

* Projects: CMaNGOS
* Files: `Spell.cpp`
* Functions: `Spell::CalculatePowerCost`, `SpellCastTargets::read`, `SpellCastTargets::write`, `Unit::MeleeSpellHitResult`, `Unit::MagicSpellHitResult`, `Unit::CanBlockAbility`, `Spell::DoSpellHitOnUnit` (heartbeat resistance)
* Constants: `SMSG_CAST_RESULT`, `SMSG_SPELLENERGIZELOG`, `SMSG_SPELLHEALLOG`, `SMSG_SPELLLOGMISS`, `SMSG_SPELLNONMELEEDAMAGELOG`, `SMSG_SPELL_FAILURE`, `SMSG_SPELL_GO`, `SMSG_SPELL_START`, `SPELL_ATTR_CANT_USED_IN_COMBAT`, `SPELL_ATTR_CASTABLE_WHILE_DEAD`, `SPELL_ATTR_EX2_CANT_CRIT`, `SPELL_ATTR_EX3_ALWAYS_HIT`, `SPELL_ATTR_ON_NEXT_SWING`, `SPELL_ATTR_ON_NEXT_SWING_NO_DAMAGE`, `SPELL_ATTR_HEARTBEAT_RESIST`, `SPELL_ATTR_EX3_COMPLETELY_BLOCKED`, `SPELL_MISS_BLOCK`
* Also: `SpellLog::Initialize`, `SpellLog::AddLog`, `SpellLog::SendToSet` (`SMSG_SPELLLOGEXECUTE`; the targets' guids packed for the 1.12 client, where CMaNGOS writes them whole)
* Also: `Spell::IsInterruptible` (`SPELL_INTERRUPT_FLAG_COMBAT`, `SPELL_PREVENTION_TYPE_SILENCE`), `CalculateSpellDuration` (combo points), `POWER_HEALTH`
* Not from an emulator: `bonusCoefficient`, Blizzard's spell power coefficients (Classic Era's SpellEffect.db2, `tools/fetch-coefficients.py`) with the 1.12 rules as fallback (docs/FORMULAS.md)
* Also: `IsSpellUseWeaponSkill` and `Unit::CalculateEffectiveMissChance` (an ability no weapon's: `GetSkillMaxForLevel`)
* Not from an emulator: `isBinarySpell` by Blizzard's resistance page (a direct-damage spell resisted in part unless
  a debuff rides on it; docs/FORMULAS.md, "Spell resistance"). `spellMissChance`'s level table is documented
  research (Wowpedia), as CMaNGOS has it.

## world/spelldamage.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`, `Unit.cpp`
* Functions: `Unit::SpellNonMeleeDamageLog`, `Unit::CalculateSpellDamage`, `Unit::SpellDamageBonusDone`, `Unit::SpellHealingBonusDone`, `Unit::DealHeal`, `Spell::EffectHeal`, `Spell::EffectEnergize`, `Spell::EffectPowerBurn`, `Spell::EffectPowerDrain`, `Spell::EffectHealthLeech`, `Spell::EffectHealMaxHealth`
* Constants: `SMSG_SPELLNONMELEEDAMAGELOG`, `SMSG_SPELLHEALLOG`, `SMSG_SPELLENERGIZELOG`, `SMSG_SPELLLOGEXECUTE`, `SPELL_ATTR_EX2_CANT_CRIT`, `SPELLMOD_MULTIPLE_VALUE`, `SPELLMOD_THREAT`
* Moved here (2026-11-20): `spellDamage`, `spellDamageToPlayer`, `spellDamageBonus`, `healingBonus`, `directCoefficient`, `heal`, `energize` of `spellhandlers.d`; `powerBurnEffect`, `powerDrainEffect`, `healthLeechEffect`, `healMaxHealthEffect`, `healSelf`, `powerOf`, `takePower` of `effecthandlers.d`; `spellDamageTo`, `healCreature` and the drains of `creaturecasting.d`

## world/spelleffects.d

* Projects: CMaNGOS
* Files: `SpellEffects.cpp`
* Functions: `Spell::HandleEffects`, `Spell::EffectLearnSpell` (a creature's at a player), `Spell::DoCreateItem` (a creature's for a player), `Spell::EffectAddComboPoints` (a player's only), `Spell::EffectSpawn`, `Spell::EffectAddExtraAttacks`, `Spell::EffectSummonPet` (a creature's), `Unit::SpellHitResult`
* Moved here (2026-11-20): the effect switches of `spellhandlers.d` (`doEffect`) and `creaturecasting.d` (`go`), and the player's hit roll (`rollHit`)

## world/spellhandlers.d

* Projects: CMaNGOS
* Files: `Spell.cpp`, `SpellEffects.cpp`, `SpellHandler.cpp`
* Functions: `GameObject::Use`, `Player::ClearCooldownForSpell`, `Player::ClearCooldownsOnLine`, `Player::HasItemFitToSpellReqirements`, `Player::_LoadSpellCooldowns`, `Player::_SaveSpellCooldowns`, `Spell::CheckCast`, `Spell::CheckItems`, `Spell::EffectEnergize`, `Spell::EffectHeal`, `Spell::EffectInstaKill`, `Spell::EffectPersistentAA`, `Spell::EffectTeleportUnits`, `Spell::EffectTransmitted`, `Spell::EffectWeaponDmg`, `Spell::SendChannelStart`, `Spell::SendChannelUpdate`, `Spell::SetTargetMap`, `Spell::SpellStart`, `Spell::cancel`, `Spell::cast`, `Spell::m_delayMoment`, `Spell::update`, `Unit::AttackerStateUpdate`, `Unit::CalculateSpellDamage`, `Unit::SpellDamageBonusDone`, `Unit::SpellHealingBonusDone`, `Unit::SpellHitResult`
* Constants: `CMSG_CANCEL_CHANNELLING`, `CURRENT_CHANNELED_SPELL`, `CURRENT_GENERIC_SPELL`, `CURRENT_MELEE_SPELL`, `FISHING_BOBBER_READY_TIME`, `MSG_CHANNEL_START`, `MSG_CHANNEL_UPDATE`, `SMSG_CLEAR_COOLDOWN`, `SMSG_FISH_NOT_HOOKED`, `SMSG_INITIAL_SPELLS`, `SMSG_SPELLINSTAKILLLOG`, `SMSG_SPELL_GO`, `SMSG_SPELL_START`, `SPELL_ATTR_EX_IS_CHANNELED`, `SPELL_AURA_MOD_DAMAGE_DONE`, `SPELL_AURA_MOD_HEALING_DONE`, `SPELL_AURA_PERIODIC_DAMAGE`, `SPELL_EFFECT_APPLY_AURA`, `SPELL_FAILED_EQUIPPED_ITEM_CLASS`, `SPELL_INTERRUPT_FLAG_MOVEMENT`, `TARGET_ALL_ENEMY_IN_AREA`, `TARGET_CASTER_COORDINATES`, `TRIGGERED_OLD_TRIGGERED`
* Also: `TARGET_UNIT_SCRIPT_NEAR_CASTER`, `Spell::CheckScriptTargeting` (`spell_script_target`), `TARGET_UNIT_FRIEND_AND_PARTY`
* Not from an emulator: fishing's skill-ups (only on a catch, by the measured catches a point) and skinning's required skill (one formula, Wowpedia "Skinning") (docs/FORMULAS.md); a mage's spell crit from intellect at level 60 (Blizzard's 59.5 a percent; docs/FORMULAS.md "Spell crit from intellect"), the other rows `Player::GetSpellCritFromIntellect`'s
* Also: `Spell::OnCheckCast` (a script's refusal last of `CheckCast`), `Spell::OnSuccessfulStart` (in `Spell::Prepare`),
  `TARGET_UNIT_RAID`
* Not from an emulator: the spell data's `CasterAuraState` and `TargetAuraState` refused at the cast (Revenge,
  Execute), `MaxAffectedTargets` (the target aimed at and the nearest), a weapon ability's crit chance, crit bonus
  (`SPELLMOD_CRIT_DAMAGE_BONUS`: Impale's tooltip) and damage modifiers and its damage done and taken as a swing's,
  procs of a spell that lands without damage (Improved Berserker Rage's tooltip), a cast within a finishing move
  (a proc's) leaving its combo points as they were
* Also: `Unit::MeleeDamageBonusDone`'s `SPELL_AURA_RANGED_ATTACK_POWER_ATTACKER_BONUS`
* Also: `WorldObject::IsSpellReady` (an item's cooldown category, the lockout only of `SPELL_PREVENTION_TYPE_SILENCE`), `Player::AddCooldown`, `Spell::EffectInterruptCast`, `Spell::TakePower` and `Spell::CheckPower` (`POWER_HEALTH`), `SpellAuraHolder::UpdateHolder` (`manaPerSecond`)
* Also: `Spell::FillFromTargetFlags` (no implicit target: the client's unit), `Unit::CanAssistSpell` for `TARGET_UNIT_RAID`
  and `TARGET_UNIT_FRIEND_CHAIN_HEAL` (`SCHEME_LOWEST_HP_CHAIN`), `TARGET_UNIT_CASTER_PET`, `Spell::TakeAmmo` after
  `Spell::FillTargetMap` in `Spell::cast`, `Spell::EffectTransmitted` (`GAMEOBJECT_TYPE_SPELLCASTER`),
  `PersistentAreaAura` (the dynamic object's duration, lost on leaving)

## world/spellmoves.d

* Projects: CMaNGOS
* Functions: `Spell::EffectCharge`, `MotionMaster::MoveCharge`
* Moved here (2026-11-20): the end of a charge from `effecthandlers.d` (`chargeEffect`), now for a creature's too

## world/spellscripting.d

* Projects: CMaNGOS
* Files: `Spells/Scripts/SpellScript.h`, `Grids/GridNotifiers.h`
* Functions: `WorldObject::PlaySpellVisual`, `MaNGOS::AnyUnfriendlyUnitInObjectRangeCheck`, `Unit::IsEnemy`

## world/spellmods.d

* Functions: `Player::ApplySpellMod`, `SpellModifier::isAffectedOnSpell`
* Constants: `SPELL_AURA_ADD_FLAT_MODIFIER`, `SPELL_AURA_ADD_PCT_MODIFIER`
* Not from an emulator: where each modifier comes in (the damage with the spell power, the crit's bonus, the hit
  chance, the threat, every stack: the talents' tooltips, docs/FORMULAS.md)

## world/spells.d

* Projects: CMaNGOS
* Constants: `SPELL_ATTR_DO_NOT_DISPLAY`, `SPELL_ATTR_EX2_ALLOW_WHILE_NOT_SHAPESHIFTED`, `SPELL_ATTR_EX_CAST_WHEN_LEARNED`, `SPELL_ATTR_PASSIVE`, `TARGET_UNIT_CASTER_PET`
* Also: `SpellMgr::LoadSpellAffects` (`doForHighRanks`: `spell_affect` for every rank)

## world/spellsummons.d

* Projects: CMaNGOS
* Functions: `Spell::EffectSummonObjectWild`, `Spell::EffectTransmitted`, `Spell::EffectSummonTotem`, `TotemAI::UpdateAI`
* Moved here (2026-11-20): `summonWildObjectEffect` of `guardians.d`, `summonTotem` and `updateTotems` of `pethandlers.d`, now for a creature's casts too

## world/spline.d

* Projects: CMaNGOS, G3D
* Files: `MoveSpline.cpp`, `MoveSplineInit.cpp`
* Functions: `ByteBuffer::appendPackXYZ`, `G3D::wrap`, `MoveSpline::ComputePosition`, `MoveSpline::Initialize`, `MoveSpline::init_spline`, `MoveSpline::updateState`, `MoveSplineInit::SetFacing`, `MoveSplineInit::Stop`, `MoveSplineInitArgs::Validate`, `PacketBuilder::WriteCreate`, `PacketBuilder::WriteMonsterMove`, `SplineBase::InitLinear`
* Constants: `SMSG_MONSTER_MOVE`

## world/stats.d

* Projects: CMaNGOS
* Files: `StatSystem.cpp`
* Functions: `Player::CalculateMinMaxDamage`, `Player::CheckAmmoCompatibility`, `Player::GetHealthBonusFromStamina`, `Player::GetManaBonusFromIntellect`, `Player::GetMeleeCritFromAgility`, `Player::InitStatsForLevel`, `Player::UpdateCritPercentage`, `Player::_ApplyItemBonuses`, `Unit::m_modCritChance`
* Constants: `MOD_ATTACK_POWER`, `MOD_INCREASE_ENERGY`, `MOD_INCREASE_HEALTH`, `MOD_PERCENT_STAT`, `MOD_RANGED_ATTACK_POWER`, `MOD_RESISTANCE`, `MOD_STAT`, `SPELL_AURA_MOD_STAT`
* Not from an emulator (2026-11-20): a druid's melee attack power (strength's, in Cat Form agility's too, none of its
  level: the Cat Form tooltip and warcraft.wiki.gg's Attack Power page; docs/FORMULAS.md)

## world/talenthandlers.d

* Projects: CMaNGOS
* Functions: `Player::AddItemsSetItem`, `Player::ApplyItemEquipSpell`, `Player::LearnTalent`, `Player::Reset_Talents`, `Player::_ApplyAllItemMods`, `Player::resetTalentsCost`, `Player::resetTalents`
* Constants: `ITEM_SPELLTRIGGER_ON_EQUIP`, `PLAYER_CHARACTER_POINTS1`

## world/taxi.d

* Projects: CMaNGOS
* Files: `Taxi.cpp`
* Functions: `ObjectMgr::GetNearestTaxiNode`, `Tracker::AddRoutes`, `Tracker::Save`, `Tracker::Load`, `Tracker::Prepare`
* Constants: `PLAYER_FLIGHT_SPEED`

## world/taxihandlers.d

* Projects: CMaNGOS
* Files: `TaxiHandler.cpp`, `Player.cpp`
* Functions: `Player::ActivateTaxiPathTo`, `Player::LoadFromDB` (the saved flight), `Player::TaxiFlightResume`, `Player::Mount` and `Player::Unmount` (the pet set aside for the flight)
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

## world/tooltipeffects.d

* Not from an emulator: effects the 1.12.1 tooltips state that the data lacks (Barkskin's), docs/FORMULAS.md "Effects only a tooltip gives"
* Not from an emulator: Demonic Sacrifice's effect by demon, from its tooltip

## world/tradehandlers.d

* Projects: CMaNGOS
* Files: `TradeHandler.cpp`
* Functions: `Item::CanBeTraded`, `Player::TradeCancel`, `TradeData::SetAccepted`, `TradeData::SetSpell`, `TradeData::SetItem`, `WorldSession::HandleAcceptTradeOpcode`, `WorldSession::SendUpdateTrade`, `Spell::CheckCast` (the trade slot), `SpellCastTargets::setTradeItemTarget`
* Constants: `ITEM_FIELD_GIFTCREATOR`, `TRADE_DISTANCE`, `TRADE_SLOT_COUNT`, `TRADE_SLOT_TRADED_COUNT`, `TRADE_SLOT_NONTRADED`, `TARGET_FLAG_TRADE_ITEM`, `SPELL_FAILED_NOT_TRADING`, `SPELL_FAILED_ITEM_NOT_READY`, `SPELL_FAILED_DONT_REPORT`, `TRIGGERED_FORCE_COSTS`

## world/unit.d

* Projects: CMaNGOS
* Functions: `Unit::DealDamage`
* Constants: `DIRECT_DAMAGE`, `SPELL_DIRECT_DAMAGE`
* Not from an emulator: `brokenByDamage` (the holds' proc flags and chance, Shadow Vulnerability's charges: the
  tooltips and data), `deathProcs` (Drain Soul's proc on the kill), `Blow.threat` (`SPELLMOD_THREAT`)
* Not from an emulator: a creature's damage-taken aura with charges spends one at a blow of its school (Hemorrhage's tooltip); a creature's auras that damage ends (`AuraInterruptFlags`: Wyvern Sting's tooltip)

## world/tooltipmasks.d

* Not from an emulator: the talents' tooltips against the world database's `spell_affect` masks (docs/FORMULAS.md)

## world/updatefields.d

* Projects: CMaNGOS
* Files: `UpdateFields.cpp`
* Constants: `ITEM_FIELD_SPELL_CHARGES`, `MAX_BAG_SIZE`, `MAX_INSPECTED_ENCHANTMENT_SLOT`, `OBJECT_FIELD_TYPE`, `PLAYER_FIELD_MOD_DAMAGE_DONE_PCT`, `PLAYER_MAX_SKILLS`, `UNIT_FIELD_HEALTH`, `UNIT_FIELD_TARGET`

## world/wareffort.d

* Projects: CMaNGOS
* Files: `World/WorldState.cpp`, `World/WorldState.h`, `World/WorldStateDefines.h`
* Functions: `AhnQirajData::GetData`, `AhnQirajData::GetDaysRemaining`, `WorldState::Load` (`SAVE_ID_AHN_QIRAJ`), `WorldState::Save`, `WorldState::Update` (the war effort's timer), `WorldState::AddWarEffortProgress`, `WorldState::HandleWarEffortPhaseTransition`, `WorldState::StartWarEffortEvent`, `WorldState::StopWarEffortEvent`, `WorldState::SpawnWarEffortGos`, `WorldState::ChangeWarEffortGoSpawns`, `WorldState::ChangeWarEffortPhase2Tier`, `WorldState::SetSilithusBossKilled`, `WorldState::GetResourceInfo`, `WorldState::GetResourceCounterAndMax`, `GetResourceTier`, `WorldState::HandlePlayerEnterZone`, `WorldState::FillInitialWorldStates` (the war effort's part)
* Constants: `AQResources`, `AQResourceGroup`, `AQPhase`, `AQSilithusBoss`, `aqWorldstateMap`, `aqWorldStateTotalsMap`, `warEffortSpawns`, `WAR_EFFORT_DB_GUID_PREFIX`, `GAME_EVENT_AHN_QIRAJ_EFFORT_PHASE_1`..`_5`, `GAME_EVENT_ASHI_DEAD`, `GAME_EVENT_REGAL_DEAD`, `GAME_EVENT_ZORA_DEAD`, `WORLD_STATE_AQ_*`, `ZONEID_*` (the capitals)

## world/worldpvp.d

* Projects: none. Written from the 1.12.1 client's data (`WorldStateUI.dbc`, `AreaPOI.dbc`, `GameObjectArtKit.dbc`,
  `AreaTrigger.dbc`, `WorldSafeLocs.dbc`, `SpellIcon.dbc`, `FactionTemplate.dbc`), the world database (the capture
  points' `gameobject_template` data, `dbscripts_on_event`, `quest_template`, `broadcast_text`, `spell_template`) and
  warcraft.wiki.gg (docs/FORMULAS.md, "World PvP"); CMaNGOS-classic's `OutdoorPvP/OutdoorPvPEP.cpp` and
  `OutdoorPvPSI.cpp` were compared afterwards only.

## world/weather.d

* Projects: CMaNGOS
* Files: `Weather.cpp`
* Functions: `Player::SendFineWeather`, `Weather::GetSound`, `Weather::NormalizeGrade`, `Weather::ReGenerate`
* Constants: `SMSG_WEATHER`

## world/whisper.d

* Functions: `WorldSession::HandleMessagechatOpcode`

## world/worlddata.d

* Projects: CMaNGOS, mangosd
* Also: `ObjectMgr::LoadGameObjects` (`gameobject_spawn_entry`: a spawn without an entry takes one of its entries)
* Functions: `GraveyardManager::GraveyardLinkKey`, `PoolGroup::RollOne`, `PoolGroup::SpawnObject`, `PoolManager::UpdatePool`, `ObjectMgr::GetBaseXP`, `ObjectMgr::GetGameTele`, `ObjectMgr::GetMapEntranceTrigger`, `ObjectMgr::GetXPForLevel`, `ObjectMgr::LoadAreaTriggerTeleports`, `ObjectMgr::LoadCreatureTemplates`, `ObjectMgr::LoadCreatures`, `ObjectMgr::LoadGameTele`, `ObjectMgr::LoadItemPrototypes`, `ObjectMgr::LoadPlayerInfo`, `Player::IsActionButtonDataValid`, `WaypointManager::Load`
* Constants: `GRAVEYARD_AREALINK`, `GRAVEYARD_MAPLINK`, `MAX_LEVEL`, `SMSG_ITEM_QUERY_SINGLE_RESPONSE`
* Also: `SpellMgr::LoadSpellScriptTarget` (`spell_script_target`)
