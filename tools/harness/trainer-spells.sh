#!/bin/sh
# Run the targeted 1.12.1 trainer audit using the native objects from check.sh.
set -eu
. "$(dirname "$0")/common.sh"
cd "$REPO"
if [ ! -x "$H/unittest/test" ]; then
    echo "Build the unit suite first with tools/harness/check.sh --quick" >&2
    exit 1
fi
db_start
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dmd -c -unittest -allinst -Isource -of="$work/probe.o" tools/harness/trainer_spell_probe.d
find "$H/unittest/obj" -name '*.o' > "$work/objects"
dmd -unittest -main -of="$work/test" "$work/probe.o" @"$work/objects" thirdparty/build/libdmnav.a -L-lstdc++
DMANGOS_REAL_DATA="$CLIENT_DATA|$MYSQL_LIB|$(db_info classicmangos)" "$work/test"
