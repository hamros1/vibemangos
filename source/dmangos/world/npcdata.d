/**
 * What NPCs say and offer, from the world database: gossip menus and
 * their options, the texts they show, points of interest, trainer greetings, trainers' spell
 * lists, vendors' item lists, and the conditions that decide what is shown.
 */
module dmangos.world.npcdata;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.conditions : Condition, conditionQuery, Conditions;
import dmangos.world.spells : SpellData, SpellEffect;

/// A `gossip_menu` row: the text a menu shows when its condition holds.
struct GossipMenuText
{
    uint menuId;
    uint textId;
    uint scriptId;
    uint conditionId;
}

/// A `gossip_menu_option` row.
struct GossipMenuOption
{
    uint menuId;
    uint id;
    uint icon;
    string text;
    uint broadcastText;      /// the text from `broadcast_text` instead, if not 0
    uint optionId;           /// `GossipOption`: what selecting it does
    uint npcFlag;            /// shown only by NPCs with one of these flags
    int actionMenuId;        /// the menu it opens; negative closes the window
    uint actionPoiId;        /// a `points_of_interest` flag it shows
    uint actionScriptId;
    bool boxCoded;
    uint boxMoney;        /// unused: the 1.12 menu has no price to confirm (TBC's; CMaNGOS classic leaves it unread)
    string boxText;
    uint boxBroadcastText;
    uint conditionId;
}

/// What selecting a gossip option does (`option_id`).
enum GossipOption : uint
{
    none = 0,
    gossip = 1,
    questGiver = 2,
    vendor = 3,
    taxiVendor = 4,
    trainer = 5,
    spiritHealer = 6,
    spiritGuide = 7,
    innkeeper = 8,
    banker = 9,
    petitioner = 10,
    tabardDesigner = 11,
    battlefield = 12,
    auctioneer = 13,
    stablePet = 14,
    armorer = 15,
    unlearnTalents = 16,
    unlearnPetSkills = 17,
    bot = 99,
}

/// An emote of a text, played after a delay.
struct TextEmote
{
    uint delay;
    uint emote;
}

/// One of an `npc_text`'s eight options.
struct GossipTextOption
{
    string text0;            /// said by a male NPC
    string text1;            /// by a female one
    uint language;
    float probability = 0;
    TextEmote[3] emotes;
    uint broadcastText;      /// `npc_text_broadcast_text`: the texts come from `broadcast_text`
}

/// An `npc_text` row.
struct GossipText
{
    GossipTextOption[8] options;
}

/// A `broadcast_text` row.
struct BroadcastText
{
    string maleText;
    string femaleText;
    uint language;
    uint chatType;   /// how the text is spoken: 0 say, 1 yell, 2 emote, 3 boss emote, 4 whisper, 5 boss whisper, 6 zone yell
    TextEmote[3] emotes;

    /// The gender's text, or the other one if it has none.
    string text(bool female) const pure nothrow @nogc @safe
    {
        if (female)
            return femaleText.length ? femaleText : maleText;
        return maleText.length ? maleText : femaleText;
    }
}

/// A `points_of_interest` row: a flag on the minimap.
struct PointOfInterest
{
    float x = 0;
    float y = 0;
    uint icon;
    uint flags;
    uint data;
    string name;
}

/// An `npc_trainer` or `npc_trainer_template` row, checked.
struct TrainerSpell
{
    uint spell;              /// the trainer's spell that teaches it
    uint cost;
    uint reqSkill;
    uint reqSkillValue;
    uint reqLevel;           /// the row's, or the spell's level
    uint[3] reqAbility;      /// spells the player must know; 0 for none
    uint conditionId;
    bool providedReqLevel;   /// the row set the level, rather than the spell
    uint learnedSpell;       /// what the player learns
}

/// An `npc_vendor` or `npc_vendor_template` row.
struct VendorItem
{
    uint item;
    uint maxCount;           /// 0: unlimited
    uint incrTime;           /// seconds before a sold-out item comes back
    uint slot;
    uint conditionId;
}

/// See the module documentation.
final class NpcData
{
    GossipMenuText[][uint] menus;               /// by menu id, in table order
    GossipMenuOption[][uint] options;           /// by menu id, in option order
    GossipText[uint] texts;                     /// `npc_text`, by id
    BroadcastText[uint] broadcastTexts;         /// by id
    uint[uint] npcGossip;                       /// `npc_gossip`: a spawn's text, by spawn guid
    PointOfInterest[uint] pointsOfInterest;     /// by id
    string[uint] trainerGreetings;              /// `trainer_greeting`, by creature entry
    TrainerSpell[][uint] trainers;              /// `npc_trainer`, by creature entry
    TrainerSpell[][uint] trainerTemplates;      /// `npc_trainer_template`, by template id
    VendorItem[][uint] vendors;                 /// `npc_vendor`, by creature entry
    VendorItem[][uint] vendorTemplates;         /// `npc_vendor_template`, by template id
    Conditions conditions;

    ///
    this()
    {
        conditions = new Conditions(null);
    }

    /// Reads the tables. `spells` checks the trainers' spells.
    static NpcData load(MySqlConnection world, const SpellData spells)
    {
        auto data = new NpcData;
        data.conditions = new Conditions(world.queryAs!(Condition, conditionQuery)());

        foreach (row; world.queryAs!(GossipMenuText,
            "SELECT entry, text_id, script_id, condition_id FROM gossip_menu")())
            data.menus[row.menuId] ~= row;
        foreach (row; world.queryAs!(GossipMenuOption, "SELECT menu_id, id, option_icon, IFNULL(option_text, ''), "
            ~ "option_broadcast_text, option_id, npc_option_npcflag, action_menu_id, action_poi_id, "
            ~ "action_script_id, box_coded, box_money, IFNULL(box_text, ''), box_broadcast_text, condition_id "
            ~ "FROM gossip_menu_option ORDER BY menu_id, id")())
            data.options[row.menuId] ~= row;

        foreach (row; world.query!("SELECT Id, IFNULL(Text, ''), IFNULL(Text1, ''), LanguageID, EmoteID1, EmoteID2, "
            ~ "EmoteID3, EmoteDelay1, EmoteDelay2, EmoteDelay3, ChatTypeID FROM broadcast_text")())
        {
            BroadcastText text;
            text.maleText = row.get!string(1);
            text.femaleText = row.get!string(2);
            text.language = row.get!uint(3);
            text.chatType = row.get!uint(10);
            foreach (i; 0 .. 3)
                text.emotes[i] = TextEmote(row.get!uint(7 + i), row.get!uint(4 + i));
            data.broadcastTexts[row.get!uint(0)] = text;
        }
        data.loadTexts(world);

        foreach (row; world.query!"SELECT npc_guid, textid FROM npc_gossip"())
            data.npcGossip[row.get!uint(0)] = row.get!uint(1);
        foreach (row; world.query!"SELECT entry, x, y, icon, flags, data, icon_name FROM points_of_interest"())
            data.pointsOfInterest[row.get!uint(0)] = PointOfInterest(row.get!float(1), row.get!float(2),
                row.get!uint(3), row.get!uint(4), row.get!uint(5), row.get!string(6));
        foreach (row; world.query!"SELECT Entry, Text FROM trainer_greeting"())
            data.trainerGreetings[row.get!uint(0)] = row.get!string(1);

        data.trainerTemplates = loadTrainers(world.query!(trainerQuery ~ "npc_trainer_template")(), spells);
        data.trainers = loadTrainers(world.query!(trainerQuery ~ "npc_trainer")(), spells);
        foreach (row; world.queryAs!(VendorRow, vendorQuery ~ "npc_vendor_template")())
            data.vendorTemplates[row.entry] ~= row.toItem;
        foreach (row; world.queryAs!(VendorRow, vendorQuery ~ "npc_vendor")())
            data.vendors[row.entry] ~= row.toItem;

        import std.algorithm.iteration : map, sum;

        info!("loaded %s gossip menus with %s options, %s npc texts, %s broadcast texts, %s conditions, "
            ~ "%s trainers and %s trainer templates, %s vendors and %s vendor templates")(data.menus.length,
            data.options.byValue.map!(list => list.length).sum, data.texts.length, data.broadcastTexts.length,
            data.conditions.length,
            data.trainers.length, data.trainerTemplates.length, data.vendors.length, data.vendorTemplates.length);
        return data;
    }

    /// `npc_text`, then `npc_text_broadcast_text`, which overrides it.
    private void loadTexts(MySqlConnection world)
    {
        enum perOption = 10;
        foreach (row; world.query!npcTextQuery())
        {
            const id = row.get!uint(0);
            if (id == 0)
                continue;
            GossipText text;
            foreach (i, ref option; text.options)
            {
                const at = 1 + i * perOption;
                option.text0 = row.get!string(at);
                option.text1 = row.get!string(at + 1);
                option.language = row.get!uint(at + 2);
                option.probability = row.get!float(at + 3);
                foreach (j; 0 .. 3)
                    option.emotes[j] = TextEmote(row.get!uint(at + 4 + 2 * j), row.get!uint(at + 5 + 2 * j));
            }
            texts[id] = text;
        }
        foreach (row; world.query!("SELECT Id, Prob0, Prob1, Prob2, Prob3, Prob4, Prob5, Prob6, Prob7, "
            ~ "BroadcastTextId0, BroadcastTextId1, BroadcastTextId2, BroadcastTextId3, BroadcastTextId4, "
            ~ "BroadcastTextId5, BroadcastTextId6, BroadcastTextId7 FROM npc_text_broadcast_text")())
        {
            const id = row.get!uint(0);
            if (id == 0)
                continue;
            GossipText text;
            foreach (i, ref option; text.options)
            {
                option.probability = row.get!float(1 + i);
                const broadcastId = row.get!uint(9 + i);
                if (const broadcast = broadcastId in broadcastTexts)
                {
                    option.language = broadcast.language;
                    option.emotes = broadcast.emotes;
                    option.broadcastText = broadcastId;
                }
            }
            texts[id] = text;
        }
    }

    /// Rows whose spell teaches another, keyed by creature entry or template id.
    static TrainerSpell[][uint] loadTrainers(Rows)(Rows rows, const SpellData spells)
    {
        enum uint targetNone = 0, targetUnitCaster = 1; // TARGET_NONE, TARGET_UNIT_CASTER
        TrainerSpell[][uint] trainers;
        foreach (row; rows)
        {
            const entry = row.get!uint(0), spellId = row.get!uint(1);
            const spell = spells.spell(spellId);
            if (spell is null || spell.effect[0] != SpellEffect.learnSpell)
            {
                trace!"trainer %s: spell %s does not teach a spell; ignored"(entry, spellId);
                continue;
            }
            TrainerSpell trainerSpell;
            trainerSpell.spell = spellId;
            trainerSpell.cost = row.get!uint(2);
            trainerSpell.reqSkill = row.get!uint(3);
            trainerSpell.reqSkillValue = row.get!uint(4);
            trainerSpell.reqLevel = row.get!uint(5);
            foreach (i; 0 .. 3)
                trainerSpell.reqAbility[i] = row.get!uint(6 + i); // NULL: 0
            trainerSpell.conditionId = row.get!uint(9);
            trainerSpell.providedReqLevel = trainerSpell.reqLevel > 0;
            // The listed spell is usually the trainer's, cast on the player to teach another one.
            trainerSpell.learnedSpell = spellId;
            foreach (i; 0 .. 3)
                if (spell.effect[i] == SpellEffect.learnSpell && spell.triggerSpell[i]
                    && (spell.implicitTargetA[i] == targetNone || spell.implicitTargetA[i] == targetUnitCaster))
                    trainerSpell.learnedSpell = spell.triggerSpell[i];
            if (!trainerSpell.reqLevel)
                trainerSpell.reqLevel = spell.spellLevel;
            trainers[entry] ~= trainerSpell;
        }
        return trainers;
    }
}

private enum trainerQuery = "SELECT entry, spell, spellcost, reqskill, reqskillvalue, reqlevel, ReqAbility1, "
    ~ "ReqAbility2, ReqAbility3, condition_id FROM ";

private enum vendorQuery = "SELECT entry, item, maxcount, incrtime, slot, condition_id FROM ";

private struct VendorRow
{
    uint entry, item, maxCount, incrTime, slot, conditionId;

    VendorItem toItem() const
    {
        return VendorItem(item, maxCount, incrTime, slot, conditionId);
    }
}

/// `npc_text`'s columns, eight options of ten.
private enum npcTextQuery = () {
    import std.format : format;

    string sql = "SELECT ID";
    foreach (i; 0 .. 8)
        sql ~= format!(", IFNULL(text%1$s_0, ''), IFNULL(text%1$s_1, ''), lang%1$s, prob%1$s, em%1$s_0, em%1$s_1, "
            ~ "em%1$s_2, em%1$s_3, em%1$s_4, em%1$s_5")(i);
    return sql ~ " FROM npc_text";
}();
