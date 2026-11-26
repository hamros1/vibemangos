#!/bin/sh
# What every change goes through before it is pushed:
#   1. the unit tests (every module but the mains, built with -unittest; fails on any compile error),
#   2. release builds of the world server, the login server and the load generator,
#   3. the spell audit and the real-data tests (the unit tests again, on the client data and world database),
#   4. the cluster regression (tools/harness/regression.sh), unless --quick.
# The release builds run while the tests run; the real-data run is split across processes.
#
#   tools/harness/check.sh            the whole gate (about 8 minutes on an idle 32-core machine)
#   tools/harness/check.sh --quick    without the regression
#   tools/harness/check.sh --fast [MODULE ...]
#       the loop of one change (about a minute): every module compiled, the unit tests and real-data tests of the
#       modules named (all of them if none: dmangos.world.realscripts_raids, or a prefix such as dmangos.cluster.),
#       and unoptimized servers in $BUILD/fastbin for a chaos case:
#       WORLDSERVER=$BUILD/fastbin/worldserver AUTHSERVER=$BUILD/fastbin/authserver python3 tools/harness/chaos.py CASE
#
# Needs dmd and dub on the PATH (see docs/DEVELOPING.md, "Toolchain"). Compilers run as many at once as the free
# memory allows (CHECK_JOBS overrides), and one check at a time on the machine builds (flock on $BUILD_LOCK).
. "$(dirname "$0")/common.sh"
cd "$REPO" || exit 1
mode=full
case "$1" in
    --quick) mode=quick; shift ;;
    --fast) mode=fast; shift ;;
esac
modules=$(echo "$*" | tr ' ' ',')
U="$BUILD/unittest"
mkdir -p "$U"
started=$(date +%s)
stage() { echo "== $1 ($(( $(date +%s) - started )) s)"; }

with_build_lock make -s -C thirdparty || { echo "FAIL: the native navigation library did not build"; exit 1; }

stage "unit tests"
rm -f "$U/test"
: > "$U/build.log"
if ! with_build_lock sh "$REPO/tools/harness/build.sh" units; then
    cat "$U/obj"/*.log >> "$U/build.log"
    grep -m 20 Error "$U/build.log"; echo "FAIL: the tests do not compile"; exit 1
fi
if ! dmd -unittest -main -of="$U/test" $(find "$U/obj" -name '*.o') thirdparty/build/libdmnav.a \
        -L-lstdc++ >> "$U/build.log" 2>&1; then
    grep -m 20 -i error "$U/build.log"; echo "FAIL: the tests do not link"; exit 1
fi

# The servers, while the tests run (fast: unoptimized ones, in $BUILD/fastbin).
server_mode=full; [ $mode = fast ] && server_mode=fast
with_build_lock sh "$REPO/tools/harness/build.sh" servers $server_mode > "$U/servers.log" 2>&1 &
servers_pid=$!

# The unit tests, the spell audit and the real-data tests at once: the real-data run split across processes (about
# 1 GB each; the longest module takes 11 s, and each process first loads the data).
DMANGOS_TEST_MODULES="$modules" "$U/test" > "$U/run.log" 2>&1 &
unit_pid=$!
stage "engine modules that import a script module"
# The world's own code knows no boss: what it must know of a script's spell or quest the script module declares
# (`SpellRule`, `QuestRule`, a `@spell` script), and only the tests name scripts.
if grep -nE 'import dmangos\.scripts\.' $(ls "$REPO"/source/dmangos/world/*.d | grep -vE '/(real[^/]*|[^/]*tests?|testclient|testdata)\.d$'); then
    echo "FAIL: an engine module imports a script module"; kill $servers_pid $unit_pid 2>/dev/null; exit 1
fi
stage "names defined twice in Character"
python3 "$REPO/tools/harness/mixin-names.py" || { echo "FAIL: a name is defined twice in Character"; kill $servers_pid $unit_pid 2>/dev/null; exit 1; }
db_start || exit 1
if [ $mode != fast ]; then
    stage "spells a player can learn, against what the server does"
    python3 "$REPO/tools/harness/spell-audit.py" env LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" "$MARIADB_ROOT/usr/bin/mariadb" \
        -S "$SOCK" -u root classicmangos -- "$CLIENT_DATA/dbc" || { echo "FAIL: a learnable spell does what the server does not"; kill $servers_pid $unit_pid 2>/dev/null; exit 1; }
fi
stage "the tests on the real data (dmangos.world.realspelltests, the sweeps of every learnable spell and every"
echo "   spell a creature casts, their known failures in tools/harness/realspell-known.txt and realnpc-known.txt)"
shards=${CHECK_REAL_SHARDS:-$(jobs_for 2)}
[ "$shards" -gt 12 ] && shards=12
[ -n "$modules" ] && shards=1
pids=""
for i in $(seq 0 $((shards - 1))); do
    DMANGOS_TEST_MODULES="$modules" DMANGOS_TEST_SHARD="$i/$shards" \
        DMANGOS_REAL_DATA="$CLIENT_DATA|$MYSQL_LIB|$(db_info classicmangos)" "$U/test" > "$U/real-$i.log" 2>&1 &
    pids="$pids $!"
done
failed=0
for pid in $pids; do wait "$pid" || failed=1; done
cat "$U"/real-[0-9]*.log > "$U/real.log"
rm -f "$U"/real-[0-9]*.log
if ! wait $unit_pid; then
    tail -20 "$U/run.log"; echo "FAIL: unit tests"; kill $servers_pid 2>/dev/null; exit 1
fi
grep "modules passed unittests" "$U/run.log"
if [ $failed = 1 ]; then
    grep -m 10 -E "Error@|Exception@|realspellsweep: FAILS|realnpcsweep: FAILS" "$U/real.log"
    echo "FAIL: a test on the real data (all of it in $U/real.log)"; kill $servers_pid 2>/dev/null; exit 1
fi
grep "^realspellsweep:" "$U/real.log"
grep -E "^realnpcsweep: ([0-9]|passes now)" "$U/real.log"

stage "server builds"
if ! wait $servers_pid; then
    cat "$U/servers.log"
    for log in "$U"/dub-*.log "$U"/fast-*.log; do [ -f "$log" ] && grep -m 10 -E "Error|error" "$log"; done
    echo "FAIL: a server build failed"; exit 1
fi
echo "built"
if [ $mode = fast ]; then echo "PASS (fast; servers in $BUILD/fastbin) in $(( $(date +%s) - started )) s"; exit 0; fi
if [ $mode = quick ]; then echo "PASS (quick: no regression) in $(( $(date +%s) - started )) s"; exit 0; fi
stage "cluster regression"
sh "$REPO/tools/harness/regression.sh" || exit 1
echo "PASS in $(( $(date +%s) - started )) s"
