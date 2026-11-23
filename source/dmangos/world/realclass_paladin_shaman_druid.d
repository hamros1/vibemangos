/**
 * The paladin's, the shaman's and the druid's spells and talents (docs/spells/paladin.md, shaman.md, druid.md) tested
 * on the real data (`dmangos.world.realspelltests`): each test asserts what the 1.12.1 tooltip says the spell does
 * (its numbers, from the spell's own data), for every rank where the ranks differ in more than their numbers. Most
 * talents are spell modifiers; the table-driven tests below check each one's claim on the spells it names, by what a
 * cast observes (a cost, a cooldown, a cast time, a duration, an aura's amount).
 */
module dmangos.world.realclass_paladin_shaman_druid;

version (unittest):

import core.time : Duration, msecs, seconds;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.bytes : ByteReader;
import dmangos.world.auras : Aura, AuraType, makeAura;
import dmangos.world.combat : AttackType, MeleeDamage, MeleeHitOutcome;
import dmangos.world.creature : Creature;
import dmangos.world.defines : PlayerClass, Power;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : SpellCastResult;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient;
import dmangos.world.unit : Blow, dealDamage, UnitRef;
import dmangos.world.updatefields;

private enum ubyte raceHuman = 1, raceOrc = 2, raceDwarf = 3, raceNightElf = 4, raceTauren = 6, raceTroll = 8;

// ---------------------------------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------------------------------

/// The spell logs of `opcode` (damage, heal, energize: a target, a caster, the spell, then its amount) since the last
/// read: the spell and the number after it.
private uint[2][] spellLogs(ref TestClient who, ushort opcode)
{
    uint[2][] logs;
    foreach (p; who.read())
        if (p.opcode == opcode)
        {
            auto r = ByteReader(p.body_);
            r.readPackedGuid();
            r.readPackedGuid();
            const spell = r.read!uint;
            logs ~= [spell, r.read!uint];
        }
    return logs;
}

/// Time passes: for the character and its map.
private void pass(ref RealWorld w, ref TestClient who, Duration elapsed)
{
    w.now += elapsed;
    who.session.inWorld.update(elapsed);
    w.context.map(0).update(elapsed);
}

/// The creature of `guid` on the map.
private Creature creatureOf(ref RealWorld w, ulong guid)
{
    return cast(Creature) w.context.map(0).findObject(guid);
}

/// The real spell `id`.
private const(SpellInfo)* spellOf(ref RealWorld w, uint id)
{
    const s = w.context.data.spells.spell(id);
    assert(s !is null, format!"no spell %s"(id));
    return s;
}

/// `who`'s talent (or other passive spell) `id`: known and its auras on.
private void learnPassive(ref RealWorld w, ref TestClient who, uint id)
{
    auto me = who.session.inWorld;
    if (!me.player.knowsSpell(id))
        me.player.spells ~= id;
    me.applyPassive(spellOf(w, id));
    me.refreshEquipBoundPassives(); // (one bound to a weapon or a shield: if worn; to forms: in them)
    me.refreshFormBoundPassives();
    const spell = spellOf(w, id);
    if (!spell.stances && spell.equippedItemClass < 0)
        assert(me.player.auras.find(id) !is null, format!"%s's aura on"(id));
}

/// An aura of the real spell `id` on the character, as its own (`stacks` times).
private Aura giveAura(ref RealWorld w, ref TestClient who, uint id, int[3] amounts = [0, 0, 0], uint stacks = 1)
{
    auto me = who.session.inWorld;
    foreach (_; 0 .. stacks)
        me.addAura(makeAura(spellOf(w, id), me.player.guid, 60, -1, true, amounts));
    return me.player.auras.find(id);
}

/// A hostile creature of `entry` (448: Hogger) `distance` yards east of `who`, who faces it; its guid.
private ulong foe(ref RealWorld w, ref TestClient who, uint entry = 448, float distance = 2)
{
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.player : Player;

    auto me = cast(Player) who.session.character;
    me.movement.position.orientation = 0;
    auto at = me.position;
    at.x += distance;
    auto creature = w.context.summonCreature(w.context.map(0), entry, at, TempSpawnType.manual, 0, 0);
    assert(creature !is null, "no such creature in the world database");
    // Enough health to outlast any test's blows, and it does not fight back (the tests strike for it).
    creature.values.set!UNIT_FIELD_MAXHEALTH(1_000_000u);
    creature.values.set!UNIT_FIELD_HEALTH(1_000_000u);
    {
        import dmangos.world.creatureai : ReactState;

        creature.ai.react = ReactState.passive;
        creature.ai.scriptMelee(false);
        creature.ai.scriptCombatMovement(false);
    }
    who.read();
    return creature.guid;
}

/// `who` takes the item `entry` and wears it (in its own slot).
private void wear(ref TestClient who, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    auto me = who.session.inWorld;
    me.storeLoot(entry, 1, 0, false);
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
            {
                who.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, s));
                break;
            }
    who.read();
    foreach (ubyte slot; 0 .. 19)
        if (const item = me.player.inventory.equipped(slot))
            if (item.entry == entry)
                return;
    assert(false, format!"%s worn"(entry));
}

/// A Horde character in Stormwind (where `RealWorld` puts everyone): the creatures about react to it as friends (as a
/// disguise makes them), lest the guards kill it while a test's time passes.
private void guestOfStormwind(ref TestClient who)
{
    import dmangos.world.relations : ReputationRank;

    auto me = who.session.inWorld;
    foreach (c; me.currentMap.creaturesNear(me.player.position, 200))
        if (c.factionTemplate !is null)
            me.forcedReactions[c.factionTemplate.faction] = ReputationRank.friendly;
}

/// A shaman's four totems, the tools its totem spells need.
private void giveTotems(ref TestClient who)
{
    foreach (totem; [5175u, 5176, 5177, 5178])
        who.session.inWorld.storeLoot(totem, 1, 0, false);
    who.read();
}

/// A swing of the creature `attacker` at `who` landing as `outcome` for `damage`.
private void struck(ref RealWorld w, ref TestClient who, ulong attacker, MeleeHitOutcome outcome, uint damage = 10)
{
    MeleeDamage d;
    d.attacker = attacker;
    d.target = who.session.inWorld.player.guid;
    d.outcome = outcome;
    d.damage = damage;
    dealDamage(w.context.map(0).unit(attacker), who.session.inWorld.unit, damage, Blow.swing(d));
}

/// Mana and health full, past the global cooldown.
private void refresh(ref RealWorld w, ref TestClient who)
{
    auto me = who.session.inWorld;
    me.player.values.set!UNIT_FIELD_POWER1(Power.mana, me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana));
    me.player.values.set!UNIT_FIELD_HEALTH(me.player.values.get!UNIT_FIELD_MAXHEALTH);
    w.now += 2.seconds;
    who.read();
}

/// Whether `value` is `base` changed by `percent` (rounded either way).
private bool changedBy(long value, long base, int percent)
{
    const want = base * (100 + percent) / 100.0;
    return value >= want - 1 && value <= want + 1;
}

// ---------------------------------------------------------------------------------------------------------------------
// Spell modifier talents: what each changes, by rank
// ---------------------------------------------------------------------------------------------------------------------

/// What a modifier talent's test observes of the spell it changes.
private enum Observed
{
    cost,       /// its mana (rage, energy) cost: `percent` or `flat`
    cooldown,   /// its cooldown after a cast, in ms
    duration,   /// its aura's duration, in ms
    castTime,   /// its cast time, in ms
    critChance, /// its crit chance, in percent
    pushback,   /// its chance not to lose casting time when hurt, in percent
    range,      /// its range, in yards
    amount,     /// its aura's amount (effect `effect`): `percent` or `flat`
    damage,     /// what its damage (or healing) is made of 1000
}

/// A talent's claim: its rank `talent` changes `spell`'s `observed` by `flat`, or by `percent`.
private struct ModClaim
{
    string name;
    uint talent;
    uint spell;
    Observed observed;
    int flat;
    int percent;
    ubyte classId;
    ubyte race;
    size_t effect;
}

/// What `who` observes of `c.spell` now.
private long observe(ref RealWorld w, ref TestClient who, const ref ModClaim c)
{
    import dmangos.world.spellcast : range;
    import dmangos.world.spellmods : SpellModOp;

    auto me = who.session.inWorld;
    const spell = spellOf(w, c.spell);
    final switch (c.observed)
    {
    case Observed.cost:
        return me.costOf(*spell);
    case Observed.critChance:
        return cast(long)(me.critChanceOf(spell, UnitRef.init) * 100) / 100;
    case Observed.damage:
        return me.spellMod(SpellModOp.damage, spell, 1000);
    case Observed.pushback:
        return me.spellMod(SpellModOp.notLoseCastingTime, spell, 100) - 100;
    case Observed.range:
        return cast(long) me.spellMod(SpellModOp.range, spell, range(*spell, w.context.client)[1]);
    case Observed.duration:
        import dmangos.world.spellcast : duration;

        return me.modDuration(spell, duration(*spell, w.context.client, me.player.data.level));
    case Observed.castTime:
        import dmangos.world.spellcast : castTime;

        return me.spellMod(SpellModOp.castingTime, spell, castTime(*spell, w.context.client, me.player.data.level));
    case Observed.cooldown:
        w.now += 3600.seconds;
        refresh(w, who);
        foreach (aura; me.player.auras.list.dup) // (Forbearance)
            if (!aura.passive)
                me.removeAura(aura);
        const target = spell.implicitTargetA[0] == 6 ? foe(w, who) : me.player.guid;
        if (spell.casterAuraState == imported!"dmangos.world.aurastate".AuraState.judgement) // Judgement: a seal on
            me.castCustom(20154, me.player.guid);
        const r = target == me.player.guid ? w.cast_(who, c.spell) : w.castAt(who, c.spell, target);
        assert(r == SpellCastResult.ok, format!"%s: %s cast: %s"(c.name, c.spell, r));
        // Tenths of a second until it is ready again.
        long waited;
        while (!me.spellIsReady(c.spell) && waited < 72_000)
        {
            w.now += 100.msecs;
            ++waited;
        }
        return waited * 100;
    case Observed.amount:
        w.now += 3600.seconds;
        refresh(w, who);
        const r = w.cast_(who, c.spell);
        assert(r == SpellCastResult.ok, format!"%s: %s cast: %s"(c.name, c.spell, r));
        auto aura = me.player.auras.find(c.spell);
        assert(aura !is null, format!"%s: %s's aura"(c.name, c.spell));
        const amount = aura.amount[c.effect];
        me.removeAura(aura);
        return amount;
    }
}

/// Each claim: observed without the talent and with it.
private void checkClaims(const(ModClaim)[] claims)
{
    foreach (n, c; claims)
    {
        auto w = RealWorld.make();
        auto who = w.character(cast(uint)(200 + n), "Claim", c.classId, 60, [c.spell], c.race);
        if (c.classId == PlayerClass.shaman)
            giveTotems(who);
        if (c.race == raceOrc || c.race == raceTauren || c.race == raceTroll)
            guestOfStormwind(who);
        const base = observe(w, who, c);
        learnPassive(w, who, c.talent);
        const changed = observe(w, who, c);
        const ok = c.percent ? changedBy(changed, base, c.percent) : changed == base + c.flat;
        assert(ok, format!"%s (%s) on %s: %s -> %s, not %s%s"(c.name, c.talent, c.spell, base, changed,
            c.percent ? c.percent : c.flat, c.percent ? "%" : ""));
    }
}

/// Paladin modifier talents, every rank (the higher ranks' masks are their first's `spell_affect` row).
unittest
{
    if (!haveRealData())
        return;
    enum P = PlayerClass.paladin;
    with (Observed)
    {
        ModClaim[] claims;
        // Benediction: the mana of Judgement and of the seals, 3% a rank.
        foreach (rank, talent; [20101u, 20102, 20103, 20104, 20105])
        {
            claims ~= ModClaim("Benediction", talent, 20293, cost, 0, -3 * cast(int)(rank + 1), P, raceHuman);
            claims ~= ModClaim("Benediction", talent, 20271, cost, 0, -3 * cast(int)(rank + 1), P, raceHuman);
        }
        // Guardian's Favor: Blessing of Protection's cooldown 60 s less a rank, Blessing of Freedom 3 s longer.
        foreach (rank, talent; [20174u, 20175])
        {
            claims ~= ModClaim("Guardian's Favor", talent, 10278, cooldown, -60_000 * cast(int)(rank + 1), 0, P, raceHuman);
            claims ~= ModClaim("Guardian's Favor", talent, 1044, duration, 3000 * cast(int)(rank + 1), 0, P, raceHuman);
        }
        // Improved Hammer of Justice: 5 s less a rank.
        foreach (rank, talent; [20487u, 20488, 20489])
            claims ~= ModClaim("Improved Hammer of Justice", talent, 10308, cooldown, -5000 * cast(int)(rank + 1), 0, P, raceHuman);
        // Improved Judgement: 1 s less a rank.
        foreach (rank, talent; [25956u, 25957])
            claims ~= ModClaim("Improved Judgement", talent, 20271, cooldown,
                -1000 * cast(int)(rank + 1), 0, P, raceHuman);
        // Improved Lay on Hands: 10 min less a rank.
        foreach (rank, talent; [20234u, 20235])
            claims ~= ModClaim("Improved Lay on Hands", talent, 10310, cooldown, -600_000 * cast(int)(rank + 1), 0, P, raceHuman);
        // Healing Light, Spiritual Focus: below (a heal's amount; the pushback chance).
        foreach (rank, talent; [20205u, 20206, 20207, 20209, 20208])
            foreach (spell; [10329u, 19943])
                claims ~= ModClaim("Spiritual Focus", talent, spell, pushback, 14 * cast(int)(rank + 1), 0, P, raceHuman);
        // Improved Blessing of Might: its attack power 4% more a rank.
        foreach (rank, talent; [20042u, 20045, 20046, 20047, 20048])
            claims ~= ModClaim("Improved Blessing of Might", talent, 19838, amount, 0, 4 * cast(int)(rank + 1), P, raceHuman);
        // Improved Blessing of Wisdom: its mana 10% more a rank.
        foreach (rank, talent; [20244u, 20245])
            claims ~= ModClaim("Improved Blessing of Wisdom", talent, 19854, amount, 0, 10 * cast(int)(rank + 1), P, raceHuman);
        // Improved Concentration Aura: 5 more a rank to its 35% chance.
        foreach (rank, talent; [20254u, 20255, 20256])
            claims ~= ModClaim("Improved Concentration Aura", talent, 19746, amount, 5 * cast(int)(rank + 1), 0, P, raceHuman);
        // Improved Devotion Aura: its armor 5% more a rank.
        foreach (rank, talent; [20138u, 20139, 20140, 20141, 20142])
            claims ~= ModClaim("Improved Devotion Aura", talent, 10293, amount, 0, 5 * cast(int)(rank + 1), P, raceHuman);
        // Improved Retribution Aura: its damage 25% more a rank.
        foreach (rank, talent; [20091u, 20092])
            claims ~= ModClaim("Improved Retribution Aura", talent, 10301, amount, 0, 25 * cast(int)(rank + 1), P, raceHuman);
        // Improved Righteous Fury: its threat 16, 33, 50% more.
        foreach (rank, talent; [20468u, 20469, 20470])
            claims ~= ModClaim("Improved Righteous Fury", talent, 25780, amount, 0, [16, 33, 50][rank], P, raceHuman);
        // Improved Seal of the Crusader: its attack power 5% more a rank.
        foreach (rank, talent; [20335u, 20336, 20337])
            claims ~= ModClaim("Improved Seal of the Crusader", talent, 20308, amount, 0, 5 * cast(int)(rank + 1), P, raceHuman);
        // Lasting Judgement: Judgement of Light and of Wisdom 10 s longer a rank.
        foreach (rank, talent; [20359u, 20360, 20361])
            foreach (spell; [20346u, 20355])
                claims ~= ModClaim("Lasting Judgement", talent, spell, duration, 10_000 * cast(int)(rank + 1), 0, P, raceHuman);
        checkClaims(claims);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Paladin
// ---------------------------------------------------------------------------------------------------------------------

/// What `spell` cast at `target` (0: oneself) healed, by heal spell, once its cast time is over.
private uint[2][] healsOf(ref RealWorld w, ref TestClient who, uint spell, ulong target = 0)
{
    refresh(w, who);
    if (!target)
        who.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(1u); // (for the heal to show whole)
    const r = target ? w.castAt(who, spell, target) : w.cast_(who, spell);
    assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
    foreach (_; 0 .. 4)
        pass(w, who, 1000.msecs);
    return spellLogs(who, Opcode.SMSG_SPELLHEALLOG);
}

/// The range of effect `i` of `spell` at `level` (its die: lowest and highest).
private int[2] valueRange(ref RealWorld w, uint spell, size_t i, uint level)
{
    import dmangos.world.spellcast : effectValue;

    const s = spellOf(w, spell);
    return [effectValue(*s, i, level, 0), effectValue(*s, i, level, 0.99999f)];
}

/// Whether `amount` is in `lo .. hi` (a crit's half again included), each changed by `percent`.
private bool inRange(uint amount, long lo, long hi, int percent = 0)
{
    const a = lo * (100 + percent) / 100.0 - 1, b = hi * (100 + percent) / 100.0 + 1;
    return (amount >= a && amount <= b) || (amount >= a * 1.5 - 1 && amount <= b * 1.5 + 1);
}

/**
 * Holy Light (8 ranks) and Flash of Light (6) heal for their tooltip's numbers (Holy Light rank 8: 1246 to 1388, Flash
 * of Light rank 6: 343 to 383); Healing Light (20237, 20238, 20239) adds 4% a rank to both.
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[] holyLight = [635, 639, 647, 1026, 1042, 3472, 10328, 10329];
    static immutable uint[] flashOfLight = [19750, 19939, 19940, 19941, 19942, 19943];
    foreach (talentRank, talent; [0u, 20237, 20238, 20239])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(300, "Uther", PlayerClass.paladin, 60, holyLight ~ flashOfLight);
        if (talent)
            learnPassive(w, paladin, talent);
        const percent = 4 * cast(int) talentRank;
        foreach (spell; holyLight ~ flashOfLight)
        {
            const range = valueRange(w, spell, 0, 60);
            bool above;
            foreach (attempt; 0 .. (percent >= 12 && spell == 10329 ? 15 : 4))
                foreach (l; healsOf(w, paladin, spell))
                {
                    assert(inRange(l[1], range[0], range[1], percent), format!"%s healed %s, not %s to %s +%s%%"(spell,
                        l[1], range[0], range[1], percent));
                    above |= l[1] > range[1] + 1 && l[1] < range[0] * 3 / 2;
                }
            if (percent >= 12 && spell == 10329)
                assert(above, "more than the rank's own");
        }
    }
}

/**
 * Divine Favor (20216): the next Holy Light, Flash of Light or Holy Shock heal crits (half again), and the favor goes
 * with it. Illumination (20210 .. 20215: 20% a rank) gives back the heal's base mana cost at a crit: every one at
 * rank 5, about a fifth at rank 1.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint divineFavor = 20216, holyLight = 10329, flashOfLight = 19943, holyShock = 20930, illuminationMana = 20272;
    foreach (spell; [holyLight, flashOfLight, holyShock])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(301, "Turalyon", PlayerClass.paladin, 60, [divineFavor, spell]);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, 20215);
        refresh(w, paladin);
        assert(w.cast_(paladin, divineFavor) == SpellCastResult.ok);
        assert(me.player.auras.find(divineFavor) !is null);
        const heal = spell == holyShock ? 25903u : spell == holyLight ? 19968u : 19993u;
        const range = spell == holyShock ? valueRange(w, heal, 0, 60) : valueRange(w, spell, 0, 60);
        const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        w.now += 2.seconds;
        paladin.read();
        assert(w.cast_(paladin, spell) == SpellCastResult.ok);
        uint healed, back;
        foreach (_; 0 .. 4)
        {
            w.now += 1.seconds;
            me.update(1000.msecs);
            foreach (p; paladin.read())
            {
                if (p.opcode != Opcode.SMSG_SPELLHEALLOG && p.opcode != Opcode.SMSG_SPELLENERGIZELOG)
                    continue;
                auto r = ByteReader(p.body_);
                r.readPackedGuid();
                r.readPackedGuid();
                const id = r.read!uint;
                if (p.opcode == Opcode.SMSG_SPELLHEALLOG && id == heal)
                    healed = r.read!uint;
                else if (p.opcode == Opcode.SMSG_SPELLENERGIZELOG && id == illuminationMana)
                {
                    r.read!uint;
                    back = r.read!uint;
                }
            }
        }
        assert(healed >= range[0] * 3 / 2 - 1 && healed <= range[1] * 3 / 2 + 1,
            format!"%s: a crit: %s, not %s to %s half again"(spell, healed, range[0], range[1]));
        assert(me.player.auras.find(divineFavor) is null, "the favor spent");
        assert(back == spellOf(w, spell).casting.manaCost, format!"%s: Illumination: %s back"(spell, back));
        assert(!me.spellIsReady(divineFavor), "two minutes");
        w.now += 112.seconds;
        assert(!me.spellIsReady(divineFavor));
        w.now += 10.seconds;
        assert(me.spellIsReady(divineFavor));
        cast(void) mana;
    }
    // Illumination rank 1: a fifth of the crits.
    {
        auto w = RealWorld.make();
        auto paladin = w.character(302, "Gavinrad", PlayerClass.paladin, 60, [divineFavor, flashOfLight]);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, 20210);
        uint backs;
        enum tries = 100;
        foreach (attempt; 0 .. tries)
        {
            w.now += 200.seconds;
            refresh(w, paladin);
            assert(w.cast_(paladin, divineFavor) == SpellCastResult.ok);
            w.now += 2.seconds;
            paladin.read();
            assert(w.cast_(paladin, flashOfLight) == SpellCastResult.ok);
            foreach (_; 0 .. 2)
            {
                w.now += 1.seconds;
                me.update(1000.msecs);
            }
            backs += spellLogs(paladin, Opcode.SMSG_SPELLENERGIZELOG).canFind!(l => l[0] == illuminationMana);
        }
        assert(backs >= 5 && backs <= 40, format!"rank 1: 20%%: %s of %s"(backs, tries));
    }
}

/// The damage logs of `spell` that `who` saw since the last read.
private uint[] damageOf(ref TestClient who, uint spell)
{
    uint[] got;
    foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
        if (l[0] == spell)
            got ~= l[1];
    return got;
}

/// Holy Shock (20473, 20929, 20930) at an enemy: its rank's holy damage (25912, 25911, 25902); at a friend: its heal
/// (25914, 25913, 25903), each of the tooltip's range.
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[3][] ranks = [[20473, 25912, 25914], [20929, 25911, 25913], [20930, 25902, 25903]];
    foreach (row; ranks)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(310, "Tyr", PlayerClass.paladin, 60, [row[0]]);
        auto friend = w.character(311, "Alexandros", PlayerClass.paladin, 60, []);
        const hurt = valueRange(w, row[1], 0, 60), heal = valueRange(w, row[2], 0, 60);
        const hogger = foe(w, paladin);
        refresh(w, paladin);
        assert(w.castAt(paladin, row[0], hogger) == SpellCastResult.ok);
        const dealt = damageOf(paladin, row[1]);
        // (a miss or a resist deals none; a crit half again)
        assert(dealt.length == 0 || dealt.length == 1 && (dealt[0] == 0 || inRange(dealt[0], hurt[0], hurt[1])),
            format!"%s: %s, not %s"(row[0], dealt, hurt));
        w.now += 31.seconds;
        friend.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(1u);
        refresh(w, paladin);
        assert(w.castAt(paladin, row[0], friend.session.inWorld.player.guid) == SpellCastResult.ok);
        const healed = spellLogs(paladin, Opcode.SMSG_SPELLHEALLOG);
        assert(healed.length == 1 && healed[0][0] == row[2] && inRange(healed[0][1], heal[0], heal[1]),
            format!"%s healed %s, not %s"(row[0], healed, heal));
    }
}

/// Hammer of Wrath (24275, 24274, 24239) only at an enemy at a fifth of its health or less: then its holy damage.
unittest
{
    if (!haveRealData())
        return;
    foreach (spell; [24275u, 24274, 24239])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(312, "Mograine", PlayerClass.paladin, 60, [spell]);
        const hogger = foe(w, paladin);
        auto target = creatureOf(w, hogger);
        const max = target.values.get!UNIT_FIELD_MAXHEALTH;
        refresh(w, paladin);
        target.values.set!UNIT_FIELD_HEALTH(max / 5 + 2);
        assert(w.castAt(paladin, spell, hogger) != SpellCastResult.ok, "over a fifth");
        target.values.set!UNIT_FIELD_HEALTH(max / 5 - 1); // (under a fifth: the aura state's; the tooltip says "20% or less")
        assert(w.castAt(paladin, spell, hogger) == SpellCastResult.ok, "under a fifth");
        foreach (_; 0 .. 4)
            pass(w, paladin, 500.msecs);
        const range = valueRange(w, spell, 0, 60);
        const dealt = damageOf(paladin, spell);
        assert(dealt.length == 0 || dealt.length == 1 && (dealt[0] == 0 || inRange(dealt[0], range[0], range[1])),
            format!"%s: %s, not %s"(spell, dealt, range));
    }
}

/// Judgement (20271) needs a seal on (its caster aura state), and spends it.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto paladin = w.character(313, "Saidan", PlayerClass.paladin, 60, [20271, 20293]);
    auto me = paladin.session.inWorld;
    const hogger = foe(w, paladin);
    refresh(w, paladin);
    // No seal: the client greys it out (its caster aura state, which the server keeps); cast anyway, it judges nothing.
    assert(!me.hasAuraState(imported!"dmangos.world.aurastate".AuraState.judgement));
    w.castAt(paladin, 20271, hogger);
    assert(spellLogs(paladin, Opcode.SMSG_SPELLNONMELEEDAMAGELOG).length == 0);
    w.now += 11.seconds;
    assert(w.cast_(paladin, 20293) == SpellCastResult.ok);
    w.now += 2.seconds;
    assert(me.hasAuraState(imported!"dmangos.world.aurastate".AuraState.judgement), "a seal on: its state");
    assert(w.castAt(paladin, 20271, hogger) == SpellCastResult.ok);
    assert(me.player.auras.find(20293) is null, "the seal spent");
    // Judgement of Righteousness, rank 8 (20286): the tooltip's 162 to 178.
    const range = valueRange(w, 20286, 0, 60);
    const dealt = damageOf(paladin, 20286);
    assert(dealt.length == 0 || dealt.length == 1 && (dealt[0] == 0 || inRange(dealt[0], range[0], range[1])), format!"%s"(dealt));
}

/**
 * Holy Shield (20925, 20927, 20928): 30% more block, and each block deals its holy damage (65, 95, 130) to the attacker,
 * for 20% more threat, and uses one of its 4 charges. Blessing of Sanctuary (20911 .. 20914; 25899, the greater) deals its (14, 21, 28, 35)
 * at each block, without charges.
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (spell; [20925u, 20927, 20928])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(314, "Bolvar", PlayerClass.paladin, 60, [spell]);
        auto me = paladin.session.inWorld;
        const hogger = foe(w, paladin);
        wear(paladin, 1200); // a shield (Holy Shield needs one)
        const blockBefore = me.unit.fighter.block;
        refresh(w, paladin);
        assert(w.cast_(paladin, spell) == SpellCastResult.ok);
        pass(w, paladin, 100.msecs);
        assert(me.unit.fighter.block >= blockBefore + 29.9f, format!"block %s -> %s"(blockBefore, me.unit.fighter.block));
        const damage = valueRange(w, spell, 1, 60)[0];
        assert(me.player.auras.find(spell) !is null, "Holy Shield on");
        foreach (charge; 0 .. 4)
        {
            paladin.read();
            const threat = creatureOf(w, hogger).ai.threatOf(me.player.guid);
            struck(w, paladin, hogger, MeleeHitOutcome.block);
            const dealt = damageOf(paladin, spell);
            const more = creatureOf(w, hogger).ai.threatOf(me.player.guid) - threat;
            assert(more > damage * 1.2f - 0.5f && more < damage * 1.2f + 0.5f, format!"20%% more threat: %s for %s"(more, damage));
            assert(dealt == [damage], format!"%s: block %s: %s, not %s (aura %s, charges %s, health %s)"(spell, charge, dealt, damage, me.player.auras.find(spell) ? me.player.auras.find(spell).amount : [-1,-1,-1], me.player.auras.find(spell) ? me.player.auras.find(spell).charges : 99, creatureOf(w, hogger).values.get!UNIT_FIELD_HEALTH));
        }
        assert(me.player.auras.find(spell) is null, "four charges");
    }
    foreach (spell; [20911u, 20912, 20913, 20914, 25899])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(315, "Danath", PlayerClass.paladin, 60, [spell]);
        auto me = paladin.session.inWorld;
        const hogger = foe(w, paladin);
        refresh(w, paladin);
        me.storeLoot(21177, 5, 0, false); // Symbol of Kings, the greater blessing's reagent
        const r = w.castAt(paladin, spell, me.player.guid);
        assert(me.player.auras.find(spell) !is null, format!"%s: %s"(spell, r));
        const damage = valueRange(w, spell, 1, 60)[0];
        foreach (_; 0 .. 5)
        {
            paladin.read();
            struck(w, paladin, hogger, MeleeHitOutcome.block);
            assert(damageOf(paladin, spell) == [damage], format!"%s"(spell));
        }
        paladin.read();
        struck(w, paladin, hogger, MeleeHitOutcome.normal);
        assert(damageOf(paladin, spell).length == 0, "only a block");
        assert(me.unit.fighter.damageTakenFlat[0] == valueRange(w, spell, 0, 60)[0], "its damage taken less");
    }
}

/**
 * Blessing of Light (19977, 19978, 19979; 25890, the greater) adds to Holy Light's and Flash of Light's heals on its
 * bearer its amounts as healing power: by the heal's share of it (Blizzard's coefficient: Holy Light 0.714, Flash of
 * Light 0.429).
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (blessing; [19977u, 19978, 19979, 25890])
        foreach (k, spell; [10329u, 19943])
        {
            auto w = RealWorld.make();
            auto paladin = w.character(316, "Lothar", PlayerClass.paladin, 60, [spell, blessing]);
            auto me = paladin.session.inWorld;
            refresh(w, paladin);
            me.storeLoot(21177, 5, 0, false); // Symbol of Kings
            w.castAt(paladin, blessing, me.player.guid);
            assert(me.player.auras.find(blessing) !is null, format!"%s on"(blessing));
            import dmangos.world.spellcast : bonusCoefficient;
            const heal = k == 0 ? 19968u : 19993u;
            const bonus = cast(int)(valueRange(w, blessing, k, 60)[0] * bonusCoefficient(*spellOf(w, heal), 0, w.context.client, 60));
            const range = valueRange(w, spell, 0, 60);
            foreach (attempt; 0 .. 5)
                foreach (l; healsOf(w, paladin, spell))
                    assert(inRange(l[1], range[0] + bonus, range[1] + bonus), format!"%s with %s: %s, not %s+%s"(spell,
                        blessing, l[1], range, bonus));
        }
}

/// `who` swings at the creature `target` until `done` (at most `swings` times); whether it was.
private bool swingUntil(ref RealWorld w, ref TestClient who, ulong target, scope bool delegate() done, uint swings = 200)
{
    auto me = who.session.inWorld;
    foreach (_; 0 .. swings)
    {
        auto creature = creatureOf(w, target);
        creature.values.set!UNIT_FIELD_HEALTH(creature.values.get!UNIT_FIELD_MAXHEALTH);
        me.player.values.set!UNIT_FIELD_HEALTH(me.player.values.get!UNIT_FIELD_MAXHEALTH);
        me.swing(creature, AttackType.mainHand);
        if (done())
            return true;
        w.now += 4.seconds;
    }
    return false;
}

/**
 * Reckoning (20177, 20179, 20181, 20180, 20182: 20% a rank) gives an extra attack after a crit taken; Redoubt (20127,
 * 20130, 20135, 20136, 20137) 6% more block a rank for 10 seconds or 5 blocks; Vengeance (20049, 20056 .. 20059) 3%
 * more physical and holy damage a rank for 8 seconds after a crit dealt. Each at its rank's chance.
 */
unittest
{
    if (!haveRealData())
        return;
    // Reckoning: a crit taken, the rank's chance of an extra attack.
    foreach (rank, talent; [20177u, 20179, 20181, 20180, 20182])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(320, "Arthas", PlayerClass.paladin, 60, []);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, talent);
        const hogger = foe(w, paladin);
        uint extra;
        enum tries = 100;
        foreach (_; 0 .. tries)
        {
            me.extraAttacks = 0;
            refresh(w, paladin);
            struck(w, paladin, hogger, MeleeHitOutcome.crit);
            extra += me.extraAttacks;
            paladin.read();
        }
        const want = 20 * (rank + 1);
        assert(extra >= want - 20 && extra <= want + 20, format!"Reckoning %s: %s of %s"(talent, extra, tries));
        // A plain hit: none.
        me.extraAttacks = 0;
        struck(w, paladin, hogger, MeleeHitOutcome.normal);
        assert(me.extraAttacks == 0, "only a crit");
    }
    // Redoubt: the block aura of the rank, 5 blocks.
    static immutable uint[2][] redoubt = [[20127, 20128], [20130, 20131], [20135, 20132], [20136, 20133], [20137, 20134]];
    foreach (rank, row; redoubt)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(321, "Kel'Thuzad", PlayerClass.paladin, 60, []);
        auto me = paladin.session.inWorld;
        wear(paladin, 1200); // a shield: Redoubt's
        learnPassive(w, paladin, row[0]);
        const hogger = foe(w, paladin);
        const before = me.unit.fighter.block;
        struck(w, paladin, hogger, MeleeHitOutcome.normal);
        assert(me.player.auras.find(row[1]) is null, "only a crit");
        struck(w, paladin, hogger, MeleeHitOutcome.crit);
        auto aura = me.player.auras.find(row[1]);
        assert(aura !is null && aura.duration <= 10_000 && aura.charges == 5, format!"Redoubt %s"(row[0]));
        pass(w, paladin, 100.msecs);
        assert(me.unit.fighter.block >= before + 6 * (rank + 1) - 0.01f, format!"block %s -> %s"(before, me.unit.fighter.block));
        foreach (_; 0 .. 5)
            struck(w, paladin, hogger, MeleeHitOutcome.block);
        assert(me.player.auras.find(row[1]) is null, "5 blocks");
    }
    // Vengeance: after a crit dealt.
    static immutable uint[2][] vengeance = [[20049, 20050], [20056, 20052], [20057, 20053], [20058, 20054], [20059, 20055]];
    foreach (rank, row; vengeance)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(322, "Dathrohan", PlayerClass.paladin, 60, []);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, row[0]);
        const hogger = foe(w, paladin);
        const physical = me.unit.fighter.damageDone[0];
        assert(swingUntil(w, paladin, hogger, () => me.player.auras.find(row[1]) !is null), "a crit, at last");
        auto aura = me.player.auras.find(row[1]);
        assert(aura.amount[0] == 3 * (rank + 1) && aura.amount[1] == 3 * (rank + 1) && aura.duration <= 8000);
        pass(w, paladin, 100.msecs);
        assert(me.unit.fighter.damageDone[0] > physical * (1 + 0.03f * (rank + 1)) - 0.01f, "physical damage more");
    }
}

/// Eye for an Eye (9799, 25988): a spell's crit against the paladin deals 15%, 30% of it back to its caster as holy
/// damage (25997), but never more than half the paladin's health.
unittest
{
    if (!haveRealData())
        return;
    foreach (rank, talent; [9799u, 25988])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(323, "Ashbringer", PlayerClass.paladin, 60, []);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, talent);
        const hogger = foe(w, paladin);
        auto caster = w.context.map(0).unit(hogger);
        refresh(w, paladin);
        uint[] back;
        foreach (attempt; 0 .. 10) // (its holy strike may miss)
        {
            refresh(w, paladin);
            dealDamage(caster, me.unit, 400, Blow.spell(2, true));
            back = damageOf(paladin, 25997);
            if (back.length)
                break;
        }
        assert(back.length == 1 && (back[0] == 400 * 15 * (rank + 1) / 100 || back[0] == 400 * 15 * (rank + 1) / 100 * 3 / 2), format!"Eye for an Eye %s: %s"(talent, back));
        dealDamage(caster, me.unit, 400, Blow.spell(2, false));
        assert(damageOf(paladin, 25997).length == 0, "only a crit");
        // (Never more than half the paladin's health: a crit for more than its health would kill it first.)
    }
}

/// Pursuit of Justice (26022, 26023): 4% faster a rank, mounted too.
unittest
{
    import dmangos.world.movement : MoveType;
    import dmangos.world.moveorders : speedRate;

    if (!haveRealData())
        return;
    foreach (rank, talent; [26022u, 26023])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(325, "Fordring", PlayerClass.paladin, 60, []);
        auto me = paladin.session.inWorld;
        learnPassive(w, paladin, talent);
        const want = 1 + 0.04f * (rank + 1);
        const run = speedRate(MoveType.run, me.player.auras, false);
        assert(run > want - 0.001f && run < want + 0.001f, format!"%s: %s"(talent, run));
    }
}

/**
 * Seal of Righteousness (20154, 21084, 20287 .. 20293): each swing's holy damage is the seal's amount by the weapon's
 * speed in hundredths (its tooltip: rank 8's "20.5 to 71.4", 1786 / 87 to 1786 / 25), with a one-handed mace (2.6) and
 * a two-handed mace (3.6) alike; Improved Seal of Righteousness (20224, 20225, 20330, 20331, 20332) adds 3% a rank to it
 * and to Judgement of Righteousness.
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] ranks = [[20154, 25742], [21084, 25741], [20287, 25740], [20288, 25739], [20289, 25738],
        [20290, 25737], [20291, 25736], [20292, 25735], [20293, 25713]];
    foreach (talentRank, talent; [0u, 20224, 20225, 20330, 20331, 20332])
        foreach (weapon; [5757u, 5815])
            foreach (row; talent && talentRank < 5 ? ranks[$ - 1 .. $] : ranks)
            {
                auto w = RealWorld.make();
                auto paladin = w.character(330, "Uther", PlayerClass.paladin, 60, [row[0], 20271]);
                auto me = paladin.session.inWorld;
                wear(paladin, weapon);
                if (talent)
                    learnPassive(w, paladin, talent);
                const percent = 3 * cast(int) talentRank;
                refresh(w, paladin);
                assert(w.cast_(paladin, row[0]) == SpellCastResult.ok);
                const amount = me.player.auras.find(row[0]).amount[0];
                const speed = weapon == 5757 ? 2.6f : 3.6f;
                const want = cast(uint)(amount * speed / 100 * (100 + percent) / 100);
                const hogger = foe(w, paladin);
                uint[] got;
                swingUntil(w, paladin, hogger, () { got ~= damageOf(paladin, row[1]); return got.length > 0; });
                assert(got.length && (got[0] == want || got[0] == want * 3 / 2 || got[0] == 0),
                    format!"%s, %s, +%s%%: %s, not %s"(row[0], weapon, percent, got, want));
                // Judgement of Righteousness: its rank's, the talent's more.
                const judged = me.player.auras.find(row[0]).spell.simpleValue(2);
                if (judged > 1)
                {
                    w.now += 11.seconds;
                    paladin.read();
                    assert(w.castAt(paladin, 20271, hogger) == SpellCastResult.ok);
                    const range = valueRange(w, cast(uint) judged, 0, 60);
                    const dealt = damageOf(paladin, cast(uint) judged);
                    assert(dealt.length == 0 || dealt[0] == 0 || inRange(dealt[0], range[0], range[1], percent),
                        format!"%s +%s%%: %s, not %s"(judged, percent, dealt, range));
                }
            }
}

/**
 * Seal of Command (20375, 20915 .. 20920): its holy strike (20424) deals 70% of the weapon's damage, about 7 times a
 * minute (with a 3.6 weapon, two swings in five).
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (seal; [20375u, 20915, 20918, 20919, 20920])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(331, "Mograine", PlayerClass.paladin, 60, [seal]);
        auto me = paladin.session.inWorld;
        wear(paladin, 5815);
        const hogger = foe(w, paladin);
        uint swings, procs;
        foreach (_; 0 .. 100)
        {
            if (me.player.auras.find(seal) is null)
            {
                refresh(w, paladin);
                assert(w.cast_(paladin, seal) == SpellCastResult.ok);
            }
            paladin.read();
            auto creature = creatureOf(w, hogger);
            creature.values.set!UNIT_FIELD_HEALTH(creature.values.get!UNIT_FIELD_MAXHEALTH);
            me.swing(creature, AttackType.mainHand);
            ++swings;
            const lo = me.player.values.get!UNIT_FIELD_MINDAMAGE * 0.7f, hi = me.player.values.get!UNIT_FIELD_MAXDAMAGE * 0.7f;
            foreach (d; damageOf(paladin, 20424))
            {
                ++procs;
                assert(d == 0 || (d >= lo - 1 && d <= hi + 1) || (d >= lo * 2 - 2 && d <= hi * 2 + 2),
                    format!"%s: %s, not 70%% of %s to %s"(seal, d, lo / 0.7f, hi / 0.7f));
            }
            w.now += 4.seconds;
        }
        assert(procs >= 15 && procs <= 70, format!"%s: %s procs in %s swings, not 42%%"(seal, procs, swings));
    }
}

/**
 * Seal of Justice (20164): a swing's chance to stun (20170, 2 seconds); its judgement (20184) keeps the target from
 * fleeing for 10 seconds. Seal of Light (20165, 20347 .. 20349): a swing's chance to heal the paladin (20167, 20333,
 * 20334, 20340); its judgement (20185, 20344 .. 20346) heals who strikes the target (20267, 20341 .. 20343). Seal of
 * Wisdom (20166, 20356, 20357): a swing's chance of mana (20168, 20350, 20351); its judgement (20186, 20354, 20355) gives
 * mana to who strikes the target (20268, 20352, 20353).
 */
unittest
{
    if (!haveRealData())
        return;
    // seal, its swing's spell, its judgement, the judgement's spell
    static immutable uint[4][] seals = [[20164, 20170, 20184, 0], [20165, 20167, 20185, 20267], [20347, 20333, 20344, 20341],
        [20348, 20334, 20345, 20342], [20349, 20340, 20346, 20343], [20166, 20168, 20186, 20268],
        [20356, 20350, 20354, 20352], [20357, 20351, 20355, 20353]];
    foreach (row; seals)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(332, "Kyle", PlayerClass.paladin, 60, [row[0], 20271]);
        auto me = paladin.session.inWorld;
        wear(paladin, 5815);
        const hogger = foe(w, paladin);
        bool seen;
        uint amount;
        foreach (_; 0 .. 100)
        {
            if (me.player.auras.find(row[0]) is null)
            {
                refresh(w, paladin);
                assert(w.cast_(paladin, row[0]) == SpellCastResult.ok);
            }
            me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 100u);
            paladin.read();
            auto creature = creatureOf(w, hogger);
            creature.values.set!UNIT_FIELD_HEALTH(creature.values.get!UNIT_FIELD_MAXHEALTH);
            me.player.values.set!UNIT_FIELD_HEALTH(100u);
            me.swing(creature, AttackType.mainHand);
            if (row[1] == 20170)
                seen = creature.auras.find(20170) !is null;
            else
                foreach (l; spellLogs(paladin, row[1] == 20167 || row[1] == 20333 || row[1] == 20334 || row[1] == 20340
                        ? Opcode.SMSG_SPELLHEALLOG : Opcode.SMSG_SPELLENERGIZELOG))
                    if (l[0] == row[1])
                    {
                        seen = true;
                        amount = l[1];
                    }
            if (seen)
                break;
            w.now += 4.seconds;
        }
        assert(seen, format!"%s: %s on a swing"(row[0], row[1]));
        if (row[1] != 20170)
        {
            const heal = spellOf(w, row[1]).effect[0] == 10; // a heal; else mana (its amount after the power type)
            const want = valueRange(w, row[1], 0, 60)[0];
            assert(heal ? inRange(amount, want, want) : true, format!"%s: %s, not %s"(row[1], amount, want));
        }
        // Its judgement.
        if (me.player.auras.find(row[0]) is null)
        {
            refresh(w, paladin);
            assert(w.cast_(paladin, row[0]) == SpellCastResult.ok);
        }
        w.now += 11.seconds;
        paladin.read();
        assert(w.castAt(paladin, 20271, hogger) == SpellCastResult.ok);
        auto judged = creatureOf(w, hogger).auras.find(row[2]);
        assert(judged !is null && judged.duration <= 10_000, format!"%s judged"(row[2]));
        if (row[3])
        {
            bool back;
            foreach (_; 0 .. 60)
            {
                me.player.values.set!UNIT_FIELD_HEALTH(100u);
                me.player.values.set!UNIT_FIELD_POWER1(Power.mana, 100u);
                paladin.read();
                auto creature = creatureOf(w, hogger);
                creature.values.set!UNIT_FIELD_HEALTH(creature.values.get!UNIT_FIELD_MAXHEALTH);
                me.swing(creature, AttackType.mainHand);
                foreach (p; paladin.read())
                    if (p.opcode == Opcode.SMSG_SPELLHEALLOG || p.opcode == Opcode.SMSG_SPELLENERGIZELOG)
                    {
                        auto r = ByteReader(p.body_);
                        r.readPackedGuid();
                        r.readPackedGuid();
                        back |= r.read!uint == row[3];
                    }
                if (back)
                    break;
                w.now += 4.seconds;
            }
            assert(back, format!"%s: the striker's %s"(row[2], row[3]));
        }
    }
}

/**
 * Seal of the Crusader (21082, 20162, 20305 .. 20308): its melee attack power and 40% quicker swings (each less by as
 * much); its judgement (21183, 20188, 20300 .. 20303) more holy damage taken by its amount (rank 6: 140), 5% more a rank
 * of Improved Seal of the Crusader (20335, 20336, 20337: its attack power too, above).
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] seals = [[21082, 21183], [20162, 20188], [20305, 20300], [20306, 20301], [20307, 20302],
        [20308, 20303]];
    foreach (talentRank, talent; [0u, 20335, 20336, 20337])
        foreach (row; talent ? seals[$ - 1 .. $] : seals)
        {
            auto w = RealWorld.make();
            auto paladin = w.character(333, "Crusader", PlayerClass.paladin, 60, [row[0], 20271]);
            auto me = paladin.session.inWorld;
            wear(paladin, 5815);
            if (talent)
                learnPassive(w, paladin, talent);
            const speed = me.player.stats.attackTime[0];
            const power = me.player.stats.attackPower;
            refresh(w, paladin);
            assert(w.cast_(paladin, row[0]) == SpellCastResult.ok);
            pass(w, paladin, 100.msecs);
            const seal = me.player.auras.find(row[0]);
            assert(changedBy(me.player.stats.attackPower - power, valueRange(w, row[0], 0, 60)[0], 5 * cast(int) talentRank),
                format!"%s: attack power %s -> %s"(row[0], power, me.player.stats.attackPower));
            assert(me.player.stats.attackTime[0] < speed / 1.4f + 2 && me.player.stats.attackTime[0] > speed / 1.4f - 2,
                format!"40%% quicker: %s -> %s"(speed, me.player.stats.attackTime[0]));
            cast(void) seal;
            const hogger = foe(w, paladin);
            w.now += 11.seconds;
            assert(w.castAt(paladin, 20271, hogger) == SpellCastResult.ok);
            auto judged = creatureOf(w, hogger).auras.find(row[1]);
            assert(judged !is null, format!"%s judged"(row[1]));
            const want = valueRange(w, row[1], 0, 60)[0];
            assert(changedBy(judged.amount[0], want, 5 * cast(int) talentRank), format!"%s: %s, not %s +%s%%"(row[1],
                judged.amount[0], want, 5 * talentRank));
        }
}

/// Vindication (9452, 26016, 26021): a swing's chance to take 5% of the target's strength and agility a rank for 10
/// seconds (67, 26017, 26018).
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] ranks = [[9452, 67], [26016, 26017], [26021, 26018]];
    foreach (rank, row; ranks)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(334, "Vindicator", PlayerClass.paladin, 60, []);
        learnPassive(w, paladin, row[0]);
        wear(paladin, 5815);
        const hogger = foe(w, paladin);
        assert(swingUntil(w, paladin, hogger, () => creatureOf(w, hogger).auras.find(row[1]) !is null), "at last");
        auto debuff = creatureOf(w, hogger).auras.find(row[1]);
        const want = -5 * cast(int)(rank + 1);
        assert(debuff.amount[0] == want && debuff.amount[1] == want && debuff.duration <= 10_000,
            format!"%s: %s"(row[1], debuff.amount));
    }
}

/// Improved Lay on Hands (20234, 20235): Lay on Hands (10310) gives its target 15%, 30% more armor from items for 2
/// minutes (20233, 20236).
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] ranks = [[20234, 20233], [20235, 20236]];
    foreach (rank, row; ranks)
    {
        auto w = RealWorld.make();
        auto paladin = w.character(335, "Lightbringer", PlayerClass.paladin, 60, [10310]);
        auto me = paladin.session.inWorld;
        wear(paladin, 15824); // a robe of 76 armor
        learnPassive(w, paladin, row[0]);
        pass(w, paladin, 100.msecs);
        const armor = me.unit.fighter.armor;
        refresh(w, paladin);
        me.player.values.set!UNIT_FIELD_HEALTH(100u);
        assert(w.cast_(paladin, 10310) == SpellCastResult.ok);
        auto aura = me.player.auras.find(row[1]);
        assert(aura !is null && aura.duration <= 120_000 && aura.duration > 110_000, format!"%s on"(row[1]));
        pass(w, paladin, 100.msecs);
        assert(me.unit.fighter.armor >= armor + 76 * 15 * (rank + 1) / 100 - 1,
            format!"%s: armor %s -> %s"(row[1], armor, me.unit.fighter.armor));
    }
}

/// Turn Undead (2878, 5627, 10326): an undead flees for 10, 15, 20 seconds, till damage ends it; another creature does not.
unittest
{
    if (!haveRealData())
        return;
    foreach (spell; [2878u, 5627, 10326])
    {
        auto w = RealWorld.make();
        auto paladin = w.character(336, "Exorcist", PlayerClass.paladin, 60, [spell]);
        const zombie = foe(w, paladin, 623); // a Skeletal Miner
        Aura turned;
        foreach (attempt; 0 .. 5) // (a spell may miss)
        {
            w.now += 31.seconds;
            refresh(w, paladin);
            assert(w.castAt(paladin, spell, zombie) == SpellCastResult.ok);
            pass(w, paladin, 2000.msecs);
            turned = creatureOf(w, zombie).auras.find(spell);
            if (turned !is null)
                break;
        }
        assert(turned !is null, format!"%s: fleeing"(spell));
        assert(turned.duration <= valueDuration(w, spell));
        // "Damage caused may interrupt the effect": its `ProcChance` (100%) at the first blow.
        dealDamage(paladin.session.inWorld.unit, w.context.map(0).unit(zombie), 1, Blow.spell(1));
        assert(creatureOf(w, zombie).auras.find(spell) is null, "damage ends it");
        // Not at a creature that is not undead.
        w.now += 31.seconds;
        const hogger = foe(w, paladin);
        refresh(w, paladin);
        w.castAt(paladin, spell, hogger);
        pass(w, paladin, 2000.msecs);
        assert(creatureOf(w, hogger).auras.find(spell) is null, "only an undead");
    }
}

/// The milliseconds `spell`'s aura lasts at level 60.
private int valueDuration(ref RealWorld w, uint spell)
{
    import dmangos.world.spellcast : duration;

    return duration(*spellOf(w, spell), w.context.client, 60);
}

// ---------------------------------------------------------------------------------------------------------------------
// Talents of the data alone (stats, chances): what each rank adds, observed
// ---------------------------------------------------------------------------------------------------------------------

/// A passive talent's claim: its ranks each add `perRank` (flat, or percent of the value without it) to `observe`.
private struct StatClaim
{
    string name;
    uint[] ranks;
    float perRank;
    bool percent;
    float delegate(imported!"dmangos.world.character".Character) observe;
    uint[] worn;    /// what to wear first
    uint[] known;   /// spells to know first (Parry)
    ubyte classId;
    ubyte race;
}

private void checkStatClaims(StatClaim[] claims)
{
    foreach (c; claims)
        foreach (rank, talent; c.ranks)
        {
            auto w = RealWorld.make();
            auto who = w.character(340, "Talented", c.classId, 60, c.known, c.race);
            auto me = who.session.inWorld;
            me.player.refreshChances(w.context.data);
            foreach (item; c.worn)
                wear(who, item);
            pass(w, who, 100.msecs);
            const base = c.observe(me);
            learnPassive(w, who, talent);
            pass(w, who, 100.msecs);
            const now = c.observe(me);
            const want = c.percent ? base * (1 + c.perRank * (rank + 1) / 100) : base + c.perRank * (rank + 1);
            const slack = c.percent ? 1.0f : 0.02f; // (whole numbers: armor, a shield's block)
            const margin = slack + (want < 0 ? -want : want) * 0.002f;
            assert(now > want - margin && now < want + margin,
                format!"%s (%s): %s -> %s, not %s"(c.name, talent, base, now, want));
        }
}

/// The paladin's.
unittest
{
    import dmangos.world.character : Character;
    import dmangos.world.defines : Stat;

    if (!haveRealData())
        return;
    enum P = PlayerClass.paladin;
    StatClaim[] claims = [
        StatClaim("Anticipation", [20096, 20097, 20098, 20099, 20100], 2, false, (Character m) => cast(float) m.unit.fighter.defenseSkill),
        StatClaim("Conviction", [20117, 20118, 20119, 20120, 20121], 1, false, (Character m) => m.unit.fighter.crit, [5815]),
        StatClaim("Deflection", [20060, 20061, 20062, 20063, 20064], 1, false, (Character m) => m.unit.fighter.parry, [], [3127]),
        StatClaim("Divine Intellect", [20257, 20258, 20259, 20260, 20261], 2, true, (Character m) => cast(float) m.player.stats.stats[Stat.intellect]),
        StatClaim("Divine Strength", [20262, 20263, 20264, 20265, 20266], 2, true, (Character m) => cast(float) m.player.stats.stats[Stat.strength]),
        StatClaim("Precision", [20189, 20192, 20193], 1, false, (Character m) => m.unit.fighter.hitBonus, [5815]),
        StatClaim("Toughness", [20143, 20144, 20145, 20146, 20147], 2, true, (Character m) => cast(float) m.unit.fighter.armor
            - m.player.stats.stats[Stat.agility] * 2, [15824]),
        StatClaim("Shield Specialization", [20148, 20149, 20150], 10, true, (Character m) => cast(float) m.unit.fighter.shieldBlock
            - (m.player.stats.stats[Stat.strength] / 20 - 1), [4129]), // the shield's own
        StatClaim("One-Handed Weapon Specialization", [20196, 20197, 20198, 20199, 20200], 2, true,
            (Character m) => m.player.damageMods.swing[0], [5757]),
        StatClaim("Two-Handed Weapon Specialization", [20111, 20112, 20113], 2, true,
            (Character m) => m.player.damageMods.swing[0], [5815]),
        StatClaim("Holy Power", [5923, 5924, 5925, 5926, 25829], 1, false,
            (Character m) => m.critChanceOf(m.context.data.spells.spell(10329), UnitRef.init)),
        StatClaim("Unyielding Faith", [9453, 25836], 5, false, (Character m) => m.player.damageMods.mechanicResist[5]),
    ];
    foreach (ref c; claims)
    {
        c.classId = P;
        c.race = raceHuman;
    }
    checkStatClaims(claims);
}

/**
 * The paladin's other talents that are spells: Blessing of Kings (20217) 10% more of every stat; Sanctity Aura (20218)
 * 10% more holy damage; Repentance (20066) only at a humanoid.
 */
unittest
{
    import dmangos.world.defines : Stat;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto paladin = w.character(341, "Kingly", PlayerClass.paladin, 60, [20217, 20218, 20066]);
    auto me = paladin.session.inWorld;
    const stats = me.player.stats.stats;
    refresh(w, paladin);
    assert(w.castAt(paladin, 20217, me.player.guid) == SpellCastResult.ok);
    pass(w, paladin, 100.msecs);
    foreach (stat; 0 .. 5)
        assert(changedBy(cast(long) me.player.stats.stats[stat], cast(long) stats[stat], 10), format!"stat %s: %s -> %s"(stat, stats[stat],
            me.player.stats.stats[stat]));
    const holy = me.player.damageMods.school[1];
    refresh(w, paladin);
    assert(w.cast_(paladin, 20218) == SpellCastResult.ok);
    pass(w, paladin, 100.msecs);
    assert(me.player.damageMods.school[1] > holy * 1.1f - 0.001f && me.player.damageMods.school[1] < holy * 1.1f + 0.001f);
    refresh(w, paladin);
    const zombie = foe(w, paladin, 623);
    assert(w.castAt(paladin, 20066, zombie) == SpellCastResult.badTargets, "not an undead");
    const hogger = foe(w, paladin);
    assert(w.castAt(paladin, 20066, hogger) == SpellCastResult.ok, "a humanoid");
}

// ---------------------------------------------------------------------------------------------------------------------
// Shaman
// ---------------------------------------------------------------------------------------------------------------------

/// Shaman modifier talents, every rank.
unittest
{
    if (!haveRealData())
        return;
    enum S = PlayerClass.shaman;
    enum ubyte R = raceOrc;
    enum uint lightningBolt = 15208, chainLightning = 10605, earthShock = 10414, flameShock = 10448, frostShock = 10473,
        healingWave = 10396, lesserHealingWave = 10468, chainHeal = 10623;
    static immutable uint[] shocks = [earthShock, flameShock, frostShock];
    static immutable uint[] lightning = [lightningBolt, chainLightning];
    static immutable uint[] heals = [healingWave, lesserHealingWave, chainHeal];
    // A few of each kind: a talent's ranks share a mask. Totemic Focus: the data's mask leaves out Stoneclaw, Searing and
    // Magma Totem (5730, 10438, 10587), which its tooltip does not say: the data wins.
    static immutable uint[] totems = [2484, 8177, 10408, 10463, 10497, 10442, 10627, 11315, 16387, 10614, 6495];
    with (Observed)
    {
        ModClaim[] claims;
        foreach (rank, talent; [16041u, 16117, 16118, 16119, 16120])
            foreach (spell; lightning)
                claims ~= ModClaim("Call of Thunder", talent, spell, critChance, [1, 2, 3, 4, 6][rank], 0, S, R);
        foreach (rank, talent; [16039u, 16109, 16110, 16111, 16112])
            foreach (spell; lightning ~ shocks)
                claims ~= ModClaim("Convection", talent, spell, cost, 0, -2 * cast(int)(rank + 1), S, R);
        foreach (rank, talent; [16035u, 16105, 16106, 16107, 16108])
            foreach (spell; lightning ~ shocks)
                claims ~= ModClaim("Concussion", talent, spell, damage, 0, cast(int)(rank + 1), S, R);
        foreach (rank, talent; [16578u, 16579, 16580, 16581, 16582])
            foreach (spell; lightning)
                claims ~= ModClaim("Lightning Mastery", talent, spell, castTime, -200 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16040u, 16113, 16114, 16115, 16116])
            foreach (spell; shocks)
                claims ~= ModClaim("Reverberation", talent, spell, cooldown, -200 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [28999u, 29000])
            foreach (spell; lightning)
                claims ~= ModClaim("Storm Reach", talent, spell, range, 3 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16179u, 16214, 16215, 16216, 16217])
            foreach (spell; heals)
                claims ~= ModClaim("Tidal Focus", talent, spell, cost, 0, -cast(int)(rank + 1), S, R);
        foreach (rank, talent; [16194u, 16218, 16219, 16220, 16221])
            foreach (spell; heals ~ lightning)
                claims ~= ModClaim("Tidal Mastery", talent, spell, critChance, cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16173u, 16222, 16223, 16224, 16225])
            foreach (spell; totems)
                claims ~= ModClaim("Totemic Focus", talent, spell, cost, 0, -5 * cast(int)(rank + 1), S, R);
        foreach (rank, talent; [16181u, 16230, 16232, 16233, 16234])
            foreach (spell; heals)
                claims ~= ModClaim("Healing Focus", talent, spell, pushback, 14 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16262u, 16287])
            claims ~= ModClaim("Improved Ghost Wolf", talent, 2645, castTime, -1000 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16182u, 16226, 16227, 16228, 16229])
            claims ~= ModClaim("Improved Healing Wave", talent, healingWave, castTime, -100 * cast(int)(rank + 1), 0, S, R);
        foreach (rank, talent; [16258u, 16293])
            claims ~= ModClaim("Guardian Totems", talent, 8177, cooldown, -1000 * cast(int)(rank + 1), 0, S, R);
        checkClaims(claims);
    }
}

/// A shaman (an orc) at level 60 knowing `spells`, its totems in its bags.
private TestClient shaman(ref RealWorld w, uint guid, const(uint)[] spells, ubyte race = raceOrc)
{
    auto who = w.character(guid, "Thrall", PlayerClass.shaman, 60, spells, race);
    giveTotems(who);
    guestOfStormwind(who);
    return who;
}

/**
 * Healing Wave (10396), Lesser Healing Wave (10468) and Chain Heal (10623) heal for their tooltip's numbers; Purification
 * (16178, 16210 .. 16213) adds 2% a rank.
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (talentRank, talent; [0u, 16178, 16210, 16211, 16212, 16213])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 350, [10396, 10468, 10623]);
        if (talent)
            learnPassive(w, who, talent);
        const percent = 2 * cast(int) talentRank;
        foreach (spell; [10396u, 10468, 10623])
        {
            const range = valueRange(w, spell, 0, 60);
            bool above;
            foreach (attempt; 0 .. (percent >= 10 ? 15 : 4))
                foreach (l; healsOf(w, who, spell))
                {
                    assert(inRange(l[1], range[0], range[1], percent), format!"%s healed %s, not %s +%s%%"(spell, l[1], range,
                        percent));
                    above |= l[1] > range[1] + 1 && l[1] < range[0] * 3 / 2;
                }
            if (percent >= 10 && spell == 10396)
                assert(above, "more than the rank's own");
        }
    }
}

/**
 * Healing Grace (29187, 29189, 29191): 5% less threat a rank from Healing Wave's heal of a friend a creature fights.
 */
unittest
{
    if (!haveRealData())
        return;
    float ratio(uint talent)
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 351, [10396]);
        auto friend = w.character(352, "Varian", PlayerClass.warrior, 60, [], raceOrc);
        if (talent)
            learnPassive(w, who, talent);
        guestOfStormwind(friend);
        const hogger = foe(w, friend, 448, 20);
        auto creature = creatureOf(w, hogger);
        creature.ai.react = imported!"dmangos.world.creatureai".ReactState.defensive; // it fights the friend
        bool isNew; // rooted there, out of reach
        creature.auras.apply(makeAura(spellOf(w, 9853), 0, 60, 60_000, false, [0, 0, 0]), creature.values, isNew);
        // Hogger fights the friend.
        dealDamage(friend.session.inWorld.unit, w.context.map(0).unit(hogger), 1, Blow.spell(0));
        friend.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(1u);
        refresh(w, who);
        const before = creature.ai.threatOf(who.session.inWorld.player.guid);
        assert(w.castAt(who, 10396, friend.session.inWorld.player.guid) == SpellCastResult.ok);
        foreach (_; 0 .. 4)
            pass(w, who, 1000.msecs);
        const logs = spellLogs(who, Opcode.SMSG_SPELLHEALLOG);
        assert(logs.length == 1);
        const threat = creature.ai.threatOf(who.session.inWorld.player.guid) - before;
        assert(threat > 0, "the heal angers it");
        return threat / logs[0][1];
    }
    const plain = ratio(0);
    foreach (rank, talent; [29187u, 29189, 29191])
    {
        const less = ratio(talent);
        const want = plain * (1 - 0.05f * (rank + 1));
        assert(less > want - 0.01f && less < want + 0.01f, format!"Healing Grace %s: %s, not %s"(talent, less, want));
    }
}

/**
 * Concussion (16035, 16105 .. 16108): 1% more damage a rank, by Lightning Bolt (15208) itself. Elemental Mastery
 * (16166): the next fire, frost or nature damage spell crits and costs nothing, then it goes; 3 minutes' cooldown.
 * Elemental Fury (16089): that crit's bonus doubled (twice the damage, not half again).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint lightningBolt = 15208, elementalMastery = 16166, elementalFury = 16089;
    foreach (talentRank, talent; [0u, 16035, 16105, 16106, 16107, 16108])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 353, [lightningBolt]);
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, who);
        const range = valueRange(w, lightningBolt, 0, 60);
        foreach (attempt; 0 .. 6)
        {
            refresh(w, who);
            creatureOf(w, hogger).values.set!UNIT_FIELD_HEALTH(creatureOf(w, hogger).values.get!UNIT_FIELD_MAXHEALTH);
            const r = w.castAt(who, lightningBolt, hogger);
            assert(r == SpellCastResult.ok, format!"%s"(r));
            foreach (_; 0 .. 5)
                pass(w, who, 1000.msecs);
            foreach (d; damageOf(who, lightningBolt))
                assert(d == 0 || inRange(d, range[0], range[1], cast(int) talentRank), format!"%s: %s, not %s +%s%%"(talent,
                    d, range, talentRank));
        }
    }
    foreach (fury; [false, true])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 354, [lightningBolt, elementalMastery]);
        auto me = who.session.inWorld;
        if (fury)
            learnPassive(w, who, elementalFury);
        const hogger = foe(w, who);
        const range = valueRange(w, lightningBolt, 0, 60);
        uint[] dealt;
        foreach (attempt; 0 .. 5)
        {
            w.now += 200.seconds;
            refresh(w, who);
            creatureOf(w, hogger).values.set!UNIT_FIELD_HEALTH(creatureOf(w, hogger).values.get!UNIT_FIELD_MAXHEALTH);
            assert(w.cast_(who, elementalMastery) == SpellCastResult.ok);
            assert(!me.spellIsReady(elementalMastery));
            w.now += 2.seconds;
            const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
            assert(w.castAt(who, lightningBolt, hogger) == SpellCastResult.ok);
            foreach (_; 0 .. 5)
                pass(w, who, 1000.msecs);
            assert(me.player.auras.find(elementalMastery) is null, "spent");
            assert(me.player.values.get!UNIT_FIELD_POWER1(Power.mana) >= mana, "free");
            dealt ~= damageOf(who, lightningBolt);
        }
        const factor = fury ? 2.0f : 1.5f;
        foreach (d; dealt)
            assert(d == 0 || (d >= range[0] * factor - 2 && d <= range[1] * factor + 2), format!"crit %s: %s, not %s x%s"(fury,
                d, range, factor));
    }
}

/**
 * Elemental Focus (16164): a tenth of the fire, frost and nature damage spells bring Clearcasting (16246), whose
 * next one costs nothing. Nature's Swiftness (16188): the next nature spell under 10 seconds' cast is instant, and it
 * goes. Eye of the Storm (29062, 29064, 29065: 33, 66, 100%): Focused Casting (29063, 6 seconds) after a melee crit
 * taken: no casting time lost to damage. Elemental Devastation (30160, 29179, 29180): a spell's crit brings 3% melee
 * crit a rank for 10 seconds (30165, 29177, 29178).
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint lightningBolt = 15208, healingWave = 10396;
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 355, [lightningBolt]);
        auto me = who.session.inWorld;
        learnPassive(w, who, 16164);
        const hogger = foe(w, who);
        uint casts, clear;
        foreach (_; 0 .. 150)
        {
            refresh(w, who);
            creatureOf(w, hogger).values.set!UNIT_FIELD_HEALTH(creatureOf(w, hogger).values.get!UNIT_FIELD_MAXHEALTH);
            const wasClear = me.player.auras.find(16246) !is null;
            const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
            assert(w.castAt(who, lightningBolt, hogger) == SpellCastResult.ok);
            foreach (__; 0 .. 4)
                pass(w, who, 1000.msecs);
            if (wasClear)
            {
                assert(me.player.values.get!UNIT_FIELD_POWER1(Power.mana) >= mana, "Clearcasting: free");
                assert(me.player.auras.find(16246) is null || me.player.auras.find(16246).duration > 14_000, "spent");
                continue;
            }
            ++casts;
            clear += me.player.auras.find(16246) !is null;
        }
        assert(clear >= 4 && clear <= casts / 4, format!"Elemental Focus: %s of %s"(clear, casts));
    }
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 356, [healingWave, 16188]);
        auto me = who.session.inWorld;
        refresh(w, who);
        assert(w.cast_(who, 16188) == SpellCastResult.ok);
        w.now += 2.seconds;
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        who.read();
        assert(w.cast_(who, healingWave) == SpellCastResult.ok);
        assert(spellLogs(who, Opcode.SMSG_SPELLHEALLOG).length == 1, "instant");
        assert(me.player.auras.find(16188) is null, "spent");
        assert(!me.spellIsReady(16188));
    }
    foreach (rank, talent; [29062u, 29064, 29065])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 357, []);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        const hogger = foe(w, who);
        uint got;
        enum tries = 60;
        foreach (_; 0 .. tries)
        {
            if (auto a = me.player.auras.find(29063))
                me.removeAura(a);
            refresh(w, who);
            struck(w, who, hogger, MeleeHitOutcome.crit);
            got += me.player.auras.find(29063) !is null;
        }
        const want = [33, 66, 100][rank] * tries / 100;
        assert(got >= want - 15 && got <= want + 15, format!"Eye of the Storm %s: %s of %s"(talent, got, tries));
        struck(w, who, hogger, MeleeHitOutcome.crit);
        if (rank == 2)
        {
            import dmangos.world.spellmods : SpellModOp;

            assert(me.spellMod(SpellModOp.notLoseCastingTime, spellOf(w, healingWave), 100) == 200, "no time lost");
        }
    }
    static immutable uint[2][] devastation = [[30160, 30165], [29179, 29177], [29180, 29178]];
    foreach (rank, row; devastation)
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 358, [lightningBolt]);
        auto me = who.session.inWorld;
        wear(who, 5757);
        learnPassive(w, who, row[0]);
        giveAura(w, who, 23434, [100, 0, 0]); // every spell crits
        const hogger = foe(w, who);
        pass(w, who, 100.msecs);
        const crit = me.unit.fighter.crit;
        foreach (attempt; 0 .. 5)
        {
            refresh(w, who);
            assert(w.castAt(who, lightningBolt, hogger) == SpellCastResult.ok);
            foreach (_; 0 .. 4)
                pass(w, who, 1000.msecs);
            if (me.player.auras.find(row[1]) !is null)
                break;
        }
        assert(me.player.auras.find(row[1]) !is null, format!"%s after a crit"(row[1]));
        pass(w, who, 100.msecs);
        assert(me.unit.fighter.crit > crit + 3 * (rank + 1) - 0.01f, format!"melee crit %s -> %s"(crit, me.unit.fighter.crit));
    }
}

/**
 * Ancestral Healing (16176, 16235, 16240): a heal's crit gives its target 8, 16, 25% more armor for 15 seconds
 * (16177, 16236, 16237). Flurry (16256, 16281 .. 16284): a melee crit makes the next 3 swings 10% a rank quicker
 * (16257, 16277 .. 16280: rank 5's 30%).
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] ancestral = [[16176, 16177], [16235, 16236], [16240, 16237]];
    foreach (rank, row; ancestral)
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 360, [10468]);
        auto me = who.session.inWorld;
        learnPassive(w, who, row[0]);
        giveAura(w, who, 23434, [100, 0, 0]); // every spell crits
        healsOf(w, who, 10468);
        auto aura = me.player.auras.find(row[1]);
        assert(aura !is null && aura.duration <= 15_000 && aura.amount[0] == [8, 16, 25][rank], format!"%s"(row[1]));
    }
    static immutable uint[2][] flurry = [[16256, 16257], [16281, 16277], [16282, 16278], [16283, 16279], [16284, 16280]];
    foreach (rank, row; flurry)
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 361, []);
        auto me = who.session.inWorld;
        wear(who, 5757);
        learnPassive(w, who, row[0]);
        const hogger = foe(w, who);
        const speed = me.player.stats.attackTime[0];
        assert(swingUntil(w, who, hogger, () => me.player.auras.find(row[1]) !is null), "a crit at last");
        auto aura = me.player.auras.find(row[1]);
        assert(aura.charges == 3 && aura.amount[0] == [10, 15, 20, 25, 30][rank]);
        pass(w, who, 100.msecs);
        const quicker = speed / (1 + aura.amount[0] / 100.0f);
        assert(me.player.stats.attackTime[0] < quicker + 2 && me.player.stats.attackTime[0] > quicker - 2,
            format!"%s: %s -> %s"(row[1], speed, me.player.stats.attackTime[0]));
    }
}

/**
 * Lightning Shield (324, 325, 905, 945, 8134, 10431, 10432): its rank's nature damage at whoever strikes the shaman
 * (13 .. 198), 3 charges; Improved Lightning Shield (16261, 16290, 16291) 5% more a rank.
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[] ranks = [324, 325, 905, 945, 8134, 10431, 10432];
    foreach (talentRank, talent; [0u, 16261, 16290, 16291])
        foreach (spell; talent ? ranks[$ - 1 .. $] : ranks)
        {
            import dmangos.world.classspells : lightningShieldDamage, rankSpell;

            auto w = RealWorld.make();
            auto who = shaman(w, 362, [spell]);
            auto me = who.session.inWorld;
            if (talent)
                learnPassive(w, who, talent);
            const hogger = foe(w, who);
            refresh(w, who);
            assert(w.cast_(who, spell) == SpellCastResult.ok);
            const damage = rankSpell(lightningShieldDamage, spell);
            const want = valueRange(w, spell, 0, 60)[0];
            uint[] got;
            foreach (charge; 0 .. 3)
            {
                w.now += 4.seconds;
                who.read();
                struck(w, who, hogger, MeleeHitOutcome.normal);
                got ~= damageOf(who, damage);
            }
            assert(me.player.auras.find(spell) is null, "three charges");
            foreach (d; got)
                assert(d == 0 || changedBy(d, want, 5 * cast(int) talentRank) || changedBy(d, want * 3 / 2, 5 * cast(int) talentRank),
                    format!"%s +%s%%: %s, not %s"(spell, 5 * talentRank, got, want));
        }
}

/**
 * Healing Way (29206, 29205, 29202: 33, 66, 100%): Healing Wave leaves on its target 6% more from the next Healing
 * Waves, stacking to 3 (29203).
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (rank, talent; [29206u, 29205, 29202])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 363, [10396]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        uint stacked;
        enum tries = 30;
        foreach (_; 0 .. tries)
        {
            if (auto a = me.player.auras.find(29203))
                me.removeAura(a);
            healsOf(w, who, 10396);
            stacked += me.player.auras.find(29203) !is null;
        }
        const want = [33, 66, 100][rank] * tries / 100;
        assert(stacked >= want - 9 && stacked <= want + 9, format!"Healing Way %s: %s of %s"(talent, stacked, tries));
        if (rank == 2)
        {
            foreach (_; 0 .. 4)
                healsOf(w, who, 10396);
            assert(me.player.auras.find(29203).stacks == 3, "three at most");
        }
    }
}

/**
 * Stormstrike (17364): a strike with the weapon, and the target takes 20% more nature damage from the next 2 sources
 * for 12 seconds; 20 seconds' cooldown.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = shaman(w, 364, [17364, 15208]);
    auto me = who.session.inWorld;
    wear(who, 5757);
    const hogger = foe(w, who);
    refresh(w, who);
    Aura storm;
    foreach (attempt; 0 .. 20) // (a strike may miss)
    {
        w.now += 21.seconds;
        refresh(w, who);
        assert(w.castAt(who, 17364, hogger) == SpellCastResult.ok);
        storm = creatureOf(w, hogger).auras.find(17364);
        if (storm !is null)
            break;
    }
    assert(storm !is null && storm.charges == 2 && storm.amount[1] == 20 && storm.duration <= 12_000, storm is null ? "no storm" : format!"%s %s %s"(storm.charges, storm.amount, storm.duration));
    assert(!me.spellIsReady(17364));
    storm.duration = 120_000; // (its charges are what is tested here, not its 12 seconds)
    uint landed;
    foreach (bolt; 0 .. 8) // (a bolt may miss)
    {
        refresh(w, who);
        assert(w.castAt(who, 15208, hogger) == SpellCastResult.ok);
        foreach (_; 0 .. 4)
            pass(w, who, 1000.msecs);
        const logs = damageOf(who, 15208);
        landed += logs.canFind!(d => d > 0);
        assert(logs.length <= 1, format!"%s"(logs));
        if (landed == 2)
            break;
        assert(creatureOf(w, hogger).auras.find(17364) !is null, format!"one nature hit: one charge left (%s landed)"(landed));
    }
    assert(landed == 2 && creatureOf(w, hogger).auras.find(17364) is null, "two nature hits");
}

/// The equipped main hand weapon of `who`: its guid.
private ulong mainHand(ref TestClient who)
{
    return who.session.inWorld.player.inventory.equipped(15).fullGuid;
}

/// `who` imbues its main hand weapon with `spell`.
private void imbue(ref RealWorld w, ref TestClient who, uint spell)
{
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    SpellTargets targets;
    targets.mask = TargetFlags.item;
    targets.item = mainHand(who);
    refresh(w, who);
    const r = who.session.inWorld.castSpell(spellOf(w, spell), targets, false, 0);
    assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
    pass(w, who, 4000.msecs);
}

/**
 * Flametongue Weapon (8024, 8027, 8030, 16339, 16341, 16342): each hit's fire damage (10444) is its proc's amount by
 * the weapon's speed in hundredths (its tooltip: rank 6's 2498 is 32.4 to 99.9); Elemental Weapons (16266, 29079,
 * 29080) adds 5% a rank to it, 7% a rank to Rockbiter Weapon's attack power (16316: 554), and 13, 27, 40% to Windfury
 * Weapon's (16362: 333).
 */
unittest
{
    if (!haveRealData())
        return;
    static immutable uint[2][] flametongue = [[8024, 8026], [8027, 8028], [8030, 8029], [16339, 10445], [16341, 16343],
        [16342, 16344]];
    foreach (talentRank, talent; [0u, 16266, 29079, 29080])
        foreach (row; talent ? flametongue[$ - 1 .. $] : flametongue)
        {
            auto w = RealWorld.make();
            auto who = shaman(w, 365, [row[0]]);
            wear(who, 5757); // 2.6
            if (talent)
                learnPassive(w, who, talent);
            imbue(w, who, row[0]);
            const hogger = foe(w, who);
            // (the weapon's share whole, then the talent's percent)
            const want = cast(uint)(cast(int)(valueRange(w, row[1], 0, 60)[0] * 2.6f / 100) * (100 + [0, 5, 10, 15][talentRank]) / 100.0);
            uint[] got;
            uint[2][] all;
            swingUntil(w, who, hogger, () {
                auto logs = spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG);
                all ~= logs;
                foreach (l; logs)
                    if (l[0] == 10444)
                        got ~= l[1];
                return got.length > 0;
            }, 10);
            assert(got.length && (got[0] == 0 || got[0] == want || got[0] == want * 3 / 2),
                format!"%s +%s: %s, not %s (%s; enchanted %s)"(row[0], talentRank, got, want, all,
                who.session.inWorld.player.inventory.equipped(15).enchantment(1)));
        }
    foreach (talentRank, talent; [0u, 16266, 29079, 29080])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 366, [16316]);
        auto me = who.session.inWorld;
        wear(who, 5757);
        if (talent)
            learnPassive(w, who, talent);
        const power = me.player.stats.attackPower;
        imbue(w, who, 16316);
        // (its passive spell's 554 at level 54, 16.5 more a level: 653 at 60)
        const want = valueRange(w, 16313, 0, 60)[0] * (100 + [0, 7, 14, 20][talentRank]) / 100;
        assert(me.player.stats.attackPower - power >= want - 1 && me.player.stats.attackPower - power <= want + 1,
            format!"Rockbiter +%s: %s more, not %s"(talentRank, me.player.stats.attackPower - power, want));
    }
    foreach (talentRank, talent; [0u, 16266, 29079, 29080])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 367, [16362]);
        auto me = who.session.inWorld;
        wear(who, 5757);
        if (talent)
            learnPassive(w, who, talent);
        imbue(w, who, 16362);
        const hogger = foe(w, who);
        assert(swingUntil(w, who, hogger, () => me.player.auras.find(16361) !is null), "Windfury, at last");
        const want = 333 * (100 + [0, 13, 27, 40][talentRank]) / 100;
        assert(changedBy(me.player.auras.find(16361).amount[0], 333, [0, 13, 27, 40][talentRank]),
            format!"Windfury +%s: %s, not %s"(talentRank, me.player.auras.find(16361).amount[0], want));
    }
}

/// `who`'s totem of `spell` just summoned (the first of its totems).
private Creature summoned(ref RealWorld w, ref TestClient who, uint spell)
{
    auto me = who.session.inWorld;
    me.unsummonTotems();
    refresh(w, who);
    const r = w.cast_(who, spell);
    assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
    pass(w, who, 1100.msecs); // its aura given out
    auto totems = me.ownTotems();
    assert(totems.length == 1, format!"%s: a totem"(spell));
    return totems[0];
}

/**
 * The totem talents: Enhancing Totems (16259, 16295) 8, 15% more from Strength of Earth (10442) and Grace of Air
 * (10627) Totems; Guardian Totems (16258, 16293) 10% a rank more from Stoneskin (10408) and Windwall (15112);
 * Restorative Totems (16187, 16205 .. 16208) 5% a rank more from Mana Spring (10497); Earth's Grasp (16043, 16130)
 * 25% a rank more health for Stoneclaw Totem (10428); Totemic Mastery (16189): their auras reach 30 yards, not 20.
 * Call of Flame (16038, 16160, 16161): 5% a rank more damage from Searing Totem (10438).
 */
unittest
{
    if (!haveRealData())
        return;
    // talent ranks, percent a rank, totem
    static struct TotemClaim
    {
        uint[] ranks;
        int[] percents;
        uint totem;
    }
    TotemClaim[] claims = [TotemClaim([16259, 16295], [8, 15], 10442), TotemClaim([16259, 16295], [8, 15], 10627),
        TotemClaim([16258, 16293], [10, 20], 10408), TotemClaim([16258, 16293], [10, 20], 15112),
        TotemClaim([16187, 16205, 16206, 16207, 16208], [5, 10, 15, 20, 25], 10497)];
    foreach (c; claims)
    {
        int base;
        foreach (k, talent; [0u] ~ c.ranks)
        {
            auto w = RealWorld.make();
            auto who = shaman(w, 370, [c.totem]);
            auto me = who.session.inWorld;
            if (talent)
                learnPassive(w, who, talent);
            auto totem = summoned(w, who, c.totem);
            auto given = me.player.auras.find(totem.totemSpell);
            assert(given !is null, format!"%s: its aura on the shaman"(c.totem));
            if (!talent)
                base = given.amount[0];
            else
                assert(changedBy(given.amount[0], base, c.percents[k - 1]), format!"%s with %s: %s, not %s +%s%%"(c.totem,
                    talent, given.amount[0], base, c.percents[k - 1]));
        }
    }
    // Earth's Grasp: Stoneclaw Totem's health.
    foreach (rank, talent; [0u, 16043, 16130])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 371, [10428]);
        if (talent)
            learnPassive(w, who, talent);
        auto totem = summoned(w, who, 10428);
        const want = valueRange(w, 10428, 0, 60)[0] * (100 + 25 * cast(int) rank) / 100;
        assert(totem.values.get!UNIT_FIELD_MAXHEALTH == want, format!"Stoneclaw +%s: %s, not %s"(rank,
            totem.values.get!UNIT_FIELD_MAXHEALTH, want));
    }
    // Totemic Mastery: a friend 25 yards away in the party.
    foreach (mastery; [false, true])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 372, [10442]);
        auto friend = w.character(373, "Rexxar", PlayerClass.warrior, 60, [], raceOrc);
        guestOfStormwind(friend);
        auto group = w.context.groups.newGroup();
        group.addLeaderInvite(who.session.inWorld.player.guid, "Thrall");
        group.create();
        group.addMember(friend.session.inWorld.player.guid, "Rexxar");
        if (mastery)
            learnPassive(w, who, 16189);
        auto totem = summoned(w, who, 10442);
        friend.session.inWorld.player.movement.position.x = totem.position.x + 25;
        friend.session.inWorld.player.movement.position.y = totem.position.y;
        pass(w, who, 1100.msecs);
        assert((friend.session.inWorld.player.auras.find(totem.totemSpell) !is null) == mastery,
            format!"Totemic Mastery %s: at 25 yards"(mastery));
    }
    // Call of Flame: Searing Totem's attack.
    foreach (rank, talent; [0u, 16038, 16160, 16161])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 374, [10438]);
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, who, 448, 8);
        auto map = w.context.map(0);
        dealDamage(who.session.inWorld.unit, map.unit(hogger), 1, Blow.spell());
        auto totem = summoned(w, who, 10438);
        const attack = totem.totemSpell;
        const range = valueRange(w, attack, 0, 60);
        uint[] got;
        foreach (_; 0 .. 20)
        {
            pass(w, who, 1000.msecs);
            got ~= damageOf(who, attack);
        }
        assert(got.length, "it attacks");
        foreach (d; got)
            assert(d == 0 || inRange(d, range[0], range[1], 5 * cast(int) rank), format!"Call of Flame %s: %s, not %s +%s%%"(
                rank, got, range, 5 * rank));
    }
}

/// Searing Totem helps the shaman's group, leaving idle creatures and other players' fights alone.
unittest
{
    import dmangos.world.creatureai : ReactState;

    if (!haveRealData())
        return;
    enum uint searingTotem = 10438;
    auto w = RealWorld.make();
    auto who = shaman(w, 381, [searingTotem]);
    auto ally = w.character(382, "Rexxar", PlayerClass.warrior, 60, [], raceOrc);
    auto bystander = w.character(383, "Drekthar", PlayerClass.warrior, 60, [], raceOrc);
    guestOfStormwind(ally);
    guestOfStormwind(bystander);
    auto me = who.session.inWorld;
    auto group = w.context.groups.newGroup();
    group.addLeaderInvite(me.player.guid, "Thrall");
    group.create();
    group.addMember(ally.session.inWorld.player.guid, "Rexxar");

    auto map = w.context.map(0);
    auto idle = creatureOf(w, foe(w, who, 448, 6));
    auto unrelated = creatureOf(w, foe(w, who, 448, 9));
    auto engaged = creatureOf(w, foe(w, who, 448, 13));
    unrelated.ai.react = ReactState.defensive;
    dealDamage(bystander.session.inWorld.unit, map.unitOf(unrelated), 0, Blow.spell());
    auto totem = summoned(w, who, searingTotem);
    pass(w, who, 1000.msecs);
    assert(!totem.ai.castingNow, "idle creatures and unrelated fights leave the totem idle");
    assert(!me.inCombat, "the totem cannot pull a creature on the shaman");

    engaged.ai.react = ReactState.defensive;
    dealDamage(ally.session.inWorld.unit, map.unitOf(engaged), 0, Blow.spell());
    assert(engaged.ai.threatOf(ally.session.inWorld.player.guid) == 0, "no damage is required to engage");
    foreach (_; 0 .. 6)
        pass(w, who, 1000.msecs);
    assert(engaged.ai.threatOf(totem.guid) > 0, "the totem helps a party member who has drawn aggro");
    assert(idle.ai.threatList.length == 0, "the nearer idle creature is still untouched");
    assert(totem.guid !in unrelated.ai.threatList, "the nearer unrelated fight is still untouched");
}

/// Player-owned totems disappear on death. Creature-owned totems remain until their own despawn.
unittest
{
    import dmangos.script.api : ActionResult;

    if (!haveRealData())
        return;
    enum uint searingTotem = 10438;
    auto w = RealWorld.make();
    auto who = shaman(w, 384, [searingTotem]);
    auto map = w.context.map(0);
    auto playerTotem = summoned(w, who, searingTotem);
    auto creature = creatureOf(w, foe(w, who, 448, 12));
    assert(creature.ai.castFor(map, searingTotem, creature.guid, true) == ActionResult.ok);
    Creature creatureTotem;
    foreach (c; map.creaturesNear(creature.position, 5))
        if (c.totemOwner == creature.guid)
            creatureTotem = c;
    assert(creatureTotem !is null, "the creature summoned a totem");

    const playerTotemGuid = playerTotem.guid;
    who.session.inWorld.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(map.creatureAt(playerTotemGuid) is null, "the player's totem goes on death");

    creature.die(map, w.context.unixTime);
    pass(w, who, 1000.msecs);
    assert(map.creatureAt(creatureTotem.guid) is creatureTotem && creatureTotem.alive,
        "the creature's totem remains after its owner dies");
}

/**
 * Improved Reincarnation (16184, 16209): Reincarnation (21169) brings the shaman back with 10, 20% more of its health
 * and mana (its own 20%).
 */
unittest
{
    import dmangos.world.player : DeathState;

    if (!haveRealData())
        return;
    foreach (rank, talent; [0u, 16184, 16209])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 375, [20608]);
        auto me = who.session.inWorld;
        if (talent)
            learnPassive(w, who, talent);
        me.storeLoot(17030, 1, 0, false); // an Ankh
        who.read();
        me.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
        who.write(Opcode.CMSG_SELF_RES, null);
        assert(me.player.deathState == DeathState.alive, "back");
        const share = 20 + 10 * cast(int) rank;
        const health = me.player.values.get!UNIT_FIELD_HEALTH, max = me.player.values.get!UNIT_FIELD_MAXHEALTH;
        assert(health >= max * share / 100 - 1 && health <= max * share / 100 + 1, format!"%s%%: %s of %s"(share, health, max));
        const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana), maxMana = me.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana);
        assert(mana >= maxMana * share / 100 - 1 && mana <= maxMana * share / 100 + 1, format!"%s%%: %s of %s mana"(share, mana, maxMana));
    }
}

/**
 * Flametongue Totem (8227, 8249, 10526, 16387) and Windfury Totem (8512, 10613, 10614): the totem enchants the party's
 * main hand weapons (Flametongue's fire damage by the weapon's speed, as Flametongue Weapon's); Improved Weapon Totems
 * (29192, 29193): 6, 12% more of the Flametongue Totem's damage, 15, 30% more of the Windfury Totem's attack power.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = shaman(w, 376, [16387]);
    auto me = who.session.inWorld;
    wear(who, 5757);
    summoned(w, who, 16387);
    foreach (_; 0 .. 6)
        pass(w, who, 1000.msecs);
    assert(me.player.inventory.equipped(15).enchantment(1) == 1683, format!"enchanted by the totem: %s"(
        me.player.inventory.equipped(15).enchantment(1)));
}

/// Improved Weapon Totems (29192, 29193): the totems' enchantments, 6, 12% more Flametongue Totem fire damage (by the
/// weapon's speed, as the weapon's), 15, 30% more Windfury Totem attack power (10610).
unittest
{
    if (!haveRealData())
        return;
    foreach (rank, talent; [0u, 29192, 29193])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 377, [16387, 10614]);
        auto me = who.session.inWorld;
        wear(who, 5757);
        if (talent)
            learnPassive(w, who, talent);
        summoned(w, who, 16387);
        foreach (_; 0 .. 6)
            pass(w, who, 1000.msecs);
        const hogger = foe(w, who);
        const want = cast(uint)(cast(int)(valueRange(w, 16389, 0, 60)[0] * 2.6f / 100) * (100 + 6 * cast(int) rank) / 100.0);
        uint[] got;
        swingUntil(w, who, hogger, () {
            foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
                if (l[0] == 16368)
                    got ~= l[1];
            return got.length > 0;
        }, 20);
        assert(got.length && (got[0] == 0 || got[0] == want || got[0] == want * 3 / 2),
            format!"Flametongue Totem +%s: %s, not %s"(rank, got, want));
        // Give the previous totem's weapon enchantment time to wear off before testing Windfury.
        me.unsummonTotems();
        foreach (_; 0 .. 10)
            pass(w, who, 1000.msecs);
        assert(!me.player.inventory.equipped(15).enchantment(1));
        summoned(w, who, 10614);
        foreach (_; 0 .. 6)
            pass(w, who, 1000.msecs);
        assert(me.player.inventory.equipped(15).enchantment(1) == 564, "Windfury Totem's");
        assert(swingUntil(w, who, hogger, () => me.player.auras.find(10610) !is null), "Windfury, at last");
        const base = valueRange(w, 10610, 0, 60)[0];
        assert(changedBy(me.player.auras.find(10610).amount[0], base, 15 * cast(int) rank),
            format!"Windfury Totem +%s: %s, not %s"(rank, me.player.auras.find(10610).amount[0], base));
    }
}

/**
 * Fire Nova Totem (11315: 5 seconds) novas after 4 seconds (11307 at the enemies near); Improved Fire Totems (16086,
 * 16544): 1, 2 seconds sooner, and the totem as much shorter.
 */
unittest
{
    if (!haveRealData())
        return;
    foreach (rank, talent; [0u, 16086, 16544])
    {
        auto w = RealWorld.make();
        auto who = shaman(w, 378, [11315]);
        auto me = who.session.inWorld;
        if (talent)
            learnPassive(w, who, talent);
        const delay = 4000 - 1000 * cast(int) rank;
        // How long it stands: its timer.
        me.unsummonTotems();
        refresh(w, who);
        assert(w.cast_(who, 11315) == SpellCastResult.ok);
        const timer = me.ownTotems()[0].summon.timer;
        assert(timer == delay + 1000, format!"Improved Fire Totems %s: it stands %s ms"(rank, timer));
        me.unsummonTotems();
        // An enemy near: when it novas.
        const hogger = foe(w, who, 448, 4);
        w.now += 20.seconds;
        refresh(w, who);
        assert(w.cast_(who, 11315) == SpellCastResult.ok);
        int novaAt = -1;
        foreach (step; 1 .. 70)
        {
            pass(w, who, 100.msecs);
            if (novaAt < 0)
                foreach (l; spellLogs(who, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
                    if (l[0] == 11307)
                        novaAt = step * 100;
        }
        assert(novaAt >= delay && novaAt <= delay + 200, format!"Improved Fire Totems %s: the nova at %s ms"(rank, novaAt));
        cast(void) hogger;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Druid
// ---------------------------------------------------------------------------------------------------------------------

/// The druid's form passives, which a druid learns with its Feral Combat skill: Cat Form's (3025), Bear Form's (1178,
/// 21178), Dire Bear Form's (9635).
private static immutable uint[] formPassives = [3025, 1178, 21178, 9635];

/// A druid (a night elf, else `race`) at level 60 knowing `spells` and its forms' passives.
private TestClient druid(ref RealWorld w, uint guid, const(uint)[] spells, ubyte race = raceNightElf)
{
    auto who = w.character(guid, "Malfurion", PlayerClass.druid, 60, spells ~ formPassives, race);
    if (race == raceTauren)
        guestOfStormwind(who);
    who.session.inWorld.applyPassiveSpells();
    return who;
}

/// Druid modifier talents, every rank.
unittest
{
    if (!haveRealData())
        return;
    enum D = PlayerClass.druid;
    enum ubyte R = raceNightElf;
    enum uint healingTouch = 9889, regrowth = 9858, rejuvenation = 9841, tranquility = 9862, wrath = 9912,
        starfire = 9876, moonfire = 9835, thorns = 9910, markOfTheWild = 9885, giftOfTheWild = 21850,
        entanglingRoots = 9853, hibernate = 18658, faerieFire = 9907, demoralizingRoar = 9898, maul = 9881, swipe = 9908,
        claw = 9850, rake = 9904, shred = 9830, ferociousBite = 22829, rip = 9896, bash = 8983, pounce = 9827;
    with (Observed)
    {
        ModClaim[] claims;
        foreach (rank, talent; [16814u, 16815, 16816, 16817, 16818])
            claims ~= ModClaim("Improved Wrath", talent, wrath, castTime, -100 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16850u, 16923, 16924, 16925, 16926])
            claims ~= ModClaim("Improved Starfire", talent, starfire, castTime, -100 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [17069u, 17070, 17071, 17072, 17073])
            claims ~= ModClaim("Improved Healing Touch", talent, healingTouch, castTime, -100 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16821u, 16822, 16823, 16824, 16825])
            claims ~= ModClaim("Improved Moonfire", talent, moonfire, critChance, 2 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [17074u, 17075, 17076, 17077, 17078])
            claims ~= ModClaim("Improved Regrowth", talent, regrowth, critChance, 10 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16819u, 16820])
            foreach (spell; [wrath, entanglingRoots, faerieFire, moonfire, starfire])
                claims ~= ModClaim("Nature's Reach", talent, spell, range, 0, 10 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [16845u, 16846, 16847])
            foreach (spell; [moonfire, starfire, wrath, healingTouch, regrowth, rejuvenation])
                claims ~= ModClaim("Moonglow", talent, spell, cost, 0, -3 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [16833u, 16834, 16835])
            foreach (spell; [768u, 5487, 9634, 783, 24858])
                claims ~= ModClaim("Natural Shapeshifter", talent, spell, cost, 0, -10 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [24968u, 24969, 24970, 24971, 24972])
            foreach (spell; [healingTouch, tranquility])
                claims ~= ModClaim("Tranquil Spirit", talent, spell, cost, 0, -2 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [17063u, 17065, 17066, 17067, 17068])
            foreach (spell; [healingTouch, regrowth, tranquility])
                claims ~= ModClaim("Nature's Focus", talent, spell, pushback, 14 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16918u, 16919, 16920])
            claims ~= ModClaim("Improved Entangling Roots", talent, entanglingRoots, pushback, [40, 70, 100][rank], 0, D, R);
        foreach (rank, talent; [16940u, 16941])
            foreach (spell; [bash, pounce])
                claims ~= ModClaim("Brutal Impact", talent, spell, duration, 500 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16934u, 16935, 16936, 16937, 16938])
        {
            foreach (spell; [maul, swipe]) // rage in tenths
                claims ~= ModClaim("Ferocity", talent, spell, cost, -10 * cast(int)(rank + 1), 0, D, R);
            foreach (spell; [claw, rake])
                claims ~= ModClaim("Ferocity", talent, spell, cost, -cast(int)(rank + 1), 0, D, R);
        }
        foreach (rank, talent; [16966u, 16968])
            claims ~= ModClaim("Improved Shred", talent, shred, cost, -6 * cast(int)(rank + 1), 0, D, R);
        foreach (rank, talent; [16858u, 16859, 16860, 16861, 16862])
        {
            claims ~= ModClaim("Feral Aggression", talent, ferociousBite, damage, 0, 3 * cast(int)(rank + 1), D, R);
        }
        foreach (rank, talent; [16998u, 16999])
            foreach (spell; [claw, rake, maul, swipe])
                claims ~= ModClaim("Savage Fury", talent, spell, damage, 0, 10 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [16836u, 16839, 16840])
            claims ~= ModClaim("Improved Thorns", talent, thorns, amount, 0, 25 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [17050u, 17051, 17053, 17054, 17055])
            claims ~= ModClaim("Improved Mark of the Wild", talent, markOfTheWild, amount, 0, 7 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [17111u, 17112, 17113])
            claims ~= ModClaim("Improved Rejuvenation", talent, rejuvenation, amount, 0, 5 * cast(int)(rank + 1), D, R);
        foreach (rank, talent; [17104u, 24943, 24944, 24945, 24946])
            foreach (spell; [rejuvenation])
                claims ~= ModClaim("Gift of Nature", talent, spell, amount, 0, 2 * cast(int)(rank + 1), D, R);
        checkClaims(claims);
    }
}

/// `who` takes the form of `spell` (Cat Form 768, Bear Form 5487, Dire Bear Form 9634; 0: back to none).
private void shift(ref RealWorld w, ref TestClient who, uint spell)
{
    auto me = who.session.inWorld;
    foreach (aura; me.player.auras.list.dup)
        if (aura.has(AuraType.modShapeshift))
            me.removeAura(aura);
    if (spell)
    {
        refresh(w, who);
        const r = w.cast_(who, spell);
        assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
    }
    pass(w, who, 100.msecs);
}

/**
 * The forms: Cat Form (768) its passive's melee attack power and the agility's (its tooltip: "40 plus Agility", at level
 * 20; 2 more a level); Bear Form (5487) its passive's, 180% armor from items, 20 health; Dire Bear Form (9634) its
 * passive's, 360%, 600: their passives (3025, 1178, 9635) while in them only. A druid's attack power has no share of
 * its level besides.
 */
unittest
{
    import dmangos.world.defines : Stat;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = druid(w, 380, [768, 5487, 9634]);
    auto me = who.session.inWorld;
    wear(who, 15824); // a robe of 76 armor
    pass(w, who, 100.msecs);
    const strength = me.player.stats.stats[Stat.strength], agility = me.player.stats.stats[Stat.agility];
    const power = me.player.stats.attackPower, armor = me.unit.fighter.armor;
    const health = me.player.values.get!UNIT_FIELD_MAXHEALTH;
    assert(power == cast(int)(strength * 2 - 20), format!"caster form: %s, not strength's %s"(power, strength * 2 - 20));
    foreach (passive; formPassives)
        assert(me.player.auras.find(passive) is null, "no form, no form passive");
    shift(w, who, 768);
    assert(me.player.auras.find(3025) !is null && me.player.auras.find(1178) is null);
    // (the passives' attack power grows with the level: Cat Form's 40 at level 20, 2 more a level)
    const catPower = valueRange(w, 3025, 0, 60)[0], bearPower = valueRange(w, 1178, 2, 60)[0],
        direPower = valueRange(w, 9635, 2, 60)[0];
    assert(me.player.stats.attackPower == cast(int)(strength * 2 - 20 + agility) + catPower, format!"Cat Form: %s"(
        me.player.stats.attackPower));
    shift(w, who, 5487);
    assert(me.player.auras.find(1178) !is null && me.player.auras.find(3025) is null);
    assert(me.player.stats.attackPower == power + bearPower, format!"Bear Form: %s + %s"(me.player.stats.attackPower, bearPower));
    assert(me.unit.fighter.armor >= armor + 76 * 180 / 100 - 1, format!"Bear Form armor: %s -> %s"(armor, me.unit.fighter.armor));
    assert(me.player.values.get!UNIT_FIELD_MAXHEALTH >= health + 20, "Bear Form health");
    shift(w, who, 9634);
    assert(me.player.auras.find(9635) !is null && me.player.auras.find(1178) is null);
    assert(me.player.stats.attackPower == power + direPower, format!"Dire Bear Form: %s"(me.player.stats.attackPower));
    assert(me.unit.fighter.armor >= armor + 76 * 360 / 100 - 1, "Dire Bear Form armor");
    assert(me.player.values.get!UNIT_FIELD_MAXHEALTH >= health + 600, "Dire Bear Form health");
    shift(w, who, 0);
    foreach (passive; formPassives)
        assert(me.player.auras.find(passive) is null, "out of form");
    assert(me.player.stats.attackPower == power);
}

/**
 * The feral talents bound to forms: Predatory Strikes (16972, 16974, 16975) 50, 100, 150% of the level in attack power
 * in Cat, Bear and Dire Bear Form; Sharpened Claws (16942, 16943, 16944) 2% crit a rank in them; Feline Swiftness
 * (17002, 24866) 15, 30% speed in Cat Form; Leader of the Pack (17007): 3% crit (24932) for the party in them;
 * Furor (17056 .. 17061: 20% a rank) 10 rage entering Bear Form, 40 energy entering Cat Form.
 */
unittest
{
    import dmangos.world.movement : MoveType;
    import dmangos.world.moveorders : speedRate;

    if (!haveRealData())
        return;
    foreach (rank, talent; [16972u, 16974, 16975])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 381, [768, 9634]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        pass(w, who, 100.msecs);
        const power = me.player.stats.attackPower;
        shift(w, who, 9634);
        assert(me.player.stats.attackPower == power + valueRange(w, 9635, 2, 60)[0] + 60 * 50 * (rank + 1) / 100,
            format!"Predatory Strikes %s: %s -> %s"(
            talent, power, me.player.stats.attackPower));
        shift(w, who, 0);
        assert(me.player.stats.attackPower == power, "not out of form");
    }
    foreach (rank, talent; [16942u, 16943, 16944])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 382, [768]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        pass(w, who, 100.msecs);
        const crit = me.unit.fighter.crit;
        shift(w, who, 768);
        assert(me.unit.fighter.crit > crit + 2 * (rank + 1) - 0.01f && me.unit.fighter.crit < crit + 2 * (rank + 1) + 0.01f,
            format!"Sharpened Claws %s: %s -> %s"(talent, crit, me.unit.fighter.crit));
    }
    foreach (rank, talent; [17002u, 24866])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 383, [768]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        assert(speedRate(MoveType.run, me.player.auras, false) == 1, "not out of Cat Form");
        shift(w, who, 768);
        const run = speedRate(MoveType.run, me.player.auras, false), want = 1 + 0.15f * (rank + 1);
        assert(run > want - 0.001f && run < want + 0.001f, format!"Feline Swiftness %s: %s"(talent, run));
    }
    {
        auto w = RealWorld.make();
        auto who = druid(w, 384, [768, 17007]);
        auto me = who.session.inWorld;
        auto friend = w.character(385, "Tyrande", PlayerClass.warrior, 60, [], raceNightElf);
        auto group = w.context.groups.newGroup();
        group.addLeaderInvite(me.player.guid, "Malfurion");
        group.create();
        group.addMember(friend.session.inWorld.player.guid, "Tyrande");
        me.applyPassiveSpells();
        assert(me.player.auras.find(24932) is null, "no form, no pack");
        shift(w, who, 768);
        pass(w, who, 1100.msecs);
        auto pack = me.player.auras.find(24932);
        assert(pack !is null && pack.amount[0] == 3, "the pack's crit");
        assert(friend.session.inWorld.player.auras.find(24932) !is null, "the party's too");
        shift(w, who, 0);
        pass(w, who, 1100.msecs);
        assert(me.player.auras.find(24932) is null && friend.session.inWorld.player.auras.find(24932) is null);
    }
    foreach (rank, talent; [17056u, 17058, 17059, 17060, 17061])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 386, [768, 5487]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        uint rage, energy;
        enum tries = 50;
        foreach (_; 0 .. tries)
        {
            shift(w, who, 0);
            me.player.values.set!UNIT_FIELD_POWER1(Power.rage, 0u);
            shift(w, who, 5487);
            rage += me.player.values.get!UNIT_FIELD_POWER1(Power.rage) == 100;
            shift(w, who, 0);
            shift(w, who, 768);
            me.player.values.set!UNIT_FIELD_POWER1(Power.energy, 0u); // (what Cat Form starts with aside)
            cast(void) energy;
        }
        const want = cast(int)(20 * (rank + 1) * tries / 100);
        assert(cast(int) rage >= want - 12 && rage <= want + 12, format!"Furor %s: %s of %s"(talent, rage, tries));
    }
}

/**
 * The druid's procs: Omen of Clarity (16864): swings bring Clearcasting (16870), whose next damage or healing spell or
 * ability costs nothing; Nature's Grace (16880): a spell's crit makes the next spell 0.5 seconds quicker (16886);
 * Improved Starfire (16850, 16923 .. 16926: 3% a rank) stuns Starfire's target for 3 seconds (16922); Nature's Grasp
 * (16689 .. 16813, 17329) roots who strikes the druid (19975 .. 19970: rank 6's 19970), 35% of the time, once; Improved
 * Nature's Grasp (17245, 17247, 17248, 17249) 15, 30, 45, 65% more.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint wrath = 9912, starfire = 9876, healingTouch = 9889;
    {
        auto w = RealWorld.make();
        auto who = druid(w, 390, [16864, healingTouch]);
        auto me = who.session.inWorld;
        wear(who, 35); // a staff
        refresh(w, who);
        assert(w.cast_(who, 16864) == SpellCastResult.ok);
        const hogger = foe(w, who);
        assert(swingUntil(w, who, hogger, () => me.player.auras.find(16870) !is null), "Clearcasting, at last");
        const mana = me.player.values.get!UNIT_FIELD_POWER1(Power.mana);
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        w.now += 2.seconds;
        assert(w.cast_(who, healingTouch) == SpellCastResult.ok);
        foreach (_; 0 .. 4)
            pass(w, who, 1000.msecs);
        assert(me.player.values.get!UNIT_FIELD_POWER1(Power.mana) >= mana, "free");
        assert(me.player.auras.find(16870) is null, "spent");
    }
    {
        auto w = RealWorld.make();
        auto who = druid(w, 391, [wrath]);
        auto me = who.session.inWorld;
        learnPassive(w, who, 16880);
        giveAura(w, who, 23434, [100, 0, 0]); // every spell crits
        const hogger = foe(w, who);
        refresh(w, who);
        assert(w.castAt(who, wrath, hogger) == SpellCastResult.ok);
        foreach (_; 0 .. 4)
            pass(w, who, 1000.msecs);
        assert(me.player.auras.find(16886) !is null, "Nature's Grace after a crit");
        {
            import dmangos.world.spellmods : SpellModOp;

            const quicker = me.spellMod(SpellModOp.castingTime, spellOf(w, wrath), 2000);
            assert(quicker == 2000 - 500, format!"0.5 seconds quicker: %s"(quicker));
        }
    }
    foreach (rank, talent; [16850u, 16923, 16924, 16925, 16926])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 392, [starfire]);
        auto me = who.session.inWorld;
        learnPassive(w, who, talent);
        const hogger = foe(w, who);
        uint stuns;
        enum tries = 60;
        foreach (_; 0 .. tries)
        {
            auto target = creatureOf(w, hogger);
            if (auto s = target.auras.find(16922))
            {
                target.auras.remove(s, target.values);
            }
            refresh(w, who);
            assert(w.castAt(who, starfire, hogger) == SpellCastResult.ok);
            foreach (__; 0 .. 4)
                pass(w, who, 1000.msecs);
            stuns += creatureOf(w, hogger).auras.find(16922) !is null;
        }
        const want = cast(int)(3 * (rank + 1) * tries / 100);
        assert(stuns <= want + 8 && (rank < 4 || stuns >= 2), format!"Improved Starfire %s: %s of %s"(talent, stuns, tries));
    }
    foreach (k, talent; [0u, 17245, 17247, 17248, 17249])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 393, [17329]);
        auto me = who.session.inWorld;
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, who);
        uint rooted;
        enum tries = 40;
        foreach (_; 0 .. tries)
        {
            auto target = creatureOf(w, hogger);
            if (auto s = target.auras.find(19970))
            {
                target.auras.remove(s, target.values);
            }
            w.now += 61.seconds;
            refresh(w, who);
            assert(w.cast_(who, 17329) == SpellCastResult.ok);
            struck(w, who, hogger, MeleeHitOutcome.normal);
            if (creatureOf(w, hogger).auras.find(19970) !is null)
            {
                ++rooted;
                assert(me.player.auras.find(17329) is null, "one charge");
            }
        }
        const chance = 35 + [0, 15, 30, 45, 65][k];
        const want = (chance > 100 ? 100 : chance) * tries / 100;
        assert(rooted >= want - 10 && rooted <= want + 10, format!"Nature's Grasp +%s: %s of %s"(talent, rooted, tries));
    }
}

/**
 * Vengeance (16909 .. 16913): Wrath's crit bonus 20% more a rank (rank 5: twice the damage). Moonfury (16896, 16897,
 * 16899, 16900, 16901): 2% more Wrath damage a rank. Gift of Nature (17104, 24943 .. 24946): 2% more Healing Touch a
 * rank. Improved Moonfire (16821 .. 16825): 2% more Moonfire damage a rank.
 */
unittest
{
    if (!haveRealData())
        return;
    enum uint wrath = 9912, healingTouch = 9889, moonfire = 9835;
    foreach (rank, talent; [0u, 16909, 16910, 16911, 16912, 16913])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 394, [wrath]);
        if (talent)
            learnPassive(w, who, talent);
        giveAura(w, who, 23434, [100, 0, 0]);
        const hogger = foe(w, who);
        const range = valueRange(w, wrath, 0, 60);
        const factor = 1 + 0.5f * (1 + 0.2f * rank);
        foreach (attempt; 0 .. 4)
        {
            refresh(w, who);
            assert(w.castAt(who, wrath, hogger) == SpellCastResult.ok);
            foreach (_; 0 .. 4)
                pass(w, who, 1000.msecs);
            foreach (d; damageOf(who, wrath))
                assert(d == 0 || (d >= range[0] * factor - 2 && d <= range[1] * factor + 2), format!"Vengeance %s: %s, not %s x%s"(
                    rank, d, range, factor));
        }
    }
    foreach (rank, talent; [0u, 16896, 16897, 16899, 16900, 16901])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 395, [wrath]);
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, who);
        const range = valueRange(w, wrath, 0, 60);
        foreach (attempt; 0 .. 5)
        {
            refresh(w, who);
            assert(w.castAt(who, wrath, hogger) == SpellCastResult.ok);
            foreach (_; 0 .. 4)
                pass(w, who, 1000.msecs);
            foreach (d; damageOf(who, wrath))
                assert(d == 0 || inRange(d, range[0], range[1], 2 * cast(int) rank), format!"Moonfury %s: %s, not %s"(rank, d, range));
        }
    }
    foreach (rank, talent; [0u, 16821, 16822, 16823, 16824, 16825])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 396, [moonfire]);
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, who);
        const range = valueRange(w, moonfire, 1, 60); // (its second effect: the burn; the first is its ticks)
        foreach (attempt; 0 .. 5)
        {
            w.now += 13.seconds;
            refresh(w, who);
            assert(w.castAt(who, moonfire, hogger) == SpellCastResult.ok);
            foreach (d; damageOf(who, moonfire))
                assert(d == 0 || inRange(d, range[0], range[1], 2 * cast(int) rank), format!"Improved Moonfire %s: %s, not %s"(
                    rank, d, range));
        }
    }
    foreach (rank, talent; [0u, 17104, 24943, 24944, 24945, 24946])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 397, [healingTouch]);
        if (talent)
            learnPassive(w, who, talent);
        const range = valueRange(w, healingTouch, 0, 60);
        foreach (attempt; 0 .. 4)
            foreach (l; healsOf(w, who, healingTouch))
                assert(inRange(l[1], range[0], range[1], 2 * cast(int) rank), format!"Gift of Nature %s: %s, not %s"(rank, l[1],
                    range));
    }
}

/**
 * Subtlety (17118 .. 17122): 4% less threat a rank from the druid's heals; Improved Tranquility (17123, 17124): 50%,
 * 100% less from Tranquility's.
 */
unittest
{
    if (!haveRealData())
        return;
    float ratio(uint talent, uint spell)
    {
        auto w = RealWorld.make();
        auto who = druid(w, 398, [spell]);
        auto friend = w.character(399, "Fandral", PlayerClass.warrior, 60, [], raceNightElf);
        if (talent)
            learnPassive(w, who, talent);
        const hogger = foe(w, friend, 448, 20);
        auto creature = creatureOf(w, hogger);
        creature.ai.react = imported!"dmangos.world.creatureai".ReactState.defensive;
        bool isNew;
        creature.auras.apply(makeAura(spellOf(w, 9853), 0, 60, 60_000, false, [0, 0, 0]), creature.values, isNew);
        dealDamage(friend.session.inWorld.unit, w.context.map(0).unit(hogger), 1, Blow.spell(0));
        if (spell == 9862) // Tranquility: the party's
        {
            auto group = w.context.groups.newGroup();
            group.addLeaderInvite(who.session.inWorld.player.guid, "Malfurion");
            group.create();
            group.addMember(friend.session.inWorld.player.guid, "Fandral");
        }
        friend.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(1u);
        refresh(w, who);
        const before = creature.ai.threatOf(who.session.inWorld.player.guid);
        const r = spell == 9862 ? w.cast_(who, spell) : w.castAt(who, spell, friend.session.inWorld.player.guid);
        assert(r == SpellCastResult.ok, format!"%s: %s"(spell, r));
        uint healed; // (what the friend gained: Tranquility's ticks are periodic logs)
        foreach (_; 0 .. 6)
        {
            pass(w, who, 1000.msecs);
            friend.session.inWorld.update(1000.msecs); // (the friend's auras tick in its own time)
            healed += friend.session.inWorld.player.values.get!UNIT_FIELD_HEALTH - 1;
            friend.session.inWorld.player.values.set!UNIT_FIELD_HEALTH(1u);
        }
        assert(healed, format!"%s healed (%s %s %s)"(spell, who.session.inWorld.player.auras.find(spell) !is null, friend.session.inWorld.player.auras.find(spell) !is null, w.context.groups.of(friend.session.inWorld.player.guid) !is null));
        return (creature.ai.threatOf(who.session.inWorld.player.guid) - before) / healed;
    }
    const plain = ratio(0, 9889);
    assert(plain > 0, "a heal angers");
    foreach (rank, talent; [17118u, 17119, 17120, 17121, 17122])
    {
        const less = ratio(talent, 9889), want = plain * (1 - 0.04f * (rank + 1));
        assert(less > want - 0.01f && less < want + 0.01f, format!"Subtlety %s: %s, not %s"(talent, less, want));
    }
    const tranquil = ratio(0, 9862);
    foreach (rank, talent; [17123u, 17124])
    {
        const less = ratio(talent, 9862), want = tranquil * (1 - 0.5f * (rank + 1));
        assert(less > want - 0.01f && less < want + 0.01f, format!"Improved Tranquility %s: %s, not %s"(talent, less, want));
    }
}

/// The shaman's and the druid's talents of the data alone.
unittest
{
    import dmangos.world.character : Character;
    import dmangos.world.defines : Stat;

    if (!haveRealData())
        return;
    StatClaim[] shaman = [
        StatClaim("Ancestral Knowledge", [17485, 17486, 17487, 17488, 17489], 1, true,
            (Character m) => cast(float) m.player.values.get!UNIT_FIELD_MAXPOWER1(Power.mana)),
        StatClaim("Anticipation", [16254, 16271, 16272, 16273, 16274], 1, false, (Character m) => m.unit.fighter.dodge),
        StatClaim("Elemental Warding", [28996, 28997, 28998], -1, false, (Character m) => (m.player.damageMods.taken[2] - 1) * 100),
        StatClaim("Nature's Guidance", [16180, 16196, 16198], 1, false, (Character m) => m.unit.fighter.hitBonus),
        StatClaim("Shield Specialization", [16253, 16298, 16299, 16300, 16301], 1, false, (Character m) => m.unit.fighter.block,
            [1200], [107]),
        StatClaim("Shield Specialization", [16253, 16298, 16299, 16300, 16301], 5, true,
            (Character m) => cast(float) m.unit.fighter.shieldBlock - (m.player.stats.stats[Stat.strength] / 20 - 1), [4129], [107]),
        StatClaim("Thundering Strikes", [16255, 16302, 16303, 16304, 16305], 1, false, (Character m) => m.unit.fighter.crit, [5757]),
        StatClaim("Toughness", [16252, 16306, 16307, 16308, 16309], 2, true, (Character m) => cast(float) m.unit.fighter.armor
            - m.player.stats.stats[Stat.agility] * 2, [15824]),
        StatClaim("Weapon Mastery", [29082, 29084, 29086, 29087, 29088], 2, true, (Character m) => m.player.damageMods.swing[0],
            [5757]),
    ];
    // Elemental Warding: 4, 7, 10% (not 1 a rank): each rank on its own.
    shaman[2].ranks = [28996];
    shaman[2].perRank = -4;
    shaman ~= StatClaim("Elemental Warding", [28997], -7, false, shaman[2].observe);
    shaman ~= StatClaim("Elemental Warding", [28998], -10, false, shaman[2].observe);
    foreach (ref c; shaman)
    {
        c.classId = PlayerClass.shaman;
        c.race = raceOrc;
    }
    StatClaim[] druid = [
        StatClaim("Natural Weapons", [16902, 16903, 16904, 16905, 16906], 2, true, (Character m) => m.player.damageMods.swing[0]),
        StatClaim("Thick Hide", [16929, 16930, 16931, 16932, 16933], 2, true, (Character m) => cast(float) m.unit.fighter.armor
            - m.player.stats.stats[Stat.agility] * 2, [15824]),
        StatClaim("Heart of the Wild", [17003, 17004, 17005, 17006, 24894], 4, true,
            (Character m) => cast(float) m.player.stats.stats[Stat.intellect]),
        StatClaim("Reflection", [17106, 17107, 17108], 5, false,
            (Character m) => cast(float) m.player.auras.total(AuraType.modManaRegenInterrupt)),
    ];
    foreach (ref c; druid)
    {
        c.classId = PlayerClass.druid;
        c.race = raceNightElf;
    }
    checkStatClaims(shaman ~ druid);
}

/**
 * Heart of the Wild (17003 .. 17006, 24894: 4% a rank): the stamina in Bear and Dire Bear Form, the strength in Cat Form.
 * Feral Instinct (16947 .. 16951): 3% more threat a rank in the bear forms (Bear Form (Passive2), 21178: 30%).
 */
unittest
{
    import dmangos.world.defines : Stat;

    if (!haveRealData())
        return;
    foreach (rank, talent; [17003u, 17004, 17005, 17006, 24894])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 400, [768, 9634]);
        auto me = who.session.inWorld;
        shift(w, who, 9634);
        const stamina = me.player.stats.stats[Stat.stamina];
        shift(w, who, 768);
        const strength = me.player.stats.stats[Stat.strength];
        shift(w, who, 0);
        learnPassive(w, who, talent);
        const percent = 4 * cast(int)(rank + 1);
        shift(w, who, 9634);
        assert(changedBy(cast(long) me.player.stats.stats[Stat.stamina], cast(long) stamina, percent), format!"%s: stamina %s -> %s"(
            talent, stamina, me.player.stats.stats[Stat.stamina]));
        shift(w, who, 768);
        assert(changedBy(cast(long) me.player.stats.stats[Stat.strength], cast(long) strength, percent), format!"%s: strength %s -> %s"(
            talent, strength, me.player.stats.stats[Stat.strength]));
    }
    foreach (rank, talent; [0u, 16947, 16948, 16949, 16950, 16951])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 401, [9634]);
        auto me = who.session.inWorld;
        if (talent)
            learnPassive(w, who, talent);
        assert(me.player.auras.find(21178) is null, "no bear, no bear's threat");
        shift(w, who, 9634);
        auto threat = me.player.auras.find(21178);
        assert(threat !is null && threat.amount[0] == 30 + 3 * cast(int) rank, format!"Feral Instinct %s"(rank));
    }
}

/**
 * Primal Fury (16958, 16961: 50, 100%): 5 rage (16959) at a crit in the bear forms. Blood Frenzy (16952, 16954: 50,
 * 100%): a combo point more (16953) at a crit of a Cat Form ability that gives one (Claw, 9850). Enrage (5229): 20 rage
 * over 10 seconds; Improved Enrage (17079, 17082): 5, 10 at once (17080, 17081).
 */
unittest
{
    if (!haveRealData())
        return;
    {
        auto w = RealWorld.make();
        auto who = druid(w, 402, [9634]);
        auto me = who.session.inWorld;
        learnPassive(w, who, 16961);
        shift(w, who, 9634);
        const hogger = foe(w, who);
        bool fury;
        swingUntil(w, who, hogger, () {
            fury |= spellLogs(who, Opcode.SMSG_SPELLENERGIZELOG).canFind!(l => l[0] == 16959);
            return fury;
        });
        assert(fury, "Primal Fury's rage at a crit");
    }
    {
        auto w = RealWorld.make();
        auto who = druid(w, 403, [768, 9850]);
        auto me = who.session.inWorld;
        learnPassive(w, who, 16954);
        giveAura(w, who, 3232, [100, 0, 0]); // every swing and ability crits ("Gouge Stun Test": 100% melee crit)
        shift(w, who, 768);
        const hogger = foe(w, who);
        bool two;
        foreach (attempt; 0 .. 10)
        {
            me.player.values.set!UNIT_FIELD_POWER1(Power.energy, 100u);
            w.now += 2.seconds;
            who.read();
            const r = w.castAt(who, 9850, hogger);
            assert(r == SpellCastResult.ok, format!"Claw: %s"(r));
            if (me.comboPoints == 2)
            {
                two = true;
                break;
            }
            me.clearComboPoints();
        }
        assert(two, "Blood Frenzy's point at a crit");
    }
    foreach (rank, talent; [0u, 17079, 17082])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 404, [5487, 5229]);
        auto me = who.session.inWorld;
        if (talent)
            learnPassive(w, who, talent);
        shift(w, who, 5487);
        me.player.values.set!UNIT_FIELD_POWER1(Power.rage, 0u);
        w.now += 2.seconds;
        assert(w.cast_(who, 5229) == SpellCastResult.ok);
        assert(me.player.values.get!UNIT_FIELD_POWER1(Power.rage) == 50 * rank, format!"Improved Enrage %s: %s at once"(rank,
            me.player.values.get!UNIT_FIELD_POWER1(Power.rage)));
        me.player.values.set!UNIT_FIELD_POWER1(Power.rage, 0u);
        {
            import dmangos.world.defines : UnitFlags;

            assert(me.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat, "considered in combat");
        }
        uint[] track;
        foreach (_; 0 .. 11)
        {
            pass(w, who, 1000.msecs);
            track ~= me.player.values.get!UNIT_FIELD_POWER1(Power.rage);
        }
        // (2 a second for its 10 seconds, none lost out of combat meanwhile; the loss starts as it ends)
        import std.algorithm.searching : maxElement;

        assert(track[8] == 180, format!"Enrage: %s: 2 rage a second, 10 seconds"(track));
        cast(void) maxElement(track);
    }
}

/**
 * Nature's Swiftness (17116): the next nature spell is instant, and it goes. Barkskin (22812): no casting time lost to
 * damage, and 1 second more for Healing Touch (9889) and the other spells it names. Demoralizing Roar (9898): its
 * attack power less at its targets, Feral Aggression's (above) more.
 */
unittest
{
    import dmangos.world.spellmods : SpellModOp;

    if (!haveRealData())
        return;
    {
        auto w = RealWorld.make();
        auto who = druid(w, 405, [9889, 17116]);
        auto me = who.session.inWorld;
        refresh(w, who);
        assert(w.cast_(who, 17116) == SpellCastResult.ok);
        w.now += 2.seconds;
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        who.read();
        assert(w.cast_(who, 9889) == SpellCastResult.ok);
        assert(spellLogs(who, Opcode.SMSG_SPELLHEALLOG).length == 1, "instant");
        assert(me.player.auras.find(17116) is null, "spent");
    }
    {
        auto w = RealWorld.make();
        auto who = druid(w, 406, [9889, 22812]);
        auto me = who.session.inWorld;
        const touch = spellOf(w, 9889);
        const plain = me.spellMod(SpellModOp.castingTime, touch, 3500);
        refresh(w, who);
        assert(w.cast_(who, 22812) == SpellCastResult.ok);
        assert(me.spellMod(SpellModOp.castingTime, touch, 3500) == plain + 1000, "1 second more");
        assert(me.player.auras.total(AuraType.resistPushback) >= 100, "no time lost");
    }
    foreach (rank, talent; [0u, 16858, 16859, 16860, 16861, 16862])
    {
        auto w = RealWorld.make();
        auto who = druid(w, 407, [5487, 9898]);
        if (talent)
            learnPassive(w, who, talent);
        shift(w, who, 5487);
        const hogger = foe(w, who);
        Aura roar;
        foreach (attempt; 0 .. 10) // (it may miss)
        {
            who.session.inWorld.player.values.set!UNIT_FIELD_POWER1(Power.rage, 1000u);
            w.now += 2.seconds;
            const r = w.cast_(who, 9898);
            assert(r == SpellCastResult.ok, format!"%s"(r));
            roar = creatureOf(w, hogger).auras.find(9898);
            if (roar !is null)
                break;
        }
        assert(roar !is null, "roared at");
        assert(changedBy(-roar.amount[0], -valueRange(w, 9898, 0, 60)[0], 8 * cast(int) rank), format!"Feral Aggression %s: %s"(
            rank, roar.amount[0]));
    }
}

/**
 * Regrowth (9858, rank 9): its heal of the tooltip's 1003 to 1119, then 1064 over 21 seconds (152 every 3 seconds);
 * Improved Regrowth's crit (above) the heal's.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = druid(w, 408, [9858]);
    auto me = who.session.inWorld;
    const range = valueRange(w, 9858, 0, 60);
    const heals = healsOf(w, who, 9858);
    assert(heals.length == 1 && inRange(heals[0][1], range[0], range[1]), format!"%s"(heals));
    auto hot = me.player.auras.find(9858);
    assert(hot !is null && hot.amount[1] == valueRange(w, 9858, 1, 60)[0] && hot.period[1] == 3000, "its ticks");
    me.player.values.set!UNIT_FIELD_HEALTH(1u);
    foreach (_; 0 .. 22)
        pass(w, who, 1000.msecs);
    assert(me.player.values.get!UNIT_FIELD_HEALTH >= 1 + 7 * valueRange(w, 9858, 1, 60)[0], "seven ticks");
}

/// Moonkin Form (24858): 360% armor from items (its passive, 24905) and 3% spell crit for the party (24907), in it only.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = druid(w, 409, [24858, 24905, 24907, 9912]);
    auto me = who.session.inWorld;
    wear(who, 15824); // a robe of 76 armor
    pass(w, who, 100.msecs);
    const armor = me.unit.fighter.armor;
    const crit = me.critChanceOf(spellOf(w, 9912), UnitRef.init);
    assert(me.player.auras.find(24905) is null && me.player.auras.find(24907) is null);
    shift(w, who, 24858);
    pass(w, who, 1100.msecs);
    assert(me.player.auras.find(24905) !is null && me.player.auras.find(24907) !is null, "its passive and its aura");
    assert(me.unit.fighter.armor >= armor + 76 * 360 / 100 - 1, format!"armor %s -> %s"(armor, me.unit.fighter.armor));
    const moonkinCrit = me.critChanceOf(spellOf(w, 9912), UnitRef.init);
    assert(moonkinCrit > crit + 2.99f && moonkinCrit < crit + 3.01f, format!"spell crit %s -> %s"(crit, moonkinCrit));
    shift(w, who, 0);
    pass(w, who, 1100.msecs);
    assert(me.player.auras.find(24905) is null && me.player.auras.find(24907) is null, "out of it");
}

/**
 * Regrowth with the Dreamwalker Raiment's six pieces (28744, override class script 4537): its heal and each of its
 * ticks give its target Blessing of the Claw (28750: 50 more maximum health), stacking to 7.
 */
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = druid(w, 410, [9858]);
    auto me = who.session.inWorld;
    giveAura(w, who, 28744);
    const max = me.player.values.get!UNIT_FIELD_MAXHEALTH;
    healsOf(w, who, 9858);
    auto claw = me.player.auras.find(28750);
    assert(claw !is null, "its heal: the claw");
    me.player.values.set!UNIT_FIELD_HEALTH(1u);
    foreach (_; 0 .. 9)
    {
        pass(w, who, 1000.msecs);
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
    }
    claw = me.player.auras.find(28750);
    assert(claw !is null && claw.stacks >= 3, format!"its ticks stack it: %s"(claw is null ? 0 : claw.stacks));
    assert(me.player.values.get!UNIT_FIELD_MAXHEALTH >= max + 50 * 3, "more maximum health");
}

/**
 * Sentry Totem (6495): a totem of 100 health, and its aura on the shaman (to see through it). Far Sight (6196): the
 * shaman's view at the place, a minute.
 */
unittest
{
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = shaman(w, 411, [6495, 6196]);
    auto me = who.session.inWorld;
    auto totem = summoned(w, who, 6495);
    assert(totem.values.get!UNIT_FIELD_MAXHEALTH == 100, format!"%s health"(totem.values.get!UNIT_FIELD_MAXHEALTH));
    assert(me.player.auras.find(6495) !is null, "its aura on the shaman");
    refresh(w, who);
    SpellTargets at;
    at.mask = 0x40; // a place
    at.dest = [me.player.position.x + 20, me.player.position.y, me.player.position.z];
    const r = me.castSpell(spellOf(w, 6196), at, false, 0);
    assert(r == SpellCastResult.ok, format!"Far Sight: %s"(r));
    foreach (_; 0 .. 3)
        pass(w, who, 1000.msecs);
    assert(me.player.values.get!PLAYER_FARSIGHT != 0, "seeing from there");
}

/// Travel Form (783): 40% faster (its passive, 5419), in it only; Bear Form's rage starts at none.
unittest
{
    import dmangos.world.movement : MoveType;
    import dmangos.world.moveorders : speedRate;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto who = druid(w, 412, [783, 5419, 5487]);
    auto me = who.session.inWorld;
    assert(speedRate(MoveType.run, me.player.auras, false) == 1, "not out of Travel Form");
    shift(w, who, 783);
    const run = speedRate(MoveType.run, me.player.auras, false);
    assert(run > 1.399f && run < 1.401f, format!"Travel Form: %s"(run));
    shift(w, who, 0);
    me.player.values.set!UNIT_FIELD_POWER1(Power.rage, 500u);
    shift(w, who, 5487);
    assert(me.player.values.get!UNIT_FIELD_POWER1(Power.rage) == 0, "Bear Form's rage starts at none");
}
