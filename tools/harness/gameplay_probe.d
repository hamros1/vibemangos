// Opt-in 1.12.1 comparisons. See docs/research/GAMEPLAY-FIDELITY.md.
module dmangos.world.gameplay_probe;

version (unittest):

import std.format : format;
import std.stdio : stderr;
import dmangos.bytes : ByteWriter, ByteReader;
import dmangos.world.auras : AuraTick, Aura, noSlot;
import dmangos.world.combat : AttackType, HitInfo, MeleeHitOutcome, calculateMeleeDamage;
import dmangos.world.creature : Creature;
import dmangos.world.defines : nullBag, nullSlot, Power, inventorySlotBag0;
import dmangos.world.inventory : InventoryResult, ItemPosCount;
import dmangos.world.movement : Position;
import dmangos.world.objects : makeGuid, HighGuid;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ClientStandStateChange, ClientSwapInvItem;
import dmangos.world.player : Copper;
import dmangos.world.realspelltests : RealWorld, haveRealData;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.unit : Blow, dealDamage;
import dmangos.world.updatefields;

unittest
{
    assert(haveRealData(), "requires the extracted client and world database");
    uint differences;
    void compare(bool matches, string rule, string observation)
    {
        stderr.writefln("gameplay-audit %s  %s  %s", matches ? "PASS" : "DIFF", rule, observation);
        differences += !matches;
    }

    // Independent priests cast the same periodic effect at a single shared target.
    {
        auto w = RealWorld.make();
        auto first = w.character(61000, "Witness", 5, 60, []);
        auto target = w.enemy(first);
        auto mob = cast(Creature) w.context.map(0).findObject(target);
        foreach (i; 0 .. 20)
        {
            auto priest = w.character(61100 + i, "Priest" ~ cast(char)('a' + i), 5, 60, [589u]);
            priest.session.inWorld.player.movement.position.orientation = 0;
            w.castAt(priest, 589, target);
            if (mob.auras.list.length >= 17)
                break;
        }
        size_t visible;
        foreach (aura; mob.auras.list)
            if (aura.spell.id == 589 && aura.slot != noSlot)
                ++visible;
        auto existing = mob.auras.list[0];
        assert(existing.spell.id == 589);
        import dmangos.world.auras : makeAura;
        auto refresh = makeAura(existing.spell, existing.caster, 60, 18_000, false, existing.amount);
        bool added;
        assert(mob.receiveAura(refresh, w.context.map(0), added) is existing && !added);
        AuraTick[] ticks;
        Aura[] expired, heartbeats;
        mob.auras.update(3000, ticks, expired, heartbeats);
        size_t ticking;
        foreach (tick; ticks)
            if (tick.aura.spell.id == 589)
                ++ticking;
        assert(visible == 16, "control: filled all 16 visible debuff slots");
        compare(ticking <= 16, "active raid debuff cap", format!"%s visible, %s due to tick"(visible, ticking));
        // Fear must be able to push off ordinary periodic damage at capacity.
        auto fear = makeAura(w.context.data.spells.spell(5782), 61500, 60, 10_000, false, [0, 0, 0]);
        assert(mob.receiveAura(fear, w.context.map(0), added) is fear && added);
        assert(mob.auras.list.length == 16 && mob.auras.find(5782) is fear);
        import dmangos.world.spellareas : admitGroundDamage;
        auto ground = w.context.data.spells.spell(10); // Blizzard rank 1
        auto unit = w.context.map(0).unit(target);
        // A peer DoT can be displaced, but the visible crowd control remains.
        assert(admitGroundDamage(unit, ground, 61501, 60, 1000));
        auto hidden = mob.auras.find(10, 61501);
        assert(hidden !is null && hidden.slot == noSlot && mob.auras.list.length == 16);
        assert(admitGroundDamage(unit, ground, 61501, 60, 500) && hidden.duration == 500);
        auto sunder = makeAura(w.context.data.spells.spell(7386), 61502, 60, 30_000, false, [-90, 0, 0]);
        assert(mob.receiveAura(sunder, w.context.map(0), added) is sunder && mob.auras.find(5782) is fear);
        assert(mob.auras.list.length == 16, "a free icon is not a free debuff slot");
        compare(true, "debuff refresh, displacement and hidden slot", "Fear displaced damage, Blizzard counted with no icon");
    }

    // A relog restores disposition and keeps the target's debuff slots occupied.
    {
        import dmangos.world.auras : makeAura;

        auto w = RealWorld.make();
        auto target = w.character(61001, "Sleeper", 1, 60, []).session.inWorld;
        auto pain = w.context.data.spells.spell(589);
        foreach (caster; 1u .. 17u)
            assert(target.addAura(makeAura(pain, caster, 60, 18_000, false, [7, 0, 0])));
        target.saveAuras();
        foreach (aura; target.player.auras.list.dup)
            if (aura.spell.id == 589)
                target.removeAura(aura);
        target.loadAuras();
        uint restored;
        foreach (aura; target.player.auras.list)
            if (aura.spell.id == 589 && !aura.positive && aura.slot >= 32 && aura.slot < 48)
                ++restored;
        compare(restored == 16, "debuffs persist across relog", format!"%s harmful effects restored"(restored));
    }

    // Generate an actual sitting crit from a creature's attack table and deliver it as a melee hit.
    {
        auto w = RealWorld.make();
        auto warrior = w.character(61200, "Sitter", 1, 60, []);
        auto me = warrior.session.inWorld;
        me.applyPassive(w.context.data.spells.spell(12317)); // Enrage rank 1
        me.applyPassive(w.context.data.spells.spell(16487)); // Blood Craze rank 1
        auto attacker = w.context.map(0).unit(w.enemy(warrior));
        warrior.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
        assert(!me.player.fighter.standing && me.player.auras.find(12880) is null);
        auto hit = calculateMeleeDamage(attacker.fighter, me.player.fighter, AttackType.mainHand, w.context.map(0).random);
        assert(hit.outcome == MeleeHitOutcome.crit && hit.damage);
        dealDamage(attacker, me.unit, hit.damage, Blow.swing(hit));
        compare(me.player.auras.find(12880) is null, "sitting crit does not trigger Enrage",
            format!"Enrage active=%s"(me.player.auras.find(12880) !is null));
        assert(me.player.auras.find(16488) is null, "sitting Blood Craze");
        auto paladin = w.character(61201, "Reckoner", 2, 60, []);
        auto pal = paladin.session.inWorld;
        pal.applyPassive(w.context.data.spells.spell(20182)); // rank 5, guaranteed on an eligible crit
        paladin.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(1));
        dealDamage(attacker, pal.unit, hit.damage, Blow.swing(hit));
        assert(pal.extraAttacks == 0, "sitting Reckoning");
        dealDamage(attacker, pal.unit, hit.damage, Blow.swing(hit));
        assert(pal.extraAttacks == 1, "standing Reckoning control");
    }

    // Matched swings: same weapons, level, target and random seed; only the Heroic Strike queue changes.
    uint[2] misses;
    foreach (mode; 0 .. 2)
    {
        auto w = RealWorld.make();
        auto warrior = w.character(61300, "Striker", 1, 60, [78u]);
        auto me = warrior.session.inWorld;
        auto player = me.player;
        player.dualWield = true;
        player.setSkill(43, 300, 300);
        foreach (hand; [ubyte(15), ubyte(16)])
        {
            me.storeLoot(2131, 1, 0, false);
            foreach (ubyte slot; 23 .. 39)
                if (const item = player.inventory[inventorySlotBag0, slot])
                    if (item.entry == 2131)
                    {
                        warrior.write(Opcode.CMSG_SWAP_INV_ITEM, ClientSwapInvItem(slot, hand));
                        break;
                    }
        }
        assert(player.fighter.dualWield, "control: two equipped weapons");
        auto target = w.enemy(warrior, 10946);
        auto mob = cast(Creature) w.context.map(0).findObject(target);
        player.movement.position.orientation = 0;
        player.values.set!UNIT_FIELD_POWER1(Power.rage, 1000u);
        if (mode)
            assert(w.castAt(warrior, 78, target) == SpellCastResult.ok);
        warrior.read();
        w.context.map(0).random.seed(77001);
        foreach (_; 0 .. 1000)
        {
            mob.values.set!UNIT_FIELD_HEALTH(mob.values.get!UNIT_FIELD_MAXHEALTH);
            me.swing(mob, AttackType.offHand);
            auto reader = ByteReader(bodyOf(warrior.read(), Opcode.SMSG_ATTACKERSTATEUPDATE));
            if (reader.read!uint & HitInfo.miss)
                ++misses[mode];
        }
    }
    compare(misses[0] > misses[1] + 100, "queued Heroic Strike removes off-hand miss penalty",
        format!"ordinary %s/1000, queued %s/1000"(misses[0], misses[1]));

    // Two world contexts share the character database as two realm nodes would.
    {
        auto db = newDatabase();
        auto first = newCreationContext(db);
        auto second = newCreationContext(db);
        foreach (copy; 1u .. 6u)
            first.enteredInstance(70, copy);
        assert(!first.instanceLimitReached(70, 1), "control: re-enter one of the five");
        assert(first.instanceLimitReached(70, 6), "control: sixth copy denied locally");
        const blocked = second.instanceLimitReached(70, 6);
        compare(blocked, "five instances per hour across realm nodes",
            format!"sixth blocked on first=true, second=%s"(blocked));
    }

    foreach (sameAccount; [false, true])
    {
        auto db = newDatabase();
        auto world = newCreationContext(db);
        auto sender = loggedIn(world, db, 7, "Anduin", Position(-8941, -140, 83));
        // The recipient only needs an offline character record, including its real account relationship.
        auto alt = db.loadable[7];
        alt.name = "Jaina";
        alt.guid = 8;
        if (!sameAccount)
            ++alt.account;
        db.loadable[8] = alt;
        auto player = sender.session.inWorld.player;
        ItemPosCount[] dest;
        assert(player.inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 1) == InventoryResult.ok);
        auto jerky = player.inventory.storeNew(dest, itemJerky);
        player.receive(Copper(100));
        ByteWriter msg;
        msg.put(makeGuid(HighGuid.gameObject, 32349, 26880));
        msg.putCString("Jaina");
        msg.putCString("Delivery");
        msg.putCString("");
        msg.put(41u);
        msg.put(0u);
        msg.put(jerky.fullGuid);
        msg.put(0u);
        msg.put(0u);
        msg.put(0UL);
        msg.put(ubyte(0));
        const sent = world.unixTime;
        sender.write(Opcode.CMSG_SEND_MAIL, msg.data);
        const mail = db.loadMail(8);
        assert(mail.length == 1 && mail[0].itemGuid);
        const delay = mail[0].deliverTime - sent;
        compare(delay >= 3600 && delay <= 3601, sameAccount ? "item mail to alt" : "item mail to another account",
            format!"%s seconds"(delay));
    }

    // Use two independent MariaDB connections against a disposable copy of the realm table.
    {
        import core.sync.barrier : Barrier;
        import core.thread : Thread;
        import std.array : split;
        import std.process : environment;
        import dmangos.mysql : ConnectionInfo, MySqlConnection;
        import dmangos.world.database : MySqlWorldDatabase;

        const library = environment["DMANGOS_REAL_DATA"].split("|")[1];
        const info = ConnectionInfo.parse(environment["DMANGOS_AUDIT_CHARACTERS"]);
        bool enter(uint instance, long now, Barrier gate = null)
        {
            auto connection = new MySqlConnection(info, library);
            scope (exit) connection.close();
            if (gate !is null)
                gate.wait();
            return new MySqlWorldDatabase(connection, connection, connection).admitInstance(1, instance, now);
        }
        foreach (copy; 1u .. 5u)
            assert(enter(copy, 1000));
        bool[2] admitted;
        auto gate = new Barrier(2);
        auto a = new Thread({ admitted[0] = enter(5, 1000, gate); });
        auto b = new Thread({ admitted[1] = enter(6, 1000, gate); });
        a.start();
        b.start();
        a.join();
        b.join();
        assert(admitted[0] != admitted[1], "only one connection claims the last slot");
        assert(enter(1, 4500) && !enter(7, 4599) && enter(7, 4600), "reconnect, re-entry and exact expiry");
        compare(true, "shared SQL dungeon history", "one fifth admission, reconnect and hourly expiry verified");
    }

    assert(!differences, "gameplay differs from the documented 1.12 rules above");
}

/// Measure Auto Shot through the normal cast, movement and character update paths.
unittest
{
    import core.time : msecs;
    import dmangos.world.defines : PlayerClass;

    enum uint shot = 75, bow = 2504, arrow = 2512;
    enum ubyte raceDwarf = 3;
    enum uint stepMs = 10;

    struct ShotTiming
    {
        uint firstShotMs;
        uint nextShotDelayMs;
    }

    // Movement times are relative to the first shot. A zero stop time is the stationary control.
    ShotTiming measure(uint moveAt, uint stopAt)
    {
        auto world = RealWorld.make();
        auto hunter = world.character(61600, "Tracker", PlayerClass.hunter, 60, [shot], raceDwarf);
        auto character = hunter.session.inWorld;
        auto player = character.player;
        player.setSkill(45, 300, 300); // bows
        equipRanged(hunter, bow);
        character.storeLoot(arrow, 20, 0, false);
        hunter.write(Opcode.CMSG_SET_AMMO, ClientSetAmmo(arrow));
        assert(player.values.get!PLAYER_AMMO_ID == arrow);
        const guid = world.enemy(hunter);
        auto target = cast(Creature) world.context.map(0).findObject(guid);
        target.movement.position.x += 16;
        target.values.set!UNIT_FIELD_MAXHEALTH(10000u);
        target.values.set!UNIT_FIELD_HEALTH(10000u);
        auto position = player.position;
        position.orientation = 0;

        uint clientTime;
        sendMovement(hunter, Opcode.MSG_MOVE_HEARTBEAT, MovementFlags.none, position, clientTime);
        hunter.write(Opcode.CMSG_SET_SELECTION, ClientSetSelection(guid));
        assert(world.castAt(hunter, shot, guid) == SpellCastResult.ok);

        // Each actual shot spends one arrow, whether it hits or misses.
        uint advance(uint limitMs, bool allowShot)
        {
            const before = player.inventory.count(arrow);
            foreach (step; 1 .. limitMs / stepMs + 1)
            {
                clientTime += stepMs;
                world.now += stepMs.msecs;
                character.update(stepMs.msecs);
                hunter.read();
                if (player.inventory.count(arrow) < before)
                {
                    assert(allowShot && player.inventory.count(arrow) == before - 1);
                    return step * stepMs;
                }
            }
            assert(!allowShot, "expected a shot within the measurement window");
            return limitMs;
        }

        const first = advance(1000, true);
        if (!stopAt)
            return ShotTiming(first, advance(5000, true));

        assert(moveAt < stopAt);
        advance(moveAt, false);
        sendMovement(hunter, Opcode.MSG_MOVE_START_FORWARD, MovementFlags.forward, position, clientTime);
        advance(stopAt - moveAt, false);
        position.x += 1;
        sendMovement(hunter, Opcode.MSG_MOVE_STOP, MovementFlags.none, position, clientTime);
        return ShotTiming(first, advance(5000, true));
    }

    const stationary = measure(0, 0);
    stderr.writefln("auto-shot stationary control: first shot at %s ms, subsequent interval %s ms",
        stationary.firstShotMs, stationary.nextShotDelayMs);
    assert(stationary.firstShotMs == 510 && stationary.nextShotDelayMs == 2300);
    const earlyStop = measure(300, 800);
    assert(earlyStop.nextShotDelayMs == 1500, "stop before the weapon is due preserves the stationary schedule");

    foreach (moveAt; [300u, stationary.nextShotDelayMs - 300])
        foreach (offset; [100u, 350u, 600u])
        {
            const stopAt = stationary.nextShotDelayMs + offset;
            const sample = measure(moveAt, stopAt);
            assert(sample.firstShotMs == stationary.firstShotMs, "identical stationary lead-in");
            enum uint retryMs = 500, windUpMs = 500;
            const expected = retryMs - offset % retryMs + windUpMs;
            stderr.writefln("auto-shot movement starts %s ms after shot, ends %s ms after stationary due time:"
                ~ " next shot %s ms after stop", moveAt, offset, sample.nextShotDelayMs);
            assert(sample.nextShotDelayMs == expected,
                format!"stop %s ms after due: expected %s ms, got %s ms"(offset, expected, sample.nextShotDelayMs));
        }
}

/// The real wand spell cancels as soon as the player moves and requires a new cast after stopping.
unittest
{
    import core.time : msecs;
    import dmangos.world.defines : PlayerClass;

    enum uint shoot = 5019, wand = 11287;
    auto world = RealWorld.make();
    auto mage = world.character(61601, "Wanduser", PlayerClass.mage, 60, [shoot]);
    auto character = mage.session.inWorld;
    character.player.setSkill(228, 300, 300); // wands
    equipRanged(mage, wand);
    const guid = world.enemy(mage);
    auto target = cast(Creature) world.context.map(0).findObject(guid);
    target.movement.position.x += 16;
    target.values.set!UNIT_FIELD_HEALTH(5000u);
    auto position = character.player.position;
    position.orientation = 0;
    sendMovement(mage, Opcode.MSG_MOVE_HEARTBEAT, MovementFlags.none, position, 0);
    mage.write(Opcode.CMSG_SET_SELECTION, ClientSetSelection(guid));
    assert(world.castAt(mage, shoot, guid) == SpellCastResult.ok);
    mage.read();

    ushort[] tick(uint ms)
    {
        world.now += ms.msecs;
        character.update(ms.msecs);
        return opcodesOf(mage.read());
    }

    tick(10);
    assert(tick(500).canFind(Opcode.SMSG_SPELL_GO), "stationary wand control fires");
    sendMovement(mage, Opcode.MSG_MOVE_START_FORWARD, MovementFlags.forward, position, 510);
    assert(tick(10).canFind(Opcode.SMSG_CANCEL_AUTO_REPEAT));
    sendMovement(mage, Opcode.MSG_MOVE_STOP, MovementFlags.none, position, 520);
    assert(!tick(3000).canFind(Opcode.SMSG_SPELL_GO), "stopping alone does not resume the wand");
    assert(world.castAt(mage, shoot, guid) == SpellCastResult.ok);
    mage.read();
    tick(10);
    assert(tick(3000).canFind(Opcode.SMSG_SPELL_GO), "a fresh wand cast fires");
    stderr.writeln("auto-shot wand control: movement cancelled Shoot, which restarted on a fresh cast");
}

private void equipRanged(ref TestClient client, uint entry)
{
    import dmangos.world.defines : equipmentSlotRanged;

    auto character = client.session.inWorld;
    auto player = character.player;
    character.storeLoot(entry, 1, 0, false);
    foreach (ubyte slot; 23 .. 39)
        if (const item = player.inventory[inventorySlotBag0, slot])
            if (item.entry == entry)
            {
                client.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
                break;
            }
    const equipped = player.inventory.equipped(equipmentSlotRanged);
    assert(equipped !is null && equipped.entry == entry);
}

private void sendMovement(ref TestClient client, uint opcode, MovementFlags flags, Position position, uint time)
{
    ByteWriter msg;
    MovementInfo(flags, time, position).write(msg);
    client.write(opcode, msg.data);
    assert(client.session.inWorld.player.movement.flags == flags, "movement packet accepted");
}
