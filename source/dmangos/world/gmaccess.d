/// Named capabilities for staff accounts. Legacy levels apply only before enrollment.
module dmangos.world.gmaccess;

import std.algorithm.searching : canFind;
import dmangos.auth.accounts : AccountLevel;
import dmangos.world.database : WorldDatabase;

struct GmAccess
{
    bool managed;
    string[] roles;
    string[] grants;

    bool allows(string capability) const
    {
        return capability.length && (grants.canFind("*") || grants.canFind(capability));
    }

    AccountLevel rank(AccountLevel legacyLevel) const
    {
        if (!managed)
            return legacyLevel;
        if (allows("staff.admin"))
            return AccountLevel.administrator;
        if (allows("staff.game_master"))
            return AccountLevel.gameMaster;
        return allows("staff.access") ? AccountLevel.moderator : AccountLevel.player;
    }
}

/// A policy read failure closes access. The implementation recognizes schemas predating RBAC.
GmAccess readGmAccess(WorldDatabase database, uint accountId)
{
    import dmangos.log : warning;
    import dmangos.mysql : DatabaseException;

    try
        return database.gmAccessFor(accountId);
    catch (DatabaseException error)
    {
        warning!"Could not read GM access for account %s: %s"(accountId, error.msg);
        return GmAccess(true);
    }
}

/// Compatibility mapping for command rows and the existing staff feature checks.
string gmCapability(char group) pure nothrow @safe @nogc
{
    switch (group)
    {
    case '0': return null;
    case '1': return "support.lookup";
    case '2', 'q': return "world.quests";
    case 'a': return "account.moderate";
    case 'b': return "staff.discipline";
    case 'f': return "staff.disconnect";
    case 'c': return "staff.support";
    case 'd': return "debug.use";
    case 'e': return "battleground.manage";
    case 'g': return "world.objects.move";
    case 'o': return "world.objects";
    case 'h': return "character.mount";
    case 'i', 'j': return "staff.presence";
    case 'l': return "support.lookup";
    case 'm': return "character.modify";
    case 'n': return "world.creatures";
    case 'r': return "character.combat";
    case 's': return "server.save";
    case 't': return "staff.tag";
    case 'u': return "staff.announce";
    case 'v': return "world.teleport";
    case 'w': return "world.waypoints";
    case 'z': return "staff.admin";
    default: return null;
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
        if (!gmAccess.managed)
        {
            blueSystemMessage("Staff access comes from your legacy account level.");
            return true;
        }
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
