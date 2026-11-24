/**
 * What the world does to a player by itself: breath under water, fatigue in deep water, lava, and
 * falling; mixed into `dmangos.world.character.Character`.
 *
 * Every tenth of a second a moving player's place is looked up in the map's liquids
 * (`dmangos.world.terrain`), which gives its `EnvironmentFlags`: in water, under it, in magma or slime,
 * in deep water (the open sea), in liquid deep enough to swim. Those drive the mirror timers, the bars
 * the client shows at the top of the screen (CMaNGOS `Player::UpdateMirrorTimers`):
 *
 * $(UL
 *   $(LI breath: a minute under water (`MirrorTimer.Breath.Max`, longer with Underwater Breathing's
 *     `MOD_WATER_BREATHING`, none with Water Breathing or Unending Breath's `WATER_BREATHING`); then
 *     drowning, a fifth of the maximum health plus up to the level less one, every two seconds;)
 *   $(LI fatigue: a minute in deep water (not on a ship, not flying), then exhaustion like drowning; a
 *     ghost that runs out goes back to its graveyard;)
 *   $(LI lava: a hidden timer of one second, then 605 to 610 fire damage every two seconds (resisted
 *     and absorbed as fire). Slime does nothing, as in CMaNGOS (its damage is commented out there for
 *     Undercity); a liquid with a spell of its own (Naxxramas's slime, 28801) casts that on whoever is
 *     in it, and takes it away again.)
 * )
 *
 * A timer runs down (scale -1) while its cause lasts and fills up again ten times as fast (scale 10)
 * once it ends, until full, when it stops. The client is sent `SMSG_START_MIRROR_TIMER` whenever a
 * timer starts, changes speed or direction, and `SMSG_STOP_MIRROR_TIMER` when it stops, exactly when
 * CMaNGOS sends them (`MirrorTimer` is its timer, statuses and all).
 *
 * Falling: the client's `MSG_MOVE_FALL_LAND` ends a fall begun at the highest point since the last
 * landing (CMaNGOS `Player::HandleFall` and `UpdateFallInformationIfNeed`); 14.57 yards and more
 * hurt, less what Safe Fall takes off (`SAFE_FALL`), and not at all with Slow Fall or Levitate
 * (`FEATHER_FALL`, `HOVER`), on a ship, or immune to physical damage. A fall that kills wears gear by
 * a tenth. Falling under the world (below -500) kills and sends the ghost to its graveyard.
 *
 * All of it is told with `SMSG_ENVIRONMENTALDAMAGELOG` to the player and those who see it. Game
 * masters with their tag on, and `.cheat god`, take none of it.
 */
module dmangos.world.environment;

import dmangos.bytes : ByteWriter;
import dmangos.world.movement : MovementInfo;
import dmangos.world.opcodes : Opcode;
import dmangos.world.terrain : LiquidData, LiquidStatus;

/// Where a player is relative to liquids (CMaNGOS `EnvironmentFlags`).
enum EnvironmentFlags : uint
{
    none = 0x00,
    inWater = 0x01,    /// swimming or standing in water
    inMagma = 0x02,    /// in magma, or just above it
    inSlime = 0x04,    /// in slime, or just above it
    highSea = 0x08,    /// anywhere in a deep water area
    underwater = 0x10, /// swimming fully under any liquid
    highLiquid = 0x20, /// in any liquid deep enough to swim
    liquid = 0x40,     /// anywhere in an area with any liquid

    liquidHazard = inMagma | inSlime,
    inLiquid = inWater | liquidHazard,
    liquidFlags = underwater | inLiquid | highSea | liquid | highLiquid,
}

/// One `SetEnvironmentFlags` call: `flags` set (`apply`) or cleared.
struct EnvironmentChange
{
    uint flags;
    bool apply;
}

/// The changes a look at the liquids makes, in the order CMaNGOS makes them (the order matters: each has
/// its consequences at once).
struct EnvironmentChanges
{
    private EnvironmentChange[8] list;
    private size_t count;

    /// The changes.
    inout(EnvironmentChange)[] opSlice() inout return pure nothrow @nogc @safe
    {
        return list[0 .. count];
    }

    private void put(uint flags, bool apply) pure nothrow @nogc @safe
    {
        list[count++] = EnvironmentChange(flags, apply);
    }
}

/**
 * CMaNGOS `Player::UpdateTerainEnvironmentFlags`: the flag changes for a point whose liquid `status` and
 * `liquid` the terrain gave, for a unit `collisionHeight` tall. A flag is only looked at for the liquids
 * that decide it (in water only for water and the sea, say), so some last until the next liquid that does.
 */
EnvironmentChanges environmentChanges(LiquidStatus status, const LiquidData liquid, float collisionHeight)
    pure nothrow @nogc @safe
{
    import dmangos.mapfile : mapLiquidTypeDeepWater, mapLiquidTypeMagma, mapLiquidTypeOcean, mapLiquidTypeSlime,
        mapLiquidTypeWater;

    alias E = EnvironmentFlags;
    EnvironmentChanges changes;
    if (status == LiquidStatus.noWater)
    {
        changes.put(E.liquidFlags, false);
        return changes;
    }
    const type = liquid.typeFlags;
    const under = status == LiquidStatus.underWater;
    const inside = under || status == LiquidStatus.inWater;
    const onSurface = inside || status == LiquidStatus.waterWalk;
    changes.put(E.liquid, true);
    if (type & (mapLiquidTypeWater | mapLiquidTypeOcean | mapLiquidTypeMagma | mapLiquidTypeSlime))
        changes.put(E.underwater, under);
    if (type & (mapLiquidTypeWater | mapLiquidTypeOcean))
        changes.put(E.inWater, inside);
    if (type & mapLiquidTypeMagma)
        changes.put(E.inMagma, onSurface);
    if (type & mapLiquidTypeSlime)
        changes.put(E.inSlime, onSurface);
    changes.put(E.highSea, (type & mapLiquidTypeDeepWater) != 0);
    changes.put(E.highLiquid, inside && liquid.level > liquid.depthLevel + collisionHeight * 0.75f);
    return changes;
}

/// `flags` after `change` (CMaNGOS `SetEnvironmentFlags`); `changed` false when it was a no-op (then nothing follows from it).
uint applyEnvironmentChange(uint flags, EnvironmentChange change, out bool changed) pure nothrow @nogc @safe
{
    if (((flags & change.flags) != 0) == change.apply)
        return flags;
    changed = true;
    return change.apply ? flags | change.flags : flags & ~change.flags;
}

unittest
{
    import dmangos.mapfile : mapLiquidTypeDeepWater, mapLiquidTypeMagma, mapLiquidTypeWater;

    alias E = EnvironmentFlags;
    uint flagsAfter(uint flags, LiquidStatus status, LiquidData liquid)
    {
        foreach (change; environmentChanges(status, liquid, 2))
        {
            bool changed;
            flags = applyEnvironmentChange(flags, change, changed);
        }
        return flags;
    }

    // Under a lake 10 deep: in water, under it, deep enough to swim; not the open sea.
    const lake = LiquidData(mapLiquidTypeWater, 1, 100, 90);
    assert(flagsAfter(0, LiquidStatus.underWater, lake) == (E.liquid | E.underwater | E.inWater | E.highLiquid));
    // At the surface, then on the bank above it: still "in an area with liquid".
    assert(flagsAfter(0, LiquidStatus.inWater, lake) == (E.liquid | E.inWater | E.highLiquid));
    assert(flagsAfter(E.liquid | E.inWater, LiquidStatus.aboveWater, lake) == E.liquid);
    // Wading in a stream half a yard deep: in water, not swimming.
    assert(flagsAfter(0, LiquidStatus.inWater, LiquidData(mapLiquidTypeWater, 1, 100, 99.5f)) == (E.liquid | E.inWater));
    // The open sea: deep water whatever the height.
    const sea = LiquidData(mapLiquidTypeWater | mapLiquidTypeDeepWater, 2, 0, -300);
    assert(flagsAfter(0, LiquidStatus.aboveWater, sea) == (E.liquid | E.highSea));
    // Lava counts just above its surface too; leaving every liquid clears all.
    const lava = LiquidData(mapLiquidTypeMagma, 3, 50, 40);
    assert(flagsAfter(0, LiquidStatus.waterWalk, lava) == (E.liquid | E.inMagma));
    assert(flagsAfter(E.liquid | E.inMagma, LiquidStatus.noWater, lava) == 0);

    bool changed;
    assert(applyEnvironmentChange(E.liquid, EnvironmentChange(E.liquid, true), changed) == E.liquid && !changed);
    assert(applyEnvironmentChange(E.liquid, EnvironmentChange(E.liquidFlags, false), changed) == 0 && changed);
}

/// The mirror timers; the first three are the client's bars, the last the server's own (CMaNGOS `MirrorTimer::Type`).
enum MirrorTimerType : uint
{
    fatigue = 0,
    breath = 1,
    feignDeath = 2,
    environmental = 3, /// lava: not shown
}

/// How many timers the client has bars for.
enum uint clientMirrorTimers = 3;

/// What the client needs to hear of a timer (CMaNGOS `MirrorTimer::Status`).
enum MirrorTimerStatus
{
    unchanged,
    fullUpdate,   /// `SMSG_START_MIRROR_TIMER`
    statusUpdate, /// `SMSG_STOP_MIRROR_TIMER` if it stopped, else `SMSG_START_MIRROR_TIMER` again
}

/**
 * One mirror timer, CMaNGOS's `MirrorTimer`: a tracker counting from 0 up to its duration while it runs
 * out (`scale` negative), down again `scale` times as fast while it fills (positive), and a two-second
 * pulse once it has run out. Times in milliseconds.
 */
struct MirrorTimer
{
    enum uint pulseInterval = 2000;

    MirrorTimerType type;
    int scale = -1;
    uint spellId;
    bool active;
    bool frozen;
    MirrorTimerStatus status;
    uint interval;      /// the tracker's: the duration
    uint current;       /// the tracker's: how much has run out
    uint pulse;         /// time since the last pulse, once run out

    /// Filling up again.
    bool regenerating() const pure nothrow @nogc @safe
    {
        return scale > 0;
    }

    /// Stopped where it is (only while running out).
    bool isFrozen() const pure nothrow @nogc @safe
    {
        return frozen && !regenerating;
    }

    /// What is left.
    uint remaining() const pure nothrow @nogc @safe
    {
        return interval - current;
    }

    /// What the client needs to hear, once: read, it is forgotten.
    MirrorTimerStatus fetchStatus() pure nothrow @nogc @safe
    {
        const was = status;
        status = MirrorTimerStatus.unchanged;
        return was;
    }

    ///
    void stop() pure nothrow @nogc @safe
    {
        if (!active)
            return;
        active = false;
        pulse = 0;
        current = 0;
        status = MirrorTimerStatus.statusUpdate;
    }

    /// Starts it full, `duration` long, if it is set to run out; otherwise stops it.
    void start(uint duration, uint spell = 0) pure nothrow @nogc @safe
    {
        if (scale >= 0)
            return stop();
        active = true;
        pulse = 0;
        current = 0;
        interval = duration;
        spellId = spell;
        status = MirrorTimerStatus.fullUpdate;
    }

    /// A new duration (0 stops it).
    void setDuration(uint duration) pure nothrow @nogc @safe
    {
        if (!duration)
            return stop();
        if (active && duration != interval)
            status = MirrorTimerStatus.fullUpdate;
        interval = duration;
    }

    ///
    void setFrozen(bool state) pure nothrow @nogc @safe
    {
        if (active && state != isFrozen)
            status = MirrorTimerStatus.statusUpdate;
        frozen = state;
    }

    /// Runs out (negative) or fills (positive); 0 freezes it.
    void setScale(int to) pure nothrow @nogc @safe
    {
        if (!to)
            return setFrozen(true);
        if (active && to != scale)
            status = MirrorTimerStatus.fullUpdate;
        scale = to;
    }

    /**
     * `diff` milliseconds pass. False when it has run out: at once when it does, then every two seconds
     * (the damage). Filling up, it stops once full.
     */
    bool update(uint diff) pure nothrow @nogc @safe
    {
        import std.math : abs;

        if (!active || isFrozen)
            return true;
        diff *= abs(scale);
        if (scale < 0)
        {
            const was = current;
            current += diff;
            if (current < interval)
                return true;
            const overflow = current - interval;
            current = interval;
            if (was == interval) // run out before: the pulse
            {
                pulse += overflow;
                if (pulse < pulseInterval)
                    return true;
                pulse -= pulseInterval;
            }
            return false;
        }
        if (current > diff)
        {
            current -= diff;
            pulse = 0;
        }
        else
            stop();
        return true;
    }
}

unittest
{
    auto breath = MirrorTimer(MirrorTimerType.breath);
    breath.start(60_000);
    assert(breath.active && breath.fetchStatus == MirrorTimerStatus.fullUpdate);
    assert(breath.fetchStatus == MirrorTimerStatus.unchanged, "told once");

    // A minute under water: nothing, then the first drowning at once, then one every two seconds.
    foreach (_; 0 .. 599)
        assert(breath.update(100));
    assert(breath.remaining == 100);
    assert(!breath.update(100), "out of breath");
    assert(breath.update(1000) && !breath.update(1000), "two seconds on");
    assert(breath.update(1500) && !breath.update(500));

    // Surfacing fills it ten times as fast, and it stops once full.
    breath.setScale(10);
    assert(breath.fetchStatus == MirrorTimerStatus.fullUpdate);
    assert(breath.update(3000) && breath.remaining == 30_000 && breath.active);
    assert(breath.update(3000) && !breath.active && breath.fetchStatus == MirrorTimerStatus.statusUpdate);

    // Set to fill, it does not start; frozen, it waits.
    auto fatigue = MirrorTimer(MirrorTimerType.fatigue, 10);
    fatigue.start(60_000);
    assert(!fatigue.active);
    fatigue.setScale(-1);
    fatigue.start(60_000);
    fatigue.setFrozen(true);
    assert(fatigue.fetchStatus == MirrorTimerStatus.statusUpdate);
    assert(fatigue.update(100_000) && fatigue.remaining == 60_000);
}

/// The kinds of environmental damage (CMaNGOS `EnvironmentalDamageType`).
enum EnvironmentalDamage : ubyte
{
    exhausted = 0,
    drowning = 1,
    fall = 2,
    lava = 3,
    slime = 4,
    fire = 5,
    fallToVoid = 6, /// under the map: shown as a fall, without the durability a fall to death costs
}

/// Drowning and exhaustion (CMaNGOS `OnMirrorTimerExpirationPulse`): a fifth of the maximum health plus `roll`, 0 to level - 1.
uint suffocationDamage(uint maxHealth, uint roll) pure nothrow @nogc @safe
{
    return maxHealth / 5 + roll;
}

/// Below this many yards (beyond Safe Fall's) a fall does not hurt (CMaNGOS's threshold, looked at before Safe Fall).
enum float harmlessFall = 14.57f;

/**
 * The damage of a fall of `height` yards (CMaNGOS `Player::HandleFall`): 1.8% of the maximum health per
 * yard beyond Safe Fall's `safeFall` yards, less 24.26%, times the configured `rate`; at most all of it.
 */
uint fallDamage(float height, int safeFall, uint maxHealth, float rate) pure nothrow @nogc @safe
{
    if (!(height >= harmlessFall))
        return 0;
    const share = 0.018f * (height - safeFall) - 0.2426f;
    if (share <= 0)
        return 0;
    const damage = cast(uint)(share * maxHealth * rate);
    return damage > maxHealth ? maxHealth : damage;
}

unittest
{
    assert(fallDamage(14.56f, 0, 1000, 1) == 0 && fallDamage(14.57f, 0, 1000, 1) == 19, "the edge: from 14.57 yards");
    assert(fallDamage(30, 0, 1000, 1) == cast(uint)((0.018f * 30 - 0.2426f) * 1000));
    assert(fallDamage(30, 20, 1000, 1) == 0, "Safe Fall takes 20 yards off");
    assert(fallDamage(30, 0, 1000, 2) == cast(uint)((0.018f * 30 - 0.2426f) * 1000 * 2), "the rate");
    assert(fallDamage(200, 0, 1000, 1) == 1000, "never more than all of it");
    assert(fallDamage(float.nan, 0, 1000, 1) == 0);
    assert(suffocationDamage(1000, 0) == 200 && suffocationDamage(1003, 59) == 259);
}

/**
 * Where the current fall began (CMaNGOS `m_lastFallTime`, `m_lastFallZ`): the highest point since the
 * last landing, by the client's fall time, which starts again at each fall.
 */
struct FallStart
{
    uint time;
    float z = 0;

    /// After a movement packet (`landed`: `MSG_MOVE_FALL_LAND`): a new fall, a higher point, or a landing starts it again.
    void moved(const MovementInfo movement, bool landed) pure nothrow @nogc @safe
    {
        if (time >= movement.fallTime || z <= movement.position.z || landed)
        {
            time = movement.fallTime;
            z = movement.position.z;
        }
    }

    /// From `at` with no fall time: after a teleport, at login, a charge, the end of a slow fall.
    void reset(float at) pure nothrow @nogc @safe
    {
        time = 0;
        z = at;
    }
}

unittest
{
    import dmangos.world.movement : Position;

    MovementInfo at(float z, uint fallTime)
    {
        MovementInfo m;
        m.position = Position(0, 0, z, 0);
        m.fallTime = fallTime;
        return m;
    }

    FallStart fall;
    fall.reset(100);
    fall.moved(at(102, 0), false);   // a jump's top
    assert(fall.z == 102);
    fall.moved(at(90, 300), false);  // falling: the start stays
    fall.moved(at(60, 900), false);
    assert(fall.z == 102 && fall.time == 0);
    fall.moved(at(50, 1000), true);  // landed: the next fall starts here
    assert(fall.z == 50 && fall.time == 1000);
    fall.moved(at(50, 0), false);    // a new fall time: starts again
    assert(fall.time == 0);
}

/// `SMSG_START_MIRROR_TIMER`
ubyte[] startMirrorTimer(const MirrorTimer timer)
{
    ByteWriter w;
    w.put(cast(uint) timer.type);
    w.put(timer.remaining);
    w.put(timer.interval);
    w.put(timer.scale);
    w.put(cast(ubyte) timer.isFrozen);
    w.put(timer.spellId);
    return w.data.dup;
}

/// `SMSG_ENVIRONMENTALDAMAGELOG`: who, the kind (a fall under the map shows as a fall), and the damage.
ubyte[] environmentalDamageLog(ulong guid, EnvironmentalDamage type, uint damage, uint absorbed, int resisted)
{
    ByteWriter w;
    w.put(guid);
    w.put(cast(ubyte)(type == EnvironmentalDamage.fallToVoid ? EnvironmentalDamage.fall : type));
    w.put(damage);
    w.put(absorbed);
    w.put(resisted);
    return w.data.dup;
}

unittest
{
    auto timer = MirrorTimer(MirrorTimerType.breath);
    timer.start(90_000);
    timer.update(1000);
    assert(startMirrorTimer(timer) == [1, 0, 0, 0, 0xA8, 0x5B, 1, 0, 0x90, 0x5F, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0]);
    assert(environmentalDamageLog(7, EnvironmentalDamage.fallToVoid, 100, 0, 0)[8] == EnvironmentalDamage.fall);
    assert(environmentalDamageLog(7, EnvironmentalDamage.lava, 100, 5, -3).length == 8 + 1 + 4 + 4 + 4);
}

/// See the module documentation.
mixin template EnvironmentHandlers()
{
    import core.time : Duration, MonoTime, seconds;
    import std.random : uniform;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.environment;
    import dmangos.world.movement : MovementFlags, MovementInfo;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : DeathState, PlayerFlags;
    import dmangos.world.spellids : AuraType;
    import dmangos.world.terrain : LiquidData, LiquidStatus;
    import dmangos.world.updatefields;

    private
    {
        uint environment;           // `EnvironmentFlags`
        MirrorTimer[4] mirrorTimers = [MirrorTimer(MirrorTimerType.fatigue), MirrorTimer(MirrorTimerType.breath),
            MirrorTimer(MirrorTimerType.feignDeath), MirrorTimer(MirrorTimerType.environmental)];
        float breathingMultiplier = 1; // 0: breathes under water
        uint lastLiquid;            // the `LiquidType.dbc` entry the player was last in, if it has a spell
        FallStart fallStart;
        MonoTime nextEnvironmentCheckpoint;
        bool fallingAtCheckpoint;
        MonoTime nextFallCheckpoint;
    }

    private static struct EnvironmentHandoff
    {
        uint flags, liquid;
        MirrorTimer[4] timers;
        FallStart fall;
    }

    package void writeEnvironmentHandoff(ref ByteWriter writer)
    {
        import dmangos.serialization : serialize;

        serialize(writer, EnvironmentHandoff(environment, lastLiquid, mirrorTimers, fallStart));
    }

    package void readEnvironmentHandoff(ref ByteReader reader)
    {
        import dmangos.serialization : deserialize;

        const state = deserialize!EnvironmentHandoff(reader);
        applyEnvironmentHandoff(state);
        fallingAtCheckpoint = player.movement.has(MovementFlags.jumping)
            || player.movement.has(MovementFlags.fallingFar);
    }

    private void applyEnvironmentHandoff(const ref EnvironmentHandoff state)
    {
        environment = state.flags;
        lastLiquid = state.liquid;
        mirrorTimers = state.timers;
        fallStart = state.fall;
        refreshWaterBreathing(true);
    }

    private bool activeEnvironmentTimers() const
    {
        import std.algorithm.searching : any;

        return mirrorTimers[].any!(timer => timer.active);
    }

    private const(ubyte)[] environmentRecoveryState()
    {
        if (!activeEnvironmentTimers() && !fallingAtCheckpoint)
            return null;
        ByteWriter state;
        state.put(map.id);
        state.put(map.instanceId);
        state.put(context.transportNow());
        writeEnvironmentHandoff(state);
        state.put(fallingAtCheckpoint);
        return state.data;
    }

    private void restoreEnvironmentRecovery(ref ByteReader state)
    {
        import dmangos.serialization : deserialize;
        import std.algorithm.comparison : max;

        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = cast(uint) max(0, cast(int)(context.transportNow() - state.read!uint));
        auto snapshot = deserialize!EnvironmentHandoff(state);
        foreach (ref timer; snapshot.timers)
        {
            if (!timer.active || timer.isFrozen)
                continue;
            const remaining = timer.remaining(), pulse = timer.pulse;
            timer.update(elapsed);
            if (!timer.regenerating && elapsed >= remaining)
                timer.pulse = (pulse + elapsed - remaining) % MirrorTimer.pulseInterval;
        }
        applyEnvironmentHandoff(snapshot);
        fallingAtCheckpoint = !state.empty && state.read!bool;
    }

    /// Game masters with their tag on (CMaNGOS `IsGameMaster`) and `.cheat god` take no environmental damage.
    private bool spared()
    {
        return player.gmTagOn || godModeCheat;
    }

    /// How tall the player is, for how deep it is in water: its own model's (not a mount's or a form's).
    private float playerCollisionHeight()
    {
        import std.math : isNaN;
        import dmangos.world.creature : defaultCollisionHeight;

        const native = context.client.collisionHeight(player.values.get!UNIT_FIELD_NATIVEDISPLAYID);
        const height = native * player.values.get!OBJECT_FIELD_SCALE_X;
        return height == 0 || isNaN(height) ? defaultCollisionHeight : height;
    }

    /// Where the player is relative to the map's liquids, every tenth of a second it moves (`afterMove`).
    package void updateEnvironment()
    {
        enum ubyte allLiquids = 0x0F; // MAP_ALL_LIQUIDS

        auto terrain = context.terrain(player.data.map);
        const p = player.position;
        const height = playerCollisionHeight();
        LiquidData liquid;
        const status = terrain.knows(p.x, p.y) ? terrain.liquidStatus(p.x, p.y, p.z, allLiquids, liquid, height)
            : LiquidStatus.noWater;
        updateLiquidSpell(status, liquid);
        foreach (change; environmentChanges(status, liquid, height))
            changeEnvironment(change);
    }

    /// A liquid with a spell (Naxxramas's slime): cast on whoever is in or under it, taken away out of it (CMaNGOS).
    private void updateLiquidSpell(LiquidStatus status, const LiquidData liquid)
    {
        const entry = status == LiquidStatus.noWater ? null : context.client.liquidTypes.lookup(liquid.entry);
        const spell = entry is null ? 0 : entry.spellId;
        const old = context.client.liquidTypes.lookup(lastLiquid);
        if (old !is null && old.spellId && old.spellId != spell)
            removeLiquidAura(old.spellId);
        lastLiquid = spell ? entry.id : 0;
        if (!spell)
            return;
        if (status == LiquidStatus.underWater || status == LiquidStatus.inWater)
        {
            if (player.auras.find(spell) is null)
                castTriggeredAt(spell, player.guid);
        }
        else
            removeLiquidAura(spell);
    }

    private void removeLiquidAura(uint spell)
    {
        if (auto aura = player.auras.find(spell))
            removeAura(aura);
    }

    /// One `SetEnvironmentFlags`: the flags, and what follows from each.
    private void changeEnvironment(EnvironmentChange change)
    {
        enum uint underwaterCancels = 0x80, abovewaterCancels = 0x100; // AURA_INTERRUPT_FLAG_*WATER_CANCELS
        alias E = EnvironmentFlags;
        bool changed;
        environment = applyEnvironmentChange(environment, change, changed);
        if (!changed)
            return;
        // Entering water deep enough to swim ends what cannot be done there (a mount); leaving it, the reverse.
        if (change.flags & E.highLiquid)
            interruptAuras(change.apply ? underwaterCancels : abovewaterCancels);
        if (change.flags & E.highSea)
            mirrorTimers[MirrorTimerType.fatigue].setScale(change.apply ? -1 : 10);
        if (change.flags & E.underwater)
            mirrorTimers[MirrorTimerType.breath].setScale(change.apply && breathingInterval ? -1 : 10);
        if (change.flags & E.liquidHazard)
            mirrorTimers[MirrorTimerType.environmental].setScale(environment & E.liquidHazard ? -1 : 10);
    }

    /// How long the player can hold its breath; 0 if it breathes under water.
    private uint breathingInterval()
    {
        return cast(uint)(context.config.mirrorTimerBreathMax * 1000 * breathingMultiplier);
    }

    /**
     * `WATER_BREATHING` (Water Breathing, Unending Breath) or `MOD_WATER_BREATHING` (Underwater
     * Breathing's longer breath) began or ended (CMaNGOS `SetWaterBreathingIntervalMultiplier`).
     */
    package void refreshWaterBreathing(bool forceTimerUpdate = false)
    {
        breathingMultiplier = player.auras.has(AuraType.waterBreathing) ? 0
            : player.auras.multiplier(AuraType.modWaterBreathing);
        auto breath = &mirrorTimers[MirrorTimerType.breath];
        if (const interval = breathingInterval)
        {
            breath.setDuration(interval);
            breath.setScale(environment & EnvironmentFlags.underwater ? -1 : 10);
        }
        else
            breath.setScale(10);
        sendMirrorTimers(forceTimerUpdate);
    }

    /// Whether `type` should start now (CMaNGOS `CheckMirrorTimerActivation`).
    private bool mirrorTimerStarts(MirrorTimerType type)
    {
        alias E = EnvironmentFlags;
        final switch (type)
        {
        case MirrorTimerType.fatigue:
            return (environment & E.highSea) && !flying && !player.movement.has(MovementFlags.onTransport);
        case MirrorTimerType.breath:
            return (environment & E.underwater) && breathingInterval;
        case MirrorTimerType.feignDeath:
            return false; // feigning death does not end in death here yet
        case MirrorTimerType.environmental:
            const liquid = context.client.liquidTypes.lookup(lastLiquid);
            return (environment & E.liquidHazard) && !(liquid !is null && liquid.spellId);
        }
    }

    /// Whether `type` should stop now (CMaNGOS `CheckMirrorTimerDeactivation`).
    private bool mirrorTimerStops(MirrorTimerType type)
    {
        const inLiquid = (environment & EnvironmentFlags.liquid) != 0;
        const alive = player.deathState == DeathState.alive;
        final switch (type)
        {
        case MirrorTimerType.fatigue:
            return !inLiquid || (!alive && player.deathState != DeathState.ghost);
        case MirrorTimerType.breath, MirrorTimerType.environmental:
            return !inLiquid || !alive;
        case MirrorTimerType.feignDeath:
            return true;
        }
    }

    /// A full timer's duration (CMaNGOS `GetMirrorTimerMaxDuration`).
    private uint mirrorTimerDuration(MirrorTimerType type)
    {
        final switch (type)
        {
        case MirrorTimerType.fatigue:
            return context.config.mirrorTimerFatigueMax * 1000;
        case MirrorTimerType.breath:
            return breathingInterval;
        case MirrorTimerType.feignDeath:
            return mirrorTimers[type].interval;
        case MirrorTimerType.environmental:
            return context.config.mirrorTimerEnvironmentalMax * 1000;
        }
    }

    /// The timers' time passes (each tick): they start, stop, and hurt; the client hears what changed.
    package void updateMirrorTimers(Duration elapsed)
    {
        const ms = cast(uint) elapsed.total!"msecs";
        bool changed, pulsed;
        foreach (ref timer; mirrorTimers)
        {
            if (player is null)
                return;
            const type = timer.type;
            if (!timer.active && !mirrorTimerStarts(type))
                continue;
            if (mirrorTimerStops(type))
                timer.stop();
            else if (!timer.active)
                timer.start(mirrorTimerDuration(type));
            else if (!timer.update(ms))
            {
                pulsed = true;
                mirrorTimerRanOut(type);
            }
            changed |= timer.status != MirrorTimerStatus.unchanged;
        }
        if (player is null)
            return;
        if (connection.gatewayHome.node && (changed || pulsed
            || (context.clock() >= nextEnvironmentCheckpoint && activeEnvironmentTimers())))
        {
            nextEnvironmentCheckpoint = context.clock() + 1.seconds;
            checkpointSummons(changed || pulsed, 0, true);
        }
        sendMirrorTimers();
    }

    /// A timer ran out (and every two seconds after): drowning, exhaustion, lava.
    private void mirrorTimerRanOut(MirrorTimerType type)
    {
        const maxHealth = player.values.get!UNIT_FIELD_MAXHEALTH;
        const level = player.data.level;
        final switch (type)
        {
        case MirrorTimerType.fatigue:
            if (player.deathState == DeathState.alive)
                environmentalDamage(EnvironmentalDamage.exhausted,
                    suffocationDamage(maxHealth, uniform(0, level, map.random)));
            else if (player.deathState == DeathState.ghost)
                repopAtGraveyard();
            break;
        case MirrorTimerType.breath:
            environmentalDamage(EnvironmentalDamage.drowning, suffocationDamage(maxHealth, uniform(0, level, map.random)));
            break;
        case MirrorTimerType.environmental:
            if (environment & EnvironmentFlags.inMagma)
                environmentalDamage(EnvironmentalDamage.lava, uniform!"[]"(context.config.environmentalDamageMin,
                    context.config.environmentalDamageMax, map.random));
            break;
        case MirrorTimerType.feignDeath:
            break;
        }
    }

    /// `SMSG_START_MIRROR_TIMER` / `SMSG_STOP_MIRROR_TIMER` for the client's timers that changed; with `forced`, every running one.
    package void sendMirrorTimers(bool forced = false)
    {
        foreach (ref timer; mirrorTimers[0 .. clientMirrorTimers])
        {
            auto status = timer.fetchStatus();
            if (forced && timer.active)
                status = MirrorTimerStatus.fullUpdate;
            final switch (status)
            {
            case MirrorTimerStatus.unchanged:
                break;
            case MirrorTimerStatus.fullUpdate:
                deliver(Opcode.SMSG_START_MIRROR_TIMER, startMirrorTimer(timer));
                break;
            case MirrorTimerStatus.statusUpdate:
                // A pause is sent as a whole start too: the client's own pause handler is broken (CMaNGOS).
                if (timer.active)
                    deliver(Opcode.SMSG_START_MIRROR_TIMER, startMirrorTimer(timer));
                else
                {
                    ByteWriter w;
                    w.put(cast(uint) timer.type);
                    deliver(Opcode.SMSG_STOP_MIRROR_TIMER, w.data);
                }
                break;
            }
        }
    }

    /// Whether every school in `schoolMask` (1 << school) is one the player is immune to (Divine Shield, Ice Block).
    private bool immuneToSchools(uint schoolMask)
    {
        int immune;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i))
                    && (aura.type(i) == AuraType.schoolImmunity || aura.type(i) == AuraType.damageImmunity))
                    immune |= aura.misc(i);
        return (immune & schoolMask) == schoolMask;
    }

    /**
     * Damage the world deals the player (CMaNGOS `Player::EnvironmentalDamage`): lava resisted and absorbed
     * as fire, slime as nature; told to it and those who see it; it stands up; a fall that kills wears its
     * gear by a tenth. Returns the damage dealt.
     */
    package uint environmentalDamage(EnvironmentalDamage type, uint damage)
    {
        import dmangos.world.combat : effectiveResistPercent, rollPartialResist;
        import dmangos.world.group : GroupUpdate;

        if (player is null || player.deathState != DeathState.alive || spared)
            return 0;
        enum uint fire = 2, nature = 3;
        uint absorbed;
        int resisted;
        if (type == EnvironmentalDamage.lava || type == EnvironmentalDamage.slime)
        {
            const school = type == EnvironmentalDamage.lava ? fire : nature;
            if (type == EnvironmentalDamage.lava && immuneToSchools(1 << fire))
                return 0;
            const resistance = cast(int) player.values.get!UNIT_FIELD_RESISTANCES(school);
            const level = player.data.level;
            const share = rollPartialResist(effectiveResistPercent(resistance, level, level, false),
                uniform!"[]"(1, 10_000, map.random));
            resisted = cast(int)(damage * share);
            damage = resisted >= cast(int) damage ? 0 : cast(uint)(damage - resisted);
            absorbed = absorbIncoming(school, damage);
        }
        map.sendToWatchers(this, Opcode.SMSG_ENVIRONMENTALDAMAGELOG,
            environmentalDamageLog(player.guid, type, damage, absorbed, resisted), true);
        if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0) // any damage but a tick stands one up
        {
            player.values.setByte!UNIT_FIELD_BYTES_1(0, 0);
            deliver(Opcode.SMSG_STANDSTATE_UPDATE, [ubyte(0)]);
        }
        if (!damage)
            return 0;
        const health = player.values.get!UNIT_FIELD_HEALTH;
        const died = damage >= health;
        player.values.set!UNIT_FIELD_HEALTH(died ? 0 : health - damage);
        flushPlayerChanges();
        if (auto group = context.groups.of(player.guid))
            group.updatePlayerOutOfRange(this, GroupUpdate.currentHealth);
        if (died)
        {
            if (auto copy = currentBattleground())
                copy.playerKilled(victim: player.guid, killer: 0);
            // Dying costs a tenth of what it wears but killed by a player or by itself (WoWWiki "Death", 2006-07: the
            // exceptions PvP and "self-inflicted death"; a ghost dying of fatigue loses it too): drowning, fatigue and
            // lava cost it as a fall does (docs/FORMULAS.md "Durability"). Not a fall through the world.
            playerDied(type != EnvironmentalDamage.fallToVoid);
        }
        return damage;
    }

    /// From `z` with no fall time: after a teleport, at login.
    package void startFallAt(float z)
    {
        fallStart.reset(z);
        if (fallingAtCheckpoint)
        {
            fallingAtCheckpoint = false;
            checkpointSummons(true);
        }
    }

    /**
     * The client landed (`MSG_MOVE_FALL_LAND`, before its movement is taken): the fall's damage
     * (CMaNGOS `Player::HandleFall`). The flags looked at are those of the move before.
     */
    package void landed(const MovementInfo movement)
    {
        if (flying || player.deathState != DeathState.alive || spared
            || player.movement.has(MovementFlags.onTransport) || player.auras.has(AuraType.hover)
            || player.auras.has(AuraType.featherFall) || immuneToSchools(1))
            return;
        const height = fallStart.z - movement.position.z;
        const damage = fallDamage(height, player.auras.total(AuraType.safeFall), player.values.get!UNIT_FIELD_MAXHEALTH,
            context.config.rateDamageFall);
        if (damage)
            environmentalDamage(EnvironmentalDamage.fall, damage);
    }

    /// After a movement packet: the fall's start (not after a knockback's acknowledgement).
    package void trackFall(const MovementInfo movement, Opcode opcode)
    {
        if (opcode == Opcode.CMSG_MOVE_KNOCK_BACK_ACK)
            return;
        const landed = opcode == Opcode.MSG_MOVE_FALL_LAND;
        fallStart.moved(movement, landed);
        if (!connection.gatewayHome.node)
            return;
        const falling = !landed && (movement.has(MovementFlags.jumping) || movement.has(MovementFlags.fallingFar));
        const changed = fallingAtCheckpoint != falling;
        fallingAtCheckpoint = falling;
        const now = context.clock();
        if (changed || (falling && now >= nextFallCheckpoint))
        {
            nextFallCheckpoint = now + 1.seconds;
            checkpointSummons(true);
        }
    }

    /**
     * Fell under the world (CMaNGOS `HandleMoverRelocation`, below -500): killed (as a fall, without the
     * durability), released, and at the graveyard.
     */
    package void fellUnderMap()
    {
        if (player.deathState == DeathState.alive)
            environmentalDamage(EnvironmentalDamage.fallToVoid, player.values.get!UNIT_FIELD_MAXHEALTH);
        if (player.deathState == DeathState.corpse)
            buildPlayerRepop();
        repopAtGraveyard(); // a game master spared too, as in CMaNGOS
    }
}

/**
 * A tile of open sea, a lake, lava and dry land: breath under the lake (and Water Breathing), fatigue at
 * sea, lava, falls (and Slow Fall), a fall to death, and falling under the world.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import dmangos.extractor.maps : buildTestAdt, convertAdt, TestTerrain;
    import dmangos.world.auras : makeAura;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.movement : MovementInfo, Position;
    import dmangos.world.player : DeathState;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType;
    import dmangos.world.terrain : pointAt;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    // Rows 0-31: the open sea, 32-63 a lake, both 40 deep (to 100); 64-79 lava a yard deep; beyond, dry land at 60.
    const dir = buildPath(tempDir, "dmangos-environment-test");
    scope (exit)
        rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "maps"));
    TestTerrain land;
    land.height = (row, column) => 60.0f;
    land.areaId = (i, j) => zoneElwynn;
    foreach (i; 0 .. 10)
        foreach (j; 0 .. 16)
        {
            land.waterLevel[[i, j]] = i < 8 ? 100 : 61;
            if (i < 4)
                land.deepWater[[i, j]] = true;
            if (i >= 8)
                land.magma[[i, j]] = true;
        }
    string problem;
    const ushort[uint] flags = [zoneElwynn: exploreElwynn];
    write(buildPath(dir, "maps", "0004831.map"), convertAdt(buildTestAdt(land), flags, problem));

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig c) { c.dataDir = dir; c.movementSpeedCheck = false; c.rateHealth = 0; });
    auto now = MonoTime.currTime;
    context.clock = () => now;
    Position at(float row, float z)
    {
        const p = pointAt(48, 31, row, 10);
        return Position(p[0], p[1], z, 0);
    }

    auto anduin = loggedIn(context, db, 7, "Anduin", at(100, 60));
    auto jaina = loggedIn(context, db, 8, "Jaina", at(101, 60));
    auto me = anduin.session.inWorld;
    auto player = me.player;
    player.values.set!UNIT_FIELD_MAXHEALTH(10_000u);
    player.values.set!UNIT_FIELD_HEALTH(10_000u);
    anduin.read();
    jaina.read();

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
    }

    void move(Opcode opcode, Position p, uint fallTime = 0)
    {
        MovementInfo m;
        m.position = p;
        m.fallTime = fallTime;
        ByteWriter w;
        m.write(w);
        anduin.write(opcode, w.data);
        tick(100); // the liquid is looked at once a tenth of a second
    }

    // What the client was told of its timers: [type, remaining, duration, scale] of each start, or [type] of a stop.
    int[][] timers(const(ServerPacketRead)[] packets)
    {
        int[][] told;
        foreach (p; packets)
        {
            auto r = ByteReader(p.body_);
            if (p.opcode == Opcode.SMSG_START_MIRROR_TIMER)
                told ~= [r.read!int, r.read!int, r.read!int, r.read!int];
            else if (p.opcode == Opcode.SMSG_STOP_MIRROR_TIMER)
                told ~= [r.read!int];
        }
        return told;
    }

    // [type, damage] of each environmental damage log.
    uint[][] hurt(const(ServerPacketRead)[] packets)
    {
        uint[][] logs;
        foreach (p; packets)
            if (p.opcode == Opcode.SMSG_ENVIRONMENTALDAMAGELOG)
            {
                auto r = ByteReader(p.body_);
                assert(r.read!ulong == 7);
                logs ~= [uint(r.read!ubyte), r.read!uint];
            }
        return logs;
    }

    // Swimming at the lake's surface: no timer. Diving: a minute of breath, running out.
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 99));
    assert(timers(anduin.read()) == []);
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 90));
    assert(timers(anduin.read()) == [[1, 60_000, 60_000, -1]]);
    foreach (_; 0 .. 59)
        tick(1000);
    assert(hurt(anduin.read()) == []);
    tick(1000);
    assert(hurt(anduin.read()) == [[1, 2000]], "drowning: a fifth of the health (and 0 to level - 1)");
    tick(1000);
    tick(1000);
    assert(hurt(anduin.read()) == [[1, 2000]], "every two seconds");
    assert(player.values.get!UNIT_FIELD_HEALTH == 6000);

    // Surfacing: the bar fills ten times as fast, and goes once full.
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 99));
    assert(timers(anduin.read()) == [[1, 1000, 60_000, 10]], "a tick of it filled already");
    foreach (_; 0 .. 6)
        tick(1000);
    assert(timers(anduin.read()) == [[1]]);

    // Water Breathing: no breath to hold.
    enum uint breathing = 91_101, slowFall = 91_102;
    with (context.data.spells)
    {
        spells[breathing] = testSpell(breathing, 6, 1, 0);
        spells.edit(breathing).casting.applyAuraName[0] = AuraType.waterBreathing;
        spells[slowFall] = testSpell(slowFall, 6, 1, 0);
        spells.edit(slowFall).casting.applyAuraName[0] = AuraType.featherFall;
    }
    auto waterBreathing = makeAura(context.data.spells.spell(breathing), 7, 1, -1, true, [0, 0, 0]);
    me.addAura(waterBreathing);
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 90));
    foreach (_; 0 .. 70)
        tick(1000);
    assert(timers(anduin.read()) == [] && player.values.get!UNIT_FIELD_HEALTH == 6000);
    me.removeAura(waterBreathing);
    tick(100);
    assert(timers(anduin.read()) == [[1, 60_000, 60_000, -1]], "without it, the breath runs out again");
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 99));
    anduin.read();

    // Out to sea: fatigue, then exhaustion like drowning. Back in the lake it fills again.
    move(Opcode.MSG_MOVE_HEARTBEAT, at(10, 99));
    assert(timers(anduin.read()) == [[0, 60_000, 60_000, -1]]);
    foreach (_; 0 .. 60)
        tick(1000);
    assert(hurt(anduin.read()) == [[0, 2000]], "exhausted");
    move(Opcode.MSG_MOVE_HEARTBEAT, at(50, 99));
    assert(timers(anduin.read()) == [[0, 1000, 60_000, 10]]);

    // Into the lava: a second, then 605 to 610 fire damage every two seconds; no bar.
    player.values.set!UNIT_FIELD_HEALTH(10_000u);
    move(Opcode.MSG_MOVE_HEARTBEAT, at(70, 60.5f));
    tick(1000);
    auto burnt = anduin.read();
    assert(timers(burnt).filter!(t => t[0] == 3).array == []);
    auto lava = hurt(burnt);
    assert(lava.length == 1 && lava[0][0] == 3 && lava[0][1] >= 605 && lava[0][1] <= 610);
    tick(2000);
    assert(hurt(anduin.read()).length == 1);

    // On dry land, a fall of 50 yards: what it costs is told to Jaina too.
    move(Opcode.MSG_MOVE_HEARTBEAT, at(100, 60));
    player.values.set!UNIT_FIELD_HEALTH(10_000u);
    anduin.read();
    jaina.read();
    move(Opcode.MSG_MOVE_JUMP, at(100, 110));
    move(Opcode.MSG_MOVE_FALL_LAND, at(100, 60), 3000);
    const fall = fallDamage(50, 0, 10_000, 1);
    assert(hurt(anduin.read()) == [[2, fall]] && player.values.get!UNIT_FIELD_HEALTH == 10_000 - fall);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_ENVIRONMENTALDAMAGELOG));

    // Slow Fall: ordered, and no damage; when it ends the next fall starts where the player is.
    player.values.set!UNIT_FIELD_HEALTH(10_000u);
    auto slow = makeAura(context.data.spells.spell(slowFall), 7, 1, -1, true, [0, 0, 0]);
    me.addAura(slow);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MOVE_FEATHER_FALL));
    move(Opcode.MSG_MOVE_JUMP, at(100, 110));
    move(Opcode.MSG_MOVE_FALL_LAND, at(100, 60), 3000);
    assert(hurt(anduin.read()) == []);
    move(Opcode.MSG_MOVE_JUMP, at(100, 110));
    me.removeAura(slow);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MOVE_NORMAL_FALL));
    move(Opcode.MSG_MOVE_FALL_LAND, at(100, 60), 3000);
    assert(hurt(anduin.read()) == [[2, fall]], "50 yards from where it ended");

    // A fall that kills: dead, and its gear worn by a tenth.
    player.values.set!UNIT_FIELD_HEALTH(100u);
    move(Opcode.MSG_MOVE_JUMP, at(100, 110));
    move(Opcode.MSG_MOVE_FALL_LAND, at(100, 60), 3000);
    const died = anduin.read();
    assert(hurt(died) == [[2, fall]] && player.deathState == DeathState.corpse);
    assert(opcodesOf(died).canFind(Opcode.SMSG_DURABILITY_DAMAGE_DEATH));

    // Drowned: the same tenth (it cost none; WoWWiki "Death": only PvP and self-inflicted deaths are free).
    me.bringBack(1);
    anduin.read();
    me.environmentalDamage(EnvironmentalDamage.drowning, 10_000);
    assert(player.deathState == DeathState.corpse && opcodesOf(anduin.read()).canFind(Opcode.SMSG_DURABILITY_DAMAGE_DEATH));

    // Back to life, then under the world: dead at once (shown as a fall), and a ghost.
    me.bringBack(1);
    anduin.read();
    move(Opcode.MSG_MOVE_HEARTBEAT, at(100, -600));
    assert(hurt(anduin.read()) == [[2, 10_000]] && player.deathState == DeathState.ghost);

    // The other node carries on the same dive, including both client bars and their damage cadence.
    auto traveler = loggedIn(context, db, 9, "Uther", at(10, 90));
    auto diving = traveler.session.inWorld;
    diving.updateEnvironment();
    diving.updateMirrorTimers(0.msecs);
    traveler.read();
    diving.updateMirrorTimers(30.seconds);
    diving.startFallAt(90);
    auto next = newCreationContext(db, (ref WorldConfig c) { c.dataDir = dir; c.rateHealth = 0; });
    auto relay = new TestPlayerRelay(context, next);
    const beside = at(10, 90);
    const markerSpawn = CreatureSpawn(9000555, creatureInnkeeper, 0, beside.x + 1, beside.y, beside.z);
    auto marker = next.makeCreature(&markerSpawn);
    next.map(0).addObject(marker);
    context.map(0).replicaCreated(2, cellKeyAt(beside.x + 1, beside.y), marker.guid, encodeState(marker, 0));
    assert(diving.actAtReplica(marker.guid, ArrivalAction.init));
    assert(relay.remote !is null);
    assert(timers(traveler.read()) == [[0, 30_000, 60_000, -1], [1, 30_000, 60_000, -1]]);
    relay.remote.inWorld.updateMirrorTimers(29_999.msecs);
    assert(!opcodesOf(traveler.read()).canFind(Opcode.SMSG_ENVIRONMENTALDAMAGELOG));
    relay.remote.inWorld.updateMirrorTimers(1.msecs);
    assert(opcodesOf(traveler.read()).filter!(op => op == Opcode.SMSG_ENVIRONMENTALDAMAGELOG).array.length == 2,
        "fatigue and drowning run out at their original deadline");

    MovementInfo landing;
    landing.position = at(100, 60);
    relay.remote.inWorld.landed(landing);
    assert(opcodesOf(traveler.read()).canFind(Opcode.SMSG_ENVIRONMENTALDAMAGELOG),
        "landing uses the height carried from the old node");
}
