#!/usr/bin/env bash
set -euo pipefail

# WinArc Wine bootstrap
# Direct iOS wineserver static-library route.
#
# Juice/Wine remains the pinned Wine baseline.
# Madeira's architecture is used only as an implementation reference:
# wineserver becomes a static archive with a callable renamed entry point,
# while WinArc owns its pthread bridge and later runtime integration.

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
BOOTSTRAP_REVISION="4.2"
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
# Gate 1: exact donor pin + Juice iOS server changes.
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

require_text "$WINE/server/process.h" "Use ptrace on iOS while retaining Mach on macOS."
require_text "$WINE/server/process.h" "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__"

log "JUICE_IOS_SERVER_PATCHES=PASS"

# ---------------------------------------------------------------------------
# Gate 2: native macOS Wine tools/config header only.
# ---------------------------------------------------------------------------

test "$(uname -s)" = "Darwin" || die "Wine bootstrap requires macOS"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"
command -v make >/dev/null 2>&1 || die "make not found"
command -v git >/dev/null 2>&1 || die "git not found"

if command -v brew >/dev/null 2>&1; then
    BISON_PREFIX="$(brew --prefix bison 2>/dev/null || true)"
    FLEX_PREFIX="$(brew --prefix flex 2>/dev/null || true)"
    test -d "$BISON_PREFIX/bin" && export PATH="$BISON_PREFIX/bin:$PATH"
    test -d "$FLEX_PREFIX/bin" && export PATH="$FLEX_PREFIX/bin:$PATH"
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
# Gate 3: small iOS config overlay.
# ---------------------------------------------------------------------------

cat > "$GENERATED/winarc_wineserver_ios_config.h" <<'C_EOF'
#ifndef WINARC_WINESERVER_IOS_CONFIG_H
#define WINARC_WINESERVER_IOS_CONFIG_H

#include "config.h"

/* macOS-only or unavailable/unusable in a normal iOS app. */
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
#include <errno.h>
#include <pthread.h>
#include <stdint.h>

extern int winarc_wineserver_main(int argc, char **argv);

static void *winarc_wineserver_thread_entry(void *opaque)
{
    char arg0[] = "wineserver";
    char arg1[] = "--foreground";
    char *argv[] = { arg0, arg1, 0 };
    int rc;

    (void)opaque;
    rc = winarc_wineserver_main(2, argv);
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
    -include stdarg.h
    -Wno-deprecated-declarations
    -Wno-implicit-function-declaration
)

SERVER_SOURCES=()
while IFS= read -r src_name; do
    SERVER_SOURCES+=("$src_name")
done < <(
    sed -nE 's/^[[:space:]]*([a-z0-9_]+\.c)([[:space:]]*\\)?[[:space:]]*$/\1/p' \
        "$WINE/server/Makefile.in"
)

test "${#SERVER_SOURCES[@]}" -ge 35 || \
    die "unexpectedly small wineserver source set: ${#SERVER_SOURCES[@]}"

log "WINE_IOS_SERVER_SOURCE_COUNT=${#SERVER_SOURCES[@]}"
: > "$LOGS/wineserver-ios-objects.txt"

# Bash 3.2 + set -u does not safely expand an empty array. Do not use an
# optional `extra[@]` array here; compile main.c and normal sources explicitly.
for src_name in "${SERVER_SOURCES[@]}"; do
    src="$WINE/server/$src_name"
    obj="$IOS_OBJ/${src_name%.c}.o"
    err="$LOGS/compile-${src_name%.c}.log"

    require_file "$src"
    log "CC server/$src_name"

    if test "$src_name" = "main.c"; then
        if ! "$CLANG" "${COMMON_CFLAGS[@]}" \
            -Dmain=winarc_wineserver_main \
            -c "$src" -o "$obj" 2>"$err"; then
            cat "$err" >&2
            die "iOS wineserver compile failed: server/$src_name"
        fi
    else
        if ! "$CLANG" "${COMMON_CFLAGS[@]}" \
            -c "$src" -o "$obj" 2>"$err"; then
            cat "$err" >&2
            die "iOS wineserver compile failed: server/$src_name"
        fi
    fi

    printf '%s\n' "$obj" >> "$LOGS/wineserver-ios-objects.txt"
done

log "WINE_IOS_SERVER_OBJECT_COMPILE=PASS"

"$CLANG" \
    -target "$IOS_TARGET" \
    -arch arm64 \
    -isysroot "$SDK" \
    "-miphoneos-version-min=$MIN_IOS" \
    -O2 \
    -fvisibility=hidden \
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

# Guard against accidentally restoring v3's full iOS Wine configure route.
# Construct the pattern in pieces so the guard does not match its own source.
obsolete_host="$(printf '%s%s' '--host=aarch64-apple-' 'ios')"
if grep -Fq -- "$obsolete_host" "$0"; then
    die "obsolete full iOS Wine configure route is still present"
fi

cat > "$WINE_ROOT/BASELINE" <<EOF
WINARC_COMPONENT=wine
BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION
UPSTREAM=ExoCore-Kernel/Juice
UPSTREAM_COMMIT=$JUICE_COMMIT
WINE_VERSION=11.13
SERVER_ROUTE=direct-ios-static-archive
SERVER_ARCHIVE=libWinArcWineServer.a
TRACE_PARENT_REMOVED=NO
SERVER_RUNTIME_PATCH_SET=NOT_YET
WINE_CLIENT_INPROCESS=NOT_YET
NEXT_STAGE=ios-server-runtime-patch-set
EOF

log "WINE_FULL_IOS_CONFIGURE=SKIPPED"
log "MADEIRA_ARCHITECTURE_ADAPTED=STATIC_SERVER_AND_THREAD_BOUNDARY"
log "WINARC_WINE_BOOTSTRAP=PASS"
log "NEXT_STAGE=IOS_SERVER_RUNTIME_PATCH_SET"
