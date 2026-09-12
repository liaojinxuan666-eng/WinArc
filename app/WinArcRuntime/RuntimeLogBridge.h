#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Start redirecting process stdout/stderr to an append-only file.
 *
 * stop_on_first_present:
 *   0 -> keep capturing until explicitly stopped / process exit
 *   1 -> RuntimeLogBridge stops after winarc_runtime_log_note_first_present()
 *
 * Returns:
 *   0  started now
 *   1  already active
 *  <0  errno-style failure
 */
int winarc_runtime_log_start(const char *path, int stop_on_first_present);

/* Restore the original stdout/stderr descriptors. */
void winarc_runtime_log_stop(void);

/* Called by the compositor after the first real guest surface is presented. */
void winarc_runtime_log_note_first_present(void);

/* Runtime breadcrumb. Written only while capture is active. */
void winarc_runtime_log_mark(const char *subsystem, const char *message);

int winarc_runtime_log_is_active(void);
const char *winarc_runtime_log_path(void);

#ifdef __cplusplus
}
#endif
