/// In-game role inspection and administration.
module dmangos.world.gmaccess;

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

/// `.access`: one's own roles and capabilities, and roles granted to and revoked from accounts.
mixin template AccessCommands()
{
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.format : format;
    import dmangos.mysql : DatabaseException;

private:
    /// `.access status`: this player's roles and capabilities.
    bool handleGmAccessInfoCommand()
    {
        greenSystemMessage("Staff access");
        systemMessage("Roles: " ~ (gmAccess.roles.length ? gmAccess.roles.join(", ") : "None"));
        if (gmAccess.grants.canFind("*"))
            systemMessage("Capabilities: All");
        else if (gmAccess.grants.length)
            foreach (capability; gmAccess.grants)
                blueSystemMessage(capability);
        else
            systemMessage("Capabilities: None");
        return true;
    }

    /// `.access grant <account> <role>`.
    bool handleGmAccessGrantCommand(string username, string role)
    {
        return changeGmRole(username, role, true);
    }

    /// `.access revoke <account> <role>`.
    bool handleGmAccessRevokeCommand(string username, string role)
    {
        return changeGmRole(username, role, false);
    }

    /// Grants (or revokes) `role` for the account `username` in the login database.
    bool changeGmRole(string username, string role, bool grant)
    {
        try
        {
            const target = context.database.findAccount(username);
            if (target.isNull)
            {
                redSystemMessage(format!"Account %s was not found."(username));
                return true;
            }
            const name = target.get.username;
            if (!context.canWrite() || !context.database.changeGmRole(target.get.id, role, grant))
            {
                redSystemMessage(format!"Could not %s %s for %s."(grant ? "grant" : "revoke", role, name));
                return true;
            }
            const done = grant ? "granted" : "revoked";
            gmLog(format!"role %s %s for %s"(role, done, name));
            greenSystemMessage(format!"Role %s %s for %s."(role, done, name));
        }
        catch (DatabaseException)
            redSystemMessage("The login database could not update the role.");
        return true;
    }
}
