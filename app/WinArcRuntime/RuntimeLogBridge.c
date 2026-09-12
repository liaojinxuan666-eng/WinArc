#include "RuntimeLogBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static int g_log_active = 0;
static int g_stop_on_first_present = 0;
static int g_first_present_seen = 0;

static int g_saved_stdout = -1;
static int g_saved_stderr = -1;

static char g_log_path[1024];

static void write_mark_unlocked(const char *subsystem, const char *message)
{
    struct timespec ts;
    struct tm tm_value;
    char timestamp[64];

    if (!g_log_active) return;

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

    dprintf(
        STDERR_FILENO,
        "[%s] [WinArc/%s] %s\n",
        timestamp,
        subsystem && *subsystem ? subsystem : "Runtime",
        message ? message : ""
    );
}

static void restore_fds_unlocked(void)
{
    fflush(NULL);

    if (g_saved_stdout >= 0)
    {
        (void)dup2(g_saved_stdout, STDOUT_FILENO);
        close(g_saved_stdout);
        g_saved_stdout = -1;
    }

    if (g_saved_stderr >= 0)
    {
        (void)dup2(g_saved_stderr, STDERR_FILENO);
        close(g_saved_stderr);
        g_saved_stderr = -1;
    }

    g_log_active = 0;
    g_stop_on_first_present = 0;
    g_first_present_seen = 0;
}

int winarc_runtime_log_start(const char *path, int stop_on_first_present)
{
    int fd;
    int saved_errno;

    if (!path || !*path)
        return -EINVAL;

    pthread_mutex_lock(&g_log_lock);

    if (g_log_active)
    {
        /*
         * Never downgrade an always-on session into first-present mode by
         * accident. An existing capture keeps its original lifetime.
         */
        pthread_mutex_unlock(&g_log_lock);
        return 1;
    }

    fflush(NULL);

    g_saved_stdout = dup(STDOUT_FILENO);
    g_saved_stderr = dup(STDERR_FILENO);

    if (g_saved_stdout < 0 || g_saved_stderr < 0)
    {
        saved_errno = errno;

        if (g_saved_stdout >= 0)
        {
            close(g_saved_stdout);
            g_saved_stdout = -1;
        }

        if (g_saved_stderr >= 0)
        {
            close(g_saved_stderr);
            g_saved_stderr = -1;
        }

        pthread_mutex_unlock(&g_log_lock);
        return -saved_errno;
    }

    fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);

    if (fd < 0)
    {
        saved_errno = errno;
        close(g_saved_stdout);
        close(g_saved_stderr);
        g_saved_stdout = -1;
        g_saved_stderr = -1;

        pthread_mutex_unlock(&g_log_lock);
        return -saved_errno;
    }

    if (dup2(fd, STDERR_FILENO) < 0 ||
        dup2(fd, STDOUT_FILENO) < 0)
    {
        saved_errno = errno;
        close(fd);
        restore_fds_unlocked();

        pthread_mutex_unlock(&g_log_lock);
        return -saved_errno;
    }

    if (fd != STDERR_FILENO && fd != STDOUT_FILENO)
        close(fd);

    snprintf(g_log_path, sizeof(g_log_path), "%s", path);

    g_log_active = 1;
    g_stop_on_first_present = stop_on_first_present ? 1 : 0;
    g_first_present_seen = 0;

    dprintf(
        STDERR_FILENO,
        "\n============================================================\n"
        "WinArc 0.0.1 runtime log session\n"
        "capture=%s\n"
        "============================================================\n",
        g_stop_on_first_present ? "game-loading" : "always"
    );

    write_mark_unlocked("LOG", "stdout/stderr capture started");

    pthread_mutex_unlock(&g_log_lock);
    return 0;
}

void winarc_runtime_log_stop(void)
{
    pthread_mutex_lock(&g_log_lock);

    if (g_log_active)
    {
        write_mark_unlocked("LOG", "stdout/stderr capture stopping");
        restore_fds_unlocked();
    }

    pthread_mutex_unlock(&g_log_lock);
}

void winarc_runtime_log_note_first_present(void)
{
    pthread_mutex_lock(&g_log_lock);

    if (!g_log_active || g_first_present_seen)
    {
        pthread_mutex_unlock(&g_log_lock);
        return;
    }

    g_first_present_seen = 1;
    write_mark_unlocked("Graphics", "first guest surface presented");

    if (g_stop_on_first_present)
    {
        write_mark_unlocked(
            "LOG",
            "game-loading capture complete at first visible guest surface"
        );
        restore_fds_unlocked();
    }

    pthread_mutex_unlock(&g_log_lock);
}

void winarc_runtime_log_mark(const char *subsystem, const char *message)
{
    pthread_mutex_lock(&g_log_lock);
    write_mark_unlocked(subsystem, message);
    pthread_mutex_unlock(&g_log_lock);
}

int winarc_runtime_log_is_active(void)
{
    int active;

    pthread_mutex_lock(&g_log_lock);
    active = g_log_active;
    pthread_mutex_unlock(&g_log_lock);

    return active;
}

const char *winarc_runtime_log_path(void)
{
    return g_log_path;
}
