/**
 * Session tests of the quest rules CMaNGOS keeps and `dmangos.world.questhandlers` follows: "each of all"
 * exclusive groups, spell-cast and quest-complete-effect credit, the source item taken back, quests failed on
 * release, raid groups, and what the client is told of quest items it receives.
 */
module dmangos.world.questruletests;

version (unittest):

import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.creature : Creature;
import dmangos.world.movement : Position;
import dmangos.world.objects : HighGuid, makeGuid;
import dmangos.world.opcodes;
import dmangos.world.player : Player;
import dmangos.world.quests;
import dmangos.world.spellcast : SpellTargets, TargetFlags;
import dmangos.world.spellhandlers : testSpell;
import dmangos.world.spellids : DamageClass, ImplicitTarget;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.updatefields;

/// A quest anyone of level 1 may take.
private Quest plainQuest(uint id)
{
    Quest q;
    q.id = id;
    q.method = 2;
    q.minLevel = 1;
    q.maxLevel = 255;
    q.questLevel = 1;
    q.title = "A quest";
    return q;
}

/**
 * A negative `ExclusiveGroup` ("each of all"): the quest they lead to is given only once every quest of the
 * group is done; a positive one ("one of all") lets the next in once one is done and keeps the others out.
 */
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto a = plainQuest(6001), b = plainQuest(6002), next = plainQuest(6003);
    a.exclusiveGroup = b.exclusiveGroup = -6001;
    a.nextQuestId = b.nextQuestId = 6003;
    context.data.quests.quests[a.id] = a;
    context.data.quests.quests[b.id] = b;
    context.data.quests.quests[next.id] = next;
    auto one = plainQuest(6011), other = plainQuest(6012), after = plainQuest(6013);
    one.exclusiveGroup = other.exclusiveGroup = 6011;
    one.nextQuestId = other.nextQuestId = 6013;
    context.data.quests.quests[one.id] = one;
    context.data.quests.quests[other.id] = other;
    context.data.quests.quests[after.id] = after;
    context.data.quests.link();

    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto session = client.session.inWorld;
    auto me = cast(Player) client.session.character;
    void done(uint id)
    {
        QuestStatus s;
        s.quest = id;
        s.status = QuestState.complete;
        s.rewarded = true;
        me.questStatus[id] = s;
    }
    const quests = context.data.quests;

    done(a.id);
    assert(!session.canTakeQuest(*quests.quest(next.id)), "one of the two done: not yet");
    done(b.id);
    assert(session.canTakeQuest(*quests.quest(next.id)), "both done");

    assert(session.canTakeQuest(*quests.quest(other.id)));
    done(one.id);
    assert(session.canTakeQuest(*quests.quest(after.id)), "one of all: one done is enough");
    assert(!session.canTakeQuest(*quests.quest(other.id)), "and the other is shut");
}

/**
 * A spell cast at a quest's creature counts for an objective that names the spell (`ReqSpellCast`); a quest
 * completed by a spell effect (`SPELL_EFFECT_QUEST_COMPLETE`); the quest's source item is taken back when it
 * is abandoned; quest reward items are received, not made, and shown by the reward window, not in chat.
 */
unittest
{
    import dmangos.world.packets : ServerItemPushResult;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint sprinkle = 97801, finish = 97802;
    context.data.spells.spells[sprinkle] = testSpell(sprinkle, 3, ImplicitTarget.enemy, 0); // a dummy at the target
    context.data.spells.spells.edit(sprinkle).casting.dmgClass = DamageClass.none;
    context.data.spells.spells[finish] = testSpell(finish, 16, ImplicitTarget.caster, 0); // SPELL_EFFECT_QUEST_COMPLETE
    context.data.spells.spells.edit(finish).miscValue[0] = 6102;
    context.data.spells.spells.edit(finish).casting.dmgClass = DamageClass.none;
    auto cast_ = plainQuest(6101);
    cast_.reqCreatureOrGoId[0] = creatureInnkeeper;
    cast_.reqCreatureOrGoCount[0] = 1;
    cast_.reqSpellCast[0] = sprinkle;
    cast_.srcItemId = itemJerky; // given with the quest
    cast_.srcItemCount = 2;
    cast_.rewItemId[0] = itemShirt;
    cast_.rewItemCount[0] = 1;
    auto event = plainQuest(6102);
    event.specialFlags = specialExplorationOrEvent;
    context.data.quests.quests[cast_.id] = cast_;
    context.data.quests.quests[event.id] = event;
    context.data.quests.link();

    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto session = client.session.inWorld;
    auto me = cast(Player) client.session.character;
    me.spells ~= [sprinkle, finish];
    session.addQuest(*context.data.quests.quest(cast_.id));
    session.addQuest(*context.data.quests.quest(event.id));
    session.flushInventory(true);
    const given = client.read();
    assert(me.inventory.count(itemJerky) == 2);
    const push = bodyOf(given, Opcode.SMSG_ITEM_PUSH_RESULT);
    assert(push !is null);
    auto r = ByteReader(push);
    r.read!ulong;
    assert(r.read!uint == 1 && r.read!uint == 0, "the source item: received, not created");

    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.movement.position = Position(-8947.95f, -132.49f, 83.53f, 0);
    session.castSpell(sprinkle in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_QUESTUPDATE_ADD_KILL) && me.questStatus[cast_.id].mobCount[0] == 1,
        "the cast counted");
    assert(me.questStatus[cast_.id].status == QuestState.complete);

    now += 2.seconds;
    session.castSpell(finish in context.data.spells.spells, SpellTargets(TargetFlags.self, me.guid), false, 0);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_QUESTUPDATE_COMPLETE) && me.questStatus[event.id].explored,
        "the effect completes it");

    // Rewarded: the shirt is received, not created, with no chat line of its own.
    session.rewardQuest(*context.data.quests.quest(cast_.id), 0);
    foreach (p; client.read())
        if (p.opcode == Opcode.SMSG_ITEM_PUSH_RESULT)
        {
            auto pr = ByteReader(p.body_);
            pr.read!ulong;
            assert(pr.read!uint == 1 && pr.read!uint == 0 && pr.read!uint == 0, "received, not created, not in chat");
        }

    // Abandoned: the source item goes back.
    session.addQuest(*context.data.quests.quest(cast_.id)); // (rewarded, but taken again for the test)
    session.flushInventory(true);
    client.read();
    const jerky = me.inventory.count(itemJerky);
    assert(jerky >= 2);
    ByteWriter w;
    w.put(cast(ubyte) session.questSlot(cast_.id));
    client.write(Opcode.CMSG_QUESTLOG_REMOVE_QUEST, w.data);
    assert(me.inventory.count(itemJerky) == jerky - 2, "taken back");
}

/// A quest to be done alive (`QUEST_FLAGS_STAY_ALIVE`) fails when the player releases its spirit.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : worldSafeLocsFormat;
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.worlddata : GraveyardLink, graveyardLinkKey;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    uint bits(float f) { return *cast(uint*) &f; }
    context.client.worldSafeLocs = typeof(context.client.worldSafeLocs).parse(buildDbc(worldSafeLocsFormat,
        [[7u, 0, bits(-9010), bits(-132), bits(83.5f), 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "WorldSafeLocs.dbc");
    context.data.graveyards[graveyardLinkKey(0, 1)] = [GraveyardLink(7, 0)];
    auto alive = plainQuest(6201), any = plainQuest(6202);
    alive.questFlags = questFlagStayAlive;
    alive.reqCreatureOrGoId[0] = creatureInnkeeper;
    alive.reqCreatureOrGoCount[0] = 1;
    any.reqCreatureOrGoId[0] = creatureInnkeeper;
    any.reqCreatureOrGoCount[0] = 1;
    context.data.quests.quests[alive.id] = alive;
    context.data.quests.quests[any.id] = any;
    context.data.quests.link();
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto session = client.session.inWorld;
    auto me = cast(Player) client.session.character;
    session.addQuest(*context.data.quests.quest(alive.id));
    session.addQuest(*context.data.quests.quest(any.id));
    client.read();

    MeleeDamage blow;
    blow.damage = 10_000;
    blow.outcome = MeleeHitOutcome.normal;
    session.unit.meleeHitBy(0xF130_0000_0000_0001, blow);
    client.read();
    assert(me.questStatus[alive.id].status == QuestState.incomplete, "dead, not yet released");
    client.write(Opcode.CMSG_REPOP_REQUEST, null);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_QUESTUPDATE_FAILED));
    assert(me.questStatus[alive.id].status == QuestState.failed && me.questStatus[any.id].status == QuestState.incomplete);
}

/// In a raid group, kills count only for raid quests (`QUEST_TYPE_RAID`); out of it, for all.
unittest
{
    import dmangos.world.loothandlers : killIt, lootableInnkeeper;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto party = plainQuest(6301), raid = plainQuest(6302);
    raid.type = 62;
    foreach (q; [&party, &raid])
    {
        q.reqCreatureOrGoId[0] = creatureInnkeeper;
        q.reqCreatureOrGoCount[0] = 2;
        context.data.quests.quests[q.id] = *q;
    }
    context.data.quests.link();
    auto client = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto session = client.session.inWorld;
    auto me = cast(Player) client.session.character;
    session.addQuest(*context.data.quests.quest(party.id));
    session.addQuest(*context.data.quests.quest(raid.id));
    client.read();

    session.killedMonster(creatureInnkeeper, 1);
    assert(me.questStatus[party.id].mobCount[0] == 1 && me.questStatus[raid.id].mobCount[0] == 1, "no group: both");
    auto group = context.groups.newGroup();
    group.addLeaderInvite(me.guid, me.data.name);
    group.create();
    group.convertToRaid();
    assert(context.groups.of(me.guid) is group && group.isRaid);
    session.killedMonster(creatureInnkeeper, 1);
    assert(me.questStatus[party.id].mobCount[0] == 1 && me.questStatus[raid.id].mobCount[0] == 2, "a raid: the raid quest only");
}
