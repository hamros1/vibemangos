#!/bin/sh
# One benchmark run against the harness (docs/BENCHMARKS.md describes the scenarios):
#
#   tools/harness/bench.sh LABEL SCENARIO BOTS [BINARY]   e.g. tools/harness/bench.sh before crowd 500
#
# Runs 60 s after a 10 s warm-up with --seed 7, against a fresh server; the report is appended to
# $DMANGOS_HARNESS/bench/LABEL.md. Compare runs of the same scenario on the same machine only.
. "$(dirname "$0")/common.sh"
[ $# -ge 3 ] || { sed -n '2,7p' "$0"; exit 2; }
LABEL=$1; SCENARIO=$2; BOTS=$3; BIN="${4:-$WORLDSERVER}"
[ -f "$H/world.json" ] || { echo "no harness; run tools/harness/setup.sh first" >&2; exit 1; }
db_start || exit 1
revive_bots || exit 1
ulimit -n 8192 2>/dev/null
mkdir -p "$H/bench"
WORLDSERVER="$BIN" LOADGEN="$LOADGEN" CONFIG="$H/world.json" WORLD=127.0.0.1:38085 \
    REPORT="$H/bench/$LABEL.md" WORKDIR="$H/bench/work" \
    LOGIN_DB="$(db_info classicrealmd)" CHARACTER_DB="$(db_info classiccharacters)" \
    WORLD_DB="$(db_info classicmangos)" MYSQL_LIBRARY="$MYSQL_LIB" \
    sh "$REPO/tools/bench.sh" "$SCENARIO" "$BOTS" --duration 60 --warmup 10 --seed 7 > "$H/bench/$LABEL-$SCENARIO-$BOTS.out" 2>&1
status=$?
pid="$(cat "$H/bench/work/world.pid" 2>/dev/null)"
[ -n "$pid" ] && { kill "$pid" 2>/dev/null; while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done; }
tail -12 "$H/bench/$LABEL.md"
exit $status
