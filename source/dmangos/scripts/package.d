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

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.deadmines, dmangos.scripts.westfall, dmangos.scripts.spells,
    dmangos.scripts.stormwind, dmangos.scripts.ungoro, dmangos.scripts.shadowfang,
    dmangos.scripts.wailingcaverns,
    // Eastern Kingdoms scripts:
    dmangos.scripts.redridge, dmangos.scripts.arathi, dmangos.scripts.lochmodan, dmangos.scripts.silverpine,
    dmangos.scripts.wetlands, dmangos.scripts.hinterlands, dmangos.scripts.swamp, dmangos.scripts.searinggorge,
    dmangos.scripts.tirisfal, dmangos.scripts.burningsteppes, dmangos.scripts.blastedlands,
    dmangos.scripts.stranglethorn, dmangos.scripts.easternplaguelands, dmangos.scripts.westernplaguelands,
    dmangos.scripts.npcs, dmangos.scripts.areatriggers);
