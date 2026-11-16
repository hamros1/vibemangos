/**
 * Entry point of the world server.
 *
 * ---
 * worldserver [--config FILE]
 * ---
 */
module dmangos.world.main;

import core.time : minutes, MonoTime, seconds;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.stdio : stderr;

import dmangos.log;
import dmangos.mysql : ConnectionInfo, MySqlConnection;
import dmangos.net.server : installShutdownHandlers, NetSession, ServerOptions, TcpServer;
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
        run(config);
        return 0;
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

private void run(WorldConfig config)
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
    auto context = new WorldContext(config, new MySqlWorldDatabase(login, characters), data, client);
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
        ServerOptions(config.bindAddress, config.port, config.idleTimeoutSeconds.seconds, config.maxConnections),
        (string address) => cast(NetSession) new WorldSession(context, address),
        (MonoTime now) {
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
}

private MySqlConnection connect(string connectionString, string library, string what)
{
    const connection = ConnectionInfo.parse(connectionString);
    info!"%s database: %s"(what, connection.toString);
    return new MySqlConnection(connection, library);
}
