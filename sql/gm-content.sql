-- Durable staff edits belong beside the world data shared by the workers.
CREATE TABLE IF NOT EXISTS dmangos_gm_spawn_link (
    follower INT UNSIGNED NOT NULL,
    leader INT UNSIGNED NOT NULL,
    flags INT UNSIGNED NOT NULL DEFAULT 0,
    has_offset BOOLEAN NOT NULL DEFAULT FALSE,
    distance FLOAT NOT NULL DEFAULT 0,
    angle FLOAT NOT NULL DEFAULT 0,
    PRIMARY KEY (follower)
) ENGINE=InnoDB;

-- A row lock serializes edits so simultaneous commands cannot create a cycle.
INSERT IGNORE INTO dmangos_gm_spawn_link (follower, leader) VALUES (0, 0);

CREATE TABLE IF NOT EXISTS dmangos_gm_waypoint (
    spawn INT UNSIGNED NOT NULL,
    point MEDIUMINT UNSIGNED NOT NULL,
    gait TINYINT UNSIGNED NOT NULL DEFAULT 0,
    emote INT UNSIGNED NOT NULL DEFAULT 0,
    model INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (spawn, point)
) ENGINE=InnoDB;
