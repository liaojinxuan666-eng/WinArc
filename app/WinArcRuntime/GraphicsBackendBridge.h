#pragma once

#ifdef __cplusplus
extern "C" {
#endif

enum
{
    WINARC_GRAPHICS_UNAVAILABLE = 0,
    WINARC_GRAPHICS_READY = 1,
    WINARC_GRAPHICS_PRESENT_BUT_INCOMPATIBLE = 2
};

/* backend_name is "DXMT" or "D3DMetal". */
int winarc_graphics_backend_status(const char *backend_name,
                                   const char *bundle_path);

/* Human-readable status. The returned pointer remains valid until the next
 * call on the same process. */
const char *winarc_graphics_backend_status_text(const char *backend_name,
                                                const char *bundle_path);

/* Apply only the Wine environment needed by the selected backend.
 * Returns 0 on success, negative on an unavailable/incompatible backend.
 * This does not start Wine. */
int winarc_graphics_backend_apply(const char *backend_name,
                                  const char *bundle_path);

#ifdef __cplusplus
}
#endif
