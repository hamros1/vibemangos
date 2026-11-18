#!/bin/sh
# Starts or stops the harness's MariaDB:  tools/harness/db.sh start|stop|status
. "$(dirname "$0")/common.sh"
case "$1" in
    start) db_start && echo "running ($SOCK)";;
    stop) db_stop && echo stopped;;
    status) db_running && echo "running ($SOCK)" || echo stopped;;
    *) echo "usage: $0 start|stop|status" >&2; exit 2;;
esac
