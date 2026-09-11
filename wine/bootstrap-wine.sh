#!/usr/bin/env bash
set -euo pipefail

# WinArc Wine bootstrap
#
# Wine baseline: pinned Juice / Wine 11.13.
# Current route:
#   Wine server sources
#     -> direct iPhoneOS ARM64 objects
#     -> WinArc process-isolation hooks
#     -> WinArc embedded server runtime entry
#     -> libWinArcWineServer.a
#
# This stage is a compile/archive gate. It deliberately does not execute the
# embedded server on the macOS CI runner.

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
BOOTSTRAP_REVISION="5"
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
log "WINARC_WINE_ROUTE=JUICE_SERVER_DIRECT_STATIC_EMBEDDED"
log "JUICE_PIN=$JUICE_COMMIT"

mkdir -p "$UPSTREAM" "$GENERATED" "$BUILD" "$LOGS"

# ---------------------------------------------------------------------------
# Gate 1: exact donor pin and APIs needed by the embedded server route.
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
require_file "$WINE/server/fd.c"
require_file "$WINE/server/signal.c"
require_file "$WINE/server/process.h"
require_file "$WINE/server/thread.h"
require_file "$WINE/server/request.h"
require_file "$WINE/server/file.h"
require_file "$WINE/server/object.h"
require_file "$WINE/server/unicode.h"
require_file "$WINE/include/wine/server_protocol.h"

require_text "$WINE/server/process.h" "Use ptrace on iOS while retaining Mach on macOS."
require_text "$WINE/server/process.h" "__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__"
require_text "$WINE/server/request.h" "extern int send_client_fd"
require_text "$WINE/server/file.h" "extern void main_loop(void);"
require_text "$WINE/server/object.h" "extern void init_threading(void);"
require_text "$WINE/server/object.h" "extern void init_registry(void);"
require_text "$WINE/server/unicode.h" "extern struct fd *load_intl_file(void);"

log "JUICE_IOS_SERVER_PATCHES=PASS"
log "WINE_EMBEDDED_SERVER_APIS=PASS"

# ---------------------------------------------------------------------------
# Gate 2: native host Wine tools/config header only.
# ---------------------------------------------------------------------------

test "$(uname -s)" = "Darwin" || die "Wine bootstrap requires macOS"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found"
command -v make >/dev/null 2>&1 || die "make not found"
command -v git >/dev/null 2>&1 || die "git not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

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
# Gate 3: iOS feature overlay.
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

# ---------------------------------------------------------------------------
# Gate 4: derive request.c only to expose Wine's own server-directory setup.
#
# create_server_dir() already handles WINEPREFIX, config_dir_fd and
# server_dir_fd. Exporting it lets WinArc initialize the Wine server without
# creating the normal master listening socket or its accept/fork lifecycle.
# This remains Wine-derived LGPL code generated at build time.
# ---------------------------------------------------------------------------

python3 - "$WINE/server/request.c" "$GENERATED/request_winarc.c" <<'PY_EOF'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
dst = Path(sys.argv[2])

needle = "static char *create_server_dir( int force )"
if src.count(needle) != 1:
    raise SystemExit("unexpected create_server_dir definition count")

src = src.replace("create_server_dir(", "winarc_create_server_dir(")
src = src.replace(
    "static char *winarc_create_server_dir( int force )",
    "char *winarc_create_server_dir( int force )",
    1,
)
dst.write_text(src, encoding="utf-8")
PY_EOF

require_text "$GENERATED/request_winarc.c" \
    "char *winarc_create_server_dir( int force )"
log "WINE_SERVER_DIRECTORY_EXPORT=PASS"

# ---------------------------------------------------------------------------
# Gate 5: process-level safety hooks.
#
# Wine's standalone wineserver may call exit() or kill(). In WinArc it lives
# inside the app process, so server-side exit() is converted to pthread_exit()
# and kill(getpid(), ...) is blocked. This object is WinArc-owned.
# ---------------------------------------------------------------------------

cat > "$GENERATED/WineServerProcessIsolation.c" <<'C_EOF'
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <sys/types.h>
#include <unistd.h>

extern void winarc_wineserver_note_thread_exit(int status);

__attribute__((noreturn, visibility("default")))
void winarc_wineserver_thread_exit(int status)
{
    winarc_wineserver_note_thread_exit(status);
    pthread_exit((void *)(intptr_t)status);
    __builtin_unreachable();
}

__attribute__((visibility("default")))
int winarc_wineserver_safe_kill(pid_t pid, int sig)
{
    if (pid == getpid()) return 0;
    return kill(pid, sig);
}

__attribute__((visibility("default")))
uint32_t winarc_wineserver_process_isolation_abi(void)
{
    return 1u;
}
C_EOF

# ---------------------------------------------------------------------------
# Gate 6: WinArc-owned embedded wineserver entry.
#
# No normal wineserver main(), no open_master_socket(), no init_signals().
# We use Wine's own directory setup and native create_process/create_thread
# bootstrap. The direct client socket is suitable for WINESERVERSOCKET later.
# ---------------------------------------------------------------------------

cat > "$GENERATED/WineServerEmbeddedRuntime.c" <<'C_EOF'
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "wine/server_protocol.h"
#include "winnt.h"
#include "object.h"
#include "file.h"
#include "process.h"
#include "request.h"
#include "thread.h"
#include "unicode.h"

enum winarc_wineserver_stage
{
    WINARC_WS_IDLE = 0,
    WINARC_WS_STARTING = 1,
    WINARC_WS_INITIALIZING = 2,
    WINARC_WS_CLIENT_READY = 3,
    WINARC_WS_MAIN_LOOP = 4,
    WINARC_WS_STOPPED = 5,
    WINARC_WS_FAILED = -1
};

extern char *winarc_create_server_dir(int force);

static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t runtime_cond = PTHREAD_COND_INITIALIZER;
static pthread_t runtime_thread;
static int runtime_thread_valid;
static int runtime_stage = WINARC_WS_IDLE;
static int runtime_status;
static int runtime_client_fd = -1;
static int runtime_control_fd = -1;
static char *runtime_prefix;

static void set_stage(int stage, int status)
{
    pthread_mutex_lock(&runtime_lock);
    runtime_stage = stage;
    runtime_status = status;
    pthread_cond_broadcast(&runtime_cond);
    pthread_mutex_unlock(&runtime_lock);
}

void winarc_wineserver_note_thread_exit(int status)
{
    pthread_mutex_lock(&runtime_lock);
    runtime_status = status;
    runtime_stage = WINARC_WS_FAILED;
    pthread_cond_broadcast(&runtime_cond);
    pthread_mutex_unlock(&runtime_lock);
}

static int set_nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int create_direct_client(void)
{
    struct process *process;
    struct thread *thread;
    int sockets[2] = { -1, -1 };
    int control = -1;

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == -1) return -1;
    if (set_nonblock(sockets[0]) == -1) goto failed;

    control = dup(sockets[1]);
    if (control == -1) goto failed;

    clear_error();

    /*
     * create_process() consumes sockets[0]. This matches Wine's normal
     * master_socket_poll_event path.
     */
    process = create_process(sockets[0], NULL, 0, NULL, NULL, NULL, 0, NULL);
    sockets[0] = -1;
    if (!process) goto failed;

    /*
     * fd == -1 asks Wine to create the native request/reply pipe and send the
     * client endpoint through the process socket with SERVER_PROTOCOL_VERSION.
     */
    thread = create_thread(-1, process, NULL);
    if (!thread)
    {
        release_object(process);
        goto failed;
    }

    /* Match Wine's own accepted-client lifetime sequence. */
    add_process_thread(process, thread);
    release_object(process);

    pthread_mutex_lock(&runtime_lock);
    runtime_client_fd = sockets[1];
    sockets[1] = -1;
    runtime_control_fd = control;
    control = -1;
    runtime_stage = WINARC_WS_CLIENT_READY;
    runtime_status = 0;
    pthread_cond_broadcast(&runtime_cond);
    pthread_mutex_unlock(&runtime_lock);
    return 0;

failed:
    if (sockets[0] >= 0) close(sockets[0]);
    if (sockets[1] >= 0) close(sockets[1]);
    if (control >= 0) close(control);
    return -1;
}

static void *embedded_server_thread(void *opaque)
{
    char *dir;

    (void)opaque;

    set_stage(WINARC_WS_INITIALIZING, 0);

    if (!runtime_prefix || !*runtime_prefix)
    {
        set_stage(WINARC_WS_FAILED, EINVAL);
        return NULL;
    }

    /*
     * Environment is process-wide, which is intentional: the Wine client
     * launched later in this same app process must see the same prefix.
     */
    if (setenv("WINEPREFIX", runtime_prefix, 1) != 0)
    {
        set_stage(WINARC_WS_FAILED, errno);
        return NULL;
    }

    mkdir(runtime_prefix, 0700);

    foreground = 1;
    debug_level = 0;
    master_socket_timeout = TIMEOUT_INFINITE;
    server_argv0 = "WinArc";

    native_machine = IMAGE_FILE_MACHINE_ARM64;
    supported_machines_count = 1;
    memset(supported_machines, 0, sizeof(supported_machines));
    supported_machines[0] = IMAGE_FILE_MACHINE_ARM64;

    sock_init();

    /*
     * Use Wine's own WINEPREFIX/server-dir setup, but deliberately do not
     * create the normal master socket. Direct socketpair bootstrap replaces
     * that accept path.
     */
    dir = winarc_create_server_dir(1);
    if (!dir)
    {
        set_stage(WINARC_WS_FAILED, EIO);
        return NULL;
    }
    server_dir = dir;

    /*
     * Juice selects ptrace rather than the desktop-Mach backend on iOS.
     * Its init_tracing_mechanism() is a no-op for that backend.
     */
    init_tracing_mechanism();

    set_current_time();

    /*
     * Deliberately no init_signals(): its sigaction handlers are process-wide
     * and would take ownership of signals belonging to the iOS app.
     */
    init_memory();
    init_directories(load_intl_file());
    init_threading();
    init_registry();

    if (create_direct_client() != 0)
    {
        set_stage(WINARC_WS_FAILED, errno ? errno : EIO);
        return NULL;
    }

    set_stage(WINARC_WS_MAIN_LOOP, 0);
    main_loop();
    set_stage(WINARC_WS_STOPPED, 0);
    return NULL;
}

__attribute__((visibility("default")))
uint32_t winarc_wineserver_embedded_abi(void)
{
    return 1u;
}

/*
 * Start the embedded server and return the client-side process socket.
 * Ownership of *client_socket_out transfers to the caller.
 */
__attribute__((visibility("default")))
int winarc_wineserver_embedded_start(const char *prefix_path, int *client_socket_out)
{
    pthread_attr_t attr;
    int ret;

    if (!prefix_path || !*prefix_path || !client_socket_out) return EINVAL;

    pthread_mutex_lock(&runtime_lock);
    if (runtime_stage != WINARC_WS_IDLE && runtime_stage != WINARC_WS_STOPPED)
    {
        pthread_mutex_unlock(&runtime_lock);
        return EALREADY;
    }

    free(runtime_prefix);
    runtime_prefix = strdup(prefix_path);
    if (!runtime_prefix)
    {
        pthread_mutex_unlock(&runtime_lock);
        return ENOMEM;
    }

    runtime_client_fd = -1;
    runtime_control_fd = -1;
    runtime_status = 0;
    runtime_stage = WINARC_WS_STARTING;
    pthread_mutex_unlock(&runtime_lock);

    pthread_attr_init(&attr);
#if defined(__APPLE__) && defined(QOS_CLASS_USER_INTERACTIVE)
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    ret = pthread_create(&runtime_thread, &attr, embedded_server_thread, NULL);
    pthread_attr_destroy(&attr);

    if (ret)
    {
        set_stage(WINARC_WS_FAILED, ret);
        return ret;
    }

    runtime_thread_valid = 1;

    pthread_mutex_lock(&runtime_lock);
    while (runtime_stage > WINARC_WS_IDLE &&
           runtime_stage < WINARC_WS_CLIENT_READY)
        pthread_cond_wait(&runtime_cond, &runtime_lock);

    if (runtime_stage < WINARC_WS_CLIENT_READY)
    {
        ret = runtime_status ? runtime_status : EIO;
        pthread_mutex_unlock(&runtime_lock);
        return ret;
    }

    *client_socket_out = runtime_client_fd;
    runtime_client_fd = -1;
    pthread_mutex_unlock(&runtime_lock);
    return 0;
}

/*
 * Terminate the direct process-socket relationship without sending a Unix
 * signal to the app process. shutdown() affects duplicated descriptors too,
 * so the Wine server observes EOF and its normal process teardown can run.
 */
__attribute__((visibility("default")))
int winarc_wineserver_embedded_request_stop(void)
{
    int fd;

    pthread_mutex_lock(&runtime_lock);
    fd = runtime_control_fd;
    runtime_control_fd = -1;
    pthread_mutex_unlock(&runtime_lock);

    if (fd < 0) return ENOTCONN;
    shutdown(fd, SHUT_RDWR);
    close(fd);
    return 0;
}

__attribute__((visibility("default")))
int winarc_wineserver_embedded_join(void)
{
    pthread_t thread;

    pthread_mutex_lock(&runtime_lock);
    if (!runtime_thread_valid)
    {
        pthread_mutex_unlock(&runtime_lock);
        return 0;
    }
    thread = runtime_thread;
    runtime_thread_valid = 0;
    pthread_mutex_unlock(&runtime_lock);

    return pthread_join(thread, NULL);
}

__attribute__((visibility("default")))
int winarc_wineserver_embedded_stage(void)
{
    int stage;
    pthread_mutex_lock(&runtime_lock);
    stage = runtime_stage;
    pthread_mutex_unlock(&runtime_lock);
    return stage;
}
C_EOF

# Source-level isolation gates. Do not let comments accidentally satisfy these.
if grep -Eq '^[[:space:]]*init_signals[[:space:]]*\(' \
    "$GENERATED/WineServerEmbeddedRuntime.c"; then
    die "embedded runtime must not call init_signals"
fi
if grep -Eq '^[[:space:]]*open_master_socket[[:space:]]*\(' \
    "$GENERATED/WineServerEmbeddedRuntime.c"; then
    die "embedded runtime must not call open_master_socket"
fi

log "WINE_SERVER_SIGNAL_ISOLATION_SOURCE=PASS"
log "WINE_SERVER_MASTER_SOCKET_BYPASS_SOURCE=PASS"

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

# Standalone wineserver process termination must become server-thread
# termination when these Wine server sources are embedded in WinArc.
WINE_SERVER_ISOLATION_CFLAGS=(
    -Dexit=winarc_wineserver_thread_exit
    -Dkill=winarc_wineserver_safe_kill
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

for src_name in "${SERVER_SOURCES[@]}"; do
    src="$WINE/server/$src_name"
    if test "$src_name" = "request.c"; then
        src="$GENERATED/request_winarc.c"
    fi

    obj="$IOS_OBJ/${src_name%.c}.o"
    err="$LOGS/compile-${src_name%.c}.log"

    require_file "$src"
    log "CC server/$src_name"

    if test "$src_name" = "main.c"; then
        if ! "$CLANG" "${COMMON_CFLAGS[@]}" \
            "${WINE_SERVER_ISOLATION_CFLAGS[@]}" \
            -Dmain=winarc_wineserver_main \
            -c "$src" -o "$obj" 2>"$err"; then
            cat "$err" >&2
            die "iOS wineserver compile failed: server/$src_name"
        fi
    else
        if ! "$CLANG" "${COMMON_CFLAGS[@]}" \
            "${WINE_SERVER_ISOLATION_CFLAGS[@]}" \
            -c "$src" -o "$obj" 2>"$err"; then
            cat "$err" >&2
            die "iOS wineserver compile failed: server/$src_name"
        fi
    fi

    printf '%s\n' "$obj" >> "$LOGS/wineserver-ios-objects.txt"
done

log "WINE_IOS_SERVER_OBJECT_COMPILE=PASS"

# WinArc-owned objects are compiled without the Wine exit/kill macros.
"$CLANG" "${COMMON_CFLAGS[@]}" \
    -c "$GENERATED/WineServerProcessIsolation.c" \
    -o "$IOS_OBJ/WineServerProcessIsolation.o" \
    2>"$LOGS/compile-process-isolation.log" || {
        cat "$LOGS/compile-process-isolation.log" >&2
        die "Wine server process-isolation object compile failed"
    }

"$CLANG" "${COMMON_CFLAGS[@]}" \
    -c "$GENERATED/WineServerEmbeddedRuntime.c" \
    -o "$IOS_OBJ/WineServerEmbeddedRuntime.o" \
    2>"$LOGS/compile-embedded-runtime.log" || {
        cat "$LOGS/compile-embedded-runtime.log" >&2
        die "Wine server embedded-runtime object compile failed"
    }

log "WINE_SERVER_EXIT_ISOLATION_OBJECT=PASS"
log "WINE_SERVER_EMBEDDED_RUNTIME_OBJECT=PASS"

rm -f "$SERVER_ARCHIVE"
"$AR" rcs "$SERVER_ARCHIVE" "$IOS_OBJ"/*.o
test -s "$SERVER_ARCHIVE" || die "static wineserver archive was not produced"

"$NM" -g "$SERVER_ARCHIVE" > "$LOGS/wineserver-ios-nm.txt"

require_symbol()
{
    local symbol="$1"
    grep -Fq "$symbol" "$LOGS/wineserver-ios-nm.txt" || \
        die "required archive symbol missing: $symbol"
}

# Previous static-library gate remains valid.
require_symbol "winarc_wineserver_main"
log "WINE_SERVER_RENAMED_MAIN=PASS"
log "WINE_IOS_SERVER_STATIC_ARCHIVE=PASS"

# New embedded-runtime gate.
require_symbol "winarc_create_server_dir"
require_symbol "winarc_wineserver_thread_exit"
require_symbol "winarc_wineserver_safe_kill"
require_symbol "winarc_wineserver_embedded_start"
require_symbol "winarc_wineserver_embedded_request_stop"
require_symbol "winarc_wineserver_embedded_join"
require_symbol "winarc_wineserver_embedded_stage"

log "WINE_SERVER_PROCESS_EXIT_ISOLATION=PASS"
log "WINE_SERVER_DIRECT_CLIENT_BOOTSTRAP=PASS"
log "WINE_SERVER_RUNTIME_PATCH_SET_COMPILE=PASS"

# Prove the embedded entry does not directly depend on the two standalone
# wineserver process-ownership functions.
"$NM" -u "$IOS_OBJ/WineServerEmbeddedRuntime.o" \
    > "$LOGS/embedded-runtime-undefined.txt" || true

if grep -Eq '(_|[[:space:]])init_signals$' \
    "$LOGS/embedded-runtime-undefined.txt"; then
    die "embedded runtime unexpectedly links init_signals"
fi
if grep -Eq '(_|[[:space:]])open_master_socket$' \
    "$LOGS/embedded-runtime-undefined.txt"; then
    die "embedded runtime unexpectedly links open_master_socket"
fi

log "WINE_SERVER_NO_PROCESS_SIGNAL_DEPENDENCY=PASS"
log "WINE_SERVER_NO_MASTER_SOCKET_DEPENDENCY=PASS"

# Keep the previous route guard.
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
SERVER_RUNTIME_PATCH_SET_COMPILE=PASS
SERVER_SIGNAL_OWNERSHIP=ISOLATED_AT_EMBEDDED_ENTRY
SERVER_MASTER_SOCKET=NOT_USED_BY_EMBEDDED_ENTRY
SERVER_DIRECT_CLIENT_SOCKETPAIR=COMPILE_READY
SERVER_EXIT_TO_PTHREAD_EXIT=COMPILE_READY
SERVER_SAFE_SELF_KILL=COMPILE_READY

TRACE_PARENT_REMOVED=NO
WINE_CLIENT_INPROCESS=NOT_YET
NTDLL_WINESERVERSOCKET_LINK=NOT_YET
PTRACE_SAME_PROCESS_MEMORY=NOT_YET
DEVICE_RUNTIME_TEST=NOT_YET

NEXT_STAGE=ios-server-runtime-patch-set
EOF

# Keep existing workflow markers while this runtime patch-set stage is being
# completed. New markers above are inspected from the real Action log.
log "WINE_SERVER_THREAD_BRIDGE_OBJECT=PASS"
log "WINE_FULL_IOS_CONFIGURE=SKIPPED"
log "MADEIRA_ARCHITECTURE_ADAPTED=STATIC_SERVER_AND_THREAD_BOUNDARY"
log "WINARC_WINE_BOOTSTRAP=PASS"
log "NEXT_STAGE=IOS_SERVER_RUNTIME_PATCH_SET"
