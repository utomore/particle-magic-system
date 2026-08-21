#!/bin/sh
# Run the out-of-process load smoke (host-runtime F006, M8).
#
#   test/oop/run.sh                  the library cabal just built
#   test/oop/run.sh <dir-or-file>    a packaging/pack.sh drop, or one .so
#
# Pointing it at a pack.sh drop is the interesting second mode: the drop
# carries its whole closure and searches $ORIGIN, so a green run there says
# an outside process can load the packaged library. That drop's own
# self-containment is packaging/pack.sh --verify's assertion, not this
# script's -- this one only proves it drives.
#
# cwd is forced to the repo root because the harness reads the spell file
# and the golden by their repo-relative paths. Exit code is the result.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

case $(uname -s) in
    Darwin) LIB_NAME=libparticle-magic-ffi.dylib ;;
    *)      LIB_NAME=libparticle-magic-ffi.so ;;
esac

TARGET=${1:-}
if [ -z "$TARGET" ]; then
    LIB=$(find "$REPO_ROOT/dist-newstyle" -type f -name "$LIB_NAME" 2>/dev/null | head -1)
    [ -n "$LIB" ] || {
        echo "run.sh: no $LIB_NAME under dist-newstyle -- run 'cabal build particle-magic-ffi' first" >&2
        exit 4
    }
elif [ -d "$TARGET" ]; then
    LIB="$TARGET/$LIB_NAME"
    [ -f "$LIB" ] || { echo "run.sh: no $LIB_NAME in $TARGET" >&2; exit 4; }
else
    LIB="$TARGET"
    [ -f "$LIB" ] || { echo "run.sh: no such library: $LIB" >&2; exit 4; }
fi

SMOKE=${OOP_SMOKE_OUT:-"$REPO_ROOT/test/oop/oop-smoke"}
if [ ! -x "$SMOKE" ] || [ "$REPO_ROOT/test/oop/oop_smoke.c" -nt "$SMOKE" ]; then
    "$REPO_ROOT/test/oop/build.sh"
fi

exec "$SMOKE" "$LIB" --all
