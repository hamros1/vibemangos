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

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.deadmines, dmangos.scripts.westfall, dmangos.scripts.spells,
    dmangos.scripts.stormwind, dmangos.scripts.ungoro, dmangos.scripts.shadowfang,
    dmangos.scripts.wailingcaverns,
    // Kalimdor scripts:
    dmangos.scripts.barrens, dmangos.scripts.ashenvale, dmangos.scripts.darkshore,
    dmangos.scripts.desolace, dmangos.scripts.durotar, dmangos.scripts.dustwallow,
    dmangos.scripts.felwood, dmangos.scripts.feralas, dmangos.scripts.thousandneedles,
    dmangos.scripts.tanaris, dmangos.scripts.teldrassil, dmangos.scripts.stonetalon, dmangos.scripts.silithus,
    dmangos.scripts.winterspring, dmangos.scripts.azshara, dmangos.scripts.moonglade);
