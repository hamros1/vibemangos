/**
 * What a creature's script (`dmangos.world.eventai`) asks of what it sees, beyond its own health and its
 * victim's: auras and their stacks, its victim's mana, friends held or missing a buff, an attacker in a range,
 * where it stands by its victim, whether its way reaches it, and the targets picked by who caused an event, who
 * tapped it, mana or distance. Mixed into `dmangos.world.creatureai.CreatureAI`, as CMaNGOS's
 * `CreatureEventAI::CheckEvent` and `GetTargetByType` do it.
 *
 * Also the script's movement: chasing at a distance and angle, standing, wandering or walking its waypoints,
 * and its waypoints paused.
 */
module dmangos.world.creatureevents;

/// See the module documentation.
mixin template CreatureEvents()
{
    import dmangos.world.eventai : EventTarget, Scripted;
    import dmangos.world.relations : isEnemy;
    import dmangos.world.updatefields;

    private
    {
        float attackDistance_ = 0; // `ACTION_T_RANGED_MOVEMENT`: how far from its victim it chases (0: in reach)
        float attackAngle_ = 0;    // and at which angle from its victim's facing (radians)
    }

    /// See `Scripted`.
    uint auraStacks(bool onVictim, uint spell)
    {
        if (!onVictim)
        {
            auto aura = me.auras.find(spell);
            return aura is null ? 0 : aura.stacks;
        }
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return other ? other.auraStacks(spell) : 0;
    }

    /// ditto
    uint victimManaPercent()
    {
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return other ? other.manaPercent : uint.max;
    }

    /// ditto: `FriendlyEligibleDispelInRangeCheck` with no dispel type: a friend that cannot move freely.
    ulong crowdControlledFriend(float radius)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.defines : UnitFlags;

        foreach (other; world_.creaturesNear(me.position, radius))
        {
            if (!other.alive || other.ai is null || !other.ai.inCombat || other.petOwner)
                continue;
            if (other !is me && isEnemy(relating, other.ai.relating, me.client))
                continue;
            if (other.values.get!UNIT_FIELD_FLAGS & (UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused)
                    || other.auras.has(AuraType.modRoot) || other.auras.has(AuraType.modStun)
                    || other.auras.has(AuraType.modDecreaseSpeed) || other.auras.has(AuraType.modConfuse)
                    || other.auras.has(AuraType.modFear))
                return other.guid;
        }
        return 0;
    }

    /// ditto: within the spell's range, as CMaNGOS's `DoFindFriendlyMissingBuff` looks.
    ulong friendMissingBuff(uint spell, bool inCombat)
    {
        import dmangos.world.spellcast : range;

        const info = lore is null ? null : lore.spellInfo(spell);
        if (info is null)
            return 0;
        const reach = range(*info, lore.clientData)[1];
        foreach (other; world_.creaturesNear(me.position, reach > 0 ? reach : 5))
        {
            if (!other.alive || other.ai is null || other.petOwner || (inCombat && !other.ai.inCombat))
                continue;
            if (other !is me && isEnemy(relating, other.ai.relating, me.client))
                continue;
            if (other.auras.find(spell) is null)
                return other.guid;
        }
        return 0;
    }

    /// ditto
    ulong attackerWithin(float min, float max)
    {
        import std.random : uniform;

        ulong[] found;
        foreach (guid, _; threat)
            if (auto other = world_.unit(guid))
            {
                const f = other.fighter;
                if (!f.alive)
                    continue;
                const d = distanceTo(guid) - me.fighter.combatReach - f.combatReach;
                if (d >= min && d <= max)
                    found ~= guid;
            }
        return found.length ? found[uniform(0, found.length, world_.random)] : 0;
    }

    /// ditto: `isInBackInMap` / `isInFrontInMap` of its victim, half the circle each.
    bool besideVictim(bool front)
    {
        import std.math : PI;
        import dmangos.world.combat : hasInArc;

        auto other = victim ? world_.unit(victim) : UnitRef.init;
        if (!other || distanceTo(victim) > 5)
            return false;
        const inFront = hasInArc(other.fighter.position, me.position, PI);
        return front == inFront;
    }

    /// ditto
    bool victimUnreachable()
    {
        return combatMovement_ && victim && !victimReachable;
    }

    /// ditto
    ulong moreTargetFor(int type, ulong invoker, uint spellId, uint castFlags)
    {
        import std.algorithm.sorting : sort;
        import std.random : uniform;
        import dmangos.world.combat : canReachWithMelee;
        import dmangos.world.eventai : castAuraNotPresent, castForceCast, castForceTargetSelf, castTriggered;
        import dmangos.world.spellcast : radius;
        import dmangos.world.unit : UnitKind;

        switch (type)
        {
        case EventTarget.actionInvokerOwner: // a pet's owner; anyone else itself
            if (auto c = invoker ? world_.creatureAt(invoker) : null)
                return c.petOwner ? c.petOwner : invoker;
            return invoker;
        case EventTarget.spawner:
            return me.summon.summoner;
        case EventTarget.playerInvoker, EventTarget.playerTapped:
            return me.lootRecipient;
        default:
            break;
        }
        // From its threat list, most hated first.
        enum uint castPlayerOnly = 0x200; // CAST_PLAYER_ONLY
        const playerOnly = (castFlags & castPlayerOnly) || type == EventTarget.hostileRandomPlayer
            || type == EventTarget.hostileRandomNotTopPlayer;
        // The spell's reach counts unless it is cast triggered or forced (CMaNGOS passes no spell then).
        const spell = lore is null || spellId == 0 || (castFlags & (castTriggered | castForceCast | castForceTargetSelf))
            ? null : lore.spellInfo(spellId);
        const effectRadius = type == EventTarget.nearestAoeTarget && lore !is null && lore.spellInfo(spellId) !is null
            ? radius(*lore.spellInfo(spellId), 0, lore.clientData) : 0;
        auto order = threat.keys;
        order.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
        bool suitable(ulong guid)
        {
            auto other = world_.unit(guid);
            if (!other || !other.fighter.alive || (playerOnly && other.kind != UnitKind.player))
                return false;
            if (type == EventTarget.hostileRandomMana && other.manaPercent == uint.max)
                return false;
            if (type == EventTarget.hostileFarthestAway && canReachWithMelee(me.fighter, other.fighter))
                return false;
            if (type == EventTarget.nearestAoeTarget)
                return distanceTo(guid) - other.fighter.combatReach < effectRadius;
            if (spell !is null)
            {
                if ((castFlags & castAuraNotPresent) && other.hasAuraOf(spell.id))
                    return false;
                if (!inRangeFor(spell, guid) || !world_.inLineOfSight(me.position, other.fighter.position))
                    return false;
            }
            return true;
        }
        ulong[] found;
        const skipTop = type == EventTarget.hostileSecondAggro || type == EventTarget.hostileRandomNotTop
            || type == EventTarget.hostileRandomNotTopPlayer;
        foreach (i, guid; order)
            if ((!skipTop || i > 0) && suitable(guid))
                found ~= guid;
        if (found.length == 0)
            return 0;
        switch (type)
        {
        case EventTarget.hostileSecondAggro: // the first suitable after the most hated
            return found[0];
        case EventTarget.hostileLastAggro:
            return found[$ - 1];
        case EventTarget.nearestAoeTarget, EventTarget.hostileFarthestAway:
        {
            ulong best = found[0];
            foreach (guid; found[1 .. $])
                if (type == EventTarget.nearestAoeTarget ? distanceTo(guid) < distanceTo(best)
                        : distanceTo(guid) > distanceTo(best))
                    best = guid;
            return best;
        }
        default: // at random
            return found[uniform(0, found.length, world_.random)];
        }
    }

    /// ditto: it chases again at that distance if it does now.
    void scriptRangedMovement(float distance, float angle)
    {
        import std.math : PI;

        attackDistance_ = distance > 0 ? distance : 0;
        attackAngle_ = angle / 180.0f * PI;
        chasedTo = Position.init; // set off afresh
    }

    /// ditto: at once out of a fight; in one, once it is home.
    void scriptChangeMovement(uint type, int param, bool asDefault)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : IdleMovement, MovementGenerator, WanderMovement, WaypointMovement;

        MovementGenerator next;
        switch (type)
        {
        case 0:
            next = new IdleMovement;
            break;
        case 1:
            next = new WanderMovement(Vector3(me.position.x, me.position.y, me.position.z), param > 0 ? param : 0,
                false);
            break;
        case 2:
        {
            const path = lore is null ? null : lore.creaturePath(me.spawn.entry, me.spawn.guid);
            if (path.length == 0)
                return;
            next = new WaypointMovement(path, false);
            break;
        }
        default:
            return;
        }
        if (inCombat_ || evadingHome)
        {
            outOfCombat = next;
            return;
        }
        me.generator = next;
        next.initialize(me, world_);
        world_.wake(me.guid);
    }

    /// ditto
    void scriptPauseWaypoints(bool pause)
    {
        import dmangos.world.motion : WaypointMovement;

        if (auto path = cast(WaypointMovement) (outOfCombat !is null ? outOfCombat : me.generator))
            path.paused = pause;
    }

    /// See `Scripted`.
    bool spawnedIn(uint condition, uint value)
    {
        switch (condition)
        {
        case 0:
            return true;
        case 1:
            return me.spawn.map == value;
        case 2:
        {
            const where = lore is null ? [0u, 0u] : lore.zoneAndAreaAt(me.spawn.map, me.position);
            return where[0] == value || where[1] == value;
        }
        default:
            return false;
        }
    }

    /// ditto: a pet's owner's.
    bool conditionMet(uint id, ulong who)
    {
        if (lore is null)
            return false;
        if (auto c = world_ is null ? null : world_.creatureAt(who))
            who = c.petOwner;
        return who && lore.conditionMet(id, who);
    }

    /// It summoned `summoned`: its script hears of it (`EVENT_T_SUMMONED_UNIT`).
    void summonedCreature(CombatWorld world, Creature summoned)
    {
        if (script is null)
            return;
        world_ = world;
        script.summoned(this, summoned.guid, summoned.template_.entry);
    }

    /// Effect `index` of its `spell` worth `value`, scaled to its level if the spell says so
    /// (`SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL`).
    private int levelScaled(const(imported!"dmangos.world.spells".SpellInfo)* spell, size_t index, int value)
    {
        import dmangos.world.creatureevents : levelScaledValue, scalesWithCreatureLevel;

        if (lore is null || !scalesWithCreatureLevel(*spell, index))
            return value;
        const unitClass = me.template_.unitClass;
        return levelScaledValue(value, lore.creatureBaseDamage(me.values.get!UNIT_FIELD_LEVEL, unitClass),
            lore.creatureBaseDamage(spell.spellLevel, unitClass));
    }

    /**
     * `who` came into its sight while it has no victim: its script's events for those in its sight
     * (`EVENT_T_OOC_LOS`), hostile to it or not, as far as they ask and in line of sight.
     */
    private void scriptSaw(UnitRef who, CombatWorld world)
    {
        if (script is null || !script.watchesLineOfSight || victim || !me.alive || who.combatGuid == me.guid)
            return;
        const at = who.fighter.position;
        const dx = at.x - me.position.x, dy = at.y - me.position.y, dz = at.z - me.position.z;
        import std.math : sqrt;

        const d = sqrt(dx * dx + dy * dy + dz * dz);
        if (d > 100 || !world.inLineOfSight(me.position, at))
            return;
        import dmangos.world.unit : UnitKind;

        const enemy = isEnemy(relating, who.relating, me.client);
        script.seen(this, who.combatGuid, enemy, who.kind == UnitKind.player, d);
    }
}

import dmangos.world.spells : SpellInfo;

/**
 * Whether an evading creature loses its aura of `spell` (CMaNGOS's `IsSpellRemovedOnEvade`): every aura does,
 * debuffs and damage over time from its enemies as well as its own buffs, but for charms and possessions,
 * those CMaNGOS marks to stay (`SPELL_ATTR_SS_IGNORE_EVADE`, `SPELL_ATTR_EX_AURA_STAYS_AFTER_COMBAT`) and the
 * passive auras creatures are made with (Thrash, poison procs, shields, visuals: `keptOnEvade`).
 */
bool removedOnEvade(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    import std.algorithm.searching : canFind;
    import dmangos.world.spellids : AuraType;

    enum uint ignoreEvade = 0x04;           // SPELL_ATTR_SS_IGNORE_EVADE
    enum uint staysAfterCombat = 0x02000000; // SPELL_ATTR_EX_AURA_STAYS_AFTER_COMBAT
    foreach (aura; spell.casting.applyAuraName)
        if (aura == AuraType.modCharm || aura == AuraType.modPossess)
            return false;
    if (spell.casting.attributesServerside & ignoreEvade || spell.attributesEx & staysAfterCombat)
        return false;
    return !keptOnEvade[].canFind(spell.id);
}

/// The passive auras CMaNGOS keeps on an evading creature (`IsSpellRemovedOnEvade`'s list, for 1.12).
immutable uint[] keptOnEvade = [588, 3235, 3284, 3417, 3418, 3509, 3512, 3582, 3616, 3637, 4148, 5111, 5301, 5680,
    6488, 6498, 6718, 6752, 6820, 6821, 6822, 6823, 6923, 6947, 6961, 7056, 7090, 7095, 7165, 7276, 7999, 8247, 8279,
    8393, 8599, 8601, 8876, 8909, 8990, 9205, 9460, 9464, 9617, 9769, 9941, 10022, 10072, 10074, 10095, 11838,
    11919, 11959, 11964, 11966, 11984, 12099, 12187, 12246, 12529, 12539, 12544, 12546, 12550, 12556, 12627, 12787,
    12898, 13260, 13299, 13616, 13767, 13787, 14111, 14133, 14178, 15088, 15097, 15506, 15876, 16140, 16345, 16563,
    16577, 16592, 17327, 17467, 18148, 18268, 18847, 18943, 18968, 19030, 18950, 19194, 19195, 19396, 19483, 19514,
    19626, 19640, 19817, 19818, 20514, 21061, 21857, 21862, 22128, 22578, 22650, 22735, 22781, 22788, 22856, 23255,
    24313, 25039, 25592, 26341, 27578, 27793, 27987, 28002, 28126, 28156, 28362, 28370, 29526, 30074];

unittest
{
    import dmangos.world.spellids : AuraType;

    SpellInfo corruption = {id: 172};
    corruption.casting.applyAuraName[0] = AuraType.periodicDamage;
    assert(removedOnEvade(corruption), "a player's damage over time goes");
    SpellInfo thrash = {id: 3417};
    assert(!removedOnEvade(thrash), "Thrash, a creature's passive, stays");
    SpellInfo charm = {id: 1};
    charm.casting.applyAuraName[1] = AuraType.modCharm;
    assert(!removedOnEvade(charm), "a charm stays");
    SpellInfo stays = {id: 2, attributesEx: 0x02000000};
    assert(!removedOnEvade(stays));
    SpellInfo marked = {id: 3};
    marked.casting.attributesServerside = 0x04;
    assert(!removedOnEvade(marked));
}

/// `SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL`: a creature's spell made for one level, cast at its own.
enum uint spellAttrScalesWithCreatureLevel = 0x00080000;

/**
 * Whether effect `index` of `spell` is scaled by a creature's level (CMaNGOS's `CalculateSpellEffectValue`):
 * a spell with `SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL` and a spell level, on its damage, heal, drain, burn,
 * leech, absorb and summon effects (not percentages).
 */
bool scalesWithCreatureLevel(const ref SpellInfo spell, size_t index) pure nothrow @nogc @safe
{
    import dmangos.world.spellids : AuraType, SpellEffect;

    if (!(spell.attributes & spellAttrScalesWithCreatureLevel) || spell.spellLevel == 0)
        return false;
    if (const aura = spell.casting.applyAuraName[index])
        switch (aura)
        {
        case AuraType.periodicDamage, AuraType.periodicLeech, AuraType.schoolAbsorb, AuraType.powerBurnMana,
                AuraType.periodicManaLeech:
            return true;
        default:
            return false;
        }
    switch (spell.effect[index])
    {
    case SpellEffect.schoolDamage, SpellEffect.powerDrain, SpellEffect.environmentalDamage, SpellEffect.healthLeech,
            SpellEffect.heal, SpellEffect.summon, SpellEffect.weaponDamageNoschool, SpellEffect.weaponDamage,
            SpellEffect.powerBurn, SpellEffect.normalizedWeaponDmg:
        return true;
    default:
        return false;
    }
}

/**
 * A scaled effect's value: times the creature's base damage at its level over that at the spell's level (both
 * of its class, `creature_template_classlevelstats`); unchanged without both.
 */
int levelScaledValue(int value, float casterBaseDamage, float spellBaseDamage) pure nothrow @nogc @safe
{
    if (casterBaseDamage <= 0 || spellBaseDamage <= 0)
        return value;
    return cast(int)(value * (casterBaseDamage / spellBaseDamage));
}

/// A scaled spell's mana cost for a caster of `level` (CMaNGOS's `CalculatePowerCost`).
int levelScaledCost(int cost, uint spellLevel, uint level) pure nothrow @nogc @safe
{
    if (spellLevel == 0 || level == 0)
        return cost;
    const divisor = 1.117f * spellLevel / level - 0.1327f;
    return divisor > 0 ? cast(int)(cost / divisor) : cost;
}

unittest
{
    import dmangos.world.spellids : AuraType, SpellEffect;

    // A creature's bolt made for level 2, cast by a caster whose base damage is five times that level's.
    SpellInfo bolt = {id: 20791, attributes: spellAttrScalesWithCreatureLevel, spellLevel: 2};
    bolt.effect[0] = SpellEffect.schoolDamage;
    bolt.effect[1] = SpellEffect.applyAura;
    bolt.casting.applyAuraName[1] = AuraType.modDecreaseSpeed;
    assert(scalesWithCreatureLevel(bolt, 0) && !scalesWithCreatureLevel(bolt, 1), "the damage, not the slow");
    assert(levelScaledValue(20, 30, 6) == 100, "five times the base damage, five times the bolt");
    assert(levelScaledValue(20, 30, 0) == 20, "no stats: as it is");
    bolt.attributes = 0;
    assert(!scalesWithCreatureLevel(bolt, 0));
    // A level 10 spell costs a level 60 caster more than a level 10 one.
    assert(levelScaledCost(100, 10, 60) > levelScaledCost(100, 10, 10));
}

// ---------------------------------------------------------------------------
// Tests in the world: evading, dungeons, healing, sight
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime, msecs;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    /// Walks a test player from where it is to `to`, two yards each half second (`tick` passes the time).
    void walkTo(ref TestClient client, Position to, scope void delegate(int ms) tick)
    {
        import std.math : sqrt;
        import dmangos.world.teleport : moveTo;

        const from = client.session.inWorld.character.position;
        const dx = to.x - from.x, dy = to.y - from.y, dz = to.z - from.z;
        const steps = cast(int)(sqrt(dx * dx + dy * dy) / 2) + 1;
        foreach (i; 1 .. steps + 1)
        {
            client.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(from.x + dx * i / steps, from.y + dy * i / steps,
                from.z + dz * i / steps, to.orientation)));
            tick(500);
        }
    }
}

/**
 * Evading, a creature loses the player's damage over time on it but keeps its own passive (Thrash); in the
 * open world it gives up a victim that got away once its pursuit time is out, and in a dungeon it does not.
 */
unittest
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.creature : CreatureSpawn, CreatureTemplate;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.teleport : moveTo;
    import dmangos.auth.accounts : AccountLevel;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // A guard in the Deadmines, as the open world's innkeeper.
    const guardAt = Position(-20, -383, 61);
    context.data.creatureSpawns ~= CreatureSpawn(90900, creatureInnkeeper, mapDeadmines, guardAt.x, guardAt.y, guardAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(guardAt.x, guardAt.y)] ~= context.data.creatureSpawns.length - 1;
    const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(5000u);
    keeper.values.set!UNIT_FIELD_HEALTH(5000u);
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        foreach (m; [map, context.instanceMap(anduin.session.inWorld.instanceId)])
            if (m !is null)
                m.update(ms.msecs);
    }

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    tick(50);
    assert(keeper.ai.inCombat);
    // A player's Corruption on it, and its own Thrash.
    static immutable corruption = () { SpellInfo s = {id: 172}; s.casting.applyAuraName[0] = AuraType.periodicDamage;
        s.effect[0] = imported!"dmangos.world.spellids".SpellEffect.applyAura; return s; }();
    static immutable thrash = () { SpellInfo s = {id: 3417}; return s; }();
    bool isNew;
    keeper.auras.apply(makeAura(&corruption, anduin.session.character.guid, 60, 18_000, false, [10, 0, 0]),
        keeper.values, isNew);
    keeper.auras.apply(makeAura(&thrash, keeper.guid, 60, -1, true, [0, 0, 0]), keeper.values, isNew);
    // It stands; the player walks 40 yards off: the pursuit time (none) is out, the victim got away.
    keeper.ai.scriptCombatMovement(false);
    anduin.write(Opcode.CMSG_ATTACKSTOP, null);
    walkTo(anduin, Position(at.x + 40, at.y, at.z, at.orientation), &tick);
    assert(anduin.session.inWorld.character.position.x > at.x + 39, "it walked away");
    foreach (_; 0 .. 4)
        tick(500);
    assert(!keeper.ai.inCombat, "the open world: it gave up");
    assert(keeper.auras.find(172) is null, "the player's damage over time went with the fight");
    assert(keeper.auras.find(3417) !is null, "its own passive stays");

    // In the Deadmines it does not give up so.
    anduin.say(".worldport 36 -19 -383 61");
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    anduin.read();
    auto copy = context.instanceMap(anduin.session.inWorld.instanceId);
    auto guard = cast(Creature) copy.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, 90900));
    assert(guard !is null && guard.ai.inDungeon && !keeper.ai.inDungeon);
    guard.values.set!UNIT_FIELD_MAXHEALTH(5000u);
    guard.values.set!UNIT_FIELD_HEALTH(5000u);
    guard.ai.attackedBy(anduin.session.inWorld.unit, copy);
    assert(guard.ai.inCombat);
    guard.ai.scriptCombatMovement(false);
    anduin.write(Opcode.CMSG_ATTACKSTOP, null);
    walkTo(anduin, Position(-19 + 40, -383, 61, 0), &tick);
    assert(anduin.session.inWorld.character.position.x > 20, "it walked away");
    foreach (_; 0 .. 6)
        tick(500);
    assert(guard.ai.inCombat && guard.ai.currentVictim == anduin.session.character.guid,
        "a dungeon's creature fights on, its pursuit time not looked at");
}

/**
 * Healing angers: a player who heals one a creature fights is on its threat list with half the heal; a
 * buff puts the helper in the fight with no threat.
 */
unittest
{
    import dmangos.world.auras : AuraType;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    auto anduin = loggedIn(context, db, 7, "Anduin", at);
    anduin.read();
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(at.x + 3, at.y, at.z, at.orientation));
    jaina.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_MAXHEALTH(5000u);
    keeper.values.set!UNIT_FIELD_HEALTH(5000u);
    keeper.ai.attackedBy(anduin.session.inWorld.unit, map);
    assert(keeper.ai.inCombat);
    const healer = jaina.session.character.guid, hurt = anduin.session.character.guid;
    assert(keeper.ai.threatOf(healer) == 0 && (healer in keeper.ai.threatList) is null);

    // The healer's spell (the player's side calls this from its heals, over time too: `assistThreat`).
    import dmangos.world.creatureai : assistThreat;

    const fighting = [keeper.guid];
    static immutable lesserHeal = () { SpellInfo s = {id: 2050}; s.casting.school = 1;
        s.effect[0] = imported!"dmangos.world.spellids".SpellEffect.heal; return s; }();
    assistThreat(map, fighting, map.unit(healer), 40, lesserHeal);
    assert((healer in keeper.ai.threatList) !is null, "the healer is in its fight");
    assert(keeper.ai.threatOf(healer) == 20, "half the heal");
    assert(jaina.session.inWorld.player.values.get!UNIT_FIELD_FLAGS & imported!"dmangos.world.defines".UnitFlags.inCombat);

    // A spell that angers no one (`SPELL_ATTR_EX_NO_THREAT`); a buff: in the fight, no threat.
    static immutable quiet = () { SpellInfo s = {id: 2051, attributesEx: 0x400}; s.casting.school = 1;
        s.effect[0] = imported!"dmangos.world.spellids".SpellEffect.heal; return s; }();
    assistThreat(map, fighting, map.unit(healer), 40, quiet);
    assert(keeper.ai.threatOf(healer) == 20, "no more threat");
    assistThreat(map, fighting, map.unit(healer), 0, lesserHeal);
    assert(keeper.ai.threatOf(healer) == 20);
    // Shared among those fighting the one healed.
    assert(keeper.ai.threatOf(hurt) >= 0 && (hurt in keeper.ai.threatList) !is null);
}

/// In its sight out of combat (`EVENT_T_OOC_LOS`): a creature that greets the players who come near.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.eventai;
    import dmangos.world.teleport : moveTo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f - 40, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    assert(keeper !is null);
    // Not hostile players within 10 yards: it waves (emote 3), once a minute.
    EventAiEvent greet = {id: 1, creature: creatureInnkeeper, type: EventType.oocLineOfSight, chance: 100,
        flags: eventRepeatable, params: [1, 10, 60_000, 60_000, 1, 0]};
    greet.actions[0] = EventAiAction(ActionType.emote, [3, 0, 0]);
    keeper.ai.setScript([greet], new EventAiData);
    assert(keeper.ai.mayNotice, "it watches for those who come into sight");
    bool waved;
    walkTo(anduin, Position(-8950, -131, 83.53f, 1.97f), (int ms) {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
        waved |= opcodesOf(anduin.read()).canFind(Opcode.SMSG_EMOTE);
    });
    assert(waved, "it waved");
}
