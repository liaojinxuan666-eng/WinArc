#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Device-safe link probe.
 *
 * This does NOT start Wine. It proves that the WinArc application binary
 * contains the Wine reference boundary and that both server/client entry
 * addresses survived final executable linking.
 */
int winarc_wine_runtime_is_linked(void);
uint32_t winarc_wine_runtime_abi(void);
uint32_t winarc_wine_runtime_ready_flag(void);
uintptr_t winarc_wine_runtime_server_entry(void);
uintptr_t winarc_wine_runtime_client_entry(void);

#ifdef __cplusplus
}
#endif
