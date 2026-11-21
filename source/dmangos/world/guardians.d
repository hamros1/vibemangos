/**
 * What a player's spells summon beside pets and totems (CMaNGOS's `Spell::EffectSummon`, `EffectSummonGuardian`,
 * `EffectSummonObjectWild`): guardians, and objects nobody owns.
 *
 * A guardian (`SPELL_EFFECT_SUMMON_GUARDIAN`: the engineers' dragonlings, target dummies, the Explosive Sheep, the
 * Battle Chicken; `SPELL_EFFECT_SUMMON`, one, and not while a pet is out) is a creature of the effect's entry with
 * its owner's faction, player-controlled and created by it (`UNIT_FIELD_SUMMONEDBY`, `UNIT_FIELD_CREATEDBY`,
 * `UNIT_CREATED_BY_SPELL`), for the spell's duration; as many as the effect's value, the first at the spell's
 * destination (others around it within the effect's radius) or two yards from the caster. It keeps its own AI (its
 * EventAI or script: a dummy's taunt, a sheep running at the enemy), follows its owner (`GuardianAI`: a yard and a
 * half to its left), and joins its owner's fight when it is not fighting (`getAttackerForHelper`). Its kills are
 * its owner's. Its level is its template's range clamped to the owner's level, or an engineering trinket's skill
 * divided by five; `SPELL_EFFECT_SUMMON`'s is the owner's own. Casting the spell again sends the guardians of its
 * entry away and summons none, unless the spell has a duration and a category (`FindGuardianWithEntry`). They go
 * with their owner off the map or out of the game; at its death those not fighting (`RemoveGuardians`).
 *
 * A wild object (`SPELL_EFFECT_SUMMON_OBJECT_WILD`: picnic blankets, firework launchers, quest objects) stands at the
 * destination or beside the caster, facing as it does, for the spell's duration (for good without one); it has no
 * owner, so anyone may use it.
 */
module dmangos.world.guardians;

/// `UNIT_BYTE2_FLAG_SUPPORTABLE | UNIT_BYTE2_FLAG_UNK5`: a guardian's misc flags (healable, its debuffs as a pet's).
enum ubyte guardianMiscFlags = 0x08 | 0x20;

/// Where a guardian follows: a yard and a half, a quarter turn left of its owner (`GuardianAI`).
enum float guardianFollowDistance = 1.5f, guardianFollowAngle = 1.5707964f;

/**
 * A guardian's level (`EffectSummonGuardian`): its template's `minLevel` .. `maxLevel` clamped to the owner's level,
 * or for an engineering trinket the owner's engineering skill divided by five.
 */
uint guardianLevel(uint ownerLevel, uint minLevel, uint maxLevel, bool engineeringTrinket, uint engineering)
    pure nothrow @nogc @safe
{
    if (engineeringTrinket && engineering)
        return engineering / 5;
    const capped = ownerLevel < maxLevel ? ownerLevel : maxLevel;
    return capped > minLevel ? capped : minLevel;
}

unittest
{
    assert(guardianLevel(30, 47, 47, false, 0) == 47, "a dragonling: its template's");
    assert(guardianLevel(60, 1, 1, false, 0) == 1, "the chicken");
    assert(guardianLevel(35, 30, 40, false, 0) == 35 && guardianLevel(50, 30, 40, false, 0) == 40);
    assert(guardianLevel(60, 47, 47, true, 225) == 45, "an engineering trinket: by the skill");
    assert(guardianLevel(60, 47, 47, true, 0) == 47);
}

/**
 * Whether casting a guardian's spell again, with guardians of its entry out, summons new ones after sending those away:
 * only a spell with both a duration and a category (one whose cooldown is shorter than its guardians' time).
 */
bool resummonsGuardians(uint durationIndex, uint category) pure nothrow @nogc @safe
{
    return durationIndex != 0 && category != 0;
}

unittest
{
    assert(!resummonsGuardians(0, 0) && !resummonsGuardians(3, 0) && resummonsGuardians(3, 4));
}

/// See the module documentation.
mixin template GuardianSummons()
{
    import std.math : cos, sin, sqrt;
    import std.random : uniform01;
    import dmangos.world.creature : Creature, TempSpawnType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.guardians : guardianFollowAngle, guardianFollowDistance, guardianLevel, guardianMiscFlags,
        resummonsGuardians;
    import dmangos.world.motion : FollowMovement;
    import dmangos.world.movement : Position;
    import dmangos.world.spellcast : duration, radius, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    private ulong[] guardians_; /// the guardians out (`m_guardianPets`)

    /// The guardians out and alive here.
    package Creature[] ownGuardians()
    {
        Creature[] found;
        foreach (guid; guardians_)
            if (auto c = cast(Creature) map.findObject(guid))
                if (c.alive)
                    found ~= c;
        return found;
    }

    /**
     * `SPELL_EFFECT_SUMMON_GUARDIAN` (`summonOne`: `SPELL_EFFECT_SUMMON`, one at the owner's level, none while a pet
     * is out): effect `i` of `spell`, `value` of them.
     */
    package void summonGuardianEffect(const(SpellInfo)* spell, size_t i, int value, const ref SpellTargets targets,
        bool triggered, uint castItemEntry, bool summonOne)
    {
        import dmangos.world.defines : InventoryType;

        const entry = cast(uint) spell.miscValue[i];
        const t = entry in context.data.creatureTemplates;
        if (t is null || (summonOne && ownPet !is null))
            return;
        // Cast again: the ones of its entry go, and unless it may summon anew, that is all.
        if (!summonOne && !triggered)
        {
            bool found;
            foreach (g; ownGuardians())
                if (g.template_.entry == entry)
                {
                    unsummonGuardian(g.guid);
                    found = true;
                }
            if (found && !resummonsGuardians(spell.casting.durationIndex, spell.category))
                return;
        }
        uint level = player.data.level;
        if (!summonOne)
        {
            enum uint skillEngineering = 202;
            const item = castItemEntry ? castItemEntry in context.data.items : null;
            const trinket = item !is null && item.requiredSkill == skillEngineering
                && item.inventoryType == InventoryType.trinket;
            level = guardianLevel(player.data.level, t.minLevel, t.maxLevel, trinket,
                trinket ? player.skillRank(skillEngineering) : 0);
        }
        const ms = modDuration(spell, duration(*spell, context.client, player.data.level));
        const count = summonOne ? 1 : value > 0 ? value : 1;
        const spread = radius(*spell, i, context.client);
        foreach (n; 0 .. count)
            makeGuardian(spell, entry, guardianSpot(targets, n, spread), level, ms);
    }

    /// Where guardian `n` stands: the first at the destination, the others around it within `spread`; without one,
    /// two yards from the caster.
    private Position guardianSpot(const ref SpellTargets targets, int n, float spread)
    {
        const me = player.position;
        if (!(targets.mask & TargetFlags.destLocation))
        {
            auto at = Position(me.x + 2 * cos(me.orientation), me.y + 2 * sin(me.orientation), me.z, me.orientation);
            const ground = map.groundHeight(at.x, at.y, me.z + 2, false);
            if (ground > -100_000 && (ground - at.z) ^^ 2 < 25)
                at.z = ground;
            return at;
        }
        auto at = Position(targets.dest[0], targets.dest[1], targets.dest[2], me.orientation);
        if (n > 0 && spread > 0)
        {
            import std.math : PI;

            const angle = uniform01(map.random) * 2 * PI, d = sqrt(uniform01(map.random)) * spread;
            at.x += d * cos(angle);
            at.y += d * sin(angle);
            const ground = map.groundHeight(at.x, at.y, at.z + 2, false);
            if (ground > -100_000)
                at.z = ground;
        }
        return at;
    }

    /// One guardian of `entry` at `at`, for `ms` (0: until it dies).
    private void makeGuardian(const(SpellInfo)* spell, uint entry, Position at, uint level, int ms)
    {
        auto g = context.summonCreature(map, entry, at, ms > 0 ? TempSpawnType.timedOrCorpse : TempSpawnType.corpse,
            ms > 0 ? ms : 0, player.guid);
        if (g is null)
            return;
        if (level != g.values.get!UNIT_FIELD_LEVEL)
            context.setCreatureLevel(g, level);
        auto v = &g.values;
        const faction = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        v.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
        g.factionTemplate = context.client.factionTemplates.lookup(faction);
        enum uint copied = UnitFlags.playerControlled | UnitFlags.pvp | UnitFlags.immuneToPlayer | UnitFlags.immuneToNpc;
        v.set!UNIT_FIELD_FLAGS(g.template_.unitFlags | (player.values.get!UNIT_FIELD_FLAGS & copied));
        v.set!UNIT_NPC_FLAGS(g.template_.npcFlags);
        v.set!UNIT_CREATED_BY_SPELL(spell.id);
        v.set!UNIT_FIELD_SUMMONEDBY(player.guid);
        v.set!UNIT_FIELD_CREATEDBY(player.guid);
        v.setByte!UNIT_FIELD_BYTES_2(1, guardianMiscFlags);
        g.guardianOwner = player.guid;
        g.controllerPlayerFlags = player.values.get!PLAYER_FLAGS;
        g.generator = new FollowMovement(player.guid, guardianFollowDistance, guardianFollowAngle);
        map.flushObjectChanges(g);
        guardians_ ~= g.guid;
    }

    /// The guardian `guid` goes.
    private void unsummonGuardian(ulong guid)
    {
        import std.algorithm.mutation : remove;

        map.removeObject(guid);
        guardians_ = guardians_.remove!(g => g == guid);
    }

    /**
     * The guardians go: all of them (`force`: the owner leaves the map or the game), or those not fighting (it died,
     * `Unit::RemoveGuardians`).
     */
    package void removeGuardians(bool force)
    {
        if (map is null)
            return;
        foreach (guid; guardians_.dup)
        {
            auto g = cast(Creature) map.findObject(guid);
            if (g is null || force || g.ai is null || !g.ai.inCombat)
                unsummonGuardian(guid);
        }
        if (force)
            guardians_ = null;
    }

    /// The owner fights `enemy`: each guardian not fighting yet joins in (`GuardianAI::UpdateAI`).
    package void guardiansAssist(ulong enemy)
    {
        import dmangos.world.relations : canAttack;
        import dmangos.world.unit : combatRelations;

        foreach (g; ownGuardians())
        {
            if (g.ai is null || g.ai.inCombat)
                continue;
            auto foe = g.ai.combatTarget(map, enemy);
            if (foe.alive && (foe.replica is null
                || canAttack(g.ai.relatingOf, foe.combatRelations(context.client), context.client)))
                g.ai.attackedBy(foe, map); // out of a fight: it starts one (`AttackStart`)
        }
    }

    /// `SPELL_EFFECT_SUMMON_OBJECT_WILD` by this player (`dmangos.world.spellsummons.summonWildObject`).
    package void summonWildObjectEffect(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellsummons : summonWildObject;

        auto me = Caster.of(this);
        summonWildObject(me, spell, i, targets);
    }
}

/**
 * A guardian summoned: the owner's faction and its own level range clamped, following; cast again it goes; it joins
 * its owner's fight; it goes with its owner off the map. A wild object stands by the caster.
 */
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.gameobject : GameObject, GameObjectTemplate, GameObjectType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.motion : FollowMovement;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint dragonling = 91_501, summon = 91_502, blanket = 91_503, picnic = 91_504;
    context.data.creatureTemplates[dragonling] = context.data.creatureTemplates[creatureInnkeeper];
    with (context.data.creatureTemplates.edit(dragonling))
    {
        entry = dragonling;
        minLevel = 30;
        maxLevel = 40;
    }
    GameObjectTemplate rug = {entry: blanket, type: GameObjectType.generic, displayId: 1, name: "Picnic Blanket"};
    context.data.gameObjectTemplates[blanket] = rug;
    with (context.data.spells)
    {
        spells[summon] = testSpell(summon, SpellEffect.summonGuardian, 1, 1);
        spells.edit(summon).miscValue[0] = dragonling;
        spells[picnic] = testSpell(picnic, SpellEffect.summonObjectWild, 1, 1);
        spells.edit(picnic).miscValue[0] = blanket;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto me = anduin.session.inWorld;
    me.player.spells ~= [summon, picnic];
    auto map = context.map(0);
    anduin.read();
    Creature cast_(bool triggered = false)
    {
        me.castSpell(context.data.spells.spell(summon), SpellTargets(TargetFlags.self, 0), triggered, 0);
        auto out_ = me.ownGuardians();
        return out_.length ? out_[0] : null;
    }

    auto g = cast_();
    assert(g !is null && g.guardianOwner == me.player.guid);
    with (g.values)
    {
        assert(get!UNIT_FIELD_FACTIONTEMPLATE == me.player.values.get!UNIT_FIELD_FACTIONTEMPLATE);
        assert(get!UNIT_FIELD_SUMMONEDBY == me.player.guid && get!UNIT_FIELD_CREATEDBY == me.player.guid);
        assert(get!UNIT_CREATED_BY_SPELL == summon && get!UNIT_FIELD_LEVEL == 30, "its lowest level: the owner is 1");
        assert((get!UNIT_FIELD_FLAGS & UnitFlags.playerControlled) && getByte!UNIT_FIELD_BYTES_2(1) == guardianMiscFlags);
    }
    assert(cast(FollowMovement) g.generator !is null, "it follows its owner");
    assert(g.ai.relatingOf().playerOwned && g.ai.relatingOf().controller == me.player.guid);

    // Cast again: it goes, and (no duration and category) none comes.
    assert(cast_() is null && map.findObject(g.guid) is null);
    g = cast_();
    assert(g !is null);

    // The owner attacks: the guardian joins in.
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    assert(g.ai.inCombat && g.ai.currentVictim == innkeeper, "at its owner's enemy");

    // Off the map with its owner.
    me.removeGuardians(true);
    assert(me.ownGuardians().length == 0 && map.findObject(g.guid) is null);

    // A wild object: beside the caster, no one's.
    me.castSpell(context.data.spells.spell(picnic), SpellTargets(TargetFlags.self, 0), false, 0);
    GameObject found;
    map.forEachObject((imported!"dmangos.world.map".MapObject o) {
        if (auto go = cast(GameObject) o)
            if (go.template_.entry == blanket)
                found = go;
    });
    assert(found !is null && found.owner == 0);
    const p = found.position, at = me.player.position;
    assert((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 < 4);
}
