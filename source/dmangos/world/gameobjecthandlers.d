/**
 * Using game objects (CMaNGOS `GameObject::Use`, `HandleGameObjectUseOpcode`, `Spell::EffectOpenLock`,
 * `CanOpenLock`, `Spell::SendLoot` and `Player::UpdateGatherSkill`), mixed into
 * `dmangos.world.session.WorldSession`.
 *
 * A door or button opens (or closes) for its time; a chair seats the player in its nearest slot; a
 * goober is in use for its time, shows its page, counts for the quest that needs it (for the
 * player and its group near it) and casts its spell on the player; a camera plays its cinematic.
 * A lock (`Lock.dbc`) is opened by a spell: with its key item, or the lock type the spell opens
 * and the skill it needs (lockpicking, herbalism, mining). Opening a chest (herbs and veins
 * included) shows its loot (`gameobject_loot_template`), with the loot rights of a group as a
 * corpse has them and its quest items for those whose quests need them; the first opening until
 * it respawns may raise the gathering skill. A chest is gone once emptied (or 5 minutes after it
 * was opened) if consumable. Quest givers among game objects, traps and fishing come later.
 */
module dmangos.world.gameobjecthandlers;

/// See the module documentation.
mixin template GameObjectHandlers()
{
    import std.random : uniform;
    import dmangos.log : info;
    import dmangos.world.clientdata : LockEntry;
    import dmangos.world.gameobject : GameObject, GameObjectType, goStateReady, GoLootState;
    import dmangos.world.loot : Loot, LootItem, Looter, questItems;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState;
    import dmangos.world.quests : QuestState;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    /// `INTERACTION_DISTANCE`
    enum float interactionDistance = 5;

    /// `LockKeyType`, `LockType`, and the skills of the lock types.
    enum uint lockKeyItem = 1, lockKeySkill = 2;
    enum uint lockPicklock = 1, lockHerbalism = 2, lockMining = 3, lockFishing = 19;
    enum uint skillLockpicking = 633, skillHerbalism = 182, skillMining = 186, skillFishing = 356;

    /// `SkillByLockType`
    static uint skillByLockType(uint lockType) pure nothrow @nogc @safe
    {
        switch (lockType)
        {
        case lockPicklock: return skillLockpicking;
        case lockHerbalism: return skillHerbalism;
        case lockMining: return skillMining;
        case lockFishing: return skillFishing;
        default: return 0;
        }
    }

    /// Within `IsWithinDistInMap(player, INTERACTION_DISTANCE)` of the object (a little more for its size).
    bool withinInteraction(const GameObject go, float more = 0)
    {
        const a = player.position, b = go.position;
        const reach = interactionDistance + more + go.template_.size;
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= reach * reach;
    }

    /// `HandleGameObjectUseOpcode`
    @Handles(Opcode.CMSG_GAMEOBJ_USE, WorldState.inWorld)
    void handleGameObjectUse(const ClientGuid request)
    {
        enum uint goFlagNoInteract = 0x10;
        if (player.deathState != DeathState.alive || transferring)
            return;
        auto go = cast(GameObject) map.findObject(request.guid);
        if (go is null || !withinInteraction(go, 2))
            return; // another node's object: not yet
        // Never for these: generic objects are used by spells, and some may not be touched.
        if (go.type == GameObjectType.generic || (go.values.get!GAMEOBJECT_FLAGS & goFlagNoInteract))
            return;
        useGameObject(go);
    }

    /// `GameObject::Use` by this player.
    package void useGameObject(GameObject go)
    {
        uint spellId;
        switch (go.type)
        {
        case GameObjectType.door, GameObjectType.button:
            go.useDoorOrButton(map);
            map.wake(go.guid);
            return;
        case GameObjectType.chest:
            // Its loot comes with the spell that opens it (`SendLoot`); one without a lock is just done.
            if (!go.lockId && go.lootState == GoLootState.ready)
            {
                go.lootState = GoLootState.justDeactivated;
                map.wake(go.guid);
            }
            return;
        case GameObjectType.generic:
            go.lootState = GoLootState.justDeactivated;
            map.wake(go.guid);
            return;
        case GameObjectType.chair:
            return sitOnChair(go);
        case GameObjectType.goober:
        {
            const t = go.template_;
            go.activateGoober(map);
            map.wake(go.guid);
            if (const page = t.data[7]) // show the page
            {
                ByteWriter w;
                w.put(go.guid);
                deliver(Opcode.SMSG_GAMEOBJECT_PAGETEXT, w.data);
            }
            // A quest objective: only while the quest it is for is under way.
            const questId = t.data[1];
            if (questId > 0 && context.data.quests.quest(questId) !is null
                && questState(questId) != QuestState.incomplete)
                return;
            rewardAtCast(go);
            spellId = t.data[10];
            break;
        }
        case GameObjectType.camera:
            if (const cinematic = go.template_.data[1])
            {
                ByteWriter w;
                w.put(cinematic);
                deliver(Opcode.SMSG_TRIGGER_CINEMATIC, w.data);
            }
            return;
        default:
            return;
        }
        // The spell it casts on its user.
        if (spellId)
            if (const spell = context.data.spells.spell(spellId))
                castSpell(spell, SpellTargets(TargetFlags.unit, player.guid), true, 0);
    }

    /// `RewardPlayerAndGroupAtCast` for a game object: its quest objective, for the group near it too.
    void rewardAtCast(GameObject go)
    {
        import dmangos.world.session : WorldSession;

        const target = -cast(int) go.template_.entry;
        auto group = context.groups.of(player.guid);
        if (group is null)
            return creditCreatureOrGo(target, 0, go.guid);
        foreach (ref slot; group.members)
            if (auto member = cast(WorldSession) context.onlinePlayer(slot.guid))
                if (member is this || (member.map is map && member.withinInteraction(go, 74)))
                    member.creditCreatureOrGo(target, 0, go.guid);
    }

    /// `GAMEOBJECT_TYPE_CHAIR`: to the nearest of its slots, sitting at its height.
    void sitOnChair(GameObject go)
    {
        import std.math : cos, sin, PI;

        enum ubyte standStateSitLowChair = 4;
        const t = go.template_;
        const slots = t.data[0] > 0 ? t.data[0] : 1;
        // `GetClosestChairSlotPosition`: the slots side by side across its width (its size).
        const at = go.position;
        const width = t.size;
        float bestX = at.x, bestY = at.y, best = float.max;
        foreach (i; 0 .. slots)
        {
            const offset = slots == 1 ? 0 : (i - (slots - 1) / 2.0f) * width / slots;
            const x = at.x + offset * cos(at.orientation + PI / 2), y = at.y + offset * sin(at.orientation + PI / 2);
            const d = (player.position.x - x) ^^ 2 + (player.position.y - y) ^^ 2;
            if (d < best)
            {
                best = d;
                bestX = x;
                bestY = y;
            }
        }
        import dmangos.world.movement : Position;

        teleportTo(player.data.map, Position(bestX, bestY, at.z, at.orientation)); // `NearTeleportTo`
        const state = cast(ubyte)(standStateSitLowChair + t.data[1]);
        player.values.setByte!UNIT_FIELD_BYTES_1(0, state);
        deliver(Opcode.SMSG_STANDSTATE_UPDATE, [state]);
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Locks (`CanOpenLock`, `EffectOpenLock`)
    // -----------------------------------------------------------------------

    /**
     * `Spell::CanOpenLock` for effect `i` of `spell` on lock `lockId`: the key item it was cast with,
     * or the lock type the effect opens and enough of its skill (the effect's points added). Gives the
     * skill and the values the skill-up needs.
     */
    SpellCastResult canOpenLock(const(SpellInfo)* spell, size_t i, uint lockId, uint castItem, out uint skillId,
        out int required, out int skillValue)
    {
        import dmangos.world.spellcast : effectValue;

        if (!lockId)
            return SpellCastResult.ok;
        const lock = context.client.locks.lookup(lockId);
        if (lock is null)
            return SpellCastResult.badTargets;
        bool needsKey;
        foreach (j; 0 .. 8)
            switch (lock.type[j])
            {
            case lockKeyItem:
                if (lock.index[j] && castItem == lock.index[j])
                    return SpellCastResult.ok;
                needsKey = true;
                break;
            case lockKeySkill:
                needsKey = true;
                if (cast(uint) spell.miscValue[i] != lock.index[j])
                    continue;
                skillId = skillByLockType(lock.index[j]);
                if (skillId)
                {
                    required = lock.skill[j];
                    skillValue = castItem ? 0 : player.skillValue(skillId)[0];
                    skillValue += effectValue(*spell, i, player.data.level, 0);
                    if (skillValue < required)
                        return SpellCastResult.lowCastLevel;
                }
                return SpellCastResult.ok;
            default:
                break;
            }
        return needsKey ? SpellCastResult.badTargets : SpellCastResult.ok;
    }

    /// `CheckCast` for a spell at a game object: there, near, not in use, and its lock opened.
    package SpellCastResult checkGameObjectTarget(const(SpellInfo)* spell, const ref SpellTargets targets,
        uint castItem)
    {
        enum uint openLock = 33;
        if (!targets.gameObject)
            return SpellCastResult.ok;
        auto go = cast(GameObject) map.findObject(targets.gameObject);
        if (go is null)
            return SpellCastResult.badTargets;
        if (!withinInteraction(go, 5))
            return SpellCastResult.outOfRange;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == openLock)
            {
                if (go.type == GameObjectType.chest && go.lootState != GoLootState.ready && go.loot is null)
                    return SpellCastResult.chestInUse;
                uint skill;
                int required, value;
                const result = canOpenLock(spell, i, go.lockId, castItem, skill, required, value);
                if (result != SpellCastResult.ok)
                    return result;
            }
        return SpellCastResult.ok;
    }

    /// `Spell::EffectOpenLock` on a game object: a skill-up the first time, then `SendLoot`.
    package void openLock(const(SpellInfo)* spell, size_t i, ulong target, uint castItem)
    {
        auto go = cast(GameObject) map.findObject(target);
        if (go is null)
            return;
        uint skillId;
        int required, value;
        if (canOpenLock(spell, i, go.lockId, castItem, skillId, required, value) != SpellCastResult.ok)
            return;
        if (skillId && go.loot is null && player.guid !in go.skilledUp)
            if (const pure_ = player.skillValue(skillId)[0])
            {
                updateGatherSkill(skillId, pure_, required);
                go.skilledUp[player.guid] = true;
            }
        sendGameObjectLoot(go);
    }

    /// `Spell::SendLoot` for a game object: doors, buttons and goobers are used; a chest's loot opens.
    void sendGameObjectLoot(GameObject go)
    {
        switch (go.type)
        {
        case GameObjectType.door, GameObjectType.button, GameObjectType.questGiver, GameObjectType.spellFocus,
                GameObjectType.goober:
            return useGameObject(go);
        case GameObjectType.chest:
            useGameObject(go);
            break;
        default:
            return;
        }
        if (go.loot is null)
        {
            if (go.lootState != GoLootState.ready)
                return;
            go.loot = makeGameObjectLoot(go);
            go.lootState = GoLootState.activated;
            map.wake(go.guid);
        }
        if (lootTarget && lootTarget != go.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        go.loot.showContentTo(this);
    }

    /// `Loot::Loot(Player*, GameObject*, LOOT_CORPSE)`: its template's items for a group's rights.
    Loot makeGameObjectLoot(GameObject go)
    {
        import dmangos.world.session : WorldSession;

        auto theMap = map;
        auto loot = new Loot(go.guid, (ulong guid) {
            auto session = cast(WorldSession) context.onlinePlayer(guid);
            return session is null || session.map !is theMap ? null : cast(Looter) session;
        });
        loot.clock = () => context.unixTime;
        setLootRights(loot, go.position, (ulong) => false);
        if (const id = go.lootId)
            if (const template_ = context.data.loot.gameObject[id])
            {
                bool meets(uint condition)
                {
                    return conditionMet(condition);
                }

                bool allowed(ulong guid, const LootItem item)
                {
                    auto owner = cast(WorldSession) context.onlinePlayer(guid);
                    if (item.quest)
                        return owner !is null && owner.hasQuestForItem(item.itemId);
                    return item.condition == 0 || (owner !is null && owner.conditionMet(item.condition));
                }

                loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowed);
            }
        loot.changed = () => map.flushGameObject(go);
        loot.lootedForAll = () {
            // `Loot::Release` of a chest: done (and gone, if consumable).
            go.lootState = GoLootState.justDeactivated;
            map.wake(go.guid);
        };
        go.despawnTimer = 5 * 60 * 1000; // `SetChestDespawn`: gone 5 minutes after opening even if not emptied
        return loot;
    }

    /**
     * `Player::UpdateGatherSkill`: herbalism, lockpicking and mining may rise by one, likelier the
     * nearer the skill is to the lock's (`SkillGainChance` with the grey, green and yellow levels
     * 100, 50 and 25 above it).
     */
    void updateGatherSkill(uint skill, uint value, int redLevel)
    {
        if (skill != skillHerbalism && skill != skillLockpicking && skill != skillMining)
            return;
        if (redLevel == 1)
            redLevel = 5; // what starts at 1 stops at 105, not 101
        // `SkillGainChance` with `SkillChance.Grey/Green/Yellow/Orange` 0, 25, 75, 100.
        int chance;
        if (value >= redLevel + 100)
            chance = 0;
        else if (value >= redLevel + 50)
            chance = 250;
        else if (value >= redLevel + 25)
            chance = 750;
        else
            chance = 1000;
        updateSkillPro(skill, chance, 1);
    }

    /// `Player::UpdateSkillPro`: by `chance` in a thousand, `step` more up to its maximum (and saved).
    package bool updateSkillPro(uint skill, int chance, uint step)
    {
        if (chance <= 0)
            return false;
        const current = player.skillValue(skill);
        if (!current[1] || !current[0] || current[0] >= current[1])
            return false;
        if (uniform!"[]"(1, 1000, map.random) > chance)
            return false;
        const value = cast(ushort)(current[0] + step > current[1] ? current[1] : current[0] + step);
        applySkill(skill, value, current[1]);
        return true;
    }

    // -----------------------------------------------------------------------
    // Quests
    // -----------------------------------------------------------------------

    /**
     * `GameObject::ActivateToQuest`: a chest with loot one of this player's quests asks for, or a
     * goober whose quest is under way (or one that counts for a quest's objective).
     */
    package bool gameObjectActivatesForQuest(const GameObject go)
    {
        if (player is null)
            return false;
        const t = go.template_;
        switch (go.type)
        {
        case GameObjectType.chest:
            if (const id = go.lootId)
                if (const template_ = context.data.loot.gameObject[id])
                    foreach (item; questItems(template_))
                        if (hasQuestForItem(item))
                            return true;
            return false;
        case GameObjectType.goober:
            if (t.data[1] > 0 && questState(t.data[1]) == QuestState.incomplete)
                return true;
            return needsCreatureOrGo(-cast(int) t.entry);
        default:
            return false;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A door used opens and closes again after its time. An herb (a consumable chest locked for
 * herbalism) opened by the herb gathering spell: the skill checked, raised the first time, the
 * loot shown and taken; emptied, it is gone, and comes back after its respawn time. A goober
 * counts for the quest that needs it.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : lockFormat;
    import dmangos.world.gameobject;
    import dmangos.world.loot : lootRow;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, specialKillOrCast;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint herbLock = 99, herbLoot = 500, gather = 2366, herbalism = 182;
    // Lock: id, 8 types, 8 indexes, 8 skills, 8 skipped. Herbalism (type 2) at 1.
    auto lockRow = new uint[lockFormat.length];
    lockRow[0] = herbLock;
    lockRow[1] = 2;
    lockRow[9] = 2;
    lockRow[17] = 1;
    context.client.locks = typeof(context.client.locks).parse(buildDbc(lockFormat, [lockRow]), "Lock.dbc");
    context.data.spells.spells[gather] = testSpell(gather, 33, 26, 0);
    context.data.spells.spells[gather].miscValue[0] = 2; // opens herbalism locks
    context.data.spells.spells[gather].casting.dmgClass = 0;
    context.data.loot.gameObject.add(herbLoot, lootRow(itemJerky, 100, 0, 1, 1, 0));

    GameObjectTemplate door = {entry: 9001, type: GameObjectType.door, displayId: 1, name: "Door"};
    door.data[2] = 2 * 0x10000; // closes after 2 s
    GameObjectTemplate herb = {entry: 9002, type: GameObjectType.chest, displayId: 2, name: "Peacebloom"};
    herb.data[0] = herbLock;
    herb.data[1] = herbLoot;
    herb.data[3] = 1; // consumable
    GameObjectTemplate idol = {entry: 9003, type: GameObjectType.goober, displayId: 3, name: "Idol"};
    idol.data[3] = 1 * 0x10000;
    context.data.gameObjectTemplates[9001] = door;
    context.data.gameObjectTemplates[9002] = herb;
    context.data.gameObjectTemplates[9003] = idol;
    context.data.gameObjectSpawns ~= [GameObjectSpawn(90001, 9001, 0, -8949, -131, 83.53f),
        GameObjectSpawn(90002, 9002, 0, -8950, -133, 83.53f, 0, [0, 0, 0, 0], 60),
        GameObjectSpawn(90003, 9003, 0, -8951, -131, 83.53f)];

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= gather;
    auto map = context.map(0);
    GameObject[3] gos;
    foreach (i; 0 .. 3)
    {
        gos[i] = context.makeGameObject(&context.data.gameObjectSpawns[$ - 3 + i]);
        map.addObject(gos[i]);
    }
    anduin.read();
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
        context.update(now);
    }

    // The door: open, then closed after its 2 seconds.
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(gos[0].guid));
    assert(gos[0].goState == goStateActive && gos[0].lootState == GoLootState.activated);
    tick(1000);
    assert(gos[0].goState == goStateActive);
    tick(1500);
    assert(gos[0].goState == goStateReady && gos[0].lootState == GoLootState.ready, "closed again");

    // The herb: no herbalism, no picking.
    ubyte[] gatherAt(ulong go)
    {
        ByteWriter w;
        w.put(gather);
        SpellTargets t;
        t.mask = TargetFlags.gameObject;
        t.gameObject = go;
        t.write(w);
        return w.data.dup;
    }
    anduin.read();
    anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(gos[1].guid));
    const refused = anduin.read();
    assert(!opcodesOf(refused).canFind(Opcode.SMSG_LOOT_RESPONSE) && opcodesOf(refused).canFind(Opcode.SMSG_CAST_RESULT),
        "no skill");
    // With herbalism 1: the loot, and a skill-up (sure at that level).
    me.setSkill(herbalism, 1, 75);
    anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(gos[1].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
    assert(me.skillValue(herbalism) == [2, 75], "a skill-up");
    ByteWriter slot;
    slot.put(ubyte(0));
    anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, slot.data);
    anduin.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(gos[1].guid));
    assert(me.inventory.count(itemJerky) >= 1);
    tick(100);
    assert(map.findObject(gos[1].guid) is null && context.gameObjectAwaitingRespawn(90002), "picked: gone");
    now += 61.seconds;
    tick(1000);
    assert(map.findObject(gos[1].guid) !is null, "back after its minute");

    // The idol: a quest asks for it to be used; its use counts, and it sparkles while it does.
    Quest q = {id: 9100, method: 2, specialFlags: specialKillOrCast};
    q.reqCreatureOrGoId[0] = -9003;
    q.reqCreatureOrGoCount[0] = 1;
    context.data.quests.quests[9100] = q;
    me.questStatus[9100] = QuestStatus(9100, QuestState.incomplete);
    me.values.set!PLAYER_QUEST_LOG_1_1(9100u);
    assert(anduin.session.gameObjectActivatesForQuest(gos[2]));
    anduin.read();
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(gos[2].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTUPDATE_ADD_KILL));
    assert(me.questStatus[9100].mobCount[0] == 1 && !anduin.session.gameObjectActivatesForQuest(gos[2]));
}
