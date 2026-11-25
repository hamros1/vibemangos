/// Staff roles for the login server and all world workers.
module dmangos.auth.staffroles;

import std.algorithm.searching : canFind;
import dmangos.auth.accounts : AccountLevel;
import dmangos.mysql : MySqlConnection;

struct GmAccess
{
    string[] roles;
    string[] grants;

    bool allows(string capability) const
    {
        return capability.length && (grants.canFind("*") || grants.canFind(capability));
    }

    AccountLevel rank() const
    {
        if (allows("staff.admin"))
            return AccountLevel.administrator;
        if (allows("staff.game_master"))
            return AccountLevel.gameMaster;
        return allows("staff.access") ? AccountLevel.moderator : AccountLevel.player;
    }
}

GmAccess staffAccess(MySqlConnection login, uint accountId)
{
    GmAccess access;
    foreach (row; login.query!("SELECT ar.role_name, COALESCE(p.capability,'') FROM dmangos_gm_account_role ar "
        ~ "LEFT JOIN dmangos_gm_role_permission p ON p.role_name=ar.role_name "
        ~ "WHERE ar.account_id=? ORDER BY ar.role_name,p.capability")(accountId))
    {
        const role = row.get!string(0), capability = row.get!string(1);
        if (!access.roles.canFind(role))
            access.roles ~= role;
        if (capability.length && !access.grants.canFind(capability))
            access.grants ~= capability;
    }
    return access;
}

bool staffRoleExists(MySqlConnection login, string role)
{
    return login.query!"SELECT role_name FROM dmangos_gm_role WHERE role_name=?"(role).length != 0;
}

bool changeStaffRole(MySqlConnection login, uint accountId, string role, bool grant)
{
    bool changed;
    login.transaction({
        changed = false;
        if (!login.query!"SELECT role_name FROM dmangos_gm_role WHERE role_name=? LOCK IN SHARE MODE"(role).length)
            return;
        if (grant)
        {
            login.execute!"INSERT IGNORE INTO dmangos_gm_enrollment (account_id) VALUES (?)"(accountId);
            login.execute!("INSERT INTO dmangos_gm_account_role (account_id, role_name) VALUES (?, ?) "
                ~ "ON DUPLICATE KEY UPDATE role_name=VALUES(role_name)")(accountId, role);
            changed = true;
        }
        else
            changed = login.execute!"DELETE FROM dmangos_gm_account_role WHERE account_id=? AND role_name=?"
                (accountId, role) != 0;
    });
    return changed;
}

string roleForRank(AccountLevel rank) pure @safe
{
    final switch (rank)
    {
    case AccountLevel.player: return null;
    case AccountLevel.moderator: return "support";
    case AccountLevel.gameMaster: return "game-master";
    case AccountLevel.administrator: return "administrator";
    }
}

/// Built-in roles for the in-memory login database.
string[] defaultRoleGrants(string role)
{
    switch (role)
    {
    case "administrator":
        return ["*"];
    case "support":
        return ["staff.discipline", "staff.access", "staff.support", "staff.tag", "staff.announce",
            "support.lookup", "support.tickets", "world.teleport", "character.mount"];
    case "game-master":
        return ["account.moderate", "battleground.manage", "character.combat", "character.learn", "character.modify",
            "character.mount", "debug.use", "guild.manage", "server.manage", "server.save", "staff.announce",
            "staff.access", "staff.discipline", "staff.disconnect", "staff.game_master", "staff.presence",
            "staff.support", "staff.tag", "support.lookup", "support.tickets", "testing.cheats",
            "world.creatures", "world.objects", "world.quests", "world.teleport",
            "world.trainers", "world.waypoints"];
    default:
        return null;
    }
}
