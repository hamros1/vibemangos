/**
 * A player's reputations in the world: loading and saving them, their packets, the reputation
 * kills and quests give, and the client's faction opcodes, mixed into
 * `dmangos.world.session.Character`.
 *
 * Kills give the reputations of `creature_onkill_reputation` (shared in a group like experience,
 * half to the team faction where it says so, up to its rank cap); quests their `RewRepFaction`
 * ones. Less for kills grey to the player and gains from quests at least 6 levels below it, down to
 * `rate_reputation_lowlevel_kill` and `_quest`; `reputation_reward_rate` scales each faction's.
 * The client sets war, the inactive list and the watched faction itself.
 */
module dmangos.world.reputationhandlers;

/// See the module documentation.
final class Reputations
{
    import dmangos.world.character : Character, Handles;
    import dmangos.world.session : WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.creature : Creature;
    import dmangos.world.experience : isGray;
    import dmangos.world.opcodes;
    import dmangos.world.quests : Quest, questReputations, QuestState;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.reputation;
    import dmangos.world.updatefields;

    /// `ReputationSource`
    enum ReputationSource { kill, quest, spell }

    /// The reputations loaded from the database, for a player made from its saved character.
    package Reputation loadedReputation(uint guid, ubyte race, ubyte classId)
    {
        auto reputation = new Reputation(me.context.client, 1u << (race - 1), 1u << (classId - 1));
        reputation.load(me.context.database.loadReputation(guid));
        return reputation;
    }

    /// Saves the factions that changed.
    package void saveReputation()
    {
        if (me.player is null || me.player.reputation is null)
            return;
        const rows = me.player.reputation.takeChanged();
        if (rows.length)
            me.context.database.saveReputation(me.player.data.guid, rows);
    }

    /// The whole list, as `SMSG_INITIALIZE_FACTIONS`.
    package ubyte[] initialReputations()
    {
        ByteWriter w;
        w.put(uint(reputationListSize));
        foreach (ref s; me.player.reputation.states)
        {
            w.put(cast(ubyte)(s.exists ? s.flags : 0));
            w.put(s.exists ? s.standing : 0);
            s.needSend = false;
        }
        me.player.reputation.made = null;
        return w.data.dup;
    }

    /**
     * The factions newly in the list, then the standings changed,
     * `first` (the one changed on purpose) leading.
     */
    void sendReputationChanges(int first)
    {
        auto rep = me.player.reputation;
        foreach (id; rep.made)
        {
            ByteWriter v;
            v.put(id);
            me.deliver(Opcode.SMSG_SET_FACTION_VISIBLE, v.data);
        }
        rep.made = null;
        ByteWriter w;
        uint count;
        void add(size_t id)
        {
            w.put(cast(uint) id);
            w.put(rep.states[id].standing);
            rep.states[id].needSend = false;
            ++count;
        }
        if (first >= 0 && first < reputationListSize && rep.states[first].exists)
            add(first);
        foreach (id, ref s; rep.states)
            if (s.exists && s.needSend)
                add(id);
        if (count == 0)
            return;
        ByteWriter packet;
        packet.put(count);
        packet.putBytes(w.data);
        me.deliver(Opcode.SMSG_SET_FACTION_STANDING, packet.data);
    }

    /**
     * `amount` more with `faction` (its related factions sharing unless `noSpillover`); the client told; quests waiting on the standing looked at.
     */
    package void modifyReputation(uint faction, int amount, bool noSpillover = false)
    {
        const entry = me.context.client.factions.lookup(faction);
        if (entry is null || me.player.reputation is null)
            return;
        me.player.reputation.change(entry, amount, true, me.context.data.spillovers, noSpillover);
        sendReputationChanges(entry.reputationListId);
        reputationChanged(faction);
    }

    /// A standing changed: a quest whose objective is this standing completes when it is reached.
    void reputationChanged(uint faction)
    {
        foreach (id, ref q; me.player.questStatus)
            if (q.status == QuestState.incomplete)
                if (const quest = me.context.data.quests.quest(id))
                    if (quest.repObjectiveFaction == faction && me.canCompleteQuest(id))
                        me.completeQuest(id);
    }

    /// The reputation `rep` from `source` is worth to this player: less for low levels, scaled by the rates.
    int reputationGain(ReputationSource source, int rep, uint faction, uint level)
    {
        import std.algorithm.comparison : max;

        // The auras' share (`MOD_REPUTATION_GAIN`: Diplomacy; for kills `MOD_FACTION_REPUTATION_GAIN` by faction), up for
        // a gain and down for a loss (CMaNGOS's `Player::CalculateReputationGain`).
        import dmangos.world.spellids : AuraType;

        float bonus = me.player.auras.total(AuraType.modReputationGain);
        if (source == ReputationSource.kill)
            bonus += me.player.auras.totalByMisc(AuraType.modFactionReputationGain, cast(int) faction);
        float percent = 100 + (rep > 0 ? bonus : -bonus);
        const current = me.player.data.level;
        if (level > 0)
        {
            // A grey kill: a fifth (Wowpedia "Reputation": "Grey mobs used to give 20% of the normal reputation
            // until the release of Patch 3.0.8").
            if (source == ReputationSource.kill && isGray(current, level))
                percent *= me.context.config.rateReputationLowLevelKill;
            else if (source == ReputationSource.quest && rep > 0 && current > level + 5)
                percent *= max(me.context.config.rateReputationLowLevelQuest, 1.0f - 0.2f * (current - (level + 5)));
        }
        if (percent <= 0)
            return 0;
        if (const rates = faction in me.context.data.reputationRates)
        {
            const rate = (*rates)[source == ReputationSource.quest ? 0 : source == ReputationSource.kill ? 1 : 2];
            if (rate <= 0)
                return 0;
            percent *= rate;
        }
        return cast(int)(me.context.config.rateReputationGain * rep * percent / 100.0f);
    }

    /// What a kill does to the factions it concerns.
    package void rewardKillReputation(Creature victim, float rate)
    {
        rewardKillReputation(victim.template_.entry, victim.values.get!UNIT_FIELD_LEVEL, rate);
    }

    /// ditto, by the creature's entry and level (a kill on another node)
    package void rewardKillReputation(uint creatureEntry, uint level, float rate)
    {
        import dmangos.world.clientdata : Team;

        const onKill = creatureEntry in me.context.data.onKillReputation;
        if (onKill is null || me.player.reputation is null)
            return;
        const team = me.context.client.teamForRace(me.player.data.race);
        foreach (i; 0 .. 2)
        {
            if (!onKill.faction[i] || (onKill.teamDependent && team != (i == 0 ? Team.alliance : Team.horde)))
                continue;
            const amount = cast(int)(reputationGain(ReputationSource.kill, onKill.value[i], onKill.faction[i], level)
                * rate);
            const entry = me.context.client.factions.lookup(onKill.faction[i]);
            if (entry is null || me.player.reputation.rankWith(entry) > onKill.maxStanding[i])
                continue;
            modifyReputation(onKill.faction[i], amount);
            // Team factions get half (Wiki).
            if (onKill.teamAward[i] && entry.team)
                modifyReputation(entry.team, amount / 2);
        }
    }

    /// The reputation a quest turned in gives.
    package void rewardQuestReputation(const ref Quest quest)
    {
        const level = quest.questLevel > 0 ? cast(uint) quest.questLevel : me.player.data.level;
        foreach (i; 0 .. questReputations)
            if (quest.rewRepFaction[i] && quest.rewRepValue[i])
                modifyReputation(quest.rewRepFaction[i],
                    reputationGain(ReputationSource.quest, quest.rewRepValue[i], quest.rewRepFaction[i], level));
    }

    /**
     * The price discount: 10% off at honored and above with the faction of the
     * NPC's template (`faction`); the PvP rank's 10% needs ranks, which do not exist yet.
     */
    package float reputationPriceDiscount(uint factionTemplate)
    {
        const t = me.context.client.factionTemplates.lookup(factionTemplate);
        if (t is null || !t.faction || me.player.reputation is null)
            return 1;
        return me.player.reputation.rankWith(t.faction) >= ReputationRank.honored ? 0.9f : 1;
    }

    /**
     * The price discount for buying: 10% off at Honored with the vendor's faction, and
     * 10% more for a rank of 3 (a visual rank: Sergeant) at a vendor friendly to the player's side.
     */
    package float buyPriceDiscount(uint factionTemplate)
    {
        import dmangos.world.relations : isFriend, Relating;

        float discount = reputationPriceDiscount(factionTemplate);
        if (me.honorRank.visualRank >= 3)
            if (const t = me.context.client.factionTemplates.lookup(factionTemplate))
                if (isFriend(Relating(0, t, false, 0, 0, true), me.relatingNow(), me.context.client))
                    discount -= 0.1f;
        return discount;
    }

    /**
     * The repair discount: the reputation's, and at a PvP-flagged vendor 5% from rank byte 6 (Corporal,
     * Grunt) and 5% more from 8 (Master Sergeant, Senior Sergeant).
     */
    package float repairDiscount(uint factionTemplate, bool vendorFlagged)
    {
        float discount = reputationPriceDiscount(factionTemplate);
        if (vendorFlagged)
        {
            const rank = me.player.values.getByte!PLAYER_BYTES_3(3);
            if (rank >= 6)
                discount -= 0.05f;
            if (rank >= 8)
                discount -= 0.05f;
        }
        return discount;
    }

    /// Whether the player is within the standings the quest asks for.
    package bool satisfyQuestReputation(const ref Quest quest)
    {
        if (me.player.reputation is null)
            return true;
        if (quest.requiredMinRepFaction
            && me.player.reputation.standingWith(quest.requiredMinRepFaction) < quest.requiredMinRepValue)
            return false;
        if (quest.requiredMaxRepFaction
            && me.player.reputation.standingWith(quest.requiredMaxRepFaction) >= quest.requiredMaxRepValue)
            return false;
        return true;
    }

package:
    /// The player sets or clears war with a faction.
    @Handles(Opcode.CMSG_SET_FACTION_ATWAR, WorldState.inWorld)
    void handleSetFactionAtWar(ref ByteReader reader)
    {
        const id = reader.read!uint, flag = reader.read!ubyte;
        me.player.reputation.setAtWarById(id, flag != 0);
    }

    /// The player moves a faction to or from the inactive list.
    @Handles(Opcode.CMSG_SET_FACTION_INACTIVE, WorldState.inWorld)
    void handleSetFactionInactive(ref ByteReader reader)
    {
        const id = reader.read!uint, flag = reader.read!ubyte;
        me.player.reputation.setInactive(id, flag != 0);
    }

    /// Reactions forced by auras (`SPELL_AURA_FORCE_REACTION`: disguises), by faction (`ReputationMgr::m_forcedReactions`).
    package ReputationRank[uint] forcedReactions;

    /**
     * `SPELL_AURA_FORCE_REACTION` begins (`apply`) or ends (`Aura::HandleForceReaction`): `faction` reacts to the
     * player as `rank`, the client told (`SMSG_SET_FORCED_REACTIONS`: each faction and rank). Friendly now, the
     * player and that faction's creatures stop fighting each other (`StopAttackFaction`).
     */
    package void forceReaction(uint faction, int rank, bool apply)
    {
        if (apply)
            forcedReactions[faction] = cast(ReputationRank) rank;
        else
            forcedReactions.remove(faction);
        ByteWriter w;
        w.put(cast(uint) forcedReactions.length);
        foreach (id, forced; forcedReactions)
        {
            w.put(id);
            w.put(uint(forced));
        }
        me.deliver(Opcode.SMSG_SET_FORCED_REACTIONS, w.data);
        if ((apply && rank >= ReputationRank.friendly)
                || (!apply && me.player.reputation.rankWith(faction) >= ReputationRank.friendly))
            stopAttackFaction(faction);
    }

    /// The fights with `faction`'s creatures end: this player's swing at one, and theirs at it (`StopAttackFaction`).
    private void stopAttackFaction(uint faction)
    {
        bool ofFaction(Creature c)
        {
            const t = c is null ? null : me.context.client.factionTemplates.lookup(c.values.get!UNIT_FIELD_FACTIONTEMPLATE);
            return t !is null && t.faction == faction;
        }

        if (me.attacking && ofFaction(cast(Creature) me.map.findObject(me.attacking)))
            me.stopAttack(false);
        foreach (guid; me.threateners)
            if (auto c = cast(Creature) me.map.findObject(guid))
                if (ofFaction(c) && c.ai !is null)
                    c.ai.forget(me.player.guid, me.map);
    }

    /// The player picks the faction shown on the experience bar.
    @Handles(Opcode.CMSG_SET_WATCHED_FACTION, WorldState.inWorld)
    void handleSetWatchedFaction(ref ByteReader reader)
    {
        me.player.values.set!PLAYER_FIELD_WATCHED_FACTION_INDEX(reader.read!int);
        me.flushPlayerChanges();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A kill of a creature with `creature_onkill_reputation` raises the player's standing with its
 * faction (the client told it is now in the list, and how it stands) and half as much with the
 * faction's team; a creature grey to the player gives a fifth; the client's war checkbox; the
 * standings saved and loaded at the next login.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.reputation : FactionFlag;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : OnKillReputation;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // Faction: id, list id, 4 race masks, 4 class masks, 4 base values, 4 flags, team, 8 names, 10 skipped.
    uint[] faction(uint id, uint list, uint flags, uint team)
    {
        auto row = new uint[factionFormat.length];
        row[0] = id;
        row[1] = list;
        row[14] = flags;
        row[18] = team;
        return row;
    }
    enum uint guild = 72, team = 469;
    context.client.factions = typeof(context.client.factions).parse(buildDbc(factionFormat,
        [faction(guild, 3, 0, team), faction(team, 5, 0, 0)]), "Faction.dbc");
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    context.data.onKillReputation[creatureInnkeeper] = OnKillReputation([guild, 0], [ReputationRank.exalted, 0],
        [true, false], [25, 0], false);

    anduin.session.inWorld.reputations.rewardKillReputation(keeper, 1);
    auto got = anduin.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_SET_FACTION_VISIBLE));
    assert(me.reputation.standingWith(guild) == 25 && me.reputation.standingWith(team) == 12, "half to the team");
    // `SMSG_SET_FACTION_STANDING`: the guild's, then the team's.
    int[] standings;
    foreach (packet; got)
        if (packet.opcode == Opcode.SMSG_SET_FACTION_STANDING)
        {
            auto r = ByteReader(packet.body_);
            foreach (_; 0 .. r.read!uint)
                standings ~= [r.read!int, r.read!int];
        }
    assert(standings == [3, 25, 5, 12]);

    // A creature grey to a level 20 player: a fifth.
    me.data.level = 20;
    anduin.session.inWorld.reputations.rewardKillReputation(keeper, 1);
    assert(me.reputation.standingWith(guild) == 25 + 5);

    Quest quest;
    quest.questLevel = 1;
    quest.rewRepFaction[0 .. 2] = [guild, team];
    quest.rewRepValue[0 .. 2] = [250, -500];
    anduin.session.inWorld.reputations.rewardQuestReputation(quest);
    assert(me.reputation.standingWith(guild) == 80 && me.reputation.standingWith(team) == -486);

    // War, by the client's checkbox.
    ByteWriter w;
    w.put(3u);
    w.put(ubyte(1));
    anduin.write(Opcode.CMSG_SET_FACTION_ATWAR, w.data);
    assert(me.reputation.atWarWith(context.client.factions.lookup(guild)));

    // Saved at logout, there at the next login.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    const rows = db.loadReputation(me.data.guid);
    assert(rows.length == 2 && rows.canFind!(r => r.faction == guild && r.standing == 80
        && (r.flags & (FactionFlag.visible | FactionFlag.atWar)) == (FactionFlag.visible | FactionFlag.atWar)));
}

// A spell's REPUTATION effect: the caster's standing with the faction of its misc value grows by its value.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionFormat, spellRangeFormat;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : ImplicitTarget, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    import dmangos.bytes : bits = floatBits;
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint armorsmiths = 72;
    auto row = new uint[factionFormat.length];
    row[0] = armorsmiths;
    row[1] = 3;
    context.client.factions = typeof(context.client.factions).parse(buildDbc(factionFormat, [row]), "Faction.dbc");
    enum uint favour = 90701;
    context.data.spells.spells[favour] = testSpell(favour, SpellEffect.reputation, ImplicitTarget.caster, 500);
    context.data.spells.spells.edit(favour).miscValue[0] = armorsmiths;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= favour;
    ByteWriter w;
    w.put(favour);
    SpellTargets(TargetFlags.self).write(w);
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    anduin.read();
    assert(me.reputation.standingWith(armorsmiths) == 500);
}

/// A disguise (`SPELL_AURA_FORCE_REACTION`): the faction's reaction forced and told to the client, then undone.
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint disguise = 91_901, defias = 15;
    context.data.spells.spells[disguise] = testSpell(disguise, 6, 1, 0);
    context.data.spells.spells.edit(disguise).casting.applyAuraName[0] = AuraType.forceReaction;
    context.data.spells.spells.edit(disguise).miscValue[0] = defias;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = anduin.session.inWorld;
    anduin.read();
    auto aura = makeAura(context.data.spells.spell(disguise), me.player.guid, 1, -1, true,
        [int(ReputationRank.friendly), 0, 0]);
    me.addAura(aura);
    auto r = ByteReader(bodyOf(anduin.read(), Opcode.SMSG_SET_FORCED_REACTIONS));
    assert(r.read!uint == 1 && r.read!uint == defias && r.read!uint == ReputationRank.friendly);
    assert((*me.relatingNow().forced).get(defias, ReputationRank.hated) == ReputationRank.friendly);
    me.removeAura(me.player.auras.find(disguise));
    assert(bodyOf(anduin.read(), Opcode.SMSG_SET_FORCED_REACTIONS) == [0, 0, 0, 0], "none forced now");
}
