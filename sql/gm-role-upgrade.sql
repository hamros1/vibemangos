-- Apply after gm-rbac.sql when upgrading an existing login database.
-- Staff access is loaded exclusively from the role tables by the new servers.
-- The enrollment row marks accounts that have already adopted roles, including
-- accounts whose last role was revoked.
SET @has_old_level = (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema=DATABASE() AND table_name='account' AND column_name='gmlevel'
);

CREATE TEMPORARY TABLE dmangos_staff_upgrade (
    account_id INT UNSIGNED NOT NULL PRIMARY KEY,
    role_name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL
) ENGINE=InnoDB;

SET @copy_staff = IF(@has_old_level,
    'INSERT INTO dmangos_staff_upgrade SELECT a.id, CASE a.gmlevel WHEN 1 THEN ''support'' WHEN 2 THEN ''game-master'' ELSE ''administrator'' END FROM account a LEFT JOIN dmangos_gm_enrollment e ON e.account_id=a.id WHERE a.gmlevel>0 AND e.account_id IS NULL',
    'SELECT 1 WHERE FALSE');
PREPARE staff_upgrade FROM @copy_staff;
EXECUTE staff_upgrade;
DEALLOCATE PREPARE staff_upgrade;

START TRANSACTION;
INSERT INTO dmangos_gm_enrollment SELECT account_id FROM dmangos_staff_upgrade;
INSERT INTO dmangos_gm_account_role SELECT account_id, role_name FROM dmangos_staff_upgrade;
COMMIT;

DROP TEMPORARY TABLE dmangos_staff_upgrade;
