-- Invalidate cached vendor, quest, creature and teleport data after a live edit.
CREATE TABLE IF NOT EXISTS `dmangos_world_catalog` (
    `catalog` tinyint unsigned NOT NULL,
    `entry` int unsigned NOT NULL,
    `revision` bigint unsigned NOT NULL,
    `pending` int unsigned NOT NULL DEFAULT 0,
    PRIMARY KEY (`catalog`, `entry`)
) ENGINE=InnoDB;

-- Jeziba introduces the nearby catalogue after the player accepts quest 5164.
SET @dmangos_jeziba_scene = EXISTS (
    SELECT 1 FROM `quest_template` WHERE `entry` = 5164 AND `StartScript` = 0
) AND NOT EXISTS (
    SELECT 1 FROM `dbscripts_on_quest_start` WHERE `id` = 5164
);

INSERT INTO `dbscripts_on_quest_start`
    (`id`, `delay`, `command`, `datalong`, `buddy_entry`, `search_radius`, `data_flags`, `dataint`, `comments`)
SELECT 5164, 1000, 36, 0, 176192, 10, 1025, 0, 'Jeziba faces the catalogue'
WHERE @dmangos_jeziba_scene
UNION ALL
SELECT 5164, 2000, 0, 0, 0, 0, 0, 6332, 'Jeziba addresses the player'
WHERE @dmangos_jeziba_scene
UNION ALL
SELECT 5164, 3000, 1, 25, 0, 0, 0, 0, 'Jeziba points at the catalogue'
WHERE @dmangos_jeziba_scene
UNION ALL
SELECT 5164, 5000, 36, 1, 0, 0, 4, 0, 'Jeziba returns to her original facing'
WHERE @dmangos_jeziba_scene;

UPDATE `quest_template` SET `StartScript` = 5164
WHERE `entry` = 5164 AND `StartScript` = 0 AND @dmangos_jeziba_scene;

-- Both Lava Bomb spells leave the same Conflagration trap in Molten Core.
UPDATE `gameobject_template` SET `ScriptName` = 'go_magmadar_lava_bomb'
WHERE `entry` = 177704 AND `ScriptName` = '';

-- The Relic Bundle starts the battle, whose redeemed Joseph starts the reunion.
UPDATE `gameobject_template` SET `ScriptName` = 'go_darrowshire_relic_bundle'
WHERE `entry` = 177526 AND `ScriptName` = '';

UPDATE `creature_template` SET `ScriptName` = 'npc_darrowshire_controller'
WHERE `entry` = 15384 AND `ScriptName` = '';

UPDATE `creature_template` SET `ScriptName` = 'npc_darrowshire_combatant'
WHERE `entry` IN (10937, 10938, 10939, 10944, 10948, 10949, 10950, 10954) AND `ScriptName` = '';

UPDATE `creature_template` SET `ScriptName` = 'npc_darrowshire_joseph'
WHERE `entry` = 10936 AND `ScriptName` = '';

UPDATE `creature_template` SET `ScriptName` = 'npc_darrowshire_pamela'
WHERE `entry` = 10926 AND `ScriptName` = '';
