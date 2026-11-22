# Quest phasing

## What Blizzard used

- Blizzard's 2018 Classic demo response said the quests connected to its phasing system were outside vanilla Classic. That statement discussed realm sharding separately. [Blizzard's demo statement, preserved in contemporary coverage](https://www.wowhead.com/classic/news/blizzcon-2018-wow-classic-demo-first-impressions-288361?page=19)
- Wrath Classic used quest phases for the Wrathgate and Battle for the Undercity sequence. Blizzard's Cataclysm Classic hotfix specifically describes moving characters back to the correct phase in Orgrimmar and Undercity after those quests were retired. [Blizzard's July 2024 hotfix](https://news.blizzard.com/en-us/article/24066687/hotfixes-july-22-2024)
- Cataclysm Classic's Molten Front starts at the Sanctuary of Malorne. Players spend Marks of the World Tree earned through quests to unlock new NPCs, structures, and daily quest routes at their own pace. [Blizzard's Molten Front overview](https://news.blizzard.com/en-us/article/24141007/cataclysm-classic-the-molten-front-now-live)
- Vanilla's Caer Darrow ghosts and Eris Havenfire use spell-based visibility. Classic-DB assigns invisibility spells `17622` and `23196` to those creatures, and equipping Spectral Essence or the Eye of Divinity grants a detection spell. That data continues to use the aura system. [Classic-DB source](https://github.com/cmangos/classic-db/tree/13e933726f386399d9820138fbd1123e7cda86c8)

## Configure a quest scene

The optional world table controls individual permanent spawns by a character's quest progress. It supports passive creatures with both NPC and player immunity flags (`UnitFlags & 0x300 = 0x300`) and quest-giver, text, and goober game objects. Use decorative or non-solid models for phased game objects. Characters at different stages can still see each other. Terrain, collision geometry and combat encounters are outside this feature. Eligible players see the same underlying spawn and share any changes to it.

1. Import [quest-spawn-phase.sql](../sql/quest-spawn-phase.sql) into each world database that will use quest phases. From the repository root, run `mariadb -u YOUR_DB_USER -p classicmangos < sql/quest-spawn-phase.sql`. Replace `YOUR_DB_USER` and `classicmangos` with the database user and world database name from your setup.
2. In `creature` or `gameobject`, look up the `guid` of each existing spawn you want to phase. The `guid` identifies one placement. `entry` identifies the template used by every copy.
3. Add rows in `quest_spawn_phase` and restart the worldserver, including every world node for that realm. With an empty or absent table, the normal Classic-DB spawns retain their existing visibility.

| `visible_states` bit | Quest stage |
| --- | --- |
| `1` | Inactive, including a quest the character never accepted or abandoned |
| `2` | In progress |
| `4` | Objectives complete, reward pending |
| `8` | Rewarded |
| `16` | Failed |

Add bits to allow multiple stages. Every row for a spawn must match. A repeatable quest uses the current attempt's stage while it is in the log and returns to rewarded after a successful turn-in or after abandoning a later attempt. Unsupported spawn types, unknown quests and invalid masks are logged at startup.

For example, substituting IDs from your own world database, a gossip NPC can disappear when quest `900001` succeeds and a quest marker can appear for the same player. The first spawn allows every state except rewarded (`1 + 2 + 4 + 16`), and the second appears only when rewarded (`8`).

```sql
INSERT INTO quest_spawn_phase (spawn_type, spawn_guid, quest_id, visible_states)
VALUES ('creature', 910001, 900001, 23),
       ('gameobject', 910002, 900001, 8);
```

For a scene that switches from one quest giver to another, make sure at least one visible giver can advance the quest at each stage. Check with two characters standing together, then relog or cross a node boundary with the character that advanced. The scene follows the character's saved quest progress.
