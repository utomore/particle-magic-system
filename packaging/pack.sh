#!/usr/bin/env bash
# pack.sh -- assemble the Linux (and, unverified, macOS) release drop.
# host-runtime F007, design.md C4.
#
# What a host receives is a folder, not a source tree. This script builds
# that folder out of what `cabal build particle-magic-ffi` already
# produced: the shared library, on Linux its entire shared-object closure,
# the C header, and a version file.
#
# Why Linux does not get Windows' `options: standalone`: standalone means
# "link the static way", and the ghcup bindist's static archives are not
# PIC, so ld refuses to put them in a shared object (measured 2026-08-20;
# adding -fPIC only moves the failure to the next prebuilt archive, and
# base/ghc-internal/rts cannot be rebuilt from here). The target is the
# same either way -- a host must not need a GHC installation, and must not
# depend on the distribution's libgmp/libffi -- so this script reaches it
# by shipping the closure beside the library and pointing the loader at
# $ORIGIN.
#
#   ./packaging/pack.sh                       # into dist/<platform-id>
#   ./packaging/pack.sh --out /tmp/drop
#   ./packaging/pack.sh --verify              # pack, then prove it is self-contained
#
# Exit code is the whole interface: 0 means the drop is complete and, with
# --verify, self-contained; anything else names the file or dependency at
# fault on stderr. CI consumes the code, not the message.

set -u

PROG=pack.sh

die() {
    printf '%s: %s\n' "$PROG" "$1" >&2
    exit "${2:-1}"
}

note() { printf '%s: %s\n' "$PROG" "$1"; }

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd) || die "cannot locate the repository root"
OUT=""
VERIFY=0
FAT_WITH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --out) [ $# -ge 2 ] || die "--out needs a directory" 2; OUT="$2"; shift 2 ;;
        --out=*) OUT="${1#--out=}"; shift ;;
        --fat-with) [ $# -ge 2 ] || die "--fat-with needs a dylib" 2; FAT_WITH="$2"; shift 2 ;;
        --fat-with=*) FAT_WITH="${1#--fat-with=}"; shift ;;
        --verify) VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

# ---------------------------------------------------------------- platform

UNAME_S=$(uname -s)
UNAME_M=$(uname -m)

case "$UNAME_S" in
    Linux)  PLATFORM_OS=linux;  LIB_NAME=libparticle-magic-ffi.so ;;
    Darwin) PLATFORM_OS=macos;  LIB_NAME=libparticle-magic-ffi.dylib ;;
    *) die "unsupported platform: $UNAME_S (this script covers Linux and macOS; Windows has packaging/pack.ps1)" 2 ;;
esac

case "$UNAME_M" in
    x86_64|amd64)  ARCH=x86_64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    *) die "unsupported architecture: $UNAME_M" 2 ;;
esac

PLATFORM_ID="$PLATFORM_OS-$ARCH"
[ -n "$OUT" ] || OUT="$REPO_ROOT/dist/$PLATFORM_ID"

if [ "$PLATFORM_OS" = macos ]; then
    note "macOS is NOT VERIFIED (F007 A3): the build settings and this branch are"
    note "written, but no macOS machine has produced or checked this drop."
fi

# ------------------------------------------------------------- inputs

HEADER="$REPO_ROOT/include/particle_magic.h"
CABAL="$REPO_ROOT/particle-magic.cabal"
[ -f "$HEADER" ] || die "missing header: $HEADER"
[ -f "$CABAL" ] || die "missing cabal file: $CABAL"

SRC_LIB=$(find "$REPO_ROOT/dist-newstyle" -type f -name "$LIB_NAME" 2>/dev/null | head -1)
[ -n "$SRC_LIB" ] || die "no $LIB_NAME under dist-newstyle -- run 'cabal build particle-magic-ffi' first"

rm -rf -- "$OUT"
mkdir -p -- "$OUT" || die "cannot create $OUT"

cp -- "$SRC_LIB" "$OUT/$LIB_NAME" || die "cannot copy $SRC_LIB"
chmod u+w "$OUT/$LIB_NAME"
cp -- "$HEADER" "$OUT/particle_magic.h" || die "cannot copy $HEADER"

# --------------------------------------------------- Linux: closure + rpath

# glibc's own core: deliberately NOT bundled. Shipping a copy of libc next
# to a host's own libc is how you get two allocators in one process.
GLIBC_CORE="libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 ld-linux-x86-64.so.2 linux-vdso.so.1"

is_glibc_core() {
    case " $GLIBC_CORE " in *" $1 "*) return 0 ;; esac
    return 1
}

collect_closure_linux() {
    local copied=0 name path
    # Resolved against the *build tree* copy, whose RUNPATH still has the
    # cabal store and ~/.ghcup in it -- that is exactly what makes the
    # closure discoverable here and unusable anywhere else.
    while read -r line; do
        case "$line" in *"=>"*) : ;; *) continue ;; esac
        name=$(printf '%s\n' "$line" | awk '{print $1}')
        path=$(printf '%s\n' "$line" | awk '{print $3}')
        is_glibc_core "$name" && continue
        [ -f "$path" ] || die "dependency $name did not resolve to a file (got '$path')"
        cp -L -- "$path" "$OUT/$name" || die "cannot copy dependency $name from $path"
        chmod u+w "$OUT/$name"
        copied=$((copied + 1))
    done <<EOF
$(ldd "$SRC_LIB")
EOF
    note "closure: $copied shared objects next to $LIB_NAME"
    [ "$copied" -gt 0 ] || die "closure is empty -- ldd resolved nothing, refusing to ship"
}

# Leave $ORIGIN as the only search path. The cabal file already appends
# -optl-Wl,-rpath,$ORIGIN, but cabal puts its own absolute entries first,
# so on the build machine the loader would still prefer the developer's
# store. patchelf does this properly when it is installed; without it we
# shorten the RUNPATH string in place, which is always safe because ELF
# strings are NUL-terminated and $ORIGIN is shorter than anything cabal
# wrote (this is what chrpath does, minus the dependency).
set_origin_rpath() {
    local lib="$1" rp off
    rp=$(readelf -d "$lib" 2>/dev/null | sed -n 's/.*Library runpath: \[\(.*\)\]/\1/p' | head -1)
    if [ -z "$rp" ]; then
        rp=$(readelf -d "$lib" 2>/dev/null | sed -n 's/.*Library rpath: \[\(.*\)\]/\1/p' | head -1)
    fi
    [ -n "$rp" ] || die "$lib has no RUNPATH to rewrite -- was it linked with -optl-Wl,-rpath,\$ORIGIN?"
    if [ "$rp" = '$ORIGIN' ]; then
        return 0
    fi
    if command -v patchelf >/dev/null 2>&1; then
        patchelf --set-rpath '$ORIGIN' "$lib" || die "patchelf failed on $lib"
        note "RUNPATH set to \$ORIGIN via patchelf"
        return 0
    fi
    off=$(grep -abo -F -- "$rp" "$lib" | head -1 | cut -d: -f1)
    [ -n "$off" ] || die "cannot locate the RUNPATH string inside $lib"
    printf '$ORIGIN\0' | dd of="$lib" bs=1 seek="$off" conv=notrunc status=none \
        || die "cannot rewrite the RUNPATH of $lib"
    rp=$(readelf -d "$lib" | sed -n 's/.*Library runpath: \[\(.*\)\]/\1/p' | head -1)
    [ "$rp" = '$ORIGIN' ] || die "RUNPATH rewrite did not take (still '$rp')"
    note "RUNPATH shortened to \$ORIGIN in place"
}

# ------------------------------------------------- macOS: install_name + fat
#
# NOT VERIFIED (F007 A3). The .dylib is linked with
# -install_name @rpath/libparticle-magic-ffi.dylib from the cabal file, so
# a host's own rpath decides where it is found. A universal binary is two
# builds joined: run this script on each machine and merge with
#   ./packaging/pack.sh --fat-with /path/from/the/other/arch/libparticle-magic-ffi.dylib
# which lipo -creates the two slices into the drop being built.
merge_fat_macos() {
    command -v lipo >/dev/null 2>&1 || die "lipo not found; cannot build a dual-architecture .dylib"
    [ -f "$FAT_WITH" ] || die "no such dylib to merge: $FAT_WITH"
    lipo -create "$OUT/$LIB_NAME" "$FAT_WITH" -output "$OUT/$LIB_NAME.fat" \
        || die "lipo -create failed"
    mv -- "$OUT/$LIB_NAME.fat" "$OUT/$LIB_NAME"
    note "merged a dual-architecture .dylib (x86_64 + arm64)"
}

if [ "$PLATFORM_OS" = linux ]; then
    collect_closure_linux
    set_origin_rpath "$OUT/$LIB_NAME"
else
    [ -n "$FAT_WITH" ] && merge_fat_macos
fi

# -------------------------------------------------------------- version file

PKG_VERSION=$(sed -n 's/^version:[[:space:]]*\([0-9.]*\).*$/\1/p' "$CABAL" | head -1)
[ -n "$PKG_VERSION" ] || die "no version: field in $CABAL"

ABI_VERSION=$(sed -n 's/^#define[[:space:]]\{1,\}PM_ABI_VERSION[[:space:]]\{1,\}\([0-9]\{1,\}\).*$/\1/p' "$HEADER" | head -1)
[ -n "$ABI_VERSION" ] || die "no PM_ABI_VERSION in $HEADER"

COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || COMMIT=""
[ -n "$COMMIT" ] || COMMIT=unknown

# --- pm-version.json BEGIN (field set is the contract: packaging/artifacts.json
# --- restates it and test/PackagingSpec.hs asserts the three agree) ---
cat > "$OUT/pm-version.json" <<EOF
{
  "package-version": "$PKG_VERSION",
  "abi-version": $ABI_VERSION,
  "platform": "$PLATFORM_ID",
  "commit": "$COMMIT"
}
EOF
# --- pm-version.json END ---
[ -s "$OUT/pm-version.json" ] || die "failed to write $OUT/pm-version.json"

note "packed $PLATFORM_ID into $OUT (package $PKG_VERSION, ABI $ABI_VERSION, commit $COMMIT)"

# ------------------------------------------------------------------- verify

verify_linux() {
    local lddout notfound outside probe_c probe_bin rc
    lddout="$OUT/.ldd.txt"
    # env -i: no LD_LIBRARY_PATH, no PATH, nothing this developer's shell
    # happens to export. What resolves here is what resolves on a host.
    env -i /usr/bin/ldd "$OUT/$LIB_NAME" > "$lddout" 2>&1 \
        || die "ldd failed on $OUT/$LIB_NAME"

    notfound=$(grep -c 'not found' "$lddout" || true)
    if [ "$notfound" != 0 ]; then
        printf '%s: %s unresolved dependencies:\n' "$PROG" "$notfound" >&2
        grep 'not found' "$lddout" >&2
        rm -f -- "$lddout"
        exit 3
    fi

    outside=$(grep '=>' "$lddout" | awk '{print $3}' | grep '^/' \
        | grep -v "^$OUT/" | sort -u)
    # glibc's core is the one thing a host is expected to already have.
    for lib in $outside; do
        base=$(basename "$lib")
        if ! is_glibc_core "$base"; then
            printf '%s: %s resolves outside the drop (%s)\n' "$PROG" "$base" "$lib" >&2
            printf '%s: the drop is not self-contained\n' "$PROG" >&2
            rm -f -- "$lddout"
            exit 3
        fi
    done
    rm -f -- "$lddout"
    note "closure is self-contained: 0 unresolved, 0 resolutions outside the drop"

    command -v cc >/dev/null 2>&1 || die "--verify needs a C compiler for the dlopen probe" 4
    probe_c="$OUT/.probe.c"
    probe_bin="$OUT/.probe"
    cat > "$probe_c" <<'PROBE'
/* Load the packaged library the way a host would -- from outside the
   build tree, with no Haskell linked in -- and drive enough of it to
   prove the RTS is alive, not merely that the file maps. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    void *h;
    void (*p_init)(void);
    void (*p_shutdown)(void);
    int (*p_abi)(void);
    int (*p_max)(void);

    if (argc < 2) { fprintf(stderr, "usage: probe <library>\n"); return 2; }
    h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    *(void **)(&p_init) = dlsym(h, "pm_init");
    *(void **)(&p_shutdown) = dlsym(h, "pm_shutdown");
    *(void **)(&p_abi) = dlsym(h, "pm_abi_version");
    *(void **)(&p_max) = dlsym(h, "pm_max_particles");
    if (!p_init || !p_shutdown || !p_abi || !p_max) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return 2;
    }

    p_init();
    printf("probe: abi=%d max_particles=%d\n", p_abi(), p_max());
    if (p_abi() != PM_EXPECT_ABI) {
        fprintf(stderr, "probe: ABI generation %d, expected %d\n", p_abi(), PM_EXPECT_ABI);
        return 3;
    }
    if (p_max() <= 0) { fprintf(stderr, "probe: max_particles %d\n", p_max()); return 3; }
    p_shutdown();
    return 0;
}
PROBE
    cc -O0 "-DPM_EXPECT_ABI=$ABI_VERSION" -o "$probe_bin" "$probe_c" -ldl \
        || die "cannot build the dlopen probe" 4
    env -i "$probe_bin" "$OUT/$LIB_NAME"
    rc=$?
    rm -f -- "$probe_c" "$probe_bin"
    [ "$rc" = 0 ] || die "the packaged library did not come up under dlopen (probe exit $rc)" 3
    note "dlopen probe passed in a clean environment"
}

verify_macos() {
    command -v otool >/dev/null 2>&1 || die "--verify needs otool on macOS" 4
    otool -L "$OUT/$LIB_NAME" || die "otool failed"
    note "macOS verification is NOT a pass/fail gate this round (F007 A3): the"
    note "install_name above is printed for a human, nothing is asserted."
}

if [ "$VERIFY" = 1 ]; then
    if [ "$PLATFORM_OS" = linux ]; then
        verify_linux
    else
        verify_macos
    fi
fi

exit 0
