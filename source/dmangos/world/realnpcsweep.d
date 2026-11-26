/**
 * Every spell a creature casts in the data, cast by a creature that casts it, on the real data, each effect checked
 * against what the data says it does: the NPC side of `dmangos.world.realspellsweep`.
 *
 * The spells, read from the world database at the run: `creature_ai_scripts` (the cast action, 11: its first
 * parameter), `creature_spell_list` (by the creatures whose `SpellList` names it), `creature_template_spells`
 * (spell1 .. spell10), `dbscripts_on_*` (the cast command, 15: `datalong` and the `dataint`s it may pick instead,
 * by the creature the script runs on), and the spells the scripts in dmangos/scripts cast (the constants passed to a
 * `cast...(` call in a `@creature` script, by the creatures of that `ScriptName`). Each is cast by one of the
 * creatures that cast it, summoned in a quiet place (no spawn within 250 yards): through `castSpell` of its AI, as
 * EventAI, its spell list, its script and the database scripts call it (the flags they would give), at its target
 * chosen from the spell's implicit targets: itself, a hostile player of its level (a warrior; a mage for what takes
 * mana), a friendly creature (another of its entry, or the creature `spell_script_target` names). Then, its cast
 * time and its first ticks gone by, each effect by its kind: damage took health, a heal was logged, an aura is on
 * the unit its implicit target names (and a stun, fear, disorientation, silence or pacify set its flag, a periodic
 * damage hurt), a persistent area exists or hurt, a summoned creature or object stands near, power was given, a
 * dispel took the aura of its type, a charge moved the caster, a teleport the target, an instant kill killed.
 *
 * A failure is classified (`not done: <effect>`, an effect `dmangos.world.spelleffects.doneBy` says a creature's
 * cast does not do; `aura <type> ...: not on the <unit>`; `targeting: ...`; `refused: <reason>`; `crash: ...`) and
 * is either fixed or listed in tools/harness/realnpc-known.txt: the sweep fails at a failure not listed there and
 * says which listed ones pass now. Runs with the other real-data tests (`DMANGOS_REAL_DATA`); `DMANGOS_NPC_SWEEP_ONLY`
 * (ids, comma separated) sweeps only those, and says what each did; `DMANGOS_NPC_SWEEP_REPORT` names a file the
 * outcome of every spell is written to (`id<TAB>outcome<TAB>source<TAB>casters`).
 */
module dmangos.world.realnpcsweep;

version (unittest):

import core.time : msecs;
import std.algorithm.comparison : among, clamp, max, min;
import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.realspelltests : haveRealData, RealWorld;
import dmangos.world.realspellsweep : harms, hasDispellable, objectNear, summoned, summonsCreature, summonsObject,
    Who, whoOf;
import dmangos.world.spellids : AuraType, ImplicitTarget, SpellEffect;
import dmangos.world.spells : SpellInfo;
import dmangos.world.testclient : TestClient;
import dmangos.world.unit : UnitRef;
import dmangos.world.updatefields;
import dmangos.world.worlddata : WorldData;

/// A spell creatures cast: who casts it (the first is the sweep's caster), with what cast flags, named where.
struct NpcSpell
{
    uint id;
    uint[] casters;   /// creature entries
    uint flags;       /// the caster's cast flags (`dmangos.world.eventai`'s `cast*`)
    string source;    /// eai, list, script, template, dbscript
    int eaiTarget = -1; /// the EventAI cast's target type (0: itself); -1 for any other source
}

// ---------------------------------------------------------------------------------------------------------------
// The set
// ---------------------------------------------------------------------------------------------------------------

/// Column `k` of `row` if it is a positive number that fits a `uint`, else 0.
private uint positive(R)(const ref R row, size_t k)
{
    const v = row.get!long(k);
    return v > 0 && v <= uint.max ? cast(uint) v : 0;
}

/// The world database the real data was loaded from (`DMANGOS_REAL_DATA`'s third part), and the MySQL library.
private string[2] worldConnection()
{
    import std.array : split;
    import std.process : environment;

    const parts = environment.get("DMANGOS_REAL_DATA").split("|");
    return [parts[2], parts[1]];
}

/**
 * The spells creatures cast, from the world database and the scripts' sources; each with every creature entry
 * that casts it, the first of the most direct source (EventAI, a spell list, a script, the template's spells, a
 * database script) first. Spells not in the data are left out.
 */
NpcSpell[] npcSpells(const WorldData data)
{
    import std.algorithm.sorting : sort;
    import dmangos.mysql : ConnectionInfo, MySqlConnection;

    const named = worldConnection();
    auto db = new MySqlConnection(ConnectionInfo.parse(named[0]), named[1]);
    scope (exit)
        db.close();

    NpcSpell[uint] found;
    void add(uint spell, uint entry, string source, uint flags, int eaiTarget = -1)
    {
        if (spell == 0 || data.spells.spell(spell) is null)
            return;
        auto sp = spell in found;
        if (sp is null)
        {
            found[spell] = NpcSpell(spell, null, flags, source);
            sp = spell in found;
        }
        if (entry && (entry in data.creatureTemplates) !is null && !sp.casters.canFind(entry))
        {
            if (!sp.casters.length) // the first real caster's source and flags
            {
                sp.source = source;
                sp.flags = flags;
                sp.eaiTarget = eaiTarget;
            }
            sp.casters ~= entry;
        }
    }

    // EventAI: the cast action (11), its spell, its flags.
    enum eaiCast = 11, eaiRelay = 53;
    uint[][uint] relayCreatures; // relay script -> the creatures whose EventAI starts it
    foreach (row; db.query!("SELECT creature_id, action1_type, action1_param1, action1_param3, action1_param2, "
            ~ "action2_type, action2_param1, action2_param3, action2_param2, action3_type, action3_param1, "
            ~ "action3_param3, action3_param2 FROM creature_ai_scripts")())
        foreach (k; 0 .. 3)
        {
            const type = positive(row, 1 + 4 * k), param = positive(row, 2 + 4 * k);
            if (type == eaiCast && param > 0)
                add(param, positive(row, 0), "eai", positive(row, 3 + 4 * k), cast(int) positive(row, 4 + 4 * k));
            else if (type == eaiRelay && param > 0)
                relayCreatures[param] ~= positive(row, 0);
        }
    // Spell lists: by the creatures whose `SpellList` names the list (else the entry its id is a hundred times).
    uint[][uint] listCreatures;
    foreach (row; db.query!"SELECT Entry, SpellList FROM creature_template WHERE SpellList <> 0"())
        listCreatures[positive(row, 1)] ~= positive(row, 0);
    foreach (row; db.query!"SELECT Id, SpellId FROM creature_spell_list ORDER BY Id, Position"())
    {
        const list = positive(row, 0), spell = positive(row, 1);
        if (auto who = list in listCreatures)
            foreach (entry; *who)
                add(spell, entry, "list", 0);
        else
            add(spell, list / 100, "list", 0);
    }
    // The scripts' own.
    foreach (name, spells; scriptSpells(data))
        foreach (entry, scriptName; data.creatureScriptNames)
            if (scriptName == name)
                foreach (spell; spells)
                    add(spell, entry, "script", 0);
    // The template's (a pet's, a totem's, a charmed creature's bar).
    foreach (row; db.query!("SELECT entry, spell1, spell2, spell3, spell4, spell5, spell6, spell7, spell8, spell9, "
            ~ "spell10 FROM creature_template_spells")())
        foreach (k; 1 .. 11)
            add(positive(row, k), positive(row, 0), "template", 0);
    // Database scripts: by the creature each runs on (its buddy, if the buddy is the source).
    {
        enum uint castTriggered = 0x02, buddyAsTarget = 0x01, reverseDirection = 0x02;
        uint[][uint] movementCreatures, questStarters, questEnders, gossipCreatures;
        foreach (row; db.query!"SELECT Entry, ScriptId FROM creature_movement_template WHERE ScriptId <> 0"())
            movementCreatures[positive(row, 1)] ~= positive(row, 0);
        foreach (row; db.query!("SELECT c.id, m.ScriptId FROM creature_movement m JOIN creature c ON c.guid = m.Id "
                ~ "WHERE m.ScriptId <> 0")())
            movementCreatures[positive(row, 1)] ~= positive(row, 0);
        foreach (row; db.query!("SELECT r.id, q.StartScript FROM creature_questrelation r JOIN quest_template q "
                ~ "ON q.entry = r.quest WHERE q.StartScript <> 0")())
            questStarters[positive(row, 1)] ~= positive(row, 0);
        foreach (row; db.query!("SELECT r.id, q.CompleteScript FROM creature_involvedrelation r JOIN quest_template q "
                ~ "ON q.entry = r.quest WHERE q.CompleteScript <> 0")())
            questEnders[positive(row, 1)] ~= positive(row, 0);
        foreach (row; db.query!("SELECT t.Entry, g.script_id FROM gossip_menu g JOIN creature_template t "
                ~ "ON t.GossipMenuId = g.entry WHERE g.script_id <> 0 UNION SELECT t.Entry, o.action_script_id "
                ~ "FROM gossip_menu_option o JOIN creature_template t ON t.GossipMenuId = o.menu_id "
                ~ "WHERE o.action_script_id <> 0")())
            gossipCreatures[positive(row, 1)] ~= positive(row, 0);
        void scripts(string table)(uint[] delegate(uint id) creaturesOf)
        {
            foreach (row; db.query!("SELECT id, datalong, buddy_entry, data_flags, dataint, dataint2, dataint3, "
                    ~ "dataint4 FROM " ~ table ~ " WHERE command = 15")())
            {
                const id = positive(row, 0), buddy = positive(row, 2), flags = positive(row, 3);
                // CMaNGOS: a buddy found is the source (unless it is the target), the two swapped by
                // `SCRIPT_FLAG_REVERSE_DIRECTION`.
                bool buddySource = buddy && !(flags & buddyAsTarget);
                if (buddy && (flags & reverseDirection))
                    buddySource = !buddySource;
                const(uint)[] who = buddySource ? [buddy] : creaturesOf is null ? null : creaturesOf(id);
                uint[] spells = [positive(row, 1)];
                foreach (k; 4 .. 8)
                    if (positive(row, k) > 0)
                        spells ~= positive(row, k);
                foreach (spell; spells)
                {
                    add(spell, 0, "dbscript", castTriggered);
                    foreach (entry; who)
                        add(spell, entry, "dbscript", castTriggered);
                }
            }
        }
        uint[] none(uint) { return null; }
        scripts!"dbscripts_on_creature_movement"(id => id in movementCreatures ? movementCreatures[id] : null);
        scripts!"dbscripts_on_creature_death"(id => [id]);
        scripts!"dbscripts_on_quest_start"(id => id in questStarters ? questStarters[id] : null);
        scripts!"dbscripts_on_quest_end"(id => id in questEnders ? questEnders[id] : null);
        scripts!"dbscripts_on_gossip"(id => id in gossipCreatures ? gossipCreatures[id] : null);
        scripts!"dbscripts_on_relay"(id => id in relayCreatures ? relayCreatures[id] : null);
        scripts!"dbscripts_on_event"(&none);
        scripts!"dbscripts_on_spell"(&none);
        scripts!"dbscripts_on_go_use"(&none);
        scripts!"dbscripts_on_go_template_use"(&none);
    }
    auto spells = found.values;
    spells.sort!((a, b) => a.id < b.id);
    return spells;
}

/**
 * The spells each creature script of dmangos/scripts casts, by its `ScriptName`: in each `@creature("...")`
 * script, the constants (or numbers) given to a `cast...(` call, as its first argument, else its second (a
 * `castSpell(caster, spell)`), resolved by the script's own constants first, then the file's.
 */
private uint[][string] scriptSpells(const WorldData data)
{
    import std.conv : to;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildNormalizedPath, dirName;
    import std.regex : ctRegex, matchAll;
    import std.string : indexOf, strip;

    enum constant = ctRegex!`\b([A-Za-z_]\w*)\s*=\s*(\d[\d_]*)u?\b`;
    enum call = ctRegex!`\bcast[A-Z]\w*\(\s*([^,\)]*)(?:,\s*([^,\)]*))?`;
    enum token = ctRegex!`[A-Za-z_]\w*|\d[\d_]*`;
    enum attribute = ctRegex!`(?m)^@(\w+)\("([^"]*)"\)`;
    uint[string] constantsOf(string text)
    {
        uint[string] found;
        foreach (m; matchAll(text, constant))
            if (m[1] !in found)
            {
                import std.array : replace;

                const digits = m[2].replace("_", "");
                if (digits.length < 10)
                    found[m[1]] = digits.to!ulong > uint.max ? 0 : digits.to!uint;
            }
        return found;
    }

    uint[][string] result;
    const dir = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "..", "scripts");
    foreach (file; dirEntries(dir, "*.d", SpanMode.shallow))
    {
        const text = readText(file.name);
        const global = constantsOf(text);
        // Each attributed script: from its attribute to the next.
        size_t[] starts;
        string[] kinds, names;
        foreach (m; matchAll(text, attribute))
        {
            starts ~= m.pre.length;
            kinds ~= m[1];
            names ~= m[2];
        }
        foreach (k, start; starts)
        {
            if (kinds[k] != "creature")
                continue;
            const block = text[start .. k + 1 < starts.length ? starts[k + 1] : text.length];
            const local = constantsOf(block);
            uint resolve(string arg)
            {
                foreach (t; matchAll(arg, token))
                {
                    const word = t.hit;
                    uint id;
                    if (word[0] >= '0' && word[0] <= '9')
                    {
                        import std.array : replace;

                        const digits = word.replace("_", "");
                        id = digits.length < 10 ? digits.to!uint : 0;
                    }
                    else if (const v = word in local)
                        id = *v;
                    else if (const v = word in global)
                        id = *v;
                    if (id > 0 && data.spells.spell(id) !is null)
                        return id;
                }
                return 0;
            }
            foreach (m; matchAll(block, call))
            {
                auto id = resolve(m[1]);
                if (!id && m[2].length)
                    id = resolve(m[2]);
                if (id && !result.get(names[k], null).canFind(id))
                    result[names[k]] ~= id;
            }
        }
    }
    return result;
}

// ---------------------------------------------------------------------------------------------------------------
// What a creature's cast does not do yet (`dmangos.world.spelleffects.doneBy`), to name a failure's cause
// ---------------------------------------------------------------------------------------------------------------

private bool notDoneByCreatures(const ref SpellInfo spell, size_t effect)
{
    import dmangos.world.spelleffects : doneBy;
    import dmangos.world.unit : UnitKind;

    return !doneBy(UnitKind.creature, spell, effect);
}

// ---------------------------------------------------------------------------------------------------------------
// One cast
// ---------------------------------------------------------------------------------------------------------------

/// What one spell's sweep came to.
struct NpcOutcome
{
    bool ok;
    string why;      /// the failure, its cause first
    bool mayRoll;    /// it failed where a roll may have (a miss, a resist): worth another try
    bool unchecked;  /// it passed with none of its effects checked (a dummy's, a script's, no oracle)
}

/// The quiet place: on Eastern Kingdoms, no spawn within 250 yards (its height looked up at the start).
private enum float spotX = 3050, spotY = -2050;

private final class NpcSweeper
{
    RealWorld w;
    Position spot;
    uint nextGuid = 5000;
    bool verbose;

    this(RealWorld w, bool verbose)
    {
        this.w = w;
        this.verbose = verbose;
        auto map = w.context.map(0);
        spot = Position(spotX, spotY, 0);
        spot.z = map.groundHeight(spotX, spotY, 1000, false);
        if (spot.z < -1000)
            spot.z = 0;
    }

    NpcOutcome sweep(const NpcSpell sp)
    {
        NpcOutcome last;
        foreach (attempt; 0 .. 5) // a miss, a dodge, a resist: again (a fault fails every time)
        {
            // Its own rolls, whatever was swept before it: the same result at every run.
            {
                import std.random : rndGen;

                const seed = sp.id * 8u + attempt;
                foreach (map; w.context.allMaps)
                    map.random.seed(seed);
                rndGen.seed(seed);
            }
            try
                last = once(sp);
            catch (Throwable t)
            {
                import std.string : lineSplitter;
                import std.range : front;

                const msg = t.msg.length ? t.msg.lineSplitter.front : typeid(t).name;
                last = NpcOutcome(false, format!"crash: %s (%s:%s)"(msg, baseName(t.file), t.line), false);
                w = RealWorld.make(); // what it left behind is not to be trusted
            }
            if (last.ok || !last.mayRoll)
                break;
        }
        return last;
    }

    private static string baseName(string file)
    {
        import std.path : baseName;

        return baseName(file);
    }

    private NpcOutcome once(const NpcSpell sp)
    {
        import std.math : abs, cos, sin, sqrt;
        import dmangos.bytes : ByteReader, ByteWriter;
        import dmangos.world.creaturecasting : isArcaneMissilesChannel;
        import dmangos.world.eventai : castForceTargetSelf;
        import dmangos.world.movement : jumpGravity, MovementFlags, MovementInfo;
        import dmangos.world.packets : ClientTeleportAck;
        import dmangos.world.relations : canAttack;
        import dmangos.world.spellcast : castTime, isNextMeleeSwingSpell, radius, range;

        auto context = w.context;
        auto map = context.map(0);
        const data = context.data;
        const s = data.spells.spell(sp.id);
        const teleportsPlayer = s.hasEffect(SpellEffect.teleportUnits) || s.hasEffect(SpellEffect.teleportUnitsFaceCaster);
        const pullsPlayer = s.hasEffect(SpellEffect.pullTowards);
        const moves = teleportsPlayer || pullsPlayer || s.hasEffect(SpellEffect.leap);
        const destination = teleportsPlayer ? sp.id in data.spellTargets : null;
        // Its first caster; one that can pay for it if the first cannot (a level 35 Sea Witch has a Blizzard of 1400
        // mana among her spells, more than she has: she never casts it, Volida does).
        uint entry = sp.casters[0];
        {
            import dmangos.world.spellcast : powerCost;

            bool affords(uint e)
            {
                const ct = e in data.creatureTemplates;
                if (ct is null || s.casting.powerType != 0)
                    return true;
                return powerCost(*s, ct.maxLevel, ct.maxLevelMana, ct.maxLevelHealth, ct.maxLevelMana) <= ct.maxLevelMana;
            }
            if (!affords(entry))
                foreach (other; sp.casters[1 .. $])
                    if (affords(other))
                    {
                        entry = other;
                        break;
                    }
        }
        const t = entry in data.creatureTemplates;
        string[] problems;
        bool mayRoll, checkedAny;

        // Who each effect is at: the scripted targets (`spell_script_target`) are a friend of that entry.
        const scripted = data.spellScriptTargets.get(sp.id, null);
        // A spell of no range (`Self Only`) is cast at itself, its friend that, unless it names a single enemy
        // (reached in melee, as CMaNGOS reaches it).
        const r = range(*s, context.client);
        bool singleEnemy;
        foreach (i; 0 .. 3)
            singleEnemy |= s.effect[i] && (s.implicitTargetA[i] == ImplicitTarget.enemy
                || (s.implicitTargetA[i] == ImplicitTarget.unit && harms(*s)));
        const atItself = r[1] == 0 && !singleEnemy;
        Who who(size_t i)
        {
            const a = s.implicitTargetA[i], b = s.casting.implicitTargetB[i];
            if (s.effect[i] == SpellEffect.pullTowards && a == ImplicitTarget.unit)
                return Who.enemy; // Magnetic Pull's explicit target is a player.
            with (ImplicitTarget)
                if (scripted.length && (a.among(unitScriptNearCaster, enumUnitsScriptAoeAtSrcLoc,
                        enumUnitsScriptAoeAtDestLoc, enumUnitsScriptInCone60) || b.among(unitScriptNearCaster,
                        enumUnitsScriptAoeAtSrcLoc, enumUnitsScriptAoeAtDestLoc, enumUnitsScriptInCone60)))
                    return Who.friend;
            const by = whoOf(*s, i, true);
            // A friend's spell its script casts at itself (`CAST_FORCE_TARGET_SELF`: a Cannibal Ghoul's Health
            // Funnel heals the ghoul) is at the caster.
            const self = atItself || (sp.flags & castForceTargetSelf);
            return by == Who.pet ? Who.nobody : by == Who.friend && self ? Who.caster : by;
        }
        bool any(Who wanted)
        {
            foreach (i; 0 .. 3)
                if (s.effect[i] && who(i) == wanted)
                    return true;
            return false;
        }
        const missiles = isArcaneMissilesChannel(*s);
        const wantsEnemy = missiles || any(Who.enemy), wantsFriend = any(Who.friend);

        // The hostile player: of the caster's level, a mage where mana is taken.
        bool takesMana;
        foreach (i; 0 .. 3)
            takesMana |= (s.effect[i].among(SpellEffect.powerBurn, SpellEffect.powerDrain) && s.miscValue[i] == 0)
                || (s.effect[i] == SpellEffect.applyAura && s.casting.applyAuraName[i].among(
                    AuraType.periodicManaLeech, AuraType.powerBurnMana) && s.miscValue[i] == 0);
        const level = clamp(t.maxLevel, 1, 60);
        // (A spell of no range at an enemy, Black Arrow, reaches as far as the two combat reaches: in melee, a yard.)
        const distance = r[1] == 0 ? 1.0f : r[1] <= 5 ? 2.0f : max(2.0f, min(r[0] + (pullsPlayer ? 20 : 3), r[1] - 1));
        const facing = moves ? PI / 4 : 0;
        auto heroAt = spot;
        heroAt.x += distance * cos(facing);
        heroAt.y += distance * sin(facing);
        heroAt.orientation = moves ? 0 : PI;
        const guid = nextGuid++;
        auto hero = player(guid, takesMana ? 8 : 1, level, heroAt);
        auto me = hero.session.inWorld;
        const speedSlack = context.config.movementSpeedSlack;
        scope (exit) context.config.movementSpeedSlack = speedSlack;
        if (pullsPlayer)
            context.config.movementSpeedSlack = 1; // Reports must qualify for the server's pull allowance.
        if (destination !is null && context.instanceable(destination.map))
        {
            // A boss casts its raid-room teleport within its own copy. Start the test player in that copy.
            if (!me.teleportTo(destination.map, heroAt, null, uint.max, true))
                return NpcOutcome(false, "could not place the player in the raid fixture");
            hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
            hero.read();
            map = me.currentMap;
        }
        const startInstance = me.instanceId;
        Creature caster, friend;
        scope (exit)
        {
            foreach (o; map.objectsNear(spot, 120))
                if (o.guid != me.player.guid && imported!"dmangos.world.objects".highGuidOf(o.guid)
                        != imported!"dmangos.world.objects".HighGuid.player)
                    map.removeObject(o.guid);
            hero.write(Opcode.CMSG_LOGOUT_REQUEST, null);
        }

        // The caster, and its friend; neither fights on its own.
        caster = context.summonCreature(map, entry, spot, TempSpawnType.manual, 0, 0);
        if (caster is null)
            return NpcOutcome(false, format!"no caster: creature %s not summoned"(entry));
        void quiet(Creature c)
        {
            c.ai.bind(map);
            c.ai.setScript(null, data.eventAi);
            c.ai.releaseBehaviour(); // its script's own casts not mixed with the sweep's
            c.ai.scriptReactState(0);
            c.ai.scriptMelee(false);
            c.ai.scriptCombatMovement(false);
            foreach (power; 0 .. 5)
                c.values.set!UNIT_FIELD_POWER1(power, c.values.get!UNIT_FIELD_MAXPOWER1(power));
        }
        quiet(caster);
        caster.movement.position.orientation = facing;
        // An enemy of the player for what harms it (one friendly to it is made a monster: as it would cast at its
        // enemies).
        auto heroUnit = map.unit(me.player.guid);
        const hostileSpell = harms(*s) || pullsPlayer || missiles;
        // What keeps it out of a fight (immune to players, not attackable: what its event takes off) taken off.
        void fighting(Creature c)
        {
            import dmangos.world.defines : UnitFlags;

            enum uint peaceful = UnitFlags.spawning | UnitFlags.notAttackable1 | UnitFlags.immuneToPlayer
                | UnitFlags.immuneToNpc | UnitFlags.untargetable | UnitFlags.uninteractible;
            c.values.set!UNIT_FIELD_FLAGS(c.values.get!UNIT_FIELD_FLAGS & ~peaceful);
        }
        if (hostileSpell)
            fighting(caster);
        // Free of what its spawn holds it in (Thaddius stunned until his adds die, a target dummy's spawn stun): a
        // creature so held casts nothing, as in CMaNGOS.
        {
            import dmangos.world.defines : UnitFlags;

            enum uint held = UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused | UnitFlags.silenced
                | UnitFlags.pacified;
            caster.values.set!UNIT_FIELD_FLAGS(caster.values.get!UNIT_FIELD_FLAGS & ~held);
        }
        const makeHostile = hostileSpell && !canAttack(caster.ai.relatingOf, heroUnit.relating, context.client);
        if (makeHostile)
            caster.ai.scriptFaction(14);
        if (wantsFriend)
        {
            auto at = spot;
            at.y += 3;
            friend = context.summonCreature(map, scripted.length ? scripted[0] : entry, at, TempSpawnType.manual, 0, 0);
            if (friend is null)
                return NpcOutcome(false, format!"no friend: creature %s not summoned"(scripted.length ? scripted[0] : entry));
            quiet(friend);
            if (hostileSpell)
                fighting(friend);
            if (makeHostile)
                friend.ai.scriptFaction(14);
        }
        hero.read();

        UnitRef unitOf(Who x)
        {
            final switch (x)
            {
            case Who.nobody, Who.pet: return UnitRef.init;
            case Who.caster: return map.unitOf(caster);
            case Who.enemy: return map.unit(me.player.guid);
            case Who.friend: return friend is null ? UnitRef.init : map.unitOf(friend);
            }
        }
        string kindOf(Who x)
        {
            final switch (x)
            {
            case Who.nobody, Who.pet: return "nobody";
            case Who.caster: return "caster";
            case Who.enemy: return "player";
            case Who.friend: return friend !is null && scripted.length ? "scripted creature" : "friendly creature";
            }
        }

        // Hurt where it heals, drained where it gives power, an aura to take where it dispels.
        foreach (i; 0 .. 3)
        {
            auto unit = unitOf(who(i));
            if (!unit)
                continue;
            auto fields = unit.fields;
            with (SpellEffect) switch (s.effect[i])
            {
            case heal, healMaxHealth, healMechanical:
                fields.set!UNIT_FIELD_HEALTH(max(1, fields.get!UNIT_FIELD_MAXHEALTH / 2));
                break;
            case energize:
                if (s.miscValue[i] >= 0 && s.miscValue[i] < 5)
                    fields.set!UNIT_FIELD_POWER1(s.miscValue[i], fields.get!UNIT_FIELD_MAXPOWER1(s.miscValue[i]) / 2);
                break;
            case dispel:
                if (const aura = dispellable(data, s.miscValue[i], unit.combatGuid != me.player.guid))
                    putAura(unit, aura, me.player.guid);
                break;
            default:
                break;
            }
        }
        // A resurrection is at the player, dead (Mandokir's chained spirits revive the raid's dead).
        const raisesHero = s.hasEffect(SpellEffect.resurrect) || s.hasEffect(SpellEffect.resurrectNew);
        if (raisesHero)
        {
            import dmangos.world.unit : Blow;

            me.sufferDamage(UnitRef.init, 100_000_000, Blow.spell());
        }
        hero.read();

        // Its target: the player for what is at an enemy, else its friend, else itself.
        ulong target = wantsEnemy ? me.player.guid : wantsFriend && friend !is null ? friend.guid : caster.guid;
        // A spell of no range (around itself) is cast at itself, as its script would.
        // One its script makes its target cast on itself (`CAST_FORCE_TARGET_SELF`) is at the player if it is at an
        // enemy (Mark of Detonation), else at itself.
        if (((sp.flags & castForceTargetSelf) && (!wantsEnemy || sp.eaiTarget == 0)) || atItself)
            target = caster.guid;
        // So is a flight (William Kielar's gossip sends the player to Naxxramas).
        const flies = s.hasEffect(SpellEffect.sendTaxi);
        if (raisesHero || flies)
            target = me.player.guid;
        // The player at the path's first node: a flight begins there, as the gossip's player stands by it.
        foreach (i; 0 .. 3)
            if (s.effect[i] == SpellEffect.sendTaxi)
                if (const path = context.client.taxiPaths.lookup(cast(uint) s.miscValue[i]))
                    if (const node = context.client.taxiNodes.lookup(path.from))
                        if (node.mapId == map.id)
                            me.player.movement.position = Position(node.x, node.y, node.z, 0);
        // A spell whose script passes the player over (Scourge Strike kills the invasion's defenders, not players:
        // `TargetChecked`) has nothing to show at the player.
        if (target == me.player.guid)
        {
            bool kept;
            foreach (i; 0 .. 3)
                kept |= s.effect[i] && caster.ai.scriptPicked(s, i, [me.player.guid]).length > 0;
            if (!kept)
                return NpcOutcome(true, null, false, true);
        }
        const drunkBefore = me.player.drunk;
        bool resurrectAsked;

        // What there is before.
        const all = [Who.caster, Who.enemy, Who.friend];
        uint[3] healthOf, powerOf;
        bool[3] dispellableBefore;
        foreach (i; 0 .. 3)
            if (auto unit = unitOf(who(i)))
            {
                healthOf[i] = unit.fields.get!UNIT_FIELD_HEALTH;
                const power = s.effect[i] == SpellEffect.energize ? s.miscValue[i] : 0;
                if (power >= 0 && power < 5)
                    powerOf[i] = unit.fields.get!UNIT_FIELD_POWER1(power);
                if (s.effect[i] == SpellEffect.dispel)
                    dispellableBefore[i] = hasDispellable(unit, s.miscValue[i]);
            }
        const casterBefore = caster.position;
        const playerBefore = me.player.position;
        const contact = pullsPlayer ? caster.values.get!UNIT_FIELD_BOUNDINGRADIUS
            + me.player.values.get!UNIT_FIELD_BOUNDINGRADIUS : 0;
        uint[Who] displayBefore;
        foreach (x; all)
            if (auto unit = unitOf(x))
                displayBefore[x] = unit.fields.get!UNIT_FIELD_DISPLAYID;

        // The cast, as its AI casts it.
        const ok = caster.ai.castSpell(s, target, sp.flags);
        map.wake(caster.guid);
        if (!ok)
            return NpcOutcome(false, format!"refused: %s"(caster.ai.castRefusal));
        // A spell on its next swing goes with the swing: it fights the player.
        const onSwing = isNextMeleeSwingSpell(*s);
        if (onSwing)
        {
            caster.ai.scriptReactState(1); // defensive: a passive one attacks nothing
            caster.ai.scriptMelee(true);
            caster.ai.scriptAttack(me.player.guid);
        }

        // Its cast time, then its first ticks.
        int amplitude;
        foreach (i; 0 .. 3)
            if (s.effect[i].among(SpellEffect.applyAura, SpellEffect.persistentAreaAura, SpellEffect.applyAreaAuraParty))
                amplitude = max(amplitude, s.casting.amplitude[i]);
        const total = ((sp.flags & 0x02) ? 0 : castTime(*s, context.client, caster.values.get!UNIT_FIELD_LEVEL))
            + 1200 + min(amplitude, 5000) + (amplitude ? 300 : 0);
        bool[Who][3] auraSeen;
        bool[Who][3] flagSeen;
        bool[3] summonSeen, healLogged;
        bool[ulong] damageLogged; // the units its damage log names
        bool areaSeen, displayChanged;
        // A transform into the look it has (Plucky's chicken form, back from the human one his script gave him: its
        // creature is himself) changes nothing to see.
        bool intoOwnLook(size_t i, Who x)
        {
            auto unit = unitOf(x);
            const t = cast(uint) s.miscValue[i] in data.creatureTemplates;
            if (!unit || t is null || x !in displayBefore)
                return false;
            foreach (model; t.modelIds)
                if (model && model != displayBefore[x])
                    return false;
            return true;
        }
        uint[3] leastHealth = healthOf, mostPower = powerOf;
        bool[Who] diedSeen;
        bool landed;
        MovementInfo flight;
        int launchMs;
        bool pullInFlight, pullLanded;
        enum step = 200;
        for (int ms = 0; ms <= total; ms += step)
        {
            if (ms)
            {
                w.now += step.msecs;
                me.update(step.msecs);
                map.update(step.msecs);
                map.wake(caster.guid);
            }
            foreach (p; hero.read())
                if (pullsPlayer && p.opcode == Opcode.SMSG_MOVE_KNOCK_BACK)
                {
                    auto packet = ByteReader(p.body_);
                    const pulledGuid = packet.readPackedGuid();
                    const order = packet.read!uint;
                    flight.jumpCos = packet.read!float;
                    flight.jumpSin = packet.read!float;
                    flight.jumpXySpeed = packet.read!float;
                    flight.jumpVelocity = packet.read!float;
                    flight.flags = MovementFlags.jumping;
                    flight.position = playerBefore;
                    ByteWriter ack;
                    ack.put(pulledGuid);
                    ack.put(order);
                    flight.write(ack);
                    hero.write(Opcode.CMSG_MOVE_KNOCK_BACK_ACK, ack.data);
                    launchMs = ms;
                    pullInFlight = true;
                }
                else if (teleportsPlayer && p.opcode == Opcode.MSG_MOVE_TELEPORT_ACK)
                {
                    hero.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
                    landed = true;
                }
                else if (teleportsPlayer && p.opcode == Opcode.SMSG_NEW_WORLD)
                {
                    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
                    landed = true;
                }
                else if (p.opcode == Opcode.SMSG_RESURRECT_REQUEST)
                    resurrectAsked = true;
                else if (p.opcode == Opcode.SMSG_SPELLHEALLOG)
                {
                    auto rd = ByteReader(p.body_);
                    const healed = rd.readPackedGuid();
                    rd.readPackedGuid();
                    const spell = rd.read!uint, amount = rd.read!uint;
                    if (spell == sp.id && amount > 0)
                        foreach (i; 0 .. 3)
                            if (auto unit = unitOf(who(i)))
                                healLogged[i] |= unit.combatGuid == healed;
                }
                else if (p.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
                {
                    auto rd = ByteReader(p.body_);
                    const hurt = rd.readPackedGuid();
                    rd.readPackedGuid();
                    const spell = rd.read!uint, amount = rd.read!uint;
                    if (spell == sp.id && amount > 0)
                        damageLogged[hurt] = true;
                    if (verbose)
                        imported!"std.stdio".stderr.writefln("  %s: %s %(%02x %)", ms, cast(Opcode) p.opcode, p.body_);
                }
                else if (verbose && p.opcode.among(Opcode.SMSG_SPELL_GO, Opcode.SMSG_SPELL_START,
                        Opcode.SMSG_SPELL_FAILURE, Opcode.SMSG_SPELLLOGMISS, Opcode.SMSG_SPELLNONMELEEDAMAGELOG))
                    imported!"std.stdio".stderr.writefln("  %s: %s %(%02x %)", ms, cast(Opcode) p.opcode, p.body_);
                else if (p.opcode == Opcode.SMSG_SPELLLOGMISS)
                    mayRoll = true;
            if (pullInFlight && ms > launchMs)
            {
                const duration = -2 * flight.jumpVelocity / jumpGravity; // Both ends are on level ground.
                const elapsed = (ms - launchMs) / 1000.0f;
                const secondsInAir = min(elapsed, duration);
                auto report = flight;
                report.position.x += secondsInAir * flight.jumpXySpeed * flight.jumpCos;
                report.position.y += secondsInAir * flight.jumpXySpeed * flight.jumpSin;
                report.position.z -= secondsInAir * (flight.jumpVelocity + jumpGravity * secondsInAir / 2);
                const landing = elapsed >= duration;
                if (landing)
                    report.flags = MovementFlags.none;
                ByteWriter body;
                report.write(body);
                hero.write(landing ? Opcode.MSG_MOVE_FALL_LAND : Opcode.MSG_MOVE_HEARTBEAT, body.data);
                if (landing)
                {
                    pullInFlight = false;
                    pullLanded = me.player.position == report.position && me.spellPull.speed == 0;
                }
            }
            foreach (i; 0 .. 3)
            {
                foreach (x; all)
                    if (auto unit = unitOf(x))
                        if (auto set = unit.auraSet)
                            if (set.find(sp.id) !is null)
                            {
                                auraSeen[i][x] = true;
                                if (s.effect[i] == SpellEffect.applyAura)
                                    if (const flag = flagOf(s.casting.applyAuraName[i]))
                                        flagSeen[i][x] = flagSeen[i].get(x, false) || (unit.unitFlags & flag) != 0;
                            }
                if (auto unit = unitOf(who(i)))
                {
                    leastHealth[i] = min(leastHealth[i], unit.fields.get!UNIT_FIELD_HEALTH);
                    const power = s.effect[i] == SpellEffect.energize ? s.miscValue[i] : 0;
                    if (power >= 0 && power < 5)
                        mostPower[i] = max(mostPower[i], unit.fields.get!UNIT_FIELD_POWER1(power));
                }
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    summonSeen[i] = summonsObject(s.effect[i]) ? objectNear(map, spot, s.miscValue[i])
                        : summonsCreature(s.effect[i]) && summoned(map, spot, s.miscValue[i]);
            }
            foreach (x; all)
                if (auto unit = unitOf(x))
                {
                    if (!unit.alive)
                        diedSeen[x] = true;
                    if (x in displayBefore && unit.fields.get!UNIT_FIELD_DISPLAYID != displayBefore[x])
                        displayChanged = true;
                }
            foreach (o; map.objectsNear(spot, 60))
                if (auto spotOf = cast(imported!"dmangos.world.dynobject".DynamicObject) o)
                    areaSeen |= spotOf.values.get!DYNAMICOBJECT_SPELLID == sp.id;
        }

        // Each effect.
        foreach (i; 0 .. 3)
        {
            const effect = s.effect[i];
            if (effect == SpellEffect.none)
                continue;
            const x = who(i);
            auto unit = unitOf(x);
            const name = kindOf(x);
            string failed; // what is wrong with this effect; null: nothing (or nothing to check)
            bool checked = true;
            with (SpellEffect) switch (effect)
            {
            case schoolDamage, weaponDamage, weaponDamageNoschool, normalizedWeaponDmg, weaponPercentDamage,
                    healthLeech, environmentalDamage, powerBurn:
                if (unit && !damageLogged.get(unit.combatGuid, false)
                        && (onSwing || (leastHealth[i] >= healthOf[i] && !diedSeen.get(x, false))))
                {
                    failed = format!"no damage to the %s"(name);
                    mayRoll = true;
                }
                break;
            case heal, healMaxHealth, healMechanical:
                // A heal of nothing (Divining Chant, Magic Backlash: a visual) has nothing to see.
                if (effect != healMaxHealth && imported!"dmangos.world.spellcast".effectValue(*s, i, 60, 1) <= 0)
                    checked = false;
                else if (unit && !healLogged[i])
                    failed = format!"no heal of the %s"(name);
                break;
            case applyAura, applyAreaAuraParty, applyAreaAuraFriend, applyAreaAuraEnemy, applyAreaAuraPet:
                if (!unit)
                    break;
                const kind = s.casting.applyAuraName[i];
                if (s.id == 5246 && i != 0)
                {
                    if (auraSeen[i].get(x, false))
                        failed = "Intimidating Shout's primary target also received the area aura";
                    break;
                }
                if (!auraSeen[i].get(x, false))
                {
                    string elsewhere;
                    foreach (other; all)
                        if (other != x && auraSeen[i].get(other, false))
                            elsewhere = kindOf(other);
                    if (elsewhere.length)
                        failed = format!"targeting: aura %s at the %s, not the %s"(kind, elsewhere, name);
                    else
                    {
                        failed = format!"aura %s: not on the %s"(kind, name);
                        mayRoll = true;
                    }
                }
                else if (flagOf(kind) && !flagSeen[i].get(x, false))
                    failed = format!"aura %s: on the %s, its unit flag not set"(kind, name);
                else if (kind == AuraType.periodicDamage && s.casting.amplitude[i] && s.casting.amplitude[i] <= 5000
                        && leastHealth[i] >= healthOf[i] && !diedSeen.get(x, false) && healthOf[i] > 0)
                    failed = format!"aura %s: on the %s, no damage"(kind, name);
                else if (kind == AuraType.transform && !displayChanged && !intoOwnLook(i, x))
                    failed = format!"aura %s: on the %s, its look unchanged"(kind, name);
                break;
            case persistentAreaAura:
                if (!areaSeen && !(unit && auraSeen[i].get(x, false)))
                    failed = format!"no area, nothing on the %s"(name);
                break;
            case energize:
                if (unit && mostPower[i] <= powerOf[i])
                    failed = format!"no power %s to the %s"(s.miscValue[i], name);
                break;
            case powerDrain:
                if (unit && s.miscValue[i] == 0 && takesMana)
                {
                    const mana = unit.fields.get!UNIT_FIELD_POWER1(0);
                    if (mana >= unit.fields.get!UNIT_FIELD_MAXPOWER1(0))
                        failed = format!"no mana drained from the %s"(name);
                }
                break;
            case summon, summonWild, summonGuardian, summonPet, summonTotem, summonTotemSlot1, summonTotemSlot2,
                    summonTotemSlot3, summonTotemSlot4, summonPossessed, summonCritter, summonPhantasm, summonDemon:
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    failed = format!"no creature %s"(s.miscValue[i]);
                break;
            case summonObjectWild, transDoor, summonObjectSlot1, summonObjectSlot2, summonObjectSlot3,
                    summonObjectSlot4:
                if (s.miscValue[i] > 0 && !summonSeen[i])
                    failed = format!"no object %s"(s.miscValue[i]);
                break;
            case charge:
                const now = caster.position;
                if (now.x == casterBefore.x && now.y == casterBefore.y && now.z == casterBefore.z)
                    failed = "the caster did not move";
                break;
            case leap:
                const at = caster.position;
                const offset = radius(*s, i, context.client);
                if (offset <= 0 || abs(at.x - casterBefore.x - offset * cos(facing)) > 0.01f
                    || abs(at.y - casterBefore.y - offset * sin(facing)) > 0.01f
                    || at.z != casterBefore.z || at.orientation != facing)
                    failed = "the caster did not blink its radius forward on flat ground";
                break;
            case teleportUnits, teleportUnitsFaceCaster:
                if (x != Who.enemy)
                {
                    checked = false;
                    break;
                }
                if (!landed)
                {
                    failed = "the player received no teleport";
                    break;
                }
                const at = me.player.position;
                if (destination !is null)
                {
                    if (me.player.data.map != destination.map || at != destination.at
                        || (destination.map == map.id && me.instanceId != startInstance))
                        failed = "the player missed the database destination or changed dungeon copies";
                    break;
                }
                const shape = s.casting.implicitTargetB[i];
                const back = shape == ImplicitTarget.locationCasterBack;
                const offset = shape == ImplicitTarget.locationCasterFront ? radius(*s, i, context.client)
                    : back ? -radius(*s, i, context.client) : 0;
                if (me.player.data.map != map.id || me.instanceId != startInstance
                    || abs(at.x - casterBefore.x - offset * cos(facing)) > 0.01f
                    || abs(at.y - casterBefore.y - offset * sin(facing)) > 0.01f
                    || abs(at.z - casterBefore.z) > 0.01f || abs(at.orientation - (facing + (back ? 0 : PI))) > 0.01f)
                    failed = "the player landed at the wrong point or faced away from the caster";
                break;
            case pullTowards:
                const dx = casterBefore.x - playerBefore.x, dy = casterBefore.y - playerBefore.y;
                const apart = sqrt(dx * dx + dy * dy);
                const at = me.player.position;
                if (!pullLanded || abs(flight.jumpXySpeed - s.miscValue[i] * 0.1f) > 0.01f
                    || abs(at.x - (casterBefore.x - dx * contact / apart)) > 0.01f
                    || abs(at.y - (casterBefore.y - dy * contact / apart)) > 0.01f || abs(at.z - casterBefore.z) > 0.01f)
                    failed = "the pull did not land the player at contact range";
                break;
            case instantKill:
                if (unit && !diedSeen.get(x, false))
                    failed = format!"the %s lives"(name);
                break;
            case dispel:
                if (unit && dispellableBefore[i] && hasDispellable(unit, s.miscValue[i]))
                    failed = format!"nothing of dispel type %s taken from the %s"(s.miscValue[i], name);
                else if (unit && !dispellableBefore[i])
                    checked = false;
                break;
            case inebriate: // the player more drunk
                if (x == Who.enemy && unit)
                {
                    if (me.player.drunk <= drunkBefore)
                        failed = "the player no more drunk";
                }
                else
                    checked = false;
                break;
            case sendTaxi: // the player on the path
                if (!me.flying)
                    failed = "the player not flying";
                break;
            case resurrect, resurrectNew: // the dead player offered to come back
                if (!resurrectAsked)
                    failed = "no resurrection offered the player";
                break;
            default:
                checked = false;
                break;
            }
            with (SpellEffect)
                checkedAny |= checked && (cast(bool) unit || summonsCreature(effect) || summonsObject(effect)
                    || effect.among(charge, leap, persistentAreaAura, teleportUnits, teleportUnitsFaceCaster) != 0);
            const unsupported = notDoneByCreatures(*s, i);
            if (failed.length || (!checked && unsupported))
            {
                import std.algorithm.searching : startsWith;

                if (unsupported)
                    problems ~= format!"not done: %s (effect %s%s)"(effect, i, failed.length ? ": " ~ failed : "");
                else if (failed.startsWith("aura ") || failed.startsWith("targeting: "))
                    problems ~= format!"%s (effect %s)"(failed, i);
                else
                    problems ~= format!"%s: %s (effect %s)"(effect, failed, i);
            }
        }
        if (verbose)
            imported!"std.stdio".stderr.writefln("%s %s (by %s, %s, flags %#x): %s", sp.id, s.casting.name, entry,
                sp.source, sp.flags, problems.length ? joinProblems(problems) : "ok");
        if (!problems.length)
            return NpcOutcome(true, null, false, !checkedAny);
        return NpcOutcome(false, joinProblems(problems), mayRoll);
    }

    /// A character of `classId` (a human, or a troll for a mage) and `level` at `at`, logged in, its power full.
    private TestClient player(uint guid, ubyte classId, uint level, Position at)
    {
        import dmangos.auth.accounts : AccountLevel;
        import dmangos.world.player : CharacterData, Player;
        import dmangos.world.testclient : loggedIn;

        auto clock = &w.now;
        w.context.clock = () => *clock;
        auto client = loggedIn(w.context, w.db, guid, format!"Npcsweep%s"(guid), at, AccountLevel.player, 1, 0, level,
            (ref CharacterData c) { c.classId = classId; });
        auto me = cast(Player) client.session.character;
        foreach (power; 0 .. 5)
            me.values.set!UNIT_FIELD_POWER1(power, me.values.get!UNIT_FIELD_MAXPOWER1(power));
        // Health enough to live through an elite's blow: a spell's aura after its damage (Mortal Strike's, War
        // Stomp's stun; Frost Burn's slow before its mana burn's damage) is on a living target, not stripped by its
        // death. An aura's, so that a recount of its stats as an aura lands keeps it.
        {
            import dmangos.world.auras : makeAura;

            static SpellInfo hardy;
            hardy.id = uint.max - 1;
            hardy.effect[0] = SpellEffect.applyAura;
            hardy.casting.applyAuraName[0] = AuraType.modIncreaseHealth;
            client.session.inWorld.addAura(makeAura(&hardy, guid, level, -1, true, [500_000, 0, 0]));
        }
        me.values.set!UNIT_FIELD_HEALTH(me.values.get!UNIT_FIELD_MAXHEALTH);
        client.read();
        return client;
    }
}

private enum float PI = 3.14159265f;

/// The unit flag an aura of `kind` sets (0: none the sweep checks).
private uint flagOf(AuraType kind)
{
    import dmangos.world.defines : UnitFlags;

    switch (kind)
    {
    case AuraType.modStun: return UnitFlags.stunned;
    case AuraType.modFear: return UnitFlags.fleeing;
    case AuraType.modConfuse: return UnitFlags.confused;
    case AuraType.modSilence: return UnitFlags.silenced;
    case AuraType.modPacify: return UnitFlags.pacified;
    default: return 0;
    }
}

/// A spell whose aura is of dispel type `type`, harmful or helpful; null if none (the lowest id).
private const(SpellInfo)* dispellable(const WorldData data, int type, bool harmful)
{
    static const(SpellInfo)*[string] cache;
    const key = format!"%s/%s"(type, harmful);
    if (auto found = key in cache)
        return *found;
    const(SpellInfo)* best;
    foreach (id, ref s; data.spells.spells)
    {
        if (s.casting.dispel != type || !s.hasEffect(SpellEffect.applyAura) || harms(s) != harmful
                || s.attributesEx & 0x44 || s.attributes & 0x40)
            continue;
        if (best is null || id < best.id)
            best = &s;
    }
    return cache[key] = best;
}

/// `spell`'s aura put on `unit` (by `caster`), for a minute.
private void putAura(UnitRef unit, const(SpellInfo)* spell, ulong caster)
{
    import dmangos.world.auras : makeAura;
    import dmangos.world.spellcast : effectValue;
    import dmangos.world.unit : UnitKind;

    auto aura = makeAura(spell, caster, 60, 60_000, !harms(*spell),
        [effectValue(*spell, 0, 60, 0), effectValue(*spell, 1, 60, 0), effectValue(*spell, 2, 60, 0)]);
    if (unit.kind == UnitKind.player)
        unit.session.addAura(aura);
    else
    {
        bool isNew;
        unit.creature.auras.apply(aura, unit.creature.values, isNew);
    }
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
        "realnpc-known.txt");
    string[uint] known;
    if (!path.exists)
        return known;
    foreach (line; readText(path).lineSplitter)
    {
        const text = line.strip;
        if (!text.length || text[0] == '#')
            continue;
        const colon = text.indexOf(':');
        assert(colon > 0, "realnpc-known.txt: id: reason, not " ~ text);
        known[text[0 .. colon].strip.to!uint] = text[colon + 1 .. $].strip;
    }
    return known;
}

/// The cause of a failure, for the counts: its first problem, without the effect's index or the numbers.
private string causeOf(string why)
{
    import std.regex : ctRegex, replaceAll;
    import std.string : indexOf;

    auto first = why.indexOf("; ") < 0 ? why : why[0 .. why.indexOf("; ")];
    if (const at = first.indexOf(" (effect ") + 1)
        first = first[0 .. at - 1];
    return first.replaceAll(ctRegex!`\b\d+\b`, "#");
}

/// The sweep.
unittest
{
    import std.algorithm.iteration : map, splitter;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.conv : to;
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.process : environment;
    import std.stdio : File, stderr;

    if (!haveRealData())
        return;
    auto watch = StopWatch(AutoStart.yes);
    auto first = RealWorld.make();
    const data = first.context.data;
    auto spells = npcSpells(data);
    const only = environment.get("DMANGOS_NPC_SWEEP_ONLY");
    if (only !is null)
    {
        const wanted = only.splitter(',').map!(x => x.to!uint).array;
        NpcSpell[] picked;
        foreach (sp; spells)
            if (wanted.canFind(sp.id))
                picked ~= sp;
        spells = picked;
    }
    auto sweeper = new NpcSweeper(first, only !is null);
    string[uint] failed;
    size_t passed, noCaster, unchecked;
    size_t[string] causes;
    uint[][string] examples;
    string[] report;
    foreach (sp; spells)
    {
        NpcOutcome outcome;
        if (!sp.casters.length)
            outcome = NpcOutcome(false, "no caster: no creature casts it in the data");
        else
            outcome = sweeper.sweep(sp);
        if (outcome.ok)
        {
            ++passed;
            unchecked += outcome.unchecked;
        }
        else
        {
            failed[sp.id] = outcome.why;
            const cause = causeOf(outcome.why);
            ++causes[cause];
            if (examples.get(cause, null).length < 4)
                examples[cause] ~= sp.id;
            noCaster += cause.length >= 9 && cause[0 .. 9] == "no caster";
        }
        report ~= format!"%s\t%s\t%s\t%(%s,%)"(sp.id, outcome.ok ? outcome.unchecked ? "ok (unchecked)" : "ok"
            : outcome.why, sp.source, sp.casters);
    }
    if (const path = environment.get("DMANGOS_NPC_SWEEP_REPORT"))
    {
        auto f = File(path, "w");
        foreach (line; report)
            f.writeln(line);
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
    stderr.writefln("realnpcsweep: %s spells creatures cast, %s as their data says (%s of them with no effect the "
        ~ "sweep checks), %s known failures (realnpc-known.txt; %s with no creature to cast them), %s new, in %s s",
        spells.length, passed, unchecked, failed.length - news.length, noCaster, news.length,
        watch.peek.total!"seconds");
    auto byCount = causes.keys;
    byCount.sort!((a, b) => causes[a] > causes[b] || (causes[a] == causes[b] && a < b));
    foreach (cause; byCount)
        stderr.writefln("realnpcsweep:   %5s %s (%(%s, %))", causes[cause], cause, examples[cause]);
    foreach (line; fixed)
        stderr.writeln("realnpcsweep: passes now, take it off realnpc-known.txt: ", line);
    foreach (line; news)
        stderr.writeln("realnpcsweep: FAILS: ", line);
    assert(!news.length, "a creature's spell on the real data does not do what its data says (see above)");
}
