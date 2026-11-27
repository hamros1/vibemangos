/**
 * A character in the world (docs/DESIGN.md, "Where the player's gameplay lives", step 3): the
 * player's simulation, apart from the connection its client talks through.
 *
 * A `Character` exists from login (or arriving from another node) until logout (or leaving for
 * another node). It holds the `Player` and everything the player does in the world: every gameplay
 * mixin (movement, combat, spells, quests, items, groups, the GM commands, ...) and their state.
 * Its `connection` (`dmangos.world.session.WorldSession`) holds the socket, the encryption, the
 * account and the protocol state, authenticates, serves the character screen, and hands the packets
 * of a player in the world to its character (`handlePacket`).
 *
 * The gameplay code reaches what belongs to the connection (the account, the protocol state, the
 * client's address, sending a packet) through properties of the same names that forward to it.
 */
module dmangos.world.character;

import dmangos.world.spellids;

import dmangos.world.honor : HonorHandlers;
import dmangos.world.pvp : PvPHandlers;
import dmangos.world.battleground : BattlegroundHandlers;
import dmangos.world.worldpvp : WorldPvpHandlers;
import dmangos.world.enchanting : Enchanting;
import dmangos.world.itemuse : ItemUseHandlers;
import dmangos.world.professions : Professions;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes;
import dmangos.timer : IntervalTimer;
import dmangos.log;
import dmangos.net.dispatch : DispatchResult, HandlesFor = Handles, PacketDispatch;
import dmangos.world.channelhandlers : Channels;
import dmangos.world.charscreen : CharacterLogin;
import dmangos.world.commands : ChatCommands;
import dmangos.world.gmactions : GmActions;
import dmangos.world.gmaccess : GmAccess, readGmAccess;
import dmangos.world.gmtargets : GmTargets;
import dmangos.world.combathandlers : CombatHandlers;
import dmangos.world.death : DeathHandlers;
import dmangos.world.loothandlers : LootHandlers;
import dmangos.world.spellhandlers : SpellHandlers;
import dmangos.world.aurahandlers : AuraHandlers;
import dmangos.world.classspells : ClassSpells;
import dmangos.world.physicalclasses : PhysicalClassRules;
import dmangos.world.procs : ProcHandlers;
import dmangos.world.effecthandlers : EffectHandlers;
import dmangos.world.tradehandlers : Trading;
import dmangos.world.duelhandlers : Dueling;
import dmangos.world.questhandlers : QuestHandlers;
import dmangos.world.talenthandlers : Talents;
import dmangos.world.mailhandlers : Mailbox;
import dmangos.world.reputationhandlers : Reputations;
import dmangos.world.gameobjecthandlers : GameObjectHandlers;
import dmangos.world.auctionhandlers : Auctioneer;
import dmangos.world.taxihandlers : Taxi;
import dmangos.world.crowdcontrol : CrowdControlHandlers;
import dmangos.world.mounting : MountRules;
import dmangos.world.guardians : GuardianSummons;
import dmangos.world.durability : DurabilityRules;
import dmangos.world.rituals : RitualSummoning;
import dmangos.world.homebind : Homebind;
import dmangos.world.unit : Blow, UnitRef;
import dmangos.world.auras : Aura, makeAura;
import dmangos.world.spells : SpellInfo;
import dmangos.world.creature : Creature;
import dmangos.world.loot : Looter;
import dmangos.world.combat : Fighter, MeleeDamage;
import dmangos.world.relations : Relating;
import dmangos.world.sessionscripting : SessionScripting;
import dmangos.world.social : FriendInfo, Contacts;
import dmangos.world.guildhandlers : GuildHandlers;
import dmangos.world.pethandlers : PetHandlers;
import dmangos.world.petauras : PetAuraRules;
import dmangos.script.api : MenuOption, QuestProgress;
import dmangos.world.grouphandlers : GroupHandlers;
import dmangos.world.exploration : Exploration;
import dmangos.world.environment : EnvironmentHandlers;
import dmangos.world.moveorders : MovementOrders;
import dmangos.world.inworld : InWorldHandlers;
import dmangos.world.itemhandlers : ItemHandlers;
import dmangos.world.npchandlers : NpcHandlers;
import dmangos.world.teleport : Teleport, TeleportHandlers;
import dmangos.world.context : Kickable, WorldContext;
import dmangos.world.database : WorldAccount;
import dmangos.world.objects : UpdateData, UpdatePacket;
import dmangos.world.map : deliverUpdate, Inhabitant, Map;
import dmangos.world.movement : Position;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.player : DeathState, Player, PlayerFlags, Viewer;
import dmangos.world.queries : chatMessage;
import dmangos.world.opcodes;
import dmangos.world.packets;

import dmangos.world.session : WorldSession, WorldState;

package alias Handles = HandlesFor!(Opcode, WorldState);

/// See the module documentation.
final class Character : OnlinePlayer, Looter
{
    /// The connection its client talks through (here, or relaying to its home node).
    WorldSession connection;

    mixin PacketDispatch!(Handles, "taxi", "mailbox", "auctioneer", "reputations", "talents", "trading", "dueling", "channels", "contacts", "enchanting", "professions", "homebind");

    Taxi taxi; /// flight masters and the flight under way (`dmangos.world.taxihandlers`)
    Homebind homebind; /// the inn the hearthstone returns to (`dmangos.world.homebind`)
    Professions professions; /// professions' skills and recipes (`dmangos.world.professions`)
    Enchanting enchanting; /// enchantments put on items (`dmangos.world.enchanting`)
    Contacts contacts; /// friends and ignored players (`dmangos.world.social`)

    /// `OnlinePlayer.ignores`: whether this player ignores `guid` (`contacts`).
    bool ignores(ulong guid) const
    {
        return contacts.ignores(guid);
    }
    Channels channels; /// chat channels joined, left and spoken in (`dmangos.world.channelhandlers`)
    Dueling dueling; /// a duel asked, under way and ended (`dmangos.world.duelhandlers`)
    Trading trading; /// trading with another player (`dmangos.world.tradehandlers`)
    Talents talents; /// talents learned and reset (`dmangos.world.talenthandlers`)
    Reputations reputations; /// factions: standing, at war, inactive, watched (`dmangos.world.reputationhandlers`)
    Auctioneer auctioneer; /// the auction house: listing, bidding and buying out (`dmangos.world.auctionhandlers`)
    Mailbox mailbox; /// the mailbox: letters sent, read and taken (`dmangos.world.mailhandlers`)

    package
    {
        WorldContext context;
        MonoTime migratedAt;     // when the player last moved between nodes
        Player player;           // while in the world
        MonoTime enteredWorld;

        // Teleports (the destination and the teleport's state) and the order counter of
        // MSG_MOVE_TELEPORT_ACK.
        Teleport teleporting;
        uint moveOrderCounter;
        bool triggerpassCheat;    // `.cheat triggerpass`: area triggers pass
        bool cooldownCheat;       // `.cheat cooldown`: no cooldowns
        bool castTimeCheat;       // `.cheat casttime`: every cast instant
        bool godModeCheat;        // `.cheat god`: no damage taken
        bool powerCheat;          // `.cheat power`: spells cost nothing
        bool invincible;          // `.invincible`: creatures do not attack it
        imported!"dmangos.world.gmstate".GmState gmState; // what its commands keep between one and the next
        bool[ulong] gmTargets;    // `.gm allowwhispers`: players who may whisper while the GM tag is on
        uint floodLines;          // flood protection: chat lines counted until `floodTime`
        long floodTime;

        // The update tick: the 20-second logout, regeneration, rest, saving.
        bool loggingOut;
        MonoTime logoutRequestedAt;
        IntervalTimer regenTimer = IntervalTimer(2.seconds);  // a full regeneration tick
        IntervalTimer restTimer = IntervalTimer(1.seconds);
        IntervalTimer saveTimer;

        // Zones: the once-a-second check, a zone the client announced (checked after its next move),
        // and the 100 ms position checks.
        IntervalTimer zoneTimer = IntervalTimer(1.seconds);
        bool zoneUpdatePending;
        uint pendingZone;
        uint lastPositionCheck; // server time

        // The movement check: where the player was, and when.
        Position checkpoint;
        MonoTime checkpointTime;
        imported!"dmangos.world.movement".SpellPullMotion spellPull;
        Position groupPositionAt; // where group members out of sight last heard the player was
    }

    ///
    this(WorldSession connection, WorldContext context)
    in (connection !is null && context !is null)
    {
        this.connection = connection;
        this.context = context;
        taxi = new Taxi(this);
        homebind = new Homebind(this);
        professions = new Professions(this);
        enchanting = new Enchanting(this);
        contacts = new Contacts(this);
        channels = new Channels(this);
        dueling = new Dueling(this);
        trading = new Trading(this);
        talents = new Talents(this);
        reputations = new Reputations(this);
        auctioneer = new Auctioneer(this);
        mailbox = new Mailbox(this);
    }

    /// One of the player's packets (the connection's protocol state `state`): handled here, or not one of its.
    DispatchResult handlePacket(Opcode opcode, WorldState state, ref ByteReader reader)
    {
        import dmangos.world.guild : GuildCommand, GuildError;
        import dmangos.world.guildmutation : mutatesGuild;

        if (state != WorldState.inWorld || !context.guildWriter.serializes(context) || !mutatesGuild(opcode))
            return dispatchPacket(opcode, state, reader);
        auto pending = reader;
        bool started;
        DispatchResult result;
        const saved = context.guildWriter.commit(context, {
            started = true;
            result = dispatchPacket(opcode, state, pending);
        });
        reader = pending;
        if (!saved)
        {
            if (started)
            {
                saveProgressOnLeave = false;
                connection.kick("guild action could not be committed");
            }
            else
                guildResult(GuildCommand.create, "", GuildError.internal);
        }
        return result;
    }

    private bool saveProgressOnLeave = true;

    /// The player leaves the world, the connection still open or not.
    void leave(string why, bool loggingOut)
    {
        leaveWorld(why, loggingOut);
    }

    // -----------------------------------------------------------------------
    // The connection's, as the gameplay code knows them
    // -----------------------------------------------------------------------

    package
    {
        @property ref inout(WorldAccount) account() inout { return connection.account; }
        @property string remoteAddress() const { return connection.remoteAddress; }
        @property ref inout(uint) build() inout { return connection.build; }
        @property ref WorldState state_() { return connection.state_; }
        @property ref ushort homeNode() { return connection.homeNode; }
        @property ref ushort ownerNode() { return connection.ownerNode; }
        @property ref bool releaseWhenBack() { return connection.releaseWhenBack; }
        @property ref bool tutorialRowMissing() { return connection.tutorialRowMissing; }
        @property ref string carriedAddress() { return connection.carriedAddress; }

        void send(T)(auto ref const T packet)
        {
            connection.send(packet);
        }

        void finish()
        {
            connection.finish();
        }

        void disconnect()
        {
            connection.disconnect();
        }
    }

    /// Frames a packet for this player's client (`Inhabitant.deliver`).
    void deliver(Opcode opcode, const(ubyte)[] body_)
    {
        connection.deliver(opcode, body_);
    }

    /// Closes its connection (`Kickable.kick`): the player leaves the world.
    void kick(string reason)
    {
        connection.kick(reason);
    }

    /// The client's address.
    @property string address() const
    {
        return connection.address;
    }

    /// The round-trip time the client last reported, in milliseconds.
    @property uint latencyMs() const
    {
        return connection.latencyMs;
    }

    /// The connection's protocol state.
    @property WorldState state() const
    {
        return connection.state;
    }

    /// Whether the connection is closing.
    @property bool wantsClose() const
    {
        return connection.wantsClose;
    }

    /// The node holding its client, if another; 0 if here.
    @property ushort home() const
    {
        return connection.home;
    }

    /// The character being played, if any.
    @property const(Player) character() const
    {
        return player;
    }

    /// The create block a player who just came into sight gets: group mates see real health.
    UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
    {
        const kind = appearanceKind(viewer);
        return player.createForOthers(serverTime, kind != 0, kind > 1 ? kind - 2 : 0);
    }

    /// 0 for a stranger, 1 for a group member, or the substituted faction plus 2.
    uint appearanceKind(const Inhabitant viewer) const
    {
        if (!context.groups.sameGroup(player.guid, viewer.character.guid))
            return 0;
        const faction = context.groupViewerFaction(player.guid, player.values, viewer.character);
        return faction ? faction + 2 : 1;
    }

    /// The player's body while it is dead and released (`DeathHandlers`); null otherwise.
    package const(imported!"dmangos.world.corpse".Corpse) ownCorpse() const
    {
        return corpse;
    }

    /// One tick of the world update; see `InWorldHandlers.updateInWorld`.
    void update(Duration elapsed)
    {
        if (player !is null)
            updateInWorld(elapsed);
    }

    // -----------------------------------------------------------------------
    // The player as a unit (`dmangos.world.unit`): what creatures and the rules of units see of it
    // -----------------------------------------------------------------------

    /// See `UnitRef`.
    @property ulong combatGuid() const
    {
        return player is null ? 0 : player.guid;
    }

    /// See `UnitRef`: nobody to fight once it has left the world.
    Fighter fighter() const
    {
        if (player is null)
        {
            Fighter gone;
            gone.alive = false;
            return gone;
        }
        return player.fighter;
    }

    /// See `UnitRef`.
    Relating relating()
    {
        return relatingNow();
    }

    /// The map the player is on (null when not in the world).
    @property Map currentMap()
    {
        return player is null ? null : map;
    }

    /// The player as a unit on its map.
    @property UnitRef unit()
    {
        return UnitRef.of(this);
    }





    /// See `dealDamage`.
    void sufferDamage(UnitRef attacker, uint damage, const Blow blow)
    {
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.combat : MeleeHitOutcome;

        import dmangos.world.updatefields : UNIT_FIELD_BYTES_1;

        // takeBlow stands the victim up. The sitting crit still deals critical damage,
        // but defender procs evaluate it as an ordinary landed swing.
        const sittingCrit = blow.kind == BlowKind.melee && blow.melee.outcome == MeleeHitOutcome.crit
            && player !is null && player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0;
        takeBlow(attacker, damage, blow);
        if (damage && player !is null && player.alive) // a hold the damage breaks (a fear, a root)
        {
            import dmangos.world.unit : brokenByDamage;

            foreach (aura; brokenByDamage(player.auras, blow, map.random))
                removeAura(aura);
        }
        if (damage && player !is null && player.alive) // a cast under way pushed back, a channel cut short
            damagedWhileCasting(blow.kind == BlowKind.periodic,
                attacker.kind == imported!"dmangos.world.unit".UnitKind.player && attacker.session is this);
        // A swing that landed: its damage shields strike back. Its auras may proc on it, and on a dodge, a parry or a
        // block (those that ask for one: `dmangos.world.procs`).
        if (blow.kind == BlowKind.melee && attacker && player !is null && player.alive
                && blow.melee.outcome != MeleeHitOutcome.evade)
        {
            import dmangos.world.procs : ProcHit, procExOfSwing;

            const landed = blow.melee.outcome != MeleeHitOutcome.miss && blow.melee.outcome != MeleeHitOutcome.dodge
                && blow.melee.outcome != MeleeHitOutcome.parry;
            const canRetaliate = attacker.replica is null || blow.retaliate !is null;
            if (landed && canRetaliate)
                damageShields(attacker, blow.retaliate);
            if (blow.melee.outcome == MeleeHitOutcome.block && canRetaliate)
                blockDamageProcs(attacker, blow.retaliate);
            if (player !is null && player.alive)
                procAuras(ProcFlag.takeMeleeSwing, attacker, ProcHit(null, procExOfSwing(sittingCrit ? MeleeHitOutcome.normal : blow.melee.outcome), damage,
                    cast(ubyte) blow.melee.type, damage != 0));
        }
        else if (blow.kind == BlowKind.spell && damage && attacker && player !is null && player.alive)
        {
            import dmangos.world.procs : ProcEx, ProcHit;

            procAuras(ProcFlag.takeHarmfulSpell, attacker, ProcHit(null, blow.crit ? ProcEx.criticalHit : ProcEx.normalHit,
                damage));
        }
    }



    /// See `UnitRef`. The player's pet joins in.
    void threatAdded(ulong creature)
    {
        addThreatener(creature);
        petAssistAgainst(creature);
    }



    /// See `UnitRef`.
    uint healthPercent()
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        if (player is null || player.values.get!UNIT_FIELD_MAXHEALTH == 0)
            return 0;
        return cast(uint)(ulong(player.values.get!UNIT_FIELD_HEALTH) * 100 / player.values.get!UNIT_FIELD_MAXHEALTH);
    }


    /// See `UnitRef`.
    bool hasAuraOf(uint spell)
    {
        return player !is null && player.auras.find(spell) !is null;
    }

    /// See `UnitRef`.
    void tell(Opcode opcode, const(ubyte)[] body_)
    {
        deliver(opcode, body_);
    }

    /// See `UnitRef`.
    @property bool untouchable()
    {
        return invincible || feigningDeath;
    }

    /// See `UnitRef`.
    void questEventHappened(uint quest)
    {
        if (player !is null)
            areaExploredOrEventHappens(quest);
    }

    /// See `UnitRef`.
    void questFailedBy(uint quest)
    {
        if (player !is null)
            failQuest(quest);
    }

    /// See `UnitRef`.
    void showGossip(ulong npc, uint menu)
    {
        if (player is null)
            return;
        auto creature = context.npcFor(map.findObject(npc));
        if (creature is null)
            return;
        prepareGossipMenu(creature, menu);
        questMenu = null;
        sendPreparedGossip(creature);
    }



    /// The guild its `PLAYER_GUILDID` names (what it was in, until told otherwise).
    @property uint guildOfField()
    {
        import dmangos.world.updatefields : PLAYER_GUILDID;

        return player is null ? 0 : player.values.get!PLAYER_GUILDID;
    }




    /// The weekly honor maintenance ran: the honor columns and rows again from the database.
    void honorReckoned()
    {
        if (player !is null)
            loadHonor();
    }

    /// Out of its battleground copy, back where it came from if `teleport`.
    void battlegroundLeave(bool teleport)
    {
        if (player !is null)
            leaveBattleground(teleport);
    }

    /// Its battleground's spirit guides' pulse brought it back.
    void battlegroundSpiritHealed()
    {
        if (player !is null)
            spiritHealedHere();
    }

    /// Its battleground ended: alive again, its marks (`markSpell`). See `Battleground.end`.
    void battlegroundEnded(uint markSpell)
    {
        if (player !is null)
            battlegroundEndedHere(markSpell);
    }

    /// Bonus honor from its battleground; whether it counted.
    bool battlegroundBonusHonor(uint honor)
    {
        return player !is null && battlegroundBonusHonorHere(honor);
    }

    /// Reputation from its battleground.
    void battlegroundReputation(uint faction, int amount)
    {
        if (player !is null)
            reputations.modifyReputation(faction, amount);
    }

    /// Its battleground takes an aura off it (a flag it no longer carries).
    void battlegroundRemoveAura(uint spell)
    {
        if (player !is null)
            battlegroundRemoveAuraHere(spell);
    }

    /// A spell its battleground casts on it (a quest's credit).
    /// For the `.guild` GM commands: founds a guild named `name` led by this player (as a charter turned in).
    package imported!"dmangos.world.guild".Guild gmFoundGuild(string name)
    {
        import dmangos.world.guild : Guild;

        Guild made;
        const saved = context.guildWriter.commit(context, {
            if (ownGuild() is null)
                made = foundGuild(name);
        });
        return saved ? made : null;
    }

    /// For `.guild removeplayer`: this player leaves its guild (removed, as a kick).
    package void gmLeaveGuild()
    {
        context.guildWriter.commit(context, {
            if (auto g = ownGuild())
                removeGuildMember(g, player.data.guid);
        });
    }

    /// For `.guild disband`: this player's guild is disbanded.
    package void gmDisbandGuild()
    {
        context.guildWriter.commit(context, {
            if (auto g = ownGuild())
                disbandGuild(g);
        });
    }

    /// A creature's spell changes the player's standing with `faction` (`SPELL_EFFECT_REPUTATION`).
    void spellReputation(uint faction, int amount)
    {
        if (player !is null)
            reputations.modifyReputation(faction, amount);
    }

    /// Thrown from `from` (a creature's knockback): its client is told how, and moves.
    void knockedBack(Position from, float horizontal, float vertical)
    {
        import dmangos.world.movement : jumpGravity, SpellPullMotion;
        import std.algorithm.comparison : max;
        import std.math : atan2, cos, sin;

        if (player is null)
            return;
        const p = player.position;
        const angle = atan2(p.y - from.y, p.x - from.x);
        const x = cos(angle), y = sin(angle);
        if (horizontal > 0)
        {
            const airtime = 1 + max(0.0f, 2 * vertical / jumpGravity);
            spellPull = SpellPullMotion(p, x, y, horizontal, horizontal * airtime, context.clock(), moveOrderCounter);
        }
        else
            spellPull = typeof(spellPull).init;
        launchKnockback(x, y, horizontal, vertical);
    }

    /// Pulled toward the caster, stopping at contact range.
    package void pulledToward(Position caster, float contact, float speed)
    {
        import std.math : sqrt;
        import dmangos.world.movement : jumpGravity, SpellPullMotion;

        if (player is null || taxi.flying || !inControl || teleporting != Teleport.none)
            return;
        const start = player.position;
        const dx = caster.x - start.x, dy = caster.y - start.y;
        const apart = sqrt(dx * dx + dy * dy), distance = apart - contact;
        if (distance < 0.1f)
            return;
        const time = distance / speed;
        const rise = (caster.z - start.z) / time + jumpGravity * time / 2;
        spellPull = SpellPullMotion(start, dx / apart, dy / apart, speed, distance, context.clock(), moveOrderCounter);
        launchKnockback(spellPull.directionX, spellPull.directionY, speed, rise);
    }

    private void launchKnockback(float cosine, float sine, float horizontal, float vertical)
    {
        import dmangos.world.packets : ServerKnockBack;

        // The vertical speed is sent negated: the client counts upwards as negative, as in its jumps (CMaNGOS
        // `SendKnockBack`). Its acknowledgement shows the throw to others (`dmangos.world.moveorders`).
        send(ServerKnockBack(player.guid, moveOrderCounter++, cosine, sine, horizontal, -vertical));
    }

    /// Up to `amount` of power `type` taken (a creature's drain or burn): what was taken.
    int drainPower(ubyte type, int amount)
    {
        import dmangos.world.defines : Power;
        import dmangos.world.updatefields : UNIT_FIELD_POWER1;

        if (player is null || type > 4)
            return 0;
        const have = cast(int) player.values.get!UNIT_FIELD_POWER1(type);
        const taken = amount < have ? amount : have;
        if (taken > 0)
        {
            player.modifyPower(cast(Power) type, -taken);
            flushPlayerChanges();
        }
        return taken;
    }

    /// A spell (a creature's) sends the player to `at` on map `mapId` (`TELEPORT_UNITS`).
    void spellTeleport(uint mapId, Position at)
    {
        if (player !is null)
            commandTeleport(mapId, at);
    }

    /// Kill credit for a battleground's objective (a mine taken, a tower assaulted) toward the player's quests.
    void battlegroundKillCredit(uint entry)
    {
        if (player !is null)
            scriptKillCredit(entry, 0);
    }

    void battlegroundCast(uint spell)
    {
        if (player !is null)
            battlegroundCastHere(spell);
    }

    /// The player's honor rank, as the battleground scoreboard shows it.
    @property uint visibleHonorRank()
    {
        return player is null ? 4 : honorRank.rank;
    }



    /// See `UnitRef`.
    void showScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests)
    {
        if (player !is null)
            sendScriptGossip(npc, textId, options, withQuests);
    }


    /// See `UnitRef`.
    void killCreditFrom(uint entry, ulong creature)
    {
        if (player !is null)
            scriptKillCredit(entry, creature);
    }

    /// See `UnitRef`.
    @property bool castingSpell()
    {
        return generic.active;
    }

    /// See `UnitRef`.
    void auraRemovedBy(uint spell)
    {
        if (player !is null)
            if (auto aura = player.auras.find(spell))
                removeAura(aura);
    }

    /// See `UnitRef`.
    void castInterruptedBy(ulong by, int lockMs = 0)
    {
        import dmangos.world.spellcast : isInterruptible, SpellCastResult;

        // The cast and the channel (Arcane Missiles, Mind Flay, Drain Life) alike, if interruptible.
        if (generic.active && isInterruptible(*generic.spell))
        {
            const school = generic.spell.casting.school;
            interruptCast(SpellCastResult.interrupted);
            lockOutSchool(school, lockMs);
        }
        if (channelSpell !is null && isInterruptible(*channelSpell))
        {
            const school = channelSpell.casting.school;
            endChannel(true);
            lockOutSchool(school, lockMs);
        }
    }

    // -----------------------------------------------------------------------
    // `Looter`: what loot sees of the player (`dmangos.world.loot`, `loothandlers.d`)
    // -----------------------------------------------------------------------

    /// See `Looter`.
    @property ulong looterGuid() const
    {
        return player is null ? 0 : player.guid;
    }





    /// Rank used by the staff presence and who-list displays, and to keep bans off equal or higher staff.
    @property AccountLevel security() const
    {
        return gmAccess.rank();
    }

    @property string staffRoles() const
    {
        import std.array : join;
        return gmAccess.roles.join(", ");
    }

    bool allowsStaff(string capability) const
    {
        return gmAccess.allows(capability);
    }

    @property bool isStaff() const
    {
        return allowsStaff("staff.access");
    }

    /// Between `SMSG_NEW_WORLD` and the client's `MSG_MOVE_WORLDPORT_ACK`.
    @property bool transferring() const
    {
        return teleporting == Teleport.far;
    }

    package uint instanceId_; // the dungeon instance it is in (0: none)
    package uint entryMap = uint.max; // where it was before going into an instance (uint.max: unknown)
    package MonoTime dungeonEntryAsked; // a dungeon's host was asked whether it may go in, then
    package ulong selectedGo;         // the game object `.gobject select` chose
    package Position entryPoint;      // ditto

    /// See `OnlinePlayer.instanceId`.
    @property uint instanceId() const
    {
        return instanceId_;
    }

    /// The group changed: the leader flag, and the health the players around see and are seen with.
    void groupChanged()
    {
        if (player is null)
            return;
        updateLeaderFlag();
        homebind.instanceValidityOnGroupChange(); // out of the group inside a dungeon: sent out (`dmangos.world.homebind`)
        if (transferring)
            return;
        map.refreshVisibility(this); // a ghost and its group see each other
        // Each way only where the client has the other (a ghost may see the living that do not see it).
        Viewer viewOf(const Inhabitant other)
        {
            return context.groups.sameGroup(player.guid, other.character.guid) ? Viewer.groupMate : Viewer.stranger;
        }
        foreach (watcher; map.watchers(this))
            deliverUpdate(watcher, player.groupView(viewOf(watcher),
                context.groupViewerFaction(player.guid, player.values, watcher.character)));
        foreach (seen; map.seenBy(this))
            deliverUpdate(this, seen.character.groupView(viewOf(seen),
                context.groupViewerFaction(seen.character.guid, seen.character.values, player)));
        if (context.config.allowTwoSideInteractionGroup)
            map.refreshReplicaGroupFactions(this);
    }


private:

    void sendUpdate(const ref UpdateData update)
    {
        const packet = update.build();
        if (packet.compressed)
            send(ServerCompressedUpdateObject(cast(ubyte[]) packet.body_));
        else
            send(ServerUpdateObject(cast(ubyte[]) packet.body_));
    }

    /// The group leader flag, set if the player leads its group.
    void updateLeaderFlag()
    {
        auto group = context.groups.of(player.guid);
        player.setFlag(PlayerFlags.groupLeader, group !is null && group.isLeader(player.guid));
        flushPlayerChanges();
    }

    /**
     * Sends the player's changed fields to itself (unless `toSelf` is false: they were sent already),
     * and to each player who sees it the fields it may see: group mates and strangers see different
     * health values.
     */
    package void flushPlayerChanges(bool toSelf = true)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        UpdateData forSelf;
        if (toSelf && player.addChanges(forSelf, Viewer.self))
            sendUpdate(forSelf);
        // Built once for each kind of viewer (a group mate, a stranger), the same bytes to each of them.
        UpdatePacket[Viewer.max + 1] built;
        bool[Viewer.max + 1] isBuilt;
        if (!transferring)
            map.forEachWatcher(this, (Inhabitant watcher) {
            const view = context.groups.sameGroup(player.guid, watcher.character.guid) ? Viewer.groupMate
                : Viewer.stranger;
            if (!isBuilt[view])
            {
                UpdateData update;
                built[view] = player.addChanges(update, view) ? update.build() : UpdatePacket.init;
                isBuilt[view] = true;
            }
            const packet = built[view];
            if (packet.body_.length)
            {
                watcher.deliver(packet.compressed ? Opcode.SMSG_COMPRESSED_UPDATE_OBJECT : Opcode.SMSG_UPDATE_OBJECT,
                    packet.body_);
                if (const faction = context.groupViewerFaction(player.guid, player.values, watcher.character))
                    if (player.values.slotChanged(UNIT_FIELD_FACTIONTEMPLATE))
                        deliverUpdate(watcher, player.groupView(view, faction));
            }
        });
        if (!transferring)
            map.playerChanged(this); // nodes holding a replica of this player
        player.clearChanges();
    }

    /// The map the player is on.
    package @property Map map()
    in (player !is null)
    {
        return context.map(player.data.map, instanceId_);
    }

    /// Milliseconds on the server's clock, as movement packets carry them.
    uint serverTime()
    {
        return context.serverTime();
    }

    /// Seconds since the character entered the world.
    package uint secondsInWorld()
    {
        return cast(uint)(context.clock() - enteredWorld).total!"seconds";
    }

    void sendSystemMessage(string text)
    {
        send(ServerMessageChat(chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text)));
    }

    /// A message in the middle of the screen.
    package void sendNotification(string text)
    {
        send(ServerNotification(text));
    }


    // -----------------------------------------------------------------------
    // The handler groups
    // -----------------------------------------------------------------------

    mixin CharacterLogin;
    mixin InWorldHandlers;
    mixin TeleportHandlers;
    mixin GroupHandlers;
    mixin NpcHandlers;
    mixin ItemHandlers;
    mixin Exploration;
    mixin EnvironmentHandlers;
    mixin MovementOrders;
    package GmAccess gmAccess;

    private void refreshGmAccess()
    {
        gmAccess = readGmAccess(context.database, account.id);
    }

    mixin ChatCommands;
    mixin GmActions;
    mixin GmTargets;
    mixin GuildHandlers;
    mixin PetHandlers;
    mixin PetAuraRules;
    mixin CombatHandlers;
    mixin DeathHandlers;
    mixin LootHandlers;
    mixin SpellHandlers;
    mixin AuraHandlers;
    mixin ProcHandlers;
    mixin ClassSpells;
    mixin PhysicalClassRules;
    mixin EffectHandlers;
    mixin QuestHandlers;
    mixin GameObjectHandlers;
    mixin CrowdControlHandlers;
    mixin MountRules;
    mixin GuardianSummons;
    mixin DurabilityRules;
    mixin RitualSummoning;
    mixin PvPHandlers;
    mixin BattlegroundHandlers;
    mixin WorldPvpHandlers;
    mixin ItemUseHandlers;
    mixin HonorHandlers;
    mixin SessionScripting;
}

version (unittest)
{
    import core.time : MonoTime, msecs;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.relations : PlayerFlagsPvP;
    import dmangos.world.updatefields;

    private bool pvpFlagged(TestClient c)
    {
        return (c.session.inWorld.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
    }
}

// The PvP flag (`dmangos.world.pvp`). `/pvp`: on at once; off five minutes after it is turned off, not before.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = anduin.session.inWorld;
    anduin.write(Opcode.CMSG_TOGGLE_PVP, null);
    assert(pvpFlagged(anduin) && me.hasPlayerFlag(PlayerFlagsPvP.desired));
    anduin.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(0)]);
    assert(!me.hasPlayerFlag(PlayerFlagsPvP.desired) && pvpFlagged(anduin), "still flagged, for now");
    me.updatePvPTimers(299_000);
    assert(pvpFlagged(anduin));
    me.updatePvPTimers(1000);
    assert(!pvpFlagged(anduin), "five minutes on: off");
    // While wanted, the timer stands still.
    anduin.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
    me.updatePvPTimers(600_000);
    assert(pvpFlagged(anduin));
}

// The other side's land and capital flag a visitor on any realm; his own never does. The free-for-all arena.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.config.gameType = 0; // a normal realm
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(10, 0, 0));
    thrall.session.inWorld.updateZone(zoneStormwind, zoneStormwind);
    assert(pvpFlagged(thrall), "an orc in Stormwind");
    anduin.session.inWorld.updateZone(zoneStormwind, zoneStormwind);
    assert(!pvpFlagged(anduin), "a human at home");
    thrall.session.inWorld.updateZone(zoneElwynn, zoneElwynn);
    thrall.session.inWorld.updatePvPTimers(300_000);
    assert(pvpFlagged(thrall), "Alliance land flags him on a normal realm too");
    thrall.session.inWorld.updateZone(zoneStranglethorn, zoneStranglethorn);
    thrall.session.inWorld.updatePvPTimers(300_000);
    assert(!pvpFlagged(thrall), "contested land on a normal realm: off after five minutes");

    auto me = anduin.session.inWorld;
    me.updateZone(zoneStranglethorn, areaGurubashiArena);
    assert(me.isFreeForAll);
    me.updateArea(zoneStranglethorn);
    assert(!me.isFreeForAll, "out of the arena");
}

// A hit between players: the attacker of a flagged player is flagged and contested; an unflagged one
// cannot be attacked at all.
unittest
{
    import dmangos.world.relations : canAttack;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(2, 0, 0));
    auto orc = thrall.session.inWorld, human = anduin.session.inWorld;
    assert(!canAttack(orc.relatingNow(), human.relatingNow(), context.client), "not flagged: not a target");
    anduin.write(Opcode.CMSG_TOGGLE_PVP, null);
    assert(canAttack(orc.relatingNow(), human.relatingNow(), context.client), "flagged: a target");
    assert(!pvpFlagged(thrall));
    human.pvpHitBy(orc, orc.isPvP);
    assert(pvpFlagged(thrall) && orc.isPvPContested, "the attacker: flagged and contested");
    orc.updatePvPTimers(29_000);
    assert(orc.isPvPContested, "while in PvP combat it stays");
    orc.pvpLeftCombat();
    orc.updatePvPTimers(30_000);
    assert(!orc.isPvPContested && pvpFlagged(thrall), "30 s out of combat: not contested; flagged 5 minutes");
}

/// Mixed-faction groups see the ally template and cannot attack each other after grouping.
unittest
{
    import dmangos.world.config : WorldConfig;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig settings) { settings.allowTwoSideInteractionGroup = true; });
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.player);
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(2, 0, 0), AccountLevel.player, raceOrc);
    auto ally = anduin.session.inWorld, horde = thrall.session.inWorld;
    enum uint original = 2, friendly = 1;
    horde.player.values.set!UNIT_FIELD_FACTIONTEMPLATE(original);
    ally.player.values.set!UNIT_FIELD_FACTIONTEMPLATE(friendly);
    anduin.read();
    auto group = context.groups.newGroup();
    assert(group.addLeaderInvite(ally.player.guid, "Anduin"));
    group.create();
    assert(group.addMember(horde.player.guid, "Thrall"));
    ClientView viewed;
    foreach (packet; anduin.read())
        if (packet.opcode == Opcode.SMSG_UPDATE_OBJECT || packet.opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
            viewed.apply(packet.opcode, packet.body_);
    assert(viewed.fields[horde.player.guid][UNIT_FIELD_FACTIONTEMPLATE] == friendly);
    assert(horde.player.values.get!UNIT_FIELD_FACTIONTEMPLATE == original);
    thrall.write(Opcode.CMSG_TOGGLE_PVP, null);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(horde.player.guid));
    assert(ally.attacking == 0 && ally.enemyPlayer(horde.player.guid) is null);
    group.disband();
    foreach (packet; anduin.read())
        if (packet.opcode == Opcode.SMSG_UPDATE_OBJECT || packet.opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
            viewed.apply(packet.opcode, packet.body_);
    assert(viewed.fields[horde.player.guid][UNIT_FIELD_FACTIONTEMPLATE] == original);
    assert(ally.enemyPlayer(horde.player.guid) is horde);
}

// Healing a flagged player flags the healer, though neither is fighting (it needed the flagged one in combat).
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(2, 0, 0));
    anduin.write(Opcode.CMSG_TOGGLE_PVP, null);
    assert(pvpFlagged(anduin) && !pvpFlagged(jaina) && !anduin.session.inWorld.inCombat);
    jaina.session.inWorld.pvpAssisted(anduin.session.inWorld);
    assert(pvpFlagged(jaina));
}

// Honor (`dmangos.world.honor`): a kill of an enemy player, its credit and the fields; kept over a save.
unittest
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import dmangos.bytes : ByteReader;
    import dmangos.world.honor : HonorType;
    import dmangos.world.pvp : spellHonorlessTarget;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(0, 0, 0), AccountLevel.player, raceOrc, 0, 20);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(2, 0, 0), AccountLevel.player, raceHuman, 0, 20);
    auto orc = thrall.session.inWorld, human = anduin.session.inWorld;
    thrall.read();

    // Level 20 on level 20, no ranks (as rank 1): 24 at 19 by 41/24 a tenth up, 25.3: 25.
    orc.playerKilledByMe(human);
    auto credit = thrall.read().filter!(p => p.opcode == Opcode.SMSG_PVP_CREDIT).array;
    assert(credit.length == 1);
    auto r = ByteReader(credit[0].body_);
    assert(r.read!uint == 25 && r.read!ulong == human.player.guid);
    ref const v = orc.player.values;
    assert((v.get!PLAYER_FIELD_SESSION_KILLS & 0xFFFF) == 1 && v.get!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS == 1);
    assert(v.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 25 && v.get!PLAYER_FIELD_THIS_WEEK_KILLS == 1);

    // The second kill of the same victim the same day is worth a tenth less.
    orc.playerKilledByMe(human);
    r = ByteReader(thrall.read().filter!(p => p.opcode == Opcode.SMSG_PVP_CREDIT).array[0].body_);
    assert(r.read!uint == 22, "90% of 25: 22.5");

    // None for an Honorless Target, one of one's own side, or one grey to the killer.
    if (const spell = context.data.spells.spell(spellHonorlessTarget))
    {
        human.castSpell(spell, SpellTargets(TargetFlags.self, 0), true, 0);
        orc.playerKilledByMe(human);
        assert(!thrall.read().canFind!(p => p.opcode == Opcode.SMSG_PVP_CREDIT), "honorless");
    }
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(4, 0, 0), AccountLevel.player, raceHuman, 0, 20);
    anduin.read();
    human.playerKilledByMe(jaina.session.inWorld);
    assert(!anduin.read().canFind!(p => p.opcode == Opcode.SMSG_PVP_CREDIT), "one's own side");

    // Saved and loaded again: the same.
    orc.saveHonor();
    context.settleWrites();
    assert(db.honorRows[9].points.length == 2 && db.honorRows[9].points[0].type == HonorType.honorable);
    orc.loadHonor();
    assert(orc.player.values.get!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS == 2);
    assert(orc.player.values.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION == 47); // 25 + 22.5
}

// What ranks bring (`dmangos.world.honor`): the rank from rank points, the highest kept, a vendor's
// discount, the halls.
unittest
{
    import dmangos.world.teleport : AreaLockStatus;
    import dmangos.world.worlddata : AreaTriggerTeleport;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto me = anduin.session.inWorld;
    me.honorStored.storedRating = 5000; // rank 7: Sergeant, visual rank 3
    me.updateHonor();
    assert(me.honorRank.rank == 7 && me.honorRank.visualRank == 3);
    assert(me.player.values.getByte!PLAYER_BYTES_3(3) == 7 && me.player.highestHonorRank == 7);
    me.honorStored.storedRating = 1000; // down to Private: the highest stays
    me.updateHonor();
    assert(me.honorRank.rank == 5 && me.player.highestHonorRank == 7);

    // Sergeant (visual 3): 10% off at a vendor friendly to the Alliance (template 11, Stormwind).
    {
        import dmangos.dbc : buildDbc;
        import dmangos.world.clientdata : factionTemplateFormat;

        enum uint players = 1, alliance = 2, monsters = 8;
        const humans = me.player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[humans, 1, 0, players | alliance, alliance, monsters, 0, 0, 0, 0, 0, 0, 0, 0],
            [11u, 11, 0, alliance, alliance, monsters, 0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    }
    me.honorStored.storedRating = 5000;
    me.updateHonor();
    assert(me.reputations.buyPriceDiscount(11) < 0.95f);
    me.honorStored.storedRating = 1000; // Private: no rank discount
    me.updateHonor();
    assert(me.reputations.buyPriceDiscount(11) > 0.95f);

    // The Hall of Champions takes a visual rank of 6.
    AreaTriggerTeleport hall;
    hall.id = 2532;
    hall.targetMap = 0;
    uint requirement;
    const mapEntry = context.client.maps.lookup(0);
    assert(me.lockStatus(hall, mapEntry, requirement) == AreaLockStatus.pvpRank);
    me.honorStored.storedRating = 25_000; // rank 11: visual 7
    me.updateHonor();
    assert(me.lockStatus(hall, mapEntry, requirement) == AreaLockStatus.ok);
}

// Skinning: a looted beast with a skin is skinnable; the skin is its skinner's loot, and then the corpse goes.
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import dmangos.world.creature : Creature;
    import dmangos.world.loot : lootRow, LootStore, LootStores;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.loot = LootStores.create();
    context.data.loot.skinning.add(200, lootRow(itemJerky, 100, 0, 1, 1, 0));
    auto t = context.data.creatureTemplates.edit(creatureInnkeeper);
    t.lootId = 0;
    t.minLootGold = t.maxLootGold = 0;
    t.skinningLootId = 200;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto victim = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    victim.values.set!UNIT_FIELD_LEVEL(1u);
    auto me = anduin.session.inWorld;
    assert(me.checkSkinning(victim.guid) == SpellCastResult.targetNotDead);
    victim.values.set!UNIT_FIELD_HEALTH(0u);
    me.prepareBodyLoot(victim);
    assert(victim.skinnable, "nothing to loot, a skin to take: skinnable at once");
    assert(me.checkSkinning(victim.guid) == SpellCastResult.lowCastLevel, "a level 1 creature asks for skill 1");
    me.player.setSkill(393, 1, 75);
    assert(me.checkSkinning(victim.guid) == SpellCastResult.ok);
    me.skinCreature(victim.guid);
    assert(!victim.skinnable && victim.loot !is null && victim.skinned);
    assert(me.checkSkinning(victim.guid) == SpellCastResult.targetUnskinnable, "once only");
    bool shown;
    foreach (p; anduin.read())
        shown = shown || p.opcode == Opcode.SMSG_LOOT_RESPONSE;
    assert(shown, "the skin, shown as loot");
}

// Pickpocketing: a living creature's pockets, once; emptied, nothing until they fill again.
unittest
{
    import core.time : MonoTime;
    import dmangos.world.creature : Creature;
    import dmangos.world.loot : lootRow, LootStore, LootStores;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.loot = LootStores.create();
    context.data.loot.pickpocketing.add(300, lootRow(itemJerky, 100, 0, 1, 1, 0));
    context.data.creatureTemplates.edit(creatureInnkeeper).pickpocketLootId = 300;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto victim = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto me = anduin.session.inWorld;
    me.pickPocket(victim.guid);
    assert(victim.loot !is null && victim.loot.items.length == 1);
    bool response(ubyte expectedError)
    {
        foreach (p; anduin.read())
            if (p.opcode == Opcode.SMSG_LOOT_RESPONSE)
                return expectedError == 0 ? p.body_.length > 10 : p.body_[9] == expectedError;
        return false;
    }
    assert(response(0), "its pockets, shown");
    victim.loot.lootedForAll(); // all taken
    me.pickPocket(victim.guid);
    assert(response(15), "already picked");
    victim.pocketsRestockAt = context.unixTime - 1;
    me.pickPocket(victim.guid);
    assert(response(0) && !victim.pocketsEmptied, "full again after the restock delay");
}

// A replacement worker can reopen picked pockets and keeps the restock deadline after the last claim.
unittest
{
    import dmangos.world.creature : Creature;
    import dmangos.world.loot : lootRow;
    import dmangos.world.loothandlers : ClientLootSlot;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_LEVEL;

    auto db = newDatabase();
    auto worker(ushort id)
    {
        auto node = newCreationContext(db, (ref config) { config.cluster.nodeId = id; });
        node.next.item = id * 1000;
        node.data.loot.pickpocketing.add(300, lootRow(itemJerky, 100, 0, 1, 1, 0));
        node.data.loot.pickpocketing.add(300, lootRow(itemSword, 100, 0, 1, 1, 0));
        node.data.creatureTemplates.edit(creatureInnkeeper).pickpocketLootId = 300;
        return node;
    }

    const guid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const position = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    auto original = worker(1);
    auto first = loggedIn(original, db, 7, "Anduin", position);
    auto creature = original.map(0).creatureAt(guid);
    creature.values.set!UNIT_FIELD_LEVEL(1u);
    first.session.inWorld.pickPocket(guid);
    assert(creature.loot.gold == 0 && creature.loot.items.length == 2);
    const firstSlot = creature.loot.items[0].slot;
    const remainingSlot = creature.loot.items[1].slot;
    first.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(firstSlot));
    assert(db.itemRows.length == 1 && db.loadPickpocket(0, innkeeperSpawn).restockAt == 0);

    auto replacement = worker(2);
    auto second = loggedIn(replacement, db, 7, "Anduin", position);
    second.session.inWorld.pickPocket(guid);
    auto restored = replacement.map(0).creatureAt(guid);
    assert(restored.loot.items[0].allowed.length == 0 && 7 in restored.loot.items[1].allowed);
    second.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(firstSlot));
    assert(db.itemRows.length == 1);
    second.session.inWorld.pickPocket(guid);
    second.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(remainingSlot));
    assert(db.itemRows.length == 2);
    const restockAt = db.loadPickpocket(0, innkeeperSpawn).restockAt;
    assert(restockAt > replacement.unixTime);

    auto restarted = worker(3);
    auto third = loggedIn(restarted, db, 7, "Anduin", position);
    third.session.inWorld.pickPocket(guid);
    auto emptied = restarted.map(0).creatureAt(guid);
    assert(emptied.pocketsEmptied && emptied.pocketsRestockAt == restockAt);
    emptied.values.set!UNIT_FIELD_HEALTH(0u);
    restarted.map(0).creatureDeath(emptied);
    restarted.update(restarted.clock());
    assert(!db.loadPickpocket(0, innkeeperSpawn).spawn, "a new lifetime starts with fresh pockets");
}

// A random property: a new item gets one of its template's, with the property's enchantment, which counts worn.
unittest
{
    import dmangos.world.enchantments : EnchantmentEffect, EnchantmentType, RandomEnchantment;
    import dmangos.world.movement : Position;
    import dmangos.world.stats : Stat;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.items.edit(itemShirt).randomProperty = 1000;
    context.data.randomProperties[1000] = [RandomEnchantment(55, 100)];
    context.data.propertyEnchantments[55] = [777, 0, 0];
    context.data.enchantmentEffects[777] = [EnchantmentEffect(EnchantmentType.stat, 5, 7), EnchantmentEffect.init,
        EnchantmentEffect.init]; // +5 stamina
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast() anduin.session.character;
    const before = me.stats.stats[Stat.stamina];
    auto shirt = me.inventory.create(itemShirt, 1);
    assert(shirt.values[ITEM_FIELD_RANDOM_PROPERTIES_ID] == 55 && shirt.enchantment(3) == 777, "of the property");
    me.inventory.equip(4, shirt); // the shirt slot (taking the place of what was there)
    me.refreshEquipmentStats(context.data);
    assert(me.stats.stats[Stat.stamina] >= before + 5 - 0.01f, "its enchantment's stamina counts");
}

// Enchanting: a permanent enchantment stays; a temporary one counts while it lasts, then goes.
unittest
{
    import core.time : minutes, seconds;
    import dmangos.world.enchantments : EnchantmentEffect, EnchantmentType;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.stats : Stat;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.enchantmentEffects[900] = [EnchantmentEffect(EnchantmentType.stat, 3, 4), EnchantmentEffect.init,
        EnchantmentEffect.init]; // +3 strength
    context.data.enchantmentEffects[901] = [EnchantmentEffect(EnchantmentType.stat, 2, 7), EnchantmentEffect.init,
        EnchantmentEffect.init]; // +2 stamina
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = anduin.session.inWorld;
    auto shirt = me.player.inventory.create(itemShirt, 1);
    me.player.inventory.equip(4, shirt);
    me.flushInventory();
    const strength = me.player.stats.stats[Stat.strength], stamina = me.player.stats.stats[Stat.stamina];

    me.enchanting.enchantItem(shirt.fullGuid, 900, false, 0);
    assert(shirt.enchantment(0) == 900 && me.player.stats.stats[Stat.strength] == strength + 3, "permanent, counted");
    me.enchanting.enchantItem(shirt.fullGuid, 901, true, 600);
    assert(shirt.enchantment(1) == 901 && me.player.stats.stats[Stat.stamina] == stamina + 2, "temporary, counted");
    bool timeSent;
    foreach (p; anduin.read())
        timeSent = timeSent || p.opcode == Opcode.SMSG_ITEM_ENCHANT_TIME_UPDATE;
    assert(timeSent, "the client is told how long it lasts");
    me.enchanting.updateEnchantments(9.minutes);
    assert(shirt.enchantment(1) == 901 && shirt.values.get!ITEM_FIELD_ENCHANTMENT(4) < 600_000, "running down, saved");
    me.enchanting.updateEnchantments(61.seconds);
    assert(shirt.enchantment(1) == 0 && me.player.stats.stats[Stat.stamina] == stamina, "gone when its time is up");
    assert(shirt.enchantment(0) == 900, "the permanent one stays");
}

// Resurrection sickness: none below level 11; a minute a level from 11, the spell's full time from 20.
unittest
{
    import core.time : minutes;
    import dmangos.world.movement : Position;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.spells.spells[15007] = SpellInfo(15007);
    with (context.data.spells.spells.edit(15007))
    {
        effect[0] = SpellEffect.applyAura;
        casting.applyAuraName[0] = AuraType.dummy; // a dummy aura
        implicitTargetA[0] = ImplicitTarget.caster; // the caster
    }
    uint minutesOf(uint level)
    {
        auto c = loggedIn(context, db, 7 + level, "Sick", Position(-8949.95f, -132.49f, 83.53f),
            AccountLevel.player, 1, 0, level);
        c.read();
        auto me = c.session.inWorld;
        me.applyResurrectionSickness();
        auto aura = me.player.auras.find(15007);
        return aura is null ? 0 : cast(uint)(aura.maxDuration / 60_000);
    }
    assert(minutesOf(10) == 0, "too low to be sick");
    assert(minutesOf(11) == 1 && minutesOf(15) == 5, "a minute a level from 11");
}

// A quest of a game event is given only while the event is on.
unittest
{
    import dmangos.world.gameevents : GameEvent, ScheduleType;
    import dmangos.world.movement : Position;
    import dmangos.world.quests : Quest;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    Quest q;
    q.id = 7000;
    context.data.questGameEvents[7000] = [9];
    const now = context.unixTime;
    context.calendar.gameEvents.events[9] = GameEvent(9, ScheduleType.date, now + 3600, now + 7200, 1440, 60);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = anduin.session.inWorld;
    ushort[] started, stopped;
    context.calendar.gameEvents.update(now, started, stopped);
    assert(!me.questInSeason(q), "out of season");
    context.calendar.gameEvents.events[9].start = now - 60;
    context.calendar.gameEvents.update(now, started, stopped);
    assert(me.questInSeason(q), "in season");
    Quest other;
    other.id = 7001;
    assert(me.questInSeason(other), "a quest of no event is always given");
}

/// Resurrection by another player: the dead are offered it, and accepting brings them back with the spell's share.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8947, -132.49f, 83.53f));
    anduin.read();
    jaina.read();
    auto her = cast(Player) jaina.session.character;
    jaina.session.inWorld.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(her.deathState != DeathState.alive);
    jaina.read();

    enum uint resurrection = 97100;
    context.data.spells.spells[resurrection] = testSpell(resurrection, 18, ImplicitTarget.friend, 35);
    anduin.session.inWorld.castTriggeredAt(resurrection, her.guid);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_RESURRECT_REQUEST), "offered");

    ByteWriter w;
    w.put(anduin.session.character.guid);
    w.put(ubyte(1));
    jaina.write(Opcode.CMSG_RESURRECT_RESPONSE, w.data);
    assert(her.deathState == DeathState.alive, "back");
    const most = her.values.get!UNIT_FIELD_MAXHEALTH;
    assert(her.values.get!UNIT_FIELD_HEALTH == most * 35 / 100, "with a third of its health");
}

/// A Soulstone: dying with its aura, the player is offered its way back, and uses it.
unittest
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellcast : ImplicitTarget;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    enum uint soulstone = 20707, rise = 3026;
    context.data.spells.spells[soulstone] = testSpell(soulstone, 6, ImplicitTarget.caster, 0);
    context.data.spells.spells.edit(soulstone).casting.applyAuraName[0] = AuraType.dummy;
    context.data.spells.spells[rise] = testSpell(rise, 94, ImplicitTarget.caster, 20);
    anduin.session.inWorld.addAura(makeAura(soulstone in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));

    anduin.session.inWorld.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(me.deathState != DeathState.alive && me.values.get!PLAYER_SELF_RES_SPELL == rise, "offered its way back");
    anduin.read();
    anduin.write(Opcode.CMSG_SELF_RES, null);
    assert(me.deathState == DeathState.alive && me.values.get!PLAYER_SELF_RES_SPELL == 0);
    assert(me.values.get!UNIT_FIELD_HEALTH == me.values.get!UNIT_FIELD_MAXHEALTH * 20 / 100, "with a fifth of its health");
}

// The real data's (docs/FORMULAS.md; the other rules' are in `dmangos.world.realrules_world`).
/// Skinning: a creature of level 10 or less asks for skill 1, of level 15 for 50, of level 25 for 125 (5 a level).
unittest
{
    import dmangos.world.realspelltests : haveRealData, RealWorld;
    import dmangos.world.player : Player;
    import dmangos.world.creature : Creature;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.updatefields;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto hunter = w.character(1, "Rexxar", cast(ubyte) 1, 60, []);
    auto me = hunter.session.inWorld;
    auto player = cast(Player) hunter.session.character;
    enum uint mountainBoar = 1190, skinning = 393;
    auto boar = cast(Creature) w.context.map(0).findObject(w.enemy(hunter, mountainBoar));
    assert(boar.template_.skinningLootId, "the boar has a skin");
    boar.values.set!UNIT_FIELD_HEALTH(0u);
    boar.loot = null;
    boar.values.set!UNIT_FIELD_FLAGS(boar.values.get!UNIT_FIELD_FLAGS | Creature.unitFlagSkinnable);
    void needs(uint level, ushort skill)
    {
        boar.values.set!UNIT_FIELD_LEVEL(level);
        player.setSkill(skinning, cast(ushort)(skill - 1), 300);
        assert(me.checkSkinning(boar.guid) == SpellCastResult.lowCastLevel, "one short");
        player.setSkill(skinning, skill, 300);
        assert(me.checkSkinning(boar.guid) == SpellCastResult.ok);
    }
    needs(10, 1);
    needs(15, 50);
    needs(20, 100);
    needs(25, 125);
    needs(60, 300);
}

/// Fishing: a fish that got away raises no skill (in Stormwind, -20 in `skill_fishing_base_level`, skill 1 lands a
/// quarter of its fish).
unittest
{
    import dmangos.world.gameobject : GameObject, GameObjectSpawn;

    import dmangos.world.realspelltests : haveRealData, RealWorld;
    import dmangos.world.player : Player;
    import dmangos.world.creature : Creature;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : SpellCastResult;
    import dmangos.world.updatefields;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    auto angler = w.character(1, "Nat", cast(ubyte) 1, 60, []);
    auto me = angler.session.inWorld;
    auto player = cast(Player) angler.session.character;
    enum uint fishing = 356, bobberEntry = 35591;
    const t = bobberEntry in w.context.data.gameObjectTemplates;
    assert(t !is null, "the fishing bobber");
    auto map = w.context.map(0);
    int escaped, caught;
    foreach (i; 0 .. 60)
    {
        player.setSkill(fishing, 1, 75);
        GameObjectSpawn spawn = {guid: w.context.nextTemporaryCounter(), entry: bobberEntry, map: 0,
            x: player.position.x + 5, y: player.position.y, z: player.position.z, respawnSeconds: -1};
        auto go = new GameObject(spawn, t);
        go.owner = player.guid;
        map.addObject(go);
        me.bobber = go.guid;
        me.bobberAge = me.bobberBite = 0;
        me.bobberGone = 5000;
        me.bobberLooted = false;
        angler.read();
        me.useBobber(go);
        bool gotAway;
        foreach (p; angler.read())
            gotAway = gotAway || p.opcode == Opcode.SMSG_FISH_ESCAPED;
        if (gotAway)
        {
            ++escaped;
            assert(player.skillValue(fishing)[0] == 1, "no skill from a fish that got away");
        }
        else
            ++caught;
        me.removeBobber();
    }
    assert(escaped > 0 && caught > 0, "some of each");
}

/**
 * A two-hander put on by the server with no room for the off hand: the off hand comes off and is mailed to the
 * player (`AutoUnequipOffhandIfNeed`), its row the letter's. (The player's own moves never get there: a two-hander
 * with no room for the off hand is refused first, as CMaNGOS's `CanEquipItem` refuses it.)
 */
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.inventory : ItemRecord;
    import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotOffhand, inventorySlotBag0;
    import dmangos.world.inventory : itemPos;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.player : CharacterData;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.worlddata : ItemTemplate;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint itemBuckler = 2129;
    ItemTemplate buckler = cast() context.data.items[itemShirt];
    buckler.entry = itemBuckler;
    buckler.itemClass = 4;
    buckler.subClass = 6;
    buckler.inventoryType = 14; // a shield
    context.data.items[itemBuckler] = buckler;
    context.data.serverStrings[706] = "This item(s) has problems with equipping/storing to inventory.";
    void setup(ref CharacterData c)
    {
        c.items = [ItemRecord(0, equipmentSlotOffhand, 501, itemBuckler, 0, 0, 1, 0, "", 0, "", 0, 0)];
        foreach (ubyte s; 23 .. 39) // the backpack full
            c.items ~= ItemRecord(0, s, 503 + s, itemHearthstone, 0, 0, 1, 0, "", 0, "", 0, 0);
    }

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 1, &setup);
    anduin.read();
    enum ubyte bag0 = inventorySlotBag0;
    auto me = anduin.session.inWorld;
    auto inventory = me.player.inventory;
    assert(inventory.equipped(equipmentSlotOffhand).guid == 501);

    // A staff put in the main hand: the buckler has no room.
    auto staff = inventory.equipNew(itemPos(bag0, equipmentSlotMainhand), itemStaff);
    inventory.autoUnequipOffhand();
    me.flushInventory();
    anduin.read();
    assert(inventory.equipped(equipmentSlotMainhand) is staff);
    assert(inventory.equipped(equipmentSlotOffhand) is null, "the off hand came off");
    assert(inventory.byGuid(makeGuid(HighGuid.item, 501)) is null && inventory.toMail.length == 0);
    assert(db.mails.length == 1, "a letter");
    const mail = db.mails.byValue.front;
    assert(mail.receiver == 7 && mail.sender == 7 && mail.itemGuid == 501 && mail.itemEntry == itemBuckler);
    assert(mail.subject == "This item(s) has problems with equipping/storing to inventory." && mail.stationery == 61);
    assert(mail.deliverTime <= context.unixTime, "at once");
    assert(!db.looseItem(501).isNull && db.looseItem(501).get.entry == itemBuckler, "its row the letter's");
}

/// Clean moves keep timer progress, chat limits and temporary session settings.
unittest
{
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.player : PlayerFlags, RestType;
    import dmangos.world.testclient : TestPlayerRelay, bodyOf, loggedIn, newCreationContext, newDatabase, say;

    void floodProtection(ref WorldConfig config)
    {
        config.floodLines = 2;
        config.floodSeconds = 20;
        config.floodMessage = true;
    }

    auto db = newDatabase();
    auto first = newCreationContext(db, &floodProtection), second = newCreationContext(db, &floodProtection);
    auto relay = new TestPlayerRelay(first, second);
    auto client = loggedIn(first, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    client.say("One");
    client.say("Two");
    client.read();
    auto previous = client.session.inWorld;
    const floodUntil = previous.floodTime, countedAt = first.unixTime - 6;
    assert(previous.floodLines == 2);
    previous.regenTimer.elapsed = 1500.msecs;
    previous.restTimer.elapsed = 800.msecs;
    previous.zoneTimer.elapsed = 400.msecs;
    previous.player.setRestType(RestType.city, countedAt);
    previous.zoneUpdatePending = true;
    previous.pendingZone = 1519;
    previous.triggerpassCheat = true;
    previous.godModeCheat = true;
    previous.gmTargets[8] = true;
    previous.player.gmTagOn = true; // `.gm on`, `.invisible`
    previous.player.setFlag(PlayerFlags.gm, true);
    previous.player.gmInvisible = true;

    previous.migrateTo(second.nodeId);
    assert(relay.remote !is null && client.session.inWorld is null);
    const current = relay.remote.inWorld;
    assert(current.regenTimer.elapsed == 1500.msecs && current.restTimer.elapsed == 800.msecs);
    assert(current.player.restType == RestType.city && current.player.restCountedAt == countedAt);
    assert(current.zoneTimer.elapsed == 400.msecs && current.zoneUpdatePending && current.pendingZone == 1519);
    assert(current.triggerpassCheat && current.godModeCheat && !current.powerCheat && 8 in current.gmTargets);
    assert(current.player.gmTagOn && current.player.hasFlag(PlayerFlags.gm) && current.player.gmInvisible);
    assert(current.floodLines == 2 && current.floodTime == floodUntil);

    client.read();
    client.say("Three");
    const rejection = bodyOf(client.read(), Opcode.SMSG_MESSAGECHAT);
    assert(canFind(rejection, cast(const(ubyte)[]) "serverside flood protection"));
}

/// A database that does not take the writes stops a move to another node before it does anything: nothing is saved,
/// ended or dismissed, and the player stays, simulated here, until the writes go through.
unittest
{
    import dmangos.world.testclient : TestPlayerRelay, loggedIn, newCreationContext, newDatabase;
    import dmangos.world.writebehind : WriteBehind, Writer;

    auto db = newDatabase();
    auto first = newCreationContext(db), second = newCreationContext(db);
    auto relay = new TestPlayerRelay(first, second);
    auto client = loggedIn(first, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto writer = new Writer(db, null, false); // not started: what is queued waits, as for a database away
    scope (exit)
        writer.stop();
    writer.stalledWaitMs = 0;
    first.writer = writer;
    first.database = new WriteBehind(db, writer, null);
    first.database.setMuteTime(1, 5); // one write waiting
    const queued = writer.statistics.waiting;
    auto staying = client.session.inWorld;

    assert(!staying.migrateTo(second.nodeId), "the writes do not settle: the move does not go on");
    assert(relay.remote is null && client.session.inWorld is staying && staying.player !is null);
    assert(writer.statistics.waiting == queued, "nothing of the move was done: not even its saves were queued");

    writer.start();
    writer.stalledWaitMs = 1_000;
    foreach (_; 0 .. 200)
        if (writer.statistics.waiting)
            imported!"core.thread".Thread.sleep(imported!"core.time".msecs(10));
    assert(staying.migrateTo(second.nodeId), "the database is back: the move goes on");
    assert(relay.remote !is null && client.session.inWorld is null);
}

/// A database read that fails as a player arrives from another node lets the account go, not a half-made session
/// holding it; one that fails once it is in the world sends it away without saving over the records it lacks.
unittest
{
    import dmangos.mysql : DatabaseException;
    import dmangos.world.context : PlayerRelay;
    import dmangos.world.database : AuraRecord, WorldDatabase;
    import dmangos.world.player : CharacterData;
    import dmangos.world.session : WorldSession;
    import dmangos.world.testclient : loggedIn, newCreationContext, newDatabase;
    import std.typecons : AutoImplement, Nullable;

    static final class Capturing : PlayerRelay
    {
        const(ubyte)[] state;
        size_t lefts;
        void toHome(ushort, uint, ushort, const(ubyte)[]) {}
        void toOwner(ushort, uint, ushort, const(ubyte)[]) {}
        void disconnect(ushort, uint) {}
        void migrate(ushort, uint, const(ubyte)[] state) { this.state = state.idup; }
        void left(ushort, uint, bool) { ++lefts; }
        void moved(ushort, uint, ushort) {}
        void remoteDone(uint) {}
    }

    static abstract class Failing : WorldDatabase
    {
        WorldDatabase inner;
        bool character, auras;

        this(WorldDatabase inner) { this.inner = inner; }

        override Nullable!CharacterData loadCharacter(uint guid)
        {
            if (character)
                throw new DatabaseException("Lost connection to server during query");
            return inner.loadCharacter(guid);
        }

        override AuraRecord[] loadAuras(uint player)
        {
            if (auras)
                throw new DatabaseException("Lost connection to server during query");
            return inner.loadAuras(player);
        }
    }

    enum string forward(C, alias method) = "return inner." ~ __traits(identifier, method) ~ "(args);";
    alias Breaking = AutoImplement!(Failing, forward);
    foreach (inWorld; [false, true])
    {
        auto db = newDatabase();
        auto first = newCreationContext(db), second = newCreationContext(db);
        first.nodeId = 1;
        second.nodeId = 2;
        auto relay = new Capturing;
        first.playerRelay = second.playerRelay = relay;
        auto client = loggedIn(first, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
        assert(client.session.inWorld.migrateTo(second.nodeId) && relay.state.length);
        AuraRecord blessing;
        blessing.spell = 1243; // Power Word: Fortitude, saved before the move
        blessing.remaining = -1;
        db.auraRows[7] = [blessing];

        auto failing = new Breaking(db);
        failing.character = !inWorld;
        failing.auras = inWorld;
        second.database = failing;
        auto arriving = new WorldSession(second, Character.migrationAccount(relay.state), first.nodeId);
        if (!inWorld)
        {
            assert(!arriving.arrive(relay.state), "the character could not be read: it does not arrive");
            assert(arriving.inWorld is null);
            continue;
        }
        const lefts = relay.lefts;
        assert(arriving.arrive(relay.state));
        assert(arriving.inWorld is null && relay.lefts == lefts + 1, "in without its auras: it leaves at once");
        assert(db.auraRows[7] == [blessing], "and its saved auras stay as they were");
    }
}
