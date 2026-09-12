/*
 * WinArc Wine host boundary.
 *
 * WinArc 0.0.1 device bring-up. wineserver already runs in-process.
 * Graphics now uses a weak DXMT fallback so the real, strong DXMT winemetal
 * call table can replace it as soon as libWinArcDXMT.a is linked.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

extern void winarc_wine_runtime_report_fatal(const char *message);

_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;

void __clear_cache(void *start, void *end)
{
    uintptr_t begin = (uintptr_t)start;
    uintptr_t finish = (uintptr_t)end;

    if (!begin || finish <= begin) return;
    sys_icache_invalidate((void *)begin, (size_t)(finish - begin));
}

volatile int g_wineserver_should_stop = 0;

void fatal_error(const char *format, ...)
{
    char buffer[1024];
    va_list args;

    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer),
              format ? format : "unknown wineserver fatal error",
              args);
    va_end(args);

    fprintf(stderr, "[WinArc/Wine] fatal_error: %s\n", buffer);
    fflush(stderr);

    winarc_wine_runtime_report_fatal(buffer);

    /* wineserver and UIKit share one Mach process. */
    pthread_exit(NULL);
}

const char wine_build[] = "wine-11.4-ios-winarc-reference";

CFTypeRef IOPSCopyPowerSourcesInfo(void)
{
    return NULL;
}

CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob)
{
    (void)blob;
    return NULL;
}

CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef source)
{
    (void)blob;
    (void)source;
    return NULL;
}

/*
 * Important: DXMT defines this as
 *
 *     const void *dxmt_winemetal_unix_call_funcs[]
 *
 * Do not use the old `void *... = NULL` strong placeholder. A strong fake
 * definition collides with — or masks — the real table. This weak one-element
 * array is replaced by DXMT's strong definition at final link.
 */
__attribute__((weak))
const void *dxmt_winemetal_unix_call_funcs[] = { NULL };

int winios_pCreateWindow(void *hwnd)
{
    (void)hwnd;
    return 1;
}

int winios_pProcessEvents(unsigned long mask)
{
    (void)mask;
    return 1;
}

void winios_pSetCursor(void *hwnd, void *cursor)
{
    (void)hwnd;
    (void)cursor;
}

void winios_pDestroyCursorIcon(void *cursor)
{
    (void)cursor;
}

void winios_pDestroyWindow(void *hwnd)
{
    (void)hwnd;
}

unsigned int winios_pShowWindow(void *hwnd, int command, void *rect, unsigned int swp)
{
    (void)hwnd;
    (void)command;
    (void)rect;
    (void)swp;
    return 1;
}

void winios_pWindowPosChanged(void *hwnd,
                              void *insert_after,
                              void *owner_hint,
                              unsigned int swp_flags,
                              const void *new_rects,
                              void *surface)
{
    (void)hwnd;
    (void)insert_after;
    (void)owner_hint;
    (void)swp_flags;
    (void)new_rects;
    (void)surface;
}

void winios_surface_present(void *hwnd,
                            int dirty_x, int dirty_y, int dirty_w, int dirty_h,
                            int surface_w, int surface_h, int stride,
                            const void *bits)
{
    (void)hwnd;
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_w;
    (void)dirty_h;
    (void)surface_w;
    (void)surface_h;
    (void)stride;
    (void)bits;
}

void winios_window_frame(void *hwnd,
                         int x, int y, int w, int h, int visible,
                         int client_x, int client_y, int client_w, int client_h)
{
    (void)hwnd;
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)visible;
    (void)client_x;
    (void)client_y;
    (void)client_w;
    (void)client_h;
}

void winios_cursor_set(unsigned int id,
                       int w, int h, int hot_x, int hot_y,
                       const void *bgra)
{
    (void)id;
    (void)w;
    (void)h;
    (void)hot_x;
    (void)hot_y;
    (void)bgra;
}

void winios_cursor_show(int show)
{
    (void)show;
}

void winios_dump_srcbits(const void *bits, int w, int h, int stride)
{
    (void)bits;
    (void)w;
    (void)h;
    (void)stride;
}

void winios_phase(const char *name)
{
    (void)name;
}
