#include "WineRuntimeBridge.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct winarc_wine_reference_boundary
{
    uint32_t abi_version;
    uint32_t runtime_ready;
    int (*server_entry)(int, char **);
    void (*client_entry)(int, char **);
};

extern const struct winarc_wine_reference_boundary *
winarc_wine_reference_get_boundary(void);

/* Supplied by Madeira's iOS wineserver reference archive. */
extern void wineserver_set_nls_dir(const char *path);

/* Defined by WinArc's host shim and polled by Madeira's iOS server loop. */
extern volatile int g_wineserver_should_stop;

static pthread_t g_server_thread;
static volatile int g_server_state = WINARC_WINESERVER_NOT_STARTED;
static volatile int g_server_exit_code = -9999;

static pthread_mutex_t g_error_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_last_error[768];

static const struct winarc_wine_reference_boundary *boundary(void)
{
    const struct winarc_wine_reference_boundary *value =
        winarc_wine_reference_get_boundary();

    if (!value) return NULL;
    if (!value->server_entry) return NULL;
    if (!value->client_entry) return NULL;
    return value;
}

static void set_last_error(const char *message)
{
    pthread_mutex_lock(&g_error_lock);

    if (!message) message = "";
    snprintf(g_last_error, sizeof(g_last_error), "%s", message);

    pthread_mutex_unlock(&g_error_lock);
}

void winarc_wine_runtime_report_fatal(const char *message)
{
    set_last_error(message ? message : "wineserver fatal_error");
}

int winarc_wine_runtime_is_linked(void)
{
    return boundary() != NULL;
}

uint32_t winarc_wine_runtime_abi(void)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    return value ? value->abi_version : 0;
}

uint32_t winarc_wine_runtime_ready_flag(void)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    return value ? value->runtime_ready : 0;
}

uintptr_t winarc_wine_runtime_server_entry(void)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    return value ? (uintptr_t)value->server_entry : 0;
}

uintptr_t winarc_wine_runtime_client_entry(void)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    return value ? (uintptr_t)value->client_entry : 0;
}

int winarc_wine_runtime_server_state(void)
{
    return __atomic_load_n(&g_server_state, __ATOMIC_SEQ_CST);
}

int winarc_wine_runtime_server_exit_code(void)
{
    return __atomic_load_n(&g_server_exit_code, __ATOMIC_SEQ_CST);
}

const char *winarc_wine_runtime_last_error(void)
{
    return g_last_error;
}

static void server_thread_cleanup(void *unused)
{
    (void)unused;
    __atomic_store_n(&g_server_state,
                     WINARC_WINESERVER_RETURNED,
                     __ATOMIC_SEQ_CST);
}

static void *server_thread_main(void *unused)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    char *argv[] = { (char *)"wineserver", (char *)"--foreground", NULL };
    int result;

    (void)unused;

    if (!value)
    {
        set_last_error("Wine runtime boundary disappeared before wineserver start");
        __atomic_store_n(&g_server_exit_code, -1, __ATOMIC_SEQ_CST);
        __atomic_store_n(&g_server_state,
                         WINARC_WINESERVER_RETURNED,
                         __ATOMIC_SEQ_CST);
        return NULL;
    }

    __atomic_store_n(&g_server_state,
                     WINARC_WINESERVER_RUNNING,
                     __ATOMIC_SEQ_CST);

    /*
     * fatal_error() may call pthread_exit(). pthread cleanup therefore owns
     * the state transition back to RETURNED for both normal and fatal exits.
     */
    pthread_cleanup_push(server_thread_cleanup, NULL);

    result = value->server_entry(2, argv);
    __atomic_store_n(&g_server_exit_code, result, __ATOMIC_SEQ_CST);

    pthread_cleanup_pop(1);
    return NULL;
}

int winarc_wine_runtime_start_server(const char *prefix_path,
                                     const char *nls_path)
{
    const struct winarc_wine_reference_boundary *value = boundary();
    int current_state;
    int result;

    if (!value)
    {
        set_last_error("Wine runtime is not linked");
        return -1;
    }

    if (!prefix_path || !*prefix_path || !nls_path || !*nls_path)
    {
        set_last_error("Invalid Wine prefix or NLS path");
        return -2;
    }

    current_state = winarc_wine_runtime_server_state();

    if (current_state == WINARC_WINESERVER_STARTING ||
        current_state == WINARC_WINESERVER_RUNNING)
        return 1;

    /*
     * The reference wineserver owns substantial process-global state.
     * Until shutdown/restart is explicitly made safe, never initialize it
     * twice inside one UIKit process.
     */
    if (current_state == WINARC_WINESERVER_RETURNED)
    {
        set_last_error("wineserver already returned; relaunch WinArc before retrying");
        return -5;
    }

    if (access(nls_path, R_OK) != 0)
    {
        char buffer[512];
        snprintf(buffer, sizeof(buffer),
                 "Wine NLS directory is missing/unreadable: %s (errno=%d)",
                 nls_path, errno);
        set_last_error(buffer);
        return -3;
    }

    if (mkdir(prefix_path, 0755) != 0 && errno != EEXIST)
    {
        char buffer[512];
        snprintf(buffer, sizeof(buffer),
                 "Cannot create Wine prefix: %s (errno=%d)",
                 prefix_path, errno);
        set_last_error(buffer);
        return -2;
    }

    set_last_error("");

    /*
     * Match the proven iOS wineserver launch contract:
     *   WINEPREFIX -> app-owned container path
     *   HOME       -> same app-owned path
     *   NLS        -> bundle resource directory
     *
     * --foreground is passed by server_thread_main(), preventing the normal
     * Unix wineserver daemon/fork model from being used.
     */
    setenv("WINEPREFIX", prefix_path, 1);
    setenv("HOME", prefix_path, 1);
    wineserver_set_nls_dir(nls_path);

    g_wineserver_should_stop = 0;
    __atomic_store_n(&g_server_exit_code, -9999, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_server_state,
                     WINARC_WINESERVER_STARTING,
                     __ATOMIC_SEQ_CST);

    result = pthread_create(&g_server_thread, NULL, server_thread_main, NULL);
    if (result != 0)
    {
        char buffer[256];
        snprintf(buffer, sizeof(buffer),
                 "pthread_create(wineserver) failed: %d", result);
        set_last_error(buffer);
        __atomic_store_n(&g_server_state,
                         WINARC_WINESERVER_NOT_STARTED,
                         __ATOMIC_SEQ_CST);
        return -4;
    }

    /*
     * v0.0.1 does not implement an in-process restart yet. Detach the probe
     * thread so a fatal early return does not leak a joinable pthread.
     */
    pthread_detach(g_server_thread);
    return 0;
}
