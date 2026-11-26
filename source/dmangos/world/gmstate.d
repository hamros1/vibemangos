/// What a game master's commands keep between one command and the next.
module dmangos.world.gmstate;

import std.typecons : Nullable;
import dmangos.world.gmadmin : SummonOffer;
import dmangos.world.motion : MotionType, WaypointNode;
import dmangos.world.worlddata : SpellListEntry;

/// The scratch state of the commands' tools, one per player (`Character.gmState`): none of it is saved.
struct GmState
{
    // `.wp`: the waypoint path being drafted (`dmangos.world.gmwaypoint`).
    uint waypointSpawn;           /// the spawn the draft is for; 0: none
    MotionType waypointMode;      /// looped or linear
    WaypointNode[] waypointDraft; /// its points, in order

    /// `.summon`: the offer made to a player on another node, until it is answered (`dmangos.world.gmadmin`).
    Nullable!SummonOffer summonOffer;

    uint formationLeader;         /// the spawn `.npc formation-add` links followers to

    // `.debug ai-test` (`dmangos.world.gmcontent`).
    ulong testingCreature;        /// the creature under test
    SpellListEntry[] testSpells;  /// its combat spells
    size_t nextTestSpell;         /// the next of them to try
}
