#include "WineRuntimeBridge.h"

#include <stddef.h>

struct winarc_wine_reference_boundary
{
    uint32_t abi_version;
    uint32_t runtime_ready;
    int (*server_entry)(int, char **);
    void (*client_entry)(int, char **);
};

extern const struct winarc_wine_reference_boundary *
winarc_wine_reference_get_boundary(void);

static const struct winarc_wine_reference_boundary *boundary(void)
{
    const struct winarc_wine_reference_boundary *value =
        winarc_wine_reference_get_boundary();

    if (!value) return NULL;
    if (!value->server_entry) return NULL;
    if (!value->client_entry) return NULL;
    return value;
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
