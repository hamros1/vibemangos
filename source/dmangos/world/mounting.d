/**
 * Riding: what a mounted player may not do, and what takes it off its mount (CMaNGOS's rules).
 *
 * A mounted player casts nothing that is not marked `SPELL_ATTR_ALLOW_WHILE_MOUNTED` ("You are mounted",
 * `SPELL_FAILED_NOT_MOUNTED`; on a flight "You are in flight", `SPELL_FAILED_NOT_ON_TAXI`), but triggered spells and
 * passives are not refused (`Spell::CheckCast`). It starts no melee (`Unit::CanAttackNow`, `Unit::Attack`): the
 * client's swing is stopped with `SMSG_ATTACKSTOP`. The 1.12 client does not dismount by itself, so none of these
 * dismounts it; the server does in three places only: using a game object that is not usable mounted (a chest, a
 * door; a mailbox and objects with their "allow mounted" data are, `GameObject::Use`), arriving in a dungeon whose
 * `instance_template.mountAllowed` is 0 (`HandleMoveWorldportAck`), and a flight started by a spell.
 *
 * Its pet stays out on a land mount with its action bar greyed out (`SMSG_PET_MODE`, `PET_MODE_DISABLE_ACTIONS`),
 * and gets its own mode back when the player dismounts (`Player::Mount`, `Player::Unmount`).
 */
module dmangos.world.mounting;

import dmangos.world.spellcast : SpellCastResult;

/// `SPELL_ATTR_ALLOW_WHILE_MOUNTED`: a spell a mounted player may cast (the mount's own dismount, Argent Dawn).
enum uint spellAttrAllowWhileMounted = 0x01000000;

/// `PET_MODE_DISABLE_ACTIONS`: the pet's bar is greyed out while its owner rides.
enum uint petModeDisableActions = 0x8000000;

/**
 * Why a player may not cast a spell of `attributes` (its `Attributes`) as things are; `ok` if it may. Only a mounted
 * player's own casts are refused: a triggered spell or a passive one never is.
 */
SpellCastResult mountedCastError(bool mounted, bool onTaxi, bool triggered, bool passive, uint attributes)
    pure nothrow @nogc @safe
{
    if (!mounted || triggered || passive || (attributes & spellAttrAllowWhileMounted))
        return SpellCastResult.ok;
    return onTaxi ? SpellCastResult.notOnTaxi : SpellCastResult.notMounted;
}

unittest
{
    assert(mountedCastError(false, false, false, false, 0) == SpellCastResult.ok);
    assert(mountedCastError(true, false, false, false, 0) == SpellCastResult.notMounted);
    assert(mountedCastError(true, true, false, false, 0) == SpellCastResult.notOnTaxi);
    assert(mountedCastError(true, false, true, false, 0) == SpellCastResult.ok, "triggered");
    assert(mountedCastError(true, false, false, true, 0) == SpellCastResult.ok, "passive");
    assert(mountedCastError(true, false, false, false, spellAttrAllowWhileMounted) == SpellCastResult.ok);
}

/**
 * Whether a game object of `type` may be used without leaving the mount (`GameObjectInfo::IsUsableMounted`): a
 * mailbox always; a quest giver, a text, a goober or a spell caster when its "allow mounted" data says so.
 */
bool usableMounted(uint type, const(int)[] data) pure nothrow @nogc @safe
{
    enum : uint { questGiver = 2, text = 9, goober = 10, mailbox = 19, spellCaster = 22 }
    size_t at;
    switch (type)
    {
    case mailbox:
        return true;
    case questGiver:
        at = 8;
        break;
    case text, spellCaster:
        at = 3;
        break;
    case goober:
        at = 17;
        break;
    default:
        return false;
    }
    return at < data.length && data[at] != 0;
}

unittest
{
    int[24] data;
    assert(usableMounted(19, data[]), "a mailbox");
    assert(!usableMounted(3, data[]), "a chest never");
    assert(!usableMounted(10, data[]));
    data[17] = 1;
    assert(usableMounted(10, data[]), "a goober allowing it");
    data[3] = 1;
    assert(usableMounted(9, data[]) && usableMounted(22, data[]) && !usableMounted(2, data[]));
}

/// See the module documentation.
mixin template MountRules()
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.mounting : mountedCastError, petModeDisableActions, usableMounted;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS, UNIT_FIELD_MOUNTDISPLAYID;

    /// Whether the player rides: on a mount, or a flight's (`Unit::GetMountID`).
    package @property bool mounted()
    {
        return player !is null && player.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0;
    }

    /// Why this player may not cast `spell` mounted; `ok` if it may.
    package SpellCastResult mountedCastRefusal(const(imported!"dmangos.world.spells".SpellInfo)* spell, bool triggered)
    {
        const onTaxi = (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight) != 0;
        return mountedCastError(mounted, onTaxi, triggered, spell.isPassive, spell.attributes);
    }

    /// Off its mount: every aura that mounts it ends (`RemoveSpellsCausingAura(SPELL_AURA_MOUNTED)`).
    package void dismount()
    {
        if (player is null)
            return;
        foreach (aura; player.auras.list.dup)
            if (aura.has(AuraType.mounted))
                removeAura(aura);
    }

    /// Using `go` by hand: off the mount first, unless it is usable mounted (`GameObject::Use`, not for traps).
    package void dismountToUse(const imported!"dmangos.world.gameobject".GameObject go)
    {
        import dmangos.world.gameobject : GameObjectType;

        if (go.type != GameObjectType.trap && !usableMounted(go.type, go.template_.data[]))
            dismount();
    }

    /// Arrived on another map: off the mount in a dungeon that allows none (`Map::IsMountAllowed`).
    package void dismountOnArrival()
    {
        const entry = context.client.maps.lookup(player.data.map);
        if (entry !is null && entry.isDungeon && !context.data.instanceMountAllowed.get(player.data.map, false))
            dismount();
    }

    /// The mount's aura began (`apply`) or ended: the pet's bar greyed out, or its own mode back (`SMSG_PET_MODE`).
    package void petModeAtMount(bool apply)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.opcodes : Opcode;

        auto pet = ownPet;
        if (pet is null || pet.petData is null || pet.ai is null)
            return;
        ByteWriter w;
        w.put(pet.guid);
        w.put(apply ? petModeDisableActions : uint(pet.ai.react) | uint(pet.petData.command) * 0x100);
        deliver(Opcode.SMSG_PET_MODE, w.data);
    }
}

/**
 * A mounted player: its casts refused ("You are mounted", a mount-allowed spell cast), its attack stopped, a chest
 * used off the mount, a mailbox on it.
 */
unittest
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.spellcast : castResultPacket, SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_MOUNTDISPLAYID;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint horse = 91_301, bolt = 91_302, banner = 91_303;
    with (context.data.spells)
    {
        spells[horse] = testSpell(horse, 6, 1, 0);
        spells.edit(horse).casting.applyAuraName[0] = AuraType.mounted;
        spells.edit(horse).miscValue[0] = creatureInnkeeper; // its model is the mount's
        spells[bolt] = testSpell(bolt, 3, 1, 0); // a dummy on oneself
        spells[banner] = testSpell(banner, 3, 1, 0);
        spells.edit(banner).attributes = spellAttrAllowWhileMounted;
    }
    GameObjectTemplate chest = {entry: 9101, type: GameObjectType.chest, displayId: 1, name: "Chest"};
    GameObjectTemplate mailbox = {entry: 9102, type: GameObjectType.mailbox, displayId: 2, name: "Mailbox"};
    context.data.gameObjectTemplates[9101] = chest;
    context.data.gameObjectTemplates[9102] = mailbox;
    context.data.gameObjectSpawns ~= [GameObjectSpawn(91001, 9101, 0, -8950, -133, 83.53f),
        GameObjectSpawn(91002, 9102, 0, -8950, -131, 83.53f)];

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto me = anduin.session.inWorld;
    me.player.spells ~= [bolt, banner];
    auto map = context.map(0);
    auto loot = context.makeGameObject(&context.data.gameObjectSpawns[$ - 2]);
    auto box = context.makeGameObject(&context.data.gameObjectSpawns[$ - 1]);
    map.addObject(loot);
    map.addObject(box);
    anduin.read();
    me.addAura(makeAura(context.data.spells.spell(horse), me.player.guid, 1, -1, true, [0, 0, 0]));
    assert(me.mounted && me.player.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0);
    anduin.read();
    ubyte[] castAt(uint spell)
    {
        ByteWriter w;
        w.put(spell);
        SpellTargets(TargetFlags.self, 0).write(w);
        return w.data.dup;
    }

    // A spell: "You are mounted"; one allowed mounted goes, and the player stays on its mount.
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(bolt));
    assert(bodyOf(anduin.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(bolt, SpellCastResult.notMounted));
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(banner));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO), "allowed while mounted");
    assert(me.mounted, "the server does not dismount for a cast");
    // A triggered one is never refused.
    assert(me.castSpell(context.data.spells.spell(bolt), SpellTargets(TargetFlags.self, 0), true, 0)
        == SpellCastResult.ok);
    anduin.read();

    // Melee: stopped at the client at once.
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_ATTACKSTOP]);

    // The mailbox is used mounted; the chest takes the player off its mount.
    me.dismountToUse(box);
    assert(me.mounted);
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(loot.guid));
    assert(!me.mounted, "off the mount for a chest");

    // Dismounted, the spell goes.
    anduin.read();
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(bolt));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO));
}
