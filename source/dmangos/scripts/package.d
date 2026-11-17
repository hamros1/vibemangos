/**
 * The gameplay scripts (docs/SCRIPTING.md): one module per dungeon or area. A new module is added
 * to `scriptModules`; the server finds its scripts there at compile time.
 */
module dmangos.scripts;

import std.meta : AliasSeq;

static import dmangos.scripts.deadmines;
static import dmangos.scripts.westfall;

/// Every module holding scripts.
alias scriptModules = AliasSeq!(dmangos.scripts.deadmines, dmangos.scripts.westfall);
