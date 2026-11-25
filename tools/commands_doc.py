#!/usr/bin/env python3
"""Writes docs/COMMANDS.md from the in-game command catalog.

    python3 tools/commands_doc.py

Reads the D command catalog and capability definitions.
"""
import ast
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WORLD = ROOT / "source" / "dmangos" / "world"


def capabilities():
    text = (WORLD / "gmaccess.d").read_text()
    return {
        letter: capability
        for group, capability in re.findall(r'case ([^:]+): return "([^"]+)";', text)
        for letter in re.findall(r"'(.)'", group)
    }


def command_catalog():
    source = (WORLD / "commandtable.d").read_text()
    tables = {}
    groups = capabilities()

    def capability(node):
        if isinstance(node, ast.Name):
            return {
                "roleAdministration": "staff.admin + roles.manage",
                "legacyAdministration": "staff.admin",
            }[node.id]
        value = ast.literal_eval(node.args[0])
        return groups.get(value, "public") if len(node.args) == 1 else value

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
                    row["children"] = args[2].id
                    if len(args) > 3:
                        row["label"] = ast.literal_eval(args[3])
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
                    row.update(capability=groups["m"], args=syntax, description=ast.literal_eval(args[2]))
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

New installations include the role tables. Upgrade an existing login database from the repository
directory, then run the new worldserver binaries on every worker.

```sh
mariadb -u root -p classicrealmd < sql/gm-rbac.sql
```

Sign in to a legacy administrator account and run `.access grant <login> <role>`. Use the account's
login name. Roles are account-wide for all realms sharing this login database.

| Role | Access |
|---|---|
| `support` | Player lookup, tickets, moderation, announcements and relocation |
| `game-master` | Support, gameplay testing, events and world editing |
| `administrator` | Every capability, including role administration |

Run `.access revoke <login> <role>` to remove a role. Multiple roles combine their grants. An
enrolled account with zero roles has no staff access. Workers read current roles at login, on
handoff and before executing chat commands. Other staff behavior uses the last loaded policy.
Accounts that have never been enrolled still use `account.gmlevel`, `gm_permissions` and
`command_overrides`. The legacy `.account level` command sets that fallback policy. Configure
`gm_command_log` on every worker to record role changes and other audited staff actions.

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
  A saved empty route makes the spawn idle. Attach existing movement scripts with
  `.wp script <point> <script-id>`.
* If you imported Classic-DB before this change, run
  `mariadb -u root -p classicmangos < sql/gm-waypoints.sql` against the world database.
  It converts the spawn and route tables to InnoDB. Run this migration during maintenance,
  then restart world workers after saving routes so they load the new paths.
* Select a trainer and run `.npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]`.
  Use the spell that teaches the lesson. The selected worker uses it immediately, and the other
  workers pick it up on their next catalog refresh.

Use `.quest reload` after updating quest definitions or giver relationships in the world database.
Workers switch to the new catalog after it loads.

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

These entries remain callable by their existing names and explain what is unavailable.
In-game command menus list working actions.

| Command | Effect | Capability |
|---|---|---|
%s
""" % (len(rows_done), "\n".join(rows_done), len(rows_todo), "\n".join(rows_todo)))


if __name__ == "__main__":
    main()
