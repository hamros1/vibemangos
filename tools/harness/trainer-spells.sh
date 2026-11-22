#!/bin/sh
# Run the 1.12.1 trainer audit (or broader mechanics audit with --gameplay) using the native objects from check.sh.
set -eu
. "$(dirname "$0")/common.sh"
case "$#:${1:-}" in
    0:) probe=trainer_spell_probe ;;
    1:--gameplay) probe=gameplay_probe ;;
    *) echo "usage: $0 [--gameplay]" >&2; exit 2 ;;
esac
cd "$REPO"
if [ ! -x "$H/unittest/test" ]; then
    echo "Build the unit suite first with tools/harness/check.sh --quick" >&2
    exit 1
fi
db_start
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dmd -c -unittest -allinst -Isource -of="$work/probe.o" "tools/harness/$probe.d"
find "$H/unittest/obj" -name '*.o' > "$work/objects"
dmd -unittest -main -of="$work/test" "$work/probe.o" @"$work/objects" thirdparty/build/libdmnav.a -L-lstdc++
if [ "$probe" = gameplay_probe ]; then
    # A private schema lets concurrent connections exercise real transactions without touching any account.
    audit_db="dmangos_gameplay_audit_$$"
    audit_sql() {
        LD_LIBRARY_PATH="$(dirname "$MYSQL_LIB")" "$MARIADB_ROOT/usr/bin/mariadb" -S "$SOCK" -u root -e "$1"
    }
    audit_sql "CREATE DATABASE $audit_db"
    trap 'audit_sql "DROP DATABASE $audit_db"; rm -rf "$work"' EXIT
    audit_sql "CREATE TABLE $audit_db.account_instances_entered LIKE classiccharacters.account_instances_entered"
    export DMANGOS_AUDIT_CHARACTERS="$(db_info "$audit_db")"
fi
DMANGOS_REAL_DATA="$CLIENT_DATA|$MYSQL_LIB|$(db_info classicmangos)" "$work/test"
