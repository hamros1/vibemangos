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
 *   $(LI The player's pet carries its flags.)
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
 * Whether a zone enforces PvP: whether it flags a player of `alliance` (or the
 * Horde) for PvP, on a realm of `gameType`.
 */
bool enforcedPvPZone(uint zoneTeam, uint zoneFlags, bool alliance, uint gameType, bool inBattleground = false)
    pure nothrow @nogc @safe
{
    switch (zoneTeam)
    {
    case AreaTeam.alliance:
        return !alliance && (isPvPRealm(gameType) || (zoneFlags & areaFlagCapital));
    case AreaTeam.horde:
        return alliance && (isPvPRealm(gameType) || (zoneFlags & areaFlagCapital));
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
    assert(!enforcedPvPZone(AreaTeam.horde, 0, true, normal), "enemy land, on a normal realm");
    assert(enforcedPvPZone(AreaTeam.horde, 0, true, pvp) && enforcedPvPZone(AreaTeam.none, 0, false, pvp),
        "enemy and contested land, on a PvP realm");
    assert(!enforcedPvPZone(AreaTeam.alliance, areaFlagCapital, true, pvp), "never at home");
    assert(!enforcedPvPZone(AreaTeam.none, 0, true, normal) && !enforcedPvPZone(6, 0, true, pvp));
}

/// The PvP flag on the player's side: `Character` mixes it in.
mixin template PvPHandlers()
{
    import dmangos.bytes : ByteReader;
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
        flushPlayerChanges();
    }

    /// Whether the player has the PvP flag.
    @property bool isPvP() const
    {
        return (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
    }

    /// Whether the player has the contested flag.
    @property bool isPvPContested() const
    {
        return hasPlayerFlag(PlayerFlagsPvP.contested);
    }

    /// Whether the player has the free-for-all flag.
    @property bool isFreeForAll() const
    {
        return hasPlayerFlag(PlayerFlagsPvP.freeForAll);
    }

    private bool hasPlayerFlag(uint flag) const
    {
        return (player.values.get!PLAYER_FLAGS & flag) != 0;
    }

    private void setPlayerFlag(uint flag, bool on)
    {
        const flags = player.values.get!PLAYER_FLAGS;
        player.values.set!PLAYER_FLAGS(on ? flags | flag : flags & ~flag);
        pvpFlagsToPet();
    }

    /// The flag on the player and on its pet; its group hears.
    void setPvP(bool on)
    {
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        player.values.set!UNIT_FIELD_FLAGS(on ? flags | UnitFlags.pvp : flags & ~UnitFlags.pvp);
        pvpFlagsToPet();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.status);
    }

    /// The pet carries its owner's PvP flag and the player flags the relations read.
    private void pvpFlagsToPet()
    {
        if (auto pet = ownPet)
        {
            const flags = pet.values.get!UNIT_FIELD_FLAGS;
            const on = isPvP;
            if (((flags & UnitFlags.pvp) != 0) != on)
            {
                pet.values.set!UNIT_FIELD_FLAGS(on ? flags | UnitFlags.pvp : flags & ~UnitFlags.pvp);
                map.flushObjectChanges(pet);
            }
            pet.controllerPlayerFlags = player.values.get!PLAYER_FLAGS;
        }
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
    package void updatePvPTimers(int diff)
    {
        const kept = pvpInCombat || pvpEnforcedArea || hasPlayerFlag(PlayerFlagsPvP.desired);
        if (!kept && pvpTimer > 0)
            pvpTimer = pvpTimer > diff ? pvpTimer - diff : 0;
        if (!pvpInCombat && pvpContestedTimer > 0)
            pvpContestedTimer = pvpContestedTimer > diff ? pvpContestedTimer - diff : 0;
        const before = player.values.get!UNIT_FIELD_FLAGS, beforeFlags = player.values.get!PLAYER_FLAGS;
        updatePvP(false);
        updatePvPContested(false);
        if (before != player.values.get!UNIT_FIELD_FLAGS || beforeFlags != player.values.get!PLAYER_FLAGS)
            flushPlayerChanges();
    }

    /// Out of combat, out of PvP combat.
    package void pvpLeftCombat()
    {
        pvpInCombat = false;
    }

    /**
     * The zone changed: an enforced area flags the player. Arriving there by teleport or
     * flight, it is an Honorless Target.
     */
    package void pvpZoneChanged(uint zone)
    {
        const entry = context.client.areas.lookup(zone);
        if (entry is null)
            return;
        const alliance = context.client.teamForRace(player.data.race) == Team.alliance;
        pvpEnforcedArea = enforcedPvPZone(entry.team, entry.flags, alliance, context.config.gameType);
        if (pvpEnforcedArea)
            updatePvP(true);
        if (pvpArrivedFar)
        {
            pvpArrivedFar = false;
            if (pvpEnforcedArea)
                if (const spell = context.data.spells.spell(spellHonorlessTarget))
                    castSpell(spell, SpellTargets(TargetFlags.self, 0), true, 0);
        }
    }

    /// The area changed: the free-for-all arenas.
    package void pvpAreaChanged(uint area)
    {
        const entry = context.client.areas.lookup(area);
        const arena = entry !is null && (entry.flags & areaFlagArena) && !player.gmTagOn;
        if (arena)
            setPlayerFlag(PlayerFlagsPvP.freeForAll, true);
        else if (isFreeForAll && !isFreeForAllRealm(context.config.gameType))
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
    package void pvpHitBy(typeof(this) attacker, bool attackerFlagged)
    {
        if (attacker is null || attacker is this || duelingWith(attacker.player.guid))
            return;
        if (attackerFlagged)
        {
            pvpInCombat = true;
            updatePvP(true);
        }
        if (isPvP)
        {
            // Fighting a flagged player ends Stealth, Divine Shield and the like (`PVP_ACTIVE_CANCELS`).
            import dmangos.world.auras : AuraInterrupt;

            attacker.interruptAuras(AuraInterrupt.pvpActiveCancels);
            attacker.pvpInCombat = true;
            attacker.updatePvP(true);
            attacker.updatePvPContested(true);
            attacker.flushPlayerChanges();
        }
    }

    /// Healing or buffing a flagged player in combat flags the helper.
    package void pvpAssisted(typeof(this) other)
    {
        if (other is null || other is this || !other.isPvP || !other.inCombat)
            return;
        if (other.pvpInCombat)
            pvpInCombat = true;
        updatePvP(true);
        if (other.isPvPContested)
            updatePvPContested(true);
    }
}

// The player's side is tested in `dmangos.world.character`, where the mixins are (their methods are
// out of other modules' reach).
