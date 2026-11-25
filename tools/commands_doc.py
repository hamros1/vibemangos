#!/usr/bin/env python3
"""Writes docs/COMMANDS.md from the command table and the handlers written.

    python3 tools/commands_doc.py

Reads the D command tables, capability definitions and available handlers.
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "source", "dmangos", "world")

ROW = re.compile(r'ChatCommand\(("(?:[^"\\]|\\.)*"), \'(.)\', (null|"\w+"), ("(?:[^"\\]|\\.)*"), (\w+), '
                 r'(null|"[^"]*"), (null|"[^"]*"), (\d)\)')

def capabilities():
    with open(os.path.join(WORLD, "gmaccess.d")) as file:
        text = file.read()
    groups = {}
    command_groups = {}
    prefixes = []
    for names, capability in re.findall('case ([^:]+):\\s*return "([^"]+)";', text):
        for group in re.findall("'(.)'", names):
            groups[group] = capability
        for path in re.findall('"([^"]+)"', names):
            command_groups[path] = capability
    for prefix, capability in re.findall(r'path\.startsWith\("([^"]+)"\)\)\s+return "([^"]+)";', text):
        prefixes.append((prefix, capability))
    return groups, command_groups, prefixes


def tables():
    text = open(os.path.join(WORLD, "commandtable.d")).read()
    found = {}
    for match in re.finditer(r"immutable ChatCommand\[\] (\w+) = \[(.*?)\n\];", text, re.S):
        rows = []
        for row in ROW.finditer(match.group(2)):
            name, group, handler, help_, child, field, _, _ = row.groups()
            rows.append({
                "name": name.strip('"'),
                "group": group,
                "handler": None if handler == "null" else handler.strip('"'),
                "help": help_[1:-1].replace('\\"', '"').replace("\\n", " "),
                "child": None if child == "null" else child,
                "field": field != "null",
            })
        found[match.group(1)] = rows
    return found


def implemented():
    names = set()
    # Most handlers live in gm*.d; a few with the system they command (honor.d's `.honor`).
    for path in glob.glob(os.path.join(WORLD, "gm*.d")) + [os.path.join(WORLD, n) for n in ("commands.d", "honor.d")]:
        for name in re.findall(r"bool ([a-z]\w*)\(", open(path).read()):
            names.add(name[0].upper() + name[1:])
    return names


def main():
    all_tables = tables()
    done = implemented()
    groups, command_groups, prefixes = capabilities()
    rows_done, rows_todo = [], []
    for row in all_tables["commandTable"]:
        children = all_tables[row["child"]] if row["child"] else [None]
        for child in children:
            entry = child or row
            name = "." + row["name"] + ("" if child is None else " " + child["name"])
            path = name[1:]
            canonical = command_groups.get(path, path) if path in {
                "learn", "travel coords", "travel player", "travel summon", "npc traineradd"
            } else path
            letter = entry["group"]
            if path in {"access grant", "access revoke"}:
                capability = "staff.admin + roles.manage"
            elif letter == "z":
                capability = groups[letter]
            elif canonical == "addtrainerspell":
                capability = "world.trainers"
            else:
                capability = command_groups.get(canonical)
                if not capability:
                    capability = next((cap for prefix, cap in prefixes if canonical.startswith(prefix)),
                                      groups.get(letter, "public"))
            works = entry["field"] or (entry["handler"] in done)
            line = "| `%s` | `%s` | %s |" % (name, capability, entry["help"].replace("|", "\\|"))
            (rows_done if works else rows_todo).append(line)

    with open(os.path.join(ROOT, "docs", "COMMANDS.md"), "w") as out:
        out.write("""# GM commands

Type `.` or `!` before a command in chat. Use `.commands` to discover the commands you can run and
`.help <command>` for its syntax. Typing a group by itself, such as `.npc`, lists its available
subcommands. Exact names take priority and existing abbreviations still work.

| Task | Command |
|---|---|
| Show location | `.gps` or `.debug dumpcoords` |
| Travel to a map coordinate | `.travel coords <map> <x> <y> <z>` |
| Visit or summon a player | `.travel player <name>`, `.travel summon <name>` |
| Teach a spell to the selected player or yourself | `.learn <spell-id>` |
| Find a support ticket | `.gmTicket list` |
| Check your access | `.access whoami` |

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
Shortcuts share their original permission path. For `.travel coords` use `command.worldport`,
and for `.npc traineradd` use `command.addtrainerspell`.

## Edit a route or trainer

* Select a saved creature. Stand at each waypoint and use `.waypoint add [wait-ms]`. Use
  `.waypoint show` to review your draft and `.waypoint save` to commit the route. Use
  `.waypoint hide` to discard unsaved edits. Selecting a different spawn starts a new draft.
  A saved empty route makes the spawn idle. Attach existing movement scripts with
  `.waypoint script <point> <script-id>`.
* If you imported Classic-DB before this change, run
  `mariadb -u root -p classicmangos < sql/gm-waypoints.sql` against the world database.
  It converts the spawn and route tables to InnoDB. Run this migration during maintenance,
  then restart world workers after saving routes so they load the new paths.
* Select a trainer and run `.npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]`.
  Use the spell that teaches the lesson. The selected worker uses it immediately, and the other
  workers pick it up on their next catalog refresh.

Use `.quest load` after updating quest definitions or giver relationships in the world database.
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

| Command | Capability | Help |
|---|---|---|
%s

## Unavailable commands (%d)

These legacy entries return “Not yet implemented.” This includes features that depend on systems
outside the 1.12 client, such as rated arena teams and player flight. Per-point animations and
model changes can use native waypoint movement scripts. SQL maintenance uses the MariaDB client.

| Command | Capability | Help |
|---|---|---|
%s
""" % (len(rows_done), "\n".join(rows_done), len(rows_todo), "\n".join(rows_todo)))


if __name__ == "__main__":
    main()
