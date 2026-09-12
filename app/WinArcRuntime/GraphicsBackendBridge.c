#include "GraphicsBackendBridge.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* Strong definition comes from DXMT's iOS winemetal unix object.
 * WineHostStubs.c provides a weak fallback only so non-DXMT bring-up builds
 * can still link. */
extern const void *dxmt_winemetal_unix_call_funcs[];

static char g_status[768];

static int file_exists(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static int dir_exists(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int is_backend(const char *name, const char *expected)
{
    return name && expected && strcasecmp(name, expected) == 0;
}

static int make_path(char *out, size_t size,
                     const char *root, const char *suffix)
{
    if (!out || !size || !root || !suffix) return -1;
    int n = snprintf(out, size, "%s/%s", root, suffix);
    return (n > 0 && (size_t)n < size) ? 0 : -1;
}

static int dxmt_status(const char *bundle_path)
{
    char d3d11[1400], dxgi[1400], winemetal[1400];

    if (!bundle_path || !*bundle_path)
    {
        snprintf(g_status, sizeof(g_status), "DXMT：无效的 App Bundle 路径");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    if (make_path(d3d11, sizeof(d3d11), bundle_path,
                  "aarch64-windows/d3d11.dll") ||
        make_path(dxgi, sizeof(dxgi), bundle_path,
                  "aarch64-windows/dxgi.dll") ||
        make_path(winemetal, sizeof(winemetal), bundle_path,
                  "aarch64-windows/winemetal.dll"))
    {
        snprintf(g_status, sizeof(g_status), "DXMT：路径过长");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    if (!file_exists(d3d11) || !file_exists(dxgi) || !file_exists(winemetal))
    {
        snprintf(g_status, sizeof(g_status),
                 "DXMT：PE 图形模块未打进 WinArc.app");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    /*
     * The table itself is the host-side Wine/Metal ABI. Merely having the
     * static archive on disk is not enough; its strong definition must have
     * survived the final app link.
     */
    if (!dxmt_winemetal_unix_call_funcs ||
        !dxmt_winemetal_unix_call_funcs[0])
    {
        snprintf(g_status, sizeof(g_status),
                 "DXMT：PE 模块已就绪，但 winemetal host 未进入最终 Mach-O");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    snprintf(g_status, sizeof(g_status),
             "DXMT：host + d3d11/dxgi/winemetal 已就绪");
    return WINARC_GRAPHICS_READY;
}

static int d3dmetal_status(const char *bundle_path)
{
    char root[1400], framework[1600], shared[1600];
    char d3d11[1600], dxgi[1600];

    if (!bundle_path || !*bundle_path)
    {
        snprintf(g_status, sizeof(g_status), "D3DMetal：无效的 App Bundle 路径");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    if (make_path(root, sizeof(root), bundle_path, "Graphics/D3DMetal") ||
        make_path(framework, sizeof(framework), root,
                  "external/D3DMetal.framework/D3DMetal") ||
        make_path(shared, sizeof(shared), root,
                  "external/libd3dshared.dylib") ||
        make_path(d3d11, sizeof(d3d11), root,
                  "aarch64-windows/d3d11.dll") ||
        make_path(dxgi, sizeof(dxgi), root,
                  "aarch64-windows/dxgi.dll"))
    {
        snprintf(g_status, sizeof(g_status), "D3DMetal：路径过长");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    if (!file_exists(framework) || !file_exists(shared) ||
        !file_exists(d3d11) || !file_exists(dxgi))
    {
        snprintf(g_status, sizeof(g_status),
                 "D3DMetal：后端接口已接入；兼容的 iOS payload 尚未安装");
        return WINARC_GRAPHICS_UNAVAILABLE;
    }

    /*
     * Do not claim that a payload is usable just because the files exist.
     * dlopen is the decisive iOS loader check (platform, architecture,
     * code-signing and dependent dylibs all participate here).
     */
    void *handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL);
    if (!handle)
    {
        const char *error = dlerror();
        snprintf(g_status, sizeof(g_status),
                 "D3DMetal：payload 存在但 iOS 无法加载：%.520s",
                 error ? error : "unknown dlopen error");
        return WINARC_GRAPHICS_PRESENT_BUT_INCOMPATIBLE;
    }

    dlclose(handle);

    snprintf(g_status, sizeof(g_status),
             "D3DMetal：framework + Wine shim payload 可加载");
    return WINARC_GRAPHICS_READY;
}

int winarc_graphics_backend_status(const char *backend_name,
                                   const char *bundle_path)
{
    if (is_backend(backend_name, "DXMT"))
        return dxmt_status(bundle_path);

    if (is_backend(backend_name, "D3DMetal"))
        return d3dmetal_status(bundle_path);

    snprintf(g_status, sizeof(g_status),
             "未知图形后端：%s", backend_name ? backend_name : "(null)");
    return WINARC_GRAPHICS_UNAVAILABLE;
}

const char *winarc_graphics_backend_status_text(const char *backend_name,
                                                const char *bundle_path)
{
    (void)winarc_graphics_backend_status(backend_name, bundle_path);
    return g_status;
}

int winarc_graphics_backend_apply(const char *backend_name,
                                  const char *bundle_path)
{
    char dll_path[1600];

    int status = winarc_graphics_backend_status(backend_name, bundle_path);
    if (status != WINARC_GRAPHICS_READY)
        return status == WINARC_GRAPHICS_PRESENT_BUT_INCOMPATIBLE ? -2 : -1;

    if (is_backend(backend_name, "DXMT"))
    {
        if (make_path(dll_path, sizeof(dll_path),
                      bundle_path, "aarch64-windows"))
            return -3;

        setenv("WINEDLLPATH", dll_path, 1);
        setenv("WINEDLLOVERRIDES", "d3d11,dxgi=n,b", 1);
        return 0;
    }

    if (is_backend(backend_name, "D3DMetal"))
    {
        if (make_path(dll_path, sizeof(dll_path),
                      bundle_path, "Graphics/D3DMetal/aarch64-windows"))
            return -3;

        setenv("WINEDLLPATH", dll_path, 1);
        setenv("WINEDLLOVERRIDES", "d3d11,d3d12,dxgi=n,b", 1);
        return 0;
    }

    return -1;
}
