#include "WineRuntimeBridge.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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

extern void wineserver_set_nls_dir(const char *path);
extern void wineserver_inject_client_fd(int fd);
extern volatile int g_wineserver_should_stop;

extern _Thread_local jmp_buf wine_ios_exit_jmpbuf;
extern _Thread_local volatile int wine_ios_exit_code;
extern _Thread_local pthread_t wine_ios_main_thread;
extern _Thread_local int wine_ios_exit_initialized;

static pthread_t g_server_thread;
static pthread_t g_client_thread;

static volatile int g_server_state = WINARC_WINESERVER_NOT_STARTED;
static volatile int g_server_exit_code = -9999;

static volatile int g_client_state = WINARC_WINECLIENT_NOT_STARTED;
static volatile int g_client_exit_code = -9999;

static pthread_mutex_t g_error_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_last_error[768];

struct client_context
{
    char prefix[1024];
    char bundle[1024];
};

static struct client_context g_client_context;

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
    snprintf(g_last_error, sizeof(g_last_error), "%s", message ? message : "");
    pthread_mutex_unlock(&g_error_lock);
}

static int ensure_dir(const char *path)
{
    struct stat st;

    if (!path || !*path) return -1;

    if (stat(path, &st) == 0)
        return S_ISDIR(st.st_mode) ? 0 : -1;

    if (mkdir(path, 0755) == 0 || errno == EEXIST)
        return 0;

    return -1;
}

static int replace_symlink(const char *target, const char *link_path)
{
    struct stat st;

    if (lstat(link_path, &st) == 0)
    {
        if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode))
            return 0;

        if (unlink(link_path) != 0)
            return -1;
    }

    if (symlink(target, link_path) == 0)
        return 0;

    return errno == EEXIST ? 0 : -1;
}

static int prepare_pe_farm(const char *prefix_path, const char *bundle_path)
{
    char drive_c[1200];
    char windows[1200];
    char system32[1200];
    char dosdevices[1200];
    char c_link[1200];
    char pe_root[1200];

    DIR *dir;
    struct dirent *entry;

    snprintf(drive_c, sizeof(drive_c), "%s/drive_c", prefix_path);
    snprintf(windows, sizeof(windows), "%s/windows", drive_c);
    snprintf(system32, sizeof(system32), "%s/system32", windows);
    snprintf(dosdevices, sizeof(dosdevices), "%s/dosdevices", prefix_path);
    snprintf(c_link, sizeof(c_link), "%s/c:", dosdevices);
    snprintf(pe_root, sizeof(pe_root), "%s/aarch64-windows", bundle_path);

    if (ensure_dir(prefix_path) ||
        ensure_dir(drive_c) ||
        ensure_dir(windows) ||
        ensure_dir(system32) ||
        ensure_dir(dosdevices))
    {
        set_last_error("Cannot create Wine prefix runtime directories");
        return -1;
    }

    if (replace_symlink("../drive_c", c_link))
    {
        set_last_error("Cannot create Wine dosdevices/c: mapping");
        return -1;
    }

    dir = opendir(pe_root);
    if (!dir)
    {
        char buffer[512];
        snprintf(buffer, sizeof(buffer),
                 "Cannot open aarch64-windows runtime (errno=%d)", errno);
        set_last_error(buffer);
        return -1;
    }

    while ((entry = readdir(dir)) != NULL)
    {
        char source[1600];
        char destination[1600];

        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;

        snprintf(source, sizeof(source), "%s/%s", pe_root, entry->d_name);
        snprintf(destination, sizeof(destination), "%s/%s",
                 system32, entry->d_name);

        if (replace_symlink(source, destination))
        {
            char buffer[512];
            snprintf(buffer, sizeof(buffer),
                     "Cannot map PE runtime file into system32: %.320s",
                     entry->d_name);
            closedir(dir);
            set_last_error(buffer);
            return -1;
        }
    }

    closedir(dir);

    {
        char explorer_path[1400];
        snprintf(explorer_path, sizeof(explorer_path),
                 "%s/explorer.exe", system32);

        if (access(explorer_path, R_OK) != 0)
        {
            set_last_error("C:\\windows\\system32\\explorer.exe is unavailable");
            return -1;
        }
    }

    return 0;
}

void winarc_wine_runtime_report_fatal(const char *message)
{
    set_last_error(message ? message : "Wine fatal_error");
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

int winarc_wine_runtime_client_state(void)
{
    return __atomic_load_n(&g_client_state, __ATOMIC_SEQ_CST);
}

int winarc_wine_runtime_client_exit_code(void)
{
    return __atomic_load_n(&g_client_exit_code, __ATOMIC_SEQ_CST);
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

    pthread_cleanup_push(server_thread_cleanup, NULL);

    result = value->server_entry(2, argv);
    __atomic_store_n(&g_server_exit_code, result, __ATOMIC_SEQ_CST);

    pthread_cleanup_pop(1);
    return NULL;
}

int winarc_wine_runtime_start_server(const char *prefix_path,
                                     const char *nls_path)
{
    int current_state;
    int result;

    if (!boundary())
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

    {
        char system_reg[1200];
        snprintf(system_reg, sizeof(system_reg), "%s/system.reg", prefix_path);

        if (access(system_reg, R_OK) != 0)
        {
            set_last_error("Wine prefix template is not prepared before wineserver start");
            return -6;
        }
    }

    set_last_error("");

    setenv("WINEPREFIX", prefix_path, 1);
    setenv("HOME", prefix_path, 1);

    /*
     * The current iOS Wine/win32u objects still use Madeira's internal
     * environment gates. Keep our public WinArc name too, but do not rename
     * the donor-side gate until the corresponding Wine sources move over.
     */
    setenv("WINARC_DESKTOP", "1", 1);
    setenv("MADEIRA_DESKTOP", "1", 1);
    setenv("MADEIRA_WIN32U", "1", 1);

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

    pthread_detach(g_server_thread);
    return 0;
}

static void client_thread_cleanup(void *unused)
{
    (void)unused;

    wine_ios_exit_initialized = 0;

    if (__atomic_load_n(&g_client_state, __ATOMIC_SEQ_CST) ==
        WINARC_WINECLIENT_RUNNING)
    {
        __atomic_store_n(&g_client_state,
                         WINARC_WINECLIENT_FAILED,
                         __ATOMIC_SEQ_CST);
    }
}

static void *client_thread_main(void *unused)
{
    const struct winarc_wine_reference_boundary *value = boundary();

#if defined(__APPLE__)
    /* Guest main thread: avoid default-QoS timer coalescing during Wine init. */
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif

    char *argv[] = {
        (char *)"wine",
        (char *)"C:\\windows\\system32\\explorer.exe",
        (char *)"/desktop=WinArc,1280x720",
        NULL
    };

    (void)unused;

    if (!value)
    {
        set_last_error("Wine runtime boundary disappeared before desktop start");
        __atomic_store_n(&g_client_exit_code, -1, __ATOMIC_SEQ_CST);
        __atomic_store_n(&g_client_state,
                         WINARC_WINECLIENT_FAILED,
                         __ATOMIC_SEQ_CST);
        return NULL;
    }

    setenv("WINEPREFIX", g_client_context.prefix, 1);
    setenv("HOME", g_client_context.prefix, 1);

    /*
     * LOAD-BEARING on iOS:
     *
     * Wine's __wine_main() normally calls check_command_line(), which reaches
     * reexec_loader(). A normal Unix Wine process may re-exec its loader; an
     * iOS app must remain inside the existing UIKit Mach process.
     *
     * The iOS Wine reference explicitly relies on WINELOADERNOEXEC=1 to skip
     * that path. __wine_main() consumes and unsets it itself.
     */
    setenv("WINELOADERNOEXEC", "1", 1);

    /*
     * The current donor win32u build still checks these internal Madeira
     * switches. WINARC_DESKTOP is our app-side switch; MADEIRA_DESKTOP is
     * required by driver_ios.c until that Wine-side source is renamed.
     */
    setenv("WINARC_DESKTOP", "1", 1);
    setenv("MADEIRA_DESKTOP", "1", 1);
    setenv("MADEIRA_WIN32U", "1", 1);

    /*
     * Match the proven iOS loader contract: WINEDLLPATH points at the App
     * bundle root, which contains aarch64-windows/. Do not point it directly
     * at aarch64-windows; Wine's loader appends the PE architecture directory.
     */
    setenv("WINEDLLPATH", g_client_context.bundle, 1);

    /* Keep desktop bring-up quiet enough to see genuine bootstrap failures. */
    setenv("WINEDEBUG", "err+all,err-virtual", 1);

    /*
     * Desktop bring-up does not initialize DXMT or D3DMetal. The shell is a
     * GDI/user32 path, which keeps this milestone independent from the game
     * graphics backend and saves memory during desktop-only testing.
     */
    unsetenv("WINEDLLOVERRIDES");

    wine_ios_main_thread = pthread_self();
    wine_ios_exit_code = 0;
    wine_ios_exit_initialized = 1;

    __atomic_store_n(&g_client_state,
                     WINARC_WINECLIENT_RUNNING,
                     __ATOMIC_SEQ_CST);

    pthread_cleanup_push(client_thread_cleanup, NULL);

    if (setjmp(wine_ios_exit_jmpbuf) == 0)
    {
        value->client_entry(3, argv);

        __atomic_store_n(&g_client_exit_code, 0, __ATOMIC_SEQ_CST);
        __atomic_store_n(&g_client_state,
                         WINARC_WINECLIENT_EXITED,
                         __ATOMIC_SEQ_CST);
    }
    else
    {
        int exit_code = wine_ios_exit_code;

        __atomic_store_n(&g_client_exit_code,
                         exit_code,
                         __ATOMIC_SEQ_CST);

        if (exit_code == 0)
        {
            __atomic_store_n(&g_client_state,
                             WINARC_WINECLIENT_EXITED,
                             __ATOMIC_SEQ_CST);
        }
        else
        {
            char buffer[256];
            snprintf(buffer, sizeof(buffer),
                     "Wine desktop exited with code %d", exit_code);
            set_last_error(buffer);

            __atomic_store_n(&g_client_state,
                             WINARC_WINECLIENT_FAILED,
                             __ATOMIC_SEQ_CST);
        }
    }

    wine_ios_exit_initialized = 0;

    pthread_cleanup_pop(0);
    return NULL;
}

int winarc_wine_runtime_start_desktop(const char *prefix_path,
                                      const char *bundle_path)
{
    int pair[2];
    int state;
    int result;
    char fd_string[32];
    char pe_path[1400];

    if (!boundary())
    {
        set_last_error("Wine runtime is not linked");
        return -1;
    }

    if (winarc_wine_runtime_server_state() != WINARC_WINESERVER_RUNNING)
    {
        set_last_error("wineserver must be running before Wine desktop starts");
        return -2;
    }

    if (!prefix_path || !*prefix_path || !bundle_path || !*bundle_path)
    {
        set_last_error("Invalid Wine desktop prefix or bundle path");
        return -3;
    }

    state = winarc_wine_runtime_client_state();

    if (state == WINARC_WINECLIENT_STARTING ||
        state == WINARC_WINECLIENT_RUNNING)
        return 1;

    if (state == WINARC_WINECLIENT_EXITED ||
        state == WINARC_WINECLIENT_FAILED)
    {
        set_last_error("Wine client already ran in this process; relaunch WinArc before retrying");
        return -5;
    }

    if (prepare_pe_farm(prefix_path, bundle_path) != 0)
        return -3;

    snprintf(g_client_context.prefix,
             sizeof(g_client_context.prefix), "%s", prefix_path);

    snprintf(pe_path, sizeof(pe_path),
             "%s/aarch64-windows", bundle_path);

    /*
     * Keep this sanity check local, but retain the BUNDLE ROOT in the client
     * context. Wine's iOS loader derives aarch64-windows/ from WINEDLLPATH.
     */
    if (access(pe_path, R_OK) != 0)
    {
        set_last_error("aarch64-windows runtime is unavailable");
        return -3;
    }

    snprintf(g_client_context.bundle,
             sizeof(g_client_context.bundle), "%s", bundle_path);

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
    {
        char buffer[256];
        snprintf(buffer, sizeof(buffer),
                 "socketpair failed (errno=%d)", errno);
        set_last_error(buffer);
        return -4;
    }

    if (fcntl(pair[1], F_SETFD, FD_CLOEXEC) != 0)
    {
        /* Wine will repeat this after consuming WINESERVERSOCKET. Keep going:
         * the descriptor is still valid for the in-process handoff. */
    }

    snprintf(fd_string, sizeof(fd_string), "%d", pair[1]);
    setenv("WINESERVERSOCKET", fd_string, 1);

    /*
     * Proven iOS bridge order:
     *   1. socketpair
     *   2. publish client fd through WINESERVERSOCKET
     *   3. inject the server fd into the in-process wineserver
     *   4. enter __wine_main on a separate pthread
     */
    wineserver_inject_client_fd(pair[0]);

    set_last_error("");
    __atomic_store_n(&g_client_exit_code, -9999, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_client_state,
                     WINARC_WINECLIENT_STARTING,
                     __ATOMIC_SEQ_CST);

    result = pthread_create(&g_client_thread, NULL, client_thread_main, NULL);
    if (result != 0)
    {
        char buffer[256];

        close(pair[0]);
        close(pair[1]);
        unsetenv("WINESERVERSOCKET");

        snprintf(buffer, sizeof(buffer),
                 "pthread_create(Wine desktop) failed: %d", result);
        set_last_error(buffer);

        __atomic_store_n(&g_client_state,
                         WINARC_WINECLIENT_NOT_STARTED,
                         __ATOMIC_SEQ_CST);
        return -6;
    }

    pthread_detach(g_client_thread);
    return 0;
}
