#!/usr/bin/env bash
set -euo pipefail

# WinArc Wine bootstrap - Revision 9
#
# Transition build:
#   1) retain the verified Revision-6 gate as an optional safety check;
#   2) build ONLY Madeira's Wine dependency stack in an isolated build/reference
#      directory, pinned to an exact Madeira commit and exact Wine submodule SHA;
#   3) isolate server state and relocatably link the native archives.
#
# This does NOT turn WinArc into a Madeira fork. Nothing from Madeira's app/UI
# is copied into the WinArc source tree. The reference checkout is temporary
# build material and remains under wine/build/.
#
# IMPORTANT LICENSING BOUNDARY:
# Madeira's current Wine fork/reference modifications are GPL-3.0-or-later.
# These artifacts are for internal bring-up/reference only. They must not become
# WinArc's final distributable Wine base. The final WinArc Wine implementation
# is still to be reimplemented on the LGPL/compatible Wine/Juice baseline.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WINE_ROOT="$ROOT/wine"
BUILD="$WINE_ROOT/build"
LOGS="$BUILD/logs"
REF_SRC="$BUILD/madeira-wine-reference-src"
REF_OUT="$BUILD/madeira-wine-reference"

BOOTSTRAP_REVISION="9"

# Last known-good WinArc Wine boundary, used only as a transition safety gate.
REV6_COMMIT="f39dbcd7d7e745d271a5fb4f57e851723a892750"

# Pinned Madeira reference state.  This main commit pins its Wine submodule.
MADEIRA_REPO="https://github.com/arjunyerevan95-dot/Madeira.git"
MADEIRA_COMMIT="daabd75fc4b09ab32196a2eec010537bf018e108"
MADEIRA_WINE_COMMIT="7817e220384e895651f868ba4d97affcf21b3816"
MADEIRA_WINE_VERSION="11.4"

die()
{
    echo "WINARC_WINE_BOOTSTRAP=FAIL"
    echo "ERROR=$*" >&2
    exit 1
}

log()
{
    printf '%s\n' "$*"
}

require_file()
{
    test -f "$1" || die "missing required file: $1"
}

require_archive()
{
    local f="$1"
    test -s "$f" || die "missing/empty reference archive: $f"
}

mkdir -p "$BUILD" "$LOGS"

log "WINARC_COMPONENT=wine"
log "WINARC_WINE_BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION"
log "WINARC_WINE_ROUTE=INDEPENDENT_WINARC_WITH_MADEIRA_WINE_REFERENCE"
log "WINARC_PRODUCT_BASE=INDEPENDENT"
log "MADEIRA_ROLE=WINE_IOS_REFERENCE_ONLY"
log "MADEIRA_PIN=$MADEIRA_COMMIT"
log "MADEIRA_WINE_PIN=$MADEIRA_WINE_COMMIT"

# ---------------------------------------------------------------------------
# Gate 0: preserve the already-passing WinArc Wine work while we pivot.
#
# This is deliberately transitional.  Once the Madeira-Wine reference build is
# proven in WinArc CI, the workflow will stop rebuilding Revision 6 every run.
# ---------------------------------------------------------------------------

# Revision 8 already proved the transition. Keep its expensive legacy rebuild
# available explicitly; the normal gate now checks the current reference link.
if [[ "${WINARC_VERIFY_LEGACY:-0}" == 1 ]]; then
    REV6_SCRIPT="$WINE_ROOT/bootstrap-rev6.sh"

    git fetch --quiet origin "$REV6_COMMIT"
    git show "$REV6_COMMIT:wine/bootstrap-wine.sh" > "$REV6_SCRIPT"
    chmod +x "$REV6_SCRIPT"

    grep -Fq 'BOOTSTRAP_REVISION="6"' "$REV6_SCRIPT" || \
        die "pinned Revision 6 bootstrap marker missing"

    bash "$REV6_SCRIPT" | tee "$LOGS/revision6-transition-baseline.log"

    grep -Fq "WINARC_WINE_BOOTSTRAP=PASS" "$LOGS/revision6-transition-baseline.log" || \
        die "Revision 6 transition baseline failed"
    grep -Fq "WINE_CLIENT_INPROCESS_BRIDGE_COMPILE=PASS" \
        "$LOGS/revision6-transition-baseline.log" || \
        die "Revision 6 client/server boundary gate failed"

    log "WINARC_TRANSITION_BASELINE=PASS"

else
    log "WINARC_TRANSITION_BASELINE=SKIPPED_PREVIOUSLY_VERIFIED"
fi

# ---------------------------------------------------------------------------
# Gate 1: exact reference checkout.
#
# Clone the Madeira source only inside the build tree so we can execute its
# proven Wine-only CI recipe.  The WinArc tracked source remains independent.
# ---------------------------------------------------------------------------

rm -rf "$REF_SRC" "$REF_OUT"
mkdir -p "$REF_SRC" "$REF_OUT"

git -C "$REF_SRC" init -q
git -C "$REF_SRC" remote add origin "$MADEIRA_REPO"
git -C "$REF_SRC" fetch --quiet --depth 1 origin "$MADEIRA_COMMIT"
git -C "$REF_SRC" checkout --quiet --detach FETCH_HEAD

actual_madeira="$(git -C "$REF_SRC" rev-parse HEAD)"
test "$actual_madeira" = "$MADEIRA_COMMIT" || \
    die "Madeira reference commit mismatch: $actual_madeira"

require_file "$REF_SRC/.gitmodules"
require_file "$REF_SRC/scripts/ci-build-dependency.sh"
require_file "$REF_SRC/build/ntdll-unix/build.sh"
require_file "$REF_SRC/build/wineserver/build.sh"
require_file "$REF_SRC/build/win32u-unix/build.sh"

grep -Fq "git submodule update --init --depth 1 wine" \
    "$REF_SRC/scripts/ci-build-dependency.sh" || \
    die "Madeira Wine-only CI entry changed unexpectedly"

log "MADEIRA_REFERENCE_CHECKOUT=PASS"
log "MADEIRA_REFERENCE_SCOPE=WINE_DEPENDENCY_BUILD_ONLY"

# ---------------------------------------------------------------------------
# Gate 2: reproduce the proven Madeira Wine dependency build environment.
#
# Madeira's current GitHub CI uses macos-15 + Xcode 26.3 for this path.
# Require that exact Xcode when it is available on the hosted image.
# ---------------------------------------------------------------------------

if test -d /Applications/Xcode_26.3.app/Contents/Developer; then
    export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
else
    die "Xcode 26.3 is not installed on this runner"
fi

export HOMEBREW_NO_AUTO_UPDATE=1

command -v brew >/dev/null 2>&1 || die "Homebrew not available"
command -v xcrun >/dev/null 2>&1 || die "xcrun not available"

# The workflow already installs bison/flex.  Install only the additional tools
# used by Madeira's Wine-only dependency job.
brew install cmake ninja llvm gnutls pkg-config

xcodebuild -version | tee "$LOGS/madeira-reference-xcode.txt"

# Build only Madeira's `wine` dependency target.  This target builds the Wine
# host headers/tools, iOS wineserver, ntdll-unix, win32u-unix and Wine's native
# crypto/font dependencies.  It does NOT build Madeira's app, FEX or DXMT.
(
    cd "$REF_SRC"
    set -o pipefail
    bash scripts/ci-build-dependency.sh wine \
        2>&1 | tee "$LOGS/madeira-reference-wine-build.log"
)

# ---------------------------------------------------------------------------
# Gate 3: prove the exact Wine submodule and outputs we got.
# ---------------------------------------------------------------------------

test -d "$REF_SRC/wine/.git" || \
    test -f "$REF_SRC/wine/.git" || \
    die "Madeira Wine submodule was not initialized"

actual_wine="$(git -C "$REF_SRC/wine" rev-parse HEAD)"
test "$actual_wine" = "$MADEIRA_WINE_COMMIT" || \
    die "Madeira Wine submodule mismatch: $actual_wine"

require_file "$REF_SRC/wine/VERSION"
grep -Fq "Wine version $MADEIRA_WINE_VERSION" "$REF_SRC/wine/VERSION" || \
    die "unexpected Madeira Wine version"

SOURCE_LIB_DIR="$REF_SRC/app/Madeira"

REFERENCE_LIBS=(
    libwineserver.a
    libntdll_unix.a
    libwin32u_unix.a
    libgnutls.a
    libhogweed.a
    libnettle.a
    libgmp.a
)

for lib in "${REFERENCE_LIBS[@]}"; do
    require_archive "$SOURCE_LIB_DIR/$lib"
    cp "$SOURCE_LIB_DIR/$lib" "$REF_OUT/$lib"
done

log "MADEIRA_WINE_SUBMODULE_PIN=PASS"
log "MADEIRA_WINE_VERSION=$MADEIRA_WINE_VERSION"
log "MADEIRA_WINE_NATIVE_ARCHIVES=PASS"

# ---------------------------------------------------------------------------
# Gate 4: architecture and symbol sanity.
# ---------------------------------------------------------------------------

LIPO="$(xcrun --find lipo)"
NM="$(xcrun --find nm)"

: > "$LOGS/madeira-reference-archives.txt"

for lib in "${REFERENCE_LIBS[@]}"; do
    "$LIPO" -info "$REF_OUT/$lib" | tee -a "$LOGS/madeira-reference-archives.txt"
    "$LIPO" "$REF_OUT/$lib" -verify_arch arm64 || \
        die "reference archive is not ARM64: $lib"
done

"$NM" -g "$REF_OUT/libntdll_unix.a" \
    > "$LOGS/madeira-reference-ntdll-nm.txt"
"$NM" -g "$REF_OUT/libwineserver.a" \
    > "$LOGS/madeira-reference-wineserver-nm.txt"

grep -Fq "__wine_main" "$LOGS/madeira-reference-ntdll-nm.txt" || \
    die "Madeira reference ntdll archive lacks __wine_main"

log "MADEIRA_WINE_ARCH_ARM64=PASS"
log "MADEIRA_WINE_NTDLL_WINE_MAIN=PASS"

# ---------------------------------------------------------------------------
# Gate 5: isolate server/client globals before combining the native archives.
# Actual Revision-8 artifacts define these names on BOTH sides. Rename every
# server member, definitions AND references, without modifying the source pin.
# Use separate output paths so the original reference archives stay intact.
# ---------------------------------------------------------------------------

LINK_OUT="$BUILD/winarc-wine-reference-link"
rm -rf "$LINK_OUT"
mkdir -p "$LINK_OUT/server-objects"
for lib in "${REFERENCE_LIBS[@]}"; do
    cp "$REF_OUT/$lib" "$LINK_OUT/$lib"
done

OBJCOPY="$(brew --prefix llvm)/bin/llvm-objcopy"
test -x "$OBJCOPY" || die "llvm-objcopy is required for server state isolation"
AR="$(xcrun --find ar)"
(
    cd "$LINK_OUT/server-objects"
    "$AR" -x "$REF_OUT/libwineserver.a"
)
SERVER_STATE=(native_machine server_start_time supported_machines supported_machines_count)
RENAME_ARGS=()
for symbol in "${SERVER_STATE[@]}"; do
    RENAME_ARGS+=(--redefine-sym "_${symbol}=_ws_${symbol}")
done
for object in "$LINK_OUT/server-objects/"*.o; do
    "$OBJCOPY" "${RENAME_ARGS[@]}" "$object"
done
rm "$LINK_OUT/libwineserver.a"
"$AR" -rcs "$LINK_OUT/libwineserver.a" "$LINK_OUT/server-objects/"*.o
python3 "$WINE_ROOT/check-reference-archives.py" "$LINK_OUT" \
    --output "$LOGS/winarc-reference-link-audit.json"
log "WINARC_SERVER_CLIENT_STATE_ISOLATION=PASS"

# ---------------------------------------------------------------------------
# Gate 6: a real relocatable link, not merely ar concatenation. -all_load makes
# every member participate so duplicate definitions cannot stay hidden in an
# unused archive member. Unresolved host/UI/backend imports remain recorded;
# this object is NOT a runnable app and is NOT final-distribution material.
# ---------------------------------------------------------------------------

cat > "$LINK_OUT/WinArcWineReferenceBoundary.c" <<'BOUNDARY'
#include <stdint.h>
extern int wineserver_main(int argc, char **argv);
extern void __wine_main(int argc, char **argv);
struct winarc_wine_reference_boundary {
    uint32_t abi_version;
    uint32_t runtime_ready;
    int (*server_entry)(int, char **);
    void (*client_entry)(int, char **);
};
/* Expose real entry addresses for later integration; do not run Wine from a
 * constructor or claim that link success establishes process initialization. */
__attribute__((visibility("default")))
const struct winarc_wine_reference_boundary *winarc_wine_reference_get_boundary(void)
{
    static const struct winarc_wine_reference_boundary boundary = {
        1, 0, wineserver_main, __wine_main
    };
    return &boundary;
}
BOUNDARY

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK_PATH" \
    -miphoneos-version-min=17.0 -std=c11 -Wall -Wextra -Werror \
    -c "$LINK_OUT/WinArcWineReferenceBoundary.c" -o "$LINK_OUT/boundary.o"
LINK_INPUTS=()
for lib in "${REFERENCE_LIBS[@]}"; do LINK_INPUTS+=("$LINK_OUT/$lib"); done
xcrun --sdk iphoneos ld -r -arch arm64 \
    -platform_version ios 17.0 "$SDK_VERSION" \
    -all_load "$LINK_OUT/boundary.o" "${LINK_INPUTS[@]}" \
    -o "$LINK_OUT/WinArcWineReference.o" \
    2>&1 | tee "$LOGS/winarc-reference-relocatable-link.log"
"$LIPO" "$LINK_OUT/WinArcWineReference.o" -verify_arch arm64
"$NM" -g -U "$LINK_OUT/WinArcWineReference.o" > "$LOGS/winarc-reference-defined.txt"
for symbol in _winarc_wine_reference_get_boundary _wineserver_main ___wine_main _win32u_unix_lib_init; do
    awk '{print $NF}' "$LOGS/winarc-reference-defined.txt" | grep -Fx "$symbol" >/dev/null || \
        die "linked reference object lacks definition $symbol"
done
"$NM" -u "$LINK_OUT/WinArcWineReference.o" > "$LOGS/winarc-reference-unresolved.txt"
"$AR" -rcs "$LINK_OUT/libWinArcWineReference.a" "$LINK_OUT/WinArcWineReference.o"
tar -czf "$LOGS/WinArc-Wine-Reference-Link.tar.gz" -C "$LINK_OUT" \
    libWinArcWineReference.a WinArcWineReferenceBoundary.c
shasum -a 256 "$LOGS/WinArc-Wine-Reference-Link.tar.gz" \
    > "$LOGS/WinArc-Wine-Reference-Link.sha256"
log "WINARC_WINE_RELOCATABLE_LINK=PASS"
log "WINARC_WINE_EXECUTABLE_LINK=NOT_RUN"
log "WINARC_WINE_RUNTIME_EXECUTION=NOT_RUN"

# Keep a single tarball under logs so the current WinArc workflow uploads it
# without requiring a workflow edit during this transition.
REFERENCE_TARBALL="$LOGS/WinArc-Madeira-Wine-Reference.tar.gz"
tar -czf "$REFERENCE_TARBALL" -C "$REF_OUT" "${REFERENCE_LIBS[@]}"

shasum -a 256 "$REFERENCE_TARBALL" \
    > "$LOGS/WinArc-Madeira-Wine-Reference.sha256"

log "MADEIRA_WINE_REFERENCE_TARBALL=PASS"

# ---------------------------------------------------------------------------
# Boundary record.
# ---------------------------------------------------------------------------

cat > "$WINE_ROOT/BASELINE" <<EOF
WINARC_COMPONENT=wine
BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION

WINARC_PRODUCT_BASE=independent
WINARC_WINE_TRANSITION=madeira-wine-reference
MADEIRA_PRODUCT_BASE=NO
MADEIRA_APP_IMPORTED=NO
MADEIRA_UI_IMPORTED=NO

MADEIRA_REFERENCE_COMMIT=$MADEIRA_COMMIT
MADEIRA_WINE_COMMIT=$MADEIRA_WINE_COMMIT
MADEIRA_WINE_VERSION=$MADEIRA_WINE_VERSION
MADEIRA_WINE_REFERENCE_ONLY=YES
MADEIRA_WINE_DISTRIBUTABLE_WINARC_BASE=NO

REFERENCE_WINESERVER=libwineserver.a
REFERENCE_NTDLL=libntdll_unix.a
REFERENCE_WIN32U=libwin32u_unix.a
REFERENCE_NATIVE_ARCHIVES=PASS

FORMAL_WINARC_WINE_BASELINE=LGPL_COMPATIBLE_REIMPLEMENTATION_LATER
DXMT_FIRST_VERSION=PLANNED
D3DMETAL_BACKEND=PLANNED
ALLOYCORE=RETAINED

REFERENCE_RELOCATABLE_LINK=PASS
REFERENCE_EXECUTABLE_LINK=NOT_RUN
RUNTIME_EXECUTION=NOT_RUN
NEXT_STAGE=implement-host-boundary-and-strict-executable-link
EOF

log "WINARC_PRODUCT_INDEPENDENCE=PASS"
log "MADEIRA_APP_IMPORTED=NO"
log "MADEIRA_WINE_REFERENCE_ONLY=PASS"
log "WINARC_WINE_REFERENCE_BUILD=PASS"
log "WINARC_NEXT_ENGINEERING_STAGE=HOST_BOUNDARY_EXECUTABLE_LINK"
log "WINARC_WINE_BOOTSTRAP=PASS"
