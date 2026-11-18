/**
 * The administrator-level GM commands that this server's systems support:
 * `.modify level` and `.modify gender`, `.worldport`, `.levelup`, `.playerinfo`,
 * `.revive`, `.paralyze`, the account, ban, unban and kick groups, the server
 * group, `.admin masssummon` and `.admin playall`, the cheat group's status,
 * explore and triggerpass, `.gm whisperblock`, `.gm allowwhispers` and
 * `.gm blockwhispers`, the character group's spell, item and skill commands,
 * the lookups, `.npc info`, and
 * `.character rename`. Their behaviour and messages match ArcEmu 2.4.3's. Mixed into
 * `dmangos.world.character.Character`.
 *
 * The database schema decides a few things:
 * $(UL
 *   $(LI `.account level` takes a permission string; it is stored as the
 *        `account.gmlevel` whose `gm_permissions` string it is (or a level number, 0-3).)
 *   $(LI Bans apply to accounts, not characters, so `.ban character` and `.unban character` ban and
 *        unban the character's account.)
 *   $(LI `ip_banned` holds addresses, not CIDR ranges: a `/32` is dropped, other ranges are kept as
 *        written and match nothing.)
 * )
 */
module dmangos.world.gmlevel3;

/// The spells `.learn all` teaches each class (by class id).
immutable uint[][] classSpells = [
    [],
    [71, 2458, 355, 469, 674, 676, 750, 871, 1161, 1680, 1719, 2048, 2565, 2687, 3411, 5246, 6554, 7620, 11578, 11585,
        12678, 18499, 20230, 23920, 25203, 25208, 25212, 25225, 25231, 25236, 25242, 25264, 25266, 25275, 29704,
        29707, 30357, 34428],
    [750, 1020, 1038, 1044, 1152, 3127, 4987, 5502, 5573, 7620, 10278, 10308, 10322, 10324, 10326, 19746, 19752,
        20271, 20347, 20348, 20356, 20772, 20773, 25780, 25895, 25898, 27136, 27137, 27138, 27139, 27140, 27141,
        27142, 27143, 27144, 27145, 27148, 27149, 27150, 27151, 27152, 27153, 27154, 27155, 27158, 27169, 27173,
        27180, 31789, 31801, 31884, 31895, 32223, 33388, 33391, 33776, 34090, 34091],
    [136, 674, 781, 883, 982, 1002, 1130, 1462, 1494, 1495, 1499, 1510, 1513, 1515, 1543, 1978, 2641, 2643, 2974,
        3018, 3034, 3043, 3044, 3045, 3111, 3127, 3661, 3662, 5116, 5118, 5384, 6197, 6991, 13159, 13161, 13163,
        13165, 13542, 13543, 13544, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 13795, 13809, 13813, 14260,
        14261, 14262, 14263, 14264, 14265, 14266, 14267, 14268, 14269, 14270, 14271, 14272, 14273, 14274, 14279,
        14280, 14281, 14282, 14283, 14284, 14285, 14286, 14287, 14288, 14289, 14290, 14294, 14295, 14302, 14303,
        14304, 14305, 14310, 14311, 14316, 14317, 14318, 14319, 14320, 14321, 14322, 14323, 14324, 14325, 14326,
        14327, 15629, 15630, 15631, 15632, 19801, 19878, 19879, 19880, 19882, 19883, 19884, 19885, 20043, 20190,
        20736, 25294, 25295, 25296, 27014, 27015, 27016, 27018, 27019, 27020, 27021, 27022, 27023, 27025, 27044,
        27045, 27046, 34026, 34074, 34120, 34477, 34600, 36916],
    [674, 921, 1725, 1787, 1804, 1833, 1842, 1860, 2094, 2836, 2842, 3127, 5938, 6774, 8643, 8681, 11297, 11305,
        26669, 26679, 26862, 26863, 26865, 26866, 26867, 26884, 26889, 27441, 27448, 31224, 32684, 38764, 38768],
    [17, 139, 453, 527, 528, 552, 586, 588, 589, 591, 592, 594, 596, 598, 600, 602, 605, 970, 976, 984, 988, 992, 996,
        1004, 1006, 1243, 1244, 1245, 1706, 2006, 2010, 2052, 2053, 2054, 2055, 2060, 2061, 2096, 2767, 2791, 3747,
        6060, 6063, 6064, 6065, 6066, 6074, 6075, 6076, 6077, 6078, 7128, 8092, 8102, 8103, 8104, 8105, 8106, 8122,
        8124, 8129, 8131, 8192, 9472, 9473, 9474, 9484, 9485, 9578, 9579, 9592, 10874, 10875, 10876, 10880, 10881,
        10888, 10890, 10892, 10893, 10894, 10898, 10899, 10900, 10901, 10909, 10911, 10912, 10915, 10916, 10917,
        10927, 10928, 10929, 10933, 10934, 10937, 10938, 10941, 10942, 10945, 10946, 10947, 10951, 10952, 10953,
        10955, 10957, 10960, 10961, 10963, 10964, 10965, 14914, 15261, 15262, 15263, 15264, 15265, 15266, 15267,
        19289, 19291, 19292, 19293, 20770, 25210, 25213, 25217, 25218, 25221, 25222, 25233, 25235, 25308, 25314,
        25315, 25316, 25363, 25364, 25367, 25368, 25372, 25375, 25379, 25380, 25384, 25389, 25429, 25431, 25435,
        25450, 25596, 32375, 32379, 32546, 32996, 33076, 34433, 34863, 34864, 34865, 34866],
    [],
    [131, 324, 325, 332, 370, 421, 526, 529, 546, 547, 548, 556, 905, 913, 915, 930, 939, 943, 945, 959, 1064, 1535,
        2008, 2484, 2645, 2860, 2870, 3599, 5394, 5675, 5730, 6041, 6196, 6363, 6364, 6365, 6375, 6377, 6390, 6391,
        6392, 6495, 8004, 8005, 8008, 8010, 8012, 8017, 8024, 8027, 8030, 8033, 8038, 8042, 8044, 8045, 8046, 8050,
        8052, 8053, 8056, 8058, 8071, 8075, 8134, 8143, 8154, 8155, 8160, 8161, 8166, 8170, 8177, 8181, 8184, 8190,
        8227, 8232, 8235, 8249, 8498, 8499, 8512, 8835, 10391, 10392, 10395, 10396, 10406, 10407, 10408, 10412, 10413,
        10414, 10427, 10428, 10431, 10432, 10437, 10438, 10442, 10447, 10448, 10456, 10462, 10463, 10466, 10467,
        10468, 10472, 10473, 10478, 10479, 10486, 10495, 10496, 10497, 10526, 10537, 10538, 10585, 10595, 10600,
        10601, 10605, 10613, 10622, 10623, 10627, 11314, 11315, 15107, 15111, 15112, 15207, 15208, 16339, 16341,
        16342, 16355, 16356, 16362, 16387, 20608, 20609, 20610, 20776, 20777, 24398, 25357, 25359, 25361, 25391,
        25396, 25420, 25422, 25423, 25439, 25442, 25448, 25449, 25454, 25457, 25464, 25469, 25472, 25489, 25500,
        25505, 25508, 25509, 25525, 25528, 25533, 25546, 25547, 25557, 25560, 25563, 25567, 25570, 25574, 25577,
        25908, 29228, 33736, 36936],
    [10, 66, 116, 118, 120, 122, 130, 143, 145, 205, 475, 543, 587, 597, 604, 759, 837, 865, 990, 1008, 1449, 1459,
        1460, 1461, 1463, 1953, 2120, 2121, 2136, 2137, 2138, 2139, 2855, 2948, 3140, 3552, 5143, 5144, 5145, 5504,
        5505, 5506, 6117, 6127, 6129, 6131, 6141, 6143, 7300, 7301, 7302, 7320, 7322, 8400, 8401, 8402, 8406, 8407,
        8408, 8412, 8413, 8416, 8417, 8422, 8423, 8427, 8437, 8438, 8439, 8444, 8445, 8446, 8450, 8451, 8455, 8457,
        8458, 8461, 8462, 8492, 8494, 8495, 10053, 10054, 10138, 10139, 10140, 10144, 10145, 10148, 10149, 10150,
        10151, 10156, 10157, 10159, 10160, 10161, 10169, 10170, 10173, 10174, 10177, 10179, 10180, 10181, 10185,
        10186, 10187, 10191, 10192, 10193, 10197, 10199, 10201, 10202, 10205, 10206, 10207, 10211, 10212, 10215,
        10216, 10219, 10220, 10223, 10225, 10230, 12051, 12824, 12825, 12826, 22782, 22783, 25304, 25306, 25345,
        27070, 27071, 27072, 27073, 27074, 27075, 27078, 27079, 27080, 27082, 27085, 27086, 27087, 27088, 27101,
        27124, 27125, 27126, 27128, 27130, 27131, 28609, 28612, 30449, 30451, 30455, 30482, 32796, 33717, 33944,
        33946, 37420, 38699],
    [126, 132, 172, 348, 603, 688, 689, 691, 693, 695, 696, 697, 698, 699, 702, 704, 705, 706, 707, 709, 710, 712,
        755, 980, 1010, 1014, 1086, 1088, 1094, 1098, 1106, 1108, 1120, 1122, 1454, 1455, 1456, 1490, 1714, 1949,
        2362, 2941, 3698, 3699, 3700, 5138, 5484, 5500, 5676, 5697, 5699, 5740, 5782, 5784, 6201, 6202, 6205, 6213,
        6215, 6217, 6219, 6222, 6223, 6226, 6229, 6353, 6366, 6789, 7641, 7646, 7648, 7651, 7658, 7659, 8288, 8289,
        11659, 11660, 11661, 11665, 11667, 11668, 11671, 11672, 11675, 11677, 11678, 11683, 11684, 11687, 11688,
        11689, 11693, 11694, 11695, 11699, 11700, 11703, 11704, 11707, 11708, 11711, 11712, 11713, 11717, 11719,
        11721, 11722, 11725, 11726, 11729, 11730, 11733, 11734, 11735, 11739, 11740, 17727, 17728, 17862, 17919,
        17920, 17921, 17922, 17923, 17924, 17925, 17926, 17928, 17937, 18540, 18647, 20752, 20755, 20756, 20757,
        23161, 25307, 25309, 25311, 27209, 27210, 27211, 27212, 27213, 27215, 27216, 27217, 27218, 27219, 27220,
        27221, 27222, 27223, 27224, 27226, 27228, 27229, 27230, 27238, 27243, 27259, 27260, 28172, 28176, 28189,
        28610, 29722, 29858, 29893, 30459, 30545, 30908, 30909, 30910, 32231],
    [],
    [99, 339, 467, 740, 768, 769, 770, 774, 778, 779, 780, 782, 783, 1058, 1062, 1066, 1075, 1079, 1082, 1126, 1178,
        1430, 1735, 1822, 1823, 1824, 1850, 2090, 2091, 2637, 2782, 2893, 2908, 2912, 3025, 3029, 3137, 3627, 5177,
        5178, 5179, 5180, 5186, 5187, 5188, 5189, 5195, 5196, 5201, 5209, 5211, 5215, 5217, 5221, 5225, 5229, 5232,
        5234, 6756, 6778, 6780, 6783, 6785, 6787, 6793, 6795, 6798, 6800, 6807, 6808, 6809, 8903, 8905, 8907, 8910,
        8914, 8918, 8921, 8924, 8925, 8926, 8927, 8928, 8929, 8936, 8938, 8939, 8940, 8941, 8946, 8949, 8950, 8951,
        8955, 8972, 8983, 8992, 8998, 9005, 9490, 9492, 9493, 9634, 9745, 9747, 9749, 9750, 9752, 9754, 9756, 9758,
        9821, 9823, 9827, 9829, 9830, 9833, 9834, 9835, 9839, 9840, 9841, 9845, 9846, 9849, 9850, 9852, 9853, 9856,
        9857, 9858, 9862, 9863, 9866, 9867, 9875, 9876, 9880, 9881, 9884, 9885, 9888, 9889, 9894, 9896, 9898, 9901,
        9904, 9907, 9908, 9910, 9912, 9913, 16914, 16952, 16954, 16958, 16961, 17401, 17402, 18657, 18658, 18960,
        20484, 20719, 20739, 20742, 20747, 20748, 22568, 22570, 22812, 22827, 22828, 22829, 22842, 22895, 22896,
        24248, 25297, 25298, 25299, 26978, 26979, 26980, 26981, 26982, 26983, 26984, 26985, 26986, 26987, 26988,
        26989, 26990, 26992, 26993, 26994, 26995, 26996, 26997, 26998, 26999, 27000, 27001, 27002, 27003, 27005,
        27006, 27008, 27012, 29166, 31018, 33357, 33745, 33763, 33786, 33943, 34090],
];

/// The extra spells `.learn all` teaches a paladin, by race.
immutable uint[][] paladinRaceSpells = [
    [],
    [13819],
    [],
    [13819],
    [],
    [],
    [],
    [],
    [],
    [34769],
    [13819],
];

/// The extra spells `.learn all` teaches a priest, by race.
immutable uint[][] priestRaceSpells = [
    [],
    [13896, 13908, 19236, 19238, 19240, 19241, 19242, 19243, 19271, 19273, 19274, 19275, 25437, 25441],
    [],
    [13908, 19236, 19238, 19240, 44041, 19241, 19242, 19243, 25437, 44043, 44044, 44045, 44046, 44047],
    [2651, 10797, 19296, 19299, 19302, 19303, 19304, 19305, 25446],
    [2652, 2944, 19261, 19262, 19264, 19265, 19266, 19276, 19277, 19278, 19279, 19280, 25461, 25467],
    [],
    [],
    [9035, 18137, 19281, 19282, 19283, 19284, 19285, 19308, 19309, 19310, 19311, 19312, 25470, 25477],
    [2652, 19261, 19262, 19264, 19265, 19266, 25461, 32676],
    [32548, 44041, 44043, 44044, 44045, 44046, 44047],
];

/// The extra spells `.learn all` teaches a shaman, by race.
immutable uint[][] shamanRaceSpells = [
    [],
    [],
    [2825],
    [],
    [],
    [],
    [2825],
    [],
    [2825],
    [],
    [32182],
];

/// The extra spells `.learn all` teaches a mage, by race.
immutable uint[][] mageRaceSpells = [
    [],
    [3561, 3562, 3565, 10059, 11416, 11419, 32266, 32271, 33690, 33691, 49359, 49360],
    [3563, 3566, 3567, 11417, 11418, 11420, 32267, 32272, 35715, 35717, 49358, 49361],
    [3561, 3562, 3565, 10059, 11416, 11419, 32266, 32271, 33690, 33691, 49359, 49360],
    [3561, 3562, 3565, 10059, 11416, 11419, 32266, 32271, 33690, 33691, 49359, 49360],
    [3563, 3566, 3567, 11417, 11418, 11420, 32267, 32272, 35715, 35717, 49358, 49361],
    [3563, 3566, 3567, 11417, 11418, 11420, 32267, 32272, 35715, 35717, 49358, 49361],
    [3561, 3562, 3565, 10059, 11416, 11419, 32266, 32271, 33690, 33691, 49359, 49360],
    [3563, 3566, 3567, 11417, 11418, 11420, 32267, 32272, 35715, 35717, 49358, 49361],
    [3563, 3566, 3567, 11417, 11418, 11420, 32267, 32272, 35715, 35717, 49358, 49361],
    [3561, 3562, 3565, 10059, 11416, 11419, 32266, 32271, 33690, 33691, 49359, 49360],
];

/// See the module documentation.
mixin template Level3Commands()
{
    import core.time : MonoTime, seconds;
    import dmangos.world.database : TicketRecord;
    import std.algorithm.comparison : clamp, min;
    import std.algorithm.searching : canFind, endsWith, findSplitBefore;
    import std.algorithm.sorting : sort;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.string : indexOf;
    import std.uni : sicmp, toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.log;
    import dmangos.world.commands;
    import dmangos.world.context : ShutdownTimer;
    import dmangos.world.database : LookupResult, LookupTable;
    import dmangos.world.defines : exploredZonesSize, PlayerClass;
    import dmangos.world.gmlevel3;
    import dmangos.world.gmtargets : GmRemoteOp;
    import dmangos.world.map : packetBody;
    import dmangos.world.movement : Position;
    import dmangos.world.player : DeathState;
    import dmangos.world.names : normalizedName;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.spells : SpellEffect;
    import dmangos.world.updatefields;

private:
    // -----------------------------------------------------------------------
    // Players
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // `.gmTicket`: answered in the GM channel (`gm_client_channel`), as "GmTicket:<what>:..." lines
    // -----------------------------------------------------------------------

    /// The ticket `id` (closed ones too); false if none.
    private bool ticketById(uint id, out TicketRecord ticket)
    {
        foreach (t; context.database.tickets(true))
            if (t.id == id)
            {
                ticket = t;
                return true;
            }
        return false;
    }

    /// The online session of the ticket's author; null if offline.
    private typeof(this) ticketAuthor(const ref TicketRecord t)
    {
        return cast(typeof(this)) context.onlinePlayer(cast(ulong) t.player);
    }

    /// `.gmTicket list`: every open ticket, a line each, to this GM.
    bool handleGMTicketListCommand(Rest args = Rest.init)
    {
        if (context.config.gmClientChannel.length == 0)
            return false;
        ticketChannelSay("GmTicket:2", false);
        foreach (t; context.database.tickets(false))
        {
            auto plr = ticketAuthor(t);
            string assigned;
            if (const gm = t.id in context.ticketAssignedTo)
            {
                if (auto aplr = cast(typeof(this)) context.onlinePlayer(*gm))
                    assigned = aplr.player.data.name;
                else
                {
                    const info = context.database.nameInfo(cast(uint) *gm);
                    if (!info.isNull)
                        assigned = info.get.name;
                }
            }
            ticketChannelSay(format!"GmTicket:3:%s:%s:%s:%s:%s:%s"(t.id, plr is null ? t.level : plr.player.data.level,
                plr is null ? 0 : 1, assigned, plr is null ? t.name : plr.player.data.name,
                context.ticketComments.get(t.id, "")), false);
        }
        return true;
    }

    /// `.gmTicket get <id>`: the ticket's words, a line each, to this GM.
    bool handleGMTicketGetByIdCommand(Rest args = Rest.init)
    {
        import std.string : split;

        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        // A line for each piece between line ends, empty ones too; none for what follows the last line end if empty.
        const lines = t.text.split('\n');
        foreach (k, line; lines)
        {
            if (k + 1 == lines.length && line.length == 0)
                break;
            ticketChannelSay(format!"GmTicket:%s:%s:%s"(k == 0 ? 4 : 5, t.id, line), false);
        }
        return true;
    }

    /// `.gmTicket remove <id>`: the ticket is closed, the channel told, its author told.
    bool handleGMTicketRemoveByIdCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned != 0 && assigned != player.guid && !canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        auto plr = ticketAuthor(t);
        ticketChannelSay(format!"GmTicket:6:%s"(t.id), true);
        context.database.closeTicket(t.id);
        if (plr !is null)
            plr.ticketRemoved();
        return true;
    }

    /// The player's ticket was removed by a GM.
    package void ticketRemoved()
    {
        ByteWriter w;
        w.put(9u);
        deliver(Opcode.SMSG_GMTICKET_DELETETICKET, w.data);
    }

    /// `.gmTicket assign <id> [name]`: the ticket to a GM online (this one by default).
    bool handleGMTicketAssignToCommand(Rest args = Rest.init)
    {
        import std.array : split;

        const words = args.text.split;
        if (words.length < 1)
            return false;
        const id = cast(uint) leadingNumber(words[0]);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        typeof(this) plr = words.length == 1 ? this : cast(typeof(this)) context.onlinePlayer(words[1]);
        if (plr is null)
        {
            ticketChannelSay("GmTicket:0:Player not found.", false);
            return true;
        }
        if (plr.player is null)
        {
            ticketChannelSay("GmTicket:0:Player isn't online.", false);
            return true;
        }
        if (!plr.hasPermissions)
        {
            ticketChannelSay("GmTicket:0:Player is not a GM.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned == plr.player.guid)
        {
            ticketChannelSay("GmTicket:0:Ticket already assigned to this GM.", false);
            return true;
        }
        if (assigned != 0 && assigned != player.guid)
            if (auto aplr = cast(typeof(this)) context.onlinePlayer(assigned))
                if (aplr.player !is null && !canUseCommand('z'))
                {
                    ticketChannelSay("GmTicket:0:Ticket already assigned to another GM.", false);
                    return true;
                }
        context.ticketAssignedTo[t.id] = plr.player.guid;
        ticketChannelSay(format!"GmTicket:8:%s:%s"(t.id, plr.player.data.name), true);
        return true;
    }

    /// `.gmTicket release <id>`: the ticket no longer assigned.
    bool handleGMTicketReleaseCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned == 0)
        {
            ticketChannelSay("GmTicket:0:Ticket not assigned to a GM.", false);
            return true;
        }
        auto plr = cast(typeof(this)) context.onlinePlayer(assigned);
        if (!canUseCommand('z') && plr !is null && plr.player !is null && plr.canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:You can not release tickets from admins.", false);
            return true;
        }
        context.ticketAssignedTo.remove(t.id);
        ticketChannelSay(format!"GmTicket:9:%s"(t.id), true);
        return true;
    }

    /// `.gmTicket comment <id> [comment]`: the ticket's comment set (none without one).
    bool handleGMTicketCommentCommand(Rest args = Rest.init)
    {
        import std.string : indexOf;

        const space = args.text.indexOf(' ');
        const comment = space < 0 ? "" : args.text[space + 1 .. $];
        const id = cast(uint) leadingNumber(space < 0 ? args.text : args.text[0 .. space]);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned != 0 && assigned != player.guid && !canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        context.ticketComments[t.id] = comment;
        ticketChannelSay(format!"GmTicket:10:%s:%s:%s"(t.id, player.data.name, comment), true);
        return true;
    }

    /// `.gmTicket deletepermanent <id>`: the ticket gone for good (closed first if it was open).
    bool handleGMTicketDeletePermanentCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t))
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        typeof(this) plr;
        if (!t.closed)
        {
            plr = ticketAuthor(t);
            ticketChannelSay(format!"GmTicket:6:%s"(t.id), true);
            context.database.closeTicket(t.id);
        }
        context.database.deleteTicket(t.id);
        context.ticketAssignedTo.remove(t.id);
        context.ticketComments.remove(t.id);
        if (plr !is null)
            plr.ticketRemoved();
        return true;
    }

    /// `.gmTicket toggle`: the ticket system on or off.
    bool handleGMTicketToggleTicketSystemStatusCommand(Rest args = Rest.init)
    {
        context.gmTicketsOn = !context.gmTicketsOn;
        greenSystemMessage(context.gmTicketsOn ? "TicketSystem enabled." : "TicketSystem disabled.");
        return true;
    }

    /// `.pet createpet`: its body does nothing (it was disabled), so the command answers nothing.
    bool handleCreatePetCommand(Rest args = Rest.init)
    {
        return true;
    }

    /// `atol` of a command's argument: its leading digits (after spaces and a sign), 0 if none.
    private static long leadingNumber(string text)
    {
        import std.ascii : isDigit;

        size_t n;
        while (n < text.length && (text[n] == ' ' || text[n] == '\t'))
            ++n;
        bool negative;
        if (n < text.length && (text[n] == '-' || text[n] == '+'))
            negative = text[n++] == '-';
        long value;
        while (n < text.length && text[n].isDigit && value < uint.max)
            value = value * 10 + (text[n++] - '0');
        return negative ? -value : value;
    }

    /// `.pet addspell <spell>`: the selected player's pet learns a spell.
    bool handleAddPetSpellCommand(Rest args = Rest.init)
    {
        return petSpellCommand(args, true);
    }

    /// `.pet removespell <spell>`: the selected player's pet forgets a spell (answered as adding is).
    bool handleRemovePetSpellCommand(Rest args = Rest.init)
    {
        return petSpellCommand(args, false);
    }

    private bool petSpellCommand(string args, bool learns)
    {
        auto plr = getSelectedChar(false);
        if (plr is null)
            return false;
        if (plr.ownPet is null)
        {
            redSystemMessage(format!"%s has no pet."(plr.player.data.name));
            return true;
        }
        const id = cast(uint) leadingNumber(args);
        if (!id || context.data.spells.spell(id) is null)
        {
            redSystemMessage("Invalid spell id requested.");
            return true;
        }
        plr.petLearnsSpell(id, learns);
        greenSystemMessage(format!"Added spell %u to %s's pet."(id, plr.player.data.name));
        return true;
    }

    /// `.pet renamepet <name>`: the player's own pet is renamed.
    bool handleRenamePetCommand(Rest args = Rest.init)
    {
        if (ownPet is null)
        {
            redSystemMessage("You have no pet.");
            return true;
        }
        if (args.length < 1)
        {
            redSystemMessage("You must specify a name.");
            return true;
        }
        greenSystemMessage(format!"Renamed your pet to %s."(args.text));
        renamePetTo(args.text);
        return true;
    }

    bool handleModifyLevelCommand(uint level = 0)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        if (level == 0 || level > context.config.maxPlayerLevel)
        {
            redSystemMessage("A level (numeric) is required to be specified after this command.");
            return true;
        }
        blueSystemMessage(format!"Setting the level of %s to %u."(plr.player.data.name, level));
        plr.greenSystemMessage(format!"%s set your level to %u."(player.data.name, level));
        gmLog(format!"used modify level on %s, level %u"(plr.player.data.name, level));
        plr.applyLevel(level);
        return true;
    }

    bool handleGenderChanger(Nullable!int requested)
    {
        auto found = context.onlinePlayer(player.values.get!UNIT_FIELD_TARGET);
        if (found is null)
        {
            systemMessage("Select A Player first.");
            return true;
        }
        auto target = sessionOf(found);
        auto p = target.player;
        const displayId = p.values.get!UNIT_FIELD_NATIVEDISPLAYID;
        const uint gender = requested.isNull ? p.data.gender == 1 ? 0 : 1 : clamp(requested.get, 0, 1);
        p.data.gender = cast(ubyte) gender;
        p.values.setByte!UNIT_FIELD_BYTES_0(2, cast(ubyte) gender);
        p.values.setHalf!PLAYER_BYTES_3(0, cast(ushort) gender);
        // A race's female model id follows its male one.
        const display = gender == 0 ? displayId - 1 : displayId + 1;
        p.values.set!UNIT_FIELD_DISPLAYID(display);
        p.values.set!UNIT_FIELD_NATIVEDISPLAYID(display);
        target.flushPlayerChanges();
        systemMessage(format!"Set %s's gender to %s(%u)."(p.data.name, gender ? "Female" : "Male", gender));
        return true;
    }

    bool handleWorldPortCommand(uint mapId, float x, float y, float z)
    {
        enum float maxCoord = 17_066.666f; // _maxX, _maxY; _minX, _minY are their negatives
        if (x >= maxCoord || x <= -maxCoord || y <= -maxCoord || y >= maxCoord)
            return false;
        commandTeleport(mapId, Position(x, y, z, 0));
        return true;
    }

    bool handleLevelUpCommand(int levels = 1)
    {
        if (levels <= 0)
            return false;
        auto plr = getSelectedChar(true);
        if (plr is null)
            plr = this;
        gmLog(format!"used level up command on %s, with %u levels"(plr.player.data.name, levels));
        levels += plr.player.data.level;
        if (levels > context.config.maxPlayerLevel)
            levels = context.config.maxPlayerLevel;
        plr.applyLevel(levels);
        plr.systemMessage(format!"You have been leveled up to Level %d"(levels));
        return true;
    }

    /// "[d days, h hours, m minutes, s seconds]", as `HandlePlayerInfo` writes played time.
    static string playedText(uint seconds)
    {
        return format!"[%d days, %d hours, %d minutes, %d seconds]"(seconds / TIME_DAY, seconds / TIME_HOUR % 24,
            seconds / TIME_MINUTE % 60, seconds % 60);
    }

    bool handlePlayerInfo(Rest name = Rest.init)
    {
        Character plr;
        if (name.length >= 2) // char name can be 2 letters
        {
            auto found = context.onlinePlayer(name);
            if (found is null)
            {
                if (!gmElsewhere(name, GmRemoteOp.playerInfo))
                    redSystemMessage(format!"Unable to locate player %s."(name));
                return true;
            }
            plr = sessionOf(found);
        }
        else
            plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.describeTo(gmSink);
        return true;
    }

    bool handleReviveCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        // Resurrected: alive, its corpse gone to bones.
        if (plr.player.deathState != DeathState.alive)
        {
            plr.resurrect(1);
            plr.spawnCorpseBones();
        }
        auto values = &plr.player.values;
        values.set!UNIT_FIELD_HEALTH(values.get!UNIT_FIELD_MAXHEALTH);
        values.set!UNIT_FIELD_POWER1(values.get!UNIT_FIELD_MAXPOWER1);
        values.set!UNIT_FIELD_POWER4(values.get!UNIT_FIELD_MAXPOWER4);
        plr.flushPlayerChanges();
        if (plr !is this)
            gmLog("revived player " ~ plr.player.data.name);
        return true;
    }

    /// The selected player, on this map, or null after "Invalid target.".
    Character selectedPlayerUnit()
    {
        auto plr = cast(Character) map.find(player.values.get!UNIT_FIELD_TARGET);
        if (plr is null)
            redSystemMessage("Invalid target.");
        return plr;
    }

    bool handleParalyzeCommand()
    {
        auto plr = selectedPlayerUnit();
        if (plr is null)
            return true;
        blueSystemMessage("Rooting target.");
        plr.blueSystemMessage(format!"You have been rooted by %s."(player.data.name));
        gmLog("rooted player " ~ plr.player.data.name);
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_ROOT)();
        return true;
    }

    bool handleUnParalyzeCommand()
    {
        auto plr = selectedPlayerUnit();
        if (plr is null)
            return true;
        blueSystemMessage("Unrooting target.");
        plr.blueSystemMessage(format!"You have been unrooted by %s."(player.data.name));
        gmLog("unrooted player " ~ plr.player.data.name);
        plr.sendMovementOrder!(Opcode.SMSG_FORCE_MOVE_UNROOT)();
        return true;
    }

    // -----------------------------------------------------------------------
    // Accounts (sLogonCommHandler.Account_*)
    // -----------------------------------------------------------------------

    /// The connection of the account named `name` (in the world or at the
    /// character screen), in any case, or null.
    WorldSession connectionOfAccountName(string name)
    {
        import dmangos.world.session : WorldSession;

        const found = context.accounts.findAccount(name);
        return found.isNull ? null : cast(WorldSession) context.sessionOfAccount(found.get.id);
    }

    /// ditto: its character, if it is in the world here.
    Character sessionOfAccountName(string name)
    {
        auto connection = connectionOfAccountName(name);
        return connection is null ? null : connection.inWorld;
    }

    /// The `account.gmlevel` a GM permission string stands for: a level number as is, otherwise
    /// the level whose `gm_permissions` string has the same letters. -1 if none has.
    int levelForPermissions(string flags)
    {
        if (flags.length == 1 && flags[0] >= '0' && flags[0] <= '3')
            return flags[0] - '0';
        const letters = loadSecurity(flags);
        foreach (level; 0 .. 4)
            if (context.config.gmPermissions.forLevel(level) == letters)
                return level;
        return -1;
    }

    bool handleAccountLevelCommand(string account, string gmlevel)
    {
        const level = levelForPermissions(gmlevel);
        if (level < 0)
        {
            redSystemMessage(format!"No account level has the permissions '%s' (see gm_permissions)."(gmlevel));
            return true;
        }
        if (!context.accounts.findAccount(account).isNull)
        {
            context.accounts.setLevel(account, cast(AccountLevel) level);
            if (auto session = sessionOfAccountName(account))
                session.account.level = cast(AccountLevel) level;
        }
        greenSystemMessage(format!("Account '%s' level has been updated to '%s'. The change will be effective "
            ~ "immediately.")(account, gmlevel));
        gmLog(format!"set account %s flags to %s"(account, gmlevel));
        return true;
    }

    bool handleAccountMuteCommand(string name, string duration)
    {
        const period = getTimePeriodFromString(duration);
        if (period <= 0)
            return false;
        const until = context.unixTime + period;
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.database.setMuteTime(found.get.id, until);
        const text = convertTimeStampToDataTime(until);
        greenSystemMessage(format!"Account '%s' has been muted until %s. The change will be effective immediately."(
            name, text));
        gmLog(format!"mutex account %s until %s"(name, text));
        if (auto session = sessionOfAccountName(name))
        {
            session.account.muteTime = until;
            session.systemMessage(format!("Your voice has been muted until %s by a GM. Until this time, you will not "
                ~ "be able to speak in any form.")(text));
        }
        return true;
    }

    bool handleAccountUnmuteCommand(string name)
    {
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.database.setMuteTime(found.get.id, 0);
        greenSystemMessage(format!"Account '%s' has been unmuted."(name));
        gmLog("unmuted account " ~ name);
        if (auto session = sessionOfAccountName(name))
        {
            session.account.muteTime = 0;
            session.systemMessage("Your voice has restored. You may speak again.");
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Disconnecting
    // -----------------------------------------------------------------------

    /// The message sent for each session a disconnect command closes, then the close.
    void disconnect(imported!"dmangos.world.session".WorldSession connection)
    {
        // "Disconnecting user with ...": an account at its character screen too.
        const name = connection.character is null ? "noplayer" : connection.character.data.name;
        gmSink.system(format!"Disconnecting user with account `%s` IP `%s` Player `%s`."(connection.account.username,
            connection.address, name));
        connection.kick(format!"disconnected by %s"(player.data.name));
    }

    /// Disconnects every session from `ip`.
    void disconnectUsersWithIP(string ip)
    {
        auto sessions = context.sessionsFrom(ip);
        foreach (session; sessions)
            if (auto connection = cast(imported!"dmangos.world.session".WorldSession) session)
                disconnect(connection);
        if (sessions.length == 0)
            systemMessage(format!"There is nobody online with ip [%s]"(ip));
    }

    /// Disconnects the session of the account named `account`.
    void disconnectUsersWithAccount(string account)
    {
        if (auto connection = connectionOfAccountName(account))
            disconnect(connection);
        else
            systemMessage(format!"There is nobody online with account [%s]"(account));
    }

    bool handleKillByPlayerCommand(Rest name = Rest.init)
    {
        if (name.length < 2)
        {
            redSystemMessage("A player's name is required.");
            return true;
        }
        // Disconnects the player's session. "There is no body online" is said only when nobody was found.
        if (auto found = context.onlinePlayer(name))
            disconnect(sessionOf(found).connection);
        else if (gmElsewhere(name, GmRemoteOp.disconnect))
        {
        }
        else
            systemMessage(format!"There is no body online with the name [%s]"(name));
        gmLog("disconnected player " ~ name);
        return true;
    }

    bool handleKillBySessionCommand(Rest account = Rest.init)
    {
        if (account.length < 2)
        {
            redSystemMessage("A player's name is required.");
            return true;
        }
        disconnectUsersWithAccount(account);
        gmLog("disconnected player with account " ~ account);
        return true;
    }

    bool handleKillByIPCommand(Rest ip = Rest.init)
    {
        if (ip.length < 2)
        {
            redSystemMessage("An IP is required.");
            return true;
        }
        disconnectUsersWithIP(ip);
        gmLog("disconnected players with IP " ~ ip);
        return true;
    }

    // -----------------------------------------------------------------------
    // Bans
    // -----------------------------------------------------------------------

    bool handleIPBanCommand(string ip, string duration, Rest reason = Rest.init)
    {
        const period = getTimePeriodFromString(duration);
        if (period < 1)
            return false;
        if (!isIPv4Address(ip.findSplitBefore("/")[0]))
        {
            redSystemMessage(format!"Invalid IPv4 address [%s]"(ip));
            return true;
        }
        const expireTime = context.unixTime + period;
        if (!ip.canFind('/'))
        {
            redSystemMessage("Lack of CIDR address assumes a 32bit match (if you don't understand, dont worry, it "
                ~ "worked)");
            ip ~= "/32";
        }
        systemMessage(format!"Adding [%s] to IP ban table, expires %s.Reason is :%s"(ip, ctimeString(expireTime),
            reason));
        const address = ip[0 .. ip.indexOf('/')];
        context.accounts.banIp(ip.endsWith("/32") ? address : ip, period, player.data.name, reason);
        disconnectUsersWithIP(address);
        gmLog(format!"banned ip address %s, expires %s"(ip, ctimeString(expireTime)));
        return true;
    }

    bool handleBanCharacterCommand(string name, string duration, Rest reason)
    {
        const banTime = getTimePeriodFromString(duration);
        if (banTime < 1)
            return false;

        auto online = context.onlinePlayer(name);
        const elsewhere = online is null ? context.remotePlayer(name) : null;
        uint accountId;
        if (elsewhere !is null)
        {
            accountId = elsewhere.entry.account;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        else if (online is null)
        {
            const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
            if (owner.isNull)
            {
                systemMessage("Player not found.");
                return true;
            }
            accountId = owner.get.account;
            systemMessage(format!"Banning player '%s' in database for '%s'."(name, reason));
        }
        else
        {
            accountId = sessionOf(online).account.id;
            systemMessage(format!"Banning player '%s' ingame for '%s'."(name, reason));
        }
        // Bans apply to accounts: the character's account is banned.
        context.accounts.banAccount(accountId, banTime, player.data.name, reason);
        systemMessage(format!"This ban is due to expire %s%s."("on ",
            convertTimeStampToDataTime(context.unixTime + banTime)));
        if (online !is null)
            sessionOf(online).bannedBy(gmSink, player.data.name);
        else if (elsewhere !is null)
            gmElsewhere(name, GmRemoteOp.banKick);
        gmLog(format!"banned %s, reason %s, for %s"(name, reason, convertTimeStampToString(banTime)));
        const message = format!"%sGM: %s has been banned by %s for %s. Reason: %s"(MSG_COLOR_RED, name,
            player.data.name, convertTimeStampToString(banTime), reason);
        sendWorldText(message.length > 199 ? message[0 .. 199] : message);
        return true;
    }

    bool handleAccountBannedCommand(string name, string duration, Rest reason = Rest.init)
    {
        const period = getTimePeriodFromString(duration);
        if (period < 0)
            return false;
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.accounts.banAccount(found.get.id, period, player.data.name, reason); // 0: for ever
        const until = period ? convertTimeStampToDataTime(context.unixTime + period) : "";
        greenSystemMessage(format!("Account '%s' has been banned %s%s for reason : %s. The change will be effective "
            ~ "immediately.")(name, period ? "until " : "forever", until, reason));
        disconnectUsersWithAccount(name);
        gmLog(format!"banned account %s until %s"(name, period ? until : "permanant"));
        return true;
    }

    bool handleIPUnBanCommand(string ip)
    {
        if (!ip.canFind('/'))
        {
            redSystemMessage("Lack of CIDR address assumes a 32bit match (if you don't understand, dont worry, it "
                ~ "worked)");
            ip ~= "/32";
        }
        systemMessage(format!"Deleting [%s] from ip ban table if it exists"(ip));
        context.accounts.unbanIp(ip.endsWith("/32") ? ip[0 .. $ - 3] : ip);
        gmLog("unbanned ip address " ~ ip);
        return true;
    }

    bool handleUnBanCharacterCommand(string name)
    {
        if (auto online = context.onlinePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(online.character.data.name));
        else if (const remote = context.remotePlayer(name))
            greenSystemMessage(format!"Unbanned player %s ingame."(remote.entry.name));
        else
            greenSystemMessage(format!"Player %s not found ingame."(name));
        const owner = context.database.characterOwner(context.database.characterGuid(normalizedName(name)));
        if (!owner.isNull)
            context.accounts.unbanAccount(owner.get.account, player.data.name);
        systemMessage(format!"Unbanned character %s in database."(name));
        gmLog("unbanned " ~ name);
        return true;
    }

    bool handleAccountUnbanCommand(string name)
    {
        const found = context.accounts.findAccount(name);
        if (!found.isNull)
            context.accounts.unbanAccount(found.get.id, player.data.name);
        greenSystemMessage(format!"Account '%s' has been unbanned. This change will be effective immediately."(name));
        gmLog("unbanned account " ~ name);
        return true;
    }

    // -----------------------------------------------------------------------
    // The server
    // -----------------------------------------------------------------------

    bool handleSetMotdCommand(Rest motd = Rest.init)
    {
        if (motd.length < 2)
        {
            redSystemMessage("You must specify a message.");
            return true;
        }
        greenSystemMessage("Motd has been set to: " ~ motd);
        context.config.motd = motd;
        gmLog("Set MOTD to " ~ motd);
        return true;
    }

    bool handleRehashCommand()
    {
        import dmangos.world.config : loadWorldConfig;

        const message = format!"%s is rehashing config file."(player.data.name);
        sendWorldWideScreenText(message);
        sendWorldText(message);
        if (context.configPath.length)
        {
            try
            {
                // Settings read when the server starts (databases, port, ...) keep their values until a restart.
                context.config = loadWorldConfig(context.configPath);
                context.loadCommandOverrides();
                info!"configuration %s read again"(context.configPath);
            }
            catch (Exception e)
                error!"cannot read the configuration again: %s"(e.msg);
        }
        return true;
    }

    bool handleDBReloadCommand(string table)
    {
        context.settleWrites(); // what the GM commands wrote (spawns, vendors, ...) is read back
        if (table.length < 3)
            return false;
        const started = MonoTime.currTime;
        sendWorldText(format!("%s%s initiated server-side reload of table `%s`. The server may experience some lag "
            ~ "while this occurs.")(MSG_COLOR_LIGHTRED, player.data.name, table));
        bool reloaded;
        // The tables this server keeps in memory and can read again.
        if (sicmp(table, "areatrigger_teleport") == 0 || sicmp(table, "game_tele") == 0)
        {
            context.data.setTeleports(context.database.loadAreaTriggerTeleports(), context.database.loadTeleports(),
                context.client);
            reloaded = true;
        }
        if (!reloaded)
            sendWorldText(MSG_COLOR_LIGHTRED ~ "Database reload failed.");
        else
            sendWorldText(format!"%sDatabase reload completed in %u ms."(MSG_COLOR_LIGHTBLUE,
                (MonoTime.currTime - started).total!"msecs"));
        gmLog("reloaded table " ~ table);
        return true;
    }

    /// Starts a shutdown or restart `delay` seconds away; the world update announces it as it counts down.
    void startShutdown(uint delay, bool restart)
    {
        ShutdownTimer timer;
        timer.at = context.clock() + delay.seconds;
        timer.restart = restart;
        context.shutdown = timer;
        warning!"'%s' ordered a %s in %s seconds"(player.data.name, restart ? "restart" : "shutdown", delay);
    }

    bool handleShutdownCommand(uint delay = 5)
    {
        // A bare `.server shutdown` waits the 5 seconds its help promises.
        sendWorldText(format!"%sServer shutdown initiated by %s, shutting down in %u seconds."(MSG_COLOR_LIGHTBLUE,
            player.data.name, delay));
        gmLog(format!"initiated server shutdown timer %u sec"(delay));
        startShutdown(delay, false);
        return true;
    }

    bool handleShutdownRestartCommand(uint delay = 5)
    {
        sendWorldText(format!"%sServer restart initiated by %s, shutting down in %u seconds."(MSG_COLOR_LIGHTBLUE,
            player.data.name, delay));
        gmLog(format!"initiated server restart timer %u sec"(delay));
        startShutdown(delay, true);
        return true;
    }

    bool handleCancelShutdownCommand()
    {
        if (context.shutdown.isNull)
            return false;
        sendWorldText(format!"%sServer %s cancelled by %s."(MSG_COLOR_LIGHTBLUE,
            context.shutdown.get.restart ? "Restart" : "Shutdown", player.data.name));
        context.shutdown.nullify();
        return true;
    }

    // -----------------------------------------------------------------------
    // The admin group
    // -----------------------------------------------------------------------

    /// A summon offered with `SMSG_SUMMON_REQUEST`, and when it lapses.
    struct SummonOffer
    {
        uint map;
        Position position;
        MonoTime expires;
    }

    SummonOffer summonOffer;
    bool hasSummonOffer;

    bool handleMassSummonCommand()
    {
        uint count;
        foreach (other; context.onlinePlayers)
        {
            sessionOf(other).summonRequest(player.guid, player.data.zone, player.data.map, player.position);
            ++count;
        }
        // Every other node of a cluster asks its own.
        if (gmEverywhere(GmRemoteOp.massSummon, format!"%u"(player.data.zone)))
            count += cast(uint) context.remotePlayers.length;
        gmLog(format!"requested a mass summon of %u players."(count));
        return true;
    }

    /// Offers the player a summon; it has two minutes to accept.
    void summonRequest(ulong summoner, uint zone, uint mapId, Position at)
    {
        summonOffer = SummonOffer(mapId, at, context.clock() + 120.seconds);
        hasSummonOffer = true;
        send(ServerSummonRequest(summoner, zone, 120_000));
    }

    /// The player answered a summon offer.
    @Handles(Opcode.CMSG_SUMMON_RESPONSE, WorldState.inWorld)
    void handleSummonResponse(const ClientSummonResponse)
    {
        if (!hasSummonOffer || context.clock() > summonOffer.expires)
            return;
        hasSummonOffer = false;
        commandTeleport(summonOffer.map, summonOffer.position);
    }

    bool handleGlobalPlaySoundCommand(uint sound)
    {
        if (sound == 0)
            return false;
        toEveryone(Opcode.SMSG_PLAY_SOUND, packetBody(ServerPlaySound(sound)));
        blueSystemMessage(format!"Broadcasted sound %u to server."(sound));
        gmLog(format!"used play all command soundid %u"(sound));
        return true;
    }

    // -----------------------------------------------------------------------
    // Cheats
    // -----------------------------------------------------------------------

    bool handleShowCheatsCommand()
    {
        auto plyr = getSelectedChar(true);
        if (plyr is null)
            return true;
        uint active, inactive;
        void status(string name, bool on)
        {
            systemMessage(format!"%s%s: %s%s"(MSG_COLOR_LIGHTBLUE, name, on ? MSG_COLOR_LIGHTRED : MSG_COLOR_GREEN,
                on ? "Active" : "Inactive"));
            if (on)
                ++active;
            else
                ++inactive;
        }

        greenSystemMessage("Showing cheat status for: " ~ plyr.player.data.name);
        // Flying and stacking auras do not exist yet: never on.
        status("Cooldown", plyr.cooldownCheat);
        status("CastTime", plyr.castTimeCheat);
        status("GodMode", plyr.godModeCheat);
        status("Power", plyr.powerCheat);
        status("Fly", false);
        status("AuraStack", false);
        status("TriggerPass", plyr.triggerpassCheat);
        systemMessage(format!"%u cheats active, %u inactive."(active, inactive));
        return true;
    }

    bool handleTaxiCheatCommand(OnOff state)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
            return true;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            greenSystemMessage(format!"%s has all taxi nodes now."(chr.player.data.name));
            chr.systemMessage(format!"%s has given you all taxi nodes."(player.data.name));
        }
        else
        {
            greenSystemMessage(format!"%s has no more taxi nodes now."(chr.player.data.name));
            chr.systemMessage(format!"%s has deleted all your taxi nodes."(player.data.name));
        }
        chr.player.data.taxiMask[] = state == OnOff.on ? uint.max : 0u;
        return true;
    }

    bool handleExploreCheatCommand(OnOff state)
    {
        auto chr = getSelectedChar(true);
        if (chr is null)
        {
            chr = this;
            systemMessage("Auto-targeting self.");
        }
        const name = chr.player.data.name;
        // The first message goes to the GM, the second to the player it is meant for.
        if (state == OnOff.on)
        {
            systemMessage(format!"%s has explored all zones now."(name));
            chr.systemMessage(format!"%s has explored all zones for you."(player.data.name));
            gmLog("explored all zones for player " ~ name);
        }
        else
        {
            systemMessage(format!"%s has no more explored zones."(name));
            chr.systemMessage(format!"%s has hidden all zones from you."(player.data.name));
            gmLog("hid all zones for player " ~ name);
        }
        foreach (i; 0 .. exploredZonesSize)
            chr.player.values.set!PLAYER_EXPLORED_ZONES_1(i, state == OnOff.on ? uint.max : 0u);
        chr.flushPlayerChanges();
        return true;
    }

    /**
     * The shape of the cheat toggles: on, off, or (with nothing said) the other way; the GM and
     * the player told, and the GM log when it goes off for another.
     */
    bool toggleCheat(Nullable!OnOff state, string name, string logLine, bool* delegate(Character) flag,
        void delegate(Character) whenOn = null)
    {
        auto plyr = getSelectedChar(true);
        if (plyr is null)
            return true;
        auto on = flag(plyr);
        if (state.isNull)
            state = *on ? OnOff.off : OnOff.on;
        if (state.get == OnOff.on)
        {
            *on = true;
            if (whenOn !is null)
                whenOn(plyr);
            blueSystemMessage(format!"activated the %s cheat on %s."(name, plyr.player.data.name));
            plyr.greenSystemMessage(format!"activated the %s cheat on you."(name));
        }
        else
        {
            *on = false;
            blueSystemMessage(format!"deactivated the %s cheat on %s."(name, plyr.player.data.name));
            plyr.greenSystemMessage(format!"deactivated the %s cheat on you."(name));
            if (plyr !is this)
                gmLog(format!"%s on %s set to %s"(logLine, plyr.player.data.name, state.get));
        }
        return true;
    }

    bool handleCastTimeCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "cast time", "god cast time", (Character p) => &p.castTimeCheat);
    }

    bool handleCooldownCheatCommand(Nullable!OnOff state)
    {
        // On, every spell known has its cooldown cleared.
        return toggleCheat(state, "cooldown", "cooldown cheat", (Character p) => &p.cooldownCheat,
            (Character p) {
                foreach (spell; p.player.spells)
                    p.clearCooldownFor(spell);
            });
    }

    bool handleGodModeCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "god mode", "god mode cheat", (Character p) => &p.godModeCheat);
    }

    bool handlePowerCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "power", "power cheat", (Character p) => &p.powerCheat);
    }

    bool handleTriggerpassCheatCommand(Nullable!OnOff state)
    {
        return toggleCheat(state, "triggerpass", "triggerpass cheat", (Character p) => &p.triggerpassCheat);
    }

    // -----------------------------------------------------------------------
    // Cooldowns, auras, talents (`HandleClearCooldownsCommand`, `HandleRemoveAurasCommand`, ...)
    // -----------------------------------------------------------------------

    bool handleClearCooldownsCommand()
    {
        const guid = cast(uint) player.values.get!UNIT_FIELD_TARGET;
        auto plr = getSelectedChar(true);
        if (plr is null)
        {
            plr = this;
            systemMessage("Auto-targeting self.");
        }
        if (plr !is this)
            gmLog("Cleared all cooldowns for player " ~ plr.player.data.name);
        // The class's three skill lines (the skill lines of its talent trees), and its name.
        static immutable uint[3][12] lines = [[0, 0, 0], [26, 256, 257], [594, 267, 184], [50, 51, 163],
            [253, 38, 39], [56, 78, 613], [0, 0, 0], [373, 374, 375], [6, 8, 237], [355, 354, 593], [0, 0, 0],
            [573, 574, 134]];
        static immutable string[12] names = ["", "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "", "Shaman",
            "Mage", "Warlock", "", "Druid"];
        const classId = plr.player.data.classId;
        if (classId >= names.length || names[classId].length == 0)
            return true;
        foreach (line; lines[classId])
            plr.clearCooldownsOnLine(line, guid);
        blueSystemMessage(format!"Cleared all %s cooldowns."(names[classId]));
        return true;
    }

    bool handleRemoveAurasCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        blueSystemMessage("Removing all auras...");
        // The removable slots: every aura but the passive ones.
        foreach (aura; plr.player.auras.list.dup)
            if (!aura.passive)
                plr.removeAura(aura);
        if (plr !is this)
            gmLog(format!"Removed all of %s's auras."(plr.player.data.name));
        return true;
    }

    bool handleResetTalentsCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        plr.resetTalents();
        systemMessage(format!"Reset talents of %s."(plr.player.data.name));
        plr.blueSystemMessage(format!"%s reset all your talents."(player.data.name));
        gmLog("reset talents of " ~ plr.player.data.name);
        return true;
    }

    bool handleDispelAllCommand(Rest args = Rest.init)
    {
        import std.ascii : isDigit;

        // `atoi`: any number but 0 also takes the positive auras.
        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        const pos = n ? args[0 .. n].to!uint : 0;
        gmLog(format!"used dispelall command, pos %u"(pos));
        // The players of this node (those on another node of a cluster keep theirs).
        foreach (other; context.onlinePlayers)
            sessionOf(other).dispelAll(pos != 0);
        gmLog("used mass dispel");
        blueSystemMessage("Dispel action done.");
        return true;
    }

    import dmangos.world.playercreate : NewCharacter;

    bool handleIncreaseWeaponSkill(uint cnt = 1)
    {
        import std.algorithm.comparison : min;
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotRanged;

        auto pr = getSelectedChar(true);
        if (pr is null)
            pr = this;
        auto it = pr.player.inventory.equipped(equipmentSlotMainhand);
        if (it is null)
            it = pr.player.inventory.equipped(equipmentSlotRanged);
        uint skill;
        if (it !is null && it.proto !is null)
        {
            // Weapon subclasses to skill lines, oddities included (exotic ones count as staves).
            static immutable uint[21] bySubClass = [44, 172, 45, 46, 54, 160, 229, 43, 55, 136, 136, 0, 473, 0, 0,
                173, 176, 227, 226, 228, 356];
            if (it.proto.subClass < bySubClass.length)
                skill = bySubClass[it.proto.subClass];
        }
        else
            skill = 162; // unarmed
        if (skill == 0)
        {
            redSystemMessage("Can't find skill ID :-/");
            return false;
        }
        blueSystemMessage(format!"Modifying skill line %d. Advancing %d times."(skill, cnt));
        gmLog(format!"increased weapon skill (%u) of %s by %u"(skill, pr.player.data.name, cnt));
        const now = pr.player.skillValue(skill);
        if (now[1] == 0)
        {
            systemMessage("Does not have skill line, adding.");
            pr.applySkill(skill, 1, 300);
        }
        else // `_AdvanceSkillLine`: up to the maximum
            pr.applySkill(skill, cast(ushort) min(now[0] + cnt, now[1]), now[1]);
        return true;
    }

    /// What a new character of `plr`'s race, class and gender starts with, as character creation gives it.
    package static bool startingAbilities(typeof(this) plr, out NewCharacter fresh)
    {
        import dmangos.auth.accounts : AccountLevel;
        import dmangos.world.playercreate : CharacterBuilder, CreateRequest;

        auto builder = new CharacterBuilder(plr.context.data, plr.context.client, plr.context.creationSettings,
            () => 0u);
        CreateRequest request = {name: plr.player.data.name, race: plr.player.data.race,
            classId: plr.player.data.classId, gender: plr.player.data.gender};
        return builder.create(0, 0, AccountLevel.player, request, true, fresh);
    }

    bool handleResetSpellsCommand()
    {
        import std.algorithm.searching : canFind;

        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        // Back to the spells a new character of its race and class has.
        NewCharacter fresh;
        if (startingAbilities(plr, fresh))
        {
            foreach (spell; plr.player.spells.dup)
                if (!fresh.spells.canFind!(s => s.spell == spell))
                    plr.unlearn(spell);
            foreach (s; fresh.spells)
                if (s.active && !s.disabled)
                    plr.learn(s.spell);
        }
        systemMessage(format!"Reset spells of %s to level 1."(plr.player.data.name));
        plr.blueSystemMessage(format!"%s reset all your spells to starting values."(player.data.name));
        gmLog(format!"reset spells of %s"(plr.player.data.name));
        return true;
    }

    bool handleResetSkillsCommand()
    {
        import std.algorithm.searching : canFind;

        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        NewCharacter fresh;
        if (!startingAbilities(plr, fresh))
            return true;
        // `_RemoveAllSkills`, then the create info's skills and the languages, the level's caps.
        foreach (skill; plr.player.skillList())
            if (!fresh.skills.canFind!(s => s.skill == skill[0]))
                plr.applySkill(skill[0], 0, 0);
        foreach (s; fresh.skills)
            plr.applySkill(s.skill, cast(ushort) s.value, cast(ushort) s.max);
        plr.player.updateSkillsForLevel(context.client);
        foreach (skill; plr.player.skillList())
            plr.applySkill(skill[0], cast(ushort) skill[1], cast(ushort) skill[2]); // saved with the new caps
        blueSystemMessage("Reset skills to default.");
        gmLog(format!"reset skills of %s to default"(plr.player.data.name));
        return true;
    }

    /// `.fixscale <scale>`: the selected creature's size, and its template's, kept.
    bool handleFixScaleCommand(float sc = 0)
    {
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        auto creature = getSelectedCreature(true);
        if (creature is null)
            return true;
        if (sc < 0.1f)
            return false;
        creature.values.set!OBJECT_FIELD_SCALE_X(sc);
        map.flushObjectChanges(creature);
        const entry = creature.spawn.entry;
        if (auto t = context.data.creatureTemplates.edit(entry))
            t.scale = sc;
        context.database.updateCreatureScale(entry, sc);
        return true;
    }

    bool handleRemoveRessurectionSickessAuraCommand()
    {
        enum uint resurrectionSickness = 15007;
        auto plr = getSelectedChar(true);
        if (plr is null)
            return false;
        blueSystemMessage("Removing ressurection sickness...");
        if (auto aura = plr.player.auras.find(resurrectionSickness))
            plr.removeAura(aura);
        if (plr !is this)
            gmLog(format!"Removed resurrection sickness from %s"(plr.player.data.name));
        return true;
    }

    bool handleCastAllCommand(Rest args = Rest.init)
    {
        import std.ascii : isDigit;

        if (args.length < 2)
        {
            redSystemMessage("No spellid specified.");
            return true;
        }
        // `atol`
        size_t n;
        while (n < args.length && n < 9 && args[n].isDigit)
            ++n;
        const spellId = n ? args[0 .. n].to!uint : 0;
        const spell = context.data.spells.spell(spellId);
        if (spell is null)
        {
            redSystemMessage("Invalid spell specified.");
            return true;
        }
        enum uint learnSpell = 36; // SPELL_EFFECT_LEARN_SPELL: not on everybody
        foreach (i; 0 .. 3)
            if (spell.effect[i] == learnSpell)
            {
                gmLog(format!"used wrong / learnall castall command, spellid %u"(spellId));
                redSystemMessage("Learn spell specified.");
                return true;
            }
        gmLog(format!"used castall command, spellid %u"(spellId));
        // The players of this node in the world, each casting it on itself, triggered.
        foreach (other; context.onlinePlayers)
        {
            auto who = sessionOf(other);
            if (who.player !is null && !who.transferring)
                who.castTriggeredAt(spellId, who.player.guid);
        }
        blueSystemMessage(format!"Casted spell %u on all players!"(spellId));
        return true;
    }

    bool handleCreatureRespawnCommand()
    {
        auto corpse = getSelectedCreature(false);
        if (corpse !is null && !corpse.alive && corpse.spawn.guid != 0)
        {
            const line = format!"Respawning a Creature: `%s` with entry: %u on map: %u sqlid: %u"(corpse.template_.name,
                corpse.spawn.entry, map.id, corpse.spawn.guid);
            blueSystemMessage(line);
            gmLog("Respawned" ~ line[10 .. $]);
            // The corpse goes now, the creature comes back a second later.
            context.respawnSoon(corpse, map);
            return true;
        }
        redSystemMessage("You must select a creature's corpse with a valid CreatureSpawn point.");
        return false;
    }

    // -----------------------------------------------------------------------
    // Whispers to a GM with the tag on
    // -----------------------------------------------------------------------

    bool handleWhisperBlockCommand()
    {
        // The GM tag without the <GM> flag: players' whispers get the automatic reply.
        if (player.gmTagOn)
            return false;
        player.gmTagOn = true;
        return true;
    }

    bool handleAllowWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (auto plr = context.onlinePlayer(name))
        {
            guid = plr.character.guid;
            found = plr.character.data.name;
        }
        else if (const remote = context.remotePlayer(name)) // another node's player
        {
            guid = remote.entry.guid;
            found = remote.entry.name;
        }
        else
        {
            redSystemMessage("Player not found.");
            return true;
        }
        gmTargets[guid] = true;
        blueSystemMessage(format!"Now accepting whispers from %s."(found));
        return true;
    }

    bool handleBlockWhispersCommand(Rest name)
    {
        if (name.length < 2)
            return false;
        ulong guid;
        string found;
        if (auto plr = context.onlinePlayer(name))
        {
            guid = plr.character.guid;
            found = plr.character.data.name;
        }
        else if (const remote = context.remotePlayer(name)) // another node's player
        {
            guid = remote.entry.guid;
            found = remote.entry.name;
        }
        else
        {
            redSystemMessage("Player not found.");
            return true;
        }
        gmTargets.remove(guid);
        blueSystemMessage(format!"Now blocking whispers from %s."(found));
        return true;
    }

    // -----------------------------------------------------------------------
    // The character group
    // -----------------------------------------------------------------------

    bool handleLearnCommand(string spellOrAll)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
        {
            plr = this;
            systemMessage("Auto-targeting self.");
        }
        if (sicmp(spellOrAll, "all") == 0)
        {
            gmLog(format!"taught %s all spells."(plr.player.data.name));
            const classId = plr.player.data.classId, race = plr.player.data.race;
            foreach (spell; classId < classSpells.length ? classSpells[classId] : null)
                plr.learn(spell); // spells 1.12 does not have are skipped
            const(uint[][]) raceSpells = classId == PlayerClass.paladin ? paladinRaceSpells
                : classId == PlayerClass.priest ? priestRaceSpells : classId == PlayerClass.mage ? mageRaceSpells
                : classId == PlayerClass.shaman ? shamanRaceSpells : null;
            if (race < raceSpells.length)
                foreach (spell; raceSpells[race])
                    plr.learn(spell);
            return true;
        }
        uint spell;
        try
            spell = spellOrAll.to!uint;
        catch (ConvException)
            return false;
        const info = context.data.spells.spell(spell);
        if (info is null)
        {
            systemMessage(format!"Invalid spell %u"(spell));
            return true;
        }
        if (!plr.hasGMPermissions && info.effect[].canFind(SpellEffect.instantKill))
        {
            systemMessage("don't be an idiot and teach players instakill spells. this action has been logged.");
            return true;
        }
        if (plr.player.knowsSpell(spell))
        {
            systemMessage(plr.player.data.name ~ " already knows that spell.");
            return true;
        }
        plr.learn(spell);
        gmLog(format!"taught %s spell %u"(plr.player.data.name, spell));
        plr.blueSystemMessage(format!"%s taught you Spell %u"(player.data.name, spell));
        greenSystemMessage(format!"Taught %s Spell %u"(plr.player.data.name, spell));
        return true;
    }

    bool handleRemoveItemCommand(uint itemId, int count = 1)
    {
        if (count == 0)
            return false;
        const ocount = count;
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        if (count > 0)
            plr.takeItem(itemId, count);
        if (const item = itemId in context.data.items)
        {
            gmLog(format!"used remove item %s (id: %u) count %u from %s"(item.details.name, itemId, ocount,
                plr.player.data.name));
            blueSystemMessage(format!"Removing %u copies of item %s (id: %u) from %s's inventory."(ocount,
                itemLink(itemId), itemId, plr.player.data.name));
            plr.blueSystemMessage(format!"%s removed %u copies of item %s from your inventory."(player.data.name,
                ocount, itemLink(itemId)));
        }
        else
            redSystemMessage(format!"Cannot remove non valid item id: %u ."(itemId));
        return true;
    }

    bool handleAddItemSetCommand(uint setId = 0)
    {
        if (setId == 0)
        {
            redSystemMessage("You must specify a setid.");
            return true;
        }
        auto chr = getSelectedChar(true);
        if (chr is null)
        {
            redSystemMessage("Unable to select character.");
            return true;
        }
        uint[] entries;
        foreach (entry, ref item; context.data.items)
            if (item.details.itemSet == setId)
                entries ~= entry;
        if (entries.length == 0)
        {
            redSystemMessage("Invalid item set.");
            return true;
        }
        entries.sort();
        blueSystemMessage(format!"Searching item set %u..."(setId));
        const started = MonoTime.currTime;
        gmLog(format!"used add item set command, set %u, target %s"(setId, chr.player.data.name));
        foreach (entry; entries)
            if (chr.giveItem(entry, 1) == 0)
            {
                sendNotification("No free slots left!");
                return true;
            }
        greenSystemMessage(format!"Added set to inventory complete. Time: %u ms"((MonoTime.currTime - started)
            .total!"msecs"));
        return true;
    }

    bool handleAdvanceAllSkillsCommand(uint amount = 0)
    {
        if (amount == 0)
        {
            redSystemMessage("An amount to increment is required.");
            return true;
        }
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (skill; plr.player.skillList) // `_AdvanceAllSkills`: each up to its maximum
            plr.applySkill(skill[0], cast(ushort) min(skill[1] + amount, skill[2]), cast(ushort) skill[2]);
        plr.greenSystemMessage(format!"Advanced all your skill lines by %u points."(amount));
        gmLog(format!"advanced all skills by %u on %s"(amount, plr.player.data.name));
        return true;
    }

    bool handleShowItems()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (item; plr.player.inventory.all()) // each item as a link, with its count
            systemMessage(format!"Item %u %s Count %u Slot %u ContainerSlots %u"(item.entry, itemLink(item.entry),
                cast(ubyte) plr.player.inventory.count(item.entry), item.slot, item.proto.containerSlots));
        gmLog(format!"used show items command on %s,"(plr.player.data.name));
        return true;
    }

    bool handleShowSkills()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        foreach (skill; plr.player.skillList)
            systemMessage(format!"Skill %u %s %u/%u"(skill[0], skillName(skill[0]), skill[1], skill[2]));
        gmLog(format!"used show skills command on %s,"(plr.player.data.name));
        return true;
    }

    bool handleRenameCommand(string name1, string name2)
    {
        import dmangos.world.names : checkPlayerName, CharNameResult;

        const config = context.config;
        if (checkPlayerName(name2, config.minPlayerName, config.strictPlayerNames, config.realmZone)
            != CharNameResult.CHAR_NAME_SUCCESS)
        {
            redSystemMessage("That name is invalid or contains invalid characters.");
            return true;
        }
        const guid = context.database.characterGuid(normalizedName(name1));
        if (guid == 0)
        {
            redSystemMessage("Player not found with this name.");
            return true;
        }
        const newName = normalizedName(name2);
        if (context.database.nameTaken(newName))
        {
            redSystemMessage("Player found with this name in use already.");
            return true;
        }
        context.database.renameCharacter(guid, newName);
        if (auto online = context.onlinePlayer(name1))
            sessionOf(online).renamedBy(gmSink, player.data.name, newName);
        else
            gmElsewhere(name1, GmRemoteOp.rename, newName);
        greenSystemMessage(format!"Changed name of '%s' to '%s'."(name1, name2));
        gmLog(format!"renamed character %s (GUID: %u) to %s"(name1, guid, name2));
        return true;
    }

    // -----------------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------------

    /// "Creature 42: Name" with the part searched for in light red.
    void sendHighlightedName(string prefix, string fullName, string search, uint id)
    {
        const offset = fullName.toLower.indexOf(search);
        string text = format!"%s %u: %s"(prefix, id, MSG_COLOR_WHITE);
        if (offset < 0)
            text ~= fullName;
        else
            text ~= fullName[0 .. offset] ~ MSG_COLOR_LIGHTRED ~ fullName[offset .. offset + search.length]
                ~ MSG_COLOR_WHITE ~ fullName[offset + search.length .. $];
        systemMessage(text);
    }

    /// The lookups that need four letters, and stop at 25 results.
    bool lookupNamed(string search, string kind, bool blue, LookupResult[] delegate(string) find)
    {
        const x = search.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        void say(string text)
        {
            if (blue)
                blueSystemMessage(text);
            else
                greenSystemMessage(text);
        }

        say(format!"Starting search of %s `%s`..."(kind, x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; find(x))
        {
            if (kind == "item")
            {
                const item = row.id in context.data.items;
                systemMessage(format!"Item %u %s ContainerSlots %u"(row.id, itemLink(row.id), item.containerSlots));
            }
            else
                sendHighlightedName(kind == "creature" ? "Creature" : kind == "spell" ? "Spell" : "Skill", row.name, x,
                    row.id);
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        say(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    bool handleCreatureSpawnCommand(uint entry = 0)
    {
        if (entry == 0)
            return false;
        const t = entry in context.data.creatureTemplates;
        if (t is null)
        {
            redSystemMessage("Invalid entry id.");
            return true;
        }
        const at = player.position;
        auto creature = context.spawnCreatureAt(map, entry, at);
        if (creature is null)
        {
            redSystemMessage("Invalid entry id.");
            return true;
        }
        blueSystemMessage(format!"Spawned a creature `%s` with entry %u at %f %f %f on map %u"(t.name, entry, at.x, at.y,
            at.z, player.data.map));
        gmLog(format!"spawned a %s at %u %f %f %f"(t.name, player.data.map, at.x, at.y, at.z));
        return true;
    }

    bool handleGetStandingCommand(uint faction = 0)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        const entry = context.client.factions.lookup(faction);
        const rep = plr.player.reputation;
        const standing = rep is null ? 0 : rep.standingWith(faction);
        const base = rep is null || entry is null ? 0 : rep.baseOf(entry);
        greenSystemMessage(format!"Reputation for faction %u:"(faction));
        systemMessage(format!"Base Standing: %d"(base));
        blueSystemMessage(format!"Standing: %d"(standing));
        return true;
    }

    bool handleSetStandingCommand(uint faction, int standing)
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        blueSystemMessage(format!"Setting standing of %u to %d on %s."(faction, standing, plr.player.data.name));
        if (plr.player.reputation !is null) // to that value, its neighbouring factions untouched
            plr.modifyReputation(faction, standing - plr.player.reputation.standingWith(faction), true);
        plr.flushPlayerChanges();
        plr.greenSystemMessage(format!"%s set your standing of faction %u to %d."(player.data.name, faction, standing));
        gmLog(format!"set standing of faction %u to %u for %s"(faction, standing, plr.player.data.name));
        return true;
    }

    bool handleLookupFactionCommand(Rest search)
    {
        const x = search.text.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        greenSystemMessage(format!"Starting search of faction `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (id; 0 .. context.client.factions.idLimit)
            if (const f = context.client.factions.lookup(id))
                if (f.name[0].toLower.canFind(x))
                {
                    sendHighlightedName("Faction", f.name[0], x, f.id);
                    if (++count == 25)
                    {
                        redSystemMessage("More than 25 results returned. aborting.");
                        break;
                    }
                }
        greenSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    bool handleLookupItemCommand(Rest search)
    {
        return lookupNamed(search, "item", true, (x) {
            LookupResult[] found;
            foreach (entry, ref item; context.data.items)
                if (item.details.name.toLower.canFind(x))
                    found ~= LookupResult(entry, item.details.name);
            found.sort!((a, b) => a.id < b.id);
            return found;
        });
    }

    bool handleLookupCreatureCommand(Rest search)
    {
        return lookupNamed(search, "creature", false, x => context.database.lookup(LookupTable.creature, x, 25));
    }

    bool handleLookupSpellCommand(Rest search)
    {
        return lookupNamed(search, "spell", false, x => context.database.lookup(LookupTable.spell, x, 25));
    }

    bool handleLookupSkillCommand(Rest search)
    {
        return lookupNamed(search, "skill", false, (x) {
            LookupResult[] found;
            foreach (ref skill; context.client.skillLines.rows)
                if (skill.name[0].toLower.canFind(x))
                    found ~= LookupResult(skill.id, skill.name[0]);
            return found;
        });
    }

    bool handleLookupObjectCommand(Rest search)
    {
        const x = search.toLower;
        greenSystemMessage(format!"Starting search of object `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.gameObject, x, 50))
        {
            sendMultilineMessage(format!"|cfffff000Object %u|cffFFFFFF: %s"(row.id, row.name));
            if (++count >= 50)
            {
                redSystemMessage("More than 50 results returned. aborting.");
                break;
            }
        }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.");
        blueSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    /// `.lookup quest`: the quests whose name matches the search text, at most 25.
    bool handleQuestLookupCommand(Rest search)
    {
        const x = search.toLower;
        if (x.length < 4)
        {
            redSystemMessage("Your search string must be at least 5 characters long.");
            return true;
        }
        blueSystemMessage(format!"Starting search of quests `%s`..."(x));
        const started = MonoTime.currTime;
        uint count;
        foreach (row; context.database.lookup(LookupTable.quest, x, 25))
        {
            sendMultilineMessage(format!"|cff00ccff%u: %s\n"(row.id, row.name));
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                break;
            }
        }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.\n\n");
        blueSystemMessage(format!"Search completed in %u ms."((MonoTime.currTime - started).total!"msecs"));
        return true;
    }

    // -----------------------------------------------------------------------
    // Creatures
    // -----------------------------------------------------------------------

    bool handleNpcInfoCommand()
    {
        import dmangos.world.objects : counterOf;

        auto crt = getSelectedCreature(true);
        if (crt is null)
            return false;
        auto v = &crt.values;
        blueSystemMessage("Showing creature info for " ~ crt.template_.name);
        systemMessage(format!"GUID: %d"(cast(uint) crt.guid));
        systemMessage(format!"Faction: %d"(v.get!UNIT_FIELD_FACTIONTEMPLATE));
        systemMessage(format!"NPCFlags: %d"(v.get!UNIT_NPC_FLAGS));
        systemMessage(format!"DisplayID: %d"(v.get!UNIT_FIELD_DISPLAYID));
        systemMessage(format!"Health (cur/max): %d/%d"(v.get!UNIT_FIELD_HEALTH, v.get!UNIT_FIELD_MAXHEALTH));
        systemMessage(format!"Mana (cur/max): %d/%d"(v.get!UNIT_FIELD_POWER1, v.get!UNIT_FIELD_MAXPOWER1));
        systemMessage("Armor/Holy/Fire/Nature/Frost/Shadow/Arcane");
        systemMessage(format!"%d/%d/%d/%d/%d/%d/%d"(v.get!UNIT_FIELD_RESISTANCES(0), v.get!UNIT_FIELD_RESISTANCES(1),
            v.get!UNIT_FIELD_RESISTANCES(2), v.get!UNIT_FIELD_RESISTANCES(3), v.get!UNIT_FIELD_RESISTANCES(4),
            v.get!UNIT_FIELD_RESISTANCES(5), v.get!UNIT_FIELD_RESISTANCES(6)));
        systemMessage(format!"Damage (min/max): %f/%f"(v.get!UNIT_FIELD_MINDAMAGE, v.get!UNIT_FIELD_MAXDAMAGE));
        colorSystemMessage(MSG_COLOR_RED, format!"Entry ID: %d"(v.get!OBJECT_FIELD_ENTRY));
        colorSystemMessage(MSG_COLOR_RED, format!"SQL Entry ID: %d"(counterOf(crt.guid)));
        const bytes = v.get!UNIT_FIELD_BYTES_0;
        systemMessage(format!"UNIT_FIELD_BYTES_0 are %s %s %s %s"(bytes & 0xFF, bytes >> 8 & 0xFF, bytes >> 16 & 0xFF,
            bytes >> 24));
        return true;
    }
}

/// `.setstanding` and `.getstanding` on the selected player, and `.resetreputation`.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionFormat;
    import dmangos.world.commands : MSG_COLOR_GREEN, MSG_COLOR_LIGHTBLUE;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto row = new uint[factionFormat.length];
    row[0] = 72;
    row[1] = 3;
    context.client.factions = typeof(context.client.factions).parse(buildDbc(factionFormat, [row]), "Faction.dbc");
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(anduin.session.character.guid));
    const me = cast(Player) anduin.session.character;

    gm.say(".character setstanding 72 1000");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Setting standing of 72 to 1000 on Anduin.|r"]);
    assert(me.reputation.standingWith(72) == 1000);
    assert(systemMessages(anduin.read()).canFind(MSG_COLOR_GREEN ~ "Varian set your standing of faction 72 to 1000.|r"));
    gm.say(".character getstanding 72");
    assert(systemMessages(gm.read()) == [MSG_COLOR_GREEN ~ "Reputation for faction 72:|r", "Base Standing: 0",
        MSG_COLOR_LIGHTBLUE ~ "Standing: 1000|r"]);
    gm.say(".character resetreputation");
    assert(systemMessages(gm.read()) == ["Done. Relog for changes to take effect."]);
    assert(me.reputation.standingWith(72) == 0);
}

/// `.admin castall` casts a spell on every player (but not a learning one); `.removesickness` takes resurrection sickness off.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.commands : MSG_COLOR_LIGHTBLUE, MSG_COLOR_LIGHTRED;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewCharacter;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint blessing = 95900, teach = 95901, sickness = 15007;
    context.data.spells.spells[blessing] = testSpell(blessing, 6, 1, 5);
    context.data.spells.spells.edit(blessing).casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells[teach] = testSpell(teach, 36, 1, 0);
    context.data.spells.spells[sickness] = testSpell(sickness, 6, 1, -75);
    context.data.spells.spells.edit(sickness).casting.applyAuraName[0] = AuraType.modStat;
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    auto victim = cast(Player) anduin.session.character;

    gm.say(".admin castall 7");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "No spellid specified.|r"], "one figure is too short");
    gm.say(".admin castall 95999");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Invalid spell specified.|r"]);
    gm.say(".admin castall 95901");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTRED ~ "Learn spell specified.|r"]);
    gm.say(".admin castall 95900");
    assert(systemMessages(gm.read()).canFind(MSG_COLOR_LIGHTBLUE ~ "Casted spell 95900 on all players!|r"));
    assert(victim.auras.find(blessing) !is null && (cast(Player) gm.session.character).auras.find(blessing) !is null);

    // No weapon: unarmed (162), from 1 a step.
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    const unarmed = victim.skillValue(162);
    gm.say(".character increaseweaponskill 2");
    assert(systemMessages(gm.read())[0] == MSG_COLOR_LIGHTBLUE ~ "Modifying skill line 162. Advancing 2 times.|r");
    assert(unarmed[1] == 0 ? victim.skillValue(162)[0] == 1
        : victim.skillValue(162)[0] == (unarmed[0] + 2 < unarmed[1] ? unarmed[0] + 2 : unarmed[1]));

    // `.character resetspells` and `resetskills`: what was learned since creation goes.
    {
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
        gm.say(".character learn 95900");
        gm.say(".character learnskill 164 1 75"); // blacksmithing
        gm.read();
        anduin.read();
        assert(victim.knowsSpell(blessing) && victim.skillValue(164)[1] == 75);
        gm.say(".character resetspells");
        assert(systemMessages(gm.read()) == ["Reset spells of Anduin to level 1."]);
        assert(systemMessages(anduin.read()).canFind(MSG_COLOR_LIGHTBLUE ~ "Varian reset all your spells to starting values.|r"));
        assert(!victim.knowsSpell(blessing));
        {
            NewCharacter fresh;
            assert(anduin.session.inWorld.startingAbilities(anduin.session.inWorld, fresh) && fresh.spells.length);
            foreach (s; fresh.spells)
                if (s.active && !s.disabled)
                    assert(victim.knowsSpell(s.spell), "a new character's spells");
        }
        gm.say(".character resetskills");
        assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Reset skills to default.|r"]);
        assert(victim.skillValue(164)[1] == 0 && victim.skillList().length > 0);
    }

    // `.fixscale` on the innkeeper.
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X;

        auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(keeper.guid));
        gm.say(".fixscale 0.05");
        assert(systemMessages(gm.read()).length > 0, "too small: the help");
        gm.say(".fixscale 2");
        gm.read();
        assert(keeper.values.get!OBJECT_FIELD_SCALE_X == 2.0f && db.creatureScales[creatureInnkeeper] == 2.0f);
        assert(context.data.creatureTemplates[creatureInnkeeper].scale == 2.0f);
    }

    anduin.session.inWorld.addAura(makeAura((sickness in context.data.spells.spells), victim.guid, 1, 600_000, false, [-75, 0, 0]));
    assert(victim.auras.find(sickness) !is null);
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(victim.guid));
    gm.say(".removesickness");
    assert(systemMessages(gm.read()) == [MSG_COLOR_LIGHTBLUE ~ "Removing ressurection sickness...|r"]);
    assert(victim.auras.find(sickness) is null);
}
