/**
 * Pets end to end (`dmangos.world.pethandlers`, `dmangos.world.petai`, `dmangos.world.creaturecombat`):
 * a demon summoned, followed, named, dismissed and summoned again as it was; a beast tamed, sent
 * against an enemy and killing it for its owner, gaining levels, stabled and taken out again,
 * saved at logout and back at login, killed and revived.
 */
module dmangos.world.pettests;

version (unittest)
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.creature : Creature, CreatureTemplate, TempSpawnType;
    import dmangos.world.creatureai : ReactState;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, highGuidOf;
    import dmangos.world.opcodes;
    import dmangos.world.pet;
    import dmangos.world.pethandlers;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    enum uint imp = 416, wolf = 299, boar = 113;

    /// A creature template for the tests: a demon, or a tameable beast of the wolf family.
    CreatureTemplate petTemplate(uint entry, string name, bool beast, uint faction = 14)
    {
        CreatureTemplate t;
        t.entry = entry;
        t.name = name;
        t.minLevel = t.maxLevel = 1;
        t.modelId1 = 1906;
        t.faction = faction;
        t.unitClass = 1;
        t.minLevelHealth = t.maxLevelHealth = 60;
        t.meleeBaseAttackTime = 2000;
        t.minMeleeDmg = 2;
        t.maxMeleeDmg = 3;
        t.speedRun = 1;
        t.speedWalk = 1;
        t.detection = 0;
        if (beast)
        {
            t.creatureType = creatureTypeBeast;
            t.family = 1;
            t.typeFlags = typeFlagTameable;
        }
        return t;
    }

    /// The pet tables and creatures the tests need, and factions: players' and monsters' (14), enemies.
    void addPetData(TestClient* client, imported!"dmangos.world.context".WorldContext context)
    {
        auto data = context.data;
        data.creatureTemplates[imp] = petTemplate(imp, "Imp", false);
        data.creatureTemplates[wolf] = petTemplate(wolf, "Young Wolf", true);
        data.creatureTemplates[boar] = petTemplate(boar, "Stonetusk Boar", true);
        foreach (uint level; 1 .. 6)
        {
            data.pets.levelStats.require(1, null)[level] = PetLevelStats(40 + 20 * level, 0, 20 * level, [22, 20, 22, 20, 20]);
            data.pets.levelStats.require(imp, null)[level] = PetLevelStats(140, 48, 20, [20, 5, 20, 24, 23]);
        }
        data.pets.nameParts[imp] = [["Aba"], ["zim"]];
        data.xpForNextLevel = [0, 400, 900, 1400, 2100, 2800];
        enum uint players = 1, monsters = 8;
        const own = client.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[own, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
            0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    }

    /// A spell with one effect, for the effects to be run by hand.
    SpellInfo effectSpell(uint id, uint effect, int misc = 0)
    {
        SpellInfo s;
        s.id = id;
        s.effect[0] = effect;
        s.miscValue[0] = misc;
        return s;
    }
}

/// A demon: summoned with its name and spells, following, named on query, sent back and summoned again.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto gul = loggedIn(context, db, 7, "Guldan", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceHuman, 0, 1, (ref c) { c.classId = classMage; });
    gul.read();
    addPetData(&gul, context);
    auto session = gul.session;
    auto map = context.map(0);

    void tick(int ms)
    {
        now += ms.msecs;
        session.update(ms.msecs);
        map.update(ms.msecs);
    }

    auto summonImp = effectSpell(spellSummonImp, 56, imp);
    session.summonPetEffect(&summonImp, 0);
    auto pet = session.ownPet;
    assert(pet !is null && pet.petOwner == session.character.guid && highGuidOf(pet.guid) == HighGuid.pet);
    auto state = cast(PetState) pet.petData;
    assert(state.type == PetType.summon && state.name == "Abazim", "a name from pet_name_generation");
    assert(pet.values.get!UNIT_FIELD_MAXHEALTH == 140 && pet.values.get!UNIT_FIELD_MAXPOWER1 == 48);
    assert(pet.values.get!UNIT_FIELD_SUMMONEDBY == session.character.guid);
    assert(session.character.values.get!UNIT_FIELD_SUMMON == pet.guid);
    const sent = gul.read();
    const spells = bodyOf(sent, Opcode.SMSG_PET_SPELLS);
    assert(spells.length > 8 && ByteReader(spells).read!ulong == pet.guid, "its bar");
    auto rows = db.loadPets(7);
    assert(rows.length == 1 && rows[0].slot == PetSlot.current && rows[0].entry == imp && rows[0].type == PetType.summon);

    // Its name, asked for.
    {
        ByteWriter w;
        w.put(state.number);
        w.put(pet.guid);
        gul.write(Opcode.CMSG_PET_NAME_QUERY, w.data);
        const name = bodyOf(gul.read(), Opcode.SMSG_PET_NAME_QUERY_RESPONSE);
        assert(name.length > 4 && name[4 .. 11] == cast(const(ubyte)[]) "Abazim\0");
    }

    // It follows: its owner runs off, and it comes after it.
    import dmangos.world.teleport : moveTo;

    gul.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(-8940, -132.49f, 83.53f, 0)));
    foreach (_; 0 .. 20)
        tick(200);
    const p = pet.position, o = session.character.position;
    assert((p.x - o.x) ^^ 2 + (p.y - o.y) ^^ 2 < 9, "beside its owner");

    // Dismissed from its bar: set aside, its bar gone.
    {
        ByteWriter w;
        w.put(pet.guid);
        w.put(actionButton(CommandState.dismiss, ActiveState.command));
        w.put(0UL);
        gul.write(Opcode.CMSG_PET_ACTION, w.data);
    }
    assert(session.ownPet is null && map.findObject(pet.guid) is null);
    assert(bodyOf(gul.read(), Opcode.SMSG_PET_SPELLS) == noPetSpellsPacket());
    rows = db.loadPets(7);
    assert(rows.length == 1 && rows[0].slot == PetSlot.notInSlot);

    // Summoned again: the same imp, at full health.
    session.summonPetEffect(&summonImp, 0);
    assert(session.ownPet !is null && (cast(PetState) session.ownPet.petData).number == state.number);
    assert(session.ownPet.values.get!UNIT_FIELD_HEALTH == 140);
    assert(db.loadPets(7).length == 1);

    // It goes with its master at logout, and comes back at login.
    gul.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    gul.read();
    tick(100);
    rows = db.loadPets(7);
    assert(rows.length == 1 && rows[0].slot == PetSlot.current, "saved as out");
}

/**
 * A beast: tamed, sent against an enemy that it kills for its owner, gaining levels, stabled and
 * taken out again, back after a login, killed and revived.
 */
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const start = Position(-8949.95f, -132.49f, 83.53f, 0);
    auto rexxar = loggedIn(context, db, 7, "Rexxar", start, AccountLevel.player, raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session;
    auto map = context.map(0);

    void tick(int ms)
    {
        now += ms.msecs;
        session.update(ms.msecs);
        map.update(ms.msecs);
    }

    // Tamed: the beast goes, and a pet of it comes out, at its level and its share of health.
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    beast.values.set!UNIT_FIELD_HEALTH(beast.values.get!UNIT_FIELD_MAXHEALTH / 2);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    assert(map.findObject(beast.guid) is null, "the beast went");
    auto pet = session.ownPet;
    assert(pet !is null && pet.template_.entry == wolf);
    auto state = cast(PetState) pet.petData;
    assert(state.type == PetType.hunter && state.name == "Young Wolf" && pet.ai.react == ReactState.defensive);
    assert(pet.values.get!UNIT_FIELD_MAXHEALTH == 60 && pet.values.get!UNIT_FIELD_HEALTH == 30);
    assert(pet.values.get!UNIT_FIELD_FLAGS & unitFlagPetRename, "it may be named");
    assert(pet.values.getByte!UNIT_FIELD_BYTES_0(3) == 2 && pet.values.get!UNIT_FIELD_MAXPOWER1(2) == maxFocus);
    rexxar.read();

    // Another beast cannot be tamed while it is out.
    auto second = context.summonCreature(map, boar, Position(-8947, -130, 83.53f, 0), TempSpawnType.dead, 0, 0);
    session.tameCreature(&tame, second.guid);
    assert(bodyOf(rexxar.read(), Opcode.SMSG_PET_TAME_FAILURE) == [ubyte(PetTameFailure.anotherSummonActive)]);

    // Named, once.
    {
        ByteWriter w;
        w.put(pet.guid);
        w.putCString("Misha");
        rexxar.write(Opcode.CMSG_PET_RENAME, w.data);
        assert(state.name == "Misha" && !(pet.values.get!UNIT_FIELD_FLAGS & unitFlagPetRename));
        ByteWriter again;
        again.put(pet.guid);
        again.putCString("Huffer");
        rexxar.write(Opcode.CMSG_PET_RENAME, again.data);
        assert(state.name == "Misha");
        assert(validPetName("Ab") && !validPetName("A") && !validPetName("Wolf1") && !validPetName("Abcdefghijklm"));
    }

    // Sent against the boar: it fights it, the boar fights back, and the boar dies the owner's kill.
    second.values.set!UNIT_FIELD_MAXHEALTH(20u);
    second.values.set!UNIT_FIELD_HEALTH(20u);
    pet.values.set!UNIT_FIELD_MINDAMAGE(8.0f);
    pet.values.set!UNIT_FIELD_MAXDAMAGE(8.0f);
    {
        ByteWriter w;
        w.put(pet.guid);
        w.put(actionButton(CommandState.attack, ActiveState.command));
        w.put(second.guid);
        rexxar.write(Opcode.CMSG_PET_ACTION, w.data);
    }
    assert(pet.ai.currentVictim == second.guid);
    foreach (_; 0 .. 60)
    {
        tick(250);
        if (!second.alive)
            break;
    }
    assert(!second.alive, "killed by the pet");
    assert(second.lootRecipient == session.character.guid, "tapped for its owner");
    foreach (_; 0 .. 4)
        tick(250);
    assert(pet.ai.currentVictim == 0, "back to its owner");

    // A hunter pet learns as its owner does, up to its owner's level.
    (cast() session.character).data.level = 3;
    session.petGainsXp(1000);
    assert(pet.values.get!UNIT_FIELD_LEVEL == 3 && pet.values.get!UNIT_FIELD_PETEXPERIENCE == 0);
    assert(pet.values.get!UNIT_FIELD_MAXHEALTH == 100 && pet.values.get!UNIT_FIELD_HEALTH == 100);
    (cast() session.character).data.level = 1;

    // At a stable master: a slot bought, the pet stabled, then taken out again.
    auto keeper = cast(Creature) map.findObject(imported!"dmangos.world.objects".makeGuid(HighGuid.unit,
        creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_NPC_FLAGS(keeper.values.get!UNIT_NPC_FLAGS | 0x2000);
    (cast() session.character).modifyMoney(10_000);
    {
        ByteWriter w;
        w.put(keeper.guid);
        rexxar.write(Opcode.CMSG_STABLE_PET, w.data);
        assert(bodyOf(rexxar.read(), Opcode.SMSG_STABLE_RESULT) == [ubyte(StableResult.failed)], "no slot yet");
        rexxar.write(Opcode.CMSG_BUY_STABLE_SLOT, w.data);
        assert(bodyOf(rexxar.read(), Opcode.SMSG_STABLE_RESULT) == [ubyte(StableResult.slotBought)]);
        assert(db.loadStableSlots(7) == 1);
        rexxar.write(Opcode.CMSG_STABLE_PET, w.data);
        assert(bodyOf(rexxar.read(), Opcode.SMSG_STABLE_RESULT) == [ubyte(StableResult.stabled)]);
        assert(session.ownPet is null && db.loadPets(7)[0].slot == 1);
        rexxar.write(Opcode.MSG_LIST_STABLED_PETS, w.data);
        auto list = ByteReader(bodyOf(rexxar.read(), Opcode.MSG_LIST_STABLED_PETS));
        assert(list.read!ulong == keeper.guid && list.read!ubyte == 1 && list.read!ubyte == 1);
        assert(list.read!uint == state.number);
        ByteWriter out_;
        out_.put(keeper.guid);
        out_.put(state.number);
        rexxar.write(Opcode.CMSG_UNSTABLE_PET, out_.data);
        assert(bodyOf(rexxar.read(), Opcode.SMSG_STABLE_RESULT) == [ubyte(StableResult.unstabled)]);
        assert(session.ownPet !is null && (cast(PetState) session.ownPet.petData).name == "Misha");
        assert(db.loadPets(7)[0].slot == PetSlot.current);
    }
    pet = session.ownPet;
    state = cast(PetState) pet.petData;

    // Killed: a corpse a while, then set aside dead; Call Pet cannot bring it, Revive Pet does.
    import dmangos.world.spellcast : SpellCastResult, SpellTargets;

    pet.ai.petStopAttack(map);
    {
        import dmangos.world.unit : Blow, dealDamage, UnitRef;

        dealDamage(UnitRef.init, map.unitOf(pet), 10_000, Blow.spell());
    }
    assert(!pet.alive && session.ownPet is pet);
    foreach (_; 0 .. 70)
        tick(1000);
    assert(session.ownPet is null && db.loadPets(7)[0].slot == PetSlot.notInSlot && db.loadPets(7)[0].health == 0);
    rexxar.read();
    auto callPet = effectSpell(883, 56);
    SpellTargets none;
    assert(session.petCastCheck(&callPet, none) == SpellCastResult.dontReport);
    assert(bodyOf(rexxar.read(), Opcode.SMSG_PET_TAME_FAILURE) == [ubyte(PetTameFailure.dead)]);
    auto revive = effectSpell(982, 109);
    assert(session.petCastCheck(&revive, none) == SpellCastResult.ok);
    session.reviveDeadPet(15);
    pet = session.ownPet;
    assert(pet !is null && pet.alive && pet.values.get!UNIT_FIELD_HEALTH == pet.values.get!UNIT_FIELD_MAXHEALTH * 15 / 100);
    assert(session.petCastCheck(&callPet, none) == SpellCastResult.alreadyHaveSummon);

    // Out at logout, out again at login.
    rexxar.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    rexxar.read();
    tick(100);
    assert(db.loadPets(7)[0].slot == PetSlot.current && map.findObject(pet.guid) is null);
    rexxar = loggedIn(context, db, 7, "Rexxar", start, AccountLevel.player, raceOrc);
    assert(rexxar.session.ownPet !is null && (cast(PetState) rexxar.session.ownPet.petData).name == "Misha");

    // Abandoned: gone for good.
    {
        ByteWriter w;
        w.put(rexxar.session.ownPet.guid);
        rexxar.write(Opcode.CMSG_PET_ABANDON, w.data);
    }
    assert(rexxar.session.ownPet is null && db.loadPets(7).length == 0);
}
