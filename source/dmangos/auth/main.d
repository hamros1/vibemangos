/**
 * Entry point of the login server.
 *
 * ---
 * authserver [--config FILE]                                  run the server
 * authserver [--config FILE] account create NAME PASSWORD [LEVEL]
 * authserver [--config FILE] account password NAME PASSWORD
 * authserver [--config FILE] account level NAME LEVEL
 * authserver [--config FILE] account ban NAME [DAYS] [REASON]
 * authserver [--config FILE] account unban NAME
 * authserver [--config FILE] account list
 * authserver [--config FILE] ip ban ADDRESS [DAYS] [REASON]
 * authserver [--config FILE] ip unban ADDRESS
 * ---
 */
module dmangos.auth.main;

import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult, getoptConfig = config;
import std.stdio : stderr, writefln, writeln;

import dmangos.log;
import dmangos.mysql : ConnectionInfo;
import dmangos.auth.accounts;
import dmangos.auth.config : AuthConfig, loadConfig;
import dmangos.auth.context : AuthContext;
import dmangos.auth.database : LoginDatabase;
import dmangos.auth.mysqldb : MySqlLoginDatabase;
import dmangos.auth.protocol : supportedBuilds;
import dmangos.auth.session : AuthSession;
import dmangos.net.server : installShutdownHandlers, NetSession, ServerOptions, TcpServer;

private enum usage = "dmangos login server for 1.12.x clients, on a CMaNGOS realmd database

Usage:
  authserver [--config FILE]
  authserver [--config FILE] account create NAME PASSWORD [player|moderator|gameMaster|administrator]
  authserver [--config FILE] account password NAME PASSWORD
  authserver [--config FILE] account level NAME LEVEL
  authserver [--config FILE] account ban NAME [DAYS] [REASON]     (no DAYS, or 0: permanent)
  authserver [--config FILE] account unban NAME
  authserver [--config FILE] account list
  authserver [--config FILE] ip ban ADDRESS [DAYS] [REASON]
  authserver [--config FILE] ip unban ADDRESS
";

/// Recorded as `banned_by`/`unbanned_by` for bans made from the command line.
private enum consoleAuthor = "[Console]";

int main(string[] args)
{
    enableConsoleLogColors();
    string configPath = "authserver.json";
    GetoptResult options;
    try
        options = getopt(args, getoptConfig.stopOnFirstNonOption,
            "config|c", "Configuration file (default: authserver.json)", &configPath);
    catch (GetOptException e)
    {
        stderr.writeln(e.msg);
        return 2;
    }
    if (options.helpWanted)
    {
        defaultGetoptPrinter(usage, options.options);
        return 0;
    }

    try
    {
        auto config = loadConfig(configPath);
        setLogLevel(config.logLevel);

        auto database = new MySqlLoginDatabase(ConnectionInfo.parse(config.loginDatabase), config.mysqlLibrary);
        scope (exit)
            database.close();

        if (args.length > 1)
            return runCommand(database, args[1 .. $]);

        info!"login database: %s"(ConnectionInfo.parse(config.loginDatabase).toString);
        foreach (known; supportedBuilds)
            if (config.allowedBuilds.canFind(known.build))
                info!"accepting client %s (build %s)"(known.versionName, known.build);

        installShutdownHandlers();
        runServer(config, database);
        return 0;
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

private void runServer(AuthConfig config, LoginDatabase database)
{
    import core.time : MonoTime, minutes, seconds;

    auto context = new AuthContext(config, database);
    auto lastPrune = MonoTime.currTime;
    auto server = new TcpServer(
        ServerOptions(config.bindAddress, config.port, config.idleTimeoutSeconds.seconds, config.maxConnections),
        (string address) => cast(NetSession) new AuthSession(context, address),
        (MonoTime now) {
            if (now - lastPrune >= 1.minutes)
            {
                context.throttle.prune(now);
                lastPrune = now;
            }
        });
    server.run();
}

// ---------------------------------------------------------------------------
// Administration commands
// ---------------------------------------------------------------------------

private alias Command = int function(LoginDatabase database, string[] args);

private int runCommand(LoginDatabase database, string[] args)
{
    // The command table is a built-in associative array keyed by "group command".
    Command[string] commands = [
        "account create": &createAccount,
        "account password": &changePassword,
        "account level": &changeLevel,
        "account ban": &banAccount,
        "account unban": &unbanAccount,
        "account list": &listAccounts,
        "ip ban": &banAddress,
        "ip unban": &unbanAddress,
    ];

    enforce(args.length >= 2, "missing command\n" ~ usage);
    auto command = (args[0] ~ " " ~ args[1]) in commands;
    enforce(command !is null, "unknown command '" ~ args[0] ~ " " ~ args[1] ~ "'\n" ~ usage);
    return (*command)(database, args[2 .. $]);
}

private int createAccount(LoginDatabase database, string[] args)
{
    enforce(args.length == 2 || args.length == 3, "usage: account create NAME PASSWORD [LEVEL]");
    const level = args.length == 3 ? args[2].to!AccountLevel : AccountLevel.player;
    const account = database.createAccount(args[0], args[1], level);
    writefln("created account %s (id %s, level %s)", account.username, account.id, account.level);
    return 0;
}

private int changePassword(LoginDatabase database, string[] args)
{
    enforce(args.length == 2, "usage: account password NAME PASSWORD");
    database.setPassword(args[0], args[1]);
    writefln("password of %s changed", canonicalAccountName(args[0]));
    return 0;
}

private int changeLevel(LoginDatabase database, string[] args)
{
    enforce(args.length == 2, "usage: account level NAME LEVEL (player, moderator, gameMaster, administrator)");
    database.setLevel(args[0], args[1].to!AccountLevel);
    writefln("%s is now %s", canonicalAccountName(args[0]), args[1]);
    return 0;
}

/// The ban length and reason given to a ban command.
private struct BanArguments
{
    uint seconds; /// 0 = permanent
    string reason;
}

/// Parses the optional `[DAYS] [REASON...]` tail of the ban commands.
private BanArguments parseBan(string[] args)
{
    import std.array : join;

    return BanArguments(args.length > 0 ? args[0].to!uint * 86_400 : 0,
        args.length > 1 ? args[1 .. $].join(" ") : "no reason");
}

private string describeBan(uint seconds)
{
    import std.format : format;

    return seconds == 0 ? "permanently" : format!"for %s days"(seconds / 86_400);
}

private int banAccount(LoginDatabase database, string[] args)
{
    enforce(args.length >= 1, "usage: account ban NAME [DAYS] [REASON]");
    const account = database.findAccount(args[0]);
    enforce(!account.isNull, "no account named '" ~ canonicalAccountName(args[0]) ~ "'");
    const ban = parseBan(args[1 .. $]);
    database.banAccount(account.get.id, ban.seconds, consoleAuthor, ban.reason);
    writefln("%s banned %s", account.get.username, describeBan(ban.seconds));
    return 0;
}

private int unbanAccount(LoginDatabase database, string[] args)
{
    enforce(args.length == 1, "usage: account unban NAME");
    const account = database.findAccount(args[0]);
    enforce(!account.isNull, "no account named '" ~ canonicalAccountName(args[0]) ~ "'");
    database.unbanAccount(account.get.id, consoleAuthor);
    writefln("%s unbanned", account.get.username);
    return 0;
}

private int listAccounts(LoginDatabase database, string[] args)
{
    enforce(args.length == 0, "usage: account list");
    writefln("%5s  %-16s  %-13s  %-9s  %-15s  %s", "id", "name", "level", "ban", "locked to", "failed logins");
    foreach (account; database.listAccounts())
        writefln("%5s  %-16s  %-13s  %-9s  %-15s  %s", account.id, account.username, account.level,
            account.ban, account.locked ? account.lockedIp : "-", account.failedLogins);
    return 0;
}

private int banAddress(LoginDatabase database, string[] args)
{
    enforce(args.length >= 1, "usage: ip ban ADDRESS [DAYS] [REASON]");
    const ban = parseBan(args[1 .. $]);
    database.banIp(args[0], ban.seconds, consoleAuthor, ban.reason);
    writefln("%s banned %s", args[0], describeBan(ban.seconds));
    return 0;
}

private int unbanAddress(LoginDatabase database, string[] args)
{
    enforce(args.length == 1, "usage: ip unban ADDRESS");
    database.unbanIp(args[0]);
    writefln("%s unbanned", args[0]);
    return 0;
}
