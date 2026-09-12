#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum
{
    WINARC_WINESERVER_NOT_STARTED = 0,
    WINARC_WINESERVER_STARTING = 1,
    WINARC_WINESERVER_RUNNING = 2,
    WINARC_WINESERVER_RETURNED = 3
};

int winarc_wine_runtime_is_linked(void);
uint32_t winarc_wine_runtime_abi(void);
uint32_t winarc_wine_runtime_ready_flag(void);
uintptr_t winarc_wine_runtime_server_entry(void);
uintptr_t winarc_wine_runtime_client_entry(void);

/*
 * Start the iOS Wine wineserver in a dedicated pthread.
 *
 * This stage deliberately does NOT call __wine_main yet. It proves that
 * wineserver can initialize and remain alive inside the WinArc Mach process.
 *
 * Returns:
 *   0  thread created
 *   1  already starting/running
 *  -1  Wine boundary unavailable
 *  -2  invalid path
 *  -3  NLS directory unavailable
 *  -4  pthread_create failed
 *  -5  wineserver already returned; relaunch the app before retrying
 */
int winarc_wine_runtime_start_server(const char *prefix_path,
                                     const char *nls_path);

int winarc_wine_runtime_server_state(void);
int winarc_wine_runtime_server_exit_code(void);
const char *winarc_wine_runtime_last_error(void);

/* Called by the host fatal_error shim before it terminates only the server
 * pthread. Not intended for Swift code. */
void winarc_wine_runtime_report_fatal(const char *message);

#ifdef __cplusplus
}
#endif
