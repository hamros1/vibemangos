/**
 * The gameplay scripts (docs/SCRIPTING.md): one module per dungeon or area. A new module is added
 * to `scriptModules`; the server finds its scripts there at compile time.
 */
module dmangos.scripts;

import std.meta : AliasSeq;

static import dmangos.scripts.deadmines;
static import dmangos.scripts.westfall;
static import dmangos.scripts.spells;
static import dmangos.scripts.stormwind;
static import dmangos.scripts.ungoro;
static import dmangos.scripts.shadowfang;
static import dmangos.scripts.wailingcaverns;
static import dmangos.scripts.barrens; // Kalimdor scripts
static import dmangos.scripts.ashenvale;
static import dmangos.scripts.darkshore;
static import dmangos.scripts.desolace;
static import dmangos.scripts.durotar;
static import dmangos.scripts.dustwallow;
static import dmangos.scripts.felwood;
static import dmangos.scripts.feralas;
static import dmangos.scripts.thousandneedles;
static import dmangos.scripts.tanaris;
static import dmangos.scripts.teldrassil;
static import dmangos.scripts.stonetalon;
static import dmangos.scripts.silithus;
static import dmangos.scripts.winterspring;
static import dmangos.scripts.azshara;
static import dmangos.scripts.moonglade;
// Eastern Kingdoms scripts:
static import dmangos.scripts.redridge;
static import dmangos.scripts.arathi;
static import dmangos.scripts.lochmodan;
static import dmangos.scripts.silverpine;
static import dmangos.scripts.wetlands;
static import dmangos.scripts.hinterlands;
static import dmangos.scripts.swamp;
static import dmangos.scripts.searinggorge;
static import dmangos.scripts.tirisfal;
static import dmangos.scripts.burningsteppes;
static import dmangos.scripts.blastedlands;
static import dmangos.scripts.stranglethorn;
static import dmangos.scripts.easternplaguelands;
static import dmangos.scripts.westernplaguelands;
static import dmangos.scripts.npcs;
static import dmangos.scripts.areatriggers;
static import dmangos.scripts.razorfenkraul;
static import dmangos.scripts.razorfendowns;
static import dmangos.scripts.gnomeregan;
static import dmangos.scripts.scarletmonastery;
static import dmangos.scripts.uldaman;
static import dmangos.scripts.zulfarrak;
static import dmangos.scripts.maraudon;
static import dmangos.scripts.blackfathomdeeps;
static import dmangos.scripts.sunkentemple;
static import dmangos.scripts.blackrockdepths;
static import dmangos.scripts.blackrockspire;
static import dmangos.scripts.stratholme;
static import dmangos.scripts.scholomance;
static import dmangos.scripts.diremaul;
// Raid scripts:
static import dmangos.scripts.moltencore;
static import dmangos.scripts.onyxia;
static import dmangos.scripts.zulgurub;
static import dmangos.scripts.blackwinglair;
static import dmangos.scripts.ruinsofahnqiraj;
static import dmangos.scripts.templeofahnqiraj;
static import dmangos.scripts.naxxramas;
// Open-world round 2:
static import dmangos.scripts.professions;
static import dmangos.scripts.emeralddragons;
static import dmangos.scripts.worldobjects;
static import dmangos.scripts.guards;
static import dmangos.scripts.worldmaps;
// Spell scripts of items, quests and the world:
static import dmangos.scripts.worldspells;
static import dmangos.scripts.itemeffects;
static import dmangos.scripts.scourgeinvasion;
static import dmangos.scripts.wareffort; // the war effort

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.scourgeinvasion, dmangos.scripts.deadmines, dmangos.scripts.westfall, dmangos.scripts.spells,
    dmangos.scripts.stormwind, dmangos.scripts.ungoro, dmangos.scripts.shadowfang,
    dmangos.scripts.wailingcaverns,
    // Kalimdor scripts:
    dmangos.scripts.barrens, dmangos.scripts.ashenvale, dmangos.scripts.darkshore,
    dmangos.scripts.desolace, dmangos.scripts.durotar, dmangos.scripts.dustwallow,
    dmangos.scripts.felwood, dmangos.scripts.feralas, dmangos.scripts.thousandneedles,
    dmangos.scripts.tanaris, dmangos.scripts.teldrassil, dmangos.scripts.stonetalon, dmangos.scripts.silithus,
    dmangos.scripts.winterspring, dmangos.scripts.azshara, dmangos.scripts.moonglade,
    // Eastern Kingdoms scripts:
    dmangos.scripts.redridge, dmangos.scripts.arathi, dmangos.scripts.lochmodan, dmangos.scripts.silverpine,
    dmangos.scripts.wetlands, dmangos.scripts.hinterlands, dmangos.scripts.swamp, dmangos.scripts.searinggorge,
    dmangos.scripts.tirisfal, dmangos.scripts.burningsteppes, dmangos.scripts.blastedlands,
    dmangos.scripts.stranglethorn, dmangos.scripts.easternplaguelands, dmangos.scripts.westernplaguelands,
    dmangos.scripts.npcs, dmangos.scripts.areatriggers,
    // Dungeon scripts:
    dmangos.scripts.razorfenkraul, dmangos.scripts.razorfendowns, dmangos.scripts.gnomeregan,
    dmangos.scripts.scarletmonastery, dmangos.scripts.uldaman, dmangos.scripts.zulfarrak, dmangos.scripts.maraudon,
    dmangos.scripts.blackfathomdeeps, dmangos.scripts.sunkentemple, dmangos.scripts.blackrockdepths,
    dmangos.scripts.blackrockspire, dmangos.scripts.stratholme, dmangos.scripts.scholomance, dmangos.scripts.diremaul,
    // Raid scripts:
    dmangos.scripts.moltencore, dmangos.scripts.onyxia, dmangos.scripts.zulgurub, dmangos.scripts.blackwinglair,
    dmangos.scripts.ruinsofahnqiraj, dmangos.scripts.templeofahnqiraj, dmangos.scripts.naxxramas,
    // Open-world round 2:
    dmangos.scripts.professions, dmangos.scripts.emeralddragons, dmangos.scripts.worldobjects,
    dmangos.scripts.guards, dmangos.scripts.worldmaps,
    // Spell scripts of items, quests and the world:
    dmangos.scripts.worldspells, dmangos.scripts.itemeffects,
    // The war effort:
    dmangos.scripts.wareffort);
