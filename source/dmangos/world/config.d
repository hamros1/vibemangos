/**
 * World server configuration, read from a JSON file.
 *
 * The field initializers are the defaults. Settings with a CMaNGOS
 * `mangosd.conf` equivalent keep its meaning and default; the equivalent is
 * named in each field's comment.
 */
module dmangos.world.config;

import std.exception : enforce;
import std.format : format;

import dmangos.json;
import dmangos.log : LogLevel;

/// Settings for the world server.
struct WorldConfig
{
    /// `RealmID`: this server's row in `realmlist`.
    @JsonName("realm_id") uint realmId = 1;

    /// `LoginDatabaseInfo`
    @JsonName("login_database") string loginDatabase = "127.0.0.1;3306;mangos;mangos;classicrealmd";
    /// `WorldDatabaseInfo`
    @JsonName("world_database") string worldDatabase = "127.0.0.1;3306;mangos;mangos;classicmangos";
    /// `CharacterDatabaseInfo`
    @JsonName("character_database") string characterDatabase = "127.0.0.1;3306;mangos;mangos;classiccharacters";
    /// Path of the MySQL/MariaDB client library; empty searches the usual names.
    @JsonName("mysql_library") string mysqlLibrary;

    @JsonName("bind_address") string bindAddress = "0.0.0.0"; /// `BindIP`
    ushort port = 8085;                                         /// `WorldServerPort`

    /// Client builds this server accepts; written to `realmlist.realmbuilds` at start-up.
    @JsonName("allowed_builds") ushort[] allowedBuilds = [5875, 6005, 6141];

    /// `GameType`: realm type shown in the realm list (0 normal, 1 PvP, 4 normal, 6 RP, 8 RP-PvP).
    @JsonName("game_type") uint gameType = 1;
    /// `RealmZone`: realm category in the realm list.
    @JsonName("realm_zone") uint realmZone = 1;
    /// `PlayerLimit`: the population shown in the realm list is relative to this.
    @JsonName("player_limit") uint playerLimit = 100;
    /// `MaxOverspeedPings`: pings faster than every 27 seconds tolerated before a player is kicked (0 = off).
    @JsonName("max_overspeed_pings") uint maxOverspeedPings = 2;
    /// `UpdateUptimeInterval`, in minutes.
    @JsonName("uptime_update_interval") uint uptimeUpdateMinutes = 10;

    /// `DataDir`: the directory holding the extracted `dbc/` folder.
    @JsonName("data_dir") string dataDir = ".";

    /// `CharactersCreatingDisabled`: bit 0 blocks Alliance, bit 1 Horde, for player accounts.
    @JsonName("characters_creating_disabled") uint charactersCreatingDisabled = 0;
    /// `CharactersPerAccount`, over all realms.
    @JsonName("characters_per_account") uint charactersPerAccount = 50;
    /// `CharactersPerRealm`
    @JsonName("characters_per_realm") uint charactersPerRealm = 10;
    /// `AllowTwoSide.Accounts`: allow both factions on one account on PvP realms.
    @JsonName("allow_two_side_accounts") bool allowTwoSideAccounts = false;
    /// `AllowTwoSide.Interaction.Chat`: allow whispers between the factions.
    @JsonName("allow_two_side_interaction_chat") bool allowTwoSideInteractionChat = false;
    /// `AllowTwoSide.Interaction.Channel`: one set of chat channels for both factions.
    @JsonName("allow_two_side_interaction_channel") bool allowTwoSideInteractionChannel = false;
    /// `AllowTwoSide.Interaction.Group`: allow groups with both factions.
    @JsonName("allow_two_side_interaction_group") bool allowTwoSideInteractionGroup = false;
    /// `GM.ChannelModerationLevel`: the account level that moderates every channel; 0 for none.
    @JsonName("gm_level_channel_moderation") uint gmLevelChannelModeration = 1;
    /// `GM.ChannelSilentJoinLevel`: the account level that joins and leaves channels unannounced; 0 for none.
    @JsonName("gm_level_channel_silent_join") uint gmLevelChannelSilentJoin = 0;
    /// `Chat.RestrictedRaidWarnings`: raid warnings only in raids.
    @JsonName("chat_restricted_raid_warnings") bool chatRestrictedRaidWarnings = false;
    /// `Instance.IgnoreLevel`: enter dungeons whatever the level.
    @JsonName("instance_ignore_level") bool instanceIgnoreLevel = false;
    /// `Instance.IgnoreRaid`: enter raids without a raid group.
    @JsonName("instance_ignore_raid") bool instanceIgnoreRaid = false;
    /**
     * Not in `mangosd.conf` (CMaNGOS leaves this to its anticheat module): check that players move no
     * faster than they can run, give or take `movement_speed_tolerance` (a factor) plus
     * `movement_speed_slack` yards. A player caught is put back where it was. Game masters are not checked.
     */
    @JsonName("movement_speed_check") bool movementSpeedCheck = true;
    @JsonName("movement_speed_tolerance") float movementSpeedTolerance = 1.5f; /// ditto
    @JsonName("movement_speed_slack") float movementSpeedSlack = 15;           /// ditto
    /// `SkipCinematics`: 0 always show the intro, 1 skip it if the account has a character of that race, 2 never.
    @JsonName("skip_cinematics") uint skipCinematics = 0;
    /// `Motd`: shown in the chat window on entering the world; '@' starts a new line.
    string motd = "Welcome to dmangos.@Players see each other, group up and chat; creatures and combat are still to come.";

    /// `Visibility.Distance.Continents`: how far players see each other, in yards.
    @JsonName("visibility_distance") float visibilityDistance = 100;
    /// `Visibility.RelocationLowerLimit`: yards a player moves before visibility is recomputed.
    @JsonName("visibility_relocation_lower_limit") float visibilityRelocationLimit = 10;
    /// `ListenRange.Say`, `ListenRange.TextEmote`, `ListenRange.Yell`, in yards.
    @JsonName("listen_range_say") float listenRangeSay = 25;
    @JsonName("listen_range_text_emote") float listenRangeTextEmote = 25; /// ditto
    @JsonName("listen_range_yell") float listenRangeYell = 300;           /// ditto
    /// The world update tick, in milliseconds (mangosd's `WORLD_SLEEP_CONST`, 50).
    @JsonName("update_interval") uint updateIntervalMs = 50;
    /// `InstantLogout`: the account level that logs out at once; others wait 20 seconds unless resting.
    @JsonName("instant_logout") uint instantLogout = 1;
    /// `PlayerSave.Interval`, in seconds (mangosd: milliseconds).
    @JsonName("player_save_interval") uint playerSaveInterval = 900;
    /// `Rate.Health`, `Rate.Mana`, `Rate.Rage.Loss`, `Rate.Energy`: regeneration rates.
    @JsonName("rate_health") float rateHealth = 1;
    @JsonName("rate_mana") float rateMana = 1;              /// ditto
    @JsonName("rate_rage_loss") float rateRageLoss = 1;     /// ditto
    @JsonName("rate_energy") float rateEnergy = 1;          /// ditto
    /// `Rate.Rest.InGame`, `Rate.Rest.Offline.InTavernOrCity`, `Rate.Rest.Offline.InWilderness`.
    @JsonName("rate_rest_ingame") float rateRestInGame = 1;
    @JsonName("rate_rest_offline_in_tavern_or_city") float rateRestOfflineInTavernOrCity = 1; /// ditto
    @JsonName("rate_rest_offline_in_wilderness") float rateRestOfflineInWilderness = 1;       /// ditto
    /// `MaxPlayerLevel`
    @JsonName("max_player_level") uint maxPlayerLevel = 60;
    /// `StartPlayerLevel`
    @JsonName("start_player_level") uint startPlayerLevel = 1;
    /// `GM.StartLevel`, for moderator accounts and up.
    @JsonName("start_gm_level") uint startGmLevel = 1;
    /// `StartPlayerMoney`, in copper.
    @JsonName("start_player_money") uint startPlayerMoney = 0;
    /// `MaxPrimaryTradeSkill`
    @JsonName("max_primary_trade_skill") uint maxPrimaryTradeSkill = 2;
    /// `TradeSkill.GMIgnore.MaxPrimarySkillsCount`
    @JsonName("trade_skill_gm_ignore_max_primary") uint tradeSkillGmIgnoreMaxPrimary = 4;
    /// `StrictPlayerNames`: 0 any one script, bit 0 basic Latin, bit 1 the realm zone's script.
    @JsonName("strict_player_names") uint strictPlayerNames = 0;
    /// `MinPlayerName`
    @JsonName("min_player_name") uint minPlayerName = 2;
    /// `CharDelete.Method`: 0 delete, 1 unlink (keep the data, free the name).
    @JsonName("char_delete_method") uint charDeleteMethod = 0;
    /// `CharDelete.MinLevel`: characters below this level are always deleted outright.
    @JsonName("char_delete_min_level") uint charDeleteMinLevel = 0;
    /// `MailDeliveryDelay`, in seconds, for mail returned to another account.
    @JsonName("mail_delivery_delay") uint mailDeliveryDelay = 3600;

    /// Seconds without traffic before a connection is dropped (the client pings every 30 seconds).
    @JsonName("idle_timeout") uint idleTimeoutSeconds = 120;
    @JsonName("max_connections") uint maxConnections = 1000;
    @JsonName("log_level") LogLevel logLevel = LogLevel.info;

    /// Throws if the settings would not work at run time.
    void validate() const
    {
        import dmangos.auth.protocol : versionName;

        enforce(realmId > 0, "realm_id must be at least 1");
        enforce(allowedBuilds.length > 0, "allowed_builds must list at least one build");
        foreach (build; allowedBuilds)
            enforce(versionName(build) !is null, format!"build %s is not supported"(build));
        // select(2) cannot watch descriptors past FD_SETSIZE (1024 on Linux).
        enforce(maxConnections > 0 && maxConnections <= 1000, "max_connections must be between 1 and 1000");
        enforce(idleTimeoutSeconds > 30, "idle_timeout must be longer than the client's 30 second ping interval");
        enforce(uptimeUpdateMinutes > 0, "uptime_update_interval must be positive");
        enforce(charactersPerRealm >= 1 && charactersPerRealm <= 10, "characters_per_realm must be between 1 and 10");
        enforce(charactersPerAccount >= charactersPerRealm, "characters_per_account must be >= characters_per_realm");
        enforce(skipCinematics <= 2, "skip_cinematics must be 0, 1 or 2");
        enforce(startPlayerLevel >= 1 && startGmLevel >= startPlayerLevel, "start levels must be >= 1, GM >= player");
        enforce(charDeleteMethod <= 1, "char_delete_method must be 0 or 1");
    }
}

/// Loads and validates the configuration at `path`.
WorldConfig loadWorldConfig(string path)
{
    import std.file : exists, readText;
    import std.json : parseJSON;

    enforce(path.exists, format!"configuration file '%s' not found (copy config/worldserver.example.json)"(path));
    auto config = fromJson!WorldConfig(parseJSON(readText(path)));
    config.validate();
    return config;
}

unittest
{
    import std.json : parseJSON;

    WorldConfig defaults;
    defaults.validate();
    assert(defaults.port == 8085 && defaults.realmId == 1);

    const config = fromJson!WorldConfig(parseJSON(`{"realm_id": 2, "game_type": 6, "port": 8086}`));
    config.validate();
    assert(config.realmId == 2 && config.gameType == 6 && config.port == 8086);
    assert(config.characterDatabase == "127.0.0.1;3306;mangos;mangos;classiccharacters");
}
