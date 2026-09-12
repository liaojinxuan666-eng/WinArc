#include "RuntimeLogBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_log_installed = 0;
static char g_log_path[1024];

static void write_mark_locked(const char *subsystem, const char *message)
{
    struct timespec ts;
    struct tm tm_value;
    char timestamp[64];

    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm_value);

    snprintf(
        timestamp,
        sizeof(timestamp),
        "%04d-%02d-%02d %02d:%02d:%02d.%03ld",
        tm_value.tm_year + 1900,
        tm_value.tm_mon + 1,
        tm_value.tm_mday,
        tm_value.tm_hour,
        tm_value.tm_min,
        tm_value.tm_sec,
        ts.tv_nsec / 1000000
    );

    /*
     * dprintf goes directly to fd 2 after installation; unlike buffered
     * stdio this gives us useful final breadcrumbs immediately before an
     * abrupt process death.
     */
    dprintf(
        STDERR_FILENO,
        "[%s] [WinArc/%s] %s\n",
        timestamp,
        subsystem && *subsystem ? subsystem : "Runtime",
        message ? message : ""
    );
}

int winarc_runtime_log_install(const char *path)
{
    int fd;

    if (!path || !*path)
        return -EINVAL;

    pthread_mutex_lock(&g_log_lock);

    if (g_log_installed)
    {
        pthread_mutex_unlock(&g_log_lock);
        return 1;
    }

    fd = open(
        path,
        O_WRONLY | O_CREAT | O_APPEND,
        0644
    );

    if (fd < 0)
    {
        int saved = errno;
        pthread_mutex_unlock(&g_log_lock);
        return -saved;
    }

    if (dup2(fd, STDERR_FILENO) < 0 ||
        dup2(fd, STDOUT_FILENO) < 0)
    {
        int saved = errno;
        close(fd);
        pthread_mutex_unlock(&g_log_lock);
        return -saved;
    }

    if (fd != STDERR_FILENO && fd != STDOUT_FILENO)
        close(fd);

    /*
     * Wine uses both stdio and direct fd writes. Keep stderr unbuffered and
     * stdout line-buffered so a crash loses as little tail information as
     * possible without forcing fsync on every Wine trace line.
     */
    setvbuf(stderr, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);

    snprintf(g_log_path, sizeof(g_log_path), "%s", path);
    g_log_installed = 1;

    dprintf(
        STDERR_FILENO,
        "\n============================================================\n"
        "WinArc 0.0.1 runtime session\n"
        "============================================================\n"
    );

    write_mark_locked("LOG", "persistent stdout/stderr capture installed");

    pthread_mutex_unlock(&g_log_lock);
    return 0;
}

void winarc_runtime_log_mark(const char *subsystem, const char *message)
{
    pthread_mutex_lock(&g_log_lock);

    if (g_log_installed)
        write_mark_locked(subsystem, message);

    pthread_mutex_unlock(&g_log_lock);
}

const char *winarc_runtime_log_path(void)
{
    return g_log_path;
}
