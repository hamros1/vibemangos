-- Run against the login database. Safe to apply again.
CREATE TABLE IF NOT EXISTS dmangos_gm_role (
    role_name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    description VARCHAR(200) NOT NULL,
    PRIMARY KEY (role_name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dmangos_gm_role_permission (
    role_name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    capability VARCHAR(120) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (role_name, capability),
    FOREIGN KEY (role_name) REFERENCES dmangos_gm_role(role_name) ON DELETE CASCADE
) ENGINE=InnoDB;

-- An enrolled account keeps its policy even when its last role is revoked.
CREATE TABLE IF NOT EXISTS dmangos_gm_enrollment (
    account_id INT UNSIGNED NOT NULL,
    PRIMARY KEY (account_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS dmangos_gm_account_role (
    account_id INT UNSIGNED NOT NULL,
    role_name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (account_id, role_name),
    FOREIGN KEY (account_id) REFERENCES dmangos_gm_enrollment(account_id) ON DELETE CASCADE,
    FOREIGN KEY (role_name) REFERENCES dmangos_gm_role(role_name) ON DELETE CASCADE
) ENGINE=InnoDB;

INSERT IGNORE INTO dmangos_gm_role VALUES
    ('support', 'Player support, moderation, and relocation'),
    ('game-master', 'Gameplay, content editing, and event operation'),
    ('administrator', 'All capabilities, including role administration');

INSERT IGNORE INTO dmangos_gm_role_permission VALUES
    ('administrator', '*'),
    ('support', 'staff.discipline'),
    ('support', 'staff.access'),
    ('support', 'staff.support'),
    ('support', 'staff.tag'),
    ('support', 'staff.announce'),
    ('support', 'support.lookup'),
    ('support', 'support.tickets'),
    ('support', 'world.teleport'),
    ('support', 'character.mount');

INSERT IGNORE INTO dmangos_gm_role_permission VALUES
    ('game-master', 'account.moderate'),
    ('game-master', 'battleground.manage'),
    ('game-master', 'character.combat'),
    ('game-master', 'character.learn'),
    ('game-master', 'character.modify'),
    ('game-master', 'character.mount'),
    ('game-master', 'debug.use'),
    ('game-master', 'guild.manage'),
    ('game-master', 'server.manage'),
    ('game-master', 'server.save'),
    ('game-master', 'staff.announce'),
    ('game-master', 'staff.access'),
    ('game-master', 'staff.discipline'),
    ('game-master', 'staff.disconnect'),
    ('game-master', 'staff.game_master'),
    ('game-master', 'staff.presence'),
    ('game-master', 'staff.support'),
    ('game-master', 'staff.tag'),
    ('game-master', 'support.lookup'),
    ('game-master', 'support.tickets'),
    ('game-master', 'testing.cheats'),
    ('game-master', 'world.creatures'),
    ('game-master', 'world.objects'),
    ('game-master', 'world.quests'),
    ('game-master', 'world.teleport'),
    ('game-master', 'world.trainers'),
    ('game-master', 'world.waypoints');

-- world.objects.move no longer exists: moving and rotating game objects needs world.objects.
DELETE FROM dmangos_gm_role_permission WHERE capability='world.objects.move';
