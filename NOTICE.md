# Notices

dmangos is a World of Warcraft 1.12 server written in D. Parts of it are derived from other projects,
whose copyright and licences apply to those parts. This file is where that is recorded. The rest of the
documentation describes how dmangos works on its own terms; [PROVENANCE.md](PROVENANCE.md) lists, module
by module, which functions of these projects each one reproduces.

> **Licence of dmangos:** the GNU Affero General Public License, version 3 or (at your option) any later
> version (`AGPL-3.0-or-later`); the text is in [LICENSE](LICENSE). The derived parts below come from works
> licensed under the GNU GPL (version 2 or later) and the GNU AGPL (version 3 or later), and this is the
> licence that meets both. Their copyright notices stay with them, as recorded below.

## Derived works

### CMaNGOS (Continued MaNGOS), classic

* <https://github.com/cmangos/mangos-classic>
* Copyright: the CMaNGOS project and the MaNGOS authors (see their `AUTHORS` file).
* Licence: GNU General Public License, version 2 or (at your option) any later version.
* Derived here: the game's behaviour, rules and formulas (combat, spells and auras, creatures and their
  AI, loot, quests, items, groups, guilds, mail, auctions, honor, battlegrounds and the rest), the client
  protocol's handling, the login server's protocol, the use of the CMaNGOS database schema, and the map
  data extraction. Its database schema and world data (classic-db) are used as they are.

### ArcEmu 2.4.3

* <https://github.com/inversion1/Arcemu-2.4.3>
* Copyright: the Ascent Team (2005-2007) and ArcEmu (2008 onwards).
* Licence: GNU Affero General Public License, version 3 or (at your option) any later version.
* Derived here: the game master command system (`world/commands.d`, `world/commandtable.d`,
  `world/gm*.d`): its command tables, permissions, messages and behaviour, which dmangos reproduces
  exactly.

### vmangos

* <https://github.com/vmangos/core>
* Copyright: the vmangos and CMaNGOS projects and the MaNGOS authors.
* Licence: GNU General Public License, version 2 or (at your option) any later version.
* Derived here: the meeting stones' queue (`world/meetingstone.d` and its part of
  `world/groupservice.d`): its roles, priorities, matching and timers, and its packets.

## Included third-party code

### Recast & Detour (recastnavigation 1.6.0)

* `thirdparty/recastnavigation`, unchanged; licence in `thirdparty/recastnavigation/License.txt`.
* Copyright (c) 2009 Mikko Mononen.
* Licence: zlib.

## Algorithms and formats followed

* **SRP6:** the variant the World of Warcraft client uses (`crypto/`).
* **MPQ archives:** the format as StormLib documents it.
* **PKWare DCL "explode":** after Mark Adler's `blast.c` (zlib licence).
* **Vector maps:** collision math after G3D (BSD licence), as the CMaNGOS vmap code uses it.
* **The timer wheel:** after the Ember server's design; no code taken.

## Trademarks

World of Warcraft is a trademark of Blizzard Entertainment, Inc. dmangos is not affiliated with or
endorsed by Blizzard Entertainment. It does not include any client data: the server reads data the
user extracts from their own client.
