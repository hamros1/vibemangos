/**
 * What groups, channels and chat need to know about the players online, and
 * how they find each other.
 *
 * `Character` is an `OnlinePlayer`; `WorldContext` finds them.
 * Groups (`dmangos.world.group`) and channels (`dmangos.world.channel`) only
 * use these interfaces, so their unit tests run on small fakes.
 */
module dmangos.world.online;

import core.time : Duration;

import dmangos.auth.accounts : AccountLevel;
import dmangos.world.map : Inhabitant;

/// A player in the world, as other players' actions reach it.
interface OnlinePlayer : Inhabitant
{
    /// The account's security level (`WorldSession::GetSecurity`).
    @property AccountLevel security() const;

    /// ArcEmu's `WorldSession::CanUseCommand`: whether the account has the permission letter `group`.
    bool canUseCommand(char group) const;

    /// ArcEmu's `WorldSession::GetPermissionCount() > 0`: any GM permission at all.
    @property bool hasPermissions() const;

    /// Whether the player ignores `guid` (its ignore list).
    bool ignores(ulong guid) const;

    /// The dungeon instance the player is in (0: none, or its map is not instanced).
    @property uint instanceId() const;

    /// Whether the player is between the two halves of a far teleport (`Player::IsBeingTeleportedFar`).
    @property bool transferring() const;

    /**
     * The player's group, or its place in it, changed: its leader flag and
     * what the players around it see of its health may have to change.
     */
    void groupChanged();

    /// One tick of the world update (`Player::Update`, `WorldSession::Update`): `elapsed` since the last.
    void update(Duration elapsed);
}
