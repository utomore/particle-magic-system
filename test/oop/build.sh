#!/bin/sh
# Build the out-of-process load smoke (host-runtime F006, M8).
#
# The harness is plain C and links no Haskell package. Two optional feature
# macros are decided here rather than written into the source, because both
# depend on what this machine has rather than on what the harness wants:
#
#   PM_OOP_WITH_RTS_HEADERS  the GHC rts include directory was found, so
#                            Rts.h can supply the LAYOUT of RTS_FLAGS and
#                            the rts-config probe can assert nursery and GC
#                            mode. Headers only -- the pointer still comes
#                            from dlsym on the loaded library.
#   PM_OOP_HAS_RTS_STATS     include/particle_magic.h has PmConfig.stats,
#                            so the probe can ask for runtime statistics.
#
# Exit code is the result. Prints the executable's path on success.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${OOP_SMOKE_OUT:-"$REPO_ROOT/test/oop/oop-smoke"}
SRC="$REPO_ROOT/test/oop/oop_smoke.c"
CC=${CC:-cc}

command -v "$CC" >/dev/null 2>&1 || {
    echo "build.sh: no C compiler (\$CC=$CC)" >&2
    exit 4
}

CFLAGS="-std=c99 -O1 -Wall -I$REPO_ROOT/include"
LDFLAGS="-ldl -lm"

# The rts include directory moved between GHC layouts; try both shapes.
RTS_INC=
if command -v ghc >/dev/null 2>&1; then
    LIBDIR=$(ghc --print-libdir 2>/dev/null || true)
    if [ -n "$LIBDIR" ]; then
        for cand in "$LIBDIR"/../rts-*/include "$LIBDIR"/rts-*/include \
                    "$LIBDIR"/*/rts-*/include "$LIBDIR"/include; do
            if [ -f "$cand/Rts.h" ]; then
                RTS_INC=$(CDPATH= cd -- "$cand" && pwd)
                break
            fi
        done
    fi
fi

if [ -n "$RTS_INC" ]; then
    CFLAGS="$CFLAGS -I$RTS_INC -DPM_OOP_WITH_RTS_HEADERS"
    echo "build.sh: RTS headers at $RTS_INC (nursery and GC mode assertable)"
else
    echo "build.sh: no Rts.h found -- rts-config will assert capabilities and statistics only"
fi

if grep -q 'uint32_t stats;' "$REPO_ROOT/include/particle_magic.h"; then
    CFLAGS="$CFLAGS -DPM_OOP_HAS_RTS_STATS"
    echo "build.sh: PmConfig.stats is in the header"
else
    echo "build.sh: no PmConfig.stats in the header -- statistics will not be requested"
fi

# shellcheck disable=SC2086
"$CC" $CFLAGS "$SRC" -o "$OUT" $LDFLAGS

echo "build.sh: $OUT"
