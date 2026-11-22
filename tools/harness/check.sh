#!/bin/sh
# What every change goes through before it is committed:
#   1. the unit tests (every module but the mains, built with -unittest; fails on any compile error),
#   2. release builds of the world server, the login server and the load generator,
#   3. the cluster regression (tools/harness/regression.sh), unless --quick.
#
#   tools/harness/check.sh [--quick]
# Needs dmd and dub on the PATH (see docs/DEVELOPING.md, "Toolchain").
. "$(dirname "$0")/common.sh"
cd "$REPO" || exit 1
mkdir -p "$H/unittest"
make -s -C thirdparty || { echo "FAIL: the native navigation library did not build"; exit 1; }
echo "== unit tests"
rm -f "$H/unittest/test"
# Each module compiled on its own, all at once (-allinst: each emits the template instances it uses, which
# separate compilation needs), then linked: seconds, where one dmd for all of them took ten minutes.
rm -rf "$H/unittest/obj" && mkdir -p "$H/unittest/obj"
: > "$H/unittest/build.log"
# CHECK_JOBS limits the compilers at once (each can take 4 GB): set it low when other builds run alongside.
if ! find source -name '*.d' ! -name main.d | xargs -P "${CHECK_JOBS:-$(nproc)}" -I{} \
        sh -c 'dmd -c -unittest -allinst -Isource -od="$1" -op "$2" > "$1/$(echo "$2" | tr / _).log" 2>&1' _ "$H/unittest/obj" {}; then
    cat "$H/unittest/obj"/*.log >> "$H/unittest/build.log"
    grep -m 20 Error "$H/unittest/build.log"; echo "FAIL: the tests do not compile"; exit 1
fi
if ! dmd -unittest -main -of="$H/unittest/test" $(find "$H/unittest/obj" -name '*.o') thirdparty/build/libdmnav.a \
        -L-lstdc++ >> "$H/unittest/build.log" 2>&1; then
    grep -m 20 -i error "$H/unittest/build.log"; echo "FAIL: the tests do not link"; exit 1
fi
"$H/unittest/test" > "$H/unittest/run.log" 2>&1 || { tail -20 "$H/unittest/run.log"; echo "FAIL: unit tests"; exit 1; }
grep "modules passed unittests" "$H/unittest/run.log"
echo "== names defined twice in Character"
python3 "$REPO/tools/harness/mixin-names.py" || { echo "FAIL: a name is defined twice in Character"; exit 1; }
echo "== release builds"
# `release-fast` optimizes without -inline. The world server is the only large build.
# Build in sequence so a low-memory machine need only run one compiler here.
failed=0
for c in worldserver authserver loadgen; do
    dub build -q -c "$c" -b release-fast > "$H/unittest/dub-$c.log" 2>&1 || failed=1
done
if [ $failed = 1 ]; then
    for c in worldserver authserver loadgen; do grep -m 10 -E "Error|error" "$H/unittest/dub-$c.log"; done
    echo "FAIL: a release build failed"; exit 1
fi
# Each output must exist and be runnable before the regression starts.
for c in worldserver authserver loadgen; do
    [ -s "bin/$c" ] || { echo "FAIL: bin/$c is missing after its build"; exit 1; }
    chmod +x "bin/$c"
done
echo "built"
[ "$1" = "--quick" ] && { echo "PASS (quick: no regression)"; exit 0; }
echo "== spells a player can learn, against what the server does"
db_start || exit 1
python3 "$REPO/tools/harness/spell-audit.py" env LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" "$MARIADB_ROOT/usr/bin/mariadb" \
    -S "$SOCK" -u root classicmangos -- "$CLIENT_DATA/dbc" || { echo "FAIL: a learnable spell does what the server does not"; exit 1; }
echo "== spells on the real data (dmangos.world.realspelltests, and the sweep of every learnable spell:"
echo "   dmangos.world.realspellsweep, its known failures in tools/harness/realspell-known.txt; and of every spell"
echo "   a creature casts: dmangos.world.realnpcsweep, its known failures in tools/harness/realnpc-known.txt)"
if ! DMANGOS_REAL_DATA="$CLIENT_DATA|$MYSQL_LIB|$(db_info classicmangos)" "$H/unittest/test" > "$H/unittest/real.log" 2>&1; then
    grep -m 10 -E "Error@|Exception@|realspellsweep: FAILS|realnpcsweep: FAILS" "$H/unittest/real.log"
    echo "FAIL: a spell on the real data"; exit 1
fi
grep "^realspellsweep:" "$H/unittest/real.log"
grep -E "^realnpcsweep: ([0-9]|passes now)" "$H/unittest/real.log"
echo "== cluster regression"
sh "$REPO/tools/harness/regression.sh"
