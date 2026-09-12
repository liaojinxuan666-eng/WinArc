#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Redirect process stdout/stderr to a persistent append-only file.
 *
 * Returns:
 *   0  installed now
 *   1  already installed
 *  <0  errno-style failure
 */
int winarc_runtime_log_install(const char *path);

/* Async-crash-friendly breadcrumb in the normal runtime path. */
void winarc_runtime_log_mark(const char *subsystem, const char *message);

const char *winarc_runtime_log_path(void);

#ifdef __cplusplus
}
#endif
