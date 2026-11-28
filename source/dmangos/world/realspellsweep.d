/**
 * Every spell a player can learn, cast on the real data, each effect checked against what the data says it does.
 *
 * The spells: those trainers teach, those a new character has, every rank of every talent, and what any of them
 * teaches, triggers or procs in turn (as tools/harness/spell-audit.py and tools/spellspec.py count them), each of the
 * class tools/spellspec.py gives it. Each is cast by a fresh level 60 character of its class with what the spell
 * asks set up first: its reagents and tools in the bags, its weapon or shield worn, its form or stance, combo points,
 * stealth, a hostile creature (of the creature type it needs) behind whose back it stands, or a hurt friend, a spell
 * focus beside it. Then, from the spell's own data: each damaging effect took health, each heal gave it, each aura is
 * on the unit the effect's implicit target names, as long as `DurationIndex` says (a finishing move's by its combo
 * points), combo points were added, power given, items made, creatures summoned; the cost was paid and the
 * cooldown (its own or its category's) started.
 * Fishing runs with extracted terrain and waits for the bobber's bite and loot through client packets.
 *
 * A spell that fails is either fixed in the server or listed in tools/harness/realspell-known.txt with its reason:
 * the sweep fails at a failure not listed there, and says which listed ones pass now. Runs with the other real-data
 * tests (`DMANGOS_REAL_DATA`, see `dmangos.world.realspelltests`); `DMANGOS_SWEEP_ONLY` (ids, comma separated)
 * sweeps only those, and says what each did.
 */
module dmangos.world.realspellsweep;

version (unittest):

import core.time : msecs;
import std.algorithm.comparison : among, max, min;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.world.character : Character;
import dmangos.world.unit : UnitKind, UnitRef;
import dmangos.world.clientdata : ClientData;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.defines : Power;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : Player;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.spellcast : isNextMeleeSwingSpell, SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.spellids : AuraType, ImplicitTarget, SpellEffect;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient : TestClient;
import dmangos.world.unit : UnitRef;
import dmangos.world.updatefields;
import dmangos.world.worlddata : WorldData;

/// A spell the sweep casts: of which class, and whether it is only ever triggered (a proc, a talent's effect).
struct Sweepable
{
    uint id;
    ubyte classId; /// 0: no class's (a profession, a racial)
    bool triggered;
}

private enum uint learnSpellEffect = 36, triggerSpellEffect = 64;
private enum uint spellAttrPassive = 0x40;

/**
 * The spells a player can learn and cast (as tools/spellspec.py has them): trainers' (the teaching spell and the
 * one taught), a new character's, every talent rank, and the closure over what they teach, trigger and proc.
 * Passive ones, and those whose effects only matter as they are learned (a skill, a proficiency), are left out.
 */
Sweepable[] learnableSpells(const WorldData data, const ClientData client)
{
    import std.algorithm.sorting : sort;

    enum ubyte[] classes = [1, 2, 3, 4, 5, 7, 8, 9, 11];
    ubyte[uint] classOf;
    ubyte exactClass(uint mask)
    {
        foreach (c; classes)
            if (mask == 1u << (c - 1))
                return c;
        return 0;
    }
    foreach (spellId; data.spells.spells.byKey)
        foreach (ability; client.abilitiesForSpell(spellId))
            if (const c = exactClass(ability.classMask))
            {
                if (spellId !in classOf)
                    classOf[spellId] = c;
                break;
            }
    uint[] start;
    foreach (_, trainer; data.npcs.trainers)
        foreach (t; trainer)
            start ~= [t.spell, t.learnedSpell];
    foreach (_, trainer; data.npcs.trainerTemplates)
        foreach (t; trainer)
            start ~= [t.spell, t.learnedSpell];
    foreach (_, ref info; data.playerInfo)
        start ~= info.spells;
    foreach (talentId; client.talents.ids)
    {
        const talent = client.talents.lookup(talentId);
        const tab = client.talentTabs.lookup(talent.talentTab);
        foreach (spell; talent.rankId)
            if (spell)
            {
                start ~= spell;
                if (tab !is null)
                    if (const c = exactClass(tab.classMask))
                        if (spell !in classOf)
                            classOf[spell] = c;
            }
    }
    bool[uint] learned, known, byTrigger;
    // What is learned (taught, given, a talent), then what that triggers and procs.
    auto todo = start.dup;
    while (todo.length)
    {
        const id = todo[$ - 1];
        todo = todo[0 .. $ - 1];
        const s = data.spells.spell(id);
        if (s is null || id in known)
            continue;
        known[id] = true;
        foreach (i; 0 .. 3)
        {
            const t = s.triggerSpell[i];
            if (!t)
                continue;
            const aura = s.casting.applyAuraName[i];
            const isLearn = s.effect[i] == learnSpellEffect;
            if (isLearn || s.effect[i] == triggerSpellEffect || aura == AuraType.procTriggerSpell
                    || aura == AuraType.periodicTriggerSpell || aura == AuraType.addTargetTrigger)
            {
                todo ~= t;
                if (!isLearn)
                    byTrigger[t] = true;
                if (const c = id in classOf)
                    if (t !in classOf)
                        classOf[t] = *c;
            }
        }
    }
    foreach (id; start)
        learned[id] = true;
    // Learned through a learning spell: learned, not triggered.
    foreach (id, _; known)
        if (const s = data.spells.spell(id))
            foreach (i; 0 .. 3)
                if (s.effect[i] == learnSpellEffect && s.triggerSpell[i])
                    learned[s.triggerSpell[i]] = true;
    enum familyClass = [3: 8, 4: 1, 5: 9, 6: 5, 7: 11, 8: 4, 9: 3, 10: 2, 11: 7];
    Sweepable[] found;
    foreach (id, _; known)
    {
        const s = data.spells.spell(id);
        if (s.attributes & spellAttrPassive || !castInPlay(*s))
            continue;
        ubyte classId;
        if (const c = id in classOf)
            classId = *c;
        else if (const c = s.casting.spellFamilyName in familyClass)
            classId = cast(ubyte)*c;
        found ~= Sweepable(id, classId, (id in learned) is null && (id in byTrigger) !is null);
    }
    found.sort!((a, b) => a.id < b.id);
    return found;
}

/// Whether casting the spell does something: an effect beyond those that matter only as it is learned.
private bool castInPlay(const ref SpellInfo s)
{
    with (SpellEffect) foreach (e; s.effect)
        if (e != none && e != learnSpell && e != dualWield && e != proficiency && e != language && e != skill
                && e != skillStep && e != weapon && e != defense && e != block && e != parry && e != dodge
                && e != spellDefense && e != tradeSkill)
            return true;
    return false;
}

// ---------------------------------------------------------------------------------------------------------------
// The setup
// ---------------------------------------------------------------------------------------------------------------

private enum : ubyte
{
    raceHuman = 1, raceOrc = 2, raceDwarf = 3, raceNightElf = 4, raceUndead = 5, raceTauren = 6, raceGnome = 7,
    raceTroll = 8,
}

/// The race and class to cast `s` (of class `classId`, 0: none): the races and classes its abilities name, the
/// power it costs.
private ubyte[2] casterOf(const WorldData data, const ClientData client, const ref SpellInfo s, ubyte classId)
{
    uint raceMask, classMask;
    foreach (ability; client.abilitiesForSpell(s.id))
    {
        raceMask |= ability.raceMask;
        classMask |= ability.classMask;
    }
    enum ubyte[] byPower = [8, 1, 3, 4]; // mana: a mage; rage: a warrior; focus: a hunter; energy: a rogue
    ubyte[] classes = classId ? [classId] : [];
    if (!classId)
    {
        if (s.casting.powerType < byPower.length)
            classes ~= byPower[s.casting.powerType];
        foreach (ubyte c; [1, 8, 4, 5, 2, 3, 7, 9, 11])
            if (!classes.canFind(c))
                classes ~= c;
        if (classMask)
        {
            ubyte[] allowed;
            foreach (c; classes)
                if (classMask & (1u << (c - 1)))
                    allowed ~= c;
            if (allowed.length)
                classes = allowed;
        }
    }
    foreach (c; classes)
        foreach (ubyte r; [raceHuman, raceOrc, raceDwarf, raceNightElf, raceUndead, raceTauren, raceGnome, raceTroll])
            if ((!raceMask || (raceMask & (1u << (r - 1)))) && data.isValidRaceClass(r, c))
                return [r, c];
    return [raceHuman, classes[0]];
}

/// The setup's real rows, looked up once.
private final class Choices
{
    const WorldData data;
    const ClientData client;
    uint[string] firstRankByName; // a spell's lowest id of a name among the learnable ones
    uint[ubyte] formSpell;        // the spell that shifts into each form (`SPELL_AURA_MOD_SHAPESHIFT`'s misc value)

    this(const WorldData data, const ClientData client, const Sweepable[] spells)
    {
        this.data = data;
        this.client = client;
        foreach (sw; spells)
        {
            const s = data.spells.spell(sw.id);
            if (s.casting.name !in firstRankByName)
                firstRankByName[s.casting.name] = sw.id;
        }
        // The forms: a player's spell of each (some are a quest's reward: Defensive Stance, Bear Form).
        foreach (id, ref s; data.spells.spells)
            foreach (i; 0 .. 3)
                if (s.effect[i] == SpellEffect.applyAura && s.casting.applyAuraName[i] == AuraType.modShapeshift
                        && client.abilitiesForSpell(id).length)
                {
                    const form = cast(ubyte) s.miscValue[i];
                    if (form !in formSpell || id < formSpell[form])
                        formSpell[form] = id;
                }
    }

    private uint[][string] itemCache;

    /// Items of `itemClass` and one of the subclasses of `mask` (0: any) that a level 60 `classId` may wear,
    /// lowest entry first.
    uint[] wearable(int itemClass, int mask, ubyte classId, ubyte race)
    {
        import std.algorithm.sorting : sort;

        const key = format!"%s/%s/%s/%s"(itemClass, mask, classId, race);
        if (auto found = key in itemCache)
            return *found;
        uint[] found;
        foreach (entry, ref item; data.items)
        {
            if (item.itemClass != itemClass || (mask && !(mask & (1 << item.subClass))))
                continue;
            if (item.requiredLevel > 60 || item.requiredSkill || item.requiredSpell || item.requiredHonorRank
                    || item.requiredReputationFaction || item.inventoryType == 0)
                continue;
            if (!(item.allowableClass & (1u << (classId - 1))) || !(item.allowableRace & (1u << (race - 1))))
                continue;
            found ~= entry;
        }
        found.sort();
        return itemCache[key] = found;
    }

    private uint[string] creatureCache;

    /**
     * A hostile creature for `s`: of the creature type it needs (`TargetCreatureType`; any: a humanoid), of a
     * level at most its `MaxTargetLevel` (else 60), tameable for Tame Beast, with pockets to pick, a skin to take,
     * mana to burn; of an ordinary rank, attackable, immune to nothing, with no script of its own if one will do;
     * 0 if none.
     */
    uint enemyFor(const ref SpellInfo s)
    {
        const typeMask = s.casting.targetCreatureType, maxLevel = s.casting.maxTargetLevel;
        const tameable = s.hasEffect(SpellEffect.tamecreature), pockets = s.hasEffect(SpellEffect.pickpocket),
            skin = s.hasEffect(SpellEffect.skinning);
        bool mana;
        foreach (i; 0 .. 3)
            mana |= s.effect[i].among(SpellEffect.powerBurn, SpellEffect.powerDrain) && s.miscValue[i] == 0;
        const key = format!"%s/%s/%s%s%s%s"(typeMask, maxLevel, tameable, pockets, skin, mana);
        if (auto found = key in creatureCache)
            return *found;
        uint mechanics; // what of it a creature may not be immune to (undead are to fear: not to Turn Undead's)
        foreach (m; [s.casting.mechanic, s.casting.effectMechanic[0], s.casting.effectMechanic[1],
                s.casting.effectMechanic[2]])
            if (m)
                mechanics |= 1u << (m - 1);
        enum uint humanoid = 7, tameableFlag = 1;
        enum uint unattackable = 0x2 | 0x100 | 0x200 | 0x2000000 | 0x80; // non-attackable, immune, not selectable
        const top = maxLevel ? min(maxLevel, 60) : 60;
        uint best;
        foreach (strict; [true, false])
        {
            foreach (entry, ref t; data.creatureTemplates)
            {
                const ofType = typeMask ? t.creatureType && (typeMask & (1u << (t.creatureType - 1)))
                    : t.creatureType == humanoid;
                if (!ofType)
                    continue;
                if (t.maxLevel > top || t.rank != 0 || (t.unitFlags & unattackable) || t.schoolImmuneMask
                        || (strict ? t.mechanicImmuneMask != 0 : (t.mechanicImmuneMask & mechanics) != 0))
                    continue;
                if ((tameable && !(t.typeFlags & tameableFlag)) || (pockets && !t.pickpocketLootId)
                        || (skin && !t.skinningLootId) || (mana && !t.minLevelMana))
                    continue;
                if (strict && (t.minLevel + 4 < top || t.civilian || t.npcFlags || entry in data.creatureScriptNames
                        || entry in data.eventAi.byCreature))
                    continue;
                const faction = client.factionTemplates.lookup(t.faction);
                if (faction is null || !(faction.enemyGroupMask & 1)) // hostile to players
                    continue;
                if (!best || entry < best)
                    best = entry;
            }
            if (best)
                break;
        }
        return creatureCache[key] = best;
    }

    /// A learnable spell whose aura is of dispel type `type`, helpful (`positive`) or harmful; null if none.
    const(SpellInfo)* dispellable(int type, bool harmful)
    {
        const(SpellInfo)* best;
        foreach (id; firstRankByName.byValue)
        {
            const s = data.spells.spell(id);
            if (s.casting.dispel != type || !s.hasEffect(SpellEffect.applyAura) || harms(*s) != harmful
                    || s.attributesEx & 0x44)
                continue;
            if (best is null || id < best.id)
                best = s;
        }
        return best;
    }

    /// A spell focus object (`GAMEOBJECT_TYPE_SPELL_FOCUS`) of `focus`; 0 if none.
    uint focusObject(uint focus)
    {
        enum uint spellFocus = 8;
        uint best;
        foreach (entry, ref t; data.gameObjectTemplates)
            if (t.type == spellFocus && t.data[0] == focus && (!best || entry < best))
                best = entry;
        return best;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// One cast
// ---------------------------------------------------------------------------------------------------------------

/// The targets an implicit target names, as the sweep sets them up.
package enum Who { nobody, caster, enemy, friend, pet }

package Who whoOf(ImplicitTarget a, ImplicitTarget b, bool hasFriend, bool harmful)
{
    with (ImplicitTarget) switch (a)
    {
    case enemy, enemyNearCaster, enemiesAroundDest, enemiesInCone, enumUnitsEnemyAoeAtDynobjLoc,
            enumUnitsEnemyWithinCasterRange, enumUnitsEnemyInCone54, enemiesAroundSource:
        return Who.enemy;
    case unit: // anyone: an enemy for what harms (Hunter's Mark), else a friend
        return harmful ? Who.enemy : hasFriend ? Who.friend : Who.caster;
    case friend, unitRaid, unitFriendChainHeal, unitFriendAndParty:
        return hasFriend ? Who.friend : Who.caster;
    case caster, partyInRange, party, partyAroundSource, friendsAroundSource, enumUnitsRaidWithinCasterRange,
            friendNearCaster, unitRaidNearCaster:
        return Who.caster;
    case unitCasterPet:
        return Who.pet;
    case casterSource, locationCasterTargetPosition, locationCasterDest:
        return b == ImplicitTarget.none ? Who.caster : whoOf(b, ImplicitTarget.none, hasFriend, harmful);
    default:
        return Who.nobody;
    }
}

/// Whether the spell harms: a damaging effect, or an aura only an enemy is given (for `TARGET_UNIT`, anyone).
package bool harms(const ref SpellInfo s)
{
    with (AuraType) with (SpellEffect) foreach (i; 0 .. 3)
    {
        if (s.effect[i].among(schoolDamage, weaponDamage, weaponDamageNoschool, normalizedWeaponDmg,
                weaponPercentDamage, healthLeech, powerDrain, powerBurn, skinning, pickpocket))
            return true;
        if (s.effect[i] == applyAura && s.casting.applyAuraName[i].among(periodicDamage, periodicLeech,
                periodicManaLeech, modStalked, empathy, modStun, modFear, modConfuse, modRoot, modDecreaseSpeed,
                modSilence, modPacify))
            return true;
        // Any aura aimed at an enemy is a debuff (Demoralizing Roar's attack power, Expose Weakness's damage taken), and
        // any other effect aimed at enemies is against them too (War Stomp's knockback).
        if (s.effect[i] && (isEnemyTarget(s.implicitTargetA[i]) || isEnemyTarget(s.casting.implicitTargetB[i])))
            return true;
    }
    return false;
}

/// Whether an implicit target is the caster's enemy or enemies (`TARGET_UNIT_ENEMY`, its areas and cone).
private bool isEnemyTarget(ImplicitTarget t)
{
    import std.algorithm.comparison : among;

    return t.among(ImplicitTarget.enemy, ImplicitTarget.enemiesAroundSource, ImplicitTarget.enemiesAroundDest,
        ImplicitTarget.enemiesInCone) != 0;
}

/// Who effect `i` of `s` is at.
package Who whoOf(const ref SpellInfo s, size_t i, bool hasFriend)
{
    return whoOf(s.implicitTargetA[i], s.casting.implicitTargetB[i], hasFriend, harms(s));
}

/// Whether the spell needs a hostile creature: one of its effects is at an enemy.
private bool hostile(const ref SpellInfo s)
{
    foreach (i; 0 .. 3)
        if (s.effect[i] && (whoOf(s, i, false) == Who.enemy
                || whoOf(s.casting.implicitTargetB[i], ImplicitTarget.none, false, harms(s)) == Who.enemy))
            return true;
    return false;
}

/// Whether one of its effects is at a friend (not the caster): the sweep gives it one.
private bool friendly(const ref SpellInfo s)
{
    foreach (i; 0 .. 3)
        if (s.effect[i] && whoOf(s, i, true) == Who.friend)
            return true;
    return false;
}

/// Whether one of its effects is at the caster's pet (Health Funnel, Mend Pet).
private bool needsPet(const ref SpellInfo s)
{
    foreach (i; 0 .. 3)
        if (s.effect[i] && (s.implicitTargetA[i] == ImplicitTarget.unitCasterPet
                || s.casting.implicitTargetB[i] == ImplicitTarget.unitCasterPet))
            return true;
    return false;
}

/// Whether it raises the dead.
private bool raises(const ref SpellInfo s)
{
    return s.hasEffect(SpellEffect.resurrect) || s.hasEffect(SpellEffect.resurrectNew);
}

/// What must be on a spell's target before it (by name: the client greys it out without): the first rank of a
/// spell the caster casts there first.
private immutable string[string] prerequisites;

shared static this()
{
    prerequisites = ["Conflagrate": "Immolate", "Swiftmend": "Rejuvenation"];
}

/// What one spell's sweep came to.
struct Outcome
{
    bool ok;
    string why; /// the failure
}

/// One world per race and class, its characters one at a time.
private struct Sweeper
{
    RealWorld w;
    Choices choices;
    uint nextGuid = 1000;
    bool verbose;

    Outcome sweep(const Sweepable sw, ubyte race, ubyte classId, uint fishingBobber)
    {
        Outcome last;
        foreach (attempt; 0 .. 4) // a miss, a dodge, a resist: again (a fault fails every time)
        {
            last = once(sw, race, classId, fishingBobber);
            if (last.ok)
                break;
        }
        return last;
    }

    private Outcome once(const Sweepable sw, ubyte race, ubyte classId, uint fishingBobber)
    {
        import dmangos.world.spellcast : castTime, duration, range;

        auto context = w.context;
        auto map = context.map(0);
        const s = context.data.spells.spell(sw.id);
        string[] problems;
        void problem(string text) { problems ~= text; }

        const guid = nextGuid++;
        auto hero = w.character(guid, format!"Sweep%s"(guid), classId, 60, [sw.id], race);
        auto me = hero.session.inWorld;
        auto player = me.player;
        Creature[] spawned;
        TestClient[] friends;
        scope (exit)
        {
            foreach (c; spawned)
                if (map.findObject(c.guid) !is null)
                    map.removeObject(c.guid);
            hero.write(Opcode.CMSG_LOGOUT_REQUEST, null);
            foreach (ref f; friends)
                f.write(Opcode.CMSG_LOGOUT_REQUEST, null);
        }
        player.movement.position.orientation = 0; // facing east, where the enemy stands
        // Its weapon skills and defense at their greatest, as a level 60 character's who trained them.
        foreach (skill; weaponSkills)
            player.setSkill(skill, 300, 300);

        // Its form or stance (the lowest the mask names), then stealth.
        enum uint allowWhileNotShapeshifted = 0x80000;
        if (s.stances && !(s.attributesEx2 & allowWhileNotShapeshifted))
        {
            import core.bitop : bsf;

            const form = cast(ubyte)(bsf(s.stances) + 1);
            if (const shift = form in choices.formSpell)
                me.castSpell(context.data.spells.spell(*shift), SpellTargets(TargetFlags.self, 0), true, 0);
            if (player.values.getByte!UNIT_FIELD_BYTES_1(2) != form)
                problem(format!"no form %s"(form));
        }
        enum uint onlyStealthed = 0x20000;
        if (s.attributes & onlyStealthed)
        {
            const stealth = classId == 11 ? "Prowl" : "Stealth";
            if (const id = stealth in choices.firstRankByName)
                me.castSpell(context.data.spells.spell(*id), SpellTargets(TargetFlags.self, 0), true, 0);
        }
        // What it needs worn: its weapon (or shield), a weapon in the main hand, ammunition.
        enum uint requiresMainHand = 0x400;
        if (s.equippedItemClass >= 0)
            if (!wear(hero, s.equippedItemClass, s.equippedItemSubClassMask, classId, race))
                problem(format!"no item of class %s, subclasses %#x to wear"(s.equippedItemClass,
                    s.equippedItemSubClassMask));
        if ((s.casting.attributesEx3 & requiresMainHand) && player.inventory.equipped(15) is null)
            wear(hero, 2, 0x1 | 0x80 | 0x8000, classId, race); // an axe, a sword, a dagger
        if (fishingBobber)
            return problems.length ? Outcome(false, joinProblems(problems)) : fish(hero, *s, fishingBobber);
        // Reagents, tools, a spell focus beside it.
        foreach (i, reagent; s.reagents)
            if (reagent > 0)
                me.storeLoot(reagent, max(1, s.casting.reagentCount[i]), 0, false);
        foreach (tool; s.casting.totems)
            if (tool)
                me.storeLoot(tool, 1, 0, false);
        if (s.casting.requiresSpellFocus)
        {
            if (const entry = choices.focusObject(s.casting.requiresSpellFocus))
            {
                auto at = player.position;
                at.y += 2;
                context.spawnEditor.spawnGameObjectAt(map, entry, at, false);
            }
        }

        // Its target: a hostile creature in range (its back to the caster), or a friend.
        const isHostile = hostile(*s), isFriendly = friendly(*s) || raises(*s);
        ulong enemy, friend;
        if (isHostile || Character.usesComboPoints(*s))
        {
            const entry = choices.enemyFor(*s);
            if (!entry)
                return Outcome(false, "no creature to target");
            const r = range(*s, context.client);
            const distance = r[1] <= 5 ? 2.0f : min(r[0] + 3, r[1] - 1);
            auto at = player.position;
            at.x += distance;
            at.orientation = 0; // its back to the caster
            auto creature = context.summonCreature(map, entry, at, TempSpawnType.manual, 0, 0);
            spawned ~= creature;
            enemy = creature.guid;
            hero.read();
            // Skinning: it is dead, looted, its skin on, and the caster skilled enough.
            if (s.hasEffect(SpellEffect.skinning))
            {
                import dmangos.world.unit : Blow, dealDamage;

                dealDamage(UnitRef.of(me), map.unitOf(creature), creature.values.get!UNIT_FIELD_HEALTH, Blow.spell());
                creature.loot = null;
                creature.values.set!UNIT_FIELD_FLAGS(creature.values.get!UNIT_FIELD_FLAGS | Creature.unitFlagSkinnable);
                player.setSkill(creature.skinningSkill, 300, 300);
                hero.read();
            }
        }
        if (isFriendly)
        {
            const friendGuid = nextGuid++;
            friends ~= w.character(friendGuid, format!"Sweep%s"(friendGuid), classId, 60, [], race);
            auto other = friends[$ - 1].session.inWorld;
            other.player.movement.position = player.position;
            other.player.movement.position.y += 3;
            friend = other.player.guid;
            if (raises(*s)) // a resurrection: of the dead
            {
                import dmangos.world.unit : Blow;

                other.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
                friends[$ - 1].read();
            }
        }
        // Its pet: a demon summoned, a beast tamed; and a pet's own spell, taught to it.
        const petSpell = s.casting.powerType == Power.focus;
        Creature pet;
        if (needsPet(*s) || petSpell)
        {
            pet = makePet(hero, classId);
            if (pet is null)
                return Outcome(false, "no pet");
            if (petSpell)
                pet.petData.learn(sw.id, false, false);
            hero.read();
        }
        // What must be on its target first (`TargetAuraState` and the class rules): a Conflagrate's Immolate.
        if (const first = s.casting.name in prerequisites)
            if (const id = *first in choices.firstRankByName)
                me.castSpell(context.data.spells.spell(*id), SpellTargets(TargetFlags.unit, enemy ? enemy : friend),
                    true, 0);
        // Its combo points; the states it needs (the client asks them; the server keeps them).
        if (Character.usesComboPoints(*s))
            me.addComboPoints(enemy, 5);
        if (s.casterAuraState)
        {
            import dmangos.world.aurastate : AuraState;

            me.modifyAuraState(cast(AuraState) s.casterAuraState, true);
        }
        enum uint healthless20Percent = 2;
        if (s.casting.targetAuraState == healthless20Percent && enemy)
        {
            auto creature = map.creatureAt(enemy);
            creature.values.set!UNIT_FIELD_HEALTH(creature.values.get!UNIT_FIELD_MAXHEALTH / 10);
        }
        // Hurt where it heals; drained where it gives power.
        foreach (i; 0 .. 3)
        {
            const who = whoOf(*s, i, friend != 0);
            auto unit = unitOf(who, me, map, enemy, friend);
            if (!unit)
                continue;
            auto fields = unit.fields;
            with (SpellEffect) switch (s.effect[i])
            {
            case heal, healMaxHealth:
                fields.set!UNIT_FIELD_HEALTH(fields.get!UNIT_FIELD_MAXHEALTH / 2);
                break;
            case energize:
                if (s.miscValue[i] >= 0 && s.miscValue[i] < 5)
                    fields.set!UNIT_FIELD_POWER1(s.miscValue[i], fields.get!UNIT_FIELD_MAXPOWER1(s.miscValue[i]) / 2);
                break;
            default:
                break;
            }
        }
        // The caster's power full again (a form changed it).
        foreach (power; 0 .. 5)
        {
            bool given;
            foreach (i; 0 .. 3)
                given |= s.effect[i] == SpellEffect.energize && s.miscValue[i] == power;
            if (!given)
                player.values.set!UNIT_FIELD_POWER1(power, player.values.get!UNIT_FIELD_MAXPOWER1(power));
        }
        hero.read();

        // Its item to enchant (`TARGET_FLAG_ITEM`): one of the class it names worn (else a weapon), or in the bags.
        enum uint itemTarget = 0x10;
        ulong itemGuid;
        if ((s.casting.targets & itemTarget) && !s.hasEffect(SpellEffect.openLock))
        {
            const itemClass = s.equippedItemClass >= 0 ? s.equippedItemClass : 2;
            const mask = s.equippedItemClass >= 0 ? s.equippedItemSubClassMask : 0;
            if (const worn = wornOf(player, itemClass, mask))
                itemGuid = worn.fullGuid;
            else if (wear(hero, itemClass, mask, classId, race))
                itemGuid = wornOf(player, itemClass, mask).fullGuid;
            else
                return Outcome(false, format!"no item of class %s, subclasses %#x to enchant"(itemClass, mask));
        }
        // What a dispel takes away: an aura of its type on its target (a friend's curse, an enemy's blessing).
        foreach (i; 0 .. 3)
            if (s.effect[i] == SpellEffect.dispel)
                if (auto unit = unitOf(whoOf(*s, i, friend != 0), me, map, enemy, friend))
                    if (const aura = choices.dispellable(s.miscValue[i], unit.combatGuid != enemy))
                        putAura(me, unit, aura);

        // Who each effect is at; what there is before.
        UnitRef unitFor(size_t i)
        {
            const who = whoOf(*s, i, friend != 0);
            return petSpell && who == Who.caster ? map.unitOf(pet) : unitOf(who, me, map, enemy, friend);
        }
        const targetUnit = enemy ? enemy : friend;
        SpellTargets targets;
        enum uint destLocation = 0x40;
        if (itemGuid)
        {
            targets.mask = TargetFlags.item;
            targets.item = itemGuid;
        }
        else if (targetUnit)
            targets = SpellTargets(TargetFlags.unit, targetUnit);
        else
            targets = SpellTargets(TargetFlags.self, 0);
        if (s.casting.targets & destLocation)
        {
            const at = targetUnit ? map.unit(targetUnit).position : player.position;
            targets.mask |= TargetFlags.destLocation;
            targets.dest = [at.x, at.y, at.z];
        }
        if (targetUnit) // selected, as the client does (an auto-repeating shot shoots at the selection)
        {
            import dmangos.world.packets : ClientGuid;

            hero.write(Opcode.CMSG_SET_SELECTION, ClientGuid(targetUnit));
            hero.read();
        }
        const powerType = s.casting.powerType;
        const powerBefore = powerType < 5 ? player.values.get!UNIT_FIELD_POWER1(powerType) : 0;
        const healthBefore = player.values.get!UNIT_FIELD_HEALTH;
        const placeBefore = player.position;
        uint[3] itemsBefore;
        foreach (i; 0 .. 3)
            if (s.effect[i] == SpellEffect.createItem && s.itemType[i])
                itemsBefore[i] = player.inventory.count(s.itemType[i]);
        uint[3] healthOf, powerOf;
        bool[3] dispellableBefore;
        // What each aura on a player should change (`auraMeasure`), before it: NaN where the sweep has no measure.
        float[3] measuredBefore = float.nan;
        foreach (i; 0 .. 3)
            if (s.effect[i] == SpellEffect.applyAura || s.effect[i] == SpellEffect.applyAreaAuraParty)
                if (auto unit = unitFor(i))
                    measuredBefore[i] = auraMeasureOn(unit, cast(AuraType) s.casting.applyAuraName[i], s.miscValue[i]);
        foreach (i; 0 .. 3)
            if (auto unit = unitFor(i))
            {
                healthOf[i] = unit.fields.get!UNIT_FIELD_HEALTH;
                const power = s.effect[i] == SpellEffect.energize ? s.miscValue[i] : 0;
                if (power >= 0 && power < 5)
                    powerOf[i] = unit.fields.get!UNIT_FIELD_POWER1(power);
                if (s.effect[i] == SpellEffect.dispel)
                    dispellableBefore[i] = hasDispellable(unit, s.miscValue[i]);
            }
        const comboBefore = me.comboPoints;
        const comboPointsUsed = Character.usesComboPoints(*s) ? me.comboPoints : 0;

        SpellCastResult result;
        if (petSpell)
        {
            // Its owner orders it (`CMSG_PET_ACTION`); what it refuses is not told as a cast result.
            import dmangos.bytes : ByteWriter;
            import dmangos.world.pet : actionButton, ActiveState;

            ByteWriter order;
            order.put(pet.guid);
            order.put(actionButton(sw.id, ActiveState.enabled));
            order.put(targetUnit);
            hero.write(Opcode.CMSG_PET_ACTION, order.data);
            result = pet.petData.knows(sw.id) ? SpellCastResult.ok : SpellCastResult.notKnown;
        }
        else
            result = me.castSpell(s, targets, sw.triggered, 0);
        if (result != SpellCastResult.ok)
        {
            problems ~= format!"refused: %s"(result);
            return Outcome(false, joinProblems(problems));
        }
        // Heroic Strike and the like go with the next swing: the caster swings.
        if (isNextMeleeSwingSpell(*s) && enemy)
        {
            import dmangos.world.packets : ClientGuid;

            hero.write(Opcode.CMSG_ATTACKSWING, ClientGuid(enemy));
        }

        // Time for the cast, the channel, the missile to fly; what was seen meanwhile.
        int[ulong][3] auraSeen; // effect -> unit -> the aura's full duration
        bool[3] triggeredSeen, resurrectAsked, summonSeen;
        uint leastOwnHealth = healthBefore;
        uint[3] leastHealth = healthOf, mostHealth = healthOf, mostPower = powerOf, leastPower = powerOf;
        uint leastOwnPower = powerBefore;
        bool coolingDown, comboAdded;
        SpellCastResult failedLater; // a failure reported after the cast began
        bool hasFailedLater;
        const total = castTime(*s, context.client, 60) + 3500
            + ((s.attributesEx & 0x44) ? min(10_000, max(0, duration(*s, context.client, 60))) : 0);
        for (int t = 0; t <= total; t += 100)
        {
            if (t)
            {
                w.now += 100.msecs;
                me.update(100.msecs);
            }
            foreach (p; hero.read())
                if (p.opcode == Opcode.SMSG_CAST_RESULT && p.body_.length >= 6 && p.body_[4] != 0
                        && (cast(const(uint)[]) p.body_[0 .. 4])[0] == sw.id && !hasFailedLater)
                {
                    hasFailedLater = true;
                    failedLater = cast(SpellCastResult) p.body_[5];
                }
                else if (verbose && (t < 300 || p.opcode.among(Opcode.SMSG_SPELL_GO, Opcode.SMSG_CAST_RESULT,
                        Opcode.SMSG_SPELL_FAILURE)))
                    imported!"std.stdio".stderr.writefln("  %s: %s %(%02x %)", t, cast(Opcode) p.opcode,
                        p.opcode == Opcode.SMSG_SPELLLOGMISS || p.opcode == Opcode.SMSG_CAST_RESULT ? p.body_ : null);
            foreach (ref f; friends)
                foreach (p; f.read())
                    if (p.opcode == Opcode.SMSG_RESURRECT_REQUEST)
                        resurrectAsked[] = true;
            foreach (i; 0 .. 3)
            {
                auto unit = unitFor(i);
                if (s.effect[i] == SpellEffect.triggerSpell && s.triggerSpell[i])
                    foreach (other; [UnitRef.of(me), map.unit(enemy), map.unit(friend), pet ? map.unitOf(pet)
                            : UnitRef.init])
                        if (other && other.auraSet && other.auraSet.find(s.triggerSpell[i]))
                            triggeredSeen[i] = true;
                if (!unit)
                    continue;
                if (auto set = unit.auraSet)
                    if (auto aura = set.find(sw.id))
                        auraSeen[i][unit.combatGuid] = aura.maxDuration;
                const health = unit.fields.get!UNIT_FIELD_HEALTH;
                leastHealth[i] = min(leastHealth[i], health);
                mostHealth[i] = max(mostHealth[i], health);
                const power = s.effect[i] == SpellEffect.energize ? s.miscValue[i] : 0;
                if (power >= 0 && power < 5)
                {
                    mostPower[i] = max(mostPower[i], unit.fields.get!UNIT_FIELD_POWER1(power));
                    leastPower[i] = min(leastPower[i], unit.fields.get!UNIT_FIELD_POWER1(power));
                }
            }
            if (powerType < 5)
                leastOwnPower = min(leastOwnPower, player.values.get!UNIT_FIELD_POWER1(powerType));
            leastOwnHealth = min(leastOwnHealth, player.values.get!UNIT_FIELD_HEALTH);
            foreach (i; 0 .. 3) // what it summons may not last (a trap springs at once)
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    summonSeen[i] = summonsObject(s.effect[i]) ? objectNear(map, placeBefore, s.miscValue[i])
                        : summonsCreature(s.effect[i]) && summoned(map, placeBefore, s.miscValue[i]);
            coolingDown |= !me.spellIsReady(sw.id);
            comboAdded |= me.comboPoints > comboBefore;
        }

        if (hasFailedLater)
        {
            problems ~= format!"refused: %s"(failedLater);
            return Outcome(false, joinProblems(problems));
        }
        // Each effect.
        foreach (i; 0 .. 3)
        {
            const effect = s.effect[i];
            if (effect == SpellEffect.none)
                continue;
            const who = whoOf(*s, i, friend != 0);
            auto unit = unitFor(i);
            const unitGuid = unit ? unit.combatGuid : 0;
            with (SpellEffect) switch (effect)
            {
            case schoolDamage, weaponDamage, weaponDamageNoschool, normalizedWeaponDmg, weaponPercentDamage,
                    healthLeech, environmentalDamage:
                if (unit && leastHealth[i] >= healthOf[i])
                    problem(format!"effect %s (%s): no damage to the %s"(i, effect, who));
                break;
            case heal, healMaxHealth:
                if (unit && mostHealth[i] <= healthOf[i])
                    problem(format!"effect %s (%s): no health to the %s"(i, effect, who));
                break;
            case applyAura, applyAreaAuraParty, persistentAreaAura:
                if (!unit)
                    break;
                auto seen = unitGuid in auraSeen[i];
                if (s.id == 5246 && i != 0)
                {
                    if (seen !is null)
                        problem("Intimidating Shout's primary target also received the area aura");
                    break;
                }
                if (seen is null)
                {
                    if (effect == persistentAreaAura && leastHealth[i] < healthOf[i])
                        break; // its area hurt the enemy, though its aura comes and goes between ticks
                    problem(format!"effect %s (%s %s): no aura on the %s"(i, effect, s.casting.applyAuraName[i], who));
                    break;
                }
                // What it does, where the sweep measures it: still on, the value moved the way its amount says.
                import std.math : isNaN;

                if (!isNaN(measuredBefore[i]) && effect != persistentAreaAura)
                    if (auto on = unit.kind == UnitKind.player ? unit.session.player.auras.find(s.id)
                            : unit.kind == UnitKind.creature ? unit.creature.auras.find(s.id) : null)
                    {
                        if (isImmunityMeasure(cast(AuraType) s.casting.applyAuraName[i]))
                        {
                            // An immunity whatever its amount: not immune before (else nothing to see), immune now.
                            const now = auraMeasureOn(unit, cast(AuraType) s.casting.applyAuraName[i], s.miscValue[i]);
                            if (measuredBefore[i] == 0 && now != 1)
                                problem(format!"effect %s (%s %s): on the %s, but it is not immune (misc %s)"(i, effect,
                                    s.casting.applyAuraName[i], who, s.miscValue[i]));
                        }
                        else if (on.amount[i] != 0)
                        {
                            const now = auraMeasureOn(unit, cast(AuraType) s.casting.applyAuraName[i], s.miscValue[i]);
                            // (A resistance of none goes no lower: Curse of the Elements at a creature without one.)
                            // (A negative `MOD_SPEED_ALWAYS` slows nothing either: CMaNGOS's `UpdateSpeed`.)
                            const auraKind = cast(AuraType) s.casting.applyAuraName[i];
                            const floor = (auraKind == AuraType.modResistance && on.amount[i] < 0 && measuredBefore[i] <= 0)
                                || (auraKind == AuraType.modSpeedAlways && on.amount[i] < 0);
                            if (!floor && (on.amount[i] > 0 ? now <= measuredBefore[i] : now >= measuredBefore[i]))
                                problem(format!"effect %s (%s %s): on the %s, but %s did not move by %s (still %s)"(i,
                                    effect, s.casting.applyAuraName[i], who, auraMeasureName(
                                    cast(AuraType) s.casting.applyAuraName[i]), on.amount[i], now));
                        }
                    }
                const expected = expectedDuration(*s, context.client, comboPointsUsed);
                // A persistent area's lasts what the area has left as one comes in (its first tick's).
                const early = effect == persistentAreaAura ? 2 * max(1000, s.casting.amplitude[i]) + 100 : 0;
                if (expected != 0 && (*seen > expected || *seen < expected - early) && !(s.attributesEx & 0x44))
                    problem(format!"effect %s: lasts %s ms, not %s"(i, *seen, expected));
                break;
            case addComboPoints:
                if (!comboAdded)
                    problem(format!"effect %s: no combo point"(i));
                break;
            case energize:
                if (unit && mostPower[i] <= powerOf[i])
                    problem(format!"effect %s: no power %s to the %s"(i, s.miscValue[i], who));
                break;
            case powerBurn, powerDrain:
                if (unit && s.miscValue[i] == 0 && leastPower[i] >= powerOf[i] && powerOf[i] > 0)
                    problem(format!"effect %s (%s): no mana taken from the %s"(i, effect, who));
                break;
            case createItem:
                uint usedUp; // the same item as a reagent (The Mortar: Reloaded makes a mortar of one)
                foreach (k, reagent; s.reagents)
                    if (reagent == s.itemType[i])
                        usedUp += s.casting.reagentCount[k];
                if (s.itemType[i] && player.inventory.count(s.itemType[i]) + usedUp <= itemsBefore[i])
                    problem(format!"effect %s: no item %s made"(i, s.itemType[i]));
                break;
            case summon, summonWild, summonGuardian, summonPet, summonTotem, summonTotemSlot1, summonTotemSlot2,
                    summonTotemSlot3, summonTotemSlot4, summonPossessed, summonCritter, summonPhantasm:
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    problem(format!"effect %s (%s): no creature %s"(i, effect, s.miscValue[i]));
                break;
            case summonObjectWild, transDoor, summonObjectSlot1, summonObjectSlot2, summonObjectSlot3,
                    summonObjectSlot4:
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    problem(format!"effect %s (%s): no object %s"(i, effect, s.miscValue[i]));
                else if (effect == transDoor)
                    if (const why = useSpellCaster(hero, s.miscValue[i]))
                        problem(format!"effect %s: %s"(i, why));
                break;
            case triggerSpell:
                const triggered = context.data.spells.spell(s.triggerSpell[i]);
                if (triggered !is null && triggered.hasEffect(applyAura) && !triggeredSeen[i])
                    problem(format!"effect %s: no aura of the spell it triggers (%s)"(i, s.triggerSpell[i]));
                break;
            case teleportUnits, leap, charge:
                const now = player.position;
                if (player.data.map == 0 && now.x == placeBefore.x && now.y == placeBefore.y && now.z == placeBefore.z)
                    problem(format!"effect %s (%s): the caster did not move"(i, effect));
                break;
            case resurrect, resurrectNew:
                if (!resurrectAsked[i])
                    problem(format!"effect %s (%s): no resurrection offered"(i, effect));
                break;
            case instantKill:
                if (unit && unit.alive)
                    problem(format!"effect %s: the %s lives"(i, who));
                break;
            case dispel:
                if (unit && dispellableBefore[i] && hasDispellable(unit, s.miscValue[i]))
                    problem(format!"effect %s: nothing of dispel type %s taken from the %s"(i, s.miscValue[i], who));
                else if (unit && !dispellableBefore[i])
                    problem(format!"effect %s: no aura of dispel type %s to take (the sweep's)"(i, s.miscValue[i]));
                break;
            case enchantItem, enchantItemTemporary:
                if (itemGuid)
                {
                    const item = player.inventory.byGuid(itemGuid);
                    const slot = effect == enchantItem ? 0 : 1;
                    if (item is null || !item.enchantment(slot))
                        problem(format!"effect %s (%s): the item is not enchanted"(i, effect));
                }
                break;
            default:
                break;
            }
        }

        // What it costs, its cooldown (one that starts as its aura ends: then, and the client told).
        if (!sw.triggered && !petSpell)
        {
            const cost = me.costOf(*s);
            const givesItsPower = s.hasEffect(SpellEffect.energize);
            if (cost > 0 && powerType < 5 && !givesItsPower && leastOwnPower > powerBefore - min(cost, powerBefore))
                problem(format!"cost %s of power %s not paid"(cost, powerType));
            if (s.casting.powerType == uint.max - 1 && cost > 0 && leastOwnHealth >= healthBefore
                    && !s.hasEffect(SpellEffect.heal))
                problem(format!"cost %s health not paid"(cost));
            const hasCooldown = s.recoveryTime > 0 || (s.category && s.categoryRecoveryTime > 0);
            if (hasCooldown && !coolingDown)
                problem("no cooldown");
            enum uint cooldownOnEvent = 0x02000000;
            if (hasCooldown && (s.attributes & cooldownOnEvent))
                if (auto aura = player.auras.find(sw.id))
                {
                    me.removeAura(aura);
                    if (!hero.read().canFind!(p => p.opcode == Opcode.SMSG_COOLDOWN_EVENT))
                        problem("its aura gone, no SMSG_COOLDOWN_EVENT");
                    if (me.spellIsReady(sw.id))
                        problem("its aura gone, no cooldown");
                }
        }
        if (verbose)
            imported!"std.stdio".stderr.writefln("%s %s (class %s, race %s): %s", sw.id, s.casting.name, classId, race,
                problems.length ? joinProblems(problems) : "ok");
        return problems.length ? Outcome(false, joinProblems(problems)) : Outcome(true, null);
    }

    /// Casts from a bank near Stormwind, then uses the owned bobber when the client sees the bite.
    private Outcome fish(ref TestClient hero, const ref SpellInfo spell, uint fishingBobber)
    {
        import dmangos.bytes : ByteReader, ByteWriter;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.packets : ClientGuid, ClientTeleportAck;
        import dmangos.world.spellcast : castTime, duration;
        import dmangos.world.terrain : invalidHeight;

        auto me = hero.session.inWorld;
        auto player = me.player;
        auto map = w.context.map(0);
        enum float bankX = -9083, bankY = 537;
        const bank = Position(bankX, bankY, map.groundHeight(bankX, bankY, 88.5f, false), 0);
        if (bank.z <= invalidHeight)
            return Outcome(false, "the fishing fixture requires the extracted terrain near Stormwind");
        if (!me.teleportTo(0, bank, null, uint.max, true))
            return Outcome(false, "could not reach the fishing fixture");
        hero.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(player.guid, 0, 0));
        hero.read();
        enum uint skillFishing = 356;
        player.setSkill(skillFishing, 300, 300);

        ByteWriter castRequest;
        castRequest.put(spell.id);
        SpellTargets(TargetFlags.self).write(castRequest);
        hero.write(Opcode.CMSG_CAST_SPELL, castRequest.data);

        const limitMs = castTime(spell, w.context.client, player.data.level)
            + duration(spell, w.context.client, player.data.level);
        GameObject bobber;
        for (int elapsed; elapsed <= limitMs; elapsed += 100)
        {
            if (bobber is null && player.values.get!UNIT_CHANNEL_SPELL == spell.id)
            {
                bobber = cast(GameObject) map.findObject(player.values.get!UNIT_FIELD_CHANNEL_OBJECT);
                if (bobber is null || bobber.owner != player.guid || bobber.spawn.entry != fishingBobber)
                    return Outcome(false, "the fishing channel has no owned bobber");
                const at = bobber.position;
                float surface;
                if (!map.waterAt(at.x, at.y, at.z, surface) || at.z != surface)
                    return Outcome(false, "the bobber is off the water surface");
            }
            foreach (packet; hero.read())
            {
                auto payload = ByteReader(packet.body_);
                if (packet.opcode == Opcode.SMSG_CAST_RESULT && payload.read!uint() == spell.id && payload.read!ubyte())
                    return Outcome(false, format!"fishing refused: %s"(cast(SpellCastResult) payload.read!ubyte()));
                if (bobber is null || packet.opcode != Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM
                    || payload.read!ulong() != bobber.guid)
                    continue;
                hero.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(bobber.guid));
                enum size_t lootItemCountOffset = ulong.sizeof + ubyte.sizeof + uint.sizeof; // GUID, type and gold
                foreach (reply; hero.read())
                    if (reply.opcode == Opcode.SMSG_LOOT_RESPONSE && reply.body_.length > lootItemCountOffset
                            && reply.body_[lootItemCountOffset] > 0)
                    {
                        if (verbose)
                            imported!"std.stdio".stderr.writefln("%s %s: cast, bite and catch verified", spell.id,
                                spell.casting.name);
                        return Outcome(true, null);
                    }
                return Outcome(false, "using the bobber at the bite returned no fishing loot");
            }
            w.now += 100.msecs;
            me.update(100.msecs);
        }
        return Outcome(false, bobber is null ? "fishing produced no bobber" : "the bobber never signaled a bite");
    }

    /**
     * A spell caster object of `entry` near the caster (a mage's portal, a Lightwell) used by it: its spell's
     * aura on it, or it taken away; what is wrong, else null.
     */
    private string useSpellCaster(ref TestClient hero, int entry)
    {
        import dmangos.world.gameobject : GameObject, GameObjectType;
        import dmangos.world.packets : ClientGuid;

        auto me = hero.session.inWorld;
        const t = cast(uint) entry in w.context.data.gameObjectTemplates;
        if (t is null || t.type != GameObjectType.spellCaster)
            return null;
        GameObject found;
        foreach (o; w.context.map(0).objectsNear(me.player.position, 40))
            if (auto go = cast(GameObject) o)
                if (go.values.get!OBJECT_FIELD_ENTRY == entry)
                    found = go;
        if (found is null)
            return "its object gone";
        const spell = w.context.data.spells.spell(t.data[0]);
        if (spell is null)
            return null;
        me.player.movement.position = found.position; // walked up to it
        const before = me.player.position;
        const mapBefore = me.player.data.map;
        hero.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(found.guid));
        hero.read();
        bool given = me.player.auras.find(spell.id) !is null;
        foreach (step; 0 .. 20) // a teleport's cast time
        {
            w.now += 500.msecs;
            me.update(500.msecs);
            hero.read();
            given |= me.player.auras.find(spell.id) !is null;
        }
        const after = me.player.position;
        const moved = me.player.data.map != mapBefore || after.x != before.x || after.y != before.y;
        if (spell.hasEffect(SpellEffect.applyAura) && !given && !moved)
            return format!"used, no aura of its spell %s"(spell.id);
        if (!spell.hasEffect(SpellEffect.applyAura) && !moved)
            return format!"used, its spell %s took no one away"(spell.id);
        return null;
    }

    /// A pet for the caster: a warlock's Imp summoned, a hunter's beast tamed; null for another class.
    private Creature makePet(ref TestClient hero, ubyte classId)
    {
        enum uint summonImp = 688;
        auto me = hero.session.inWorld;
        auto context = w.context;
        auto map = context.map(0);
        if (classId == 9)
            me.castSpell(context.data.spells.spell(summonImp), SpellTargets(TargetFlags.self, 0), true, 0);
        else if (classId == 3)
        {
            import dmangos.world.pethandlers : spellTameBeast;

            const entry = choices.enemyFor(*context.data.spells.spell(spellTameBeast));
            if (!entry)
                return null;
            auto at = me.player.position;
            at.y -= 3;
            auto beast = context.summonCreature(map, entry, at, TempSpawnType.manual, 0, 0);
            me.tameBeastChannelDone(beast.guid);
        }
        hero.read();
        auto pet = me.ownPet;
        if (pet !is null)
            foreach (power; 0 .. 5)
                pet.values.set!UNIT_FIELD_POWER1(power, pet.values.get!UNIT_FIELD_MAXPOWER1(power));
        return pet;
    }

    /// Takes an item of `itemClass` and `mask` the caster may wear and wears it; whether one is worn.
    private bool wear(ref TestClient hero, int itemClass, int mask, ubyte classId, ubyte race)
    {
        import dmangos.world.defines : inventorySlotBag0;
        import dmangos.world.inventory : itemSkill;
        import dmangos.world.packets : ClientItemPos;

        auto me = hero.session.inWorld;
        foreach (k, entry; choices.wearable(itemClass, mask, classId, race))
        {
            if (k == 8)
                break;
            // Its skill (a weapon's), as a character who trained it has.
            if (const skill = itemSkill(entry in choices.data.items))
                me.player.setSkill(skill, 300, 300);
            me.storeLoot(entry, 1, 0, false);
            foreach (ubyte slot; 23 .. 39)
                if (const item = me.player.inventory[inventorySlotBag0, slot])
                    if (item.entry == entry)
                    {
                        hero.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
                        break;
                    }
            hero.read();
            foreach (ubyte slot; 0 .. 19)
                if (const item = me.player.inventory.equipped(slot))
                    if (item.entry == entry)
                    {
                        wearAmmunition(hero, item.proto.subClass);
                        return true;
                    }
        }
        return false;
    }

    /// A bow's arrows, a gun's bullets: some in the bags, and chosen.
    private void wearAmmunition(ref TestClient hero, uint weaponSubClass)
    {
        enum uint bow = 2, gun = 3, crossbow = 18, projectile = 6, arrow = 2, bullet = 3;
        if (weaponSubClass != bow && weaponSubClass != gun && weaponSubClass != crossbow)
            return;
        auto me = hero.session.inWorld;
        const kind = weaponSubClass == gun ? bullet : arrow;
        const ammo = choices.wearable(projectile, 1 << kind, me.player.data.classId, me.player.data.race);
        if (!ammo.length)
            return;
        me.storeLoot(ammo[0], 200, 0, false);
        me.player.values.set!PLAYER_AMMO_ID(ammo[0]);
        hero.read();
    }
}

/// Defense, unarmed, and every weapon's skill (`SkillLine.dbc`).
private immutable uint[] weaponSkills = [95, 162, 173, 43, 55, 44, 172, 54, 160, 136, 229, 45, 46, 226, 176, 228, 473];

/// The unit `who` names.
private UnitRef unitOf(Who who, Character me, imported!"dmangos.world.map".Map map, ulong enemy, ulong friend)
{
    final switch (who)
    {
    case Who.nobody: return UnitRef.init;
    case Who.pet: return me.ownPet is null ? UnitRef.init : map.unitOf(me.ownPet);
    case Who.caster: return UnitRef.of(me);
    case Who.enemy: return enemy ? map.unit(enemy) : UnitRef.init;
    case Who.friend: return friend ? map.unit(friend) : UnitRef.init;
    }
}

/// The worn item of `itemClass` and one of the subclasses of `mask` (0: any); null if none.
private imported!"dmangos.world.inventory".Item wornOf(Player player, int itemClass, int mask)
{
    foreach (ubyte slot; 0 .. 19)
        if (auto item = player.inventory.equipped(slot))
            if (item.proto.itemClass == itemClass && (!mask || (mask & (1 << item.proto.subClass))))
                return item;
    return null;
}

/// Whether `unit` has an aura of dispel type `type`.
package bool hasDispellable(UnitRef unit, int type)
{
    if (auto set = unit.auraSet)
        foreach (aura; set.list)
            if (aura.spell.casting.dispel == type && !aura.passive)
                return true;
    return false;
}

/// `spell`'s aura put on `unit` by `me`, for a minute.
private void putAura(Character me, UnitRef unit, const(SpellInfo)* spell)
{
    import dmangos.world.auras : makeAura;
    import dmangos.world.spellcast : effectValue;

    const positive = !harms(*spell);
    auto aura = makeAura(spell, me.player.guid, 60, 60_000, positive,
        [effectValue(*spell, 0, 60, 0), effectValue(*spell, 1, 60, 0), effectValue(*spell, 2, 60, 0)]);
    if (unit.kind == imported!"dmangos.world.unit".UnitKind.player)
        unit.session.addAura(aura);
    else
    {
        bool isNew;
        unit.creature.auras.apply(aura, unit.creature.values, isNew);
    }
}

/// Whether `effect` summons a creature.
package bool summonsCreature(SpellEffect effect)
{
    with (SpellEffect)
        return effect.among(summon, summonWild, summonGuardian, summonPet, summonTotem, summonTotemSlot1,
            summonTotemSlot2, summonTotemSlot3, summonTotemSlot4, summonPossessed, summonCritter, summonPhantasm,
            summonDemon) != 0;
}

/// Whether `effect` summons a game object.
package bool summonsObject(SpellEffect effect)
{
    with (SpellEffect)
        return effect.among(summonObjectWild, transDoor, summonObjectSlot1, summonObjectSlot2, summonObjectSlot3,
            summonObjectSlot4) != 0;
}

/// Whether a game object of `entry` stands near `at`.
package bool objectNear(imported!"dmangos.world.map".Map map, Position at, int entry)
{
    import dmangos.world.gameobject : GameObject;

    foreach (o; map.objectsNear(at, 40))
        if (auto go = cast(GameObject) o)
            if (go.values.get!OBJECT_FIELD_ENTRY == entry)
                return true;
    return false;
}

/// Whether a creature of `entry` stands near `at`.
package bool summoned(imported!"dmangos.world.map".Map map, Position at, int entry)
{
    foreach (c; map.creaturesNear(at, 40))
        if (c.values.get!OBJECT_FIELD_ENTRY == entry)
            return true;
    return false;
}

/// How long the aura of `s` lasts, from its data alone (CMaNGOS's `CalculateSpellDuration`): its duration, toward
/// the greatest a fifth a combo point; 0: the data says nothing.
private int expectedDuration(const ref SpellInfo s, const ClientData client, uint comboPoints)
{
    const entry = client.spellDurations.lookup(s.casting.durationIndex);
    if (entry is null)
        return 0;
    if (entry.duration == -1)
        return -1;
    int value = entry.duration;
    if (comboPoints && entry.maximum > value)
        value += (entry.maximum - value) * cast(int) comboPoints / 5;
    return value;
}

private string joinProblems(string[] problems)
{
    import std.array : join;

    return problems.join("; ");
}

/// The known failures: spell id -> reason.
private string[uint] knownFailures()
{
    import std.conv : to;
    import std.file : exists, readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : indexOf, lineSplitter, strip;

    const path = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "..", "..", "tools", "harness",
        "realspell-known.txt");
    string[uint] known;
    if (!path.exists)
        return known;
    foreach (line; readText(path).lineSplitter)
    {
        const text = line.strip;
        if (!text.length || text[0] == '#')
            continue;
        const colon = text.indexOf(':');
        assert(colon > 0, "realspell-known.txt: id: reason, not " ~ text);
        known[text[0 .. colon].strip.to!uint] = text[colon + 1 .. $].strip;
    }
    return known;
}

/// The sweep.
unittest
{
    import std.algorithm.iteration : map, splitter;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.conv : to;
    import std.process : environment;
    import std.stdio : stderr;

    if (!haveRealData())
        return;
    auto first = RealWorld.make();
    const data = first.context.data;
    const client = first.context.client;
    auto spells = learnableSpells(data, client);
    const only = environment.get("DMANGOS_SWEEP_ONLY");
    if (only !is null)
    {
        const wanted = only.splitter(',').map!(x => x.to!uint).array;
        Sweepable[] picked;
        foreach (sw; spells)
            if (wanted.canFind(sw.id))
                picked ~= sw;
        spells = picked;
    }
    auto choices = new Choices(data, client, learnableSpells(data, client));
    Sweeper[uint] sweepers;
    string[uint] failed;
    size_t passed;
    foreach (sw; spells)
    {
        const s = data.spells.spell(sw.id);
        const caster = casterOf(data, client, *s, sw.classId);
        uint fishingBobber;
        foreach (i, effect; s.effect)
            if (effect == SpellEffect.transDoor && Character.isFishingBobber(cast(uint) s.miscValue[i] in data.gameObjectTemplates))
                fishingBobber = cast(uint) s.miscValue[i];
        const key = (fishingBobber ? 1u << 16 : 0u) | (cast(uint) caster[0] << 8) | caster[1];
        if (key !in sweepers)
        {
            auto world = fishingBobber ? RealWorld.make(20_261_120, true) : sweepers.length ? RealWorld.make() : first;
            sweepers[key] = Sweeper(world, choices, 1000, only !is null);
        }
        const outcome = sweepers[key].sweep(sw, caster[0], caster[1], fishingBobber);
        if (outcome.ok)
            ++passed;
        else
            failed[sw.id] = outcome.why;
    }
    const known = knownFailures();
    string[] news, fixed;
    foreach (id, why; failed)
        if (id !in known)
            news ~= format!"%s: %s (%s)"(id, why, data.spells.spell(id).casting.name);
    if (only is null)
        foreach (id, why; known)
            if (id !in failed)
                fixed ~= format!"%s (%s)"(id, why);
    news.sort();
    fixed.sort();
    stderr.writefln("realspellsweep: %s spells cast, %s as their data says, %s known failures (realspell-known.txt), "
        ~ "%s new", spells.length, passed, failed.length - news.length, news.length);
    foreach (line; fixed)
        stderr.writeln("realspellsweep: passes now, take it off realspell-known.txt: ", line);
    foreach (line; news)
        stderr.writeln("realspellsweep: FAILS: ", line);
    assert(!news.length, "a spell on the real data does not do what its data says (see above)");
}

/**
 * What an aura of `type` (its misc value `misc`) changes on `who`, as a number its amount moves: a stat, a
 * resistance, attack power, the maximum health, spell or healing power, the melee damage it takes. NaN where the
 * sweep has no measure of the type (most: an aura's being on is all it checks of them).
 */
float auraMeasure(Character who, AuraType type, int misc)
{
    import core.bitop : bsf;

    auto p = who.player;
    with (AuraType) switch (type)
    {
    case modStat:
        if (misc >= 0 && misc < 5)
            return p.stats.stats[misc];
        float all = 0;
        foreach (v; p.stats.stats)
            all += v;
        return all;
    case modResistance, modResistanceExclusive:
        return misc > 0 ? p.stats.resistances[bsf(misc)] : float.nan;
    case modAttackPower:
        return p.stats.attackPower;
    case modRangedAttackPower:
        return p.stats.rangedAttackPower;
    case modIncreaseHealth:
        return p.stats.maxHealth;
    case modDamageDone:
        return misc > 0 ? who.spellPower(misc) : float.nan;
    case modHealingDone:
        return who.healingPower();
    case modMeleeDamageTaken:
        return who.unit.fighter.meleeTakenFlat;
    case modCritPercent:
        return who.unit.fighter.crit;
    case modHitChance:
        return who.unit.fighter.hitBonus;
    case modDodgePercent:
        return who.unit.fighter.dodge;
    case modParryPercent:
        return who.unit.fighter.canParry ? who.unit.fighter.parry : float.nan;
    case modBlockPercent:
        return who.unit.fighter.canBlock ? who.unit.fighter.block : float.nan;
    case modDamagePercentDone: // its physical part only (a school's spells go another way)
        return misc & 1 ? who.unit.fighter.damageDone[0] : float.nan;
    case modDamageTaken:
        return misc > 0 ? who.unit.fighter.damageTakenFlat[bsf(misc)] : float.nan;
    case modDamagePercentTaken:
        return misc > 0 ? who.unit.fighter.damageTaken[bsf(misc)] : float.nan;
    case modIncreaseEnergy:
        return misc >= 0 && misc < 5 ? p.stats.maxPower[misc] : float.nan;
    case modIncreaseHealthPercent:
        return p.stats.maxHealth;
    case modPercentStat, modTotalStatPercentage:
        if (misc >= 0 && misc < 5)
            return p.stats.stats[misc];
        float sum = 0;
        foreach (v; p.stats.stats)
            sum += v;
        return sum;
    case modMeleeHaste, modAttackSpeed: // faster: less time between swings
        return -cast(float) p.stats.attackTime[0];
    case modIncreaseSpeed, modSpeedAlways, modSpeedNotStack, modDecreaseSpeed: // its run (Sprint, Hamstring)
    {
        import dmangos.world.movement : MoveType;

        return p.speeds[MoveType.run];
    }
    case schoolImmunity, mechanicImmunity, modMechanicResistance:
        return fighterMeasure(who.unit.fighter, type, misc);
    case modSkill, modSkillTalent: // a skill it has (a weapon's, a profession's): its value with bonuses
        return misc > 0 && p.skillSlot(misc) >= 0 ? p.skillWithBonus(misc) : float.nan;
    case modScale: // its size (Enlarge, a giant's growth)
    {
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        return p.values.get!OBJECT_FIELD_SCALE_X;
    }
    case modRangedHaste: // a ranged weapon's speed: none worn (Rapid Fire asks for none), nothing to see
    {
        import dmangos.world.defines : equipmentSlotRanged;

        return p.inventory.equipped(equipmentSlotRanged) is null ? float.nan : -cast(float) p.stats.attackTime[2];
    }
    default:
        return float.nan;
    }
}

/// `auraMeasure` for a player; for a creature (a debuff at the sweep's enemy), what its fighter and fields show.
float auraMeasureOn(UnitRef unit, AuraType type, int misc)
{
    import core.bitop : bsf;
    import dmangos.world.updatefields : UNIT_FIELD_BASEATTACKTIME, UNIT_FIELD_RESISTANCES;

    if (unit.kind == UnitKind.player)
        return auraMeasure(unit.session, type, misc);
    if (unit.kind != UnitKind.creature)
        return float.nan;
    auto c = unit.creature;
    const f = c.fighter;
    with (AuraType) switch (type)
    {
    case modResistance, modResistanceExclusive:
        return misc > 0 ? cast(int) c.values.get!UNIT_FIELD_RESISTANCES(bsf(misc)) : float.nan;
    case modDamagePercentTaken:
        return misc > 0 ? f.damageTaken[bsf(misc)] : float.nan;
    case modDamageTaken:
        return misc > 0 ? f.damageTakenFlat[bsf(misc)] : float.nan;
    case modScale:
    {
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        return c.values.get!OBJECT_FIELD_SCALE_X;
    }
    case schoolImmunity, mechanicImmunity, modMechanicResistance:
        return fighterMeasure(f, type, misc);
    case modHitChance:
        return f.hitBonus;
    case modCritPercent:
        return f.crit;
    case modMeleeHaste, modAttackSpeed: // slower: more time between swings (Thunder Clap)
        return -cast(float) c.values.get!UNIT_FIELD_BASEATTACKTIME(0);
    case modAttackPower: // its blows (Demoralizing Shout)
        return f.damage[0][1];
    case modDecreaseSpeed, modIncreaseSpeed: // its run (Hamstring, Frostbolt's chill)
    {
        import dmangos.world.movement : MoveType;

        return c.speeds[MoveType.run];
    }
    case modDamagePercentDone:
        return misc & 1 ? f.damageDone[0] : float.nan;
    case modDamageDone: // its physical blows' flat part (Curse of Weakness)
        return misc & 1 ? f.weaponDamageFlat[0] : float.nan;
    default:
        return float.nan;
    }
}

/// What `auraMeasure` measures of `type`, for the sweep's report.
/// The immunities the oracle checks as on or off (1 or 0), not by their amount (`fighterMeasure`).
bool isImmunityMeasure(AuraType type)
{
    return type == AuraType.schoolImmunity || type == AuraType.mechanicImmunity;
}

/// What a fighter shows of an immunity (1 immune to all of `misc`'s, 0 not) or of a mechanic's resist chance.
float fighterMeasure(F)(auto ref const F f, AuraType type, int misc)
{
    with (AuraType) switch (type)
    {
    case schoolImmunity:
        return misc > 0 ? ((f.immune.schools & misc) == misc ? 1 : 0) : float.nan;
    case mechanicImmunity:
        return misc > 0 && misc <= 32 ? ((f.immune.mechanics & (1u << (misc - 1))) ? 1 : 0) : float.nan;
    case modMechanicResistance:
        return misc > 0 && misc < f.mechanicResist.length ? f.mechanicResist[misc] : float.nan;
    default:
        return float.nan;
    }
}

string auraMeasureName(AuraType type)
{
    with (AuraType) switch (type)
    {
    case modStat: return "its stat";
    case modResistance, modResistanceExclusive: return "its resistance";
    case modAttackPower: return "its attack power";
    case modRangedAttackPower: return "its ranged attack power";
    case modIncreaseHealth: return "its maximum health";
    case modDamageDone: return "its spell power";
    case modHealingDone: return "its healing power";
    case modMeleeDamageTaken: return "its melee damage taken";
    case modCritPercent: return "its crit chance";
    case modHitChance: return "its hit chance";
    case modDodgePercent: return "its dodge chance";
    case modParryPercent: return "its parry chance";
    case modBlockPercent: return "its block chance";
    case modDamagePercentDone: return "its physical damage done";
    case modDamageTaken: return "its flat damage taken";
    case modDamagePercentTaken: return "its damage taken";
    case modIncreaseEnergy: return "its maximum power";
    case modIncreaseHealthPercent: return "its maximum health";
    case modPercentStat, modTotalStatPercentage: return "its stat";
    case modMeleeHaste, modAttackSpeed: return "its swing speed";
    case modRangedHaste: return "its ranged speed";
    case modIncreaseSpeed, modSpeedAlways, modSpeedNotStack, modDecreaseSpeed: return "its run speed";
    case modSkill, modSkillTalent: return "its skill";
    case modScale: return "its size";
    case schoolImmunity, mechanicImmunity: return "its immunity";
    case modMechanicResistance: return "its resistance to the mechanic";
    default: return "nothing";
    }
}
