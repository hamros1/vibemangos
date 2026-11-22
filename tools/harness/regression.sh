#!/bin/sh
# The cluster regression: two nodes, 250 bots in one crowd while regions split between the nodes and
# merge again, then the nodes stop. The default run requires evidence of all three events:
# a split, a merge, and a player handoff. A lease lapse or a fenced write fails any run.
# Needs tools/harness/setup.sh once.
#
#   tools/harness/regression.sh            (BOTS=250, DURATION=180 seconds, AFTER=60 seconds idle)
#
# Logs and the load generator's report go to $DMANGOS_HARNESS/regression/.
. "$(dirname "$0")/common.sh"
BOTS="${BOTS:-250}"; DURATION="${DURATION:-180}"; AFTER="${AFTER:-60}"
EXPECT_BALANCING="${EXPECT_BALANCING:-auto}"
if [ "$EXPECT_BALANCING" = auto ]; then
    EXPECT_BALANCING=0
    if [ "$BOTS" -ge 250 ] && [ "$DURATION" -ge 180 ] && [ "$AFTER" -ge 60 ]; then
        EXPECT_BALANCING=1
    fi
fi
[ -f "$H/node1.json" ] || { echo "no harness; run tools/harness/setup.sh first" >&2; exit 1; }
db_start || exit 1
revive_bots || exit 1
ulimit -n 8192 2>/dev/null
R="$H/regression"; mkdir -p "$R"; rm -f "$R"/*.log "$R"/*.md "$R"/*.out "$H"/writes-*.log
cd "$R" || exit 1
pid1= pid2= loadgen_pid= pause_pid=
stop_children() {
    for p in $loadgen_pid $pause_pid $pid2 $pid1; do kill "$p" 2>/dev/null; done
    for p in $loadgen_pid $pause_pid $pid2 $pid1; do wait "$p" 2>/dev/null; done
    pid1= pid2= loadgen_pid= pause_pid=
}
trap stop_children EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$WORLDSERVER" -c "$H/node1.json" > "$R/node1.log" 2>&1 &
pid1=$!
if ! wait_listening 2 "$R/node1.log"; then
    echo "FAIL: node 1 did not start (see $R/node1.log)"; exit 1
fi
"$WORLDSERVER" -c "$H/node2.json" > "$R/node2.log" 2>&1 &
pid2=$!
if ! wait_listening 2 "$R/node2.log"; then
    echo "FAIL: node 2 did not start (see $R/node2.log)"; exit 1
fi

# Waiting for a child lets the shell run its termination trap immediately.
pause() {
    sleep "$1" &
    pause_pid=$!
    wait "$pause_pid"
    pause_pid=
}
pause 15 # the nodes see each other and the regions are granted
for log in "$R/node1.log" "$R/node2.log"; do
    if ! grep -q 'lease holds' "$log"; then
        echo "FAIL: no initial ownership lease in $log"; exit 1
    fi
done
"$LOADGEN" --world 127.0.0.1:38085 --login-db "$(db_info classicrealmd)" \
    --character-db "$(db_info classiccharacters)" --world-db "$(db_info classicmangos)" \
    --mysql-library "$MYSQL_LIB" --bots "$BOTS" --scenario crowd --duration "$DURATION" --warmup 10 \
    --report "$R/report.md" > "$R/loadgen.out" 2>&1 &
loadgen_pid=$!
wait "$loadgen_pid"
loadgen_status=$?
loadgen_pid=
if [ "$loadgen_status" != 0 ]; then
    echo "FAIL: loadgen exited with status $loadgen_status (see $R/loadgen.out)"; exit 1
fi
pause "$AFTER" # the crowd gone: regions merge back
alive=0
for p in $pid1 $pid2; do kill -0 $p 2>/dev/null && alive=$((alive + 1)); done
# Check before stopping the nodes, since deliberate shutdown can revoke their leases.
awk '
    FNR == 1 { held = 0 }
    /lease holds/ { held = 1 }
    /lease lapsed:|lease has lapsed.*not written|NOT saved:.*cluster lease lapsed/ || (held && /lease LAPSED/) {
        print FILENAME ":" FNR ": " $0
    }
' "$R/node1.log" "$R/node2.log" > "$R/lease-failures.log"
stop_children
line="$(grep -h 'bots in the world at the end' "$R/loadgen.out" "$R/report.md" 2>/dev/null | head -1)"
splits=$(grep -c 'cluster: balancing: .* split,' "$R/node1.log")
merges=$(grep -c 'cluster: balancing: .* merged into ' "$R/node1.log")
handoffs=$(grep -h ' moves to node [0-9]' "$R/node1.log" "$R/node2.log" | wc -l)
crashes=$(grep -hE 'Segmentation|core\.exception|object\.Error' "$R/node1.log" "$R/node2.log" | wc -l)
echo "regression: ${line#* }; nodes alive at the end: $alive/2; splits $splits, merges $merges, handoffs $handoffs; crashes logged: $crashes"
if [ -s "$R/lease-failures.log" ]; then
    echo "FAIL: ownership lease lapsed or a save was fenced (see $R/lease-failures.log)"; exit 1
fi
if [ "$EXPECT_BALANCING" = 1 ] && { [ "$splits" = 0 ] || [ "$merges" = 0 ] || [ "$handoffs" -eq 0 ]; }; then
    echo "FAIL: expected splits, merges and handoffs (see $R/node*.log)"; exit 1
fi
case "$line" in
    *"end: $BOTS; failed: 0"*) [ $alive = 2 ] && [ "$crashes" = 0 ] && { echo PASS; exit 0; };;
esac
echo "FAIL (see $R/)"; exit 1
