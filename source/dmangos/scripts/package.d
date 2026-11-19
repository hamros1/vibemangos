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

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.deadmines, dmangos.scripts.westfall, dmangos.scripts.spells,
    dmangos.scripts.stormwind, dmangos.scripts.ungoro, dmangos.scripts.shadowfang,
    dmangos.scripts.wailingcaverns,
    // Kalimdor scripts:
    dmangos.scripts.barrens, dmangos.scripts.ashenvale);
