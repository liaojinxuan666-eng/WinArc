#!/usr/bin/env bash
set -euo pipefail

# WinArc / Wine component bootstrap
#
# Repository policy:
#   - WinArc is the product name.
#   - This directory is only the modified Wine component.
#   - Juice/Grape is used as the pinned upstream Wine/iOS base.
#   - TrollStore/TIPA/CoreTrust/rootless execution is not WinArc mainline.
#   - We do not remove Juice's known-good trace path until the in-process path
#     has independently passed its build/runtime gates.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WINE_ROOT="$ROOT/wine"
UPSTREAM="$WINE_ROOT/upstream"
JUICE_DIR="$UPSTREAM/Juice"
GENERATED="$WINE_ROOT/generated"
BUILD="$WINE_ROOT/build"

JUICE_REPO="https://github.com/ExoCore-Kernel/Juice.git"
JUICE_COMMIT="c0de19d93064eac25f87524849e12bb2d49e9a4f"
BOOTSTRAP_REVISION="2"

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

mkdir -p "$UPSTREAM" "$GENERATED" "$BUILD"

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
# Gate 1: prove that the specific Juice/Wine revision still exposes the exact
# upstream interfaces required by the in-process migration.
# ---------------------------------------------------------------------------

require_file "$WINE/server/process.h"
require_file "$WINE/server/thread.h"
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

echo "WINE_11_13_CREATE_PROCESS_API=PASS"
echo "WINE_11_13_CREATE_THREAD_API=PASS"
echo "WINE_11_13_WINESERVERSOCKET=PASS"
echo "WINE_11_13_WINE_MAIN_EXPORT=PASS"

# ---------------------------------------------------------------------------
# Gate 2: generate the first WinArc-side Wine bridge.
#
# This is intentionally based on the path already validated in the old
# WineIOS-Core work, but renamed and isolated from the WinArc product layer.
#
# Important: this is only the native Wine FD bootstrap. It does not claim that
# full server_init_process() is running yet. The real Wine server event loop
# and persistent process lifetime are the next gate.
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

/*
 * Compatibility gate for Wine's real initial process/thread FD handshake.
 *
 * server_fd is one end of an AF_UNIX SOCK_STREAM socketpair and ownership is
 * transferred to Wine server create_process(). create_thread(-1, ...) then
 * asks Wine itself to create its request pipe and transfer the client end via
 * SCM_RIGHTS together with SERVER_PROTOCOL_VERSION.
 *
 * This gate intentionally tears the temporary process/thread back down after
 * the handshake. A later stage will retain them and run Wine's real server
 * event loop. Keeping this gate one-shot makes regressions unambiguous.
 */
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

    /* create_process() consumes server_fd. */
    process = create_process(server_fd, NULL, 0, NULL, NULL, NULL, 0, NULL);
    server_fd = -1;
    if (!process) goto done;
    bootstrap_stage = WINE_INPROC_STAGE_PROCESS;

    /*
     * fd == -1 selects Wine's normal initial request-pipe bootstrap path.
     * Successful create_thread() means send_client_fd() has completed.
     */
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

# The server executable normally owns these four globals in server/main.c.
# The reusable core excludes main.o, so provide only those ABI globals.
cat > "$GENERATED/WineServerGlobals.c" <<'C_EOF'
#include "object.h"

#define WINE_TICKS_PER_SEC 10000000

int debug_level = 0;
int foreground = 1;
timeout_t master_socket_timeout =
    (timeout_t)(-3LL * WINE_TICKS_PER_SEC);
const char *server_argv0 = "wine-inprocess";
C_EOF

# ---------------------------------------------------------------------------
# Gate 3: compile the new bridge as plain objects when a compiler is available.
# This is deliberately a source/API gate, not a full Wine link yet.
# ---------------------------------------------------------------------------

CC_BIN="${CC:-}"
if test -z "$CC_BIN"; then
    if command -v clang >/dev/null 2>&1; then
        CC_BIN="$(command -v clang)"
    elif command -v cc >/dev/null 2>&1; then
        CC_BIN="$(command -v cc)"
    fi
fi

if test -n "$CC_BIN"; then
    COMMON=(
        -D__WINESRC__
        -fms-extensions
        -I"$WINE/include"
        -I"$WINE/server"
    )

    "$CC_BIN" "${COMMON[@]}" \
        -c "$GENERATED/WineServerNativeBootstrap.c" \
        -o "$BUILD/WineServerNativeBootstrap.o"

    "$CC_BIN" "${COMMON[@]}" \
        -c "$GENERATED/WineServerGlobals.c" \
        -o "$BUILD/WineServerGlobals.o"

    echo "WINE_INPROC_BRIDGE_COMPILE=PASS"
else
    echo "WINE_INPROC_BRIDGE_COMPILE=SKIP_NO_COMPILER"
fi

# ---------------------------------------------------------------------------
# Do not mutate the known-good Juice checkout yet.
# The old tracer path remains available as a reference until the replacement
# passes the real persistent server + __wine_main gate.
# ---------------------------------------------------------------------------

cat > "$WINE_ROOT/BASELINE" <<EOF
WINARC_COMPONENT=wine
BOOTSTRAP_REVISION=$BOOTSTRAP_REVISION
UPSTREAM=ExoCore-Kernel/Juice
UPSTREAM_COMMIT=$JUICE_COMMIT
PRODUCT_NAME=WinArc
COMPONENT_NAME=Wine

TROLLSTORE_MAINLINE=NO
TIPA_MAINLINE=NO
VAR_JB_MAINLINE=NO
CORETRUST_MAINLINE=NO

JUICE_WINE_SOURCE_LOCKED=YES
WINE_INPROC_CREATE_PROCESS_API=PASS
WINE_INPROC_CREATE_THREAD_API=PASS
WINE_INPROC_WINESERVERSOCKET_API=PASS
WINE_INPROC_WINE_MAIN_EXPORT=PASS

TRACE_PARENT_REMOVED=NO
WINE_SERVER_PERSISTENT_INPROCESS=NOT_YET
WINE_MAIN_INPROCESS=NOT_YET

NEXT_STAGE=persistent-inprocess-wineserver
EOF

echo "WINARC_WINE_BOOTSTRAP=PASS"
echo "WINE_INPROC_FD_GATE_SOURCE=READY"
echo "TRACE_PARENT_REMOVED=NO"
echo "NEXT_STAGE=PERSISTENT_INPROCESS_WINESERVER"
