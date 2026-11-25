#!/usr/bin/env python3
"""Writes docs/COMMANDS.md from the in-game command catalog.

    python3 tools/commands_doc.py

Reads the D command catalog.
"""
import ast
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WORLD = ROOT / "source" / "dmangos" / "world"


def command_catalog():
    source = (WORLD / "commandtable.d").read_text()
    tables = {}
    def capability(node):
        if isinstance(node, ast.Name):
            return {"roleAdministration": "staff.admin + roles.manage"}[node.id]
        return ast.literal_eval(node.args[0]) or "public"

    for name, content in re.findall(r"immutable ChatCommand\[\] (\w+) = \[(.*?)\n\];", source, re.S):
        rows = []
        for line in content.strip().splitlines():
            call = ast.parse(line.strip().removesuffix(","), mode="eval").body
            args = call.args
            word = ast.literal_eval(args[0])
            row = dict(name=word, label=word, args="", description="", capability="public",
                       children=None, target=None, unavailable=False)
            match call.func.id:
                case "section":
                    row["children"] = args[1].id
                    if len(args) > 2:
                        row["label"] = ast.literal_eval(args[2])
                case "shortcut":
                    row["target"] = ast.literal_eval(args[1])
                case "unavailable":
                    row.update(capability=capability(args[1]), description=ast.literal_eval(args[2]),
                               unavailable=True)
                case "action":
                    row.update(capability=capability(args[1]), args=ast.literal_eval(args[3]),
                               description=ast.literal_eval(args[4]))
                    if len(args) > 5:
                        row["label"] = ast.literal_eval(args[5])
                case "stat":
                    maximum = len(args) > 3 and not isinstance(args[3], ast.UnaryOp)
                    syntax = "<min> <max>" if word == "damage" else "<value> [max]" if maximum else "<value>"
                    row.update(capability="character.modify", args=syntax, description=ast.literal_eval(args[2]))
                    if len(args) > 5:
                        row["label"] = ast.literal_eval(args[5])
                case _:
                    raise ValueError(line)
            rows.append(row)
        tables[name] = rows
    return tables


def command_rows(tables, table="commandTable", path="", label=""):
    for entry in tables[table]:
        name = path + entry["name"]
        shown = label + entry["label"]
        if entry["children"]:
            yield from command_rows(tables, entry["children"], name + " ", shown + " ")
        else:
            yield name, shown, entry


def main():
    catalog = list(command_rows(command_catalog()))
    by_name = {name: entry for name, _, entry in catalog}
    rows_done, rows_todo = [], []
    for name, label, row in sorted(catalog, key=lambda item: item[1].lower()):
        action = by_name[row["target"]] if row["target"] else row
        args = (" " + action["args"]).replace("|", "\\|") if action["args"] else ""
        syntax = f"`.{label}{args}`"
        if label != name:
            syntax += f" (also `.{name}`)"
        line = f"| {syntax} | {action['description']} | `{action['capability']}` |"
        (rows_todo if action["unavailable"] else rows_done).append(line)

    with (ROOT / "docs" / "COMMANDS.md").open("w") as out:
        out.write("""# GM commands

Type a command in chat with a leading `.` or `!`. Start with `.commands` or open a group such as
`.wp` to see the actions you can use. Use `.help <command>` to see its arguments and what it does.
The catalog shows the shorter spellings first. Existing spellings and their abbreviations still work.

| Task | Command |
|---|---|
| Show your location | `.where` |
| Travel to a map coordinate | `.go coords <map> <x> <y> <z>` |
| Visit or summon a player | `.go player <name>`, `.go summon <name>` |
| Teach a spell to the selected player or yourself | `.learn <spell-id>` |
| Find a support ticket | `.ticket list` |
| Check your access | `.access status` |
| Inspect the battleground queue | `.bg queue` |
| See uptime and player counts | `.server status` |

Use `.modify hp 400` to set both health and maximum health to 400. Use
`.modify hp 300 400` to set them separately.

## Give someone staff access

New installations include the role tables. For an existing cluster, stop the login server and
all world processes, then run these migrations from the repository directory before starting
the new binaries together. Substitute your login database name if it differs.

```sh
mariadb -u root -p classicrealmd < sql/gm-rbac.sql
mariadb -u root -p classicrealmd < sql/gm-role-upgrade.sql
```

The upgrade preserves existing role assignments and migrates old staff accounts to the
corresponding built-in role. Reapplying it respects accounts whose roles were revoked.
Recreate any customized permissions as named grants. The servers read staff access from the
role tables.

Run `./bin/authserver account grant <login> administrator` to give your first administrator
access. In game, use `.access grant <login> <role>`. Roles apply to the account across all
realms that share this login database.

| Role | Access |
|---|---|
| `support` | Player lookup, tickets, moderation, announcements and relocation |
| `game-master` | Support, gameplay testing, events and world editing |
| `administrator` | Every capability, including role administration |

Run `.access revoke <login> <role>` to remove a role. Multiple roles combine their grants.
An account with zero roles has no staff access. Workers refresh roles at login, on handoff
and before executing chat commands. Configure `gm_command_log` on every worker to record
role changes and audited staff actions.

## Create a narrow role

Run SQL against the login database to define a role, then grant it in game. For example, this role
can inspect NPCs and inherits the public commands available to staff. Broad gameplay privileges
are explicit capabilities such as `staff.access` and `staff.game_master`.

```sql
INSERT INTO dmangos_gm_role (role_name, description)
VALUES ('npc-inspector', 'Inspect selected creatures');

INSERT INTO dmangos_gm_role_permission (role_name, capability)
VALUES ('npc-inspector', 'command.npc info');
```

Then use `.access grant <login> npc-inspector`. A capability such as `world.creatures` grants
every command with that capability in the reference below. For one command, use
`command.<full command path>` with lowercase words, for example `command.character learn`.
Shortcuts share their original permission path. For `.go coords` use `command.worldport`,
and for `.npc traineradd` use `command.addtrainerspell`.

## Edit a route or trainer

* Select a saved creature. Stand at each waypoint and use `.wp add [wait-ms]`. Use
  `.wp list` to review your draft and `.wp save` to commit the route. Use
  `.wp discard` to discard unsaved edits. Selecting a different spawn starts a new draft.
  A saved empty route makes the spawn idle. Use `.wp gait`, `.wp emote` or `.wp model` to
  customize a point, or `.wp script <point> <script-id>` to attach an existing script.
  Use `.wp add-air` for a creature whose template supports flight.
* If you imported Classic-DB before this change, run
  `mariadb -u root -p classicmangos < sql/gm-waypoints.sql` against the world database.
  Run `mariadb -u root -p classicmangos < sql/gm-content.sql` for NPC spawn links.
  The waypoint migration converts the spawn and route tables to InnoDB. Run both during maintenance,
  then restart world workers after saving routes so they load the new paths.
* Select a trainer and run `.npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]`.
  Use the spell that teaches the lesson. The selected worker uses it immediately, and the other
  workers pick it up on their next catalog refresh.

Use `.quest reload` after updating quest definitions or giver relationships in the world database.
Workers switch to the new catalog after it loads.

## Test encounters and edit spawn links

* Select a saved leader and use `.npc formation-leader`. Select a follower and use
  `.npc formation-add [yards] [degrees]`. Use `.npc link-info` to inspect the saved link and
  `.npc formation-remove` to clear it. Restart world workers to load saved changes.
* Select an NPC with a spell list. Use `.debug ai-test` to inspect its spells and
  `.debug ai-next` to cast the next spell on its normal targets.
* Use `.bg pause on` in a battleground to pause the match clock, scoring and objectives.
  Use `.bg pause off` to resume the same match.

## Design references

* Guild Wars lists commands in game. Final Fantasy XIV documents command groups, aliases and
  syntax. The same discovery workflow is available here through `.commands`, `.help` and group
  menus. [Guild Wars command reference](https://wiki.guildwars.com/wiki/Special_command)
  [Final Fantasy XIV command reference](https://na.finalfantasyxiv.com/lodestone/playguide/db/search/?category=text_command)
* RuneScape documents its developer cheats separately from player commands. This server gives
  testing toggles their own `testing.cheats` capability. [RuneScape developer cheats](https://developer.runescape.com/rs/cheats.html)
* Aion's location command is an example of a short, task-based shortcut. WildStar's publisher
  patch archive shows the role of chat in the player UI. That informed direct travel shortcuts
  and chat-based staff feedback. [Aion command reference](https://power.ncsoft.jp/aion/powerWiki/操作方法およびコマンド)
  [WildStar Redmoon Rising patch notes](https://store.steampowered.com/news/posts/?appids=376570&enddate=1472591462)

## Working commands (%d)

Generated from the command tables by `python3 tools/commands_doc.py`.

| Command | Effect | Capability |
|---|---|---|
%s

## Unavailable commands (%d)

These actions depend on features absent from the supported client. Calling one directly
shows the client restriction. In-game command menus list working actions.

| Command | Effect | Capability |
|---|---|---|
%s
""" % (len(rows_done), "\n".join(rows_done), len(rows_todo), "\n".join(rows_todo)))


if __name__ == "__main__":
    main()
