#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
usage() {
    printf 'Usage: %s {install|export-world} WORLD.sql.gz [MariaDB connection options]\n' "$0" >&2
    printf '       %s apply-world-fixes [MariaDB connection options]\n' "$0" >&2
    exit 2
}
(( $# >= 1 )) || usage
operation=$1
shift

case "$operation" in
    install)
        (( $# >= 1 )) || usage
        world=$1
        shift
        # Check the compressed file before creating any databases.
        gzip -t -- "$world"
        {
            cat "$repo/sql/create-databases.sql"
            printf '\nUSE classicrealmd;\n'
            cat "$repo/sql/classicrealmd.sql"
            printf '\nUSE classiccharacters;\n'
            cat "$repo/sql/classiccharacters.sql"
            printf '\nUSE classicmangos;\n'
            gzip -dc -- "$world"
            printf '\nUSE classicmangos;\n'
            cat "$repo/sql/classic-world-fixes.sql"
        } | mariadb "$@" --batch --skip-force
        ;;
    apply-world-fixes)
        mariadb "$@" --batch --skip-force classicmangos < "$repo/sql/classic-world-fixes.sql"
        ;;
    export-world)
        (( $# >= 1 )) || usage
        world=$1
        shift
        # The game data is in classicmangos. Keep runtime-only tables as empty schemas.
        # The dump client takes read locks for the MyISAM tables, too.
        mkdir -p -- "$(dirname -- "$world")"
        temporary=$(mktemp -- "${world}.XXXXXX")
        trap 'rm -f -- "$temporary"' EXIT
        mariadb-dump "$@" --quick --lock-tables --no-tablespaces --skip-add-locks \
            --skip-add-drop-table --skip-dump-date \
            --ignore-table-data=classicmangos.auction \
            --ignore-table-data=classicmangos.bugreport \
            --ignore-table-data=classicmangos.spam_records \
            classicmangos | gzip -n > "$temporary"
        mv -- "$temporary" "$world"
        ;;
    *)
        echo "Unknown database operation: $operation" >&2
        exit 2
        ;;
esac
