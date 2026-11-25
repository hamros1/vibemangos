-- CMaNGOS classic schema. See NOTICE.md for attribution.
-- Fresh installation. Apply to an empty classicrealmd database.

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `account` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Identifier',
  `username` varchar(32) NOT NULL DEFAULT '',
  `gmlevel` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `sessionkey` longtext DEFAULT NULL,
  `v` longtext DEFAULT NULL,
  `s` longtext DEFAULT NULL,
  `email` text DEFAULT NULL,
  `joindate` datetime NOT NULL DEFAULT current_timestamp(),
  `lockedIp` varchar(30) NOT NULL DEFAULT '0.0.0.0',
  `failed_logins` int(11) unsigned NOT NULL DEFAULT 0,
  `locked` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `last_module` char(32) DEFAULT '',
  `module_day` mediumint(8) unsigned NOT NULL DEFAULT 0,
  `active_realm_id` int(11) unsigned NOT NULL DEFAULT 0,
  `expansion` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `mutetime` bigint(40) unsigned NOT NULL DEFAULT 0,
  `locale` varchar(4) NOT NULL DEFAULT '',
  `os` varchar(4) NOT NULL DEFAULT '0',
  `platform` varchar(4) NOT NULL DEFAULT '0',
  `token` text DEFAULT NULL,
  `flags` int(10) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_username` (`username`),
  KEY `idx_gmlevel` (`gmlevel`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Account System';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `account_banned` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `account_id` int(11) NOT NULL DEFAULT 0 COMMENT 'Account id',
  `banned_at` bigint(40) NOT NULL DEFAULT 0,
  `expires_at` bigint(40) NOT NULL DEFAULT 0,
  `banned_by` varchar(50) NOT NULL,
  `unbanned_at` bigint(40) NOT NULL DEFAULT 0,
  `unbanned_by` varchar(50) DEFAULT NULL,
  `reason` varchar(255) NOT NULL,
  `active` tinyint(4) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Ban List';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `account_logons` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `accountId` int(10) unsigned NOT NULL,
  `ip` varchar(30) NOT NULL,
  `loginTime` timestamp NOT NULL,
  `loginSource` int(10) unsigned NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `account_raf` (
  `referrer` int(10) unsigned NOT NULL DEFAULT 0,
  `referred` int(10) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`referrer`,`referred`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_swedish_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `antispam_blacklist` (
  `string` varchar(64) NOT NULL,
  PRIMARY KEY (`string`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `antispam_replacement` (
  `from` varchar(32) NOT NULL DEFAULT '',
  `to` varchar(32) NOT NULL DEFAULT '',
  PRIMARY KEY (`from`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `antispam_unicode_replacement` (
  `from` mediumint(5) unsigned NOT NULL DEFAULT 0,
  `to` mediumint(5) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`from`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `ip_banned` (
  `ip` varchar(32) NOT NULL DEFAULT '0.0.0.0',
  `banned_at` bigint(40) NOT NULL,
  `expires_at` bigint(40) NOT NULL,
  `banned_by` varchar(50) NOT NULL DEFAULT '[Console]',
  `reason` varchar(255) NOT NULL DEFAULT 'no reason',
  PRIMARY KEY (`ip`,`banned_at`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Banned IPs';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `realmcharacters` (
  `realmid` int(11) unsigned NOT NULL DEFAULT 0,
  `acctid` bigint(20) unsigned NOT NULL,
  `numchars` tinyint(3) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`realmid`,`acctid`),
  KEY `acctid` (`acctid`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Realm Character Tracker';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `realmd_db_version` (
  `required_z2820_01_realmd_joindate_datetime` bit(1) DEFAULT NULL
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Last applied sql update to DB';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `realmlist` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(32) NOT NULL DEFAULT '',
  `address` varchar(32) NOT NULL DEFAULT '127.0.0.1',
  `port` int(11) NOT NULL DEFAULT 8085,
  `icon` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `realmflags` tinyint(3) unsigned NOT NULL DEFAULT 2 COMMENT 'Supported masks: 0x1 (invalid, not show in realm list), 0x2 (offline, set by mangosd), 0x4 (show version and build), 0x20 (new players), 0x40 (recommended)',
  `timezone` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `allowedSecurityLevel` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `population` float unsigned NOT NULL DEFAULT 0,
  `realmbuilds` varchar(64) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_name` (`name`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Realm System';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `system_fingerprint_usage` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `fingerprint` int(10) unsigned NOT NULL,
  `account` int(10) unsigned NOT NULL,
  `ip` varchar(16) NOT NULL,
  `realm` int(10) unsigned NOT NULL,
  `time` datetime DEFAULT NULL,
  `architecture` varchar(16) DEFAULT NULL,
  `cputype` varchar(64) DEFAULT NULL,
  `activecpus` int(10) unsigned DEFAULT NULL,
  `totalcpus` int(10) unsigned DEFAULT NULL,
  `pagesize` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fingerprint` (`fingerprint`),
  KEY `account` (`account`),
  KEY `ip` (`ip`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `uptime` (
  `realmid` int(11) unsigned NOT NULL,
  `starttime` bigint(20) unsigned NOT NULL DEFAULT 0,
  `startstring` varchar(64) NOT NULL DEFAULT '',
  `uptime` bigint(20) unsigned NOT NULL DEFAULT 0,
  `maxplayers` smallint(5) unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (`realmid`,`starttime`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Uptime system';
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
CREATE TABLE IF NOT EXISTS d_battlegroup_host (
  battlegroup VARBINARY(128) NOT NULL PRIMARY KEY,
  topology VARBINARY(1024) NOT NULL,
  host_slot TINYINT UNSIGNED NOT NULL DEFAULT 0,
  owner_token BIGINT UNSIGNED NOT NULL DEFAULT 0,
  expires_at DATETIME(6) NOT NULL DEFAULT '1970-01-01 00:00:00'
) ENGINE=InnoDB;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

INSERT INTO realmd_db_version VALUES (NULL);

-- One realm for the whole cluster. The coordinator publishes client endpoints at runtime.
INSERT INTO realmlist (id, name, address, port, icon, realmflags, timezone)
VALUES (1, 'dmangos', '127.0.0.1', 8085, 1, 2, 1);

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
    ('support', 'world.objects.move'),
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
    ('game-master', 'world.objects.move'),
    ('game-master', 'world.quests'),
    ('game-master', 'world.teleport'),
    ('game-master', 'world.trainers'),
    ('game-master', 'world.waypoints');
