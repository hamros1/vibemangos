#!/bin/sh
# The builds of tools/harness/check.sh, each run under the machine's build lock (common.sh, `with_build_lock`):
#   build.sh units          every module but the mains compiled with -unittest into $BUILD/unittest/obj
#   build.sh servers full   release builds of the three servers into bin/ (dub, `release-fast`)
#   build.sh servers fast   unoptimized builds of them into $BUILD/fastbin, in seconds, for chaos cases
. "$(dirname "$0")/common.sh"
cd "$REPO" || exit 1
U="$BUILD/unittest"

case "$1" in
units)
    # Each module compiled on its own, all at once (-allinst: each emits the template instances it uses, which
    # separate compilation needs): seconds, where one dmd for all of them took ten minutes. As many at once as
    # the free memory allows: each can take 4 GB.
    rm -rf "$U/obj" && mkdir -p "$U/obj"
    find source -name '*.d' ! -name main.d | xargs -P "${CHECK_JOBS:-$(jobs_for 4)}" -I{} \
        sh -c 'dmd -c -unittest -allinst -Isource -od="$1" -op "$2" > "$1/$(echo "$2" | tr / _).log" 2>&1' _ "$U/obj" {}
    ;;
servers)
    if [ "$2" = fast ]; then
        # Unoptimized: the optimizer alone takes minutes over the world server's largest module (context.d).
        mkdir -p "$BUILD/fastbin"
        files=$(find source -name '*.d' ! -path '*/auth/main.d' ! -path '*/extractor/*' ! -path '*/loadgen/main.d')
        dmd -release -version=Have_dmangos -Isource -of="$BUILD/fastbin/worldserver" $files thirdparty/build/libdmnav.a \
            -L-lstdc++ > "$U/fast-worldserver.log" 2>&1 || exit 1
        dmd -release -i=dmangos -version=Have_dmangos -Isource -of="$BUILD/fastbin/authserver" \
            source/dmangos/auth/main.d > "$U/fast-authserver.log" 2>&1 || exit 1
        dmd -release -i=dmangos -version=Have_dmangos -Isource -of="$BUILD/fastbin/loadgen" \
            source/dmangos/loadgen/main.d thirdparty/build/libdmnav.a -L-lstdc++ > "$U/fast-loadgen.log" 2>&1 || exit 1
        exit 0
    fi
    # `release-fast` optimizes without -inline. The world server is the only large build (about 3 minutes, 6 GB).
    for c in worldserver authserver loadgen; do
        dub build -q -c "$c" -b release-fast > "$U/dub-$c.log" 2>&1 || exit 1
    done
    for c in worldserver authserver loadgen; do
        [ -s "bin/$c" ] || { echo "bin/$c is missing after its build" >> "$U/dub-$c.log"; exit 1; }
        chmod +x "bin/$c"
    done
    ;;
*)
    echo "usage: build.sh units | servers full|fast" >&2; exit 2 ;;
esac
