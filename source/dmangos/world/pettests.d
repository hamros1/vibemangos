/**
 * Pets end to end (`dmangos.world.pethandlers`, `dmangos.world.petai`, `dmangos.world.creaturecombat`):
 * a demon summoned, followed, named, dismissed and summoned again as it was; a beast tamed, sent
 * against an enemy and killing it for its owner, gaining levels, stabled and taken out again,
 * saved at logout and back at login, killed and revived.
 */
module dmangos.world.pettests;

import dmangos.world.money : Copper;

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
        s.effect[0] = cast(imported!"dmangos.world.spellids".SpellEffect) effect;
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
    auto session = gul.session.inWorld;
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
    auto state = pet.petData;
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
    assert(session.ownPet !is null && session.ownPet.petData.number == state.number);
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
    auto session = rexxar.session.inWorld;
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
    auto state = pet.petData;
    assert(state.type == PetType.hunter && state.name == "Young Wolf" && pet.ai.react == ReactState.defensive);
    // Rebellious and unhappy at first, but with loyalty to lose (some ten minutes of it), not none.
    assert(state.loyalty == 1 && state.loyaltyPoints == tamedLoyaltyPoints);
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
    pet.values.set!UNIT_FIELD_POWER1(4, 500_000u); // content: its damage as it is
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
    (cast() session.character).receive(Copper(10_000));
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
        assert(session.ownPet !is null && session.ownPet.petData.name == "Misha");
        assert(db.loadPets(7)[0].slot == PetSlot.current);
    }
    pet = session.ownPet;
    state = pet.petData;

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

    // Out at logout, out again at login: with its aura's time left and its cooldown.
    {
        import dmangos.world.auras : AuraType, makeAura;
        import dmangos.world.spellhandlers : testSpell;

        enum uint mark = 97301, bite = 97302;
        context.data.spells.spells[mark] = testSpell(mark, 6, 1, 0);
        context.data.spells.spells.edit(mark).casting.applyAuraName[0] = AuraType.modResistance;
        bool isNew;
        pet.auras.apply(makeAura(mark in context.data.spells.spells, pet.guid, 1, 300_000, true, [10, 0, 0]),
            pet.values, isNew);
        pet.ai.petCooldowns[bite] = 30_000;
    }
    const petId = pet.petData.number;
    rexxar.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    rexxar.read();
    tick(100);
    assert(db.loadPets(7)[0].slot == PetSlot.current && map.findObject(pet.guid) is null);
    assert(db.loadPetAuras(petId).length == 1 && db.loadPetAuras(petId)[0].remaining > 290_000, "its aura saved");
    assert(db.loadPetCooldowns(petId).length == 1 && db.loadPetCooldowns(petId)[0][0] == 97302, "its cooldown saved");
    rexxar = loggedIn(context, db, 7, "Rexxar", start, AccountLevel.player, raceOrc);
    assert(rexxar.session.inWorld.ownPet !is null && rexxar.session.inWorld.ownPet.petData.name == "Misha");
    assert(rexxar.session.inWorld.ownPet.auras.find(97301) !is null, "its aura back");
    assert(97302 in rexxar.session.inWorld.ownPet.ai.petCooldowns, "its cooldown back");

    // Abandoned: gone for good.
    {
        ByteWriter w;
        w.put(rexxar.session.inWorld.ownPet.guid);
        rexxar.write(Opcode.CMSG_PET_ABANDON, w.data);
    }
    assert(rexxar.session.inWorld.ownPet is null && db.loadPets(7).length == 0);
}

/**
 * A hunter pet's mood: its happiness falls with time, its loyalty rises while it is content or happy, food
 * makes it happier, and its mood sets how hard it hits.
 */
unittest
{
    import dmangos.world.pethandlers : happinessLevel, moodDamageFactor;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session.inWorld;
    auto map = context.map(0);
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    auto pet = session.ownPet;
    auto state = pet.petData;
    rexxar.read();

    // Content: every 7.5 s a pet of loyalty level 1 loses (140 >> 1) x 125 = 8750 happiness.
    pet.values.set!UNIT_FIELD_POWER1(4, 2 * happinessLevel - 1);
    const before = pet.values.get!UNIT_FIELD_POWER1(4);
    session.updatePetMood(7500.msecs);
    assert(pet.values.get!UNIT_FIELD_POWER1(4) == before - 8750, "happiness falls");
    const points = state.loyaltyPoints;
    session.updatePetMood(4500.msecs); // 12 s in all: a loyalty tick
    assert(state.loyaltyPoints == points + 10, "content: ten loyalty points");

    // Past its level's points, and no experience owed: its loyalty rises, with training points.
    state.xpForNextLoyalty = 0;
    state.loyaltyPoints = 5495;
    const trainingBefore = state.trainingPoints;
    session.modifyLoyalty(10);
    assert(state.loyalty == 2 && state.loyaltyPoints == 4500 && state.trainingPoints > trainingBefore, "level 2");

    // Unhappy, it hits a quarter softer; happy, a quarter harder.
    assert(moodDamageFactor(0) == 0.75f && moodDamageFactor(2 * happinessLevel) == 1.25f);
}

/// The owner's death sends the pet away; it comes back when its owner comes back to life.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session.inWorld;
    auto map = context.map(0);
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    assert(session.ownPet !is null);
    rexxar.read();

    import dmangos.world.unit : Blow, UnitRef;

    session.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(session.ownPet is null, "gone with its owner");
    session.bringBack(1.0f);
    assert(session.ownPet !is null && session.ownPet.template_.entry == wolf, "back with its owner");
}

/**
 * Pet training: a teaching spell cast at the pet teaches it (and costs it its training points); the hunter learns a
 * noted teaching spell as the pet uses its ability, one time in ten; the training points field as the client reads it.
 */
unittest
{
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.updatefields : UNIT_TRAINING_POINTS;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session.inWorld;
    auto map = context.map(0);
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    auto pet = session.ownPet;
    auto state = pet.petData;
    rexxar.read();

    // Taught a spell (no training points asked for it here): it knows it.
    enum uint bite = 97001, teachBite = 97002;
    context.data.spells.spells[bite] = testSpell(bite, 2, 6, 10);
    assert(session.canTeachPet(bite) == SpellCastResult.ok);
    session.teachPet(bite);
    assert(state.knows(bite));

    // Noted as taught by `teachBite`: the hunter learns it as the pet bites, sooner or later.
    context.data.spells.spells[teachBite] = testSpell(teachBite, 36, 5, 0);
    state.teachSpells = "97001 97002 0 0 0 0 0 0 ";
    auto me = cast(Player) rexxar.session.character;
    foreach (_; 0 .. 300)
    {
        session.petCastSpell(bite);
        if (me.knowsSpell(teachBite))
            break;
    }
    assert(me.knowsSpell(teachBite) && state.teachSpells == "0 0 0 0 0 0 0 0 ", "learned, and no longer noted");

    // The field: points to spend as their complement less one, a debt as it is.
    context.data.spells.spells[97003] = testSpell(97003, 2, 6, 10);
    context.data.spells.spells[97004] = testSpell(97004, 2, 6, 10);
    state.trainingPoints = 5;
    session.teachPet(97003);
    assert(pet.values.get!UNIT_TRAINING_POINTS == cast(uint)-6);
    state.trainingPoints = -10;
    session.teachPet(97004);
    assert(pet.values.get!UNIT_TRAINING_POINTS == 10);
}

/// A hostile creature notices a pet that comes within its aggro radius, and attacks it.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session.inWorld;
    auto map = context.map(0);
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    auto pet = session.ownPet;
    rexxar.read();

    context.data.creatureTemplates.edit(boar).detection = 20; // its aggro radius
    auto boar = context.summonCreature(map, boar, Position(-8940, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    assert(boar.ai.currentVictim == 0);
    map.objectRelocated(pet);
    assert(boar.ai.currentVictim == pet.guid, "the boar goes for the pet");
}

/**
 * Totems: one summoned stands beside its owner with the owner's level and its health; a passive one's aura reaches
 * its owner; a second of the same element replaces the first; they go when their owner dies.
 */
unittest
{
    import core.time : msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : spellDurationFormat, spellRadiusFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
        [[1u, bits(30), 0, 0]]), "SpellRadius.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 120_000, 0, 120_000]]), "SpellDuration.dbc");
    auto thrall = loggedIn(context, db, 7, "Thrall", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    thrall.read();
    addPetData(&thrall, context);
    auto session = thrall.session.inWorld;
    auto me = cast(Player) thrall.session.character;
    enum uint totemEntry = 5873, totemAura = 97400, summon = 97401;
    auto t = petTemplate(totemEntry, "Stoneskin Totem", false);
    context.data.creatureTemplates[totemEntry] = t;
    context.data.creatureFirstSpell[totemEntry] = totemAura;
    context.data.spells.spells[totemAura] = testSpell(totemAura, 35, ImplicitTarget.caster, 10);
    context.data.spells.spells.edit(totemAura).casting.applyAuraName[0] = AuraType.modResistance;
    context.data.spells.spells.edit(totemAura).casting.radiusIndex[0] = 1;
    context.data.spells.spells[summon] = testSpell(summon, 88, ImplicitTarget.caster, 5); // the earth slot
    context.data.spells.spells.edit(summon).miscValue[0] = totemEntry;
    context.data.spells.spells.edit(summon).casting.durationIndex = 1;

    session.castTriggeredAt(summon, 0);
    auto totem = cast(Creature) context.map(0).findObject(session.totems[1]);
    assert(totem !is null && totem.totemOwner == me.guid && totem.values.get!UNIT_FIELD_HEALTH == 5);
    assert(totem.values.get!UNIT_FIELD_LEVEL == me.data.level && totem.auras.find(totemAura) !is null);
    session.updateAreaAuras(1000.msecs);
    auto given = me.auras.find(totemAura);
    assert(given !is null && given.caster == totem.guid, "its aura on its owner");

    session.castTriggeredAt(summon, 0);
    assert(context.map(0).findObject(totem.guid) is null && session.totems[1] != totem.guid, "replaced");
    session.updateAreaAuras(1000.msecs);
    const second = session.totems[1];
    assert(me.auras.find(totemAura) !is null && me.auras.find(totemAura).caster == second, "the new one's");

    session.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(context.map(0).findObject(second) is null, "gone with its owner");
}

/// Untraining a pet: its taught spells go for 10 silver; done again the same day, 50.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto rexxar = loggedIn(context, db, 7, "Rexxar", Position(-8949.95f, -132.49f, 83.53f, 0), AccountLevel.player,
        raceOrc);
    rexxar.read();
    addPetData(&rexxar, context);
    auto session = rexxar.session.inWorld;
    auto map = context.map(0);
    auto beast = context.summonCreature(map, wolf, Position(-8947, -132.49f, 83.53f, 0), TempSpawnType.dead, 0, 0);
    auto tame = effectSpell(spellTameBeastDone, 55);
    session.tameCreature(&tame, beast.guid);
    auto pet = session.ownPet;
    auto state = pet.petData;
    foreach (uint id; [97501, 97502])
    {
        context.data.spells.spells[id] = testSpell(id, 2, 6, 10);
        session.teachPet(id);
    }
    auto me = cast(Player) rexxar.session.character;
    me.receive(Copper(10_000));
    const money = me.money;
    rexxar.read();
    ByteWriter w;
    w.put(pet.guid);
    rexxar.write(Opcode.CMSG_PET_UNLEARN, w.data);
    assert(!state.knows(97501) && !state.knows(97502) && me.money == money - Copper(1000), "for 10 silver");
    foreach (uint id; [97501, 97502])
        session.teachPet(id);
    rexxar.write(Opcode.CMSG_PET_UNLEARN, w.data);
    assert(me.money == money - Copper(1000) - Copper(5000), "then 50");
}
