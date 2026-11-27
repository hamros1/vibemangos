/**
 * The PvP flag, the contested flag and the free-for-all flag: whether other players may attack this
 * one, and how zones, areas and fights set and clear the flags.
 *
 * $(UL
 *   $(LI `UNIT_FLAG_PVP` is the flag. It is set by the player's wish (`/pvp`, `PLAYER_FLAGS_PVP_DESIRED`),
 *        by an enforced area (an enemy capital; on a PvP realm enemy and contested territory), and by
 *        fighting flagged players. Each of these restarts a 5-minute timer; the flag goes when the
 *        timer runs out, and the timer only runs while none of them holds.)
 *   $(LI `PLAYER_FLAGS_CONTESTED_PVP` is set for 30 s by attacking a flagged player: a contested zone's
 *        guards (`FACTION_TEMPLATE_FLAG_ATTACK_PVP_ACTIVE_PLAYERS`) attack the player meanwhile.)
 *   $(LI `PLAYER_FLAGS_FFA_PVP` is set in the free-for-all arenas (areas with `AREA_FLAG_ARENA`, the
 *        Gurubashi Arena), and on a free-for-all realm everywhere but where the player rests.)
 *   $(LI The player's pets, charmed creatures and guardians carry its flags.)
 *   $(LI Arriving by teleport or by flight in an enforced area, the player is an Honorless Target
 *        (spell 2479) for a while: a kill of it gives no honor.)
 * )
 * Who may then attack whom is `dmangos.world.relations.canAttack`.
 */
module dmangos.world.pvp;

/// The PvP flag's and the contested flag's timers, in milliseconds.
enum int pvpFlagMs = 300_000, pvpContestedMs = 30_000;

/// The realm types (`game_type` in the configuration) that are PvP realms, and the free-for-all one.
bool isPvPRealm(uint gameType) pure nothrow @nogc @safe
{
    return gameType == 1 || gameType == 8 || gameType == 16; // PvP, RP-PvP, free-for-all
}

/// ditto
bool isFreeForAllRealm(uint gameType) pure nothrow @nogc @safe
{
    return gameType == 16;
}

/// Whose a zone is.
enum AreaTeam : uint
{
    none = 0,       /// contested
    alliance = 2,
    horde = 4,
}

/// `AREA_FLAG_ARENA`, `AREA_FLAG_CAPITAL`
enum uint areaFlagArena = 0x80, areaFlagCapital = 0x100;

/// Spell 2479, Honorless Target: no honor for killing whoever has it.
enum uint spellHonorlessTarget = 2479;

/**
 * Whether a zone enforces PvP: whether it flags a player of `alliance` (or the Horde) for PvP, on a realm of
 * `gameType`. On every realm the other side's capitals and the zones its races begin in (`enemyStartZone`:
 * playercreateinfo's); on PvP realms all the other side's land and contested land too (WoWWiki "PvP flag", 2006-10:
 * "You enter a territory that is one of the beginning zones for the opposite faction", "You enter an opposing
 * factions capital city ... This applies even on PvE Realms", "Only applies to PvP Realms: You enter a contested
 * territory"; docs/FORMULAS.md "The PvP flag").
 */
bool enforcedPvPZone(uint zoneTeam, uint zoneFlags, bool alliance, uint gameType, bool enemyStartZone = false,
    bool inBattleground = false) pure nothrow @nogc @safe
{
    switch (zoneTeam)
    {
    case AreaTeam.alliance, AreaTeam.horde:
        if ((zoneTeam == AreaTeam.alliance) == alliance)
            return false; // at home
        return enemyStartZone || (zoneFlags & areaFlagCapital) || isPvPRealm(gameType);
    case AreaTeam.none:
        return isPvPRealm(gameType) || inBattleground;
    default:
        return false; // a sanctuary
    }
}

unittest
{
    enum normal = 0, pvp = 1;
    assert(enforcedPvPZone(AreaTeam.horde, areaFlagCapital, true, normal), "an enemy capital, on any realm");
    assert(enforcedPvPZone(AreaTeam.horde, 0, true, normal, true), "an enemy beginning zone, on any realm");
    assert(!enforcedPvPZone(AreaTeam.horde, 0, true, normal), "the rest of the enemy's land: not on a normal realm");
    assert(enforcedPvPZone(AreaTeam.horde, 0, true, pvp) && enforcedPvPZone(AreaTeam.none, 0, false, pvp),
        "enemy and contested land, on a PvP realm");
    assert(!enforcedPvPZone(AreaTeam.alliance, areaFlagCapital, true, pvp), "never at home");
    assert(!enforcedPvPZone(AreaTeam.none, 0, true, normal) && !enforcedPvPZone(6, 0, true, pvp));
}

/// See the module documentation.
final class PvP
{
    import dmangos.world.character : Character;
    import dmangos.world.session : Handles, WorldState;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.clientdata : Team;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.group : GroupUpdate;
    import dmangos.world.updatefields;
    import dmangos.world.relations : PlayerFlagsPvP;
    import dmangos.world.pvp;

    private
    {
        bool pvpInCombat;          // fighting a flagged player (until out of combat)
        bool pvpEnforcedArea;      // in a zone that flags the player
        int pvpTimer;              // milliseconds until the PvP flag may go
        int pvpContestedTimer;     // milliseconds until the contested flag may go
        bool pvpArrivedFar;        // a teleport or flight ended: the next zone check may make it honorless
    }

    /// The client toggles PvP: a byte sets the wish to fight players, none toggles it.
    @Handles(Opcode.CMSG_TOGGLE_PVP, WorldState.inWorld)
    void handleTogglePvP(ref ByteReader reader)
    {
        const desired = reader.remaining >= 1 ? reader.read!ubyte != 0 : !hasPlayerFlag(PlayerFlagsPvP.desired);
        setPlayerFlag(PlayerFlagsPvP.desired, desired);
        if (desired)
            updatePvP(true);
        me.flushPlayerChanges();
    }

    /// Whether the player has the PvP flag.
    package @property bool isPvP() const
    {
        return (me.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
    }

    /// Whether the player has the contested flag.
    package @property bool isPvPContested() const
    {
        return hasPlayerFlag(PlayerFlagsPvP.contested);
    }

    /// Whether the player has the free-for-all flag.
    @property bool isFreeForAll() const
    {
        return hasPlayerFlag(PlayerFlagsPvP.freeForAll);
    }

    package bool hasPlayerFlag(uint flag) const
    {
        return (me.player.values.get!PLAYER_FLAGS & flag) != 0;
    }

    private void setPlayerFlag(uint flag, bool on)
    {
        const flags = me.player.values.get!PLAYER_FLAGS;
        me.player.values.set!PLAYER_FLAGS(on ? flags | flag : flags & ~flag);
        pvpFlagsToCreatures();
    }

    /// The flag on the player and its controlled creatures; its group hears.
    void setPvP(bool on)
    {
        const flags = me.player.values.get!UNIT_FIELD_FLAGS;
        me.player.values.set!UNIT_FIELD_FLAGS(on ? flags | UnitFlags.pvp : flags & ~UnitFlags.pvp);
        pvpFlagsToCreatures();
        if (auto group = me.context.groups.of(me.player.guid))
            group.updatePlayerOutOfRange(me, GroupUpdate.status);
    }

    /// Controlled creatures carry the player's PvP flag and the player flags the relations read.
    private void pvpFlagsToCreatures()
    {
        const on = isPvP;
        const playerFlags = me.player.values.get!PLAYER_FLAGS;
        void carry(imported!"dmangos.world.creature".Creature creature)
        {
            const flags = creature.values.get!UNIT_FIELD_FLAGS;
            if (((flags & UnitFlags.pvp) != 0) != on)
            {
                creature.values.set!UNIT_FIELD_FLAGS(on ? flags | UnitFlags.pvp : flags & ~UnitFlags.pvp);
                me.map.flushObjectChanges(creature);
            }
            creature.controllerPlayerFlags = playerFlags;
        }
        if (auto pet = me.ownPet)
            carry(pet);
        foreach (guardian; me.guardians.ownGuardians())
            carry(guardian);
    }

    /**
     * Flagged now, for 5 minutes more (`state`); or, the timer run out (or
     * `overriding`), unflagged.
     */
    void updatePvP(bool state, bool overriding = false)
    {
        if (!state || overriding)
        {
            if ((pvpTimer == 0 || overriding) && isPvP != state)
            {
                setPvP(state);
                pvpTimer = 0;
            }
        }
        else
        {
            if (!isPvP)
                setPvP(true);
            pvpTimer = pvpFlagMs;
        }
    }

    /// As `updatePvP`, for the contested flag and 30 s.
    void updatePvPContested(bool state, bool overriding = false)
    {
        if (!state || overriding)
        {
            if ((pvpContestedTimer == 0 || overriding) && isPvPContested != state)
            {
                setPlayerFlag(PlayerFlagsPvP.contested, state);
                pvpContestedTimer = 0;
            }
        }
        else
        {
            if (!isPvPContested)
                setPlayerFlag(PlayerFlagsPvP.contested, true);
            pvpContestedTimer = pvpContestedMs;
        }
    }

    /// The flags' timers, every tick: they run only while nothing keeps the flag.
    package void update(int diff)
    {
        const kept = pvpInCombat || pvpEnforcedArea || hasPlayerFlag(PlayerFlagsPvP.desired);
        if (!kept && pvpTimer > 0 && me.currentBattleground() is null)
            pvpTimer = pvpTimer > diff ? pvpTimer - diff : 0;
        if (!pvpInCombat && pvpContestedTimer > 0)
            pvpContestedTimer = pvpContestedTimer > diff ? pvpContestedTimer - diff : 0;
        const before = me.player.values.get!UNIT_FIELD_FLAGS, beforeFlags = me.player.values.get!PLAYER_FLAGS;
        updatePvP(false);
        updatePvPContested(false);
        if (before != me.player.values.get!UNIT_FIELD_FLAGS || beforeFlags != me.player.values.get!PLAYER_FLAGS)
            me.flushPlayerChanges();
    }

    /// Out of combat, out of PvP combat.
    package void pvpLeftCombat()
    {
        pvpInCombat = false;
    }

    /// Keep the PvP state of the live character as its simulation changes nodes.
    void writePvPHandoff(ref ByteWriter w)
    {
        w.put(isPvP);
        w.put(me.player.values.get!PLAYER_FLAGS & handoffPvPFlags);
        w.put(pvpTimer);
        w.put(pvpContestedTimer);
        w.put(pvpEnforcedArea);
        w.put(pvpArrivedFar);
    }

    void readPvPHandoff(ref ByteReader r)
    {
        const flags = me.player.values.get!UNIT_FIELD_FLAGS;
        me.player.values.set!UNIT_FIELD_FLAGS(r.read!bool ? flags | UnitFlags.pvp : flags & ~UnitFlags.pvp);
        me.player.values.set!PLAYER_FLAGS((me.player.values.get!PLAYER_FLAGS & ~handoffPvPFlags) | r.read!uint);
        pvpTimer = r.read!int;
        pvpContestedTimer = r.read!int;
        pvpEnforcedArea = r.read!bool;
        pvpArrivedFar = r.read!bool;
    }

    private enum handoffPvPFlags = PlayerFlagsPvP.desired | PlayerFlagsPvP.contested | PlayerFlagsPvP.freeForAll;

    /**
     * The zone changed: an enforced area flags the player. Arriving there by teleport or
     * flight, it is an Honorless Target.
     */
    package void pvpZoneChanged(uint zone)
    {
        const entry = me.context.client.areas.lookup(zone);
        if (entry is null)
            return;
        const alliance = me.context.client.teamForRace(me.player.data.race) == Team.alliance;
        bool enemyStart; // a zone the other side's races begin in (playercreateinfo)
        foreach (key, ref info; me.context.data.playerInfo)
            if (info.zone == zone && (me.context.client.teamForRace(cast(ubyte)(key >> 8)) == Team.alliance) != alliance)
            {
                enemyStart = true;
                break;
            }
        pvpEnforcedArea = enforcedPvPZone(entry.team, entry.flags, alliance, me.context.config.gameType, enemyStart);
        if (pvpEnforcedArea)
            updatePvP(true);
        if (pvpArrivedFar)
        {
            pvpArrivedFar = false;
            if (pvpEnforcedArea)
                if (const spell = me.context.data.spells.spell(spellHonorlessTarget))
                    me.castSpell(spell, SpellTargets(TargetFlags.self, 0), true, 0);
        }
    }

    /// The area changed: the free-for-all arenas.
    package void pvpAreaChanged(uint area)
    {
        const entry = me.context.client.areas.lookup(area);
        const arena = entry !is null && (entry.flags & areaFlagArena) && !me.player.gmTagOn;
        if (arena)
            setPlayerFlag(PlayerFlagsPvP.freeForAll, true);
        else if (isFreeForAll && !isFreeForAllRealm(me.context.config.gameType))
            setPlayerFlag(PlayerFlagsPvP.freeForAll, false);
    }

    /// A teleport or a flight ended: the next zone check decides whether the player is honorless.
    package void pvpArrived()
    {
        pvpArrivedFar = true;
    }

    /**
     * This player was hit by `attacker`: a hit between players (not duellists) flags the attacker if
     * the victim is flagged, and the victim if the attacker is; the attacker becomes contested.
     */
    package void pvpHitBy(Character attacker, bool attackerFlagged)
    {
        if (attacker is null || attacker is me || me.dueling.duelingWith(attacker.player.guid))
            return;
        flagFromPvPHit(attackerFlagged);
        if (isPvP)
            attacker.pvp.attackedFlaggedPlayer();
    }

    package void flagFromPvPHit(bool attackerFlagged)
    {
        if (attackerFlagged)
        {
            pvpInCombat = true;
            updatePvP(true);
        }
    }

    package void attackedFlaggedPlayer()
    {
        // Fighting a flagged player ends Stealth, Divine Shield and the like (`PVP_ACTIVE_CANCELS`).
        import dmangos.world.auras : AuraInterrupt;

        me.interruptAuras(AuraInterrupt.pvpActiveCancels);
        pvpInCombat = true;
        updatePvP(true);
        updatePvPContested(true);
        me.flushPlayerChanges();
    }

    /// Healing a flagged player flags the helper, in combat or not ("If you cast a healing spell or resurrect a
    /// flagged player, your flag will go up", WoWWiki "PvP flag", 2006-10; docs/FORMULAS.md "The PvP flag").
    package void pvpAssisted(Character other)
    {
        if (other !is null && other !is me)
            pvpAssisted(other.pvp.isPvP, other.pvp.isPvPContested, other.pvp.pvpInCombat);
    }

    package @property bool inPvPCombat() const
    {
        return pvpInCombat;
    }

    package void pvpAssisted(bool flagged, bool contested, bool fighting)
    {
        if (!flagged)
            return;
        if (fighting)
            pvpInCombat = true;
        updatePvP(true);
        if (contested)
            updatePvPContested(true);
    }
}

// The player's side is tested in `dmangos.world.character`, where the mixins are (their methods are
// out of other modules' reach).
