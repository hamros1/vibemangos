# Shared settings of the test harness (sourced by the other scripts). Override with environment variables:
#   DMANGOS_HARNESS  where the harness keeps its database, configurations and logs (~/.cache/dmangos-harness)
#   MARIADB_ROOT     an unpacked MariaDB: usr/sbin/mariadbd and usr/lib/.../libmariadb.so.3 under it
#   CLIENT_DATA      the extracted client data (dbc/, maps/, vmaps/, mmaps/), used read-only
#   WORLDSERVER      the server binary to test (bin/worldserver)
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
H="${DMANGOS_HARNESS:-$HOME/.cache/dmangos-harness}"
MARIADB_ROOT="${MARIADB_ROOT:-$HOME/dmangos-server/mariadb}"
CLIENT_DATA="${CLIENT_DATA:-$HOME/dmangos-server/data}"
WORLDSERVER="${WORLDSERVER:-$REPO/bin/worldserver}"
LOADGEN="${LOADGEN:-$REPO/bin/loadgen}"
MYSQL_LIB="$(find "$MARIADB_ROOT/usr/lib" -name 'libmariadb.so.3' 2>/dev/null | head -1)"
SOCK="$H/run/mysql.sock"
# The harness's MariaDB runs without grant tables, on a private socket only: any password works.
db_info() { echo ".;$SOCK;mangos;harness;$1"; }

db_running() { [ -f "$H/run/mariadb.pid" ] && kill -0 "$(cat "$H/run/mariadb.pid")" 2>/dev/null; }

db_start() {
    db_running && { db_migrate; return; }
    mkdir -p "$H/run" "$H/logs"
    LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" setsid "$MARIADB_ROOT/usr/sbin/mariadbd" --no-defaults \
        --basedir="$MARIADB_ROOT/usr" --datadir="$H/mariadb-data" --socket="$SOCK" \
        --pid-file="$H/run/mariadb.pid" --skip-networking --skip-grant-tables \
        --lc-messages-dir="$MARIADB_ROOT/usr/share/mysql" >> "$H/logs/mariadb.log" 2>&1 < /dev/null &
    for i in $(seq 120); do [ -S "$SOCK" ] && db_running && { db_migrate; return; }; sleep 0.25; done
    echo "the harness's MariaDB did not start; see $H/logs/mariadb.log" >&2
    return 1
}

# Brings the copied login database up to the schema the servers refuse to start without. Each script is
# safe to apply again, so this runs at every start.
db_migrate() {
    for script in gm-rbac.sql gm-role-upgrade.sql; do
        LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" "$MARIADB_ROOT/usr/bin/mariadb" -S "$SOCK" -u root classicrealmd \
            < "$REPO/sql/$script" || { echo "the harness could not apply sql/$script" >&2; return 1; }
    done
}

db_stop() {
    db_running || return 0
    pid="$(cat "$H/run/mariadb.pid")"
    kill "$pid"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.25; done
}

# Brings the harness's characters back to life (bots that died in a run log out dead and come back as ghosts,
# and a crowd of ghosts is not what a benchmark means to measure): their corpses go, the ghost flag goes.
revive_bots() {
    LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" "$MARIADB_ROOT/usr/bin/mariadb" -S "$SOCK" -u root classiccharacters \
        -e "DELETE FROM corpse; UPDATE characters SET playerFlags = playerFlags & ~16 WHERE playerFlags & 16;"
}

# Waits until every log given has said it listens (twice: client port and, in a cluster, the node port).
wait_listening() {
    want=$1; shift
    for i in $(seq 180); do
        ok=1
        for log in "$@"; do [ "$(grep -c 'listening on' "$log" 2>/dev/null)" -ge "$want" ] || ok=0; done
        [ $ok = 1 ] && return 0
        sleep 1
    done
    return 1
}
