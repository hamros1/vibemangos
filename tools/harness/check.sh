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
# `release-fast` (dub.json): optimized without -inline, which made DMD take ten minutes on context.d alone; the
# three at once. About 13% slower at run time (docs/BENCHMARKS.md): build `-b release` to measure speed.
for c in worldserver authserver loadgen; do
    dub build -q -c $c -b release-fast > "$H/unittest/dub-$c.log" 2>&1 &
done
failed=0
for job in $(jobs -p); do wait "$job" || failed=1; done
if [ $failed = 1 ]; then
    for c in worldserver authserver loadgen; do grep -m 10 -E "Error|error" "$H/unittest/dub-$c.log"; done
    echo "FAIL: a release build failed"; exit 1
fi
# The three wrote into bin/ at once: each must be there, whole and runnable, before anything starts it.
for c in worldserver authserver loadgen; do
    [ -s "bin/$c" ] || { echo "FAIL: bin/$c is missing after its build"; exit 1; }
    chmod +x "bin/$c"
done
echo "built"
[ "$1" = "--quick" ] && { echo "PASS (quick: no regression)"; exit 0; }
echo "== cluster regression"
sh "$REPO/tools/harness/regression.sh"
