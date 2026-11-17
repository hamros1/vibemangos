#!/bin/sh
# Runs one load scenario against a freshly started world server and appends the report to $REPORT.
# docs/BENCHMARKS.md describes the scenarios and how to read the numbers.
#
#   tools/bench.sh SCENARIO BOTS [loadgen options...]
#   tools/bench.sh crowd 500 --duration 60 --warmup 10
#
# Settings (environment):
#   WORLDSERVER  the server binary (bin/worldserver)
#   CONFIG       its configuration; set metrics_interval_seconds to 5 and max_connections to 1000
#   WORLD        host:port it listens on (127.0.0.1:8085)
#   LOGIN_DB, CHARACTER_DB, WORLD_DB, MYSQL_LIBRARY   as in worldserver.json
#   REPORT       where the reports go (bench-report.md)
#   WORKDIR      where the server's log and pid go (bench/)
#
# The load generator writes accounts, session keys and character positions: use a test copy of the
# databases, never a live realm.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORLDSERVER="${WORLDSERVER:-$HERE/bin/worldserver}"
LOADGEN="${LOADGEN:-$HERE/bin/loadgen}"
CONFIG="${CONFIG:-worldserver.json}"
WORLD="${WORLD:-127.0.0.1:8085}"
REPORT="${REPORT:-bench-report.md}"
WORKDIR="${WORKDIR:-bench}"
[ $# -ge 2 ] || { sed -n '2,8p' "$0"; exit 2; }
scenario=$1; bots=$2; shift 2

mkdir -p "$WORKDIR"
if [ -f "$WORKDIR/world.pid" ]; then kill "$(cat "$WORKDIR/world.pid")" 2>/dev/null || true; sleep 2; fi
"$WORLDSERVER" -c "$CONFIG" > "$WORKDIR/world.log" 2>&1 &
echo $! > "$WORKDIR/world.pid"
for i in $(seq 120); do grep -q listening "$WORKDIR/world.log" && break; sleep 1; done
if ! grep -q listening "$WORKDIR/world.log"; then
    # Evidence of a stalled start: what each of its threads is doing (R running, S/D waiting, and on what).
    pid="$(cat "$WORKDIR/world.pid")"
    for task in /proc/"$pid"/task/*; do
        echo "thread ${task##*/}: state $(cut -d' ' -f3 "$task/stat"), waiting in $(cat "$task/wchan" 2>/dev/null), cpu ticks $(cut -d' ' -f14-15 "$task/stat")"
    done > "$WORKDIR/stalled-start.txt" 2>&1
    echo "the server did not start; see $WORKDIR/world.log and $WORKDIR/stalled-start.txt"
    exit 1
fi

/usr/bin/time -f "* load generator: %P CPU, %M KiB max memory" -a -o "$REPORT" \
    "$LOADGEN" --world "$WORLD" --login-db "$LOGIN_DB" --character-db "$CHARACTER_DB" --world-db "$WORLD_DB" \
    ${MYSQL_LIBRARY:+--mysql-library "$MYSQL_LIBRARY"} --bots "$bots" --scenario "$scenario" \
    --server-pid "$(cat "$WORKDIR/world.pid")" --server-log "$WORKDIR/world.log" --report "$REPORT" "$@"
echo >> "$REPORT"
kill "$(cat "$WORKDIR/world.pid")" 2>/dev/null || true
