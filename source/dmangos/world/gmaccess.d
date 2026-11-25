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

/// Public shortcuts and their original permission paths.
string gmCanonicalCommand(string path) pure nothrow @safe @nogc
{
    switch (path)
    {
    case "learn": return "character learn";
    case "travel coords": return "worldport";
    case "travel player": return "appear";
    case "travel summon": return "summon";
    case "npc traineradd": return "addtrainerspell";
    default: return path;
    }
}

/// Named domains for staff tasks that used to share the same compatibility letter.
string gmCommandCapability(string path, char legacyGroup) pure @safe
{
    import std.algorithm.searching : startsWith;

    if (path == "access grant" || path == "access revoke")
        return "roles.manage";
    if (legacyGroup == 'z')
        return "staff.admin";
    if (path.startsWith("cheat "))
        return "testing.cheats";
    if (path.startsWith("guild "))
        return "guild.manage";
    if (path.startsWith("gmTicket "))
        return "support.tickets";
    if (path == "addtrainerspell")
        return "world.trainers";
    switch (path)
    {
    case "character learn", "character unlearn", "character learnskill", "character advanceskill",
        "character removeskill", "character resetspells", "character resettalents",
        "character resetskills", "character advanceallskills", "character increaseweaponskill":
        return "character.learn";
    default: return gmCapability(legacyGroup);
    }
}

mixin template AccessCommands()
{
    import std.conv : to;
    import std.format : format;

private:
    bool handleGmAccessInfoCommand()
    {
        if (!gmAccess.managed)
        {
            systemMessage("This account currently uses its legacy account level.");
            return true;
        }
        systemMessage("Roles: " ~ (gmAccess.roles.length ? gmAccess.roles.to!string : "none"));
        systemMessage("Capabilities: " ~ (gmAccess.grants.length ? gmAccess.grants.to!string : "none"));
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
            if (!context.canWrite() || target.isNull || !context.database.changeGmRole(target.get.id, role, grant))
                return false;
            gmLog(format!"role %s %s for %s"(role, grant ? "granted" : "revoked", target.get.username));
            systemMessage(format!"Role %s %s for %s."(role, grant ? "granted" : "revoked", target.get.username));
        }
        catch (DatabaseException)
        {
            systemMessage("The login database could not update the role.");
        }
        return true;
    }
}
