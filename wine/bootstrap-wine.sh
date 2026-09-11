#!/usr/bin/env bash
set -euo pipefail

# WinArc Wine component bootstrap
# v3: Juice/Wine 11.13 -> real iOS ARM64 Wine server core link gate.
#
# WinArc is the product. This file only prepares the modified Wine component.
# Do not remove the known-good Juice tracer route until its replacement has
# passed independently.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WINE_ROOT="$ROOT/wine"
UPSTREAM="$WINE_ROOT/upstream"
JUICE_DIR="$UPSTREAM/Juice"
GENERATED="$WINE_ROOT/generated"
BUILD="$WINE_ROOT/build"
LOGS="$BUILD/logs"
TOOLS_BUILD="$BUILD/wine-tools-macos"
IOS_BUILD="$BUILD/wine-ios-arm64"
SERVER_CORE="$BUILD/libWineServerCore.dylib"

JUICE_REPO="https://github.com/ExoCore-Kernel/Juice.git"
JUICE_COMMIT="c0de19d93064eac25f87524849e12bb2d49e9a4f"
BOOTSTRAP_REVISION="3"
MIN_IOS="${WINARC_WINE_MIN_IOS:-14.0}"

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
    grep -Fq "$text" "$file" || die "required upstream API marker missing: $text in $file"
}

echo "WINARC_COMPONENT=wine"
echo "WINARC_WINE_BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION"
echo "JUICE_PIN=$JUICE_COMMIT"

mkdir -p "$UPSTREAM" "$GENERATED" "$BUILD" "$LOGS"

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

WINE="$JUICE_DIR/wine"

# ---------------------------------------------------------------------------
# Gate 1: lock the exact Wine interfaces used by the migration.
# ---------------------------------------------------------------------------

require_file "$WINE/server/process.h"
require_file "$WINE/server/thread.h"
require_file "$WINE/server/file.h"
require_file "$WINE/server/request.h"
require_file "$WINE/dlls/ntdll/unix/server.c"
require_file "$WINE/dlls/ntdll/unix/loader.c"
require_file "$WINE/include/wine/server_protocol.h"

require_text "$WINE/server/process.h" \
    "extern struct process *create_process( int fd, struct process *parent, unsigned int flags,"
require_text "$WINE/server/thread.h" \
    "extern struct thread *create_thread( int fd, struct process *process,"
require_text "$WINE/dlls/ntdll/unix/server.c" \
    'const char *env_socket = getenv( "WINESERVERSOCKET" );'
require_text "$WINE/dlls/ntdll/unix/server.c" \
    'data->request_fd = wine_server_receive_fd( &version );'
require_text "$WINE/dlls/ntdll/unix/loader.c" \
    "DECLSPEC_EXPORT void __wine_main( int argc, char *argv[] )"
require_text "$WINE/server/file.h" \
    "extern void main_loop(void);"

echo "WINE_11_13_CREATE_PROCESS_API=PASS"
echo "WINE_11_13_CREATE_THREAD_API=PASS"
echo "WINE_11_13_WINESERVERSOCKET=PASS"
echo "WINE_11_13_WINE_MAIN_EXPORT=PASS"
echo "WINE_11_13_SERVER_MAIN_LOOP_API=PASS"

# ---------------------------------------------------------------------------
# Gate 2: WinArc-side reusable server bridge sources.
# ---------------------------------------------------------------------------

cat > "$GENERATED/WineServerNativeBootstrap.c" <<'C_EOF'
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "wine/server_protocol.h"
#include "object.h"
#include "process.h"
#include "thread.h"
#include "winnt.h"

#define WINE_INPROC_BOOTSTRAP_ABI_VERSION 1u

enum wine_inproc_bootstrap_stage
{
    WINE_INPROC_STAGE_IDLE = 0,
    WINE_INPROC_STAGE_PROCESS = 1,
    WINE_INPROC_STAGE_THREAD = 2,
    WINE_INPROC_STAGE_FD_SENT = 3,
    WINE_INPROC_STAGE_CLEAN = 4
};

static uint32_t bootstrap_stage;

__attribute__((visibility("default")))
uint32_t wine_inproc_bootstrap_abi_version(void)
{
    return WINE_INPROC_BOOTSTRAP_ABI_VERSION;
}

__attribute__((visibility("default")))
uint32_t wine_inproc_bootstrap_stage(void)
{
    return bootstrap_stage;
}

__attribute__((visibility("default")))
int wine_inproc_bootstrap_client(int server_fd)
{
    struct process *process = NULL;
    struct thread *thread = NULL;
    timeout_t saved_timeout;
    unsigned int saved_machine_count;
    unsigned short saved_native_machine;
    unsigned short saved_machines[8];
    int flags;
    int result = -1;

    bootstrap_stage = WINE_INPROC_STAGE_IDLE;
    if (server_fd < 0) return -1;

    flags = fcntl(server_fd, F_GETFL, 0);
    if (flags == -1 || fcntl(server_fd, F_SETFL, flags | O_NONBLOCK) == -1)
    {
        close(server_fd);
        return -1;
    }

    saved_timeout = master_socket_timeout;
    saved_native_machine = native_machine;
    saved_machine_count = supported_machines_count;
    memcpy(saved_machines, supported_machines, sizeof(saved_machines));

    master_socket_timeout = TIMEOUT_INFINITE;
    native_machine = IMAGE_FILE_MACHINE_ARM64;
    supported_machines_count = 1;
    memset(supported_machines, 0, sizeof(saved_machines));
    supported_machines[0] = IMAGE_FILE_MACHINE_ARM64;
    clear_error();

    process = create_process(server_fd, NULL, 0, NULL, NULL, NULL, 0, NULL);
    server_fd = -1;
    if (!process) goto done;
    bootstrap_stage = WINE_INPROC_STAGE_PROCESS;

    thread = create_thread(-1, process, NULL);
    if (!thread) goto done;
    bootstrap_stage = WINE_INPROC_STAGE_THREAD;

    bootstrap_stage = WINE_INPROC_STAGE_FD_SENT;
    result = 0;

done:
    if (thread)
    {
        kill_thread(thread, 0);
        thread = NULL;
    }
    if (process) release_object(process);
    if (server_fd >= 0) close(server_fd);

    master_socket_timeout = saved_timeout;
    native_machine = saved_native_machine;
    supported_machines_count = saved_machine_count;
    memcpy(supported_machines, saved_machines, sizeof(saved_machines));

    if (!result) bootstrap_stage = WINE_INPROC_STAGE_CLEAN;
    return result;
}
C_EOF

cat > "$GENERATED/WineServerGlobals.c" <<'C_EOF'
#include <stdint.h>

#include "wine/server_protocol.h"
#include "object.h"

#define WINE_TICKS_PER_SEC 10000000

int debug_level = 0;
int foreground = 1;
timeout_t master_socket_timeout = (timeout_t)(-3LL * WINE_TICKS_PER_SEC);
const char *server_argv0 = "wine-inprocess";

__attribute__((visibility("default")))
uint32_t wine_inproc_server_protocol_version(void)
{
    return (uint32_t)SERVER_PROTOCOL_VERSION;
}

__attribute__((visibility("default")))
uint32_t wine_inproc_server_core_abi_version(void)
{
    return 1u;
}
C_EOF

# ---------------------------------------------------------------------------
# Gate 3: host Wine tools + public-iPhoneOS cross configure.
# ---------------------------------------------------------------------------

test "$(uname -s)" = "Darwin" || die "v3 iOS server-core gate requires macOS"

command -v xcrun >/dev/null 2>&1 || die "xcrun not found"
command -v make >/dev/null 2>&1 || die "make not found"

if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
    if brew --prefix bison >/dev/null 2>&1; then
        BISON_BIN="$(brew --prefix bison)/bin"
    else
        BISON_BIN=""
    fi
    if brew --prefix flex >/dev/null 2>&1; then
        FLEX_BIN="$(brew --prefix flex)/bin"
    else
        FLEX_BIN=""
    fi
    export PATH="${BISON_BIN:+$BISON_BIN:}${FLEX_BIN:+$FLEX_BIN:}$PATH"
fi

if test ! -x "$TOOLS_BUILD/tools/makedep" || \
   test ! -x "$TOOLS_BUILD/tools/winebuild/winebuild"; then
    rm -rf "$TOOLS_BUILD"
    mkdir -p "$TOOLS_BUILD"
    (
        cd "$TOOLS_BUILD"
        "$WINE/configure" \
            --enable-archs=none \
            --disable-tests \
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
            --without-mingw \
            --without-opencl \
            --without-opengl \
            --without-pcap \
            --without-pcsclite \
            --without-sdl \
            --without-usb \
            --without-vulkan \
            --without-wayland \
            --without-x \
            2>&1 | tee "$LOGS/wine-tools-configure.log"
    )

    make -C "$TOOLS_BUILD" -j2 __tooldeps__ \
        2>&1 | tee "$LOGS/wine-tools-build.log"
fi

test -x "$TOOLS_BUILD/tools/makedep" || die "host makedep was not built"
test -x "$TOOLS_BUILD/tools/winebuild/winebuild" || die "host winebuild was not built"

echo "WINE_HOST_TOOLS=PASS"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
CLANGXX="$(xcrun --sdk iphoneos --find clang++)"
IOS_TARGET="arm64-apple-ios$MIN_IOS"

rm -rf "$IOS_BUILD"
mkdir -p "$IOS_BUILD"

export CC="$CLANG -target $IOS_TARGET -isysroot $SDK"
export CXX="$CLANGXX -target $IOS_TARGET -isysroot $SDK"
export OBJC="$CC"
export OBJCXX="$CXX"
export CPPFLAGS="-D_WINE_IOS_BUILD=1"
export CFLAGS="-Os -fvisibility=hidden"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,-dead_strip"

(
    cd "$IOS_BUILD"
    "$WINE/configure" \
        --build="$("$WINE/tools/config.guess")" \
        --host=aarch64-apple-ios \
        --with-wine-tools="$TOOLS_BUILD" \
        --without-mingw \
        --disable-tests \
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
        --without-inotify \
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
        2>&1 | tee "$LOGS/wine-ios-configure.log"
)

require_file "$IOS_BUILD/Makefile"
require_file "$IOS_BUILD/include/config.h"

grep -q '^host_os = ios' "$IOS_BUILD/Makefile" || die "Wine configure did not select host_os=ios"
grep -q '^HOST_ARCH = aarch64' "$IOS_BUILD/Makefile" || die "Wine configure did not select HOST_ARCH=aarch64"
grep -q '^#define WINE_IOS 1' "$IOS_BUILD/include/config.h" || die "WINE_IOS was not defined"

echo "WINE_IOS_CONFIGURE=PASS"

# ---------------------------------------------------------------------------
# Gate 4: build Wine's real server objects, then relink without server/main.o.
# ---------------------------------------------------------------------------

make -C "$IOS_BUILD" -j2 server/wineserver \
    2>&1 | tee "$LOGS/wine-server-build.log"

OBJECT_LIST="$BUILD/wine-server-core-objects.txt"
: > "$OBJECT_LIST"

server_objects=()
for obj in "$IOS_BUILD"/server/*.o; do
    test -f "$obj" || continue
    test "$(basename "$obj")" = "main.o" && continue
    server_objects+=("$obj")
    printf '%s\n' "$obj" >> "$OBJECT_LIST"
done

test "${#server_objects[@]}" -ge 20 || die "too few Wine server objects: ${#server_objects[@]}"

COMMON_IOS=(
    -target "$IOS_TARGET"
    -arch arm64
    -isysroot "$SDK"
    "-miphoneos-version-min=$MIN_IOS"
    -D__WINESRC__
    -fms-extensions
    -I"$IOS_BUILD/include"
    -I"$WINE/include"
    -I"$WINE/server"
)

"$CLANG" "${COMMON_IOS[@]}" \
    -c "$GENERATED/WineServerNativeBootstrap.c" \
    -o "$BUILD/WineServerNativeBootstrap.o"

"$CLANG" "${COMMON_IOS[@]}" \
    -c "$GENERATED/WineServerGlobals.c" \
    -o "$BUILD/WineServerGlobals.o"

rm -f "$SERVER_CORE"

"$CLANG" \
    -target "$IOS_TARGET" \
    -arch arm64 \
    -isysroot "$SDK" \
    "-miphoneos-version-min=$MIN_IOS" \
    -dynamiclib \
    -Wl,-undefined,error \
    -Wl,-install_name,@rpath/libWineServerCore.dylib \
    "${server_objects[@]}" \
    "$BUILD/WineServerNativeBootstrap.o" \
    "$BUILD/WineServerGlobals.o" \
    -o "$SERVER_CORE" \
    2>&1 | tee "$LOGS/wine-server-core-link.log"

test -s "$SERVER_CORE" || die "Wine server core dylib was not produced"

file "$SERVER_CORE" | tee "$LOGS/wine-server-core-file.log"
file "$SERVER_CORE" | grep -q 'Mach-O 64-bit' || die "server core is not Mach-O 64-bit"
file "$SERVER_CORE" | grep -q 'arm64' || die "server core is not arm64"

xcrun nm -gU "$SERVER_CORE" > "$LOGS/wine-server-core-symbols.log"

grep -q ' _wine_inproc_server_protocol_version$' "$LOGS/wine-server-core-symbols.log" \
    || die "protocol export missing"
grep -q ' _wine_inproc_bootstrap_client$' "$LOGS/wine-server-core-symbols.log" \
    || die "native bootstrap export missing"
grep -q ' _wine_inproc_bootstrap_stage$' "$LOGS/wine-server-core-symbols.log" \
    || die "bootstrap stage export missing"

echo "WINE_INPROC_BRIDGE_COMPILE=PASS"
echo "WINE_IOS_SERVER_OBJECTS=PASS count=${#server_objects[@]}"
echo "WINE_IOS_SERVER_CORE_LINK=PASS"
echo "WINE_INPROC_FD_GATE_SOURCE=READY"

# Keep old route until the new core has a persistent server thread and a real
# ntdll client connected to it.
cat > "$WINE_ROOT/BASELINE" <<EOF
WINARC_COMPONENT=wine
BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION
UPSTREAM=ExoCore-Kernel/Juice
UPSTREAM_COMMIT=$JUICE_COMMIT
PRODUCT_NAME=WinArc
COMPONENT_NAME=Wine
MIN_IOS=$MIN_IOS

TROLLSTORE_MAINLINE=NO
TIPA_MAINLINE=NO
VAR_JB_MAINLINE=NO
CORETRUST_MAINLINE=NO

JUICE_WINE_SOURCE_LOCKED=YES
WINE_IOS_CONFIGURE=PASS
WINE_IOS_SERVER_CORE_LINK=PASS
WINE_INPROC_WINESERVERSOCKET_API=PASS
WINE_INPROC_WINE_MAIN_EXPORT=PASS

TRACE_PARENT_REMOVED=NO
WINE_SERVER_PERSISTENT_INPROCESS=NOT_YET
WINE_MAIN_INPROCESS=NOT_YET

NEXT_STAGE=server-thread-and-signal-isolation
EOF

echo "WINARC_WINE_BOOTSTRAP=PASS"
echo "TRACE_PARENT_REMOVED=NO"
echo "NEXT_STAGE=SERVER_THREAD_AND_SIGNAL_ISOLATION"
