/// In-game role inspection and administration.
module dmangos.world.gmaccess;

public import dmangos.auth.staffroles : GmAccess;
import dmangos.world.database : WorldDatabase;

/// A policy read failure denies staff access.
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

mixin template AccessCommands()
{
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.format : format;

private:
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

    bool handleGmAccessGrantCommand(string username, string role)
    {
        return changeGmRole(username, role, true);
    }

    bool handleGmAccessRevokeCommand(string username, string role)
    {
        return changeGmRole(username, role, false);
    }

    private bool changeGmRole(string username, string role, bool grant)
    {
        import dmangos.mysql : DatabaseException;

        try
        {
            const target = context.database.findAccount(username);
            if (target.isNull)
                redSystemMessage(format!"Account %s was not found."(username));
            else if (!context.canWrite() || !context.database.changeGmRole(target.get.id, role, grant))
                redSystemMessage(format!"Could not %s %s for %s."(grant ? "grant" : "revoke", role, target.get.username));
            else
            {
                gmLog(format!"role %s %s for %s"(role, grant ? "granted" : "revoked", target.get.username));
                greenSystemMessage(format!"Role %s %s for %s."(role, grant ? "granted" : "revoked", target.get.username));
            }
        }
        catch (DatabaseException)
        {
            redSystemMessage("The login database could not update the role.");
        }
        return true;
    }
}
