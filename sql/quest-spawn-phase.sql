-- Optional extension to the Classic-DB world database. This creates an empty rule table.
CREATE TABLE IF NOT EXISTS `quest_spawn_phase` (
  `spawn_type` varchar(10) NOT NULL,
  `spawn_guid` int unsigned NOT NULL,
  `quest_id` int unsigned NOT NULL,
  `visible_states` tinyint unsigned NOT NULL COMMENT '1 inactive, 2 active, 4 complete, 8 rewarded, 16 failed',
  PRIMARY KEY (`spawn_type`, `spawn_guid`, `quest_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
