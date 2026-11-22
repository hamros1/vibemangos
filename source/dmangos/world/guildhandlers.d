/**
 * What players do with guilds: guild
 * charters bought from a guild master, signed by nine others and turned in to found a guild;
 * invitations; the roster and information; promotions and demotions; leaving, removing,
 * disbanding and handing over leadership; the message of the day, the guild information and the
 * members' notes; the ranks and their rights; the tabard; guild and officer chat; and the members'
 * logins and logouts. Mixed into `dmangos.world.session.Character`.
 */
module dmangos.world.guildhandlers;

import dmangos.world.money : Copper;

/// The guild charter item, its cost (copper), the display id of its petition, and the signatures it needs.
enum uint guildCharter = 5863, guildCharterCost = 1000, charterDisplayId = 16161, petitionSignsNeeded = 9;

/// The tabard's price (10 gold).
enum uint tabardCost = 100_000;

/// The results of signing a charter and of turning one in.
enum : uint
{
    petitionSignOk = 0,
    petitionSignAlreadySigned = 1,
    petitionTurnOk = 0,
    petitionTurnAlreadyInGuild = 2,
    petitionTurnNeedMoreSignatures = 4,
}

/// See the module documentation.
mixin template GuildHandlers()
{
    import dmangos.world.money : Copper;
    import std.conv : to;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.database : GuildMemberRecord, GuildRankRecord, GuildRecord;
    import dmangos.world.guild;
    import dmangos.world.guildhandlers;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.updatefields : ITEM_FIELD_ENCHANTMENT, PLAYER_GUILDID, PLAYER_GUILDRANK;

    private uint guildInvited;     // the guild that invited this player
    private ulong guildInviter;    // ... and who

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// This player's guild; null if it has none.
    package Guild ownGuild()
    {
        return player is null ? null : context.guilds.of(player.data.guid);
    }

    /// This player's rank in its guild.
    private uint ownRank()
    {
        if (auto g = ownGuild())
            if (auto m = g.member(player.data.guid))
                return m.rank;
        return GuildRank.initiate;
    }

    private void guildResult(GuildCommand command, string text, GuildError error)
    {
        deliver(Opcode.SMSG_GUILD_COMMAND_RESULT, guildCommandResult(command, text, error));
    }

    /// The guild and rank fields others see, from the guild this player is in now.
    public void refreshGuildFields()
    {
        if (player is null)
            return;
        auto g = ownGuild();
        player.values.set!PLAYER_GUILDID(g is null ? 0u : g.id);
        player.values.set!PLAYER_GUILDRANK(g is null ? 0u : ownRank());
        flushPlayerChanges();
    }

    /**
     * A packet to the guild: to the members online here
     * whose rank has `right` (0: everyone), and in a cluster to those on the other nodes.
     */
    package void guildBroadcast(Guild g, Opcode opcode, const(ubyte)[] body_, uint right = 0)
    {
        context.guildToMembersHere(g.id, opcode, body_, right);
        if (context.guildBroadcastElsewhere !is null)
            context.guildBroadcastElsewhere(g.id, right, cast(ushort) opcode, body_);
    }

    /// An event for the guild's log (`LogGuildEvent`), saved; the other nodes read it with the guild.
    private void logGuildEvent(Guild g, GuildEventLogType type, uint player1, uint player2 = 0, uint newRank = 0)
    {
        const e = g.logEvent(type, player1, player2, cast(ubyte) newRank, context.unixTime);
        context.database.saveGuildEvent(g.id, e);
    }

    /// A guild changed: saved, its members' fields here brought up to date, the other nodes told.
    package void guildChanged(Guild g)
    {
        context.guildFieldsHere();
        if (context.guildReloadElsewhere !is null)
            context.guildReloadElsewhere(g.id);
    }

    private void guildEvent(Guild g, GuildEvent event, const(string)[] strings, ulong guid = 0)
    {
        guildBroadcast(g, Opcode.SMSG_GUILD_EVENT, guildEventPacket(event, strings, guid));
    }

    /// The character called `name`, online here or elsewhere: its low guid, name and race; false if none is online.
    private bool onlineNamed(string name, out uint low, out string realName, out ubyte race, out ushort node)
    {
        if (auto here = context.onlinePlayer(name))
        {
            low = cast(uint) here.character.guid;
            realName = here.character.data.name;
            race = here.character.data.race;
            return true;
        }
        if (auto remote = context.remotePlayer(name))
        {
            low = cast(uint) remote.entry.guid;
            realName = remote.entry.name;
            race = remote.entry.race;
            node = remote.node;
            return true;
        }
        return false;
    }

    // -----------------------------------------------------------------------
    // Queries, information, roster
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_GUILD_QUERY, WorldState.inWorld)
    void handleGuildQuery(ref ByteReader reader)
    {
        const id = reader.read!uint;
        if (auto g = context.guilds.find(id))
            deliver(Opcode.SMSG_GUILD_QUERY_RESPONSE, g.queryResponse());
        else
            guildResult(GuildCommand.create, "", GuildError.notInGuild);
    }

    @Handles(Opcode.CMSG_GUILD_INFO, WorldState.inWorld)
    void handleGuildInfo()
    {
        import std.datetime.systime : SysTime;

        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        const created = SysTime.fromUnixTime(g.created);
        ByteWriter w;
        w.putCString(g.name);
        w.put(cast(uint) created.day);
        w.put(cast(uint) created.month);
        w.put(cast(uint) created.year);
        w.put(cast(uint) g.members.length);
        w.put(g.accountCount);
        deliver(Opcode.SMSG_GUILD_INFO, w.data);
    }

    @Handles(Opcode.CMSG_GUILD_ROSTER, WorldState.inWorld)
    void handleGuildRoster()
    {
        if (auto g = ownGuild())
            deliver(Opcode.SMSG_GUILD_ROSTER, rosterOf(g));
    }

    /// The guild roster as this player sees it (officers' notes only with the right).
    package const(ubyte)[] rosterOf(Guild g)
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        const seesOfficerNotes = g.hasRight(ownRank(), GuildRight.viewOfficerNote);
        ByteWriter w;
        w.put(cast(uint) g.members.length);
        w.putCString(g.motd);
        w.putCString(g.info);
        w.put(cast(uint) g.ranks.length);
        foreach (ref r; g.ranks)
            w.put(r.rights);
        foreach (ref m; g.members)
        {
            const guid = context.playerGuid(m.guid);
            w.put(guid);
            ubyte level = m.level, classId = m.classId;
            uint zone = m.zone;
            bool online;
            if (auto here = context.onlinePlayer(guid))
            {
                online = true;
                level = cast(ubyte) here.character.data.level;
                classId = here.character.data.classId;
                zone = here.character.data.zone;
            }
            else if (auto remote = context.remotePlayer(guid))
            {
                online = true;
                level = remote.entry.level;
                classId = remote.entry.classId;
                zone = remote.entry.zone;
            }
            w.put(cast(ubyte) online);
            w.putCString(m.name);
            w.put(m.rank);
            w.put(level);
            w.put(classId);
            w.put(zone);
            if (!online)
                w.put(cast(float)((context.unixTime - m.logoutTime) / 86_400.0));
            w.putCString(m.publicNote);
            w.putCString(seesOfficerNotes ? m.officerNote : "");
        }
        return w.data;
    }

    // -----------------------------------------------------------------------
    // Founding: `CMSG_GUILD_CREATE` (game masters only here) and charters
    // -----------------------------------------------------------------------

    /// Founds a guild of `name` with this player its master; null if the name is taken.
    package Guild foundGuild(string name)
    {
        if (context.guilds.named(name) !is null)
            return null;
        GuildRecord r;
        r.id = context.database.nextGuildId();
        r.name = name;
        r.leader = player.data.guid;
        r.motd = "No message set.";
        r.created = context.unixTime;
        r.ranks = Guild.defaultRanks();
        context.database.saveGuild(r);
        context.database.saveGuildRanks(r.id, r.ranks);
        auto g = new Guild(r);
        context.guilds.put(g);
        addGuildMember(g, player.data.guid, GuildRank.master);
        info!"%s: '%s' founded guild %s '%s'"(remoteAddress, player.data.name, g.id, name);
        return g;
    }

    /// This player or another (online here or not) joins at `rank`.
    package void addGuildMember(Guild g, uint member, uint rank)
    {
        GuildMemberRecord m;
        m.guid = member;
        m.rank = rank;
        if (member == player.data.guid)
        {
            m.name = player.data.name;
            m.level = cast(ubyte) player.data.level;
            m.classId = player.data.classId;
            m.zone = player.data.zone;
            m.account = account.id;
        }
        else
        {
            const info = context.database.nameInfo(member);
            if (!info.isNull)
            {
                m.name = info.get.name;
                m.classId = info.get.classId;
            }
        }
        m.logoutTime = context.unixTime;
        g.members ~= m;
        context.guilds.memberJoined(g, member);
        context.database.saveGuildMember(g.id, member, rank, "", "");
        context.database.deletePetitionsOf(member);
        guildChanged(g);
    }

    /// The client's `/gcreate`: a game master's only.
    @Handles(Opcode.CMSG_GUILD_CREATE, WorldState.inWorld)
    void handleGuildCreate(ref ByteReader reader)
    {
        const name = reader.readCString();
        if (!hasPermissions || ownGuild() !is null || name.length == 0)
            return;
        if (foundGuild(name) is null)
            guildResult(GuildCommand.create, name, GuildError.nameExistsS);
    }

    /// A guild master's charter, its price, the signatures it needs.
    @Handles(Opcode.CMSG_PETITION_SHOWLIST, WorldState.inWorld)
    void handlePetitionShowList(const ClientGuid request)
    {
        import dmangos.world.npchandlers : NpcFlag;

        if (interactableNpc(request.guid, NpcFlag.petitioner) is null)
            return;
        ByteWriter w;
        w.put(request.guid);
        w.put(ubyte(1));
        w.put(uint(1));
        w.put(guildCharter);
        w.put(charterDisplayId);
        w.put(guildCharterCost);
        w.put(uint(1));
        w.put(petitionSignsNeeded);
        deliver(Opcode.SMSG_PETITION_SHOWLIST, w.data);
    }

    /// The player buys a charter for a guild of a name not taken, for 10 silver.
    @Handles(Opcode.CMSG_PETITION_BUY, WorldState.inWorld)
    void handlePetitionBuy(ref ByteReader reader)
    {
        import dmangos.world.inventory : InventoryResult, ItemPosCount;
        import dmangos.world.defines : nullBag, nullSlot;
        import dmangos.world.npchandlers : NpcFlag;

        const npc = reader.read!ulong;
        reader.read!uint;
        reader.read!ulong;
        const name = reader.readCString();
        if (interactableNpc(npc, NpcFlag.petitioner) is null || ownGuild() !is null)
            return;
        if (context.guilds.named(name) !is null)
            return guildResult(GuildCommand.create, name, GuildError.nameExistsS);
        import dmangos.world.names : normalizedName;

        if (name.length < 2 || name.length > 24 || normalizedName(name) is null && name.length < 2)
            return guildResult(GuildCommand.create, name, GuildError.nameInvalid);
        if (guildCharter !in context.data.items)
            return;
        if (!player.canAfford(Copper(guildCharterCost)))
            return;
        ItemPosCount[] dest;
        if (player.inventory.canStoreNew(nullBag, nullSlot, dest, guildCharter, 1) != InventoryResult.ok)
            return;
        auto charter = player.inventory.storeNew(dest, guildCharter);
        if (charter is null)
            return;
        player.pay(Copper(guildCharterCost));
        charter.values.set!ITEM_FIELD_ENCHANTMENT(charter.guid); // the guild (its id is the charter's)
        context.database.createPetition(player.data.guid, charter.guid, name);
        flushInventory();
        flushPlayerChanges();
    }

    /// The signatures of a charter, to this player or (an offer) to another.
    private const(ubyte)[] signaturesPacket(ulong charter, ulong owner, const(uint)[] signers)
    {
        import dmangos.world.objects : HighGuid, lowGuid, makeGuid;

        ByteWriter w;
        w.put(charter);
        w.put(owner);
        w.put(lowGuid(charter));
        w.put(cast(ubyte) signers.length);
        foreach (s; signers)
        {
            w.put(context.playerGuid(s));
            w.put(uint(0));
        }
        return w.data;
    }

    @Handles(Opcode.CMSG_PETITION_SHOW_SIGNATURES, WorldState.inWorld)
    void handlePetitionShowSignatures(const ClientGuid request)
    {
        import dmangos.world.objects : HighGuid, lowGuid, makeGuid;

        const p = context.database.loadPetition(lowGuid(request.guid));
        if (p.isNull)
            return;
        deliver(Opcode.SMSG_PETITION_SHOW_SIGNATURES, signaturesPacket(request.guid,
            context.playerGuid(p.get.owner), p.get.signers));
    }

    /// What a charter says.
    @Handles(Opcode.CMSG_PETITION_QUERY, WorldState.inWorld)
    void handlePetitionQuery(ref ByteReader reader)
    {
        import dmangos.world.objects : HighGuid, lowGuid, makeGuid;

        reader.read!uint; // the guild: the charter's low guid
        const charter = reader.read!ulong;
        const p = context.database.loadPetition(lowGuid(charter));
        if (p.isNull)
            return;
        ByteWriter w;
        w.put(lowGuid(charter));
        w.put(context.playerGuid(p.get.owner));
        w.putCString(p.get.name);
        w.put(ubyte(0));
        w.put(uint(1));
        w.put(petitionSignsNeeded);
        w.put(petitionSignsNeeded);
        foreach (_; 0 .. 4)
            w.put(uint(0));
        w.put(ushort(0));
        foreach (_; 0 .. 4)
            w.put(uint(0));
        deliver(Opcode.SMSG_PETITION_QUERY_RESPONSE, w.data);
    }

    /// The player signs a charter: of the owner's faction, in no guild, once an account, nine at most.
    @Handles(Opcode.CMSG_PETITION_SIGN, WorldState.inWorld)
    void handlePetitionSign(ref ByteReader reader)
    {
        import dmangos.world.objects : HighGuid, lowGuid, makeGuid;

        const charter = reader.read!ulong;
        const p = context.database.loadPetition(lowGuid(charter));
        if (p.isNull)
            return;
        const owner = context.playerGuid(p.get.owner);
        if (owner == player.guid)
            return;
        const ownerInfo = context.database.nameInfo(p.get.owner);
        if (!context.config.allowTwoSideInteractionGuild && !ownerInfo.isNull
            && context.client.teamForRace(ownerInfo.get.race) != context.client.teamForRace(player.data.race))
            return guildResult(GuildCommand.create, "", GuildError.notAllied);
        if (ownGuild() !is null)
            return guildResult(GuildCommand.invite, player.data.name, GuildError.alreadyInGuildS);
        if (guildInvited)
            return guildResult(GuildCommand.invite, player.data.name, GuildError.alreadyInvitedS);
        if (p.get.signers.length + 1 > petitionSignsNeeded)
            return;
        ByteWriter w;
        w.put(charter);
        w.put(player.guid);
        const already = context.database.accountSignedPetition(account.id, lowGuid(charter));
        if (!already)
            context.database.signPetition(p.get.owner, lowGuid(charter), player.data.guid, account.id);
        w.put(already ? petitionSignAlreadySigned : petitionSignOk);
        deliver(Opcode.SMSG_PETITION_SIGN_RESULTS, w.data);
        if (auto ownerSession = context.onlinePlayer(owner))
            ownerSession.deliver(Opcode.SMSG_PETITION_SIGN_RESULTS, w.data);
    }

    /// The player declines to sign a charter: the owner hears of it.
    @Handles(Opcode.MSG_PETITION_DECLINE, WorldState.inWorld)
    void handlePetitionDecline(const ClientGuid request)
    {
        import dmangos.world.objects : HighGuid, lowGuid, makeGuid;

        const p = context.database.loadPetition(lowGuid(request.guid));
        if (p.isNull)
            return;
        ByteWriter w;
        w.put(player.guid);
        if (auto owner = context.onlinePlayer(context.playerGuid(p.get.owner)))
            owner.deliver(Opcode.MSG_PETITION_DECLINE, w.data);
    }

    /// The charter shown to another player, to sign.
    @Handles(Opcode.CMSG_OFFER_PETITION, WorldState.inWorld)
    void handleOfferPetition(ref ByteReader reader)
    {
        import dmangos.world.objects : lowGuid;

        const charter = reader.read!ulong, target = reader.read!ulong;
        auto other = context.onlinePlayer(target);
        if (other is null)
            return;
        if (!context.config.allowTwoSideInteractionGuild
            && context.client.teamForRace(other.character.data.race) != context.client.teamForRace(player.data.race))
            return guildResult(GuildCommand.create, "", GuildError.notAllied);
        if (context.guilds.of(cast(uint) target) !is null)
            return guildResult(GuildCommand.invite, player.data.name, GuildError.alreadyInGuildS);
        const p = context.database.loadPetition(lowGuid(charter));
        if (p.isNull || p.get.owner != player.data.guid)
            return;
        other.deliver(Opcode.SMSG_PETITION_SHOW_SIGNATURES, signaturesPacket(charter, player.guid, p.get.signers));
    }

    /// The charter turned in: with its nine signatures, the charter becomes the guild.
    @Handles(Opcode.CMSG_TURN_IN_PETITION, WorldState.inWorld)
    void handleTurnInPetition(const ClientGuid request)
    {
        import dmangos.world.objects : lowGuid;

        void turnResult(uint result)
        {
            ByteWriter w;
            w.put(result);
            deliver(Opcode.SMSG_TURN_IN_PETITION_RESULTS, w.data);
        }

        const p = context.database.loadPetition(lowGuid(request.guid));
        if (p.isNull)
            return;
        if (ownGuild() !is null)
            return turnResult(petitionTurnAlreadyInGuild);
        if (p.get.owner != player.data.guid)
            return;
        if (p.get.signers.length < petitionSignsNeeded)
            return turnResult(petitionTurnNeedMoreSignatures);
        if (context.guilds.named(p.get.name) !is null)
            return guildResult(GuildCommand.create, p.get.name, GuildError.nameExistsS);
        auto item = itemByGuid(request.guid);
        if (item is null)
            return;
        player.inventory.destroy(item.bagSlot, item.slot);
        flushInventory();
        auto g = foundGuild(p.get.name);
        if (g is null)
            return;
        foreach (signer; p.get.signers)
            addGuildMember(g, signer, g.lowestRank);
        context.database.deletePetition(lowGuid(request.guid));
        turnResult(petitionTurnOk);
        context.guildFieldsHere();
    }

    // -----------------------------------------------------------------------
    // Invitations, joining, leaving
    // -----------------------------------------------------------------------

    /// The player invites someone online into its guild.
    @Handles(Opcode.CMSG_GUILD_INVITE, WorldState.inWorld)
    void handleGuildInvite(ref ByteReader reader)
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        const name = reader.readCString();
        uint low;
        string realName;
        ubyte race;
        ushort node;
        if (!onlineNamed(name, low, realName, race, node))
            return guildResult(GuildCommand.invite, name, GuildError.playerNotFoundS);
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (context.database.isIgnoring(low, player.data.guid))
            return;
        if (!context.config.allowTwoSideInteractionGuild
            && context.client.teamForRace(race) != context.client.teamForRace(player.data.race))
            return guildResult(GuildCommand.invite, name, GuildError.notAllied);
        if (context.guilds.of(low) !is null)
            return guildResult(GuildCommand.invite, realName, GuildError.alreadyInGuildS);
        if (!g.hasRight(ownRank(), GuildRight.invite))
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        const guid = context.playerGuid(low);
        if (auto here = cast(typeof(this)) context.onlinePlayer(guid))
        {
            if (here.guildInvited)
                return guildResult(GuildCommand.invite, realName, GuildError.alreadyInvitedS);
            here.guildInvite(g.id, player.guid, player.data.name, g.name);
        }
        else if (context.guildInviteElsewhere !is null)
            context.guildInviteElsewhere(node, guid, g.id, player.guid, player.data.name, g.name);
        logGuildEvent(g, GuildEventLogType.invitePlayer, player.data.guid, low);
        guildChanged(g); // the other nodes' copies hold the log too
        guildResult(GuildCommand.invite, realName, GuildError.noMoreInGuild); // `ERR_PLAYER_NO_MORE_IN_GUILD`: 0, "invited"
    }

    /// An invitation for this player (here, or from another node): it is asked.
    public void guildInvite(uint guild, ulong inviter, string inviterName, string guildName)
    {
        if (guildInvited || ownGuild() !is null)
            return;
        guildInvited = guild;
        guildInviter = inviter;
        ByteWriter w;
        w.putCString(inviterName);
        w.putCString(guildName);
        deliver(Opcode.SMSG_GUILD_INVITE, w.data);
    }

    /// The invited player accepts: in at the lowest rank; everyone hears of it.
    @Handles(Opcode.CMSG_GUILD_ACCEPT, WorldState.inWorld)
    void handleGuildAccept()
    {
        if (!guildInvited || ownGuild() !is null)
            return;
        auto g = context.guilds.find(guildInvited);
        guildInvited = 0;
        if (g is null)
            return;
        logGuildEvent(g, GuildEventLogType.joinGuild, player.data.guid);
        addGuildMember(g, player.data.guid, g.lowestRank);
        guildEvent(g, GuildEvent.joined, [player.data.name], player.guid);
    }

    /// The invited player declines: the inviter hears of it.
    @Handles(Opcode.CMSG_GUILD_DECLINE, WorldState.inWorld)
    void handleGuildDecline()
    {
        if (guildInvited)
        {
            ByteWriter w;
            w.putCString(player.data.name);
            if (auto inviter = context.onlinePlayer(guildInviter))
                inviter.deliver(Opcode.SMSG_GUILD_DECLINE, w.data);
            else if (auto remote = context.remotePlayer(guildInviter))
                if (context.deliverRemote !is null)
                    context.deliverRemote(remote.node, guildInviter, cast(ushort) Opcode.SMSG_GUILD_DECLINE, w.data);
        }
        guildInvited = 0;
    }

    /// A member gone (the guild's master: the highest rank left takes over).
    private void removeGuildMember(Guild g, uint member)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;
        import dmangos.world.objects : HighGuid, makeGuid;

        if (g.leader == member)
        {
            GuildMemberRecord* best;
            foreach (ref m; g.members)
                if (m.guid != member && (best is null || m.rank < best.rank))
                    best = &m;
            if (best !is null)
            {
                const oldName = g.member(member).name;
                g.leader = best.guid;
                best.rank = GuildRank.master;
                context.database.saveGuild(g.record);
                context.database.saveGuildMember(g.id, best.guid, best.rank, best.publicNote, best.officerNote);
                guildEvent(g, GuildEvent.leaderChanged, [oldName, best.name]);
            }
        }
        g.members = g.members.filter!(m => m.guid != member).array;
        context.guilds.memberLeft(member);
        context.database.deleteGuildMember(member);
        if (auto gone = cast(typeof(this)) context.onlinePlayer(context.playerGuid(member)))
            gone.refreshGuildFields();
        guildChanged(g);
    }

    /// Disbands the guild: everyone out, its rows gone.
    private void disbandGuild(Guild g)
    {
        guildEvent(g, GuildEvent.disbanded, null);
        foreach (m; g.members.dup)
        {
            context.guilds.memberLeft(m.guid);
            context.database.deleteGuildMember(m.guid);
        }
        context.guilds.remove(g.id);
        context.database.deleteGuild(g.id);
        info!"%s: guild %s '%s' disbanded"(remoteAddress, g.id, g.name);
        guildChanged(g);
    }

    @Handles(Opcode.CMSG_GUILD_LEAVE, WorldState.inWorld)
    void handleGuildLeave()
    {
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader == player.data.guid && g.members.length > 1)
            return guildResult(GuildCommand.quit, "", GuildError.leaderLeave);
        if (g.leader == player.data.guid)
            return disbandGuild(g);
        guildResult(GuildCommand.quit, g.name, GuildError.noMoreInGuild);
        logGuildEvent(g, GuildEventLogType.leaveGuild, player.data.guid);
        removeGuildMember(g, player.data.guid);
        guildEvent(g, GuildEvent.left, [player.data.name], player.guid);
    }

    @Handles(Opcode.CMSG_GUILD_REMOVE, WorldState.inWorld)
    void handleGuildRemove(ref ByteReader reader)
    {
        const name = reader.readCString();
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (!g.hasRight(ownRank(), GuildRight.remove))
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        auto m = g.memberNamed(name);
        if (m is null)
            return guildResult(GuildCommand.invite, name, GuildError.notInGuildS);
        if (m.guid == g.leader)
            return guildResult(GuildCommand.quit, "", GuildError.leaderLeave);
        if (ownRank() >= m.rank)
            return guildResult(GuildCommand.quit, name, GuildError.rankTooHighS);
        const removedName = m.name;
        logGuildEvent(g, GuildEventLogType.uninvitePlayer, player.data.guid, m.guid);
        removeGuildMember(g, m.guid);
        guildEvent(g, GuildEvent.removed, [removedName, player.data.name]);
    }

    @Handles(Opcode.CMSG_GUILD_DISBAND, WorldState.inWorld)
    void handleGuildDisband()
    {
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader != player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        disbandGuild(g);
    }

    // -----------------------------------------------------------------------
    // Ranks and leadership
    // -----------------------------------------------------------------------

    private void changeRank(bool promote, string name)
    {
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (!g.hasRight(ownRank(), promote ? GuildRight.promote : GuildRight.demote))
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        auto m = g.memberNamed(name);
        if (m is null)
            return guildResult(GuildCommand.invite, name, GuildError.notInGuildS);
        if (m.guid == player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.nameInvalid);
        if (promote ? ownRank() + 1 >= m.rank : ownRank() >= m.rank)
            return guildResult(GuildCommand.invite, name, GuildError.rankTooHighS);
        if (!promote && m.rank >= g.lowestRank)
            return guildResult(GuildCommand.invite, name, GuildError.rankTooLowS);
        m.rank = promote ? m.rank - 1 : m.rank + 1;
        context.database.saveGuildMember(g.id, m.guid, m.rank, m.publicNote, m.officerNote);
        logGuildEvent(g, promote ? GuildEventLogType.promotePlayer : GuildEventLogType.demotePlayer, player.data.guid,
            m.guid, m.rank);
        guildEvent(g, promote ? GuildEvent.promotion : GuildEvent.demotion, [player.data.name, m.name,
            g.ranks[m.rank].name]);
        guildChanged(g);
    }

    @Handles(Opcode.CMSG_GUILD_PROMOTE, WorldState.inWorld)
    void handleGuildPromote(ref ByteReader reader)
    {
        changeRank(true, reader.readCString());
    }

    @Handles(Opcode.CMSG_GUILD_DEMOTE, WorldState.inWorld)
    void handleGuildDemote(ref ByteReader reader)
    {
        changeRank(false, reader.readCString());
    }

    @Handles(Opcode.CMSG_GUILD_LEADER, WorldState.inWorld)
    void handleGuildLeader(ref ByteReader reader)
    {
        const name = reader.readCString();
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader != player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        auto next = g.memberNamed(name);
        if (next is null)
            return guildResult(GuildCommand.invite, name, GuildError.notInGuildS);
        auto self = g.member(player.data.guid);
        g.leader = next.guid;
        next.rank = GuildRank.master;
        self.rank = GuildRank.officer;
        context.database.saveGuild(g.record);
        context.database.saveGuildMember(g.id, next.guid, next.rank, next.publicNote, next.officerNote);
        context.database.saveGuildMember(g.id, self.guid, self.rank, self.publicNote, self.officerNote);
        guildEvent(g, GuildEvent.leaderChanged, [player.data.name, next.name]);
        guildChanged(g);
    }

    /// A rank's name and rights changed, by the master (the master's own keep every right).
    @Handles(Opcode.CMSG_GUILD_RANK, WorldState.inWorld)
    void handleGuildRank(ref ByteReader reader)
    {
        const id = reader.read!uint, rights = reader.read!uint;
        const name = reader.readCString();
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader != player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        if (id >= g.ranks.length)
            return;
        g.ranks[id].name = name;
        g.ranks[id].rights = id == GuildRank.master ? GuildRight.all : rights;
        rankListChanged(g);
    }

    @Handles(Opcode.CMSG_GUILD_ADD_RANK, WorldState.inWorld)
    void handleGuildAddRank(ref ByteReader reader)
    {
        const name = reader.readCString();
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader != player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        if (g.ranks.length >= maxRanks)
            return;
        g.ranks ~= GuildRankRecord(cast(uint) g.ranks.length, name, GuildRight.chatListen | GuildRight.chatSpeak);
        rankListChanged(g);
    }

    /// The lowest rank goes, if nobody holds it and five are left.
    @Handles(Opcode.CMSG_GUILD_DEL_RANK, WorldState.inWorld)
    void handleGuildDelRank()
    {
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (g.leader != player.data.guid)
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        if (g.ranks.length <= minRanks)
            return;
        foreach (ref m; g.members)
            if (m.rank == g.lowestRank)
                return; // `ERR_GUILD_RANK_IN_USE` is not in 1.12's strings, so nothing is answered
        g.ranks = g.ranks[0 .. $ - 1];
        rankListChanged(g);
    }

    private void rankListChanged(Guild g)
    {
        context.database.saveGuildRanks(g.id, g.ranks);
        deliver(Opcode.SMSG_GUILD_QUERY_RESPONSE, g.queryResponse());
        guildBroadcast(g, Opcode.SMSG_GUILD_QUERY_RESPONSE, g.queryResponse());
        guildChanged(g);
    }

    // -----------------------------------------------------------------------
    // Texts and the tabard
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_GUILD_MOTD, WorldState.inWorld)
    void handleGuildMotd(ref ByteReader reader)
    {
        const motd = reader.remaining ? reader.readCString() : "";
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (!g.hasRight(ownRank(), GuildRight.setMotd))
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        g.motd = motd;
        context.database.saveGuild(g.record);
        guildEvent(g, GuildEvent.motd, [motd]);
        guildChanged(g);
    }

    @Handles(Opcode.CMSG_GUILD_INFO_TEXT, WorldState.inWorld)
    void handleGuildInfoText(ref ByteReader reader)
    {
        const text = reader.readCString(500);
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (!g.hasRight(ownRank(), GuildRight.modifyInfo))
            return guildResult(GuildCommand.create, "", GuildError.permissions);
        g.info = text;
        context.database.saveGuild(g.record);
        guildChanged(g);
    }

    private void setNote(ref ByteReader reader, bool officer)
    {
        const name = reader.readCString(), note = reader.readCString(31);
        auto g = ownGuild();
        if (g is null)
            return guildResult(GuildCommand.create, "", GuildError.notInGuild);
        if (!g.hasRight(ownRank(), officer ? GuildRight.editOfficerNote : GuildRight.editPublicNote))
            return guildResult(GuildCommand.invite, "", GuildError.permissions);
        auto m = g.memberNamed(name);
        if (m is null)
            return guildResult(GuildCommand.invite, name, GuildError.notInGuildS);
        if (officer)
            m.officerNote = note;
        else
            m.publicNote = note;
        context.database.saveGuildMember(g.id, m.guid, m.rank, m.publicNote, m.officerNote);
        deliver(Opcode.SMSG_GUILD_ROSTER, rosterOf(g));
        guildChanged(g);
    }

    @Handles(Opcode.CMSG_GUILD_SET_PUBLIC_NOTE, WorldState.inWorld)
    void handleGuildSetPublicNote(ref ByteReader reader)
    {
        setNote(reader, false);
    }

    @Handles(Opcode.CMSG_GUILD_SET_OFFICER_NOTE, WorldState.inWorld)
    void handleGuildSetOfficerNote(ref ByteReader reader)
    {
        setNote(reader, true);
    }

    /// `MSG_TABARDVENDOR_ACTIVATE`: the tabard designer's window.
    @Handles(Opcode.MSG_TABARDVENDOR_ACTIVATE, WorldState.inWorld)
    void handleTabardVendorActivate(const ClientGuid request)
    {
        import dmangos.world.npchandlers : NpcFlag;

        if (interactableNpc(request.guid, NpcFlag.tabardDesigner) is null)
            return;
        ByteWriter w;
        w.put(request.guid);
        deliver(Opcode.MSG_TABARDVENDOR_ACTIVATE, w.data);
    }

    /// A new guild emblem: the guild master's, at a tabard designer, for 10 gold.
    @Handles(Opcode.MSG_SAVE_GUILD_EMBLEM, WorldState.inWorld)
    void handleSaveGuildEmblem(ref ByteReader reader)
    {
        import dmangos.world.npchandlers : NpcFlag;

        enum uint success = 0, noGuild = 2, notMaster = 3, notEnoughMoney = 4, invalidVendor = 5;
        void emblemResult(uint result)
        {
            ByteWriter w;
            w.put(result);
            deliver(Opcode.MSG_SAVE_GUILD_EMBLEM, w.data);
        }

        const vendor = reader.read!ulong;
        uint[5] emblem;
        foreach (ref part; emblem)
            part = reader.read!uint;
        if (interactableNpc(vendor, NpcFlag.tabardDesigner) is null)
            return emblemResult(invalidVendor);
        auto g = ownGuild();
        if (g is null)
            return emblemResult(noGuild);
        if (g.leader != player.data.guid)
            return emblemResult(notMaster);
        if (!player.canAfford(Copper(tabardCost)))
            return emblemResult(notEnoughMoney);
        player.pay(Copper(tabardCost));
        flushPlayerChanges();
        g.emblem = emblem;
        context.database.saveGuild(g.record);
        emblemResult(success);
        deliver(Opcode.SMSG_GUILD_QUERY_RESPONSE, g.queryResponse());
        guildChanged(g);
    }

    // -----------------------------------------------------------------------
    // Chat, logins, logouts
    // -----------------------------------------------------------------------

    /// `CHAT_MSG_GUILD` and `CHAT_MSG_OFFICER`: from a rank that may speak, to those that may listen.
    package void guildChat(bool officer, uint language, string text)
    {
        import dmangos.world.queries : chatMessage;

        auto g = ownGuild();
        if (g is null)
            return;
        if (!g.hasRight(ownRank(), officer ? GuildRight.officerChatSpeak : GuildRight.chatSpeak))
            return;
        const body_ = chatMessage(officer ? ChatType.CHAT_MSG_OFFICER : ChatType.CHAT_MSG_GUILD, cast(Language) language,
            player.guid, text, player.chatTag);
        guildBroadcast(g, Opcode.SMSG_MESSAGECHAT, body_, officer ? GuildRight.officerChatListen : GuildRight.chatListen);
    }

    /// At login: the guild's message of the day, and its members hear the player signed on.
    package void guildLogin()
    {
        auto g = ownGuild();
        refreshGuildFields();
        if (g is null)
            return;
        deliver(Opcode.SMSG_GUILD_EVENT, guildEventPacket(GuildEvent.motd, [g.motd]));
        guildEvent(g, GuildEvent.signedOn, [player.data.name], player.guid);
    }

    /// At logout: its members hear it signed off; its level and zone kept for the roster.
    package void guildLogout()
    {
        auto g = ownGuild();
        if (g is null)
            return;
        if (auto m = g.member(player.data.guid))
        {
            m.level = cast(ubyte) player.data.level;
            m.zone = player.data.zone;
            m.logoutTime = context.unixTime;
        }
        guildEvent(g, GuildEvent.signedOff, [player.data.name], player.guid);
    }
}

/**
 * A guild's life: founded by a game master, Jaina invited and in at the lowest rank, the guild's chat
 * heard by both, the message of the day set, Jaina promoted and demoted (not past the lowest rank,
 * not by herself), the roster, and her leaving; every step saved.
 */
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.guild;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : PLAYER_GUILDID, PLAYER_GUILDRANK;
    import dmangos.bytes : ByteWriter;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.administrator);
    auto jaina = loggedIn(context, db, 8, "Jaina", at);
    anduin.read();
    jaina.read();

    ubyte[] text(string s)
    {
        ByteWriter w;
        w.putCString(s);
        return w.data.dup;
    }

    bool got(TestClient* c, Opcode opcode)
    {
        foreach (p; c.read())
            if (p.opcode == opcode)
                return true;
        return false;
    }

    anduin.write(Opcode.CMSG_GUILD_CREATE, text("Knights of Stormwind"));
    auto g = context.guilds.named("knights of stormwind");
    assert(g !is null && g.leader == 7 && g.ranks.length == 5 && db.loadGuild(g.id).get.members.length == 1);
    assert(anduin.session.character.values.get!PLAYER_GUILDID == g.id);
    jaina.write(Opcode.CMSG_GUILD_CREATE, text("Mine"));
    assert(context.guilds.named("mine") is null, "not a game master's");

    anduin.read();
    anduin.write(Opcode.CMSG_GUILD_INVITE, text("Jaina"));
    assert(got(&jaina, Opcode.SMSG_GUILD_INVITE));
    jaina.write(Opcode.CMSG_GUILD_ACCEPT, null);
    assert(g.member(8) !is null && g.member(8).rank == GuildRank.initiate);
    assert(jaina.session.character.values.get!PLAYER_GUILDRANK == GuildRank.initiate);
    assert(got(&anduin, Opcode.SMSG_GUILD_EVENT), "Anduin hears she joined");
    jaina.read();

    // The guild's chat: both hear it.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_GUILD, "Hello, guild!"));
    assert(got(&anduin, Opcode.SMSG_MESSAGECHAT) && got(&jaina, Opcode.SMSG_MESSAGECHAT));
    // Officers' chat: an initiate may not speak in it.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_OFFICER, "psst"));
    assert(!got(&anduin, Opcode.SMSG_MESSAGECHAT));

    anduin.write(Opcode.CMSG_GUILD_MOTD, text("Raid tonight"));
    assert(g.motd == "Raid tonight" && db.loadGuild(g.id).get.motd == "Raid tonight" && got(&jaina, Opcode.SMSG_GUILD_EVENT));

    anduin.write(Opcode.CMSG_GUILD_PROMOTE, text("jaina"));
    assert(g.member(8).rank == GuildRank.member);
    anduin.write(Opcode.CMSG_GUILD_DEMOTE, text("Jaina"));
    anduin.write(Opcode.CMSG_GUILD_DEMOTE, text("Jaina"));
    assert(g.member(8).rank == GuildRank.initiate, "not below the lowest rank");
    jaina.read();
    jaina.write(Opcode.CMSG_GUILD_PROMOTE, text("Jaina"));
    assert(g.member(8).rank == GuildRank.initiate && got(&jaina, Opcode.SMSG_GUILD_COMMAND_RESULT), "no right");

    anduin.read();
    anduin.write(Opcode.CMSG_GUILD_ROSTER, null);
    foreach (p; anduin.read())
        if (p.opcode == Opcode.SMSG_GUILD_ROSTER)
            assert(p.body_[0] == 2, "two members");

    jaina.write(Opcode.CMSG_GUILD_LEAVE, null);
    assert(g.member(8) is null && context.guilds.of(8) is null && jaina.session.character.values.get!PLAYER_GUILDID == 0);
    assert(db.loadGuild(g.id).get.members.length == 1, "saved");

    // The event log (`guild_eventlog`): the invitation, the joining, a promotion, a demotion (the second one refused,
    // not logged), the leaving; each in the place after the last, saved, and read back with the guild.
    with (GuildEventLogType)
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        const log = db.loadGuild(g.id).get.events;
        assert(log.map!(e => cast(GuildEventLogType) e.type).array == [invitePlayer, joinGuild, promotePlayer, demotePlayer,
            leaveGuild]);
        assert(log.map!(e => e.logGuid).array == [1, 2, 3, 4, 5]);
        assert(log[0].player1 == 7 && log[0].player2 == 8 && log[1].player1 == 8 && log[1].player2 == 0);
        assert(log[2].player1 == 7 && log[2].player2 == 8 && log[2].newRank == GuildRank.member);
        assert(log[3].newRank == GuildRank.initiate && log[4].player1 == 8 && log[0].time == context.unixTime);
        assert(g.events == log && g.inviterOf(8) == 7 && g.inviterOf(7) == 0);
    }
    // The master alone leaves: the guild is disbanded.
    anduin.write(Opcode.CMSG_GUILD_LEAVE, null);
    assert(context.guilds.count == 0 && db.loadGuild(g.id).isNull);
}

/**
 * A guild charter: bought from a guild master for 10 silver (its petition saved), signed by another
 * player (once), and refused at the turn-in with too few signatures.
 */
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.items[guildCharter] = context.data.items[itemShirt];
    context.data.items.edit(guildCharter).entry = guildCharter;
    enum uint guildMaster = 4974;
    auto master = cast() context.data.creatureTemplates[creatureInnkeeper];
    master.entry = guildMaster;
    master.npcFlags = 0x200 | 0x400; // petitioner, tabard designer
    context.data.creatureTemplates[guildMaster] = master;
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto varian = loggedIn(context, db, 7, "Varian", at);
    auto jaina = loggedIn(context, db, 8, "Jaina", at);
    CreatureSpawn spawn = {guid: 90200, entry: guildMaster, map: 0, x: at.x + 1, y: at.y, z: at.z};
    auto npc = context.makeCreature(&spawn);
    context.map(0).addObject(npc);
    varian.read();
    jaina.read();
    auto me = cast(Player) varian.session.character;
    me.values.set!(imported!"dmangos.world.updatefields".PLAYER_FIELD_COINAGE)(5000u); // exactly this much

    bool got(TestClient* c, Opcode opcode, out const(ubyte)[] body_)
    {
        foreach (p; c.read())
            if (p.opcode == opcode)
            {
                body_ = p.body_.dup;
                return true;
            }
        return false;
    }

    const(ubyte)[] b;
    varian.write(Opcode.CMSG_PETITION_SHOWLIST, ClientGuid(npc.guid));
    assert(got(&varian, Opcode.SMSG_PETITION_SHOWLIST, b) && b[9 .. 13] == [0x01, 0, 0, 0]);
    ByteWriter buy;
    buy.put(npc.guid);
    buy.put(uint(0));
    buy.put(ulong(0));
    buy.putCString("Order of the Lion");
    foreach (_; 0 .. 10)
        buy.put(uint(0));
    buy.put(ushort(0));
    buy.put(ubyte(0));
    buy.put(uint(1));
    buy.put(uint(0));
    varian.write(Opcode.CMSG_PETITION_BUY, buy.data);
    assert(me.money == Copper(4000), "ten silver");
    assert(me.hasItem(guildCharter), "the charter");
    import dmangos.world.defines : inventorySlotBag0, inventorySlotItemEnd;
    import dmangos.world.inventory : Item;

    Item charterItem;
    foreach (ubyte slot; 0 .. inventorySlotItemEnd)
        if (auto item = me.inventory[inventorySlotBag0, slot])
            if (item.entry == guildCharter)
                charterItem = item;
    assert(charterItem !is null);
    const charter = charterItem.fullGuid;
    const petition = db.loadPetition(charterItem.guid);
    assert(!petition.isNull && petition.get.name == "Order of the Lion" && petition.get.owner == 7);

    ByteWriter sign;
    sign.put(charter);
    sign.put(ubyte(1));
    jaina.write(Opcode.CMSG_PETITION_SIGN, sign.data);
    assert(got(&jaina, Opcode.SMSG_PETITION_SIGN_RESULTS, b) && b[16] == petitionSignOk);
    assert(db.loadPetition(charterItem.guid).get.signers == [8]);
    jaina.write(Opcode.CMSG_PETITION_SIGN, sign.data);
    assert(got(&jaina, Opcode.SMSG_PETITION_SIGN_RESULTS, b) && b[16] == petitionSignAlreadySigned, "once");

    varian.read();
    varian.write(Opcode.CMSG_TURN_IN_PETITION, ClientGuid(charter));
    assert(got(&varian, Opcode.SMSG_TURN_IN_PETITION_RESULTS, b) && b[0] == petitionTurnNeedMoreSignatures);
    assert(context.guilds.count == 0 && me.hasItem(guildCharter), "no guild yet; the charter kept");
}
