/*
 * WinArc Wine host boundary.
 *
 * Winios rendering lives in Winios.m. This file only contains process-level
 * host shims and compatibility counters required by the current DXMT/Wine
 * reference objects.
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
              format ? format : "unknown Wine fatal error",
              args);
    va_end(args);

    fprintf(stderr, "[WinArc/Wine] fatal_error: %s\n", buffer);
    fflush(stderr);

    winarc_wine_runtime_report_fatal(buffer);

    /*
     * Wine and UIKit share one Mach process. A fatal Wine worker must never
     * terminate WinArc itself.
     */
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
 * Current DXMT's present-cadence diagnostics reference these counters from
 * Madeira's instrumented ntdll build. WinArc's reference archive does not
 * export every diagnostic counter, so provide weak zero-value fallbacks.
 * If a later Wine build exports the real counters, its strong definitions win.
 *
 * Exact types match the upstream instrumented sources:
 *   ios_exc_msg_count                         -> int
 *   ios_srv_*_count / timeouts / req_count   -> int
 *   ios_srv_wait_us / wait_req_us             -> long long
 */
__attribute__((weak)) volatile int ios_exc_msg_count = 0;
__attribute__((weak)) volatile int ios_srv_req_count = 0;
__attribute__((weak)) volatile int ios_srv_wait_count = 0;
__attribute__((weak)) volatile int ios_srv_wait_timeouts = 0;
__attribute__((weak)) volatile long long ios_srv_wait_us = 0;
__attribute__((weak)) volatile long long ios_srv_wait_req_us = 0;
