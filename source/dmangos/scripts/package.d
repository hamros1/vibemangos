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

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.deadmines, dmangos.scripts.westfall, dmangos.scripts.spells,
    dmangos.scripts.stormwind, dmangos.scripts.ungoro, dmangos.scripts.shadowfang,
    dmangos.scripts.wailingcaverns, dmangos.scripts.razorfenkraul, dmangos.scripts.razorfendowns,
    dmangos.scripts.gnomeregan, dmangos.scripts.scarletmonastery, dmangos.scripts.uldaman,
    dmangos.scripts.zulfarrak, dmangos.scripts.maraudon, dmangos.scripts.blackfathomdeeps,
    dmangos.scripts.sunkentemple, dmangos.scripts.blackrockdepths, dmangos.scripts.blackrockspire,
    dmangos.scripts.stratholme, dmangos.scripts.scholomance);
