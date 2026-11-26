/**
 * Auras on players and the creatures they cast at: applying them, what they do, their periodic
 * ticks, and cancelling them; mixed into `dmangos.world.character.Character`.
 *
 * What an aura does while it lasts: stats, resistances, armor and attack power (the stats are worked
 * out again), speeds (and mounts), water walking, slow fall and hover (`dmangos.world.moveorders`),
 * breathing under water (`dmangos.world.environment`), a stance or form, being rooted or stunned, and
 * periodic effects:
 * damage and heals over time, food's health and drink's mana, energize, triggered spells. Auras end
 * when their time is up, when cancelled (positive ones), at death, and by what their
 * `AuraInterruptFlags` say: standing up (food and drink), moving, taking damage, casting, attacking.
 * Auras are saved with the character and loaded at login and arrival. A player's shields (school absorbs, mana shields) take damage before it lands; damage shields
 * strike back at melee attackers; auras that trigger a spell proc on melee swings and damaging spells,
 * dealt and taken, and on kills.
 * A party area aura (a paladin's) is given each second to the caster's group members on its map within
 * its radius. Not yet: procs on other events, saved charges (an aura loaded at login has its full charges).
 */
module dmangos.world.aurahandlers;

import dmangos.world.spellids;

/// See the module documentation.
/// Events auras may proc on (`procFlags`).
enum ProcFlag : uint
{
    kill = 0x2,                /// it killed something worth experience
    dealMeleeSwing = 0x4,      /// it hit with a melee swing
    takeMeleeSwing = 0x8,      /// a melee swing hit it
    dealMeleeAbility = 0x10,   /// its melee ability (Sinister Strike, Mortal Strike) hit
    takeMeleeAbility = 0x20,   /// a melee ability hit it
    dealRangedAttack = 0x40,   /// its ranged attack (Auto Shot, a wand) hit
    takeRangedAttack = 0x80,   /// a ranged attack hit it
    dealRangedAbility = 0x100, /// its ranged ability (Aimed Shot) hit
    takeRangedAbility = 0x200, /// a ranged ability hit it
    dealHelpfulAbility = 0x400,
    takeHelpfulAbility = 0x800,
    dealHarmfulAbility = 0x1000,
    takeHarmfulAbility = 0x2000,
    dealHelpfulSpell = 0x4000, /// its heal landed
    takeHelpfulSpell = 0x8000, /// a heal landed on it
    dealHarmfulSpell = 0x10000, /// its damaging spell hit
    takeHarmfulSpell = 0x20000, /// a damaging spell hit it
    dealHarmfulPeriodic = 0x40000, /// its damage over time ticked
    takeHarmfulPeriodic = 0x80000, /// a damage over time ticked on it
}

mixin template AuraHandlers()
{
    import dmangos.world.spellids;
    import core.time : Duration;
    import std.random : uniform01;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.auras;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Power, UnitFlags;
    import dmangos.world.movement : baseMoveSpeed, MoveType;
    import dmangos.world.opcodes;
    import dmangos.world.player : DeathState;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellcast : duration, effectValue, heartbeatResistChance, SpellTargets, TargetFlags;
    import dmangos.world.combat : armorReducedDamage;
    import dmangos.world.packets : ServerStandStateUpdate;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

private:
    float manaFromDrink = 0; // drink's mana not yet whole

    /// `SPELL_EFFECT_APPLY_AURA` by this player at `target` (`dmangos.world.spellauras.applyAura`).
    package void applyAuraEffect(const(SpellInfo)* spell, size_t i, ulong target, ubyte effects = 0)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellauras : applyAura;

        auto me = Caster.of(this);
        applyAura(me, spell, i, map.unit(target), effects);
    }

    // -----------------------------------------------------------------------
    // Area auras (`SPELL_EFFECT_APPLY_AREA_AURA_PARTY`)
    // -----------------------------------------------------------------------

    private Duration sinceAreaAuras;
    /// Whose area aura of which spell.
    private static struct AreaAuraKey
    {
        ulong source;
        uint spell;
    }

    private ulong[][AreaAuraKey] areaAuraGiven; /// the players given it
    import dmangos.cluster.protocol : PartyAreaAura;

    private struct ReceivedAreaAura
    {
        PartyAreaAura renewal;
        Aura aura;
    }

    private ReceivedAreaAura[AreaAuraKey] receivedAreaAuras;

    private static ubyte partyAuraEffects(const(SpellInfo)* spell)
    {
        ubyte effects;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.applyAreaAuraParty)
                effects |= cast(ubyte)(1 << i);
        return effects;
    }

    /// Whether `spell` has an area aura for the party.
    private static bool partyAreaAura(const(SpellInfo)* spell)
    {
        return partyAuraEffects(spell) != 0;
    }

    private static bool inPartyAuraRange(Position at, Position source, float radius)
    {
        return (at.x - source.x) ^^ 2 + (at.y - source.y) ^^ 2 + (at.z - source.z) ^^ 2 <= radius * radius;
    }

    package void renewPartyAreaAura(const(SpellInfo)* spell, const ref PartyAreaAura renewal)
    {
        import std.math : isFinite;

        const expiresIn = cast(int)(renewal.deadline - context.transportNow());
        if (expiresIn <= 0 || expiresIn > PartyAreaAura.lifetime + 500 || renewal.radius <= 0
            || !isFinite(renewal.radius) || !context.client.isValidMapCoord(renewal.map, renewal.x, renewal.y, renewal.z)
            || !inPartyAuraRange(player.position, Position(renewal.x, renewal.y, renewal.z), renewal.radius)
            || duelingWith(renewal.controller))
            return;
        const effects = renewal.effects & partyAuraEffects(spell);
        if (!effects)
            return;
        const key = AreaAuraKey(renewal.source, renewal.spell);
        if (const previous = key in receivedAreaAuras)
            if (cast(int)(renewal.deadline - previous.renewal.deadline) <= 0 && previous.aura is player.auras.find(spell.id))
                return;
        auto aura = player.auras.find(spell.id);
        if (aura !is null && aura.caster != renewal.source)
            return;
        if (aura !is null && (aura.amount != renewal.values || aura.effects != effects))
        {
            removeAura(aura);
            aura = null;
        }
        if (aura is null)
        {
            aura = makeAura(spell, renewal.source, renewal.level, -1, true, renewal.values);
            aura.effects = cast(ubyte) effects;
            addAura(aura);
        }
        if (player.auras.find(spell.id, renewal.source) is aura)
            receivedAreaAuras[key] = ReceivedAreaAura(renewal, aura);
    }

    private void expirePartyAreaAuras()
    {
        const now = context.transportNow();
        foreach (key; receivedAreaAuras.keys)
        {
            auto row = receivedAreaAuras[key];
            const r = &row.renewal;
            if (cast(int)(r.deadline - now) > 0 && player.alive && map.id == r.map && map.instanceId == r.instance
                && context.sameAuraSubgroup(r.controller, player.guid, r.group) && !duelingWith(r.controller)
                && inPartyAuraRange(player.position, Position(r.x, r.y, r.z), r.radius))
                continue;
            receivedAreaAuras.remove(key);
            if (player.auras.find(key.spell, key.source) is row.aura)
                removeAura(row.aura);
        }
    }

    /// The radius of `spell`'s party area aura.
    private float areaAuraRadius(const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : radius;

        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.applyAreaAuraParty) // (the player's talents: Totemic Mastery)
            {
                import dmangos.world.spellmods : SpellModOp;

                return spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));
            }
        return 0;
    }

    /**
     * Once a second: each party area aura this player cast on itself (a paladin's aura), and each of its
     * totems', is given to the members of its group on this map within its radius (and, a totem's, to the
     * player too), as the source's aura (its caster the source); those who left the radius or the group, or
     * whose source lost it, lose it.
     */
    package void updateAreaAuras(Duration elapsed)
    {
        import core.time : seconds;
        import dmangos.world.replication : Replica;
        import std.algorithm.comparison : min;
        import std.algorithm.searching : canFind;
        import dmangos.world.player : DeathState;

        sinceAreaAuras += elapsed;
        if (sinceAreaAuras < 1.seconds || player is null)
            return;
        sinceAreaAuras = Duration.zero;
        expirePartyAreaAuras();
        updatePetAreaAuras(); // (`dmangos.world.petauras`)
        struct Source
        {
            ulong guid;
            Position at;
            Aura[] auras;
            bool toOwner; /// the player itself gets it too (a totem's)
        }
        Source[] sources;
        {
            Aura[] own;
            if (player.deathState == DeathState.alive)
                foreach (aura; player.auras.list)
                    if (aura.caster == player.guid && partyAreaAura(aura.spell))
                        own ~= aura;
            sources ~= Source(player.guid, player.position, own, false);
        }
        foreach (totem; ownTotems())
        {
            Aura[] given;
            foreach (aura; totem.auras.list)
                if (partyAreaAura(aura.spell))
                    given ~= aura;
            sources ~= Source(totem.guid, totem.position, given, true);
        }
        // Its pet's (an imp's Blood Pact, a felhunter's Paranoia), as a totem's.
        if (auto pet = ownPet)
            if (pet !is charmed_ && map.findObject(pet.guid) is pet)
            {
                Aura[] given;
                if (pet.alive)
                    foreach (aura; pet.auras.list)
                        if (aura.caster == pet.guid && partyAreaAura(aura.spell))
                            given ~= aura;
                sources ~= Source(pet.guid, pet.position, given, true);
            }
        typeof(this)[] members = [this];
        Replica[] remote;
        auto group = context.groups.of(player.guid);
        if (group !is null)
            foreach (ref m; group.members)
                if (m.guid != player.guid && m.subGroup == group.subGroupOf(player.guid))
                {
                    if (auto s = context.onlinePlayer(m.guid))
                    {
                        if (s.player !is null && s.map is map)
                            members ~= s;
                    }
                    else if (context.sendPartyAreaAura !is null && context.canWrite())
                        if (auto copy = cast(Replica) map.findObject(m.guid))
                            remote ~= copy;
                }
        // Sources that lost an aura (or are gone) take it back first, so a replacing source's is given now.
        bool[AreaAuraKey] current;
        foreach (ref src; sources)
            foreach (aura; src.auras)
                if (aura.effects & partyAuraEffects(aura.spell))
                    current[AreaAuraKey(src.guid, aura.spell.id)] = true;
        foreach (key, given; areaAuraGiven.dup)
            if (key !in current)
            {
                areaAuraGiven.remove(key);
                takeAreaAuraKey(key, given);
            }
        foreach (ref src; sources)
            foreach (aura; src.auras)
            {
                const key = AreaAuraKey(src.guid, aura.spell.id);
                const r = areaAuraRadius(aura.spell);
                const effects = aura.effects & partyAuraEffects(aura.spell);
                if (!effects)
                    continue;
                ulong[] given;
                foreach (m; members)
                {
                    if ((m is this && !src.toOwner) || m.player.deathState != DeathState.alive
                        || m.duelingWith(player.guid))
                        continue;
                    if (!inPartyAuraRange(m.player.position, src.at, r))
                        continue;
                    given ~= m.player.guid;
                    m.receivedAreaAuras.remove(key);
                    if (m.player.auras.find(aura.spell.id) is null)
                    {
                        auto granted = makeAura(aura.spell, src.guid, aura.casterLevel, -1, true, aura.amount);
                        granted.effects = cast(ubyte) effects;
                        m.addAura(granted);
                    }
                }
                foreach (recipient; remote)
                    if (inPartyAuraRange(recipient.position, src.at, r))
                    {
                        const ms = aura.duration < 0 ? PartyAreaAura.lifetime
                            : min(cast(uint) aura.duration, PartyAreaAura.lifetime);
                        const renewal = PartyAreaAura(src.guid, player.guid, recipient.guid, group.id, aura.spell.id,
                            map.id, map.instanceId, context.transportNow() + ms, aura.casterLevel,
                            src.at.x, src.at.y, src.at.z, r, aura.amount, cast(ubyte) effects);
                        map.holdCasterReplica(src.guid, recipient.owner, ms + 1_000);
                        context.sendPartyAreaAura(recipient.owner, renewal);
                    }
                foreach (g; areaAuraGiven.get(key, null))
                    if (!given.canFind(g))
                        takeAreaAura(g, aura.spell.id, src.guid);
                areaAuraGiven[key] = given;
            }
    }

    /// The area auras this player gives go from everyone it gave them to (it leaves, dies, logs out).
    package void areaAurasOnLeave()
    {
        foreach (key, given; areaAuraGiven)
            takeAreaAuraKey(key, given);
        areaAuraGiven = null;
        foreach (key, received; receivedAreaAuras)
            if (player.auras.find(key.spell, key.source) is received.aura)
                removeAura(received.aura);
        receivedAreaAuras = null;
    }

    private void takeAreaAuraKey(const AreaAuraKey key, const(ulong)[] given)
    {
        foreach (g; given)
            takeAreaAura(g, key.spell, key.source);
    }

    /// Player `member` loses the aura of `spell` that `source` gave it.
    private void takeAreaAura(ulong member, uint spell, ulong source)
    {
        auto s = member == player.guid ? this : context.onlinePlayer(member);
        if (s is null || s.player is null)
            return;
        foreach (aura; s.player.auras.list.dup)
            if (aura.spell.id == spell && aura.caster == source)
                s.removeAura(aura);
    }

    /**
     * Damage of `school` (an index) about to hit this player: its shields take what they can, and the
     * rest is left in `damage`. A school absorb (Power Word: Shield, Ice Barrier) takes up to what it has
     * left; a mana shield too, while the player has the mana, each point costing the effect's multiple
     * value in mana. A shield used up goes. Returns what was absorbed.
     */
    public uint absorbIncoming(uint school, ref uint damage)
    {
        if (player is null || damage == 0)
            return 0;
        const absorbed = unit.absorbShields(school, damage);
        splitDamage(school, damage); // Blessing of Sacrifice: a share to its paladin
        splitDamagePct(school, damage); // Soul Link: a share to the demon (`dmangos.world.petauras`)
        if (absorbed)
            flushPlayerChanges();
        return absorbed;
    }

    private bool inProc; /// casting what procs cast

    /**
     * Something happened to this player (`flags`: `ProcFlag`s) with `other`, the unit it struck or that struck
     * it, and `hit` tells how (the spell, a crit, a dodge): its auras that proc on it do what they do
     * (`dmangos.world.procs`, `runProcs`). A spell cast by a proc does not set off procs itself.
     */
    package void procAuras(uint flags, UnitRef other, imported!"dmangos.world.procs".ProcHit hit
        = imported!"dmangos.world.procs".ProcHit.init)
    {
        if (player is null || !player.alive || inProc)
            return;
        inProc = true;
        scope (exit)
            inProc = false;
        runProcs(flags, other, hit);
    }

    /**
     * A melee swing of `attacker`'s hit this player: each damage shield (Thorns) hurts the attacker by its
     * amount, in its spell's school (`SMSG_SPELLDAMAGESHIELD`).
     */
    package void damageShields(UnitRef attacker,
        scope imported!"dmangos.world.unit".SwingRetaliationReply reply = null)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.unit : Blow, dealDamage;

        if (player is null || !attacker)
            return;
        uint[2][] hits; // damage, school
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.damageShield && aura.amount[i] > 0)
                    hits ~= [cast(uint) aura.amount[i], aura.spell.casting.school];
        foreach (hit; hits)
        {
            if (!attacker.alive)
                return;
            if (reply !is null)
            {
                reply(hit[0], hit[1], 0, 1);
                continue;
            }
            ByteWriter w;
            w.put(player.guid);
            w.put(attacker.combatGuid);
            w.put(hit[0]);
            w.put(hit[1]);
            map.sendToWatchers(this, Opcode.SMSG_SPELLDAMAGESHIELD, w.data, true);
            dealDamage(unit, attacker, hit[0], Blow.spell());
        }
    }

    /// The aura on this player: its effects begin (if new), its duration shown.
    package bool addAura(Aura aura)
    {
        bool isNew;
        if (auto displaced = player.auras.displacedBy(aura, player.values)) // another's that may not stay beside it
            removeAura(displaced);
        const had = player.auras.find(aura.spell.id, aura.caster);
        const stacksBefore = had is null ? 0 : had.stacks;
        auto applied = player.auras.apply(aura, player.values, isNew);
        if (applied is null)
            return false;
        if (isNew)
            auraEffects(applied, true);
        else // one more stack (Blessing of the Claw's health): the stats of its amounts again
            player.refreshEquipmentStats(context.data);
        checkpointEncounterAura(applied);
        sendAuraDuration(applied);
        flushPlayerChanges();
        if (isNew) // its spell's script hears of each of its effects (whoever cast it)
        {
            import dmangos.script.api : AuraApplied, EntityRef;

            foreach (i; 0 .. 3)
                if (applied.effects & (1 << i))
                    spellScriptEvent(applied.spell, AuraApplied(EntityRef(applied.caster), EntityRef(player.guid),
                        cast(ubyte) i, applied.amount[i]));
        }
        else if (applied.stacks > stacksBefore && stacksBefore) // a creature's, one more stack: its script hears
        {
            import dmangos.script.api : AuraStacked, EntityRef;

            if (auto caster = map.creatureAt(applied.caster))
                if (caster.ai !is null)
                    caster.ai.spellScriptEvent(applied.spell, AuraStacked(EntityRef(caster.guid),
                        EntityRef(player.guid), applied.stacks), map);
        }
        return true;
    }

    /**
     * The model the player shows without the transform that went: the newest transform left's (a harmful one
     * first), else its own (CMaNGOS's `RestoreDisplayId`). A ghost keeps its wisp.
     */
    private void restoreDisplay()
    {
        if (player.deathState != DeathState.alive)
            return;
        int model;
        bool harmful;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.transform && aura.amount[i] > 0
                        && (!harmful || !aura.positive))
                {
                    model = aura.amount[i];
                    harmful = !aura.positive;
                }
        player.values.set!UNIT_FIELD_DISPLAYID(model > 0 ? cast(uint) model : player.values.get!UNIT_FIELD_NATIVEDISPLAYID);
    }

    /// The transform aura of `spell` on this player shows `model` (a script's: the Orb of Deception's); false if it
    /// has no such aura.
    package bool transformModel(uint spell, uint model)
    {
        auto aura = player is null || model == 0 ? null : player.auras.find(spell);
        if (aura is null)
            return false;
        foreach (i; 0 .. 3)
            if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.transform)
                aura.amount[i] = cast(int) model;
        restoreDisplay();
        flushPlayerChanges();
        return true;
    }

    /// This player's diminishing returns on crowd control in PvP (`dmangos.world.diminishing`).
    private imported!"dmangos.world.diminishing".DiminishingReturns diminishing;

    /**
     * How long a hostile aura of `spell` lasting `ms`, cast by a player or a player's pet or totem, lasts on this
     * player: diminished by the auras of its category before it (full, half, a quarter); 0 when it is immune to them
     * for now.
     */
    package int diminishedDuration(const(SpellInfo)* spell, int ms)
    {
        import dmangos.world.diminishing : drCategory;

        uint level;
        return diminishing.apply(drCategory(*spell), ms, context.clock(), level);
    }

    /// The aura ends (`expired`: its time ran out): its slot empties, its effects end.
    package void removeAura(Aura aura, bool expired = false)
    {
        if (!aura.positive) // a diminished one's 15 seconds count from its end, broken early or not
            diminishing.ended(imported!"dmangos.world.diminishing".drCategory(*aura.spell), context.clock());
        player.auras.remove(aura, player.values);
        auraEffects(aura, false);
        if (aura.caster == player.guid)
            cooldownEvent(aura.spell); // Presence of Mind's cooldown starts now
        checkpointEncounterAura(aura);
        flushPlayerChanges();
        {
            import dmangos.script.api : AuraEnded, EntityRef;

            foreach (i; 0 .. 3)
                if (aura.effects & (1 << i))
                    spellScriptEvent(aura.spell, AuraEnded(EntityRef(aura.caster), EntityRef(player.guid), cast(ubyte) i,
                        expired));
        }
        if (battleground_.instance)
            if (auto copy = currentBattleground())
                copy.rules.auraLost(copy, player.guid, aura.spell.id); // a flag's: it falls
    }

    /// The negative auras go, and with `positive` the positive ones too (not the passive).
    package void dispelAll(bool positive)
    {
        if (player is null)
            return;
        foreach (aura; player.auras.list.dup)
            if (!aura.passive && (positive || !aura.positive))
                removeAura(aura);
    }

    /// `SMSG_UPDATE_AURA_DURATION`: how long the aura in its slot lasts, for the client's buff bar.
    package void sendAuraDuration(const Aura aura)
    {
        if (aura.slot == noSlot || aura.passive)
            return;
        ByteWriter w;
        w.put(aura.slot);
        w.put(cast(uint) aura.duration);
        deliver(Opcode.SMSG_UPDATE_AURA_DURATION, w.data);
    }

    /**
     * What an aura's effects do as it begins (`apply`) and ends: the aura types this
     * server handles.
     */
    void auraEffects(Aura aura, bool apply)
    {
        bool stats, speeds, movement, movementAuras, breathing;
        classAuraChanged(aura, apply); // a seal
        petOwnerAuraChanged(aura, apply); // a talent of its pet's (`dmangos.world.petauras`)
        {
            import dmangos.world.tooltipeffects : hiddenEffectsOf;

            stats = hiddenEffectsOf(aura.spell.id).length > 0; // what only its tooltip gives counts in the stats
        }
        foreach (i; 0 .. 3)
        {
            if (!(aura.effects & (1 << i)))
                continue;
            switch (aura.type(i))
            {
            case AuraType.aoeCharm:
                npcCharmChanged(aura, apply);
                break;
            case AuraType.modStat, AuraType.modPercentStat, AuraType.modResistance, AuraType.modAttackPower,
                    AuraType.modRangedAttackPower, AuraType.modIncreaseHealth, AuraType.modIncreaseEnergy,
                    AuraType.modTotalStatPercentage, AuraType.modBaseResistancePct, AuraType.modResistancePct,
                    AuraType.modIncreaseHealthPercent, AuraType.modIncreaseEnergyPercent, AuraType.modAttackPowerPct,
                    AuraType.modOffhandDamagePct, AuraType.modSkill, AuraType.modSkillTalent,
                    AuraType.modDamagePercentDone, AuraType.modDamagePercentTaken, AuraType.modDamageTaken, AuraType.modDamageDoneVersus,
                    AuraType.modCritPercentVersus, AuraType.modThreat, AuraType.modMechanicResistance, AuraType.modShieldBlockvaluePct,
                    AuraType.modMeleeHaste, AuraType.modRangedHaste, AuraType.modAttackSpeed, AuraType.modRangedAmmoHaste,
                    AuraType.modResistanceExclusive, AuraType.modCastingSpeed, AuraType.modResistanceOfStatPercent,
                    AuraType.modCritPercent, AuraType.modDodgePercent, AuraType.modParryPercent, AuraType.modBlockPercent:
                stats = true; // (the melee chances too: Holy Shield's block, a talent's crit)
                break;
            // Speeds (`dmangos.world.moveorders`: `speedRate`).
            case AuraType.modIncreaseSpeed, AuraType.modDecreaseSpeed, AuraType.modIncreaseSwimSpeed,
                    AuraType.modIncreaseMountedSpeed, AuraType.modSpeedAlways, AuraType.modMountedSpeedAlways,
                    AuraType.modSpeedNotStack, AuraType.modMountedSpeedNotStack, AuraType.useNormalMovementSpeed:
                speeds = true;
                break;
            case AuraType.waterWalk, AuraType.featherFall, AuraType.hover:
                movementAuras = true;
                break;
            case AuraType.waterBreathing, AuraType.modWaterBreathing:
                breathing = true;
                break;
            case AuraType.forceReaction: // a disguise: `dmangos.world.reputationhandlers`
                forceReaction(cast(uint) aura.misc(i), aura.amount[i], apply);
                break;
            // A transform (the Wondervolt's shapes, a hex): the model of its misc value's creature (a script's for none:
            // the Orb of Deception's), until it goes and the newest left shows (CMaNGOS's `HandleAuraTransform`).
            case AuraType.transform:
                if (apply)
                {
                    import dmangos.world.creature : chooseDisplay;

                    enum uint pinkPig = 16358; // an unknown creature's
                    aura.amount[i] = 0;
                    if (const misc = aura.misc(i))
                    {
                        const t = cast(uint) misc in context.data.creatureTemplates;
                        aura.amount[i] = t is null ? pinkPig : cast(int) chooseDisplay(*t, map.random);
                    }
                    if (aura.amount[i] > 0 && player.deathState == DeathState.alive)
                        player.values.set!UNIT_FIELD_DISPLAYID(aura.amount[i]);
                }
                else
                    restoreDisplay();
                break;
            case AuraType.mounted:
                speeds = true; // mounted, the mount's speed counts instead of the speed on foot
                uint display;
                if (apply)
                    if (const t = cast(uint) aura.misc(i) in context.data.creatureTemplates)
                        display = t.modelId1;
                player.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
                interruptAuras(apply ? AuraInterrupt.mounting : AuraInterrupt.dismount, aura);
                petModeAtMount(apply); // the pet's bar greyed out while riding (`dmangos.world.mounting`)
                break;
            // An immunity purges what ends with one (a carried flag: `AURA_INTERRUPT_FLAG_INVULNERABILITY_BUFF_CANCELS`):
            // an effect immunity that helps, a school immunity with `SPELL_ATTR_EX_IMMUNITY_PURGES_EFFECT`.
            case AuraType.effectImmunity, AuraType.schoolImmunity:
                enum uint invulnerabilityCancels = 0x00200000, immunityPurges = 0x00008000;
                if (apply && (aura.type(i) == AuraType.effectImmunity ? aura.positive
                        : (aura.spell.attributesEx & immunityPurges) != 0))
                    interruptAuras(invulnerabilityCancels, aura); // not itself (Silithyst, 29519, has both)
                break;
            // A mechanic's immunity that purges (Berserker Rage and fear, Blessing of Freedom and roots): the
            // player's auras of that mechanic go (CMaNGOS's `RemoveAurasAtMechanicImmunity`).
            case AuraType.mechanicImmunity, AuraType.mechanicImmunityMask:
                enum uint immunityPurgesEffect = 0x00008000; // SPELL_ATTR_EX_IMMUNITY_PURGES_EFFECT
                // (and Improved Sprint's, 30918, which is there only to "remove all movement impairing effects")
                enum uint improvedSprintPurge = 30918;
                if (apply && ((aura.spell.attributesEx & immunityPurgesEffect) || aura.spell.id == improvedSprintPurge))
                {
                    const misc = aura.misc(i);
                    const mask = aura.type(i) == AuraType.mechanicImmunity
                        ? (misc > 0 && misc <= 32 ? 1u << (misc - 1) : 0) : cast(uint) misc;
                    bool hasMechanic(const Aura other)
                    {
                        static bool inMask(uint mechanic, uint mask) { return mechanic && mechanic <= 32 && (mask & (1u << (mechanic - 1))); }
                        if (inMask(other.spell.casting.mechanic, mask))
                            return true;
                        foreach (j; 0 .. 3)
                            if ((other.effects & (1 << j)) && inMask(other.spell.casting.effectMechanic[j], mask))
                                return true;
                        return false;
                    }
                    foreach (other; player.auras.list.dup)
                        if (other !is aura && !other.passive && hasMechanic(other))
                            removeAura(other);
                }
                break;
            case AuraType.retainComboPoints: // Premeditation ran out: its combo points with it
                if (!apply)
                    retainedComboPointsExpired(aura.amount[i]);
                break;
            case AuraType.addFlatModifier, AuraType.addPctModifier: // talents: the client's numbers
                if (map !is null) // in the world (at login they all go at once: `sendAllSpellMods`)
                    spellModChanged(aura, i);
                break;
            case AuraType.modStealth: // who sees it changes (`Map`'s `playerSees`); a carried flag falls
                if (apply)
                    interruptAuras(AuraInterrupt.stealthInvisCancels, aura);
                if (map !is null)
                    map.refreshVisibility(this);
                break;
            case AuraType.modInvisibility: // the glow it sees itself with; who sees it changes
            {
                if (apply)
                    interruptAuras(AuraInterrupt.stealthInvisCancels, aura);
                enum ubyte invisibilityGlow = 0x40; // PLAYER_FIELD_BYTE2_INVISIBILITY_GLOW
                const bytes = player.values.getByte!PLAYER_FIELD_BYTES2(1);
                const glowing = player.auras.hasType(AuraType.modInvisibility);
                player.values.setByte!PLAYER_FIELD_BYTES2(1, cast(ubyte)(glowing ? bytes | invisibilityGlow
                    : bytes & ~invisibilityGlow));
                if (map !is null)
                    map.refreshVisibility(this);
                break;
            }
            case AuraType.modInvisibilityDetection: // what it sees changes
                if (map !is null)
                    map.refreshVisibility(this);
                break;
            case AuraType.modShapeshift:
                // One form, one stance at a time: the one it was in ends first.
                if (apply)
                    foreach (other; player.auras.list.dup)
                        if (other !is aura && other.has(AuraType.modShapeshift))
                            removeAura(other);
                player.values.setByte!UNIT_FIELD_BYTES_1(2, apply ? cast(ubyte) aura.misc(i) : 0);
                if (apply)
                    interruptAuras(AuraInterrupt.shapeshifting, aura);
                refreshFormBoundPassives(); // the form's own passives, its talents'
                if (apply)
                    classShapeshifted(cast(ubyte) aura.misc(i));
                if (apply && map !is null) // (in the world: a stance taken, not one put back at login)
                    warriorStanceTaken();
                break;
            case AuraType.modRoot:
                movement = true;
                break;
            case AuraType.feignDeath: // creatures let the player be, if it is not seen through
                feignDeathAura(aura, apply);
                break;
            case AuraType.modTotalThreat: // Fade: less threat with every creature, while it lasts
                fadeThreat(aura, i, apply);
                break;
            // Tracking: the minimap's creature types and resources (`PLAYER_TRACK_CREATURES`, `_RESOURCES`), a bit
            // for each type (the misc value, from 1).
            case AuraType.trackCreatures, AuraType.trackResources, AuraType.trackStealthed:
                trackingAura(aura, i, apply);
                break;
            case AuraType.modUnattackable: // Divine Intervention: out of every fight, and nothing may target it
                unattackableAura(apply);
                break;
            // Crowd control (CMaNGOS's `SetStunned`, `SetFleeing`, `SetConfused`, silence, pacify, disarm): on the
            // unit's flags while any such aura lasts; as it begins, what it stops stops.
            case AuraType.modStun:
                movement = true;
                crowdControlFlag(UnitFlags.stunned, AuraType.modStun, apply, true);
                break;
            case AuraType.modFear:
                crowdControlFlag(UnitFlags.fleeing, AuraType.modFear, apply, true);
                break;
            case AuraType.modConfuse:
                crowdControlFlag(UnitFlags.confused, AuraType.modConfuse, apply, true);
                break;
            case AuraType.modSilence:
                crowdControlFlag(UnitFlags.silenced, AuraType.modSilence, apply, false);
                if (apply && generic.active && generic.spell.casting.preventionType == 1)
                    interruptCast(SpellCastResult.interrupted);
                if (apply && channelSpell !is null && channelSpell.casting.preventionType == 1)
                    endChannel(true);
                break;
            case AuraType.modPacify:
                crowdControlFlag(UnitFlags.pacified, AuraType.modPacify, apply, false);
                if (apply)
                    stopAttack(false);
                break;
            case AuraType.modDisarm:
                crowdControlFlag(UnitFlags.disarmed, AuraType.modDisarm, apply, false);
                stats = true; // the weapon's damage goes
                break;
            default:
                break;
            }
        }
        // Food and drink sit down.
        if (apply && (aura.spell.casting.auraInterruptFlags & AuraInterrupt.standingCancels)
            && player.values.getByte!UNIT_FIELD_BYTES_1(0) == 0)
        {
            player.setStandState(1);
            send(ServerStandStateUpdate(1));
        }
        // The health Last Stand's aura grants (12976, `MOD_INCREASE_HEALTH`: "grants you 30% of your maximum hit
        // points... After the effect expires, the hit points are lost"): the health itself, not only its maximum.
        enum uint lastStandHealth = 12976;
        int granted;
        foreach (i; 0 .. 3)
            if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modIncreaseHealth && map !is null
                    && aura.spell.id == lastStandHealth)
                granted += aura.amount[i];
        const healthBefore = cast(int) player.values.get!UNIT_FIELD_HEALTH;
        if (stats)
            player.refreshEquipmentStats(context.data);
        if (granted && player.alive)
        {
            const max = cast(int) player.values.get!UNIT_FIELD_MAXHEALTH;
            int health = apply ? healthBefore + granted : healthBefore - granted;
            health = health < 1 ? 1 : health > max ? max : health;
            player.values.set!UNIT_FIELD_HEALTH(cast(uint) health);
        }
        if (speeds)
            refreshSpeeds();
        if (movement)
            refreshRooted();
        if (movementAuras)
            refreshMovementAuras();
        if (breathing)
            refreshWaterBreathing();
    }

    /// Rooted while any root or stun lasts (and stunned while a stun does).
    void refreshRooted()
    {
        const stunned = player.auras.has(AuraType.modStun);
        const rooted = stunned || player.auras.has(AuraType.modRoot);
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        player.values.set!UNIT_FIELD_FLAGS(stunned ? flags | UnitFlags.stunned : flags & ~UnitFlags.stunned);
        if (rooted)
            sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        else if (player.deathState != DeathState.corpse)
            sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
    }

    // -----------------------------------------------------------------------
    // The client's spell modifiers
    // -----------------------------------------------------------------------

    /**
     * The total of the player's modifiers of `type` (`ADD_FLAT_MODIFIER` or `ADD_PCT_MODIFIER`) for `op` whose
     * spell mask has `bit`: what the client adds to the spells of its family with that bit (CMaNGOS's
     * `Player::AddSpellMod`). The client shows tooltips, costs, cast times and ranges with them, and refuses a cast
     * at a talent's longer range without them.
     */
    private int spellModTotal(AuraType type, int op, uint bit)
    {
        int total;
        foreach (aura; player.auras.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && aura.misc(i) == op
                        && (aura.spell.itemType[i] & (1u << bit)))
                    total += aura.amount[i];
        return total;
    }

    private void sendSpellMod(AuraType type, uint bit, int op, int value)
    {
        ByteWriter w;
        w.put(cast(ubyte) bit);
        w.put(cast(ubyte) op);
        w.put(value);
        deliver(type == AuraType.addFlatModifier ? Opcode.SMSG_SET_FLAT_SPELL_MODIFIER
            : Opcode.SMSG_SET_PCT_SPELL_MODIFIER, w.data);
    }

    /// A modifier came or went (effect `i` of `aura`): the client's totals for each bit of its mask, anew.
    private void spellModChanged(Aura aura, size_t i)
    {
        const type = aura.type(i), op = aura.misc(i), mask = aura.spell.itemType[i];
        foreach (uint bit; 0 .. 32)
            if (mask & (1u << bit))
                sendSpellMod(type, bit, op, spellModTotal(type, op, bit));
    }

    /// Every modifier total the player has, for a client logging in or arriving after a far teleport.
    package void sendAllSpellMods()
    {
        foreach (type; [AuraType.addFlatModifier, AuraType.addPctModifier])
        {
            uint[int] masks; // op: the bits any modifier of it has
            foreach (aura; player.auras.list)
                foreach (i; 0 .. 3)
                    if ((aura.effects & (1 << i)) && aura.type(i) == type)
                        masks[aura.misc(i)] |= aura.spell.itemType[i];
            foreach (op, mask; masks)
                foreach (uint bit; 0 .. 32)
                    if (mask & (1u << bit))
                        if (const total = spellModTotal(type, op, bit))
                            sendSpellMod(type, bit, op, total);
        }
    }

    /**
     * `flag` on the player's unit flags while it has an aura of `type` (taken off with the last); `stopsCasting`:
     * as the first begins, the cast and channel under way stop (a stun, a fear, a disorientation).
     */
    private void crowdControlFlag(uint flag, AuraType type, bool apply, bool stopsCasting)
    {
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        const on = player.auras.hasType(type);
        player.values.set!UNIT_FIELD_FLAGS(on ? flags | flag : flags & ~flag);
        if (apply && stopsCasting)
        {
            interruptCast(SpellCastResult.interrupted);
            if (channelSpell !is null)
                endChannel(true);
        }
    }

    /// What standing up, moving, damage, casting or attacking ends (`except`: the aura that causes it, kept).
    package void interruptAuras(uint flags, const Aura except = null)
    {
        if (player is null)
            return;
        foreach (aura; player.auras.interruptedBy(flags))
            if (aura !is except)
                removeAura(aura);
    }

    /**
     * What casting `spell` ends (CMaNGOS's `RemoveAurasOnCast`): the auras with `flag`, but its own aura from
     * this player, Stealth for a spell allowed while stealthed (Pick Pocket, Distract), and invisibility for one
     * allowed while invisible.
     */
    package void interruptAurasOnCast(uint flag, const(SpellInfo)* spell)
    {
        enum uint dispelStealth = 5, dispelInvisibility = 6;
        enum uint allowWhileStealthed = 0x00000020, allowWhileInvisible = 0x00004000; // attributes ex, ex 2
        if (player is null)
            return;
        foreach (aura; player.auras.interruptedBy(flag))
        {
            if (aura.spell.id == spell.id && aura.caster == player.guid)
                continue;
            if (aura.spell.casting.dispel == dispelStealth && (spell.attributesEx & allowWhileStealthed))
                continue;
            if (aura.spell.casting.dispel == dispelInvisibility && (spell.attributesEx2 & allowWhileInvisible))
                continue;
            removeAura(aura);
        }
    }

    /// Every aura goes on death but the passive ones and those that last through it (CMaNGOS `RemoveAllAurasOnDeath`).
    package void removeAurasOnDeath()
    {
        enum uint allowAuraWhileDead = 0x00100000; // SPELL_ATTR_EX3_ALLOW_AURA_WHILE_DEAD: flasks, Deserter, sickness
        foreach (aura; player.auras.list.dup)
            if (!aura.passive && !(aura.spell.casting.attributesEx3 & allowAuraWhileDead))
                removeAura(aura);
    }

    /// Saves the auras that last (not passive ones), as they are now.
    package void saveAuras()
    {
        import dmangos.world.database : AuraRecord;

        AuraRecord[] rows;
        foreach (aura; player.auras.list)
            if (!aura.passive && aura.duration != 0 && (!partyAreaAura(aura.spell) || aura.caster == player.guid))
                rows ~= AuraRecord(aura.caster, aura.spell.id, aura.stacks, aura.amount, aura.periodTimer,
                    aura.maxDuration, aura.duration, aura.savedEffectMask, aura.charges);
        context.database.saveAuras(player.data.guid, rows);
    }

    private bool loadingSavedAuras;

    private static bool recoverableEncounterAura(uint spell)
    {
        import dmangos.scripts.blackwinglair : isBlackwingRecoveryAura;
        import dmangos.scripts.naxxramas : isNaxxramasRecoveryAura;

        return isBlackwingRecoveryAura(spell) || isNaxxramasRecoveryAura(spell);
    }

    private void checkpointEncounterAura(const Aura aura)
    {
        if (!loadingSavedAuras && connection.gatewayHome.node && recoverableEncounterAura(aura.spell.id))
            checkpointSummons(true);
    }

    package const(ubyte)[] encounterAuraRecoveryState()
    {
        ByteWriter state;
        foreach (aura; player.auras.list)
            if (recoverableEncounterAura(aura.spell.id))
            {
                if (!state.length)
                {
                    state.put(map.id);
                    state.put(map.instanceId);
                    state.put(context.transportNow());
                }
                aura.saveState(state);
            }
        return state.data;
    }

    package void restoreEncounterAuraRecovery(ref ByteReader state)
    {
        import std.algorithm.comparison : max;

        if (state.empty || state.read!uint != map.id || state.read!uint != map.instanceId)
            return;
        const elapsed = max(0, cast(int)(context.transportNow() - state.read!uint));
        loadingSavedAuras = true;
        scope (exit) loadingSavedAuras = false;
        while (!state.empty)
        {
            import dmangos.scripts.naxxramas : pausesWithItsFight;

            auto aura = Aura.loadState(state, (uint id) => context.data.spells.spell(id));
            if (aura.spell is null || !recoverableEncounterAura(aura.spell.id))
                continue;
            // Sapphiron's freeze waits with his air phase, which a crash pauses, and Kel'Thuzad's Frost Blast and Detonate
            // Mana with his fight: they keep the time they had.
            const lost = pausesWithItsFight(aura.spell.id) ? 0 : elapsed;
            if (aura.duration >= 0 && aura.duration <= lost)
                continue;
            if (aura.duration > 0)
                aura.duration -= lost;
            foreach (i, period; aura.period)
                if (period > 0)
                {
                    const due = aura.periodTimer[i] - lost;
                    aura.periodTimer[i] = due > 0 ? due : period - (-due % period);
                }
            aura.slot = noSlot;
            addAura(aura);
        }
    }

    /// Loads the auras saved at the last logout, with the time they had left.
    package void loadAuras(bool recovered = false)
    {
        import dmangos.world.auras : enableAuraEffect;

        loadingSavedAuras = true;
        scope (exit) loadingSavedAuras = false;
        foreach (ref row; context.database.loadAuras(player.data.guid))
        {
            const spell = context.data.spells.spell(row.spell);
            if (spell is null || row.remaining == 0 || (partyAreaAura(spell) && row.caster != player.guid))
                continue;
            if (recovered && row.caster == player.guid && recoverableChannelAura(*spell))
                continue; // the gateway's channel checkpoint supplies its current timing
            if (ownChannelGone(*spell, row))
                continue; // the channel it belonged to ended with the session it ran in
            if (recovered && recoverableEncounterAura(row.spell))
                continue; // the gateway checkpoint also records dispels since the last periodic save
            auto aura = makeAura(spell, row.caster, player.data.level, row.maxDuration,
                Aura.savedPositive(*spell, row.effectMask), row.amount);
            ubyte groundEffects;
            foreach (i, effect; spell.effect)
                if (effect == SpellEffect.persistentAreaAura && (row.effectMask & (1 << i)))
                    groundEffects |= cast(ubyte)(1 << i);
            if (groundEffects)
            {
                aura.positive = false;
                aura.effects = 0;
                aura.detachedChannel = true;
                foreach (i; 0 .. spell.effect.length)
                    if (groundEffects & (1 << i))
                        enableAuraEffect(aura, i, row.amount[i]);
            }
            aura.duration = row.remaining;
            if (row.charges)
                aura.charges = row.charges;
            aura.stacks = row.stacks ? row.stacks : 1;
            foreach (i; 0 .. 3)
                if (aura.period[i] > 0 && row.periodTimer[i] > 0)
                    aura.periodTimer[i] = row.periodTimer[i];
            addAura(aura);
            // Its own Presence of Mind still on: the spell held in use again, its cooldown to start as it ends.
            enum uint cooldownOnEvent = 0x02000000; // SPELL_ATTR_COOLDOWN_ON_EVENT
            if (row.caster == player.guid && (spell.attributes & cooldownOnEvent))
                holdForCooldownEvent(spell);
        }
    }

    /**
     * A saved aura of the player's own channel (Evocation, Tranquility) whose channel is not running here: saved as
     * the player left, crashed or moved, it would come back on its own, ticking while the player moves and casts.
     * A channel carried here (a clean handoff) keeps its aura; a channel's ground effect comes back detached, as its
     * own handling below does.
     */
    private bool ownChannelGone(const ref SpellInfo spell, const ref imported!"dmangos.world.database".AuraRecord row)
    {
        enum uint channeled = 0x04, selfChanneled = 0x40;
        if (row.caster != player.guid || !(spell.attributesEx & (channeled | selfChanneled)))
            return false;
        if (channelSpell !is null && channelSpell.id == spell.id)
            return false;
        foreach (i, effect; spell.effect)
            if (effect == SpellEffect.persistentAreaAura && (row.effectMask & (1 << i)))
                return false;
        return true;
    }

    /// A positive aura the player clicks off.
    @Handles(Opcode.CMSG_CANCEL_AURA, WorldState.inWorld)
    void handleCancelAura(ref ByteReader reader)
    {
        const spell = reader.read!uint;
        if (auto aura = player.auras.find(spell))
            if (aura.positive && !(aura.spell.attributes & spellAttrNoAuraCancel))
            {
                import dmangos.world.classspells : ofFamily, SpellFamily;

                const cancelledStealth = ofFamily(aura.spell, SpellFamily.rogue, 0x400000) && aura.has(AuraType.modStealth);
                removeAura(aura);
                if (cancelledStealth)
                    foreach (id; [11327u, 11329u]) // Vanish's enhanced stealth, ranks 1 and 2
                        if (auto vanish = player.auras.find(id))
                            removeAura(vanish);
            }
    }

    /// The auras' time passes: their ticks, then those that ended; drink's mana.
    void updateAuras(Duration elapsed)
    {
        const ms = cast(int) elapsed.total!"msecs";
        if (ms <= 0)
            return;
        if ((heartbeatIn -= ms) <= 0)
        {
            heartbeatIn = heartbeatMs;
            auraHeartbeat();
        }
        if (player.auras.list.length == 0)
            return;
        import dmangos.scripts.naxxramas : Kelthuzad;

        AuraTick[] ticks;
        Aura[] expired, heartbeats;

        bool frostBlastTick;
        player.auras.update(ms, ticks, expired, heartbeats);
        foreach (tick; ticks)
        {
            import dmangos.script.api : AuraTickEnded, EntityRef;

            selfTick(tick.aura, tick.effect);
            frostBlastTick |= tick.aura.spell.id == Kelthuzad.frostBlast && tick.aura.duration > 0;
            if (player is null)
                return;
            spellScriptEvent(tick.aura.spell, AuraTickEnded(EntityRef(tick.aura.caster), EntityRef(player.guid),
                cast(ubyte) tick.effect));
        }
        // A raid checkpoint can save this health before the next tick. Keep the remaining blast with it.
        if (frostBlastTick && player.alive)
            checkpointSummons(true);
        // Crowd control breaking early (`SPELL_ATTR_HEARTBEAT_RESIST`).
        foreach (aura; heartbeats)
        {
            import std.algorithm.searching : canFind;

            if (!expired.canFind(aura) && uniform01(map.random) * 100 < aura.heartbeatChance)
                expired ~= aura;
        }
        // Drink (`MOD_POWER_REGEN` of mana) adds its mana every 5 seconds' worth.
        const drink = player.auras.totalByMisc(AuraType.modPowerRegen, Power.mana);
        if (drink > 0 && player.deathState == DeathState.alive)
        {
            manaFromDrink += drink * ms / 5000.0f;
            if (manaFromDrink >= 1)
            {
                player.modifyPower(Power.mana, cast(int) manaFromDrink);
                manaFromDrink -= cast(int) manaFromDrink;
            }
        }
        foreach (aura; expired)
        {
            if (aura.maxDuration > 0 && aura.duration <= 0 && aura.has(AuraType.feignDeath) && feigningDeath
                && player.deathState == DeathState.alive)
                return playerDied(false);
            removeAura(aura, true);
        }
        if (ticks.length || drink > 0)
            flushPlayerChanges();
    }

    private enum int heartbeatMs = 5000; // CMaNGOS's `GetHeartbeatDuration`
    private int heartbeatIn = heartbeatMs; // until the player's next heartbeat

    /// The player's heartbeat: the scripts of its auras' spells hear of each effect (food's chewing).
    private void auraHeartbeat()
    {
        import dmangos.script.api : AuraHeartbeat, EntityRef;

        foreach (aura; player.auras.list.dup)
            foreach (i; 0 .. 3)
                if (aura.effects & (1 << i))
                    spellScriptEvent(aura.spell, AuraHeartbeat(EntityRef(aura.caster), EntityRef(player.guid), cast(ubyte) i));
    }

    /// One periodic tick of an aura on this player.
    void selfTick(Aura aura, size_t i)
    {
        if (player.deathState != DeathState.alive)
            return;
        auto v = &player.values;
        const amount = aura.amount[i] > 0 ? aura.amount[i] : 0;
        uint healed;
        switch (aura.type(i))
        {
        case AuraType.periodicHeal:
            healed = player.auras.healingTaken(amount, aura.spell.casting.school);
            break;
        case AuraType.modRegen:
            healed = amount;
            break;
        case AuraType.obsModHealth:
            healed = v.get!UNIT_FIELD_MAXHEALTH * amount / 100;
            break;
        case AuraType.obsModMana:
            player.modifyPower(Power.mana, cast(int)(v.get!UNIT_FIELD_MAXPOWER1(Power.mana) * amount / 100));
            return periodicLog(player.guid, aura, i, amount, Power.mana);
        case AuraType.periodicEnergize:
            if (aura.misc(i) >= 0 && aura.misc(i) <= Power.happiness)
                player.modifyPower(cast(Power) aura.misc(i), amount);
            return periodicLog(player.guid, aura, i, amount, cast(uint) aura.misc(i));
        case AuraType.periodicTriggerSpell:
            if (classPeriodicTrigger(aura, i)) // Frenzied Regeneration
                return;
            if (aura.caster != player.guid && creatureAuraTickScript(aura, i)) // Kel'Thuzad's Detonate Mana
                return;
            if (const spell = context.data.spells.spell(aura.spell.triggerSpell[i]))
            {
                // A channel's ticks (Arcane Missiles' missiles) go at what it is channelled at.
                const channelled = aura.caster == player.guid ? channelledAt(aura.spell) : 0;
                if (channelled && channelled != player.guid)
                {
                    import dmangos.world.classspells : CustomValues;
                    import dmangos.world.replication : Replica;

                    if (auto replica = cast(Replica) map.findObject(channelled))
                        castProcAtReplica(spell, replica, CustomValues.init);
                    else
                        castSpell(spell, SpellTargets(TargetFlags.unit, channelled), true, 0);
                }
                else
                    castSpell(spell, SpellTargets(TargetFlags.self, player.guid), true, 0);
            }
            return;
        case AuraType.periodicLeech, AuraType.periodicManaLeech:
            // Another player's drain (a duel, world PvP): its caster's doing, as on a creature.
            if (aura.caster != player.guid)
                if (auto caster = context.onlinePlayer(aura.caster))
                    if (caster.map is map && caster.player !is null)
                        return aura.type(i) == AuraType.periodicLeech ? caster.leechTick(unit, aura, i, amount)
                            : caster.manaLeechTick(unit, aura, i, amount);
            if (aura.type(i) == AuraType.periodicManaLeech)
            {
                if (aura.caster && aura.caster != player.guid && aura.caster <= uint.max)
                    return imported!"dmangos.world.spellauras".remoteManaLeechTick(context, unit, aura, i);
                return creatureManaLeechTick(aura, i, amount);
            }
            goto case AuraType.periodicDamage; // a creature's: damage over time
        case AuraType.periodicDamage:
        {
            // A creature's damage over time (armor takes off physical).
            if (aura.caster == player.guid || amount == 0)
                return;
            uint damage = amount;
            if (aura.spell.casting.school == 0)
                damage = cast(uint) armorReducedDamage(aura.casterLevel, player.fighter.armor, damage);
            auto attacker = map.unit(aura.caster);
            if (aura.type(i) == AuraType.periodicLeech && !attacker && aura.caster && aura.caster <= uint.max)
                return imported!"dmangos.world.spellauras".remoteLeechTick(context, unit, aura, i, damage);
            const absorbed = absorbIncoming(aura.spell.casting.school, damage);
            import dmangos.world.unit : Blow, dealDamage;

            if (aura.type(i) != AuraType.periodicLeech)
            {
                periodicLog(player.guid, aura, i, damage, 0, absorbed);
                if (!attacker && aura.caster && aura.caster <= uint.max)
                    return context.dealRemotePeriodicDamage(unit, aura, damage, i);
                return dealDamage(attacker, unit, damage, Blow.periodic());
            }
            // A creature's drain: the periodic damage log (as CMaNGOS's leech sends), and its health back.
            import dmangos.world.spellcast : nonMeleeDamageLog;

            const school = aura.spell.casting.school;
            tellAround(player.guid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(player.guid, aura.caster,
                aura.spell.id, damage, school, absorbed, 0, true, 0, false));
            const dealt = damage < v.get!UNIT_FIELD_HEALTH ? damage : v.get!UNIT_FIELD_HEALTH;
            dealDamage(attacker, unit, damage, Blow.periodic(school));
            if (auto drainer = cast(Creature) map.findObject(aura.caster))
                if (drainer.alive)
                {
                    const factor = aura.spell.casting.multipleValue[i] > 0 ? aura.spell.casting.multipleValue[i] : 1;
                    const health = drainer.values.get!UNIT_FIELD_HEALTH, top = drainer.values.get!UNIT_FIELD_MAXHEALTH;
                    const back = cast(uint)(dealt * factor);
                    drainer.values.set!UNIT_FIELD_HEALTH(health + back > top ? top : health + back);
                    map.flushObjectChanges(drainer);
                }
            return;
        }
        default:
            return;
        }
        if (aura.type(i) == AuraType.periodicHeal) // what the healer's class rules do at its ticks
            if (auto healer = map.unit(aura.caster))
                if (healer.kind == imported!"dmangos.world.unit".UnitKind.player)
                    healer.session.classHealed(aura.spell, unit);
        const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
        if (health >= maxHealth)
            return;
        v.set!UNIT_FIELD_HEALTH(health + healed > maxHealth ? maxHealth : health + healed);
        if (aura.type(i) != AuraType.modRegen) // food shows no log
            periodicLog(player.guid, aura, i, healed, 0);
        if (aura.type(i) == AuraType.periodicHeal) // a heal over time angers as a heal does
            if (auto healer = map.unit(aura.caster))
            {
                import dmangos.world.spellmods : SpellModOp;

                int threat = health + healed > maxHealth ? maxHealth - health : healed;
                if (healer.kind == imported!"dmangos.world.unit".UnitKind.player) // less by the healer's talents
                    threat = healer.session.spellMod(SpellModOp.threat, aura.spell, threat);
                imported!"dmangos.world.creatureai".assistThreat(map, threateners, healer, threat > 0 ? threat : 0,
                    *aura.spell);
            }
    }

    /**
     * A creature's drain of this player's power (Mark of Kazzak, `SPELL_AURA_PERIODIC_MANA_LEECH`): as much as the
     * tick takes, if the player has it, and to the creature by the effect's multiplier if it has that power.
     */
    private void creatureManaLeechTick(Aura aura, size_t i, uint amount)
    {
        const kind = aura.misc(i);
        if (kind < 0 || kind > Power.happiness)
            return;
        const power = cast(Power) kind;
        auto v = &player.values;
        if (v.get!UNIT_FIELD_MAXPOWER1(power) == 0)
            return;
        const now = v.get!UNIT_FIELD_POWER1(power);
        const drained = now < amount ? now : amount;
        player.modifyPower(power, -cast(int) drained);
        auto drainer = cast(Creature) map.findObject(aura.caster);
        const factor = drainer !is null && drainer.alive && drainer.values.get!UNIT_FIELD_MAXPOWER1(power) > 0
            ? multiplier(aura.spell, i) : 0.0f;
        periodicLog(player.guid, aura, i, drained, power, 0, factor);
        const gain = cast(uint)(drained * factor);
        if (gain == 0)
            return;
        const top = drainer.values.get!UNIT_FIELD_MAXPOWER1(power), has = drainer.values.get!UNIT_FIELD_POWER1(power);
        drainer.values.set!UNIT_FIELD_POWER1(power, has + gain > top ? top : has + gain);
        map.flushObjectChanges(drainer);
    }

    /// A periodic aura's log (`dmangos.world.spellauras.periodicLog`).
    void periodicLog(ulong target, const Aura aura, size_t i, uint amount, uint powerOrSchool, uint absorbed = 0,
        float gainMultiplier = 0)
    {
        import dmangos.world.caster : Caster;
        static import dmangos.world.spellauras;

        auto me = Caster.of(this);
        dmangos.world.spellauras.periodicLog(me, target, aura, i, amount, powerOrSchool, absorbed, gainMultiplier);
    }

    /// A log about `target` (this player or another unit) for everyone who sees it, and for this player.
    package void tellAround(ulong target, Opcode opcode, const(ubyte)[] body_)
    {
        if (target == player.guid)
            return map.sendToWatchers(this, opcode, body_, true);
        map.sendToObservers(target, opcode, body_);
        if (!map.seesObject(player.guid, target))
            deliver(opcode, body_);
    }

    /// See `UnitRef.auraTick` (`dmangos.world.spellauras.periodicTick`).
    public void auraTick(Creature target, Aura aura, size_t i)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellauras : periodicTick;

        if (player is null)
            return;
        auto me = Caster.of(this);
        periodicTick(me, target, aura, i);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A buff raises a stat while it lasts and shows on the buff bar; food sits the player down and heals
 * every 5 seconds until it stands; damage over time ticks on a creature; a speed buff speeds up;
 * a buff can be cancelled.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind, count;
    import dmangos.dbc : buildDbc;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : Stat;
    import dmangos.world.movement : MoveType, Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientStandStateChange;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 10_000, 0, 10_000], [2u, 9000, 0, 9000], [3u, -1, 0, -1]]), "SpellDuration.dbc");
    enum uint wits = 91001, meal = 91002, gash = 91003, haste = 91004;
    with (context.data.spells)
    {
        spells[wits] = testSpell(wits, 6, 1, 2);                    // +2 intellect, 10 s
        spells.edit(wits).casting.applyAuraName[0] = AuraType.modStat;
        spells.edit(wits).miscValue[0] = Stat.intellect;
        spells.edit(wits).casting.durationIndex = 1;
        spells[meal] = testSpell(meal, 6, 1, 16);                   // 16 health every 5 s, sitting
        spells.edit(meal).casting.applyAuraName[0] = AuraType.modRegen;
        spells.edit(meal).casting.durationIndex = 3;
        spells.edit(meal).casting.auraInterruptFlags = 0x00040000;
        spells.edit(meal).attributes = 0x08000000;                       // castable while sitting
        spells[gash] = testSpell(gash, 6, 6, 5);                    // 5 damage every 3 s for 9 s
        spells.edit(gash).casting.applyAuraName[0] = AuraType.periodicDamage;
        spells.edit(gash).casting.amplitude[0] = 3000;
        spells.edit(gash).casting.durationIndex = 2;
        spells.edit(gash).casting.school = 1;
        spells.edit(gash).casting.dmgClass = DamageClass.none; // no hit roll: the test must not depend on a 1% miss
        spells[haste] = testSpell(haste, 6, 1, 50);                 // 50% faster
        spells.edit(haste).casting.applyAuraName[0] = AuraType.modIncreaseSpeed;
        spells.edit(haste).casting.durationIndex = 1;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= [wits, meal, gash, haste];

    ubyte[] castAt(uint spell, ulong target)
    {
        ByteWriter w;
        w.put(spell);
        SpellTargets(target ? TargetFlags.unit : TargetFlags.self, target).write(w);
        return w.data.dup;
    }

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        context.map(0).update(ms.msecs);
    }

    // The buff: two more intellect, in the first positive slot, for ten seconds.
    const intellect = me.values.get!UNIT_FIELD_STAT0(Stat.intellect);
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(wits, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_UPDATE_AURA_DURATION));
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.intellect) == intellect + 2 && me.values.get!UNIT_FIELD_AURA(0) == wits);
    tick(10_100);
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.intellect) == intellect && me.values.get!UNIT_FIELD_AURA(0) == 0,
        "it ended");
    anduin.read();

    // Food: sitting, 16 health every 5 seconds; standing up ends it.
    me.values.set!UNIT_FIELD_HEALTH(10u);
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(meal, 0));
    assert(me.values.getByte!UNIT_FIELD_BYTES_1(0) == 1, "sat down");
    tick(5000);
    assert(me.values.get!UNIT_FIELD_HEALTH >= 26, "16 from the food (and the regeneration of sitting)");
    anduin.write(Opcode.CMSG_STANDSTATECHANGE, ClientStandStateChange(0));
    assert(me.auras.list.length == 0);
    anduin.read();

    // Damage over time on the innkeeper (an enemy): three ticks of 5.
    enum uint players = 1, monsters = 8;
    const humans = me.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, players, 0,
        0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    (cast(Player) me).values.set!UNIT_FIELD_LEVEL(60u); // so that the spell is not resisted
    (cast(Player) me).data.level = 60;
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(gash, keeper.guid));
    assert(keeper.auras.list.length == 1 && keeper.values.get!UNIT_FIELD_AURA(32) == gash);
    foreach (_; 0 .. 10)
        tick(1000);
    assert(keeper.values.get!UNIT_FIELD_HEALTH == 485, "three ticks");
    assert(keeper.auras.list.length == 0 && keeper.values.get!UNIT_FIELD_AURA(32) == 0, "and it ended");
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_PERIODICAURALOG) == 3);

    // With +30 holy damage done: 30 times 9 s over 15 s, over 3 ticks: 6 more a tick.
    {
        enum uint devotion = 91005;
        context.data.spells.spells[devotion] = testSpell(devotion, 6, 1, 30);
        context.data.spells.spells.edit(devotion).casting.applyAuraName[0] = AuraType.modDamageDone;
        context.data.spells.spells.edit(devotion).miscValue[0] = 1 << 1; // holy
        import dmangos.world.auras : makeAura;

        auto bonus = makeAura((devotion in context.data.spells.spells), me.guid, 60, -1, true, [30, 0, 0]);
        bonus.passive = true;
        anduin.session.inWorld.addAura(bonus);
        now += 2.seconds;
        anduin.write(Opcode.CMSG_CAST_SPELL, castAt(gash, keeper.guid));
        foreach (_; 0 .. 10)
            tick(1000);
        assert(keeper.values.get!UNIT_FIELD_HEALTH == 485 - 3 * 11, "three ticks of 5 and 6");
        anduin.session.inWorld.removeAura((cast(Player) me).auras.find(devotion));
        anduin.read();
    }

    // Faster; then the buff is clicked off.
    now += 2.seconds;
    anduin.write(Opcode.CMSG_CAST_SPELL, castAt(haste, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_FORCE_RUN_SPEED_CHANGE));
    assert(me.speeds[MoveType.run] == 7.0f * 1.5f);
    ByteWriter cancel;
    cancel.put(haste);
    anduin.write(Opcode.CMSG_CANCEL_AURA, cancel.data);
    assert(me.speeds[MoveType.run] == 7.0f && me.auras.list.length == 0);
}

/// Auras last across a logout: saved with the time they had left, and back at the next login.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.database : AuraRecord;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint wits = 91001;
    context.data.spells.spells[wits] = testSpell(wits, 6, 1, 2);
    context.data.spells.spells.edit(wits).casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells.edit(wits).miscValue[0] = 3;
    context.data.spells.spells.edit(wits).casting.procCharges = 3;
    db.auraRows[7] = [AuraRecord(7, wits, 1, [2, 0, 0], [0, 0, 0], 60_000, 42_000, 1)];
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    assert(me.auras.list.length == 1 && me.auras.list[0].duration == 42_000 && me.values.get!UNIT_FIELD_AURA(0) == wits);
    assert(me.auras.list[0].charges == 3, "old saves without charge counts use the spell default");
    me.auras.list[0].charges = 1;
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    import core.time : seconds;

    anduin.session.update(25.seconds);
    assert(db.auraRows[7].length == 1 && db.auraRows[7][0].remaining > 0, "saved again at logout");
    assert(db.auraRows[7][0].charges == 1);
    auto relog = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    assert((cast(Player) relog.session.character).auras.list[0].charges == 1);
    auto destination = newCreationContext(db);
    destination.data.spells.spells[wits] = *context.data.spells.spell(wits);
    auto relay = new TestPlayerRelay(context, destination);
    context.regionOwnerAround = (uint, Position, float) => destination.nodeId;
    relog.session.update(5.seconds);
    assert((cast(Player) relay.remote.character).auras.list[0].charges == 1);
}

/// Shields: a school absorb takes damage until used up, then goes; a mana shield pays mana for what it takes.
unittest
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto jaina = loggedIn(context, db, 3, "Jaina", Position(-8949.95f, -132.49f, 83.53f, 0));
    jaina.read();
    auto session = jaina.session.inWorld;
    enum uint shield = 91101, manaShield = 91102;
    with (context.data.spells)
    {
        spells[shield] = testSpell(shield, 6, 1, 50);
        spells.edit(shield).casting.applyAuraName[0] = AuraType.schoolAbsorb;
        spells.edit(shield).miscValue[0] = 127; // every school
        spells[manaShield] = testSpell(manaShield, 6, 1, 100);
        spells.edit(manaShield).casting.applyAuraName[0] = AuraType.manaShield;
        spells.edit(manaShield).miscValue[0] = 1; // physical
        spells.edit(manaShield).casting.multipleValue[0] = 2;
    }
    auto me = cast(Player) jaina.session.character;
    session.addAura(makeAura(shield in context.data.spells.spells, me.guid, 1, -1, true, [50, 0, 0]));
    uint damage = 30;
    assert(session.absorbIncoming(4, damage) == 30 && damage == 0, "fire, all of it");
    damage = 30;
    assert(session.absorbIncoming(0, damage) == 20 && damage == 10, "the last 20");
    assert(!me.auras.has(AuraType.schoolAbsorb), "used up: gone");

    // A mana shield: 2 mana a point; with 30 mana it takes 15.
    session.addAura(makeAura(manaShield in context.data.spells.spells, me.guid, 1, -1, true, [100, 0, 0]));
    me.values.set!UNIT_FIELD_POWER1(0, 30u);
    damage = 40;
    assert(session.absorbIncoming(0, damage) == 15 && damage == 25 && me.values.get!UNIT_FIELD_POWER1(0) == 0);
    damage = 10;
    assert(session.absorbIncoming(4, damage) == 0, "fire is not its school");
}

/// A party area aura: its caster's group members near get it, those who move away lose it, and all do when it ends.
unittest
{
    import core.time : msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : spellRadiusFormat;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGroupName;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    import dmangos.bytes : bits = floatBits;
    context.client.spellRadii = typeof(context.client.spellRadii).parse(buildDbc(spellRadiusFormat,
        [[1u, bits(30), 0, 0]]), "SpellRadius.dbc");
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8945, -132.49f, 83.53f));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    assert(context.groups.of(8) !is null);
    enum uint devotion = 97300;
    context.data.spells.spells[devotion] = testSpell(devotion, 35, ImplicitTarget.caster, 25);
    context.data.spells.spells.edit(devotion).casting.applyAuraName[0] = AuraType.modResistance;
    context.data.spells.spells.edit(devotion).casting.radiusIndex[0] = 1;
    auto session = anduin.session.inWorld;
    auto her = cast(Player) jaina.session.character;
    auto him = cast(Player) anduin.session.character;
    session.castTriggeredAt(devotion, 0);
    assert(him.auras.find(devotion) !is null, "on the paladin");
    session.updateAreaAuras(1000.msecs);
    assert(her.auras.find(devotion) !is null, "and on the member near");

    her.movement.position = Position(-8800, -132.49f, 83.53f, 0); // far off
    session.updateAreaAuras(1000.msecs);
    assert(her.auras.find(devotion) is null, "gone as she left");
    her.movement.position = Position(-8945, -132.49f, 83.53f, 0);
    session.updateAreaAuras(1000.msecs);
    assert(her.auras.find(devotion) !is null, "back");

    session.removeAura(him.auras.find(devotion));
    session.updateAreaAuras(1000.msecs);
    assert(her.auras.find(devotion) is null, "gone with the paladin's");
}

/// A dispel updates the gateway checkpoint even when the ordinary character save still has the debuff.
unittest
{
    import dmangos.cluster.protocol : SimulationOwner;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint blue = 23153;
    context.data.spells.spells[blue] = testSpell(blue, SpellEffect.applyAura, 6, 0);
    context.data.spells.spells.edit(blue).casting.applyAuraName[0] = AuraType.modDecreaseSpeed;
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto session = client.session.inWorld;
    client.session.gatewayHome = SimulationOwner(4, 1);
    auto aura = makeAura(context.data.spells.spell(blue), 123, 60, 600_000, false, [10, 0, 0]);
    assert(session.addAura(aura) && db.loadPlayerSummons(7).length, "the newly applied debuff was checkpointed");
    session.saveAuras();
    assert(db.loadAuras(7).length == 1);
    session.removeAura(aura);
    assert(!db.loadPlayerSummons(7).length, "the last encounter aura was removed from the checkpoint");
    session.loadAuras(true);
    assert(session.player.auras.find(blue) is null, "the old periodic save did not resurrect the dispelled aura");
}

/// A root with `SPELL_ATTR_HEARTBEAT_RESIST` on a creature keeps its chance to break, and breaks at a heartbeat.
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.spellcast : spellAttrHeartbeatResist, SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint roots = 91_701;
    context.client.spellDurations = typeof(context.client.spellDurations).parse(imported!"dmangos.dbc".buildDbc(
        imported!"dmangos.world.clientdata".spellDurationFormat, [[6u, 8000, 0, 8000]]), "SpellDuration.dbc");
    context.data.spells.spells[roots] = testSpell(roots, SpellEffect.applyAura, 6, 0); // at the target
    with (context.data.spells.spells.edit(roots))
    {
        casting.durationIndex = 6;
        casting.applyAuraName[0] = AuraType.modRoot;
        attributes = spellAttrHeartbeatResist;
        casting.attributesEx3 = 0x00040000; // SPELL_ATTR_EX3_ALWAYS_HIT: the hit roll left out of the test
        casting.school = 3;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto me = anduin.session.inWorld;
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto keeper = cast(Creature) context.map(0).findObject(innkeeper);
    me.castSpell(context.data.spells.spell(roots), SpellTargets(TargetFlags.unit, innkeeper), true, 0);
    auto aura = keeper.auras.find(roots);
    assert(aura !is null && aura.heartbeatChance > 0, "the chance to miss it, kept");
    aura.duration = 8000;
    aura.setHeartbeatResist(100, 8000); // certain, to see it break
    keeper.updateAuras(context.map(0), 3000);
    assert(keeper.auras.find(roots) !is null);
    keeper.updateAuras(context.map(0), 1500);
    assert(keeper.auras.find(roots) is null, "broken at the heartbeat");
}

// A saved aura of the player's own channel comes back only with its channel: after a crash and a fresh login the
// channel is gone, and so is its aura. Its other auras come back.
unittest
{
    import dmangos.world.database : AuraRecord;
    import dmangos.world.movement : Position;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint evocation = 91_511, blessing = 91_512;
    SpellInfo channel;
    channel.id = evocation;
    channel.attributesEx = 0x04; // channeled
    channel.effect[0] = SpellEffect.applyAura;
    context.data.spells.spells[evocation] = channel;
    SpellInfo buff;
    buff.id = blessing;
    buff.effect[0] = SpellEffect.applyAura;
    context.data.spells.spells[blessing] = buff;
    enum ulong anduin = 7;
    AuraRecord channelled, kept;
    channelled.caster = kept.caster = anduin;
    channelled.spell = evocation;
    kept.spell = blessing;
    channelled.maxDuration = channelled.remaining = 8_000;
    kept.maxDuration = kept.remaining = 60_000;
    channelled.effectMask = kept.effectMask = 1;
    db.auraRows[7] = [channelled, kept];
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto me = client.session.inWorld;
    assert(me.player.auras.find(evocation) is null, "no channel, no channel aura");
    assert(me.player.auras.find(blessing) !is null);
}

/**
 * Sapphiron's freeze comes back from a gateway player's checkpoint with the time it had, however long the crash's
 * outage: his air phase does not count it either, and his breath must find the frozen still frozen. Life Drain loses
 * the outage, as Chromaggus's afflictions do.
 */
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.bytes : ByteReader;
    import dmangos.cluster.protocol : SimulationOwner;
    import dmangos.scripts.naxxramas : Sapphiron;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    foreach (spell; [Sapphiron.icebolt, Sapphiron.iceboltImmunity, Sapphiron.lifeDrain])
    {
        context.data.spells.spells[spell] = testSpell(spell, SpellEffect.applyAura, 6, 0);
        context.data.spells.spells.edit(spell).casting.applyAuraName[0] = spell == Sapphiron.icebolt
            ? AuraType.modStun : spell == Sapphiron.lifeDrain ? AuraType.periodicLeech : AuraType.schoolImmunity;
    }
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto session = client.session.inWorld;
    client.session.gatewayHome = SimulationOwner(4, 1);
    const sapphiron = 0xF130_0000_0000_0100UL | (ulong(15_989) << 24);
    session.addAura(makeAura(context.data.spells.spell(Sapphiron.icebolt), sapphiron, 63, 25_000, false, [0, 0, 0]));
    session.addAura(makeAura(context.data.spells.spell(Sapphiron.iceboltImmunity), 7, 60, 27_000, true, [127, 0, 0]));
    session.addAura(makeAura(context.data.spells.spell(Sapphiron.lifeDrain), sapphiron, 63, 12_000, false, [100, 0, 0]));
    assert(db.loadPlayerSummons(7).length, "the freeze was not checkpointed as it came");
    const saved = session.encounterAuraRecoveryState();
    foreach (spell; [Sapphiron.icebolt, Sapphiron.iceboltImmunity, Sapphiron.lifeDrain])
        session.removeAura(session.player.auras.find(spell));

    // The worker is lost; the player comes back thirty seconds on (longer than any of the three lasts).
    now += 30.seconds;
    auto state = ByteReader(saved);
    session.restoreEncounterAuraRecovery(state);
    auto freeze = session.player.auras.find(Sapphiron.icebolt), immunity = session.player.auras.find(
        Sapphiron.iceboltImmunity);
    assert(freeze !is null && freeze.duration == 25_000 && freeze.caster == sapphiron,
        "the frozen player came back thawed: the outage counted against the freeze");
    assert(immunity !is null && immunity.duration == 27_000, "the frozen player lost the immunity");
    assert(session.player.auras.find(Sapphiron.lifeDrain) is null, "Life Drain outlasted its time");
}

/**
 * Kel'Thuzad's Frost Blast and Detonate Mana come back from a gateway player's checkpoint with the time they had, their
 * next ticks too: his fight's timers do not count a crash's outage, and neither do they.
 */
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.bytes : ByteReader;
    import dmangos.cluster.protocol : SimulationOwner;
    import dmangos.scripts.naxxramas : Kelthuzad;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    foreach (id; [Kelthuzad.frostBlast, Kelthuzad.manaDetonation])
    {
        context.data.spells.spells[id] = testSpell(id, SpellEffect.applyAura, 6, 0);
        context.data.spells.spells.edit(id).casting.applyAuraName[0] = AuraType.dummy;
    }
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto session = client.session.inWorld;
    client.session.gatewayHome = SimulationOwner(4, 1);
    const kelthuzad = 0xF130_0000_0000_0100UL | (ulong(15_990) << 24);
    session.addAura(makeAura(context.data.spells.spell(Kelthuzad.frostBlast), kelthuzad, 63, 4_000, false, [0, 0, 0]));
    session.addAura(makeAura(context.data.spells.spell(Kelthuzad.manaDetonation), kelthuzad, 63, 5_000, false,
        [0, 0, 0]));
    assert(db.loadPlayerSummons(7).length, "the blast was not checkpointed as it came");
    const saved = session.encounterAuraRecoveryState();
    foreach (id; [Kelthuzad.frostBlast, Kelthuzad.manaDetonation])
        session.removeAura(session.player.auras.find(id));

    now += 10.seconds; // the worker is lost; the player comes back ten seconds on (longer than either lasts)
    auto state = ByteReader(saved);
    session.restoreEncounterAuraRecovery(state);
    auto blast = session.player.auras.find(Kelthuzad.frostBlast);
    auto detonate = session.player.auras.find(Kelthuzad.manaDetonation);
    assert(blast !is null && blast.duration == 4_000 && blast.caster == kelthuzad,
        "the Frost Blast came back gone or short: the outage counted against it");
    assert(detonate !is null && detonate.duration == 5_000, "the Detonate Mana came back gone or short");
}

/**
 * The Four Horsemen's marks come back from a gateway player's checkpoint with their stacks: each mark is saved as it
 * stacks, and the outage counts against its time, as against Life Drain's.
 */
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.bytes : ByteReader;
    import dmangos.cluster.protocol : SimulationOwner;
    import dmangos.scripts.naxxramas : markOfKorthazz;
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.spells.spells[markOfKorthazz] = testSpell(markOfKorthazz, SpellEffect.applyAura, 6, 0);
    context.data.spells.spells.edit(markOfKorthazz).casting.applyAuraName[0] = AuraType.dummy;
    context.data.spells.spells.edit(markOfKorthazz).casting.stackAmount = 99;
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto session = client.session.inWorld;
    client.session.gatewayHome = SimulationOwner(4, 1);
    const thane = 0xF130_0000_0000_0100UL | (ulong(16_064) << 24);
    foreach (_; 0 .. 3)
        session.addAura(makeAura(context.data.spells.spell(markOfKorthazz), thane, 63, 75_000, false, [0, 0, 0]));
    assert(session.player.auras.find(markOfKorthazz).stacks == 3);
    assert(db.loadPlayerSummons(7).length, "the mark was not checkpointed as it stacked");
    const saved = session.encounterAuraRecoveryState();
    session.removeAura(session.player.auras.find(markOfKorthazz));

    now += 10.seconds; // the worker is lost; the player comes back ten seconds on
    auto state = ByteReader(saved);
    session.restoreEncounterAuraRecovery(state);
    auto mark = session.player.auras.find(markOfKorthazz);
    assert(mark !is null && mark.stacks == 3 && mark.caster == thane, "the marks did not come back with their stacks");
    assert(mark.duration <= 65_000 && mark.duration > 64_000, "the outage did not count against the mark");
}
