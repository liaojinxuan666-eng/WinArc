/*
 * WinArc Wine host boundary - bring-up stubs.
 *
 * These definitions exist ONLY to close the iOS host side of the Revision-9
 * reference archive during the first executable-link/device-probe stage.
 *
 * They are intentionally minimal: no Wine execution is started in v0.0.2.
 * Window/display/DXMT callbacks are replaced later by WinArc-owned runtime
 * implementations as each subsystem is enabled.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

/* ------------------------------------------------------------------------- */
/* Wine/iOS process-exit state expected by the ntdll iOS exit shim.           */
/* ------------------------------------------------------------------------- */

_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;

/* ------------------------------------------------------------------------- */
/* wineserver host state.                                                     */
/* ------------------------------------------------------------------------- */

volatile int g_wineserver_should_stop = 0;

void fatal_error(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    fputs("[WinArc/Wine] fatal_error: ", stderr);
    if (format) vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);

    /* Never kill the UIKit process from the wineserver path. */
    pthread_exit(NULL);
}

/* Wine normally generates this during its full build. */
const char wine_build[] = "wine-11.4-ios-winarc-reference";

/* ------------------------------------------------------------------------- */
/* iOS does not expose the macOS IOPowerSources API used by desktop Wine.     */
/* Madeira solves the same final-link gap with null-returning host stubs.      */
/* ------------------------------------------------------------------------- */

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

/* ------------------------------------------------------------------------- */
/* Graphics backend boundary. v0.0.2 only links/probes Wine; no DXMT call is  */
/* allowed yet, so the table is deliberately null.                            */
/* ------------------------------------------------------------------------- */

void *dxmt_winemetal_unix_call_funcs = NULL;

/* ------------------------------------------------------------------------- */
/* Minimal display-driver host hooks.                                         */
/* They close weak/user-driver references without creating UIKit surfaces.    */
/* ------------------------------------------------------------------------- */

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
