# Set up dmangos

This guide installs a fresh two-node realm on one computer. The commands use Bash and the
package names on Ubuntu and Linux Mint on x86-64. Run commands from the dmangos checkout
unless a step says otherwise. Gather these files before you start.

- The dmangos repository.
- `classicmangos.sql.gz` from the source machine. It has world data. It is kept outside Git,
  so a new clone needs a copy.
- Extracted `dbc/` and `maps/` folders, or your own 1.12.x client to extract them from. The
  SQL archive and the client data are separate.

## 1. Install dependencies and build

Open a terminal on the destination computer.

```bash
sudo apt update
sudo apt install build-essential ca-certificates curl git gnupg xz-utils python3 openssl \
  mariadb-server mariadb-client libmariadb3
sudo systemctl start mariadb
```

If you already have a checkout, open it and skip the clone. If GitHub prompts for access,
use an account that can read the repository.

```bash
git clone https://github.com/hamros1/vibemangos.git "$HOME/dmangos"
cd "$HOME/dmangos"
```

Install DMD 2.114.0, then build the three programs. Run the `source` command again whenever
you need to build from a new terminal. [D toolchain installer](https://dlang.org/install.html)

```bash
mkdir -p "$HOME/dlang"
curl -fsSL https://dlang.org/install.sh -o "$HOME/dlang/install.sh"
bash "$HOME/dlang/install.sh" install dmd-2.114.0
source "$HOME/dlang/dmd-2.114.0/activate"

dub build -b release-fast -c authserver
dub build -b release-fast -c worldserver
dub build -b release-fast -c extractor
```

Check that the build produced all three files.

```bash
ls -lh bin/authserver bin/worldserver bin/extractor
```

## 2. Prepare the data

Make the destination folders.

```bash
mkdir -p sql/local data
```

1. Copy the source machine's `sql/local/classicmangos.sql.gz` into `sql/local/` on this
   computer. Keep it compressed. If the source has no archive, [export it first](#export-the-world-database).
2. Copy the source machine's extracted `dbc/` and `maps/` directories into `data/`.
   Copy `vmaps/` and `mmaps/` too if available. Copy the optional `coefficients.csv`,
   `procs.csv`, and `instance-resets.csv` into `data/` if you want the same server data
   files as the source.
3. If you skipped the copy of the extracted directories, change the quoted input path below
   to your client folder, the folder containing `Data/`. The extraction writes `data/dbc/`
   and `data/maps/`. [Extra extraction modes](CLIENT-DATA.md) cover buildings and navigation.

   ```bash
   ./bin/extractor -i "/path/to/your/WoW folder" -o data
   ```

Before moving on, check that these three paths exist. If the last two are missing, check for
an extra folder level such as `data/data/dbc/`.

```bash
ls -ld sql/local/classicmangos.sql.gz data/dbc/ data/maps/
```

## 3. Import the database and write the configs

Run this command **once** on the destination as your regular user. It checks for existing
databases, imports the archive, generates a password for the database user, and writes the
three server configs.

```bash
tools/setup-local.sh
```

The import seeds realm ID 1 with the name `dmangos`. You start with zero game accounts and
characters. The generated database password is already in the JSON files. For the next step,
choose a separate game username and password. Use 1–16 letters or digits for each.

```bash
read -r -p 'Game username: ' game_user
read -rs -p 'Game password: ' game_password
printf '\n'
./bin/authserver account create "$game_user" "$game_password"
unset game_password
```

Look for `created account` before continuing. [Account administration](CONFIGURATION.md#account-administration)
covers password resets and GM permissions.

## 4. Start the servers

Open three terminals and run `cd "$HOME/dmangos"` in each, or use your checkout's path if
you cloned elsewhere. Start the processes in this order.

| Terminal | Command | What to look for |
|---|---|---|
| 1 | `./bin/authserver` | Listening on port `3724` |
| 2 | `./bin/worldserver` | `cluster: node 1` and `coordinator`, then listening on world port `8085` |
| 3 | `./bin/worldserver --config worldserver-member.json` | `cluster: node 2`, world port `8086`, and a cluster view with both nodes |

Wait for node 1 before starting node 2. Both world nodes use realm ID 1, so the client sees one
realm. The coordinator advertises a reachable world port in the realm list. Node-to-node traffic
uses ports 9000 and 9001 on loopback.

To stop, press **Ctrl+C** in terminal 3, wait for it to exit, then stop terminals 2 and 1.
For later sessions, use this step again. Create accounts only when you need another one.

## 5. Log in

1. Close the client. Open `realmlist.wtf` in the client folder and set it to the following
   single line if client and server are on the same computer.

   ```text
   set realmlist 127.0.0.1
   ```

2. Launch the client and log in with the game account you made in step 3.
3. Select **dmangos**, create a character, and enter the world. If the realm initially says
   **Offline**, wait up to 30 seconds for the realm list to refresh, then log in again.

### Connecting from another computer

Before starting the world nodes, set `cluster.client_address` in `worldserver.json` to the
server's LAN address and port 8085, for example `192.168.1.20:8085`. Regenerate the member
config from node 1's updated config.

```bash
python3 tools/cluster-member.py worldserver.json > worldserver-member.json
```

Allow incoming TCP 3724, 8085 and 8086 on the server's firewall for your LAN. Use the same
LAN address without the port in the client's `realmlist.wtf`. Allow up to 30 seconds after
startup for the coordinator and login server to publish the new realm address.

## Common problems

| Symptom | Check |
|---|---|
| `mariadb` cannot connect | Run `sudo systemctl status mariadb`. Verify it is running and listening on TCP 3306 for the game servers. |
| Missing SQL archive | Copy the original `classicmangos.sql.gz` to `sql/local/`. A clone does not contain it. |
| Existing database or user | This setup is for a new installation. Back up an existing installation before making changes. The [configuration reference](CONFIGURATION.md) covers connecting to existing databases. |
| Missing DBC files | Look for `data/dbc/ChrRaces.dbc`. Run the extractor against the folder containing `Data/`, with `-o data`. |
| `Address already in use` | Run `ss -ltnp` and check 3724, 8085, 8086, 9000 and 9001 for an existing process. Stop the earlier server before starting another. |
| The client cannot reach the realm | Verify the client build, realm address, and that both the login and world server logs show listening ports. For a LAN client, check that both nodes advertise the LAN address. |
| Login succeeds but entering the world hangs | Check the world node terminals first. They should show a view with both nodes and no database or DBC startup errors. |

## Export the world database

Run this on the source machine if you need a fresh archive. Pass the same connection options
you use with MariaDB. For a local MariaDB administrator using the default socket:

```bash
sudo tools/database.sh export-world sql/local/classicmangos.sql.gz
```

For a private local setup, pass its socket path and run as the user who can read that
database. Export takes read locks while it dumps the world tables.

```bash
tools/database.sh export-world sql/local/classicmangos.sql.gz --socket=/path/to/mysql.sock
```

Copy the resulting archive to the destination, where the setup imports it alongside the
empty account and character schemas. The source world data comes from
[CMaNGOS Classic-DB](https://github.com/cmangos/classic-db) and local world database changes.
