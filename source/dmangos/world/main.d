/**
 * Entry point of the world server.
 *
 * ---
 * worldserver [--config FILE]
 * ---
 */
module dmangos.world.main;

import core.time : minutes, MonoTime, msecs, seconds;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.stdio : stderr;

import dmangos.log;
import dmangos.mysql : ConnectionInfo, MySqlConnection;
import dmangos.auth.mysqldb : MySqlLoginDatabase;
import dmangos.net.server : installShutdownHandlers, NetSession, requestShutdown, ServerOptions, TcpServer;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : loadWorldConfig, WorldConfig;
import dmangos.world.context : WorldContext;
import dmangos.world.database : MySqlWorldDatabase;
import dmangos.world.realm : RealmRegistration;
import dmangos.world.session : WorldSession;
import dmangos.world.worlddata : WorldData;

private enum usage = "dmangos world server for 1.12.x clients, on CMaNGOS databases

Usage:
  worldserver [--config FILE]
";

int main(string[] args)
{
    string configPath = "worldserver.json";
    GetoptResult options;
    try
        options = getopt(args, "config|c", "Configuration file (default: worldserver.json)", &configPath);
    catch (GetOptException e)
    {
        stderr.writeln(e.msg);
        return 2;
    }
    if (options.helpWanted || args.length > 1)
    {
        defaultGetoptPrinter(usage, options.options);
        return options.helpWanted ? 0 : 2;
    }

    try
    {
        auto config = loadWorldConfig(configPath);
        setLogLevel(config.logLevel);
        return run(config, configPath);
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

/// `mangosd`'s exit code for a restart (`RESTART_EXIT_CODE`), for a script that starts it again.
private enum restartExitCode = 2;

private int run(WorldConfig config, string configPath)
{
    auto login = connect(config.loginDatabase, config.mysqlLibrary, "login");
    scope (exit)
        login.close();
    auto characters = connect(config.characterDatabase, config.mysqlLibrary, "character");
    scope (exit)
        characters.close();
    auto world = connect(config.worldDatabase, config.mysqlLibrary, "world");
    scope (exit)
        world.close();

    auto client = ClientData.load(config.dataDir);
    auto data = WorldData.load(world, client);
    auto context = new WorldContext(config, new MySqlWorldDatabase(login, characters, world), data, client,
        new MySqlLoginDatabase(login));
    context.configPath = configPath;
    context.database.markAllOffline(config.realmId); // as clearOnlineAccounts: nobody is online after a restart
    info!"next ids: character %s, item %s, mail %s"(context.next.character, context.next.item, context.next.mail);

    auto realm = new RealmRegistration(login, config.realmId);
    realm.markOnline(config.allowedBuilds, config.gameType, config.realmZone);
    scope (exit)
        realm.markOffline();

    auto lastPopulation = MonoTime.currTime;
    auto lastUptime = MonoTime.currTime;
    const uptimeInterval = config.uptimeUpdateMinutes.minutes;

    installShutdownHandlers();
    auto server = new TcpServer(
        ServerOptions(config.bindAddress, config.port, config.idleTimeoutSeconds.seconds, config.maxConnections,
            config.updateIntervalMs.msecs),
        (string address) => cast(NetSession) new WorldSession(context, address),
        (MonoTime now) {
            if (context.update(now))
                requestShutdown();
            if (now - lastPopulation >= 1.minutes)
            {
                realm.updatePopulation(context.sessionCount, config.playerLimit);
                lastPopulation = now;
            }
            if (now - lastUptime >= uptimeInterval)
            {
                realm.updateUptime(cast(uint) context.peakSessions);
                lastUptime = now;
            }
        });
    server.run();
    realm.updateUptime(cast(uint) context.peakSessions);
    return context.restartRequested ? restartExitCode : 0;
}

private MySqlConnection connect(string connectionString, string library, string what)
{
    const connection = ConnectionInfo.parse(connectionString);
    info!"%s database: %s"(what, connection.toString);
    return new MySqlConnection(connection, library);
}
