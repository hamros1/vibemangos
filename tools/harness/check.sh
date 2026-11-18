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
if ! dmd -unittest -main -Isource -od="$H/unittest/obj" -of="$H/unittest/test" \
        $(find source -name '*.d' ! -name main.d) thirdparty/build/libdmnav.a -L-lstdc++ > "$H/unittest/build.log" 2>&1; then
    grep -m 20 Error "$H/unittest/build.log"; echo "FAIL: the tests do not compile"; exit 1
fi
"$H/unittest/test" > "$H/unittest/run.log" 2>&1 || { tail -20 "$H/unittest/run.log"; echo "FAIL: unit tests"; exit 1; }
grep "modules passed unittests" "$H/unittest/run.log"
echo "== release builds"
for c in worldserver authserver loadgen; do
    dub build -q -c $c -b release > "$H/unittest/dub-$c.log" 2>&1 || { tail -20 "$H/unittest/dub-$c.log"; echo "FAIL: release build of $c"; exit 1; }
done
echo "built"
[ "$1" = "--quick" ] && { echo "PASS (quick: no regression)"; exit 0; }
echo "== cluster regression"
sh "$REPO/tools/harness/regression.sh"
