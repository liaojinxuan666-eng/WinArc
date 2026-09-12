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

enum
{
    WINARC_WINECLIENT_NOT_STARTED = 0,
    WINARC_WINECLIENT_STARTING = 1,
    WINARC_WINECLIENT_RUNNING = 2,
    WINARC_WINECLIENT_EXITED = 3,
    WINARC_WINECLIENT_FAILED = 4
};

int winarc_wine_runtime_is_linked(void);
uint32_t winarc_wine_runtime_abi(void);
uint32_t winarc_wine_runtime_ready_flag(void);
uintptr_t winarc_wine_runtime_server_entry(void);
uintptr_t winarc_wine_runtime_client_entry(void);

int winarc_wine_runtime_start_server(const char *prefix_path,
                                     const char *nls_path);

int winarc_wine_runtime_server_state(void);
int winarc_wine_runtime_server_exit_code(void);

/*
 * First visible Wine client milestone:
 *
 *   socketpair
 *      -> WINESERVERSOCKET
 *      -> wineserver_inject_client_fd()
 *      -> __wine_main()
 *      -> explorer.exe /desktop=WinArc,1280x720
 *
 * The caller must prepare the prefix template before wineserver starts.
 */
int winarc_wine_runtime_start_desktop(const char *prefix_path,
                                      const char *bundle_path);

int winarc_wine_runtime_client_state(void);
int winarc_wine_runtime_client_exit_code(void);

const char *winarc_wine_runtime_last_error(void);

/* Host shims call this before terminating only the current Wine thread. */
void winarc_wine_runtime_report_fatal(const char *message);

#ifdef __cplusplus
}
#endif
