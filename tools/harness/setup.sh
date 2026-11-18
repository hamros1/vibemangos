#!/bin/sh
# Makes the test harness: a private MariaDB holding a copy of a CMaNGOS classic data directory, and the
# configurations the regression and the benchmarks run with.
#
#   tools/harness/setup.sh SOURCE_DATADIR [--force]
#
# SOURCE_DATADIR is a MariaDB data directory with classicrealmd, classiccharacters and classicmangos
# (for example a dev server's). It is copied as files, so the server using it must be stopped while the
# copy is made; the script refuses otherwise. --force replaces an existing harness database.
set -e
. "$(dirname "$0")/common.sh"
[ $# -ge 1 ] || { sed -n '2,10p' "$0"; exit 2; }
SRC="$(cd "$1" && pwd)"; FORCE="$2"
[ -x "$MARIADB_ROOT/usr/sbin/mariadbd" ] || { echo "no mariadbd under MARIADB_ROOT ($MARIADB_ROOT)" >&2; exit 1; }
[ -n "$MYSQL_LIB" ] || { echo "no libmariadb.so.3 under MARIADB_ROOT" >&2; exit 1; }
[ -d "$CLIENT_DATA/dbc" ] || { echo "no extracted client data at CLIENT_DATA ($CLIENT_DATA)" >&2; exit 1; }
for db in classicrealmd classiccharacters classicmangos; do
    [ -d "$SRC/$db" ] || { echo "$SRC has no $db database" >&2; exit 1; }
done
# A data directory a running server has open cannot be copied safely.
for fd in /proc/[0-9]*/fd/*; do
    case "$(readlink "$fd" 2>/dev/null)" in "$SRC"/*) echo "$SRC is in use (process ${fd#/proc/}); stop that server first" >&2; exit 1;; esac
done
if [ -d "$H/mariadb-data" ]; then
    [ "$FORCE" = "--force" ] || { echo "$H/mariadb-data exists; pass --force to replace it" >&2; exit 1; }
    db_stop
    rm -rf "$H/mariadb-data"
fi
mkdir -p "$H" "$H/run" "$H/logs"
cp -a "$SRC" "$H/mariadb-data"
rm -f "$H/mariadb-data"/*.pid "$H/mariadb-data"/*.sock
db_start

# One standalone configuration (benchmarks) and two cluster nodes (the regression).
python3 - "$H" "$SOCK" "$MYSQL_LIB" "$CLIENT_DATA" <<'PY'
import json, sys
h, sock, lib, data = sys.argv[1:]
db = lambda name: ".;%s;mangos;harness;%s" % (sock, name)
base = {
    "realm_id": 1, "login_database": db("classicrealmd"), "character_database": db("classiccharacters"),
    "world_database": db("classicmangos"), "mysql_library": lib, "data_dir": data,
    "bind_address": "127.0.0.1", "port": 38085, "log_level": "info", "metrics_interval_seconds": 5,
    "max_connections": 2000, "write_log": h + "/writes.log",
}
json.dump(base, open(h + "/world.json", "w"), indent=2)
for n in (1, 2):
    c = dict(base, port=38084 + n, metrics_interval_seconds=10, write_log="%s/writes-%d.log" % (h, n))
    c["cluster"] = {"node_id": n, "name": "harness", "listen_address": "127.0.0.1", "listen_port": 38999 + n, "coordinator": "127.0.0.1:39000",
                    "balance_interval_seconds": 10, "region_cooldown_seconds": 30}
    json.dump(c, open("%s/node%d.json" % (h, n), "w"), indent=2)
PY
echo "harness ready in $H"
