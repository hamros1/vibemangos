# A sampling profiler for the world server where perf is not available, run inside gdb:
#
#   SAMPLE_OUT=samples.txt gdb -q -batch -x tools/gdb-sample.py --args bin/worldserver -c worldserver.json
#
# gdb runs the server as its child (so no ptrace permission is needed beyond that), and records the
# main thread's stack every time the server is interrupted from outside, e.g. ten times a second:
#
#   while kill -INT "$(pgrep -f '^/full/path/to/bin/worldserver')"; do sleep 0.1; done
#
# Create the file $SAMPLE_OUT.stop and interrupt once more to detach. Build the server with -g for
# function names. tools/gdb-summary.py counts the functions in the samples. docs/DEVELOPING.md has
# the whole recipe.
import gdb, os

out = open(os.environ["SAMPLE_OUT"], "w")
for sig in ("SIGPIPE", "SIGUSR1", "SIGUSR2"):
    gdb.execute("handle %s nostop noprint pass" % sig)
gdb.execute("handle SIGINT stop print nopass")
gdb.execute("set pagination off")
gdb.execute("run")
while True:
    if not gdb.selected_inferior().pid:
        break
    if os.path.exists(os.environ["SAMPLE_OUT"] + ".stop"):
        gdb.execute("detach")
        break
    try:
        gdb.execute("thread 1", to_string=True)
        out.write(gdb.execute("bt 40", to_string=True) + "\n----\n")
        out.flush()
    except gdb.error:
        pass
    try:
        gdb.execute("continue")
    except gdb.error:
        break
out.close()
