/**
 * Summoning a player: the warlocks' Ritual of Summoning, the meeting stones' summons, and the request the summoned
 * player answers (CMaNGOS's `Spell::EffectTransmitted` for `GAMEOBJECT_TYPE_SUMMONING_RITUAL`, `GameObject::Use` and
 * `TriggerSummoningRitual`, `Spell::EffectSummonPlayer`, `Player::SummonIfPossible`).
 *
 * The ritual's spell (698; a meeting stone's 23598) is channelled; its portal stands where the caster does, owned by
 * it, with the caster as its first participant and the caster's target as the one to summon. Others of the
 * caster's group click it (`CMSG_GAMEOBJ_USE`, while the caster still channels, not in combat if its spell is not
 * for combat): each joins once and channels the ritual too (or casts the portal's own animation spell). With as
 * many participants as the portal needs (`reqParticipants`, the caster counted), every channel ends, the portal
 * goes, and the caster casts the portal's spell (7720) at the target. The portal goes too when the caster's channel
 * ends early.
 *
 * `SPELL_EFFECT_SUMMON_PLAYER` asks the target: `SMSG_SUMMON_REQUEST` with the summoner, its area and two minutes to
 * answer; the summoner's place is kept. The client accepts with `CMSG_SUMMON_RESPONSE` (the summoner's guid; it
 * says nothing to decline, the request just runs out): alive, out of combat, within the two minutes and for that
 * summoner, the player stops any flight and is teleported there.
 *
 * A meeting stone (`GAMEOBJECT_TYPE_MEETINGSTONE`) used with a group mate targeted, both within its levels, starts
 * the meeting stones' ritual (two participants: the user and one more).
 */
module dmangos.world.rituals;

/// `MAX_PLAYER_SUMMON_DELAY`: how long a summons may be accepted, in seconds.
enum uint summonAcceptSeconds = 2 * 60;

/// `SMSG_SUMMON_REQUEST`: the summoner, its area, the milliseconds before the request runs out.
ubyte[] summonRequest(ulong summoner, uint area) pure nothrow @safe
{
    import dmangos.bytes : ByteWriter;

    ByteWriter w;
    w.put(summoner);
    w.put(area);
    w.put(summonAcceptSeconds * 1000);
    return w.data.dup;
}

unittest
{
    assert(summonRequest(0x42, 12) == [0x42, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 0xC0, 0xD4, 0x01, 0]);
}

/// A summoning portal's data (`GAMEOBJECT_TYPE_SUMMONING_RITUAL`).
struct RitualData
{
    uint participants; /// `reqParticipants`, the caster counted
    uint spell;        /// cast by the caster at the target when they are all there
    uint animSpell;    /// cast by each who joins; none: they channel the ritual's spell
    bool persistent;   /// it stays for another ritual
    bool grouped;      /// only the caster's group may join (`castersGrouped`)

    /// From the template's data.
    static RitualData of(const(int)[] data) pure nothrow @nogc @safe
    {
        return RitualData(cast(uint) data[0], cast(uint) data[1], cast(uint) data[2], data[3] != 0, data[6] != 0);
    }
}

unittest
{
    int[24] portal = [3, 7720, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    assert(RitualData.of(portal[]) == RitualData(3, 7720, 0, false, true));
}

/// See the module documentation.
mixin template RitualSummoning()
{
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectType;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.rituals : RitualData, summonAcceptSeconds, summonRequest;
    import dmangos.world.spellcast : duration, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    private ulong ritualPortal; /// the portal of the ritual this player channels; 0: none

    /// A summons waiting for this player's answer (`Player::SetSummonPoint`).
    private struct SummonPoint
    {
        ulong summoner;
        uint map;
        Position at;
        long expires; /// Unix time
    }

    private SummonPoint summonPoint;

    /// Whether `t` is a summoning portal (`SPELL_EFFECT_TRANS_DOOR` makes one instead of a bobber).
    package static bool isRitualPortal(const(imported!"dmangos.world.gameobject".GameObjectTemplate)* t)
    {
        return t !is null && t.type == GameObjectType.summoningRitual;
    }

    /**
     * The ritual's portal (effect `i` of `spell`): where the caster stands, owned by it, the caster its first
     * participant and the caster's target the one to summon; the caster's channel is at it.
     */
    package void openRitualPortal(const(SpellInfo)* spell, size_t i)
    {
        const entry = cast(uint) spell.miscValue[i];
        const t = entry in context.data.gameObjectTemplates;
        if (!isRitualPortal(t))
            return;
        closeRitualPortal();
        const at = player.position;
        GameObjectSpawn spawn = {guid: context.nextTemporaryCounter(), entry: entry, map: map.id, x: at.x, y: at.y,
            z: at.z, orientation: at.orientation, respawnSeconds: -1};
        spawn.rotation = [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)];
        auto go = new GameObject(spawn, t);
        go.owner = player.guid;
        go.instanceId = map.instanceId;
        go.ritualSpell = spell.id;
        go.ritualUsers = [player.guid];
        go.ritualTarget = player.values.get!UNIT_FIELD_TARGET;
        go.values.set!OBJECT_FIELD_CREATED_BY(player.guid);
        go.values.set!GAMEOBJECT_LEVEL(player.data.level);
        map.addObject(go);
        ritualPortal = go.guid;
        channelObject = go.guid; // the channel is at it
    }

    /// The caster's channel ended: its portal goes (`Unit::RemoveGameObject` at the spell's end).
    package void closeRitualPortal()
    {
        if (ritualPortal && map !is null)
            map.removeObject(ritualPortal);
        ritualPortal = 0;
    }

    import std.math : cos, sin;

    /**
     * A player clicks the portal `go` (`GameObject::Use`): it joins the ritual once, and when enough have joined
     * the ritual is done.
     */
    package void joinRitual(GameObject go)
    {
        const r = RitualData.of(go.template_.data[]);
        enum uint notInCombat = 0x10000000; // SPELL_ATTR_NOT_IN_COMBAT_ONLY_PEACEFUL
        const summonSpell = context.data.spells.spell(r.spell);
        if (summonSpell !is null && (summonSpell.attributes & notInCombat) && inCombat)
            return;
        auto owner = go.owner ? cast(typeof(this)) context.onlinePlayer(go.owner) : null;
        if (go.owner)
        {
            // The caster's group only, the caster not again, and only while it channels.
            if (owner is null || owner is this || owner.map !is map || owner.channelSpell is null
                    || !context.groups.sameGroup(player.guid, go.owner))
                return;
        }
        else if (go.ritualUsers.length && r.grouped && !context.groups.sameGroup(player.guid, go.ritualUsers[0]))
            return;
        import std.algorithm.searching : canFind;

        if (go.ritualUsers.canFind(player.guid))
            return;
        go.ritualUsers ~= player.guid;
        if (const anim = r.animSpell ? context.data.spells.spell(r.animSpell) : null)
            castSpell(anim, SpellTargets(TargetFlags.self, 0), false, 0);
        else if (const ritual = context.data.spells.spell(go.ritualSpell))
        {
            channelObject = go.guid; // the ritual's channel alone, without its effects (`TRIGGERED_CHANNEL_ONLY`)
            startChannel(ritual, go.guid);
        }
        if (go.ritualUsers.length >= r.participants)
            completeRitual(go, r, owner);
    }

    /// Enough have joined (`TriggerSummoningRitual`): the channels end, the portal goes, the summons is cast.
    private void completeRitual(GameObject go, const RitualData r, typeof(this) owner)
    {
        auto caster = owner !is null ? owner : go.ritualUsers.length ? cast(typeof(this)) context.onlinePlayer(
            go.ritualUsers[0]) : null;
        const target = go.ritualTarget;
        foreach (guid; go.ritualUsers)
            if (auto user = cast(typeof(this)) context.onlinePlayer(guid))
                if (user.map is map && user.channelSpell !is null)
                    user.endChannel(false);
        if (r.persistent)
            go.ritualUsers = null;
        else
            map.removeObject(go.guid);
        if (caster !is null && caster.player !is null)
            if (const spell = context.data.spells.spell(r.spell))
                caster.castSpell(spell, SpellTargets(TargetFlags.unit, target), true, 0);
    }

    /**
     * `SPELL_EFFECT_SUMMON_PLAYER` at `target`: it is asked to come here (`SMSG_SUMMON_REQUEST`), unless Evil Twin
     * makes it ignore summonses.
     */
    package void summonPlayerEffect(ulong target)
    {
        enum uint evilTwin = 23445;
        auto who = target && target != player.guid ? cast(typeof(this)) context.onlinePlayer(target) : null;
        if (who is null || who.player is null || who.player.auras.find(evilTwin) !is null)
            return;
        who.summonPoint = SummonPoint(player.guid, player.data.map, player.position,
            context.unixTime + summonAcceptSeconds);
        who.deliver(Opcode.SMSG_SUMMON_REQUEST, summonRequest(player.guid, player.area ? player.area : player.data.zone));
    }

    /**
     * The client accepts a summons (`HandleSummonResponseOpcode`, `Player::SummonIfPossible`); a game master's mass
     * summon is answered the same way (`dmangos.world.gmlevel3`).
     */
    @Handles(Opcode.CMSG_SUMMON_RESPONSE, WorldState.inWorld)
    void handleSummonResponse(const imported!"dmangos.world.packets".ClientSummonResponse response)
    {
        import dmangos.world.defines : UnitFlags;

        if (acceptGmSummonOffer())
            return;
        const summoner = response.summoner;
        if (!player.fighter.alive || inCombat)
            return;
        const point = summonPoint;
        if (summoner != point.summoner || point.summoner == 0 || point.expires < context.unixTime)
            return;
        summonPoint = SummonPoint.init;
        if (flying) // the flight stops (`TaxiFlightInterrupt`)
        {
            taxiDestination = 0;
            player.data.taxiPath = null;
            player.values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
            player.values.set!UNIT_FIELD_FLAGS(player.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.taxiFlight);
        }
        teleportTo(point.map, Position(point.at.x, point.at.y, point.at.z, player.position.orientation));
    }

    /**
     * A meeting stone used (`GAMEOBJECT_TYPE_MEETINGSTONE`): with a group mate targeted, both within the stone's
     * levels (data 0 and 1), the user casts the meeting stones' ritual (23598) at itself.
     */
    package void useMeetingStoneToSummon(GameObject go)
    {
        enum uint meetingStoneRitual = 23598;
        const target = player.values.get!UNIT_FIELD_TARGET;
        auto mate = target && target != player.guid ? cast(typeof(this)) context.onlinePlayer(target) : null;
        if (mate is null || mate.player is null || !context.groups.sameGroup(player.guid, target))
            return;
        const minLevel = cast(uint) go.template_.data[0], maxLevel = cast(uint) go.template_.data[1];
        foreach (level; [player.data.level, mate.player.data.level])
            if (level < minLevel || level > maxLevel)
                return;
        if (const spell = context.data.spells.spell(meetingStoneRitual))
            castSpell(spell, SpellTargets(TargetFlags.unit, player.guid), false, 0);
    }
}

/**
 * Ritual of Summoning: the warlock's portal, two group mates joining, the summons sent to the target, who accepts
 * and comes; a stranger cannot join; the portal goes with an early end of the channel.
 */
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.gameobject : GameObject, GameObjectTemplate, GameObjectType;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[6u, 120_000, 0, 120_000]]), "SpellDuration.dbc");
    enum uint ritual = 698, summons = 7720, portalEntry = 36727;
    with (context.data.spells)
    {
        spells[ritual] = testSpell(ritual, SpellEffect.transDoor, 1, 0);
        spells.edit(ritual).miscValue[0] = portalEntry;
        spells.edit(ritual).attributesEx = 0x4; // channelled
        spells.edit(ritual).casting.durationIndex = 6;
        spells[summons] = testSpell(summons, SpellEffect.summonPlayer, 0, 0);
    }
    GameObjectTemplate portal = {entry: portalEntry, type: GameObjectType.summoningRitual, displayId: 1,
        name: "Summoning Portal"};
    portal.data[0] = 3;
    portal.data[1] = summons;
    portal.data[6] = 1; // the caster's group only
    context.data.gameObjectTemplates[portalEntry] = portal;

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8948, -132, 83.5f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8948, -133, 83.5f));
    auto uther = loggedIn(context, db, 10, "Uther", Position(-8900, -100, 83.5f));
    auto bolvar = loggedIn(context, db, 11, "Bolvar", Position(-8949, -133, 83.5f));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("uther"));
    uther.write(Opcode.CMSG_GROUP_ACCEPT, null);
    auto me = anduin.session.inWorld;
    me.player.spells ~= ritual;
    auto map = context.map(0);
    anduin.read();
    jaina.read();
    varian.read();
    uther.read();
    bolvar.read();
    GameObject portalHere()
    {
        GameObject found;
        map.forEachObject((imported!"dmangos.world.map".MapObject o) {
            if (auto go = cast(GameObject) o)
                if (go.template_.entry == portalEntry)
                    found = go;
        });
        return found;
    }

    // Uther targeted, the ritual begins: the portal at the warlock, who channels at it.
    anduin.write(Opcode.CMSG_SET_SELECTION, ClientGuid(uther.session.character.guid));
    ByteWriter cast_;
    cast_.put(ritual);
    SpellTargets(TargetFlags.self, 0).write(cast_);
    anduin.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    auto go = portalHere();
    assert(go !is null && go.owner == me.player.guid && go.ritualUsers == [me.player.guid]);
    assert(go.ritualTarget == uther.session.character.guid);
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == ritual && me.player.values.get!UNIT_FIELD_CHANNEL_OBJECT == go.guid);

    // A stranger cannot join; Jaina can, once, and channels too.
    bolvar.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(go.guid));
    assert(go.ritualUsers.length == 1);
    jaina.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(go.guid));
    jaina.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(go.guid));
    assert(go.ritualUsers.length == 2, "once each");
    assert(jaina.session.character.values.get!UNIT_CHANNEL_SPELL == ritual);
    uther.read();

    // The third: the channels end, the portal goes, Uther is asked.
    varian.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(go.guid));
    assert(portalHere() is null);
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == 0 && jaina.session.character.values.get!UNIT_CHANNEL_SPELL == 0);
    auto request = ByteReader(bodyOf(uther.read(), Opcode.SMSG_SUMMON_REQUEST));
    assert(request.read!ulong == me.player.guid);
    request.read!uint; // the area
    assert(request.read!uint == 120_000);

    // A wrong summoner is ignored; the right one brings him over, once.
    uther.write(Opcode.CMSG_SUMMON_RESPONSE, ClientSummonResponse(jaina.session.character.guid));
    assert(!opcodesOf(uther.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK));
    uther.write(Opcode.CMSG_SUMMON_RESPONSE, ClientSummonResponse(me.player.guid));
    assert(opcodesOf(uther.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK), "teleported to the warlock");
    uther.write(Opcode.CMSG_SUMMON_RESPONSE, ClientSummonResponse(me.player.guid));
    assert(!opcodesOf(uther.read()).canFind(Opcode.MSG_MOVE_TELEPORT_ACK), "once");

    // Begun again and cancelled: the portal goes with the channel.
    anduin.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    assert(portalHere() !is null);
    ByteWriter cancel;
    cancel.put(ritual);
    anduin.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    assert(portalHere() is null);
}
