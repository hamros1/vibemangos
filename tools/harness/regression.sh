#!/bin/sh
# The cluster regression: two nodes, 250 bots in one crowd while regions split between the nodes and
# merge again, then the nodes stop. Passes if every bot is in the world at the end, none failed, and both
# nodes ran to the end. Needs tools/harness/setup.sh once.
#
#   tools/harness/regression.sh            (BOTS=250, DURATION=180 seconds, AFTER=60 seconds idle)
#
# Logs and the load generator's report go to $DMANGOS_HARNESS/regression/.
. "$(dirname "$0")/common.sh"
BOTS="${BOTS:-250}"; DURATION="${DURATION:-180}"; AFTER="${AFTER:-60}"
[ -f "$H/node1.json" ] || { echo "no harness; run tools/harness/setup.sh first" >&2; exit 1; }
db_start || exit 1
ulimit -n 8192 2>/dev/null
R="$H/regression"; mkdir -p "$R"; rm -f "$R"/*.log "$R"/*.md "$R"/*.out "$H"/writes-*.log
cd "$R"
for n in 1 2; do
    "$WORLDSERVER" -c "$H/node$n.json" > "$R/node$n.log" 2>&1 &
    eval "pid$n=$!"
    [ $n = 1 ] && wait_listening 2 "$R/node1.log"
done
stop_nodes() { kill $pid1 $pid2 2>/dev/null; for p in $pid1 $pid2; do while kill -0 $p 2>/dev/null; do sleep 0.5; done; done; }
if ! wait_listening 2 "$R/node1.log" "$R/node2.log"; then
    echo "FAIL: the nodes did not start (see $R/node*.log)"; stop_nodes; exit 1
fi
sleep 15 # the nodes see each other and the regions are granted
"$LOADGEN" --world 127.0.0.1:38085 --login-db "$(db_info classicrealmd)" \
    --character-db "$(db_info classiccharacters)" --world-db "$(db_info classicmangos)" \
    --mysql-library "$MYSQL_LIB" --bots "$BOTS" --scenario crowd --duration "$DURATION" --warmup 10 \
    --report "$R/report.md" > "$R/loadgen.out" 2>&1
sleep "$AFTER" # the crowd gone: regions merge back
alive=0
for p in $pid1 $pid2; do kill -0 $p 2>/dev/null && alive=$((alive + 1)); done
stop_nodes
line="$(grep -h 'bots in the world at the end' "$R/loadgen.out" "$R/report.md" 2>/dev/null | head -1)"
splits=$(grep -hc 'split,' "$R/node1.log"); merges=$(grep -hc 'merged' "$R/node1.log")
crashes=$(cat "$R"/node*.log | grep -c 'Segmentation\|core.exception\|object.Error')
echo "regression: ${line#* }; nodes alive at the end: $alive/2; splits $splits, merges $merges; crashes logged: $crashes"
case "$line" in
    *"end: $BOTS; failed: 0"*) [ $alive = 2 ] && [ "$crashes" = 0 ] && { echo PASS; exit 0; };;
esac
echo "FAIL (see $R/)"; exit 1
