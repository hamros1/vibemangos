/**
 * Session tests of what items and professions do (`dmangos.world.itemuse`, `dmangos.world.professions`): the
 * packets and errors the client gets, as CMaNGOS sends them.
 */
module dmangos.world.itemtests;

version (unittest):

import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.defines : inventorySlotBag0;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType;
import dmangos.world.loot : lootRow;
import dmangos.world.movement : Position;
import dmangos.world.opcodes;
import dmangos.world.packets : ClientGuid, ClientItemPos;
import dmangos.world.player : Player;
import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.spellhandlers : testSpell;
import dmangos.world.spellids : DamageClass;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.updatefields;

/// What `SMSG_CAST_RESULT` says: the reason (`ok` for success) and the number after it, if any.
private SpellCastResult castReason(const(ServerPacketRead)[] packets, out uint extra)
{
    const body_ = bodyOf(packets, Opcode.SMSG_CAST_RESULT);
    assert(body_ !is null, "a cast result");
    auto r = ByteReader(body_);
    r.read!uint;
    if (r.read!ubyte == 0)
        return SpellCastResult.ok;
    const reason = cast(SpellCastResult) r.read!ubyte;
    if (r.remaining >= 4)
        extra = r.read!uint;
    return reason;
}

/// A cast of `spell` at `targets` as the client sends it.
private ubyte[] castAt(uint spell, SpellTargets targets)
{
    ByteWriter w;
    w.put(spell);
    targets.write(w);
    return w.data.dup;
}

/// The bag and slot of the first item of `entry` in the backpack.
private ubyte backpackSlotOf(Player me, uint entry)
{
    foreach (ubyte s; 23 .. 39)
        if (const item = me.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
                return s;
    assert(false, "not in the backpack");
}

/**
 * A recipe that needs an anvil near and a hammer in the bags: refused with `REQUIRES_SPELL_FOCUS` (and the
 * focus id) away from one, with `TOTEMS` (and the tool) without the hammer, made with both.
 */
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint smith = 97501, anvilFocus = 1;
    context.data.spells.spells[smith] = testSpell(smith, 24, 1, 1); // SPELL_EFFECT_CREATE_ITEM, on the caster
    with (*context.data.spells.spells.edit(smith))
    {
        itemType[0] = itemJerky;
        casting.dmgClass = DamageClass.none;
        casting.requiresSpellFocus = anvilFocus;
        casting.totems = [itemSword, 0];
    }
    auto smithy = loggedIn(context, db, 7, "Smithy", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) smithy.session.character;
    me.spells ~= smith;
    smithy.read();
    const self = SpellTargets(TargetFlags.self, 0);
    uint extra;

    smithy.write(Opcode.CMSG_CAST_SPELL, castAt(smith, self));
    assert(castReason(smithy.read(), extra) == SpellCastResult.requiresSpellFocus && extra == anvilFocus, "no anvil");

    // An anvil 12 yards off: beyond its 10 and the caster's reach; then one 8 yards off.
    GameObjectTemplate anvil = {entry: 9101, type: GameObjectType.spellFocus, displayId: 1, name: "Anvil"};
    anvil.data[0] = anvilFocus;
    anvil.data[1] = 10;
    context.data.gameObjectTemplates[9101] = anvil;
    auto map = context.map(0);
    context.data.gameObjectSpawns ~= GameObjectSpawn(91001, 9101, 0, -8949.95f + 12, -132.49f, 83.53f);
    map.addObject(context.makeGameObject(&context.data.gameObjectSpawns[$ - 1]));
    smithy.write(Opcode.CMSG_CAST_SPELL, castAt(smith, self));
    assert(castReason(smithy.read(), extra) == SpellCastResult.requiresSpellFocus, "too far");
    context.data.gameObjectSpawns ~= GameObjectSpawn(91002, 9101, 0, -8949.95f + 8, -132.49f, 83.53f);
    map.addObject(context.makeGameObject(&context.data.gameObjectSpawns[$ - 1]));

    smithy.write(Opcode.CMSG_CAST_SPELL, castAt(smith, self));
    assert(castReason(smithy.read(), extra) == SpellCastResult.totems && extra == itemSword, "no hammer");

    smithy.session.inWorld.storeLoot(itemSword, 1, 0, false);
    smithy.read();
    const before = me.inventory.count(itemJerky);
    smithy.write(Opcode.CMSG_CAST_SPELL, castAt(smith, self));
    assert(castReason(smithy.read(), extra) == SpellCastResult.ok && me.inventory.count(itemJerky) == before + 1, "made");
    assert(me.inventory.count(itemSword) == 1, "the tool is not used up");
}

/**
 * Disenchanting: an item that cannot be is refused (`CANT_BE_DISENCHANTED`); one that can opens its
 * `disenchant_loot_template` loot, and released, what was left is in the bags and the item is gone.
 */
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint disenchant = 13262, dust = 50;
    context.data.spells.spells[disenchant] = testSpell(disenchant, 99, 0, 0); // SPELL_EFFECT_DISENCHANT
    context.data.spells.spells.edit(disenchant).casting.dmgClass = DamageClass.none;
    context.data.items.edit(itemSword).details.quality = 2;
    context.data.items.edit(itemSword).details.disenchantId = dust;
    context.data.loot.disenchant.add(dust, lootRow(itemJerky, 100, 0, 2, 2, 0)); // two "dusts"

    auto enchanter = loggedIn(context, db, 7, "Enchanter", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) enchanter.session.character;
    me.spells ~= disenchant;
    enchanter.session.inWorld.storeLoot(itemSword, 1, 0, false);
    enchanter.session.inWorld.storeLoot(itemShirt, 1, 0, false);
    enchanter.read();
    SpellTargets at(uint entry)
    {
        SpellTargets t;
        t.mask = TargetFlags.item;
        t.item = me.inventory[inventorySlotBag0, backpackSlotOf(me, entry)].fullGuid;
        return t;
    }
    uint extra;

    enchanter.write(Opcode.CMSG_CAST_SPELL, castAt(disenchant, at(itemShirt)));
    assert(castReason(enchanter.read(), extra) == SpellCastResult.cantBeDisenchanted, "a shirt");

    const sword = at(itemSword).item;
    const jerky = me.inventory.count(itemJerky);
    enchanter.write(Opcode.CMSG_CAST_SPELL, castAt(disenchant, at(itemSword)));
    const cast_ = enchanter.read();
    assert(castReason(cast_, extra) == SpellCastResult.ok && opcodesOf(cast_).canFind(Opcode.SMSG_LOOT_RESPONSE));
    enchanter.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(sword));
    const released = enchanter.read();
    assert(me.inventory.count(itemJerky) == jerky + 2 && me.inventory.count(itemSword) == 0, "the dust kept, the sword gone");
    assert(opcodesOf(released).canFind(Opcode.SMSG_ITEM_PUSH_RESULT));
}

/**
 * A lockbox (an item with a lockpicking lock): it does not open unpicked; Pick Lock with too little skill is
 * refused (`LOW_CASTLEVEL`), with enough it unlocks it (`ITEM_DYNFLAG_UNLOCKED`) and shows its loot; picked
 * again it is `ALREADY_OPEN`. Pick Lock as spell_template has it (1804: misc 1, base points 4, dice 1, 5 points
 * a level from spellLevel 1), cast by a level 60 rogue: its lockpicking skill counts, not its level.
 */
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : lockFormat;
    import dmangos.world.inventory : itemDynFlagUnlocked;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint boxLock = 98, pickLock = 1804, lockpicking = 633;
    auto lockRow = new uint[lockFormat.length];
    lockRow[0] = boxLock;
    lockRow[1] = 2;  // a skill lock
    lockRow[9] = 1;  // lockpicking
    lockRow[17] = 50; // at 50
    context.client.locks = typeof(context.client.locks).parse(buildDbc(lockFormat, [lockRow]), "Lock.dbc");
    context.data.spells.spells[pickLock] = testSpell(pickLock, 33, 26, 5); // SPELL_EFFECT_OPEN_LOCK, locked target
    with (*context.data.spells.spells.edit(pickLock))
    {
        miscValue[0] = 1; // opens lockpicking locks
        basePoints[0] = 4;
        baseDice[0] = 1;
        casting.realPointsPerLevel[0] = 5;
        spellLevel = 1;
        casting.baseLevel = 1;
        casting.dmgClass = DamageClass.none;
    }
    context.data.items.edit(itemJerky).details.lockId = boxLock; // the "jerky" is a lockbox now
    context.data.loot.item.add(itemJerky, lootRow(itemShirt, 100, 0, 1, 1, 0));

    auto rogue = loggedIn(context, db, 7, "Rogue", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 60);
    auto me = cast(Player) rogue.session.character;
    me.spells ~= pickLock;
    rogue.session.inWorld.storeLoot(itemJerky, 1, 0, false);
    rogue.read();
    const slot = backpackSlotOf(me, itemJerky);
    auto box = me.inventory[inventorySlotBag0, slot];
    SpellTargets t;
    t.mask = TargetFlags.item;
    t.item = box.fullGuid;
    uint extra;

    rogue.write(Opcode.CMSG_OPEN_ITEM, ClientItemPos(inventorySlotBag0, slot));
    assert(opcodesOf(rogue.read()).canFind(Opcode.SMSG_INVENTORY_CHANGE_FAILURE), "locked");

    me.setSkill(lockpicking, 10, 100);
    rogue.write(Opcode.CMSG_CAST_SPELL, castAt(pickLock, t));
    assert(castReason(rogue.read(), extra) == SpellCastResult.lowCastLevel, "skill 10 against 50, at level 60");

    me.setSkill(lockpicking, 150, 300); // far above: it never resists
    rogue.write(Opcode.CMSG_CAST_SPELL, castAt(pickLock, t));
    const picked = rogue.read();
    assert(castReason(picked, extra) == SpellCastResult.ok && opcodesOf(picked).canFind(Opcode.SMSG_LOOT_RESPONSE));
    assert(box.values[ITEM_FIELD_FLAGS] & itemDynFlagUnlocked, "unlocked");
    rogue.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(box.fullGuid));
    rogue.read();
    rogue.write(Opcode.CMSG_CAST_SPELL, castAt(pickLock, t));
    assert(castReason(rogue.read(), extra) == SpellCastResult.alreadyOpen);
    // Opened like any container now.
    rogue.write(Opcode.CMSG_OPEN_ITEM, ClientItemPos(inventorySlotBag0, slot));
    assert(opcodesOf(rogue.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
}

/// `CMSG_USE_ITEM` of the item at `bag`, `slot`, at the user itself.
private ubyte[] useItem(ubyte bag, ubyte slot)
{
    ByteWriter w;
    w.put(bag);
    w.put(slot);
    w.put(ubyte(1));
    SpellTargets(TargetFlags.self).write(w);
    return w.data.dup;
}

/**
 * Item charges: one with two positive charges is used twice, then stays with none (`NO_CHARGES_REMAIN`); one
 * with a negative charge is used up a use at a time. Using an item that binds on use binds it.
 */
unittest
{
    import dmangos.world.inventory : itemDynFlagBound;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint heal = 97601, gun = 97602;
    context.data.spells.spells[heal] = testSpell(heal, 10, 1, 1); // SPELL_EFFECT_HEAL on the caster
    import dmangos.world.worlddata : ItemTemplate;

    ItemTemplate flareGun = context.data.items[itemJerky];
    flareGun.entry = gun;
    flareGun.stackable = 1;
    flareGun.bonding = 3; // binds on use
    flareGun.spellCharges[0] = 2;
    flareGun.details.spells[0].id = heal;
    flareGun.details.spells[0].trigger = 0;
    context.data.items[gun] = flareGun;
    with (*context.data.items.edit(itemJerky))
    {
        spellCharges[0] = -1;
        details.spells[0].id = heal;
        details.spells[0].trigger = 0;
    }

    auto user = loggedIn(context, db, 7, "User", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) user.session.character;
    user.session.inWorld.storeLoot(gun, 1, 0, false);
    user.session.inWorld.storeLoot(itemJerky, 3, 0, false);
    user.read();
    const gunSlot = backpackSlotOf(me, gun), jerkySlot = backpackSlotOf(me, itemJerky);
    auto item = me.inventory[inventorySlotBag0, gunSlot];
    assert(!(item.values[ITEM_FIELD_FLAGS] & itemDynFlagBound));
    uint extra;

    foreach (left; [1, 0])
    {
        now += 2.seconds;
        user.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, gunSlot));
        assert(castReason(user.read(), extra) == SpellCastResult.ok);
        assert(cast(int) item.values.get!ITEM_FIELD_SPELL_CHARGES(0) == left, "a charge a use");
    }
    assert(item.values[ITEM_FIELD_FLAGS] & itemDynFlagBound, "bound by its use");
    now += 2.seconds;
    user.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, gunSlot));
    assert(castReason(user.read(), extra) == SpellCastResult.noChargesRemain && me.inventory.count(gun) == 1,
        "kept, with no charges");

    now += 2.seconds;
    user.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, jerkySlot));
    user.read();
    assert(me.inventory.count(itemJerky) == 2, "one of the stack used up");
}

/**
 * The equip cooldown: putting on an item with an on-use spell starts its 30 seconds (`SMSG_ITEM_COOLDOWN`); it
 * cannot be used until then.
 */
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint heal = 97701;
    context.data.spells.spells[heal] = testSpell(heal, 10, 1, 1);
    with (*context.data.items.edit(itemShirt))
    {
        details.spells[0].id = heal;
        details.spells[0].trigger = 0;
    }
    auto wearer = loggedIn(context, db, 7, "Wearer", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) wearer.session.character;
    if (me.inventory.equipped(3) !is null) // the starting shirt off first
        me.inventory.destroy(inventorySlotBag0, 3);
    wearer.session.inWorld.storeLoot(itemShirt, 1, 0, false);
    wearer.read();
    const slot = backpackSlotOf(me, itemShirt);
    const guid = me.inventory[inventorySlotBag0, slot].fullGuid;
    wearer.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    const body_ = bodyOf(wearer.read(), Opcode.SMSG_ITEM_COOLDOWN);
    assert(body_ !is null, "told");
    auto r = ByteReader(body_);
    assert(r.read!ulong == guid && r.read!uint == heal);
    uint extra;
    now += 2.seconds;
    assert(me.inventory.equipped(3) !is null && me.inventory.equipped(3).entry == itemShirt, "worn");
    wearer.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, 3));
    const used = wearer.read();
    assert(castReason(used, extra) == SpellCastResult.notReady, "the equip cooldown");
    now += 29.seconds;
    wearer.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, 3));
    assert(castReason(wearer.read(), extra) == SpellCastResult.ok, "over");
}

/**
 * An item's own cooldown category (`spellcategory_N`) counts like its spell's (`Player::IsSpellReady` with the
 * item). The rows as item_template and spell_template have them: Major Healing Potion (13446: spell 17534 of
 * category 4, the item: 120000, category 4, 120000) shares its category with the Swiftness Potion (2379: spell
 * 2379 of no category, the item: 120000, category 4, 120000); the Minor Healthstone (5512: spell 6262 of category
 * 30, the item: 0, category 1153, 120000) with Fishliver Oil (1322: spell 7396 of category 4, the item: -1,
 * category 1153, 120000).
 */
unittest
{
    import dmangos.world.worlddata : ItemTemplate;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    void potion(uint entry, uint spellId, uint spellCategory, uint spellCategoryMs, int itemMs, uint itemCategory,
        int itemCategoryMs)
    {
        context.data.spells.spells[spellId] = testSpell(spellId, 10, 1, 1); // a heal on the caster stands in
        with (*context.data.spells.spells.edit(spellId))
        {
            category = spellCategory;
            recoveryTime = 0;
            categoryRecoveryTime = spellCategoryMs;
        }
        ItemTemplate t = context.data.items[itemJerky];
        t.entry = entry;
        t.stackable = 5;
        t.spellCharges[0] = -1;
        t.spellCategory[0] = itemCategory;
        t.details.spells[0].id = spellId;
        t.details.spells[0].trigger = 0;
        t.details.spells[0].cooldown = itemMs;
        t.details.spells[0].categoryCooldown = itemCategoryMs;
        context.data.items[entry] = t;
    }
    potion(13446, 17534, 4, 10_000, 120_000, 4, 120_000);  // Major Healing Potion
    potion(2459, 2379, 0, 0, 120_000, 4, 120_000);          // Swiftness Potion
    potion(5512, 6262, 30, 0, 0, 1153, 120_000);            // Minor Healthstone
    potion(1322, 7396, 4, 0, -1, 1153, 120_000);            // Fishliver Oil

    auto user = loggedIn(context, db, 7, "Drinker", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) user.session.character;
    foreach (entry; [13446, 2459, 5512, 1322])
        user.session.inWorld.storeLoot(entry, 2, 0, false);
    user.read();
    uint extra;
    SpellCastResult use(uint entry)
    {
        now += 2.seconds;
        user.write(Opcode.CMSG_USE_ITEM, useItem(inventorySlotBag0, backpackSlotOf(me, entry)));
        return castReason(user.read(), extra);
    }
    assert(use(13446) == SpellCastResult.ok);
    assert(use(2459) == SpellCastResult.notReady, "the Swiftness Potion waits on the healing potion's category 4");
    assert(use(5512) == SpellCastResult.ok);
    assert(use(1322) == SpellCastResult.notReady, "Fishliver Oil waits on the healthstone's category 1153");
    assert(use(5512) == SpellCastResult.notReady, "and the healthstone on its own item category");
    now += 120.seconds;
    assert(use(2459) == SpellCastResult.ok && use(1322) == SpellCastResult.ok, "over");
}

/// A timed item: the client is told its time (`SMSG_ITEM_TIME_UPDATE`); it counts down by the second, and goes at 0.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.items.edit(itemSword).duration = 3;
    auto carrier = loggedIn(context, db, 7, "Carrier", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) carrier.session.character;
    carrier.session.inWorld.storeLoot(itemSword, 1, 0, false);
    carrier.read();
    auto sword = me.inventory[inventorySlotBag0, backpackSlotOf(me, itemSword)];
    void tick()
    {
        now += 1000.msecs;
        carrier.session.update(1000.msecs);
    }
    tick();
    const told = bodyOf(carrier.read(), Opcode.SMSG_ITEM_TIME_UPDATE);
    assert(told !is null && ByteReader(told[8 .. $]).read!uint == 3, "told its 3 seconds as it came");
    tick();
    assert(sword.values[ITEM_FIELD_DURATION] == 1 && me.inventory.count(itemSword) == 1);
    tick();
    assert(me.inventory.count(itemSword) == 0, "gone");
}
