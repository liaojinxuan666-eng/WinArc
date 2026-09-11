#!/usr/bin/env bash
set -euo pipefail

# WinArc Wine bootstrap
# Direct iOS wineserver static-library route inspired by the architecture
# proven by Madeira, but implemented against the pinned Juice/Wine tree.
#
# Stage goal:
#   Juice Wine server sources -> iPhoneOS arm64 objects
#   -> libWinArcWineServer.a
#   -> compile a WinArc-owned pthread bridge object
#
# This stage intentionally does NOT run wineserver inside the app yet.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WINE_ROOT="$ROOT/wine"
UPSTREAM="$WINE_ROOT/upstream"
JUICE_DIR="$UPSTREAM/Juice"
WINE="$JUICE_DIR/wine"
GENERATED="$WINE_ROOT/generated"
BUILD="$WINE_ROOT/build"
LOGS="$BUILD/logs"
HOST_BUILD="$BUILD/wine-host-tools"
IOS_OBJ="$BUILD/wineserver-ios-obj"
SERVER_ARCHIVE="$BUILD/libWinArcWineServer.a"

JUICE_REPO="https://github.com/ExoCore-Kernel/Juice.git"
JUICE_COMMIT="c0de19d93064eac25f87524849e12bb2d49e9a4f"
BOOTSTRAP_REVISION="4"
MIN_IOS="${WINARC_WINE_MIN_IOS:-14.0}"
JOBS="${WINARC_JOBS:-2}"

die()
{
    echo "WINARC_WINE_BOOTSTRAP=FAIL"
    echo "ERROR=$*" >&2
    exit 1
}

require_file()
{
    test -f "$1" || die "missing required file: $1"
}

require_text()
{
    local file="$1"
    local text="$2"
    grep -Fq "$text" "$file" || die "required upstream marker missing: $text in $file"
}

log()
{
    printf '%s\n' "$*"
}

log "WINARC_COMPONENT=wine"
log "WINARC_WINE_BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION"
log "WINARC_WINE_ROUTE=JUICE_SERVER_DIRECT_STATIC"
log "JUICE_PIN=$JUICE_COMMIT"

mkdir -p "$UPSTREAM" "$GENERATED" "$BUILD" "$LOGS"

# ---------------------------------------------------------------------------
# Gate 1: pin the exact donor and verify the iOS-specific Wine server work
# we depend on is present before compiling anything.
# ---------------------------------------------------------------------------

if test ! -d "$JUICE_DIR/.git"; then
    rm -rf "$JUICE_DIR"
    git clone --filter=blob:none "$JUICE_REPO" "$JUICE_DIR"
fi

git -C "$JUICE_DIR" fetch --quiet origin "$JUICE_COMMIT"
git -C "$JUICE_DIR" checkout --quiet --detach "$JUICE_COMMIT"
git -C "$JUICE_DIR" reset --quiet --hard "$JUICE_COMMIT"
git -C "$JUICE_DIR" clean -fdx >/dev/null

actual="$(git -C "$JUICE_DIR" rev-parse HEAD)"
test "$actual" = "$JUICE_COMMIT" || die "pinned Juice commit mismatch: $actual"

require_file "$WINE/server/Makefile.in"
require_file "$WINE/server/main.c"
require_file "$WINE/server/request.c"
require_file "$WINE/server/process.h"
require_file "$WINE/include/wine/server_protocol.h"
require_file "$WINE/include/config.h.in"

# Juice already carries an iOS-specific tracing split. We preserve that work;
# this prevents accidentally compiling the macOS Mach tracing backend for iOS.
require_text "$WINE/server/process.h" "Use ptrace on iOS while retaining Mach on macOS."
require_text "$WINE/server/process.h" "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__"

log "JUICE_IOS_SERVER_PATCHES=PASS"

# ---------------------------------------------------------------------------
# Gate 2: build only native host Wine tools/config headers.
# No aarch64-windows compiler and no full iOS Wine configure are required.
# ---------------------------------------------------------------------------

test "$(uname -s)" = "Darwin" || die "Wine bootstrap requires a macOS GitHub runner"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"
command -v make >/dev/null 2>&1 || die "make not found"
command -v git >/dev/null 2>&1 || die "git not found"

if command -v brew >/dev/null 2>&1; then
    BISON_BIN="$(brew --prefix bison 2>/dev/null || true)/bin"
    FLEX_BIN="$(brew --prefix flex 2>/dev/null || true)/bin"
    test -d "$BISON_BIN" && export PATH="$BISON_BIN:$PATH"
    test -d "$FLEX_BIN" && export PATH="$FLEX_BIN:$PATH"
fi

if test ! -f "$HOST_BUILD/include/config.h" || \
   test ! -x "$HOST_BUILD/tools/makedep" || \
   test ! -x "$HOST_BUILD/tools/winebuild/winebuild"; then
    rm -rf "$HOST_BUILD"
    mkdir -p "$HOST_BUILD"
    (
        cd "$HOST_BUILD"
        "$WINE/configure" \
            --enable-archs=none \
            --disable-tests \
            --without-mingw \
            --without-alsa \
            --without-capi \
            --without-coreaudio \
            --without-cups \
            --without-dbus \
            --without-ffmpeg \
            --without-fontconfig \
            --without-freetype \
            --without-gettext \
            --without-gphoto \
            --without-gnutls \
            --without-gssapi \
            --without-gstreamer \
            --without-krb5 \
            --without-netapi \
            --without-opencl \
            --without-opengl \
            --without-oss \
            --without-pcap \
            --without-pcsclite \
            --without-pulse \
            --without-sane \
            --without-sdl \
            --without-udev \
            --without-usb \
            --without-v4l2 \
            --without-vulkan \
            --without-wayland \
            --without-x \
            2>&1 | tee "$LOGS/wine-host-configure.log"
    )

    make -C "$HOST_BUILD" -j"$JOBS" __tooldeps__ \
        2>&1 | tee "$LOGS/wine-host-tools-build.log"
fi

require_file "$HOST_BUILD/include/config.h"
test -x "$HOST_BUILD/tools/makedep" || die "host makedep was not built"
test -x "$HOST_BUILD/tools/winebuild/winebuild" || die "host winebuild was not built"

log "WINE_HOST_HEADERS=PASS"
log "WINE_HOST_TOOLS=PASS"

# ---------------------------------------------------------------------------
# Gate 3: construct an iOS overlay on top of the generated macOS config.h.
# This is intentionally small. The source is still the Juice/Wine tree.
# ---------------------------------------------------------------------------

cat > "$GENERATED/winarc_wineserver_ios_config.h" <<'C_EOF'
#ifndef WINARC_WINESERVER_IOS_CONFIG_H
#define WINARC_WINESERVER_IOS_CONFIG_H

/* Start from Wine's generated Darwin feature set. */
#include "config.h"

/* These headers/APIs are macOS-only or unusable in a normal iOS app. */
#undef HAVE_SYS_USER_H
#undef HAVE_SYS_PTRACE_H
#undef HAVE_NETINET_TCP_FSM_H
#undef HAVE_NETINET_TCP_VAR_H
#undef HAVE_LIBPROCSTAT
#undef HAVE_PROCSTAT_OPEN_SYSCTL

#ifndef WINE_IOS
#define WINE_IOS 1
#endif

#endif
C_EOF

cat > "$GENERATED/WineServerThreadBridge.c" <<'C_EOF'
/*
 * WinArc-owned bridge object for the in-process wineserver architecture.
 * Runtime activation comes in the next stage; this gate only proves that the
 * server entry can live behind a pthread boundary inside an iOS binary.
 */
#include <errno.h>
#include <pthread.h>
#include <stdint.h>

extern int winarc_wineserver_main(int argc, char **argv);

static void *winarc_wineserver_thread_entry(void *opaque)
{
    (void)opaque;
    char arg0[] = "wineserver";
    char arg1[] = "--foreground";
    char *argv[] = { arg0, arg1, 0 };
    int rc = winarc_wineserver_main(2, argv);
    return (void *)(intptr_t)rc;
}

__attribute__((visibility("default")))
uint32_t winarc_wineserver_thread_bridge_abi(void)
{
    return 1u;
}

__attribute__((visibility("default")))
int winarc_wineserver_start_thread_for_gate(pthread_t *thread_out)
{
    if (!thread_out) return EINVAL;
    return pthread_create(thread_out, 0, winarc_wineserver_thread_entry, 0);
}
C_EOF

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
AR="$(xcrun --sdk iphoneos --find ar)"
NM="$(xcrun --sdk iphoneos --find nm)"
IOS_TARGET="arm64-apple-ios$MIN_IOS"

rm -rf "$IOS_OBJ"
mkdir -p "$IOS_OBJ"

COMMON_CFLAGS=(
    -target "$IOS_TARGET"
    -arch arm64
    -isysroot "$SDK"
    "-miphoneos-version-min=$MIN_IOS"
    -O2
    -fno-common
    -fvisibility=hidden
    -D__WINESRC__
    -DBINDIR=\"/usr/local/bin\"
    -DDATADIR=\"/usr/local/share\"
    -I"$GENERATED"
    -I"$HOST_BUILD/include"
    -I"$WINE/include"
    -I"$WINE/server"
    -include "$GENERATED/winarc_wineserver_ios_config.h"
    -Wno-deprecated-declarations
    -Wno-implicit-function-declaration
)

# Read the authoritative server source list from Wine itself instead of
# hard-coding a fork-specific list.
SERVER_SOURCES=()
while IFS= read -r src_name; do
    SERVER_SOURCES+=("$src_name")
done < <(
    sed -nE 's/^[[:space:]]*([a-z0-9_]+\.c)([[:space:]]*\\)?[[:space:]]*$/\1/p' \
        "$WINE/server/Makefile.in"
)

test "${#SERVER_SOURCES[@]}" -ge 35 || die "unexpectedly small wineserver source set: ${#SERVER_SOURCES[@]}"
log "WINE_IOS_SERVER_SOURCE_COUNT=${#SERVER_SOURCES[@]}"

: > "$LOGS/wineserver-ios-objects.txt"

for src_name in "${SERVER_SOURCES[@]}"; do
    src="$WINE/server/$src_name"
    obj="$IOS_OBJ/${src_name%.c}.o"
    require_file "$src"

    extra=()
    if test "$src_name" = "main.c"; then
        # Madeira's key structural idea: turn wineserver main() into a callable
        # symbol. WinArc uses its own symbol name and bridge implementation.
        extra+=( -Dmain=winarc_wineserver_main )
    fi

    log "CC server/$src_name"
    if ! "$CLANG" "${COMMON_CFLAGS[@]}" "${extra[@]}" -c "$src" -o "$obj" \
        2>"$LOGS/compile-${src_name%.c}.log"; then
        cat "$LOGS/compile-${src_name%.c}.log" >&2
        die "iOS wineserver compile failed: server/$src_name"
    fi
    printf '%s\n' "$obj" >> "$LOGS/wineserver-ios-objects.txt"
done

# Compile our own pthread boundary as a separate object, then package it with
# Wine's server objects. We deliberately do not execute it in CI.
"$CLANG" \
    -target "$IOS_TARGET" \
    -arch arm64 \
    -isysroot "$SDK" \
    "-miphoneos-version-min=$MIN_IOS" \
    -O2 -fvisibility=hidden \
    -c "$GENERATED/WineServerThreadBridge.c" \
    -o "$IOS_OBJ/WineServerThreadBridge.o" \
    2>"$LOGS/compile-thread-bridge.log" || {
        cat "$LOGS/compile-thread-bridge.log" >&2
        die "WinArc wineserver pthread bridge compile failed"
    }

log "WINE_SERVER_THREAD_BRIDGE_OBJECT=PASS"

rm -f "$SERVER_ARCHIVE"
"$AR" rcs "$SERVER_ARCHIVE" "$IOS_OBJ"/*.o

test -s "$SERVER_ARCHIVE" || die "static wineserver archive was not produced"

"$NM" -g "$SERVER_ARCHIVE" > "$LOGS/wineserver-ios-nm.txt"
grep -Fq "winarc_wineserver_main" "$LOGS/wineserver-ios-nm.txt" || \
    die "renamed wineserver entry symbol missing"
grep -Fq "winarc_wineserver_start_thread_for_gate" "$LOGS/wineserver-ios-nm.txt" || \
    die "WinArc pthread bridge symbol missing"

log "WINE_SERVER_RENAMED_MAIN=PASS"
log "WINE_IOS_SERVER_STATIC_ARCHIVE=PASS"

# Explicitly assert that the obsolete v3 route is gone from this bootstrap.
if grep -Fq -- '--host=aarch64-apple-ios' "$0"; then
    die "obsolete full iOS Wine configure route is still present"
fi

log "WINE_FULL_IOS_CONFIGURE=SKIPPED"
log "MADEIRA_ARCHITECTURE_ADAPTED=STATIC_SERVER_AND_THREAD_BOUNDARY"
log "WINARC_WINE_BOOTSTRAP=PASS"
log "NEXT_STAGE=IOS_SERVER_RUNTIME_PATCH_SET"
