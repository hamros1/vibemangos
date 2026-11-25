-- Run against each world database before using .waypoint save.
-- Classic-DB uses MyISAM for these tables. The route and the spawn's
-- movement type must commit together so readers never see a partial edit.
ALTER TABLE creature ENGINE=InnoDB ROW_FORMAT=DYNAMIC;
ALTER TABLE creature_movement ENGINE=InnoDB ROW_FORMAT=DYNAMIC;
