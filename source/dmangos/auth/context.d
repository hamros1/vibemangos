/// State shared by every session on a login server.
module dmangos.auth.context;

import core.time : seconds;

import dmangos.crypto.random : secureRandom;
import dmangos.auth.config : AuthConfig;
import dmangos.auth.database : LoginDatabase;
import dmangos.auth.realms : RealmCache;
import dmangos.auth.throttle : LoginThrottle;

/**
 * Configuration, database, realm list and throttle shared by all sessions.
 *
 * The server runs a single-threaded event loop, so none of this needs locking.
 */
final class AuthContext
{
    AuthConfig config;
    LoginDatabase database;
    RealmCache realms;
    LoginThrottle throttle;

    /// Per-process secret behind the fake challenges sent for unknown accounts.
    immutable ubyte[20] fakeAccountSecret;

    ///
    this(AuthConfig config, LoginDatabase database)
    in (database !is null, "a login database is required")
    {
        this.config = config;
        this.database = database;
        this.realms = new RealmCache(&database.loadRealms, config.realmsStateUpdateDelay);
        this.throttle = LoginThrottle(config.maxFailedLogins, config.failedLoginBlockSeconds.seconds);
        this.fakeAccountSecret = secureRandom!20;
    }
}
