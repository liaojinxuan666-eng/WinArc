/*
 * WinArc iOS display shim for DXMT.
 *
 * Fullscreen/direct-game mode uses a registered CAMetalLayer.
 * Wine desktop mode resolves each HWND to Winios' per-window CAMetalLayer.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "IOSDisplayShim.h"
#include "Winios.h"

typedef struct macdrv_opaque_metal_device *macdrv_metal_device;
typedef struct macdrv_opaque_metal_view   *macdrv_metal_view;
typedef struct macdrv_opaque_metal_layer  *macdrv_metal_layer;
typedef struct macdrv_opaque_view         *macdrv_view;
typedef struct macdrv_opaque_window       *macdrv_window;
typedef struct opaque_HWND                *HWND;

struct macdrv_win_data
{
    HWND hwnd;
    macdrv_window cocoa_window;
    macdrv_view cocoa_view;
    macdrv_view client_cocoa_view;
};

struct macdrv_functions_t
{
    void (*macdrv_init_display_devices)(BOOL);
    struct macdrv_win_data *(*get_win_data)(HWND hwnd);
    void (*release_win_data)(struct macdrv_win_data *data);
    macdrv_window (*macdrv_get_cocoa_window)(HWND hwnd, BOOL require_on_screen);
    macdrv_metal_device (*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(macdrv_metal_device d);
    macdrv_metal_view (*macdrv_view_create_metal_view)(macdrv_view v,
                                                       macdrv_metal_device d);
    macdrv_metal_layer (*macdrv_view_get_metal_layer)(macdrv_metal_view v);
    void (*macdrv_view_release_metal_view)(macdrv_metal_view v);
    void (*on_main_thread)(dispatch_block_t b);
};

static pthread_mutex_t g_layer_lock = PTHREAD_MUTEX_INITIALIZER;
static CAMetalLayer *g_fullscreen_layer = nil;

void winarc_display_set_layer(CAMetalLayer *layer)
{
    pthread_mutex_lock(&g_layer_lock);

    if (layer != g_fullscreen_layer)
    {
        if (layer) CFRetain((__bridge CFTypeRef)layer);
        if (g_fullscreen_layer)
            CFRelease((__bridge CFTypeRef)g_fullscreen_layer);

        g_fullscreen_layer = layer;
    }

    pthread_mutex_unlock(&g_layer_lock);
}

static _Thread_local struct macdrv_win_data g_win_data;

static struct macdrv_win_data *winarc_get_win_data(HWND hwnd)
{
    g_win_data.hwnd = hwnd;
    g_win_data.cocoa_window = NULL;

    /*
     * The iOS DXMT shim only needs a stable token that identifies the Wine
     * window. Reusing HWND avoids a second cross-thread mapping table.
     */
    g_win_data.cocoa_view = (macdrv_view)hwnd;
    g_win_data.client_cocoa_view = (macdrv_view)hwnd;

    return &g_win_data;
}

static void winarc_release_win_data(struct macdrv_win_data *data)
{
    (void)data;
}

static macdrv_metal_device winarc_create_metal_device(void)
{
    return (macdrv_metal_device)(uintptr_t)0x1;
}

static void winarc_release_metal_device(macdrv_metal_device device)
{
    (void)device;
}

static CAMetalLayer *winarc_layer_for_view(macdrv_view view)
{
    const char *desktop = getenv("WINARC_DESKTOP");

    if (desktop && desktop[0] == '1')
        return winios_metal_layer_for_hwnd((void *)view);

    pthread_mutex_lock(&g_layer_lock);

    CAMetalLayer *layer = g_fullscreen_layer;
    if (layer)
        CFRetain((__bridge CFTypeRef)layer);

    pthread_mutex_unlock(&g_layer_lock);

    return layer;
}

static macdrv_metal_view
winarc_create_metal_view(macdrv_view view, macdrv_metal_device device)
{
    (void)device;

    CAMetalLayer *layer = winarc_layer_for_view(view);

    if (!layer)
    {
        fprintf(stderr,
                "[WinArc/DXMT] no CAMetalLayer for view=%p desktop=%s\n",
                view,
                getenv("WINARC_DESKTOP") ? getenv("WINARC_DESKTOP") : "0");
        return NULL;
    }

    /*
     * Winios returns an unretained layer; fullscreen mode already retained it
     * inside winarc_layer_for_view(). Make both modes obey the same ownership
     * contract expected by macdrv_view_release_metal_view().
     */
    const char *desktop = getenv("WINARC_DESKTOP");
    if (desktop && desktop[0] == '1')
        CFRetain((__bridge CFTypeRef)layer);

    return (macdrv_metal_view)(__bridge void *)layer;
}

static macdrv_metal_layer
winarc_get_metal_layer(macdrv_metal_view view)
{
    return (macdrv_metal_layer)view;
}

static void winarc_release_metal_view(macdrv_metal_view view)
{
    if (view)
        CFRelease((CFTypeRef)view);
}

static void winarc_on_main_thread(dispatch_block_t block)
{
    if (!block) return;

    if ([NSThread isMainThread])
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

__attribute__((used, visibility("default")))
struct macdrv_functions_t macdrv_functions = {
    .macdrv_init_display_devices = NULL,
    .get_win_data = winarc_get_win_data,
    .release_win_data = winarc_release_win_data,
    .macdrv_get_cocoa_window = NULL,
    .macdrv_create_metal_device = winarc_create_metal_device,
    .macdrv_release_metal_device = winarc_release_metal_device,
    .macdrv_view_create_metal_view = winarc_create_metal_view,
    .macdrv_view_get_metal_layer = winarc_get_metal_layer,
    .macdrv_view_release_metal_view = winarc_release_metal_view,
    .on_main_thread = winarc_on_main_thread,
};

__attribute__((used, visibility("default")))
struct macdrv_win_data *get_win_data(HWND hwnd)
{
    return winarc_get_win_data(hwnd);
}

__attribute__((used, visibility("default")))
void release_win_data(struct macdrv_win_data *data)
{
    winarc_release_win_data(data);
}

__attribute__((used, visibility("default")))
macdrv_metal_view
macdrv_view_create_metal_view(macdrv_view view, macdrv_metal_device device)
{
    return winarc_create_metal_view(view, device);
}

__attribute__((used, visibility("default")))
macdrv_metal_layer macdrv_view_get_metal_layer(macdrv_metal_view view)
{
    return winarc_get_metal_layer(view);
}

__attribute__((used, visibility("default")))
void macdrv_view_release_metal_view(macdrv_metal_view view)
{
    winarc_release_metal_view(view);
}
