/**
 * In-game role inspection and administration.
 *
 * `.access`: one's own roles and capabilities, and roles granted to and revoked from accounts.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmaccess;

import dmangos.world.character : Character;

public import dmangos.auth.staffroles : GmAccess;
import dmangos.world.database : WorldDatabase;

/// The account's staff access; none if the database cannot be read.
GmAccess readGmAccess(WorldDatabase database, uint accountId)
{
    import dmangos.log : warning;
    import dmangos.mysql : DatabaseException;

    try
        return database.gmAccessFor(accountId);
    catch (DatabaseException error)
    {
        warning!"Could not read GM access for account %s: %s"(accountId, error.msg);
        return GmAccess.init;
    }
}

import std.algorithm.searching : canFind;
import std.array : join;
import std.format : format;
import dmangos.mysql : DatabaseException;

/// `.access status`: this player's roles and capabilities.
bool handleGmAccessInfoCommand(Character gm)
{
    gm.greenSystemMessage("Staff access");
    gm.systemMessage("Roles: " ~ (gm.gmAccess.roles.length ? gm.gmAccess.roles.join(", ") : "None"));
    if (gm.gmAccess.grants.canFind("*"))
        gm.systemMessage("Capabilities: All");
    else if (gm.gmAccess.grants.length)
        foreach (capability; gm.gmAccess.grants)
            gm.blueSystemMessage(capability);
    else
        gm.systemMessage("Capabilities: None");
    return true;
}

/// `.access grant <account> <role>`.
bool handleGmAccessGrantCommand(Character gm, string username, string role)
{
    return gm.changeGmRole(username, role, true);
}

/// `.access revoke <account> <role>`.
bool handleGmAccessRevokeCommand(Character gm, string username, string role)
{
    return gm.changeGmRole(username, role, false);
}

/// Grants (or revokes) `role` for the account `username` in the login database.
bool changeGmRole(Character gm, string username, string role, bool grant)
{
    try
    {
        const target = gm.context.database.findAccount(username);
        if (target.isNull)
        {
            gm.redSystemMessage(format!"Account %s was not found."(username));
            return true;
        }
        const name = target.get.username;
        if (!gm.context.canWrite() || !gm.context.database.changeGmRole(target.get.id, role, grant))
        {
            gm.redSystemMessage(format!"Could not %s %s for %s."(grant ? "grant" : "revoke", role, name));
            return true;
        }
        const done = grant ? "granted" : "revoked";
        gm.gmLog(format!"role %s %s for %s"(role, done, name));
        gm.greenSystemMessage(format!"Role %s %s for %s."(role, done, name));
    }
    catch (DatabaseException)
        gm.redSystemMessage("The login database could not update the role.");
    return true;
}

